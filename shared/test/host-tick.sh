#!/usr/bin/env bash
# shared/test/host-tick.sh — the host's wake decision (#759), offline: the
# board and the store are fixtures behind wake_gh and wake_store, so every
# rule — reasons by role, the three vetoes, the why token, the digest — is
# driven with no network, no box and no host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=shared/lib/host/wake.sh
source "$ROOT/shared/lib/host/wake.sh"

# --- the board as rows, through a gh that answers fixtures -----------------
HT_GH_LOG="$TMP/gh.log"
wake_gh() {
  printf '%s\n' "$*" | tr '\n' ' ' >>"$HT_GH_LOG"; echo >>"$HT_GH_LOG"
  [ "${HT_GH_FAIL:-}" != "$1" ] || return 1
  case "$1" in
    issue) printf 'I 12 2026-10-23T10:00:00Z ready -\nI 13 2026-10-23T09:00:00Z attention,ready dan-claude-bot\nI 14 2026-10-23T08:00:00Z needs-triage -\n' ;;
    pr)    printf 'P 20 2026-10-23T11:00:00Z dan-claude-bot 0 codex-bot\nP 21 2026-10-23T07:00:00Z someone 1 dan-claude-bot\n' ;;
    api)   printf 'D 5 2026-10-23T06:00:00Z\n' ;;
  esac
}
rows="$(wake_board_rows o/r)"; rows_rc=$?
t board-rows-join-the-three-reads 6 "$(printf '%s\n' "$rows" | grep -c .)"
t board-rows-read-rc 0 "$rows_rc"
t board-reads-issues-prs-and-discussions-once-each "1 1 1" \
  "$(printf '%s %s %s' "$(grep -c '^issue list' "$HT_GH_LOG")" "$(grep -c '^pr list' "$HT_GH_LOG")" "$(grep -c '^api graphql' "$HT_GH_LOG")")"
HT_GH_FAIL='pr'; failed_rows="$(wake_board_rows o/r)"; failed_rc=$?; unset HT_GH_FAIL
t board-an-unreadable-read-yields-nothing "" "$failed_rows"
t board-an-unreadable-read-is-1 1 "$failed_rc"
d1="$(printf '%s\n' "$rows" | wake_digest)"; d2="$(printf '%s\n' "$rows" | wake_digest)"
d3="$(printf '%s\nI 99 2026-10-23T12:00:00Z ready -\n' "$rows" | wake_digest)"
t digest-is-stable "$d1" "$d2"
t digest-moves-with-the-board 0 "$([ "$d1" = "$d3" ] && echo 1 || echo 0)"

# --- reasons by role --------------------------------------------------------
reasons_of() { wake_reasons "$1" "$2" o/r "$rows" | sort | paste -sd'|' -; }
t reasons-builder-sees-the-unassigned-ready-issue-and-its-own-pr \
  "attention#o/r#13 2026-10-23T09:00:00Z|pr#o/r#20 2026-10-23T11:00:00Z|ready#o/r#12 2026-10-23T10:00:00Z" \
  "$(reasons_of builder dan-claude-bot)"
t reasons-reviewer-sees-the-request-and-the-attention "attention#o/r#13 2026-10-23T09:00:00Z|review#o/r#21 2026-10-23T07:00:00Z" \
  "$(reasons_of reviewer dan-claude-bot)"
t reasons-triage-sees-the-whole-board "board#o/r -" "$(reasons_of triage nobody)"
t reasons-an-assigned-ready-issue-is-not-ready-work 0 "$(reasons_of builder other | grep -c 'ready#o/r#13')"
t reasons-no-login-no-personal-work "ready#o/r#12 2026-10-23T10:00:00Z" "$(reasons_of builder "")"
t reasons-a-draft-of-someone-else-is-nobodys-review 0 "$(reasons_of reviewer codex-bot | grep -c 'review#o/r#21')"
t reasons-a-review-request-on-an-open-pr-counts 1 "$(reasons_of reviewer codex-bot | grep -c 'review#o/r#20')"
t reasons-an-empty-board-wakes-nobody "" "$(wake_reasons 'triage builder' dan-claude-bot o/r "")"

# --- the vetoes, from a store that answers fixtures --------------------------
HT_LEDGER=""; HT_BREAKER=""; HT_COUNT=0
wake_store() {
  case "$1" in
    ledger) [ -n "$HT_LEDGER" ] && printf '%s\n' "$HT_LEDGER" ;;
    state) case "$*" in *".session-terminal.$HT_BREAKER"*) [ -n "$HT_BREAKER" ] && printf '3\ttripped\t9\tno\t0\t0\n' ;; *) return 1 ;; esac ;;
    sessions-count) printf '%s\n' "$HT_COUNT" ;;
  esac
}
R="$(wake_reasons builder dan-claude-bot o/r "$rows")"
t veto-nothing-vetoes-a-fresh-board 0 "$(wake_veto alpha "$R" | grep -c '^veto:')"
HT_LEDGER=$'o/r#12 2026-10-23T10:00:00Z\no/r#20 2026-10-23T10:00:00Z'
t veto-a-seen-item-at-its-timestamp-is-dropped 1 "$(wake_veto alpha "$R" | grep -c '^veto:ready#o/r#12:seen$')"
t veto-an-item-seen-before-it-moved-still-wakes 0 "$(wake_veto alpha "$R" | grep -c '^veto:pr#o/r#20:')"
HT_LEDGER=""
HT_BREAKER=build
t veto-a-tripped-lane-drops-its-reasons "veto:pr#o/r#20:breaker-build|veto:ready#o/r#12:breaker-build" \
  "$(wake_veto alpha "$R" | grep '^veto:' | sort | paste -sd'|' -)"
t veto-a-tripped-lane-leaves-the-others 1 "$(wake_veto alpha "$R" | grep -c '^attention#o/r#13 ')"
HT_BREAKER=""
# shellcheck disable=SC2034  # read through ${!var} by wake_budget_exhausted
export BUDGET_SESSIONS_BUILD=12 BUDGET_WINDOW=86400; HT_COUNT=12
t veto-an-exhausted-budget-drops-the-lane 2 "$(wake_veto alpha "$R" | grep -c ':budget-build$')"
HT_COUNT=11
t veto-a-budget-with-room-wakes 0 "$(wake_veto alpha "$R" | grep -c ':budget-')"
export BUDGET_SESSIONS_BUILD=0; HT_COUNT=999
t veto-no-ceiling-no-veto 0 "$(wake_veto alpha "$R" | grep -c ':budget-')"
# A due wait is answered by the RESUME session, so the resume lane's spent
# budget vetoes it — otherwise a refused resume woke the box every tick.
export BUDGET_SESSIONS_RESUME=1; HT_COUNT=1
t veto-a-due-wait-is-vetoed-by-the-resume-lanes-budget 'veto:wait#o/r#5:budget-resume' "$(wake_veto alpha 'wait#o/r#5 -')"
unset BUDGET_SESSIONS_BUILD BUDGET_SESSIONS_RESUME BUDGET_WINDOW HT_COUNT
t veto-triage-board-reason-is-never-ledger-vetoed 1 "$(HT_LEDGER='o/r#12 2099-01-01T00:00:00Z' wake_veto alpha "board#o/r -" | grep -c '^board#o/r -$')"

# --- the why token -----------------------------------------------------------
t why-joins-the-surviving-reasons "attention#o/r#13,pr#o/r#20,ready#o/r#12" "$(wake_why "$(wake_veto alpha "$R" | sort)")"
HT_BREAKER=build
t why-drops-the-vetoed-ones "attention#o/r#13" "$(wake_why "$(wake_veto alpha "$R")")"
HT_BREAKER=""
t why-is-empty-when-nothing-survives "" "$(wake_why "veto:ready#o/r#12:seen")"

# ── #760 — a parked wait wakes the member when its checks conclude ─────────
HT_STATES=""; HT_PENDING=0; HT_HEAD=h1
wake_store() {
  case "$1" in
    states) [ -n "$HT_STATES" ] && printf '%s\n' "$HT_STATES" ;;
    *) return 1 ;;
  esac
}
wake_gh() { printf '{"headRefOid":"%s","statusCheckRollup":[%s]}\n' "$HT_HEAD" "$([ "$HT_PENDING" -gt 0 ] && printf '{"status":"IN_PROGRESS","conclusion":null}')"; }
t wait-no-parks-no-reasons "" "$(wake_wait_reasons alpha)"
HT_STATES=$'.wait-o_r-7\to/r 7 h1 2026-10-23T10:00:00Z'
HT_PENDING=1
t wait-a-pending-park-is-not-a-reason "" "$(wake_wait_reasons alpha)"
HT_PENDING=0
t wait-a-concluded-park-is-a-reason "wait#o/r#7 -" "$(wake_wait_reasons alpha)"
HT_PENDING=1; HT_HEAD=h2
t wait-a-moved-head-is-a-reason "wait#o/r#7 -" "$(wake_wait_reasons alpha)"
HT_STATES=$'.seen-build\to/r#1 2026-10-23T00:00:00Z'
t wait-other-state-files-are-not-parks "" "$(wake_wait_reasons alpha)"

# ── #762 — a deferred cut wakes the member when main's quiet window is due ──
t release-no-deferral-no-reasons "" "$(wake_release_reasons alpha)"
HT_STATES=".release-due-o_r	o/r $(( $(date +%s) + 600 ))"
t release-a-cut-not-yet-due-is-not-a-reason "" "$(wake_release_reasons alpha)"
HT_STATES=".release-due-o_r	o/r $(( $(date +%s) - 1 ))"
t release-a-due-cut-is-a-reason "release#o/r -" "$(wake_release_reasons alpha)"
HT_STATES=$'.release-due-o_r\to/r soon'
t release-an-unreadable-due-time-is-not-a-reason "" "$(wake_release_reasons alpha)"
HT_STATES=$'.release-cut-o_r\t91 release/x 0123abc'
t release-the-cut-record-is-not-a-deferral "" "$(wake_release_reasons alpha)"

# ── crew tick, end to end: shims for box and gh, a real store ─────────────
# shellcheck source=shared/lib/platform.sh
source "$ROOT/shared/lib/platform.sh"
export CREW_PLATFORM_BOX_MIN
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
CLI="$ROOT/cli/crew"
CONF="$TMP/conf"; SHIM="$TMP/shim"; STATE="$TMP/state"; HT_STATE="$STATE"; export HT_STATE
mkdir -p "$CONF" "$SHIM" "$STATE"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
printf 'o/r\n' >"$CONF/repos.txt"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta  codex  reviewer
gamma claude triage
EOF
# The box shim: states in files, every call recorded, exec answers the three
# reads the tick makes (the full probe for a drain, .idle-ticks, the wake)
# and records what the wake wrote.
cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${1:-}"; shift || true
state_of() { cat "$HT_STATE/$1.state" 2>/dev/null || echo stopped; }
case "$cmd" in
  --version|-V) printf 'box %s (/opt/box/versions/%s)\n' "$CREW_PLATFORM_BOX_MIN" "$CREW_PLATFORM_BOX_MIN" ;;
  list)
    if [ "${1:-}" = --json ]; then
      printf '['; sep=""
      for n in alpha beta gamma; do printf '%s{"name":"%s","state":"%s"}' "$sep" "$n" "$(state_of "$n")"; sep=,; done
      printf ']\n'
    else printf 'NAME\nalpha\nbeta\ngamma\n'; fi ;;
  info) printf '[{"name":"%s","status":"%s"}]\n' "$1" "$(state_of "$1")" ;;
  start) echo "start $1" >>"$HT_STATE/calls"; echo running >"$HT_STATE/$1.state" ;;
  down)  echo "down $1" >>"$HT_STATE/calls"; echo stopped >"$HT_STATE/$1.state" ;;
  exec)
    name="$1"; script="${*: -1}"
    cat >/dev/null
    [ "$(state_of "$name")" = running ] || { echo "Error: instance is not running" >&2; exit 1; }
    case "$script" in
      true) exit 0 ;;
      # The probe first: its file list names .idle-ticks and .wake-reason too.
      *'echo "::logstart"'*) echo "drain $name" >>"$HT_STATE/calls"; cat "$HT_STATE/$name.record" ;;
      *'.wake-reason'*) echo "wake $name $(printf '%s' "$script" | sed -n "s/.*printf '%s\\\\n' '\([^']*\)'.*/\1/p")" >>"$HT_STATE/calls" ;;
      *'.idle-ticks'*) cat "$HT_STATE/$name.idle" 2>/dev/null || echo 0 ;;
      # The busy probe the stop path makes: `<box>.lock` names a held lock.
      *'flock -n "$lock" true'*) echo "probe $name" >>"$HT_STATE/calls"; if [ -s "$HT_STATE/$name.lock" ]; then echo "busy $(cat "$HT_STATE/$name.lock")"; else echo "idle 0"; fi ;;
      *'CREW-FLOOR-PAUSED'*) echo "crontab $name" >>"$HT_STATE/calls"; echo "paused 1" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM/box"
# The gh shim: the board, per fixture file; a missing fixture is an API failure.
cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") [ -z "${HT_GH_DEAD:-}" ] || exit 1; exit 0 ;;
  "issue list") cat "$HT_STATE/board.issues" 2>/dev/null || exit 1 ;;
  "pr list")    cat "$HT_STATE/board.prs" 2>/dev/null || exit 1 ;;
  "api graphql") cat "$HT_STATE/board.discs" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SHIM/gh"
ht_board() {  # ht_board <issues> <prs> <discs>
  printf '%s\n' "$1" >"$HT_STATE/board.issues"; printf '%s\n' "$2" >"$HT_STATE/board.prs"; printf '%s\n' "$3" >"$HT_STATE/board.discs"
}
run_crew() { env CREW_CONFIG_DIR="$CONF" HT_STATE="$STATE" PATH="$SHIM:$PATH" bash "$CLI" "$@"; }
capture() { OUT="$(run_crew "$@" 2>&1)"; RC=$?; }
calls() { grep -c "^$1" "$STATE/calls" 2>/dev/null || true; }
# A record that lands alpha's identity and an empty ledger in the store.
ht_record() {  # ht_record <box> <login> [ledger-line] [idle-ticks]
  {
    printf '::engine 9.9.9\n::integrity current\n::agent claude\n::uptime 1\n::now 2026-10-23T12:00:00Z\n'
    printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n::vitals \n'
    printf '::logstart\n2026-10-23T11:00:00Z duty run start\n::logend\n'
    printf '::statefiles .identity .seen-build%s\n::filestart .identity\n%s\n::fileend\n' "${4:+ .idle-ticks}" "$2"
    printf '::filestart .seen-build\n%s\n::fileend\n' "${3:-}"
    [ -z "${4:-}" ] || printf '::filestart .idle-ticks\n%s\n::fileend\n' "$4"
    printf '::logfrom 1\n::logtotal 1\n::filestart duty.log\n2026-10-23T11:00:00Z duty run start\n::fileend\n'
  } >"$STATE/$1.record"
  CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" ingest --box "$1" <"$STATE/$1.record" >/dev/null
}
CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" init >/dev/null
ht_record alpha dan-claude-bot
ht_record beta codex-bot
ht_record gamma triage-bot
ht_board 'I 12 2026-10-23T10:00:00Z ready -' 'P 20 2026-10-23T11:00:00Z someone 0 codex-bot' 'D 5 2026-10-23T06:00:00Z'
printf 'FLEET_MAX_RUNNING=2\nIDLE_TICKS_BEFORE_STOP=2\nHOST_TICK_READY_S=10\n' >>"$CONF/fleet.conf"

# (1) a first tick: the builder has a ready issue, the reviewer a request, triage the board
: >"$STATE/calls"
capture tick
t tick-exits-0 0 "$RC"
t tick-starts-the-builder-for-the-ready-issue 1 "$(grep -c 'alpha: starting why=ready#o/r#12' <<<"$OUT")"
t tick-starts-the-reviewer-for-its-request 1 "$(grep -c 'beta: starting why=review#o/r#20' <<<"$OUT")"
t tick-holds-triage-at-the-cap 1 "$(grep -c 'gamma: held — 2 of 2 boxes running; why=board#o/r' <<<"$OUT")"
t tick-started-two-boxes 2 "$(calls 'start ')"
t tick-hands-each-box-its-why "wake alpha ready#o/r#12|wake beta review#o/r#20" "$(grep '^wake ' "$STATE/calls" | sort | paste -sd'|' -)"
t tick-records-the-digest-for-the-woken 2 "$(find "$CONF/store/wake" -name 'alpha.o_r.digest' -o -name 'beta.o_r.digest' | wc -l | tr -d ' ')"
t tick-does-not-record-the-held-members-digest 0 "$(find "$CONF/store/wake" -name 'gamma.*' | wc -l | tr -d ' ')"
t tick-summary-line 1 "$(grep -c '^tick: started 2, woke 0, held 1, stopped 0, vetoed 0, nothing-for 0; running 2 of 2$' <<<"$OUT")"

# (2) the board did not move: nothing starts, nothing wakes; idle boxes stop
: >"$STATE/calls"
printf '2\n' >"$STATE/alpha.idle"; printf '1\n' >"$STATE/beta.idle"
capture tick
t tick-an-unchanged-board-restarts-nobody-who-saw-it 0 "$(( $(calls 'start alpha') + $(calls 'start beta') ))"
t tick-an-idle-box-is-drained-then-stopped "drain alpha|down alpha" "$(grep -E '^(drain|down) ' "$STATE/calls" | paste -sd'|' -)"
t tick-a-box-under-the-threshold-stays "1" "$(grep -c 'beta: idle 1/2' <<<"$OUT")"
t tick-the-held-member-starts-once-there-is-room 1 "$(grep -c 'gamma: starting why=board#o/r' <<<"$OUT")"

# (3) the store's memory vetoes: alpha has seen #12 at its timestamp
ht_board 'I 12 2026-10-23T10:00:00Z ready -' '' ''
ht_record alpha dan-claude-bot 'o/r#12 2026-10-23T10:00:00Z'
rm -f "$CONF/store/wake"/alpha.*; echo stopped >"$STATE/alpha.state"
: >"$STATE/calls"
capture tick
t tick-a-seen-item-is-vetoed-and-named 1 "$(grep -c 'alpha: veto ready#o/r#12:seen' <<<"$OUT")"
t tick-a-vetoed-member-is-not-started 0 "$(calls 'start alpha')"

# (4) pause and resume
ht_board 'I 13 2026-10-23T13:00:00Z ready -' '' ''
rm -f "$CONF/store/wake"/alpha.*
capture pause alpha
t pause-exits-0 0 "$RC"
t pause-writes-the-host-marker yes "$([ -e "$CONF/store/paused/alpha" ] && echo yes || echo no)"
: >"$STATE/calls"
capture tick
t tick-never-starts-a-paused-member 1 "$(grep -c 'alpha: paused — left alone' <<<"$OUT")"
t tick-paused-member-start-count 0 "$(calls 'start alpha')"
capture resume alpha
t resume-removes-the-host-marker no "$([ -e "$CONF/store/paused/alpha" ] && echo yes || echo no)"
echo running >"$STATE/alpha.state"; : >"$STATE/calls"
capture pause alpha
t pause-on-a-running-box-edits-its-crontab 1 "$(calls 'crontab alpha')"
capture resume alpha

# (5) dry run acts on nothing
echo stopped >"$STATE/alpha.state"; echo stopped >"$STATE/gamma.state"; rm -f "$CONF/store/wake"/alpha.*; : >"$STATE/calls"
capture tick --dry-run
t tick-dry-run-says-what-it-would-start 1 "$(grep -c 'alpha: starting why=ready#o/r#13' <<<"$OUT")"
t tick-dry-run-starts-nothing 0 "$(calls 'start ')"
t tick-dry-run-records-no-digest 0 "$(find "$CONF/store/wake" -name 'alpha.*' 2>/dev/null | wc -l | tr -d ' ')"

# (6) an unreadable board is no change, said once
rm -f "$STATE/board.prs"; : >"$STATE/calls"
capture tick
t tick-an-unreadable-board-is-no-change 1 "$(grep -c 'o/r: board unreadable this tick — no change assumed, and no box is stopped on a tick that could not see the board' <<<"$OUT")"
t tick-an-unreadable-board-starts-nothing 0 "$(calls 'start ')"
# ...and stops nothing: a blind tick must not read a dead board as a quiet fleet.
echo running >"$STATE/beta.state"; printf '5\n' >"$STATE/beta.idle"; : >"$STATE/calls"
capture tick
t tick-an-unreadable-board-stops-nobody 0 "$(calls 'down ')"
t tick-an-unreadable-board-says-why-it-did-not-stop 1 "$(grep -c 'beta: idle 5 ticks, but a board was unreadable this tick — not stopped on a blind tick' <<<"$OUT")"
# A host whose gh is not logged in is blind the same way, and says so.
: >"$STATE/calls"
HT_GH_DEAD=1 capture tick
t tick-a-logged-out-host-says-so 1 "$(grep -c 'gh is not logged in on this host' <<<"$OUT")"
t tick-a-logged-out-host-stops-nobody 0 "$(calls 'down ')"
t tick-a-logged-out-host-starts-nobody 0 "$(calls 'start ')"
# A board unreadable for TICK_BLIND_TICKS running ticks is a repository the
# host cannot read, not a hiccup: said, set aside, and the idle box is stopped
# (two blind ticks above, this is the third; the logged-out tick read no
# board). A readable board clears the count.
echo running >"$STATE/beta.state"; printf '5\n' >"$STATE/beta.idle"; : >"$STATE/calls"
capture tick
t tick-a-board-unreadable-for-three-ticks-is-set-aside 1 "$(grep -c 'o/r: board unreadable for 3 ticks — not holding the fleet for it' <<<"$OUT")"
t tick-a-set-aside-board-no-longer-holds-the-idle-stop 1 "$(calls 'down beta')"
t tick-the-blind-count-is-kept 3 "$(cat "$CONF/store/wake/o_r.unreadable")"
ht_board 'P 12 2026-10-23T12:00:00Z codex-bot 0 dan-claude-bot' '' ''
capture tick
t tick-a-readable-board-clears-the-blind-count no "$([ -e "$CONF/store/wake/o_r.unreadable" ] && echo yes || echo no)"
echo stopped >"$STATE/beta.state"; rm -f "$STATE/beta.idle"

# (7) a parked wait in the store wakes a stopped member when its checks conclude
ht_board 'I 99 2026-10-23T10:00:00Z needs-triage -' '' ''
{ printf '::engine 9.9.9\n::integrity current\n::agent claude\n::uptime 1\n::now 2026-10-23T12:00:00Z\n'
  printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n::vitals \n'
  printf '::logstart\n2026-10-23T11:00:00Z duty run start\n::logend\n'
  printf '::statefiles .identity .wait-o_r-7\n::filestart .identity\ndan-claude-bot\n::fileend\n'
  printf '::filestart .wait-o_r-7\no/r 7 h1 2026-10-23T10:00:00Z\n::fileend\n'
  printf '::logfrom 1\n::logtotal 1\n::filestart duty.log\n2026-10-23T11:00:00Z duty run start\n::fileend\n'
} >"$STATE/alpha.record"
CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" ingest --box alpha <"$STATE/alpha.record" >/dev/null
t store-states-lists-the-park ".wait-o_r-7	o/r 7 h1 2026-10-23T10:00:00Z" "$(CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" states --box alpha --prefix .wait-)"
cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") [ -z "${HT_GH_DEAD:-}" ] || exit 1; exit 0 ;;
  "issue list") cat "$HT_STATE/board.issues" 2>/dev/null || exit 1 ;;
  "pr list")    cat "$HT_STATE/board.prs" 2>/dev/null || exit 1 ;;
  "api graphql") cat "$HT_STATE/board.discs" 2>/dev/null || exit 1 ;;
  "pr view")    printf '{"headRefOid":"h1","statusCheckRollup":[%s]}\n' "${HT_PR_VIEW:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$SHIM/gh"
echo stopped >"$STATE/alpha.state"; echo stopped >"$STATE/beta.state"; echo stopped >"$STATE/gamma.state"
rm -f "$CONF/store/wake"/alpha.*; : >"$STATE/calls"
HT_PR_VIEW='' capture tick
t tick-a-concluded-park-starts-the-member 1 "$(grep -c 'alpha: starting why=wait#o/r#7' <<<"$OUT")"
t tick-the-wake-names-the-park "wake alpha wait#o/r#7" "$(grep '^wake alpha' "$STATE/calls" | head -1)"

# (8) the store gives a member's memory back as files, and names the peaks
HT_EXPORT="$TMP/export"; rm -rf "$HT_EXPORT"
t store-export-writes-the-members-files 1 "$(CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" export --box alpha --dir "$HT_EXPORT" >/dev/null; [ -f "$HT_EXPORT/.identity" ] && [ -f "$HT_EXPORT/.wait-o_r-7" ] && echo 1 || echo 0)"
t store-export-identity-round-trips dan-claude-bot "$(cat "$HT_EXPORT/.identity")"
t store-peaks-without-sessions-is-1 1 "$(CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" peaks --box alpha >/dev/null 2>&1; echo $?)"

# --- wiring pins ----------------------------------------------------------------
t crontab-example-runs-the-host-tick 1 "$(grep -c 'crew tick' "$ROOT/shared/host-crontab.example")"
t the-floor-reads-the-one-pause-shell 1 "$(grep -c '_host_shell_block("PAUSE_SH")' "$ROOT/fleet-floor/server/floor/actions.py")"
t exactly-one-copy-of-the-pause-shell 1 "$(grep -rl "sed -E 's|^(\[^#\].\*tick" "$ROOT/shared" "$ROOT/cli" "$ROOT/fleet-floor/server" | wc -l | tr -d ' ')"
t help-names-the-tick 1 "$(run_crew help 2>&1 | grep -c '^  tick ')"


# ── the adversarial review's gaps (#763): a busy box, a frozen breaker, a pause that holds, triage's idle rule ──
ht_board 'I 12 2026-10-23T10:00:00Z ready -' '' ''
# alpha's ledger already holds #12 (a full pull is the truth, so the row is
# shipped again here): the board gives it no reason, which is what makes
# its idle counter the thing on trial.
ht_record alpha dan-claude-bot 'o/r#12 2026-10-23T10:00:00Z'; ht_record beta codex-bot; ht_record gamma triage-bot
rm -f "$CONF/store/wake"/* "$CONF/store/paused"/* "$STATE"/*.lock "$STATE"/*.idle
# (1) a running box past the idle threshold whose duty lock is HELD is never stopped
echo running >"$STATE/alpha.state"; echo stopped >"$STATE/beta.state"; echo stopped >"$STATE/gamma.state"
printf '4\n' >"$STATE/alpha.idle"; printf '90\n' >"$STATE/alpha.lock"
for n in alpha beta gamma; do printf 'x\n' >"$CONF/store/wake/$n.o_r.digest"; done
: >"$STATE/calls"
capture tick
t busy-an-idle-counter-past-the-threshold-is-probed 1 "$(calls 'probe alpha')"
t busy-a-held-lock-is-not-stopped 0 "$(calls 'down alpha')"
t busy-the-refusal-is-named 1 "$(grep -c 'alpha: idle 4 ticks, but a duty holds its lock (busy) — not stopped mid-session' <<<"$OUT")"
rm -f "$STATE/alpha.lock"; : >"$STATE/calls"
capture tick
t busy-once-idle-it-is-stopped "drain alpha|down alpha" "$(grep -E '^(drain|down) ' "$STATE/calls" | paste -sd'|' -)"
# (2) a breaker tripped in the store's copy vetoes only a RUNNING box: a
# stopped one is started for the work, and its own gate decides.
{ printf '::engine 9.9.9\n::integrity current\n::agent claude\n::uptime 1\n::now 2026-10-23T12:00:00Z\n'
  printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n::vitals \n'
  printf '::logstart\n2026-10-23T11:00:00Z duty run start\n::logend\n'
  printf '::statefiles .identity .session-terminal.build\n::filestart .identity\ndan-claude-bot\n::fileend\n'
  printf '::filestart .session-terminal.build\n3\ttripped\t9\tno\t0\t0\n::fileend\n'
  printf '::logfrom 1\n::logtotal 1\n::filestart duty.log\n2026-10-23T11:00:00Z duty run start\n::fileend\n'
} >"$STATE/alpha.record"
CREW_CONFIG_DIR="$CONF" python3 "$ROOT/fleet-floor/server/floor/store.py" ingest --box alpha <"$STATE/alpha.record" >/dev/null
ht_board 'I 14 2026-10-23T14:00:00Z ready -' '' ''
echo stopped >"$STATE/alpha.state"; rm -f "$CONF/store/wake"/alpha.* "$STATE/alpha.idle"; : >"$STATE/calls"
capture tick
t breaker-a-stopped-box-is-not-vetoed-by-the-stores-copy 0 "$(grep -c 'alpha: veto ready#o/r#14:breaker-build' <<<"$OUT")"
t breaker-a-stopped-box-is-started-for-the-work 1 "$(calls 'start alpha')"
ht_board 'I 15 2026-10-23T15:00:00Z ready -' '' ''
rm -f "$CONF/store/wake"/alpha.*; : >"$STATE/calls"
capture tick
t breaker-a-running-box-is-vetoed-while-its-gate-holds 1 "$(grep -c 'alpha: veto ready#o/r#15:breaker-build' <<<"$OUT")"
# (3) a pause holds: a paused box that is running is drained and stopped, and
# never counts toward the cap.
echo running >"$STATE/alpha.state"; printf '0\n' >"$STATE/alpha.idle"
capture pause alpha
: >"$STATE/calls"
capture tick
t pause-a-paused-running-box-is-drained-and-stopped "drain alpha|down alpha" "$(grep -E '^(drain|down) alpha' "$STATE/calls" | paste -sd'|' -)"
t pause-the-stop-is-said 1 "$(grep -c 'alpha: paused — drained and stopped' <<<"$OUT")"
# ...and off the cap: with room for ONE, a paused running box does not hold
# a member with work; the member starts.
printf 'FLEET_MAX_RUNNING=1\n' >>"$CONF/fleet.conf"
echo running >"$STATE/alpha.state"; echo stopped >"$STATE/beta.state"; echo stopped >"$STATE/gamma.state"
ht_board 'P 21 2026-10-23T16:00:00Z someone 0 codex-bot' '' ''
rm -f "$CONF/store/wake"/beta.*; : >"$STATE/calls"
capture tick
t pause-a-paused-box-is-off-the-cap 0 "$(grep -c 'beta: held' <<<"$OUT")"
t pause-the-member-with-work-starts-beside-a-paused-box 1 "$(calls 'start beta')"
printf 'FLEET_MAX_RUNNING=2\n' >>"$CONF/fleet.conf"
echo stopped >"$STATE/beta.state"
capture resume alpha
# (4) triage's coarse board reason: a running triage box the movement bought
# nothing for, IDLE_TICKS_BEFORE_STOP times, is not woken for it again and
# is stopped; a precise reason is never set aside this way.
ht_board 'I 16 2026-10-23T16:00:00Z needs-triage -' '' ''
echo stopped >"$STATE/alpha.state"; echo running >"$STATE/gamma.state"; printf '2\n' >"$STATE/gamma.idle"
# The record the drain lands carries the count too, as the real probe's does.
ht_record gamma triage-bot '' 2
rm -f "$CONF/store/wake"/gamma.* "$STATE/gamma.lock"; : >"$STATE/calls"
capture tick
t triage-a-board-move-that-bought-nothing-is-not-a-wake 1 "$(grep -c 'gamma: the board moved, but 2 idle ticks bought nothing for triage — not woken for it again' <<<"$OUT")"
t triage-the-box-is-then-stopped "drain gamma|down gamma" "$(grep -E '^(drain|down) gamma' "$STATE/calls" | paste -sd'|' -)"
t triage-no-wake-was-written 0 "$(calls 'wake gamma')"
# ...and STAYS stopped on the next coarse move: the count the drain landed in
# the store is read for a stopped box too, so the board moving again does not
# boot it to be stopped two ticks later (#763 re-review: start/stop churn).
echo stopped >"$STATE/gamma.state"
ht_board 'I 17 2026-10-23T17:00:00Z needs-triage -' '' ''
: >"$STATE/calls"
capture tick
t triage-a-stopped-box-is-not-started-for-the-same-coarse-reason 0 "$(calls 'start gamma')"
t triage-the-stored-idle-count-is-what-says-so 1 "$(grep -c 'gamma: the board moved, but 2 idle ticks bought nothing for triage — not woken for it again' <<<"$OUT")"

suite_finish
