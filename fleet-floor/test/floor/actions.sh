# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/actions.sh — the suite for fleet-floor/server/floor/actions.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
#
# Subject: POST /api/command — every operator verb, what it reports when it
# had nothing to do, and the two races that put one operator's prompt in
# another's session.

echo "== control"
t "cmd: pause ok"     200 "$(status POST /api/command '{"action":"pause","box":"ff-working"}')"
t "cmd: pause applied" paused "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"
t "cmd: resume ok"    200 "$(status POST /api/command '{"action":"resume","box":"ff-working"}')"
t "cmd: resume applied" resumed "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"
# The verb says what it DID, so the console can tell a control that took effect
# from one that had nothing to do. Asserted on the per-box `out` the page and
# the drill both read, not on the status code alone — the status code is what
# was already wrong.
case "$(body POST /api/command '{"action":"pause","box":"ff-working"}')" in
  *"paused 1"*) ok "cmd: pause reports what it did" ;;
  *) fail "cmd: pause reports what it did" "$(body POST /api/command '{"action":"pause","box":"ff-working"}')" ;;
esac
status POST /api/command '{"action":"resume","box":"ff-working"}' >/dev/null

# #188 — a box with no armed tick.sh line has NOTHING to pause, and that is a
# success. It answered 500 "command refused", because PAUSE_SH ended on a
# `grep -c` and `grep -c` exits 1 on a zero count. Every drill box is in
# exactly this state by design (drill/rehearsal.sh disarms before any tick),
# which is why the whole control block on a real host was red.
t "cmd: pause on a disarmed box is not a refusal" 200 \
  "$(status POST /api/command '{"action":"pause","box":"ff-disarmed"}')"
case "$(body POST /api/command '{"action":"pause","box":"ff-disarmed"}')" in
  *"nothing to pause"*) ok "cmd: pause on a disarmed box says nothing to pause" ;;
  *) fail "cmd: pause on a disarmed box says nothing to pause" \
          "$(body POST /api/command '{"action":"pause","box":"ff-disarmed"}')" ;;
esac
# And it must not have invented a state change to report success with.
t "cmd: pause on a disarmed box changes nothing" "" \
  "$(cat "$FLOOR_STATE/ff-disarmed.cron" 2>/dev/null)"
# The same rule on the other verb: ff-working was resumed above, so there is no
# commented line left for RESUME_SH to restore.
t "cmd: resume with nothing paused is not a refusal" 200 \
  "$(status POST /api/command '{"action":"resume","box":"ff-working"}')"
case "$(body POST /api/command '{"action":"resume","box":"ff-working"}')" in
  *"nothing to resume"*) ok "cmd: resume with nothing paused says so" ;;
  *) fail "cmd: resume with nothing paused says so" \
          "$(body POST /api/command '{"action":"resume","box":"ff-working"}')" ;;
esac

t "cmd: power-off ok" 200 "$(status POST /api/command '{"action":"power-off","box":"ff-idle"}')"
t "cmd: power-off applied" stopped "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"
t "cmd: power-on ok"  200 "$(status POST /api/command '{"action":"power-on","box":"ff-idle"}')"
t "cmd: power-on applied" running "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"
t "cmd: restart ok"   200 "$(status POST /api/command '{"action":"restart","box":"ff-idle"}')"
t "cmd: restart ends running" running "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"

# ===========================================================================
# #486 — the one box state that needs stopping could not be stopped. `box
# down` is `incus stop` with no force and no timeout, so against a guest that
# cannot schedule its own shutdown every graceful verb runs out the floor's
# own ACTION_TIMEOUT_S and reports failure. stub-box's `wedged` arm now hangs
# on `down` the way that guest does, which is why these cases can exist at
# all: until it did, stopping always worked here.
#
# ff-wedged is borrowed and PUT BACK. A fixture row of its own is the tidier
# shape and test/cli.sh records why it is refused — three suites hardcode the
# fixture's box count and the browser scroll walk has been destabilised by
# fleet size before. So this block ends by restoring the box AND waiting for
# the console to call it unreachable again, because floor/ping.sh reads
# exactly that and reading it is not this suite's to break.
# ===========================================================================
# calls_since MARK — the stub's own call log from line MARK on. Every case
# below asks what the HOST was told to do, not what the reply said: "restart
# force-stops an unreachable box" is a claim about argv, and a 200 with a
# per-box `ok` is equally true of a graceful stop that happened to succeed.
fs_mark()        { wc -l < "$FLOOR_CALLS"; }
fs_calls_since() { tail -n "+$(( $1 + 1 ))" "$FLOOR_CALLS"; }

# #563 D1 — a shell program is one argv argument and may span many source
# lines, but it is still one stub invocation and therefore one call-log
# record. The mark/slice helpers below are meaningful only if that identity
# holds. The recognized `tail` probe isolates the recorder without mutating
# any fixture state, while exercising the real multi-line `box exec` shape.
echo "== atomic call log (#563)"
FS_CALLS_ACTUAL="$FLOOR_CALLS"
FS_STATE_ACTUAL="$FLOOR_STATE"
FLOOR_CALLS="$TMP/atomic-calls.log"
FLOOR_STATE="$TMP/atomic-state"
: > "$FLOOR_CALLS"
FS_RECORD_M=$(fs_mark)
# stub-box's exec arm drains stdin because the real transport forwards it.
# Keep this recorder-only probe detached from the suite's terminal stdin or it
# waits for EOF when the documented command is run interactively.
"$HERE/stub-box" exec ff-working -- bash -lc \
  $'\ntail -n 1 ~/duty/duty.log\nprintf done\n' </dev/null >/dev/null
t "calls: a multi-line argv advances the mark once" 1 \
  "$(( $(fs_mark) - FS_RECORD_M ))"
FS_RECORD="$(fs_calls_since "$FS_RECORD_M")"
t "calls: a multi-line argv is escaped into one record" \
  'exec ff-working -- bash -lc \ntail -n 1 ~/duty/duty.log\nprintf done\n' \
  "$FS_RECORD"

# The streaming encoder makes more than one write for a large record, so the
# lock is part of the record contract rather than an implementation detail.
# Pin the lock directly so its removal always reds; the concurrent behavior
# case beneath it then proves what the lock protects without depending on a
# scheduler race to turn a source mutation into corruption.
if grep -Fqx '  flock -x 9' "$HERE/stub-box"; then
  ok "calls: the streaming append holds its record lock"
else
  fail "calls: the streaming append holds its record lock" "flock -x 9 missing"
fi
FS_LONG_A=$'alpha-start\n'
FS_LONG_B=$'bravo-start\n'
for _ in $(seq 1 1500); do
  FS_LONG_A+=$'alpha-payload\n'
  FS_LONG_B+=$'bravo-payload\n'
done
"$HERE/stub-box" list "$FS_LONG_A" >/dev/null & FS_LONG_A_PID=$!
"$HERE/stub-box" list "$FS_LONG_B" >/dev/null & FS_LONG_B_PID=$!
wait "$FS_LONG_A_PID" "$FS_LONG_B_PID"
FS_LONG_A_RECORD="list ${FS_LONG_A//$'\n'/\\n}"
FS_LONG_B_RECORD="list ${FS_LONG_B//$'\n'/\\n}"
t "calls: concurrent large argv remain two records" 3 "$(fs_mark)"
if grep -Fqx "$FS_LONG_A_RECORD" "$FLOOR_CALLS" && \
   grep -Fqx "$FS_LONG_B_RECORD" "$FLOOR_CALLS"; then
  ok "calls: concurrent records keep their own complete argv"
else
  fail "calls: concurrent records keep their own complete argv" \
       "$(wc -l -c < "$FLOOR_CALLS")"
fi
FLOOR_CALLS="$FS_CALLS_ACTUAL"
FLOOR_STATE="$FS_STATE_ACTUAL"

echo "== force stop (#486)"

# The predicate the collector escalates on is the ping tier's wedge rule, so
# wait for the tier to have reached it rather than assuming the suites sourced
# before this one took long enough. Without this the whole block would pass or
# fail on how fast the machine is.
# This observation is not carried as the action verdict: the explicit `force`
# POST rechecks the live ping map and refuses on disagreement, so an expired
# display observation cannot select the wrong stop path.
FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')" != "True" ] \
      && [ "$(date +%s)" -lt "$FS_DL" ]; do sleep 1; done
t "force: the fixture's wedged box is unreachable to the collector" True \
  "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')"

# --- D3: restart on an UNREACHABLE box force-stops, then starts -------------
# MUST FAIL: the action timing out where force was available. A restart that
# still reached for `box down` here would hang the full action timeout and end
# with the box neither stopped nor started.
FS_M=$(fs_mark)
FS_T0=$(date +%s)
FS_R="$(api POST /api/command '{"action":"restart","box":"ff-wedged","mode":"force"}')"
FS_EL=$(( $(date +%s) - FS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: restart on an unreachable box succeeds" 200 "$(printf '%s' "$FS_R" | tail -1)"
# Anchored at the line start, because every line in $FLOOR_CALLS is one
# stub-box invocation's whole argv and an `exec` line carries a page-long
# script: an unanchored "incus " would eventually match somebody's comment.
# A here-string and not `printf | grep -q`, per #449 — this suite sets
# pipefail and grep -q exits on the first match, so the producer takes
# SIGPIPE and reds the assertion.
if grep -q '^incus ff-wedged -- stop --force$' <<<"$FS_SEEN"; then
  ok "force: restart fires the ruled passthrough"
else fail "force: restart fires the ruled passthrough" "$FS_SEEN"; fi
if grep -q '^down ff-wedged$' <<<"$FS_SEEN"; then
  fail "force: restart does not try the graceful stop first" "$FS_SEEN"
else ok "force: restart does not try the graceful stop first"; fi
if grep -q '^start ff-wedged$' <<<"$FS_SEEN"; then
  ok "force: restart starts the box afterwards"
else fail "force: restart starts the box afterwards" "$FS_SEEN"; fi
t "force: restart ends with the box running" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
if [ "$FS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "force: restart lands inside the action timeout"
else
  fail "force: restart lands inside the action timeout" "${FS_EL}s"
fi
# The record, not the outcome: which path a two-step lifecycle action took is
# the thing an operator reads afterwards, and "it worked" does not carry it.
t "force: the reply records which path it took" force-stop \
  "$(printf '%s' "$FS_R" | sed '$d' | jqf "d['results'][0].get('step','')")"

# --- D3, the other half: a REACHABLE box restarts exactly as before ---------
# MUST FAIL: force firing on a reachable box. Asserted on argv for the same
# reason as above — both paths end with the box running, so an outcome check
# cannot tell them apart.
FS_M=$(fs_mark)
t "force: restart on a reachable box succeeds" 200 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "force: a reachable box is never force-stopped" "$FS_SEEN"
else ok "force: a reachable box is never force-stopped"; fi
if grep -q '^down ff-idle$' <<<"$FS_SEEN"; then
  ok "force: a reachable box still gets the graceful stop"
else fail "force: a reachable box still gets the graceful stop" "$FS_SEEN"; fi
# Both halves of the restart, on both paths. The unreachable case asserts its
# `start` and this one did not — an asymmetry that would have let a graceful
# path which stopped the box and never started it pass here.
if grep -q '^start ff-idle$' <<<"$FS_SEEN"; then
  ok "force: a reachable box is started again afterwards"
else fail "force: a reachable box is started again afterwards" "$FS_SEEN"; fi

# --- D1/D4: the confirmed path and the executed path are ONE decision -------
# The round-1 fix put the wedge rule in one place and served it. That is still
# one rule evaluated at TWO TIMES: the page confirms from a fleet snapshot up
# to one poll old, and the collector re-reads the ping map when the POST
# lands. A box crossing the boundary in between let an operator confirm the
# gentle sentence over a host that then ran `stop --force` — D1's silent
# escalation through time-of-check/time-of-use rather than a duplicated
# constant, and no assertion in this suite could see it, because every case
# above posts and executes at the same instant.
#
# So the confirmed mode travels with the request and a disagreement REFUSES.
# The transition is driven here by posting the mode the OTHER path would have
# authorised — which is exactly what a stale page sends, and is the only way
# to hold the two verdicts apart in one process without sleeping through a
# poll interval and hoping.
#
# MUST FAIL, and it is the whole point of the block: a refusal that still
# touched the host. `409` alone is equally true of a collector that refused
# after stopping the box, so every case asks $FLOOR_CALLS what the host was
# told to do. Patterns are anchored per box rather than asserting the log is
# empty: the refusal asks for a fleet refresh on purpose, so the poller's own
# calls land in this window and an emptiness check would read them as fired.
echo "== restart mode (#486 round 2)"

# Both wedged preconditions below have a bounded lifetime. Wait for a fresh
# publication before issuing each request, otherwise a loaded runner can let
# the heartbeat become unmeasured before the command handler reads it.
read -r FS_PING_INTERVAL FS_PING_STALE_AFTER <<EOF
$(
  CREW_FLOOR_PING_INTERVAL="$FLOOR_TEST_PING_INTERVAL" \
  CREW_FLOOR_PING_TIMEOUT="$FLOOR_TEST_PING_TIMEOUT" \
  CREW_FLOOR_PING_FAILS="$FLOOR_TEST_PING_FAILS" \
  FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys
sys.path.insert(0, os.environ["FF_SERVER"])
from floor.ping import PING_INTERVAL_S, PING_STALE_AFTER_S
print(PING_INTERVAL_S, PING_STALE_AFTER_S)
PY
)
EOF
# A local POST normally takes milliseconds. Leave at least one complete ping
# scheduler interval plus one second, so an observation near an integer-second
# boundary cannot become stale before the command handler reads it.
FS_PING_REQUEST_MARGIN=$(( (FS_PING_INTERVAL > 2 ? FS_PING_INTERVAL : 2) + 1 ))
FS_PING_FRESH_MAX=$(( FS_PING_STALE_AFTER - FS_PING_REQUEST_MARGIN ))
if [ "$(( FS_PING_STALE_AFTER - FS_PING_FRESH_MAX ))" -ge 3 ] && \
   [ "$FS_PING_FRESH_MAX" -ge 1 ]; then
  ok "mode: the freshness guard leaves time for the request"
else
  fail "mode: the freshness guard leaves time for the request" \
       "margin=$(( FS_PING_STALE_AFTER - FS_PING_FRESH_MAX ))"
fi

# 1. A GENTLE confirmation over a box that has gone wedged. The destructive
#    direction: this is the one that must never authorise a kill.
# The force-restart case above stops and starts this fixture. A ping round that
# observed it while stopped legitimately removes its heartbeat, so establish
# the wedged precondition again here rather than borrowing the earlier wait.
FS_DL=$(( $(date +%s) + 60 ))
FS_PING_FRESH=False
FS_X=
FS_M=$(fs_mark)
while [ "$(date +%s)" -lt "$FS_DL" ]; do
  FS_PING_FRESH="$(uf ff-wedged "u[\"ping\"][\"wedged\"] and u[\"ping\"][\"age\"] <= $FS_PING_FRESH_MAX")"
  if [ "$FS_PING_FRESH" = "True" ]; then
    FS_M=$(fs_mark)
    FS_X="$(api POST /api/command '{"action":"restart","box":"ff-wedged","mode":"graceful"}')"
    break
  fi
  sleep 0.25
done
t "mode: the fixture is wedged again after force restart" True "$FS_PING_FRESH"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "mode: a graceful confirmation over a wedged box is refused" 409 \
  "$(printf '%s' "$FS_X" | tail -1)"
t "mode: ...and says which way the box moved" force \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('verdict','')")"
t "mode: ...and what was confirmed against it" graceful \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('confirmed','')")"
# REFUSED is not FAILED: the page renders them differently because nothing ran.
t "mode: ...and marks itself refused rather than failed" True \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('refused',False)")"
case "$FS_X" in
  *"confirm again"*) ok "mode: ...and tells the operator what to do next" ;;
  *) fail "mode: ...and tells the operator what to do next" "$FS_X" ;;
esac
if grep -qE '^(down|start) ff-wedged$|^incus ff-wedged ' <<<"$FS_SEEN"; then
  fail "mode: a refused restart fires NOTHING at the host" "$FS_SEEN"
else ok "mode: a refused restart fires NOTHING at the host"; fi
t "mode: ...and the box is left exactly as it was" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

# 2. The same rule the other way. Harmless in outcome — a gentler path than
#    the operator authorised — but an operator told "any running session is
#    lost" who got something else still met a console that does not do what it
#    says, and one predicate with two behaviours is what this issue is about.
FS_M=$(fs_mark)
FS_X="$(api POST /api/command '{"action":"restart","box":"ff-idle","mode":"force"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "mode: a force confirmation over a box that answers is refused too" 409 \
  "$(printf '%s' "$FS_X" | tail -1)"
t "mode: ...naming the verdict that now holds" graceful \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('verdict','')")"
if grep -qE '^(down|start) ff-idle$|^incus ff-idle ' <<<"$FS_SEEN"; then
  fail "mode: the harmless direction fires nothing either" "$FS_SEEN"
else ok "mode: the harmless direction fires nothing either"; fi

# 3. A request that names NO mode means graceful — a bare restart's meaning
#    before this issue existed. So the old request shape keeps its old
#    semantics and cannot become a kill by arriving at the wrong moment: the
#    escalation is reachable only from a client that showed a human the word.
FS_DL=$(( $(date +%s) + 60 ))
FS_PING_FRESH=False
FS_NO_MODE_STATUS=
FS_M=$(fs_mark)
while [ "$(date +%s)" -lt "$FS_DL" ]; do
  FS_PING_FRESH="$(uf ff-wedged "u[\"ping\"][\"wedged\"] and u[\"ping\"][\"age\"] <= $FS_PING_FRESH_MAX")"
  if [ "$FS_PING_FRESH" = "True" ]; then
    FS_M=$(fs_mark)
    FS_NO_MODE_STATUS="$(status POST /api/command '{"action":"restart","box":"ff-wedged"}')"
    break
  fi
  sleep 0.25
done
t "mode: the no-mode check starts from a fresh wedged verdict" True "$FS_PING_FRESH"
t "mode: a restart naming no mode never escalates" 409 \
  "$FS_NO_MODE_STATUS"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^incus ff-wedged ' <<<"$FS_SEEN"; then
  fail "mode: ...and did not kill the guest on the way" "$FS_SEEN"
else ok "mode: ...and did not kill the guest on the way"; fi
t "mode: an unknown mode is refused as a bad request" 400 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle","mode":"kill"}')"

# 4. Agreement still executes, on both paths, with the argv unchanged. Without
#    these the block above is satisfied by a collector that refuses everything.
FS_M=$(fs_mark)
t "mode: an agreeing graceful confirmation still restarts" 200 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle","mode":"graceful"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^down ff-idle$' <<<"$FS_SEEN" && grep -q '^start ff-idle$' <<<"$FS_SEEN"; then
  ok "mode: ...with today's argv, both halves"
else fail "mode: ...with today's argv, both halves" "$FS_SEEN"; fi
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "mode: ...and no escalation on the agreeing gentle path" "$FS_SEEN"
else ok "mode: ...and no escalation on the agreeing gentle path"; fi

# --- D1: a graceful stop never escalates on its own -------------------------
# MUST FAIL: a graceful stop silently succeeding against the hanging arm. This
# is the case the old stub could not express — `down` always wrote `stopped`
# and answered 0, so the floor reported success for a box it had not stopped.
FS_M=$(fs_mark)
FS_OFF="$(api POST /api/command '{"action":"power-off","box":"ff-wedged"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: a graceful stop against a wedged guest is reported failed" 500 \
  "$(printf '%s' "$FS_OFF" | tail -1)"
case "$FS_OFF" in
  *"timed out"*) ok "force: ...and the failure names the timeout" ;;
  *) fail "force: ...and the failure names the timeout" "$FS_OFF" ;;
esac
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "force: a graceful stop never escalates to force" "$FS_SEEN"
else ok "force: a graceful stop never escalates to force"; fi
t "force: a hung stop does not claim the box stopped" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

# --- D1/D2: force-stop is its own verb, and it works -----------------------
FS_M=$(fs_mark)
FS_T0=$(date +%s)
FS_F="$(api POST /api/command '{"action":"force-stop","box":"ff-wedged"}')"
FS_EL=$(( $(date +%s) - FS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: force-stop succeeds where the graceful stop hung" 200 \
  "$(printf '%s' "$FS_F" | tail -1)"
t "force: the wedged guest is actually stopped" stopped \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
if grep -q '^incus ff-wedged -- stop --force$' <<<"$FS_SEEN"; then
  ok "force: it fires exactly the ruled command"
else fail "force: it fires exactly the ruled command" "$FS_SEEN"; fi
if [ "$FS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "force: a wedged box is stopped inside the action timeout"
else
  fail "force: a wedged box is stopped inside the action timeout" "${FS_EL}s"
fi
t "force: force-stop records its path too" force-stop \
  "$(printf '%s' "$FS_F" | sed '$d' | jqf "d['results'][0].get('step','')")"
t "force: an unknown box is still refused" 400 \
  "$(status POST /api/command '{"action":"force-stop","box":"nope"}')"

# The stub's refusal, driven directly. Every argv assertion above leans on the
# unmatched arm — "it fires exactly the ruled passthrough and not a near
# neighbour" is only true because anything else exits 2.
#
# `incus ff-idle stop stop --force` is the argv that makes the point, and it
# is chosen rather than any old malformed call: an arm that shifted three
# without checking WHERE the separator is reads this as `stop --force` and
# quietly force-stops the box, so the case that is supposed to be refused
# succeeds instead. A shorter malformed call exits 2 under both spellings and
# would assert nothing. Both the log and the state dir are pointed elsewhere,
# so a probe that IS silently reinterpreted cannot mutate the fleet the cases
# above read.
FS_PROBE_ENV=(FLOOR_CALLS=/dev/null FLOOR_STATE="$TMP/stub-probe")
if env "${FS_PROBE_ENV[@]}" "$HERE/stub-box" incus ff-idle stop stop --force >/dev/null 2>&1; then
  fail "force: the stub refuses a passthrough with the separator misplaced" \
       "shifted past it blind and reinterpreted the call as the ruled one"
else
  ok "force: the stub refuses a passthrough with the separator misplaced"
fi
t "force: ...and did not stop the box on the way" "" \
  "$(cat "$TMP/stub-probe/ff-idle.state" 2>/dev/null)"
if env "${FS_PROBE_ENV[@]}" "$HERE/stub-box" incus ff-idle -- restart >/dev/null 2>&1; then
  fail "force: the stub refuses an incus verb it does not model" "exit 0"
else
  ok "force: the stub refuses an incus verb it does not model"
fi

# ===========================================================================
# #487 D2/D4 — `restart` appended its stop result and never read it, so a stop
# that failed was followed by `box start` on the next line and the box was
# started anyway.
#
# Two cases, because reading the stop makes the stop's OTHER answer matter
# too. Round 1, claude-bot: `box down` is not idempotent on the single-box
# path — heavy-duty/box registers it `incus:stop` and runs `incus stop <inst>`
# bare, and the `stop:STOPPED -> ""` guard is reached only by `box down all` —
# so a stopped box answers the verb with an error, and a conditional start
# swallowed a restart that used to work. "Nothing to stop" and "the stop
# failed" are ranked apart, and both are asserted here.
#
# The block above left ff-wedged stopped, which is the first case exactly.
# ===========================================================================
echo "== restart reads its own stop (#487)"

# Unlike a wedged=True classification, this absence does not age out. The ping
# loop omits a stopped box until the POST below starts it again, so None stays
# the current fact throughout this wait and assertion.
FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["ping"]')" != "None" ] && [ "$(date +%s)" -lt "$FS_DL" ]; do
  sleep 1
done
t "stop: the stopped box's heartbeat is dropped, not left stale" None \
  "$(uf ff-wedged 'u["ping"]')"
t "stop: ...so the collector's verdict is the graceful path" stopped \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

# --- NOTHING TO STOP IS NOT A FAILED STOP -----------------------------------
# MUST FAIL: `down` in the call log, or the box still stopped afterwards. The
# status code is not where this is asserted either way — the pre-#487 code
# fired a failing `down` here and started the box anyway, so 200 was already
# true of the behaviour this replaces.
FS_M=$(fs_mark)
FS_AR="$(api POST /api/command '{"action":"restart","box":"ff-wedged"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "stop: a restart on a stopped box is not a refusal" 200 \
  "$(printf '%s' "$FS_AR" | tail -1)"
if grep -q '^down ff-wedged$' <<<"$FS_SEEN"; then
  fail "stop: the verb is not fired at a box already stopped" "$FS_SEEN"
else ok "stop: the verb is not fired at a box already stopped"; fi
if grep -q '^start ff-wedged$' <<<"$FS_SEEN"; then
  ok "stop: ...and the box is started, which is what was asked for"
else fail "stop: ...and the box is started, which is what was asked for" "$FS_SEEN"; fi
t "stop: ...ending running, as the confirm dialog promised" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
# Reported, not silently dropped: both steps are still in the reply, and the
# stop row says which of its two answers this was.
t "stop: the reply still records the stop step" down \
  "$(printf '%s' "$FS_AR" | sed '$d' | jqf "d['results'][0].get('step','')")"
t "stop: ...as the success that having nothing to do is (#77)" True \
  "$(printf '%s' "$FS_AR" | sed '$d' | jqf "d['results'][0]['ok']")"
t "stop: ...naming why it did not run" "already stopped" \
  "$(printf '%s' "$FS_AR" | sed '$d' | jqf "d['results'][0]['out']")"

# --- ...AND A STOP THAT REALLY FAILED STOPS THE START -----------------------
# ff-absent, because that shortcut closed the route this case used to take.
# It drove the failure through ff-wedged while it was stopped, which is now the
# case above; and the other two shapes are unreachable here — a wedged box is
# stopped by the FORCE branch, and every other fixture box stops cleanly.
# ff-absent is the roster line the host has no instance for, and `box down`
# against one errors exactly as the stub's `info` arm has always said it does.
# Nothing about the box changes, which is why this case can sit in a suite
# whose collector is shared: no state file is written, no heartbeat moves, and
# the reachability alert ledger the alerts module counts never sees an edge.
#
# The CAUSE is not the point and is not asserted — a host that refuses the stop
# and one that runs out the action timeout produce the same `ok: False`, and
# test/concurrent-actions.py drives the timeout flavour (rc 124) deterministically
# on both stop paths. What is under test is that the start is conditioned on
# that row.
#
# MUST FAIL: `box start` appearing in the call log. The reply is not where this
# is asserted — "restart reported a failure" is equally true of a restart that
# failed, started the box anyway and mentioned the stop afterwards, which is
# the defect exactly.
FS_M=$(fs_mark)
FS_RR="$(api POST /api/command '{"action":"restart","box":"ff-absent"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "stop: a restart whose stop failed is reported failed" 500 \
  "$(printf '%s' "$FS_RR" | tail -1)"
if grep -q '^down ff-absent$' <<<"$FS_SEEN"; then
  ok "stop: the graceful stop was attempted"
else fail "stop: the graceful stop was attempted" "$FS_SEEN"; fi
if grep -q '^start ff-absent$' <<<"$FS_SEEN"; then
  fail "stop: a failed stop does not start the box" "$FS_SEEN"
else ok "stop: a failed stop does not start the box"; fi
# The box the host does not have is still the box the host does not have: a
# lever that could not act left no trace of having acted.
t "stop: ...and nothing was written for a box the host has not got" "" \
  "$(cat "$FLOOR_STATE/ff-absent.state" 2>/dev/null)"
# The record, not just the outcome: a start that did not run is a third state
# beside ran-and-worked and ran-and-failed, and the reply says which (#487 D4).
t "stop: the reply records the start that never ran" start \
  "$(printf '%s' "$FS_RR" | sed '$d' | jqf "d['results'][1].get('step','')")"
t "stop: ...as not-attempted rather than as a second failure" None \
  "$(printf '%s' "$FS_RR" | sed '$d' | jqf "d['results'][1]['ok']")"
case "$FS_RR" in
  *"not started"*) ok "stop: ...and says so in words the page renders" ;;
  *) fail "stop: ...and says so in words the page renders" "$FS_RR" ;;
esac
# AND CLAIMS NOTHING BEYOND IT. This row used to end "so the box was left as it
# was", which a timed-out graceful stop cannot establish: it has ASKED for a
# shutdown that may still be in flight, so the guest's state is precisely the
# unknown here (round 1, codex-bot and claude-bot). Asserted as an absence,
# because every positive assertion above survives the claim being re-added.
case "$FS_RR" in
  *"left as it was"*) fail "stop: ...and claims nothing about the guest" "$FS_RR" ;;
  *) ok "stop: ...and claims nothing about the guest" ;;
esac

# Put ff-wedged back the way this suite found it, and prove it is back. The
# already-stopped case above started it, so this is now belt and braces rather
# than the restore it used to be — kept because the block's own restore must
# not depend on which of its cases last touched the box. The ping tier skips a
# stopped box, so leaving it down would empty its heartbeat and floor/ping.sh —
# which waits on exactly that fact — would spend its timeout and then fail for
# a reason nobody would trace to this block.
status POST /api/command '{"action":"power-on","box":"ff-wedged"}' >/dev/null
# This is a terminal restoration check, not an observation carried into a
# later action. No request depends on the note after the assertion reads it.
FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')" != "True" ] \
      && [ "$(date +%s)" -lt "$FS_DL" ]; do sleep 1; done
t "force: the fixture box is restored for the suites that read it" True \
  "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')"

# The prompt must reach the box as stdin bytes, never as part of a command
# line. This is the one that must never regress.
# The payload goes to python through the ENVIRONMENT, never through a
# double-quoted bash string: interpolating it would let bash expand $(id) and
# the backticks here, and the test would then be sending something tamer than
# it claims to.
# The quotes and backticks are the POINT: this must stay a literal payload all
# the way into the box, so bash must not expand or re-quote any of it here.
# shellcheck disable=SC2016,SC2089,SC2090
INJECT='hi"; touch /tmp/floor-pwned; echo "$(id)`whoami`'
# shellcheck disable=SC2090
export INJECT
status POST /api/command "$(python3 -c 'import json,os
print(json.dumps({"action":"message","box":"ff-working","prompt":os.environ["INJECT"]}))')" >/dev/null
if [ -e /tmp/floor-pwned ]; then fail "message: prompt cannot inject" "/tmp/floor-pwned was created"; rm -f /tmp/floor-pwned
else ok "message: prompt cannot inject"; fi
if grep -q 'floor-pwned' "$FLOOR_CALLS"; then fail "message: prompt never in argv" "found in call log"
else ok "message: prompt never in argv"; fi
t "message: envelope and prompt delivered via stdin" \
  "$(cat "$FLOOR/../shared/prompts/fragment-floor-envelope.txt")
$INJECT" \
  "$(cat "$FLOOR_STATE/ff-working.prompt" 2>/dev/null)"

# #537 — hop 2 receives the same four configuration layers `load_conf` would
# source. The stub preserves the bytes it actually received; this is not an
# assertion over a helper's proposed output.
OP_CONF="$(find "$FLOOR_STATE" -name 'ff-working.message-conf.*' -print -quit)"
if awk '
  /^TIMEOUT_ATTENTION=/{d=NR}
  /^FLEET_HUMAN=fixture$/{f=NR}
  /^BOT_CLI_CMD=/{a=NR}
  /^TIMEOUT_BUILD=/{r=NR}
  END {exit !(d && f && a && r && d<f && f<a && a<r)}
' "$OP_CONF"; then
  ok "message: stdin carries defaults, fleet, agent, role in order"
else
  fail "message: stdin carries defaults, fleet, agent, role in order" \
       "$(grep -nE '^(TIMEOUT_ATTENTION|FLEET_HUMAN|BOT_CLI_CMD|TIMEOUT_BUILD)=' "$OP_CONF")"
fi
t "message: builder default is its longest layered session timeout" 3600 \
  "$(sed -n 's/.* timeout=\([0-9]*\)s .*/\1/p' "$FLOOR_STATE/ff-working.home/duty/duty.log" | tail -1)"
FF_MESSAGE_TIMEOUT_SOURCE="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["FF_SERVER"])
from floor.actions import MESSAGE_SH
print("literal=%s" % ("1800" in MESSAGE_SH))
print("record=%s" % ('timeout=%ss' in MESSAGE_SH and '"$operator_timeout" "$slog"' in MESSAGE_SH))
print("wall=%s" % ('timeout -k 60 "$operator_timeout"' in MESSAGE_SH))
PY
)"
t "message: MESSAGE_SH carries no literal 1800 timeout" False \
  "$(sed -n 's/^literal=//p' <<<"$FF_MESSAGE_TIMEOUT_SOURCE")"
t "message: the start record uses operator_timeout" True \
  "$(sed -n 's/^record=//p' <<<"$FF_MESSAGE_TIMEOUT_SOURCE")"
t "message: the enforced wall uses operator_timeout" True \
  "$(sed -n 's/^wall=//p' <<<"$FF_MESSAGE_TIMEOUT_SOURCE")"
if FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["FF_SERVER"])
from floor.actions import MESSAGE_SH
raise SystemExit(0 if "MARK_" not in MESSAGE_SH else 1)
PY
then
  ok "message: box-side script consumes no MARK_ variable"
else
  fail "message: box-side script consumes no MARK_ variable" "MARK_ found in MESSAGE_SH"
fi

t "cmd: unknown box refused"    400 "$(status POST /api/command '{"action":"pause","box":"nope"}')"
t "cmd: unknown action refused" 400 "$(status POST /api/command '{"action":"rm -rf","box":"ff-working"}')"
t "cmd: empty prompt refused"   400 "$(status POST /api/command '{"action":"message","box":"ff-working","prompt":"   "}')"
t "cmd: bad json refused"       400 "$(status POST /api/command '{oops')"
# A control aimed at a box that cannot run it must be REPORTED, not swallowed.
t "cmd: unreachable box -> 500"  500 "$(status POST /api/command '{"action":"pause","box":"ff-unreach"}')"
case "$(body POST /api/command '{"action":"pause","box":"ff-unreach"}')" in
  *"not running"*) ok "cmd: failure carries the reason" ;;
  *) fail "cmd: failure carries the reason" "$(body POST /api/command '{"action":"pause","box":"ff-unreach"}')" ;;
esac

# `wake-silent` on a fleet with nothing silent must not read as a failure.
# Wake everything first, so the second call genuinely has nothing to do.
status POST /api/command '{"action":"start-all"}' >/dev/null
WS_BODY="$(body POST /api/command '{"action":"wake-silent"}')"
WS_CODE="$(status POST /api/command '{"action":"wake-silent"}')"
if [ "$WS_CODE" = "200" ] || grep -q '"results"' <<<"$WS_BODY"; then
  ok "wake-silent always reports per-box results"
else
  fail "wake-silent always reports per-box results" "$WS_CODE $WS_BODY"
fi

# #189 — wake-silent must not try to wake a box it CANNOT wake. A disarmed box
# has no commented crontab line for RESUME_SH to restore, so the call did
# nothing and then reported a failed row, because `grep -c` exits 1 on a zero
# count (#188). Arming is `crew hire`, on the host — not a console action.
#
# The `not paused` half of the guard is the load-bearing half: pausing zeroes
# the cron count too, so a paused box is disarmed, and it is exactly the box
# this action exists to wake. Guard on `disarmed` alone and wake-silent stops
# doing the one thing it is for.
rm -f "$FLOOR_STATE/ff-disarmed.cron" "$FLOOR_STATE/ff-paused.cron"
status POST /api/command '{"action":"pause","box":"ff-paused"}' >/dev/null
# request_refresh polls in a BACKGROUND thread, so the snapshot wake-silent
# reads is NOT updated by the time the pause call returns — and wake-silent
# decides entirely from that snapshot. Wait for the fact to arrive rather than
# sleeping a guessed interval; the test server polls on a 3600s cycle, so a
# guess would have to be luck.
for _ in $(seq 1 60); do
  [ "$(uf ff-paused "u['paused']")" = "True" ] && break
  sleep 0.5
done
FS_M=$(fs_mark)
WS_T0=$(date +%s)
WS_R="$(api POST /api/command '{"action":"wake-silent"}')"
WS_EL=$(( $(date +%s) - WS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "wake-silent: resumes a PAUSED box"   resumed "$(cat "$FLOOR_STATE/ff-paused.cron" 2>/dev/null)"
# ...and lifts the host's pause marker with it (#763 re-review): left there,
# the next host tick drained and stopped the box this action just woke.
t "wake-silent: lifts the host's pause marker" absent \
  "$([ -e "$CREW_CONFIG_DIR/store/paused/ff-paused" ] && echo present || echo absent)"
t "wake-silent: leaves a DISARMED box alone" "" "$(cat "$FLOOR_STATE/ff-disarmed.cron" 2>/dev/null)"

# #487 D3/D4 — the wake went to every box incus did not call `stopped`, which
# includes the wedged one: RESUME_SH down a channel that cannot execute
# anything, blocking the whole ACTION_TIMEOUT_S to report a timeout for a fact
# the collector had already published as ping.wedged.
#
# MUST FAIL: the wake's own `exec` at ff-wedged in the call log. Asserted on
# argv, because a failed row for that box is what the OLD behaviour produced
# too — the difference is entirely in whether the wake was sent.
#
# THE WAKE'S OWN, not any exec at that box. $FLOOR_CALLS is shared by every
# tier: the ping tier probes the same box with `-- sh -c PING_SH` on its own
# 10s timer (floor/ping.py), and a `^exec ff-wedged ` prefix matches that
# probe exactly as well as a resume. Round 1, codex-bot: this assertion red on
# a heartbeat that happened to land inside the window, in a required suite —
# which makes whether it passes a question about background timing rather than
# about the code. So the resume is identified by its OWN argv.
#
# stub-box logs one invocation per line, escaping each newline in the argv as
# the two literal bytes `\n`. A resume's record therefore starts with
# `exec <box> -- bash -lc \n` followed immediately by RESUME_SH's first line.
# Both are matched, because the argv prefix alone is shared with any other
# bash -lc script that starts with a newline.
# The needle is a LITERAL: it is a line of RESUME_SH as the stub logged it, so
# nothing in it may be expanded here.
# shellcheck disable=SC2016
RESUME_BODY_HEAD='cron="$(crontab -l 2>/dev/null || true)"'
ws_resumed() {  # ws_resumed BOX — was RESUME_SH fired into BOX, in $FS_SEEN?
  awk -v head="exec $1 -- bash -lc " -v body="$RESUME_BODY_HEAD" '
    index($0, head "\\n" body) == 1 { found = 1 }
    END        { exit found ? 0 : 1 }
  ' <<<"$FS_SEEN"
}
if ws_resumed ff-wedged; then
  fail "wake-silent: a wedged box is not sent a wake" "$FS_SEEN"
else ok "wake-silent: a wedged box is not sent a wake"; fi
# THE POSITIVE, through the same needle, and it is not decoration: a needle
# that precise rots into a silent PASS if RESUME_SH's opening moves, and the
# case above would go quiet rather than red. ff-paused is woken by this very
# call — asserted on its crontab above — so if ws_resumed cannot see that, the
# needle is stale and this is the assertion that says so.
if ws_resumed ff-paused; then
  ok "wake-silent: ...and the needle above can see a wake that WAS sent"
else fail "wake-silent: ...and the needle above can see a wake that WAS sent" "$FS_SEEN"; fi

# D3's race is deterministic here: another complete invocation may land
# between two resume records, but it cannot land inside either one. The
# negative half must therefore see a wedged-box resume wherever its atomic
# record falls; otherwise it would silently claim no wake was sent.
FS_INTERLEAVED="exec ff-paused -- bash -lc \\n$RESUME_BODY_HEAD\\npaused body
list --json
exec ff-wedged -- bash -lc \\n$RESUME_BODY_HEAD\\nwedged body"
FS_ACTUAL="$FS_SEEN"
FS_SEEN="$FS_INTERLEAVED"
if ws_resumed ff-wedged; then
  ok "wake-silent: concurrent record order cannot hide a sent wake"
else
  fail "wake-silent: concurrent record order cannot hide a sent wake" "$FS_SEEN"
fi

# The body head remains load-bearing precision. A header-only matcher would
# stay green under this mutation and could confuse RESUME_SH with any other
# multi-line bash program sent to the same box.
RESUME_BODY_ACTUAL="$RESUME_BODY_HEAD"
RESUME_BODY_HEAD='not the opening line of RESUME_SH'
if ws_resumed ff-wedged; then
  fail "wake-silent: the resume body head remains load-bearing" "$FS_SEEN"
else
  ok "wake-silent: the resume body head remains load-bearing"
fi
RESUME_BODY_HEAD="$RESUME_BODY_ACTUAL"
FS_SEEN="$FS_ACTUAL"
# It is REPORTED, not skipped. A disarmed box drops out of the wake set with no
# row at all (#189) because nothing is wrong with it; a wedged one is the
# incident this console exists to surface, so it carries a row that names the
# lever that can still reach it.
ws_field() {  # ws_field KEY — one field of ff-wedged's row in the reply above
  printf '%s' "$WS_R" | sed '$d' | jqf \
    "[r for r in d['results'] if r['box']=='ff-wedged'][0].get('$1','')"
}
t "wake-silent: ...it is escalated rather than dropped" escalate "$(ws_field step)"
t "wake-silent: ...and a box it could not wake is not a success" False "$(ws_field ok)"
case "$(ws_field out)" in
  *"Restart it"*) ok "wake-silent: ...naming the lever that can still reach it" ;;
  *) fail "wake-silent: ...naming the lever that can still reach it" "$(ws_field out)" ;;
esac
# The cost, which is the half an operator feels: two unreachable boxes in this
# fixture each spent a full action timeout before this change.
if [ "$WS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "wake-silent: a wedged box costs no action timeout"
else
  fail "wake-silent: a wedged box costs no action timeout" "${WS_EL}s"
fi

# ===========================================================================
# ROUND 11 — codex-bot: two rapid messages to ONE box could interleave, and a
# session would run the OTHER request's prompt. Production bug, not a test
# one. The earlier concurrency case sent only `pause`, and the box-side test
# sent one message at a time, so neither could reach it.
# ===========================================================================
echo "== concurrent messages keep their own bytes"
# Isolate this round: an earlier sequential message test left its own prompt
# file and log behind, which is why an aggregate count once read 6-for-5.
CM_HOME="$FLOOR_STATE/ff-working.home"
rm -f "$FLOOR_STATE"/ff-working.prompt.* 2>/dev/null
rm -f "$CM_HOME"/duty/logs/*operator-floor* 2>/dev/null

CM_OUT="$(python3 - <<'PY_CM'
import base64, json, os, threading, urllib.request, urllib.error
port, user, pw = os.environ["PORT"], os.environ["USER"], os.environ["PASSWD"]
auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
# Distinct, individually identifiable payloads to the SAME box at once.
prompts = [f"PROMPT-{i}-" + ("x" * (20 + i)) for i in range(5)]
codes = []
lock = threading.Lock()

def hit(p):
    body = json.dumps({"action": "message", "box": "ff-working", "prompt": p}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/command", data=body, method="POST")
    req.add_header("Authorization", auth)
    req.add_header("Content-Type", "application/json")
    try:
        c = urllib.request.urlopen(req, timeout=60).status
    except urllib.error.HTTPError as e:
        c = e.code
    except Exception:
        c = 0
    with lock:
        codes.append(c)

ts = [threading.Thread(target=hit, args=(p,)) for p in prompts]
[t.start() for t in ts]
[t.join(90) for t in ts]
print(sum(1 for c in codes if c == 200))
PY_CM
)"
t "5 concurrent messages all accepted" 5 "$CM_OUT"

# Wait for the detached sessions to land their logs.
for _ in $(seq 1 40); do
  [ "$(find "$CM_HOME/duty/logs" -name '*operator-floor*' 2>/dev/null | wc -l)" -ge 5 ] && break
  sleep 0.5
done

# EXACTLY five, not "at least": a stray log means the population under test is
# not the one this case created.
CM_LOGS=$(find "$CM_HOME/duty/logs" -name '*operator-floor*' 2>/dev/null | wc -l)
t "exactly five session logs" 5 "$CM_LOGS"

CM_STAGED=0
for f in "$FLOOR_STATE"/ff-working.prompt.*; do
  case "$f" in *'*') continue ;; esac
  [ -f "$f" ] && CM_STAGED=$((CM_STAGED + 1))
done
t "each message staged its own prompt file" 5 "$CM_STAGED"

# The decisive check, PER TOKEN. Comparing the SET of prompts staged against
# the SET delivered is not the property claimed: if session A runs B's prompt
# and B runs A's — the exact cross-request swap this case exists for — the two
# sets are identical and every aggregate assertion passes. Correlate instead:
# each staged token must have exactly one log bearing THAT token, carrying
# THAT token's bytes.
CM_BAD=""
for f in "$FLOOR_STATE"/ff-working.prompt.*; do
  case "$f" in *'*') continue ;; esac
  [ -f "$f" ] || continue
  _tok="${f##*.}"
  _staged="$(cat "$f")"
  _n=$(find "$CM_HOME/duty/logs" -name "*operator-floor-$_tok.log" 2>/dev/null | wc -l)
  if [ "$_n" -ne 1 ]; then
    CM_BAD="$CM_BAD token=$_tok:logs=$_n"
    continue
  fi
  _log=$(find "$CM_HOME/duty/logs" -name "*operator-floor-$_tok.log" 2>/dev/null | head -1)
  _got="$(sed '1s/^PROMPT=\[//; $s/]$//' "$_log")"
  [ "$_got" = "$_staged" ] || CM_BAD="$CM_BAD token=$_tok:staged[$_staged]!=delivered[$_got]"
done
if [ -z "$CM_BAD" ] && [ "$CM_STAGED" -eq 5 ]; then
  ok "each token's session ran exactly that token's prompt (1:1)"
else
  fail "each token's session ran exactly that token's prompt (1:1)" "${CM_BAD:-no tokens staged}"
fi
