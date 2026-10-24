"""Operator control (#39): the scripts fired into a box, and the dispatcher.

`floor_message_prompt` lives here rather than beside the paths it reads: the
envelope exists for exactly one caller, the `message` action below.
"""

import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from floor import FLOOR_ENVELOPE
from floor.ping import log, run
from floor.registry import KINDS, clear_override, set_fleet, set_override
from floor.roster import CONFIG_DIR, CREW_ROOT, box_states, read_roster, roster_set

ACTION_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_ACTION_TIMEOUT", "120"))
# Fleet-wide controls share the host with evidence and heartbeat fan-outs.
# Eight is a no-op for today's seven-member roster and a hard ceiling as the
# single-role fleet grows.
ACTION_WORKERS = 8


def force_stop_argv(box):
    """The host command that stops a guest which cannot stop itself (#486).

    Every stop the floor could fire was graceful: `box down` is `incus stop`
    with neither `--force` nor a timeout, so against a guest that can no
    longer schedule its own shutdown it runs out ACTION_TIMEOUT_S and the
    action reports failure. The one box state that needs stopping was the one
    state the console could not stop.

    Deliberately box's own non-interactive incus passthrough and NOT a new
    `box down --force`: heavy-duty/box#11's ownership rule puts that flag
    outside box, so this carries no cross-repo dependency (D2). One definition
    because two call sites fire it — the `force-stop` action and restart's
    recovery — and a second spelling is a second thing to keep in step.
    """
    return ["box", "incus", box, "--", "stop", "--force"]


def floor_message_prompt(operator_text):
    """Wrap an operator message in the shared one-shot environment contract."""
    try:
        with open(FLOOR_ENVELOPE, encoding="utf-8") as src:
            envelope = src.read()
    except OSError as exc:
        raise RuntimeError("floor message envelope unavailable: %s" % exc) from exc
    if not envelope:
        raise RuntimeError("floor message envelope is empty: %s" % FLOOR_ENVELOPE)
    return envelope + operator_text


# --------------------------------------------------------------------------
# operator control  (#39)
# --------------------------------------------------------------------------

# Fired into the box with `box exec`; the box initiates nothing.
#
# Each script states its own verdict on the last line and exits deliberately.
# It used to end on a bare `grep -c`, and `grep -c` exits 1 when it counts
# zero — so the count WAS the exit status, and a box with no armed `tick.sh`
# line reported the same rc 1 as a box that could not be reached. `in_box`
# read that as ok=False, `do_command` answered 500, and the console rendered
# it "command refused" (#188). Nothing was refusing: a count of zero was
# being reported as a failure, which is #176's shape — "nothing to do" and
# "it went wrong" collapsed into one status.
#
# Three outcomes, three answers: `paused N` (it took effect), `nothing to
# pause: ...` (rc 0, there was nothing armed), and a non-zero exit whose
# stderr says why. The counts travel as data on stdout; only a real failure
# is allowed to redden the row. Each write is checked on its own exit status
# rather than inferred from a later read, so a `crontab -` that refuses is
# named as the failure it is.
#
# N is the number of lines THIS call moved, not the number of lines now in
# the target state: a box carrying a `#CREW-FLOOR-PAUSED` line from an
# earlier pause, plus one armed line, pauses one line and says `paused 1`.
# Reporting the post-state total would say `paused 2` — an overcount on a
# control plane whose whole subject is saying what it actually did.
#
# That is also why the crontab is read ONCE, into `cron`, and the write is
# fed from that snapshot rather than from a second `crontab -l`: the counts
# and the text being rewritten are then the same crontab, so the delta check
# below means what it says. It costs one read rather than adding one.
# Both scripts are read out of shared/lib/host/pause.sh, the one copy (#284):
# cli/crew sources that file and the floor extracts the two marked blocks, so
# `crew pause` and the floor's pause button run byte-identical shell (#759).
def _host_shell_block(name):
    path = os.path.join(CREW_ROOT, "shared", "lib", "host", "pause.sh")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    start = text.index("# ---%s---\n" % name) + len("# ---%s---\n" % name)
    # A leading newline, as the embedded strings had: the stub box logs the
    # script after `bash -lc `, and the floor suite's needle reads the first
    # line of RESUME_SH right after that newline.
    return "\n" + text[start:text.index("# ---END---", start)]

PAUSE_SH = _host_shell_block("PAUSE_SH")


def _paused_marker(box, on):
    """`<config>/store/paused/<box>`: the file `crew pause` writes and `crew
    tick` reads, so the button and the verb pause the same way."""
    d = os.path.join(CONFIG_DIR, "store", "paused")
    path = os.path.join(d, box)
    if on:
        os.makedirs(d, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
RESUME_SH = _host_shell_block("RESUME_SH")

# The operator's message becomes a real session of the box's own vendor CLI,
# detached so the HTTP request does not hold a model run open, and logged where
# every other session logs so it shows up in the console's history.
MESSAGE_SH = r"""
set -u
# Every path here is per-invocation. They used to be fixed names, and the
# server is threaded: two rapid messages to one box interleaved as
#   write prompt A -> launch A -> write prompt B -> A reads .floor-prompt
# and session A ran prompt B. An operator's instruction executed with someone
# else's text, on a real box. Same-second sessions also collided on the log
# name. __TOK__ is a uuid4 hex minted per request by the collector.
tok="__TOK__"
conf="/tmp/.crew-floor-agent.$tok.conf"
pf="${DUTY_DIR:-$HOME/duty}/.floor-prompt.$tok"
cat >"$conf"
timeout_names="$(sed -n 's/^[[:space:]]*\(TIMEOUT_[A-Z0-9_]*\)=.*/\1/p' "$conf")"
# shellcheck disable=SC1090
source "$conf"
operator_timeout="${TIMEOUT_OPERATOR:-}"
if [ -z "$operator_timeout" ]; then
  operator_timeout=0
  while IFS= read -r timeout_name; do
    [ -n "$timeout_name" ] || continue
    [ "$timeout_name" = TIMEOUT_OPERATOR ] && continue
    eval 'timeout_value=${'"$timeout_name"':-}'
    case "$timeout_value" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$timeout_value" -le "$operator_timeout" ] || operator_timeout="$timeout_value"
  done <<<"$timeout_names"
fi
case "$operator_timeout" in
  ''|*[!0-9]*|0) echo "invalid operator timeout: $operator_timeout" >&2; rm -f "$conf"; exit 2 ;;
esac
export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
mkdir -p "$DUTY_DIR/logs"
# Read ONCE, here, and hand the bytes to the detached shell as an argument.
# The re-read inside that shell was the race: it resolved the path long after
# this request had returned.
prompt="$(cat "$pf")"
rm -f "$pf"
[ -n "$prompt" ] || { echo "empty prompt"; rm -f "$conf"; exit 2; }
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
slog="$DUTY_DIR/logs/$(date -u '+%Y%m%dT%H%M%SZ')-operator-floor-$tok.log"
# One O_APPEND write under 4K is atomic, so this cannot interleave with a
# tick's own line even though the operator session runs outside the duty flock.
printf '%s SESSION START kind=operator key=floor timeout=%ss log=%s\n' "$ts" "$operator_timeout" "$slog" >>"$DUTY_DIR/duty.log"
nohup setsid bash -c '
  DUTY_DIR="'"$DUTY_DIR"'"; slog="'"$slog"'"; conf="'"$conf"'"; operator_timeout="'"$operator_timeout"'"
  start=$SECONDS; rc=0; session_stamp="${slog##*/}"
  source "$conf"; rm -f "$conf"
  export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
  cd "$HOME"
  env DUTY_SESSION_STAMP="$session_stamp" \
    timeout -k 60 "$operator_timeout" "${BOT_CLI_CMD[@]}" "$1" </dev/null >"$slog" 2>&1 || rc=$?
  proc_root="${SESSION_PROC_ROOT:-/proc}"; left=unknown
  if [ -d "$proc_root" ]; then
    count=0; scanned=0
    for environ in "$proc_root"/[0-9]*/environ; do
      [ -f "$environ" ] || continue
      if grep -Fzxq -- "DUTY_SESSION_STAMP=$session_stamp" "$environ" 2>/dev/null; then
        erc=0
      else
        erc=$?
      fi
      case "$erc" in
        0) count=$((count + 1)); scanned=$((scanned + 1));;
        1) scanned=$((scanned + 1));;
      esac
    done
    [ "$scanned" -eq 0 ] || left="$count"
  fi
  dur=$((SECONDS - start)); v=ok; acted=unknown
  [ "$rc" -eq 124 ] && v=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && v=FAILED
  if declare -F bot_session_acted >/dev/null 2>&1; then
    bot_session_acted "$slog" && arc=0 || arc=$?
    case "$arc" in 0) acted=yes;; 1) acted=no;; esac
  fi
  reply_tail="$(awk '\''NF { line=$0 } END { printf "%s", substr(line, 1, 200) }'\'' "$slog" 2>/dev/null | base64 | tr -d '\''\n'\'')"
  log_bytes="$(stat -c %s -- "$slog" 2>/dev/null)" || log_bytes=unknown
  case "$log_bytes" in ""|*[!0-9]*) log_bytes=unknown;; esac
  printf "%s SESSION END kind=operator key=floor rc=%s dur=%ss outcome=%s acted=%s reply_tail=%s log=%s left=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$dur" "$v" "$acted" "$reply_tail" "$log_bytes" "$left" >>"$DUTY_DIR/duty.log"
' _ "$prompt" </dev/null >/dev/null 2>&1 &
echo "session started; log $slog"
"""


def registry_command(action, box, body, actor):
    """The three registry writes (#488). Returns (http_status, result dict).

    Split out of `do_command`'s ladder rather than adding three more `elif`
    arms to it, because these share nothing with the arms around them: no
    `box exec`, no host verb, no per-box row, and — the reason it matters —
    NO REFRESH. Every other action changes what the fleet snapshot renders, so
    it ends by asking for a re-poll; a registry write changes two files on the
    host's own disk and nothing the snapshot carries, and firing a fleet-wide
    probe storm after an edit would spend seven `box exec` round-trips to
    re-learn facts that did not move.

    A refusal here is 400 and not 500: the operator typed something the fleet
    will not accept, and nothing was written. That is a different thing from a
    box that was asked to do something and refused, which is what 500 means
    everywhere else in this module.

    AND IT IS A DIFFERENT THING AGAIN FROM AN EDIT THAT LANDED WITHOUT ITS
    RECORD, which is the one failure where the registry moved and the answer is
    still not "ok". The writers say which by whether they hand back a result
    alongside the error: no result means nothing was written and the page may
    say `refused`; a result WITH an error means the file on disk changed and
    could not be journalled, so it is a 500, `refused` is false, `recorded` is
    false, and the result travels with it. Reporting that as a refusal would
    tell the operator their edit did not land while the fleet's scope had
    already moved — the one wrong answer this endpoint can give.
    """
    kind = str(body.get("kind", ""))
    if kind not in KINDS:
        return 400, {"ok": False, "error": "unknown registry %r" % kind}

    if action == "registry-set":
        result, err = set_fleet(kind, list(body.get("entries") or []), actor)
    elif action == "registry-override":
        result, err = set_override(kind, box, list(body.get("entries") or []),
                                   actor)
    else:
        result, err = clear_override(kind, box, actor)

    if err and result is not None:
        return 500, {"ok": False, "action": action, "error": err,
                     "refused": False, "recorded": False,
                     "registry": result, "results": []}
    if err:
        return 400, {"ok": False, "action": action, "error": err,
                     # The same flag `restart` raises for its own 409: nothing
                     # ran, so the page must be able to say "refused" without
                     # parsing prose, and there are no per-box rows to carry
                     # the news the way a failed action's do (#486).
                     "refused": True}
    return 200, {"ok": True, "action": action, "registry": result,
                 # An empty `results` is the honest answer — no box was
                 # touched — and `do_command`'s own rule already reads an empty
                 # list as success for every action but `message`.
                 "results": []}


def do_command(fleet, body, actor=""):
    """Apply one operator action. Returns (http_status, result dict).

    `actor` is the authenticated operator, carried only as far as the registry
    journal (#488 D5). Defaulted so every existing caller — this repo's own
    suites among them — keeps the signature it had.
    """
    action = str(body.get("action", ""))
    box = str(body.get("box", ""))

    roster = {u["box"]: u for u in read_roster()}
    fleet_wide = {"start-all", "stop-all", "wake-silent", "registry-set", "roster-set"}
    registry = {"registry-set", "registry-override", "registry-inherit"}

    if action not in fleet_wide:
        if box not in roster:
            return 400, {"ok": False, "error": "unknown box %r" % box}

    # AFTER the roster check and before everything else. The per-box writes
    # need `box` to name a real roster member — an override file for a box that
    # is not in the fleet is a file nothing will ever read — and the fleet-wide
    # write needs no box at all, which is why it joins the set above.
    if action in registry:
        return registry_command(action, box, body, actor)
    if action == "roster-set":
        # The roster, whole (#764): the registry writers' three
        # outcomes, with the same codes. A refusal is 400 and nothing moved; a
        # landed edit without its record is 500 with the result beside it. A
        # refresh IS asked for here, unlike a registry write: the roster is
        # exactly what the snapshot enumerates, so the next poll must read it.
        result, err = roster_set(body.get("members"), actor)
        if result is None:
            return 400, {"ok": False, "action": action, "error": err, "refused": True}
        fleet.request_refresh()
        if err:
            return 500, {"ok": False, "action": action, "error": err, "refused": False,
                         "roster": result, "results": []}
        return 200, {"ok": True, "action": action, "roster": result, "results": []}

    def one(name, argv, timeout=ACTION_TIMEOUT_S, stdin_data=None, step=None):
        rc, out, err = run(argv, timeout, stdin_data)
        ok = rc == 0
        # `step` names WHICH call this row is, for the actions that now have
        # more than one shape: restart reaches its box gracefully or by force
        # depending on whether the box still answers, and "the action records
        # what it did" is worthless if the record cannot say which (#486 D4).
        # Additive and only where a caller passes one, so every row this
        # module wrote before carries exactly the keys it carried before.
        log("%s %s%s -> rc %d" % (action, name, " (%s)" % step if step else "", rc))
        row = {"box": name, "ok": ok, "out": (out or err).strip()[-400:]}
        if step:
            row["step"] = step
        return row

    def in_box(name, script, stdin_data=None, step=None):
        return one(name, ["box", "exec", name, "--", "bash", "-lc", script],
                   stdin_data=stdin_data, step=step)

    def operator_conf_for(name):
        unit = roster[name]
        return fleet.operator_conf(unit["agent"], unit["room"])

    def concurrently(tasks):
        """Run per-box calls together and return results in submission order."""
        if not tasks:
            return []
        with ThreadPoolExecutor(max_workers=min(len(tasks), ACTION_WORKERS)) as pool:
            futures = [pool.submit(fn, *args) for fn, args in tasks]
            return [future.result() for future in futures]

    def done(result):
        """Make an already-known per-box result fit a concurrent task list."""
        return result

    # `wake-silent` reaches a box three different ways and the reply says which,
    # in the vocabulary #486 added for restart's two: `start` for a box that is
    # down, `resume` for one whose crontab can still be restored, `escalate` for
    # one nothing can be run inside. Named helpers because `concurrently` submits
    # `fn(*args)` and the step is not one of the caller's arguments.
    def wake_start(name):
        return one(name, ["box", "start", name], step="start")

    def wake_resume(name):
        return in_box(name, RESUME_SH, step="resume")

    results = []

    if action == "message":
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            return 400, {"ok": False, "error": "empty prompt"}
        if len(prompt) > 8000:
            return 400, {"ok": False, "error": "prompt too long"}
        try:
            prompt = floor_message_prompt(prompt)
        except RuntimeError as exc:
            return 500, {"ok": False, "error": str(exc)}
        # Two hops so the prompt is never interpolated into a shell string:
        # it travels as stdin bytes, and the session reads it from a file.
        # The filename carries a per-request token: with one fixed name, two
        # rapid messages to the same box raced and a session could run the
        # OTHER request's prompt.
        token = uuid.uuid4().hex
        w = one(box, ["box", "exec", box, "--", "bash", "-lc",
                      'mkdir -p "$HOME/duty" && cat > "$HOME/duty/.floor-prompt.%s"' % token],
                stdin_data=prompt)
        if not w["ok"]:
            results.append(w)
        else:
            results.append(in_box(box, MESSAGE_SH.replace("__TOK__", token),
                                  stdin_data=operator_conf_for(box)))

    elif action == "pause":
        # The host's marker FIRST: it is what keeps the host tick from starting
        # the box again (#759); the box's own crontab is paused after it.
        _paused_marker(box, True)
        results.append(in_box(box, PAUSE_SH))
    elif action == "resume":
        _paused_marker(box, False)
        results.append(in_box(box, RESUME_SH))
    elif action == "restart":
        # Force-then-start recovery WHEN THE BOX IS UNREACHABLE, and only then
        # (#486 D3). A box that still answers is restarted exactly as it was
        # before this branch existed — `box down`, then `box start` — because
        # a restart that quietly became a kill is the escalation D1 refuses,
        # one verb over.
        #
        # The predicate is the ping tier's own wedge rule, asked of the fleet
        # rather than re-derived here: what the console paints UNREACHABLE and
        # what this escalates on have to be one fact, or an operator meets two
        # answers about the same box mid-incident.
        #
        # ONE FACT IS NOT ENOUGH; IT HAS TO BE ONE DECISION. Publishing
        # `ping.wedged` stopped the page spelling a rule of its own, but the
        # page still read it from a snapshot up to one poll old while this
        # asked the ping map again on arrival. One rule evaluated at two times
        # is two answers: a box crossing the wedge boundary inside that window
        # let an operator confirm "it is stopped and started again" over a
        # host that then ran `stop --force`. Disclosing the kill afterwards is
        # not the same thing as being authorised to do it.
        #
        # So the confirmed path travels WITH the request. `mode` is not an
        # instruction — the collector still decides, exactly as above — it is
        # the operator's authorisation, a record of which sentence they were
        # shown. The two are compared, and a disagreement REFUSES rather than
        # picking a winner: nothing is fired at the host, in either direction.
        #
        # Absent means "graceful", which is what a bare restart meant before
        # this issue existed. That keeps the old request shape's old meaning
        # and makes the escalation reachable only from something that showed a
        # human the word FORCE-STOPPED — a client that names no mode cannot
        # kill a guest by arriving at the wrong moment.
        mode = str(body.get("mode", "graceful"))
        if mode not in ("graceful", "force"):
            return 400, {"ok": False, "error": "unknown restart mode %r" % mode}
        verdict = "force" if fleet.box_unreachable(box) else "graceful"
        if mode != verdict:
            # Refuse SYMMETRICALLY. Recovering into a gentler path is the
            # harmless direction, but an operator who was told "any running
            # session is lost" and got something else still met a console that
            # does not do what it says. One predicate, one behaviour.
            became = ("has stopped answering since that dialog, so restarting "
                      "it now would FORCE-STOP it"
                      if verdict == "force" else
                      "is answering again since that dialog, so restarting it "
                      "now would stop it gracefully")
            log("restart %s refused (confirmed %s, now %s)" % (box, mode, verdict))
            # Re-poll so the operator's next click carries the new verdict
            # rather than the snapshot that just went stale under them.
            fleet.request_refresh()
            return 409, {
                "ok": False,
                # REFUSED is not FAILED, and the page must be able to tell them
                # apart without parsing prose: nothing ran, so no per-box rows
                # exist to carry the news the way a failed action's do.
                "refused": True,
                "confirmed": mode,
                "verdict": verdict,
                "error": "%s %s. Nothing was done — confirm again." % (box, became),
            }
        if verdict == "force":
            stop = one(box, force_stop_argv(box), step="force-stop")
        elif box_states().get(box) == "stopped":
            # NOTHING TO STOP IS NOT A FAILED STOP, and once the start is
            # conditional on the stop row the difference is the whole action.
            # `box down` is not idempotent on the single-box path: it is
            # `incus:stop` (heavy-duty/box `bin/box:157`) and the single-box
            # branch runs `incus stop <inst>` bare under `set -euo pipefail`
            # (:3420), while the guard for this case — `fleet_op`'s
            # `stop:STOPPED -> ""` (:1187) — is reached only from `run_fleet`,
            # i.e. only by `box down all`. So `box down <already-stopped>`
            # exits non-zero. That was inert noise while the row was appended
            # and ignored; the moment it is read it swallows the start, and
            # `ac-restart` is the one ACCESS control state does not dim, so an
            # operator confirming "it is stopped and started again" over a
            # stopped box got neither half.
            #
            # The verb is not fired at a box already in the target state —
            # `stop-all` above has answered this exact question that way since
            # #77, and box itself settled it for its own verb with
            # `restart:STOPPED -> start`, whose comment explains why a single
            # start is not the stop-then-start composite #486 D1 forbids. Read
            # from `box_states()` because that is the source `stop-all` reads;
            # a box that moves between the list and the call lands on the
            # ordinary path below and the host decides, which is the right
            # answer and the same TOCTOU box accepts for the same reason.
            stop = {"box": box, "ok": True, "step": "down", "out": "already stopped"}
            log("restart %s (down) -> already stopped, not fired" % box)
        else:
            stop = one(box, ["box", "down", box], step="down")
        results.append(stop)
        # READ THE STOP BEFORE STARTING (#487 D2). The stop row was appended and
        # `box start` fired on the next line, on both of the paths above, with
        # neither branch looking at `.ok` — so a restart whose stop timed out
        # against a guest that cannot schedule its own shutdown went on to start
        # a box it had never stopped, and the reply carried the failed stop as
        # detail under an action the page had already animated as two steps.
        #
        # Starting is not harmless there: the graceful stop returns 124 having
        # ASKED for a shutdown that may still be in flight, so `box start` races
        # a guest that is either still up or on its way down. A restart that
        # could not stop the box has failed at the first of its two steps, and
        # the second one is not a repair for it.
        if stop["ok"]:
            results.append(one(box, ["box", "start", box], step="start"))
        else:
            # `ok: None`, the value #77 gave a row that is named in the detail
            # and excluded from the verdict. The action is ALREADY failed by the
            # stop row above, and a second `False` would report two refusals
            # where one thing went wrong — the page names `bad[0]`, and the
            # first failure is the one that explains this. What the row carries
            # is the one fact nothing else in the reply states: the start did
            # not run (#487 D4 — a lever that cannot act says so).
            #
            # AND NOTHING BEYOND IT. This said "so the box was left as it was",
            # which is a claim about the guest on the one path where the guest's
            # state is exactly what is unknown: the graceful stop returns 124
            # having ASKED for a shutdown that may still be in flight, so the
            # box may well be on its way down. Reporting an outcome it did not
            # establish is this issue's own D4, one clause over (round 1,
            # codex-bot and claude-bot). What is left is what the process knows
            # from its own return codes and nothing else.
            results.append({"box": box, "ok": None, "step": "start",
                            "out": "not started: the %s step failed"
                                   % stop["step"]})
    elif action == "force-stop":
        # ITS OWN ACTION, never an escalation from a graceful one (#486 D1):
        # an operator who fired Power off must not discover it became a kill.
        # That is also why nothing here checks reachability first — force is
        # what was asked for, and a control that second-guessed the operator
        # would be as surprising in the other direction.
        results.append(one(box, force_stop_argv(box), step="force-stop"))
    elif action == "power-off":
        results.append(one(box, ["box", "down", box]))
    elif action == "power-on":
        results.append(one(box, ["box", "start", box]))
    elif action in ("start-all", "stop-all"):
        verb = "start" if action == "start-all" else "down"
        states = box_states()
        tasks = []
        for name in roster:
            st = states.get(name)
            if st is None:
                # A roster line with no box yet is inventory drift, not a refusal:
                # `fleet.roster` is the TARGET fleet and deliberately names boxes
                # `crew up` has not created. `ok: None` keeps the box named in the
                # per-box detail while excluding it from the pass/fail verdict, so
                # the whole action does not read failed mid-migration (#77).
                tasks.append((done, ({"box": name, "ok": None, "out": "not created"},)))
                continue
            if (verb == "start") == (st == "stopped"):
                tasks.append((one, (name, ["box", verb, name])))
            else:
                tasks.append((done, ({"box": name, "ok": True,
                                      "out": "already %s" % st},)))
        results = concurrently(tasks)
    elif action == "wake-silent":
        # A silent box is one cron is not ticking for. Waking it means resuming
        # the crontab and, if it is stopped, starting it — not a model session.
        states = box_states()
        tasks = []
        for u in fleet.get()["units"]:
            if u["state"] != "offline":
                continue
            # A box that is disarmed WITHOUT being paused has no commented line
            # for RESUME_SH to restore, so waking it is not a thing this action
            # can do — arming is `crew hire`, on the host. It used to be sent
            # RESUME_SH anyway and reported as a failed row, which made
            # wake-silent read as broken on any fleet holding an unarmed box.
            #
            # The `not paused` half is load-bearing: pausing comments the line
            # out, so a paused box reports cron=0 and is disarmed too — and it
            # is exactly the box this action exists to wake.
            if u["disarmed"] and not u["paused"]:
                continue
            name = u["box"]
            # A wake of a PAUSED box is a resume, and the host's pause marker
            # is part of the pause (#759): left in place, the next host tick
            # would drain and stop the box this action just woke.
            if u["paused"]:
                _paused_marker(name, False)
            if states.get(name) == "stopped":
                # FIRST, and before the wedge question. Starting a stopped box
                # is a host operation that works whatever the guest was doing
                # when it went down, and a heartbeat left over from before it
                # stopped must not talk this action out of the one thing it can
                # certainly do.
                tasks.append((wake_start, (name,)))
            elif states.get(name) is None:
                # GONE FROM THE HOST, and that answer comes before the wedge
                # question rather than after it. `fleet.get()`'s units are a
                # snapshot up to a poll old while `states` is read fresh, so a
                # box that was wedged when the collector last looked and has
                # since left the host would otherwise draw an `escalate` row
                # naming a restart lever for a box there is nothing to restart.
                # Before this PR it drew no row at all, and no row is still the
                # right answer: this is inventory drift, not an incident (round
                # 1, claude-bot). The `stopped` arm stays FIRST — starting a
                # box the host does have is the one thing this action can
                # certainly do — and only absence overtakes the wedge.
                continue
            elif (u.get("ping") or {}).get("wedged"):
                # NOT A WAKE TARGET (#487 D3). RESUME_SH went to every box incus
                # did not call `stopped`, which includes the one state this tier
                # exists to name: up, wedged, and unable to execute anything. So
                # the wake was sent down the channel that is wedged, blocked for
                # the whole ACTION_TIMEOUT_S, and came back as a timed-out row
                # whose text described the symptom of a fact the collector had
                # already published.
                #
                # The collector's own verdict, read off the unit rather than
                # re-derived or re-asked: this box is IN the wake set because
                # `Fleet.get()` painted it offline on `wedged`, so routing it
                # out on any other reading of the same rule would be one rule
                # answered twice inside one action (#486). `ping` is absent for
                # a box the tier has not measured, and unmeasured is not wedged
                # — the same asymmetry `wedged()` states for a stale heartbeat.
                #
                # It is classified, never escalated in place: the force path
                # kills whatever the guest is doing, and #486 put that behind an
                # operator's authorisation — a fleet-wide button that force-
                # stopped guests on its own would be exactly the silent
                # escalation that ruling refuses. So the row names the lever and
                # the operator fires it.
                tasks.append((done, ({
                    "box": name, "ok": False, "step": "escalate",
                    "out": "wedged — not woken: `box exec` is not answering, so "
                           "there is no channel to resume its crontab through. "
                           "Restart it; the force path is the way in."},)))
            else:
                # A plain `else`: the absence question is asked once, above,
                # and asking it again here would leave two places that have to
                # agree about which boxes this action can reach.
                tasks.append((wake_resume, (name,)))
        results = concurrently(tasks)
    else:
        return 400, {"ok": False, "error": "unknown action %r" % action}

    # An action with nothing to do is not a failure: `wake-silent` on a fleet
    # with no silent boxes had `results == []`, which read as ok=False and 500.
    # Only `message`-class actions, which must produce a result, stay strict.
    # An action that did everything it COULD is not a failure either: a row with
    # `ok is None` (a not-yet-created box) is inventory drift, not a refusal, so
    # it is excluded from the verdict — 500 is reserved for a box that was there
    # and refused. All rows still travel in `results`, absent ones included.
    ok = all(r["ok"] for r in results if r["ok"] is not None)
    # A control action changes exactly what the page is displaying, so refresh
    # rather than leaving the operator to guess whether it took. Coalesced, so
    # a burst of clicks cannot become a burst of fleet-wide probe storms.
    fleet.request_refresh()
    return (200 if ok else 500), {"ok": ok, "action": action, "results": results}
