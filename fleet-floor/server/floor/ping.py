"""The liveness tier, and the two primitives every other module runs on.

`log` and `run` live here because the ping is the cheapest thing that uses
them and the one that must never raise; everything else imports them from
here rather than keeping a copy.
"""

import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

from floor import PROBE, SILENT_AFTER_S

# box exec into a wedged box can block forever; every probe is capped so one
# sick box cannot stall the whole poll. Overridable so the test suite can
# exercise a wedged box without waiting the production timeout for it.
PROBE_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_PROBE_TIMEOUT", "45"))

# --- the ping tier ---------------------------------------------------------
#
# The evidence probe answers "what has this box been doing"; it reads ~600 log
# lines and cannot run often. "Is this box still answering" is a different and
# much cheaper question, and tying it to the evidence poll meant the fastest
# possible detection of a wedged guest was one full probe interval.
#
# `box exec <box> -- true` is the whole ping. Deliberately an EXEC and not a
# socket: a listening port is answered by the guest kernel, so it stays green
# through a userspace that can no longer fork. This round-trip needs the incus
# agent alive, a fork, an exec and a binary read off disk — it fails when the
# box is wedged, which is the entire point.
# Measured on the drill host: ~97ms wall, ~47ms host CPU per ping, and that
# 47ms is a FLOOR — `time` accounts only for children of the calling shell, so
# it excludes incusd's handling and the in-guest fork. At 10s across 7 boxes
# that is ~3% of a core. 1s would be ~33% for detection nothing downstream can
# act on.
#
# Two things this knob does NOT do, both of which make a smaller number a lie:
#   · values below 2 are silently ignored — ping_loop's sleep has a max(2, ...)
#     floor, so setting 1 buys nothing
#   · one wedged box paces the whole fleet — ping_once blocks until every
#     thread joins, up to PING_TIMEOUT_S + 5, so the configured interval is a
#     BEST case that degrades exactly when something is unhealthy
#
# The 97ms-normal against a 5000ms timeout is a 50x margin, and that is what
# makes PING_FAILS_TO_WEDGE=3 a wedge detector rather than a jitter detector.
PING_INTERVAL_S = int(os.environ.get("CREW_FLOOR_PING_INTERVAL", "10"))
# Tight on purpose. A healthy round-trip is ~100ms; anything past a couple of
# seconds is already the pathology, and a long timeout here would just
# reintroduce the interval it was meant to beat.
PING_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_PING_TIMEOUT", "5"))
# One dropped ping is a scheduler hiccup, not a wedge. Three consecutive
# misses (~30s) is a box that has stopped answering.
PING_FAILS_TO_WEDGE = int(os.environ.get("CREW_FLOOR_PING_FAILS", "3"))
# A round that cannot run (a failed `box list`) leaves the previous heartbeats
# published rather than wiping their miss counters. That is right, but a
# SUSTAINED host-level failure then leaves the last round's `ok: True` on
# screen forever — trading "counters reset" for "stale green", and stale green
# on a liveness widget is the failure this tier was added to prevent. Past this
# age a heartbeat is reported as unknown rather than believed. Generous enough
# that ordinary jitter never trips it: several rounds AND the wedge threshold.
PING_STALE_AFTER_S = int(os.environ.get(
    "CREW_FLOOR_PING_STALE_AFTER", str(PING_INTERVAL_S * (PING_FAILS_TO_WEDGE + 2))))

# The bound for a lock held with NOTHING IN FLIGHT: a duty run stalled between
# dispatches, which has no session ceiling to exceed. Two tick boundaries, the
# same number the SILENT rule uses — past it, tick.sh is logging "previous run
# still holds the lock" every 5 minutes and the box looks perfectly healthy
# while doing nothing.
#
# It is NOT the bound for a run with a session in flight, and the claim that
# used to stand here is the bug #610 fixes: *"run_session's own ceiling is
# 1800s, so this surfaces the wedge ~20 minutes before the timeout resolves
# it."* `run_session` has no ceiling of its own — session.sh passes the
# CALLER's `$tmo` to `timeout` — and 1800 is merely what three of the seven
# lanes happen to pass. The four that pass more (`build` and `resume` at
# 3600s, `hygiene` at 3000s, `review` at 2700s) were being called stuck at
# minute 10 for spending time they were dispatched to spend, and the badge
# that fired also HIDES the running-session panel. An alarm that is usually
# wrong is one an operator learns to scroll past.
#
# So the in-flight bound is the ceiling the session itself declares on its
# `SESSION START`, read off duty.log by `units.stuck_verdict`, which owns the
# whole decision. This number remains that function's second clause and its
# fallback for a record carrying no `timeout=` token, which is what
# `CREW_FLOOR_STUCK_AFTER` still tunes.
STUCK_AFTER_S = int(os.environ.get("CREW_FLOOR_STUCK_AFTER", str(SILENT_AFTER_S)))


LOG_LOCK = threading.Lock()


def log(msg):
    line = "%s floor: %s\n" % (
        datetime.now(timezone.utc).strftime("%H:%M:%S"), msg)
    # Fleet-wide actions finish on worker threads. Keep the complete human
    # evidence line together even when several boxes return simultaneously.
    with LOG_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def run(argv, timeout, stdin_data=None):
    """Run a host command. Returns (rc, stdout, stderr) and never raises.

    The timeout is enforced against the whole PROCESS GROUP, not just the
    child. `box exec` runs a shell inside the box; if anything it spawned
    outlives the kill while still holding the stdout pipe, communicate() waits
    for EOF on that pipe and blocks long past the deadline — which is exactly
    the hang the timeout exists to prevent, and it only shows up against the
    kind of wedged box the timeout was written for. start_new_session puts the
    child in its own group so killpg can take the whole tree down.
    """
    try:
        p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError as e:
        return 127, "", str(e)
    except Exception as e:                                  # noqa: BLE001
        return 1, "", str(e)

    try:
        out, err = p.communicate(
            stdin_data.encode() if stdin_data is not None else None, timeout=timeout)
        return (p.returncode,
                out.decode("utf-8", "replace"),
                err.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        try:
            p.communicate(timeout=5)
        except Exception:                                   # noqa: BLE001
            pass
        return 124, "", "timed out after %ss" % timeout
    except Exception as e:                                  # noqa: BLE001
        try:
            p.kill()
        except Exception:                                   # noqa: BLE001
            pass
        return 1, "", str(e)


# The ping already pays for a host-side process start (~47ms of the ~97ms);
# what runs INSIDE the guest is nearly free by comparison. So it reads two
# files on the way past, and STUCK detection moves from the 60s evidence tier
# to this one — a hung duty session is now seen ~6x sooner, for no extra cost.
#
# It emits the lock's AGE, never its raw contents. duty.sh writes an ABSOLUTE
# unix stamp (`date +%s`), and every consumer wants elapsed seconds — probe.sh
# has always converted. The first cut of this passenger shipped the stamp raw,
# so the overlay compared ~1.7e9 against STUCK_AFTER_S and a duty run that had
# started THAT SECOND rendered "STUCK — held the lock for 495881h". A false
# positive on every live tick, and the tests missed it twice over: stub-box
# answered with an already-computed age, and the real-shell test only asserted
# the field was non-empty. Both now assert it is an AGE.
#
# A non-numeric or future stamp emits nothing rather than a bogus number: a
# torn read (duty.sh writes this file at the top of every run) must never
# manufacture a wedge.
#
# `exit 0` is load-bearing and is this change's sharp edge. `.duty.lock.since`
# is ABSENT whenever no duty run is in flight, which is the normal state of a
# healthy idle box; `cat` on a missing file exits 1, so without the explicit
# exit every healthy box would fail three pings and render UNREACHABLE. The
# `[ -r ]` guard makes that impossible independently, and a test asserts a box
# with no lock file still pings ok.
#
# rc semantics are unchanged, and that is the point: a non-zero rc still means
# "could not run anything in the guest", which is the entire liveness claim.
# The parsed output is a PASSENGER — malformed, empty or absent output never
# turns into a failed ping, because the one tier that must never lie now has a
# parser attached to it. Everything it reads degrades to None.
PING_SH = (
    'printf "u %s\n" "$(cut -d. -f1 /proc/uptime 2>/dev/null)"; '
    's=""; d="${DUTY_DIR:-$HOME/duty}"; '
    'if [ -r "$d/.duty.lock.since" ]; then '
    'v="$(cat "$d/.duty.lock.since" 2>/dev/null)"; '
    'case "$v" in \'\'|*[!0-9]*) : ;; '
    '*) a=$(( $(date +%s) - v )); [ "$a" -ge 0 ] && s="$a" ;; '
    'esac; fi; '
    'printf "l %s\n" "$s"; '
    'exit 0'
)


def parse_ping(out):
    """The passenger facts, or None each. NEVER raises and never signals."""
    facts = {"uptime": None, "lockheld": None}
    for line in (out or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        key, val = parts
        if key not in ("u", "l"):
            continue
        try:
            n = int(val.strip())
        except (TypeError, ValueError):
            continue
        if key == "u":
            facts["uptime"] = n
        elif n >= 0:
            facts["lockheld"] = n
    return facts


def ping_box(name):
    """Is this box answering? Returns (ok, milliseconds, error, facts).

    The cheapest `box exec` that still proves a fork: no stdin, no script piped
    in, one tiny shell in the guest. Never raises — an unreachable box is a
    datum, like everywhere else in this file.
    """
    t0 = time.time()
    rc, out, err = run(["box", "exec", name, "--", "sh", "-c", PING_SH],
                       PING_TIMEOUT_S)
    ms = int((time.time() - t0) * 1000)
    if rc == 0:
        return True, ms, "", parse_ping(out)
    if rc == 124:
        return False, ms, "no answer in %ss" % PING_TIMEOUT_S, {}
    return False, ms, (err.strip().splitlines() or ["box exec rc %d" % rc])[-1], {}


def probe_box(unit, agent_conf, env=None):
    """One box's evidence, via `box exec`. Never raises — failure is a datum.

    `env` is a dict of `NAME=value` the script runs under — the host's own
    environment does not cross `box exec`, so it is exported at the top of
    the script text itself. The store's full mode (#758) is `PROBE_FULL=1`
    and `PROBE_LOG_FROM=<n>`; values are restricted to the shape an export
    can carry unquoted, and anything else is dropped rather than quoted.
    """
    with open(PROBE) as f:
        script = f.read()
    if env:
        exports = " ".join("%s=%s" % (k, v) for k, v in sorted(env.items())
                           if re.fullmatch(r"[A-Z_][A-Z0-9_]*", str(k))
                           and re.fullmatch(r"[A-Za-z0-9._:/-]*", str(v)))
        if exports:
            script = "export %s\n%s" % (exports, script)
    rc, out, err = run(["box", "exec", unit["box"], "--", "bash", "-lc", script],
                       PROBE_TIMEOUT_S, stdin_data=agent_conf)
    if rc != 0:
        return None, (err.strip().splitlines() or ["box exec failed (rc %d)" % rc])[-1]
    return out, None
