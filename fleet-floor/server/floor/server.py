"""HTTP: the request handler, the server, and the process entry point."""

import base64
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from floor import INDEX
from floor.actions import do_command
from floor.alerts import alert_command_from_config
from floor.fleet import Fleet
from floor.ping import PING_INTERVAL_S, log, run
from floor.registry import snapshot as registry_snapshot
from floor.roster import CONFIG_DIR, read_roster, require_operator_config, roster_snapshot

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "crew-floor"
    protocol_version = "HTTP/1.1"

    # Args injected by serve()
    fleet = None
    auth_token = None
    # WHO, for the registry journal (#488 D5). The floor authenticates one
    # operator identity, so this is the whole of what the process knows about
    # the hand behind a write — and naming it beats recording every registry
    # change against nobody. Set beside the token it is half of.
    auth_user = ""

    def log_message(self, fmt, *args):
        pass                                    # the poller's log() is the log

    # -- auth ---------------------------------------------------------------
    def authed(self):
        got = self.headers.get("Authorization", "")
        if not got.startswith("Basic "):
            return False
        return hmac.compare_digest(got[6:].strip(), self.auth_token)

    def deny(self):
        # Slow a guesser down. The server is threaded, so this costs the
        # attacker far more than it costs the operator who mistyped once.
        time.sleep(0.5)
        body = b"crew floor: authentication required\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="crew floor"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- helpers ------------------------------------------------------------
    def send_bytes(self, status, ctype, payload, cache=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        if not cache:
            self.send_header("Cache-Control", "no-store")
        # The page has control actions; keep it out of anything else's frame.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, status, obj):
        self.send_bytes(status, "application/json; charset=utf-8",
                        json.dumps(obj).encode("utf-8"))

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        if not self.authed():
            return self.deny()
        path = urlparse(self.path).path
        qs = parse_qs(urlparse(self.path).query)

        if path in ("/", "/index.html"):
            try:
                with open(INDEX, "rb") as f:
                    return self.send_bytes(200, "text/html; charset=utf-8", f.read())
            except OSError as e:
                return self.send_bytes(500, "text/plain; charset=utf-8",
                                       ("cannot read %s: %s\n" % (INDEX, e)).encode())

        if path == "/api/fleet":
            return self.send_json(200, self.fleet.get())

        if path == "/api/registries":
            # Its own endpoint rather than a key on `/api/fleet`, because the
            # two answer at different costs and on different clocks: the fleet
            # snapshot is a background thread's 60s probe of every guest, and
            # this is two small reads off the host's own disk. Folding the
            # registries into the snapshot would serve them at the poller's
            # cadence — up to a minute after the operator's own write — and
            # reading them fresh on every request is what makes a hand edit
            # visible with no floor restart (#488 D4).
            return self.send_json(200, registry_snapshot(
                [u["box"] for u in read_roster()]))

        if path == "/api/roster":
            # Read fresh on every request, as the registries are: what the
            # editor opens on is the file as it is on disk right now, so a
            # hand edit between two clicks is picked up with no restart.
            return self.send_json(200, roster_snapshot())

        if path == "/api/logs":
            return self.serve_log(qs)

        if path == "/healthz":
            return self.send_bytes(200, "text/plain; charset=utf-8", b"ok\n")

        # The page reports errors for a living; a 404 for the icon Chrome asks
        # for unprompted is noise in exactly the console an operator scans.
        if path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")

    def serve_log(self, qs):
        box = (qs.get("box") or [""])[0]
        name = (qs.get("file") or [""])[0]
        if box not in {u["box"] for u in read_roster()}:
            return self.send_bytes(400, "text/plain; charset=utf-8", b"unknown box\n")
        # The filename comes from the browser: allow only the shape run_session
        # generates, so no traversal or shell metacharacter can reach the box.
        if name and not re.fullmatch(r"[A-Za-z0-9._@#-]{1,120}", name):
            return self.send_bytes(400, "text/plain; charset=utf-8", b"bad log name\n")
        target = ('"$HOME/duty/logs/%s"' % name) if name else '"$HOME/duty/duty.log"'
        rc, out, err = run(["box", "exec", box, "--", "bash", "-lc",
                            "tail -n 500 %s 2>/dev/null" % target], 30)
        payload = out if rc == 0 else "unreadable: %s" % (err.strip() or "rc %d" % rc)
        return self.send_bytes(200, "text/plain; charset=utf-8",
                               payload.encode("utf-8", "replace"))

    # Without these, BaseHTTPRequestHandler answers 501 from inside its own
    # request loop — before do_*() and therefore before any auth check. An
    # unauthenticated caller should learn nothing but "authenticate", so every
    # method this server does not implement is routed through the same gate.
    def do_PUT(self):
        return self.deny() if not self.authed() else self.send_bytes(
            405, "text/plain; charset=utf-8", b"method not allowed\n")

    do_DELETE = do_PUT
    do_PATCH = do_PUT
    do_OPTIONS = do_PUT

    def do_HEAD(self):
        if not self.authed():
            return self.deny()
        self.send_bytes(405, "text/plain; charset=utf-8", b"")

    def do_POST(self):
        if not self.authed():
            return self.deny()
        path = urlparse(self.path).path
        if path != "/api/command":
            return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 64 * 1024:
                return self.send_json(413, {"ok": False, "error": "body too large"})
            body = json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as e:
            return self.send_json(400, {"ok": False, "error": "bad JSON: %s" % e})
        status, result = do_command(self.fleet, body, actor=self.auth_user)
        return self.send_json(status, result)


def serve(bind, port, user, password, interval):
    if not os.path.exists(INDEX):
        # Named for both trees this runs in: a checkout, where build.sh is the
        # fix, and an installed one, which carries the built page and not the
        # builder (#365) — so advice naming only build.sh cannot be followed
        # there. "a repository checkout" rather than the obvious alternative:
        # run.sh's floor-named-crew-verb-roster-is-complete greps `crew <word>`
        # out of this whole file, comments included, and prose in that position
        # mints a console verb that does not exist.
        sys.exit("crew floor: %s is missing — build it with fleet-floor/build.sh "
                 "in a repository checkout, or reinstall (an installed tree "
                 "carries the built page, not the builder)" % INDEX)

    alert_command, alert_error = alert_command_from_config(CONFIG_DIR)
    if alert_error:
        log(alert_error)
    fleet = Fleet(interval, alert_command)
    Handler.fleet = fleet
    Handler.auth_token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    Handler.auth_user = user

    threading.Thread(target=fleet.loop, daemon=True).start()
    if PING_INTERVAL_S > 0:
        threading.Thread(target=fleet.ping_loop, daemon=True).start()

    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    log("serving fleet-floor on http://%s:%d/ (evidence every %ds, ping every %ds)"
        % (bind, port, interval, PING_INTERVAL_S))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        httpd.shutdown()


def main():
    # First, and before the auth and index preconditions below: an
    # unconfigured host must get the config answer, not a missing-password or
    # missing-build one — the same order cmd_floor uses.
    require_operator_config()
    ap_port = int(os.environ.get("CREW_FLOOR_PORT", "8420"))
    ap_bind = os.environ.get("CREW_FLOOR_BIND", "0.0.0.0")
    ap_user = os.environ.get("CREW_FLOOR_USER", "operator")
    ap_pass = os.environ.get("CREW_FLOOR_PASS", "")
    ap_int = int(os.environ.get("CREW_FLOOR_INTERVAL", "60"))
    if not ap_pass:
        sys.exit("crew floor: CREW_FLOOR_PASS is unset — refusing to serve "
                 "operator controls without auth")
    serve(ap_bind, ap_port, ap_user, ap_pass, ap_int)
