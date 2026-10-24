#!/usr/bin/env bash
# drill/rehearsal-fleet.sh — the fleet-lifecycle leg (#656).
#
#   drill/rehearsal-fleet.sh --boxes "crew-drill-triage crew-drill-builder" \
#     [--agent claude] [--roles "triage builder"]
#
# Role-INDEPENDENT, unlike every leg that runs inside rehearsal.sh's phase 2:
# what `--all`, a per-box outcome and a busy-skip need is a ROSTER, and a round
# mints one by the end of phase 2 whatever roles it ran. The single-box `config`
# leg deliberately does not carry that, which is why the fleet-wide ordering has
# never been exercised.
#
# WHY THIS LEG EXISTS. `crew restart --all`, `crew down` and `crew reset --cut
# --all` were evidenced only by an operator reading three real boxes by hand.
# The MECHANISM half of that reading — the verb works across a roster, names
# each box's outcome, skips a busy box, reports a refusal with its composition
# — needs a real host, real boxes and a real operator fleet definition, all of
# which a drill round already has. The FLEET-IDENTITY half — seven boxes with
# weeks of accreted state, real gh credentials and real vendor logins — is what
# a drill box structurally cannot carry, and this leg does not claim it. A
# `crew reset` restore on a box hired ninety minutes ago proves the restore
# PATH; it does not prove that a production reviewer comes back without a
# re-login. That reading stays the operator's.
#
# EVERY VERDICT IS TAKEN FROM PER-BOX OUTPUT AND NONE FROM AN EXIT CODE. The
# three verbs return one number for a whole roster, so an rc can say "something
# was skipped" and never "which box". drill/fleet-lifecycle.sh holds the
# classifiers, and its fixtures execute them; see the header there.
set -uo pipefail

BOXES=""
AGENT="claude"
ROLES=""

usage() {
  echo "usage: drill/rehearsal-fleet.sh --boxes \"<name> ...\" [--agent <name>] [--roles \"<role> ...\"]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --boxes) BOXES="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --roles) ROLES="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done
[ -n "${BOXES// /}" ] || { usage; exit 1; }

# This leg STOPS boxes, snapshots them and rolls one back. Every target is
# checked before anything is built, and the check is on the name rather than on
# the roster it came from: a roster is a file an operator can point anywhere,
# and `crew reset --cut --all` over the production fleet is not a mistake this
# script gets to make once.
for box_name in $BOXES; do
  case "$box_name" in
    crew-drill-*) ;;
    *)
      echo "refusing non-drill box '$box_name' — the fleet-lifecycle rehearsal targets crew-drill-* boxes only" >&2
      exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/cli/crew"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=drill/fleet-lifecycle.sh
. "$HERE/fleet-lifecycle.sh"
command -v box >/dev/null \
  || { echo "drill/rehearsal-fleet.sh runs on a box HOST — no 'box' on PATH"; exit 1; }

PASS=0
declare -a FAILS=()
VERDICTS=""
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); VERDICTS="$VERDICTS
ok $1"; }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); VERDICTS="$VERDICTS
FAIL $1${2:+ — $2}"; }
skip() { echo "skip $1${2:+  — $2}"; VERDICTS="$VERDICTS
skip $1${2:+ — $2}"; }
bx()   { box exec "$1" -- bash -lc "$2" </dev/null; }

TMP="$(mktemp -d)"
CONFIG="$TMP/operator"
LOCK_TAG=".crew-fleet-drill-$$"
BUSY_BOX=""
declare -a TARGETS=()
for box_name in $BOXES; do TARGETS+=("$box_name"); done
# The roles column of the roster, positionally paired with the boxes. A generated
# roster whose agent or role column is wrong is read by every verb below, so it
# is built from what the round drilled rather than defaulted.
declare -a TARGET_ROLES=()
for role in ${ROLES:-}; do TARGET_ROLES+=("$role"); done

# Release the duty lock this leg took, whatever happened. The busy box is a
# REAL held lock — the same `flock` on the same path a duty tick takes, which is
# what drain_probe() reads — so leaving it held would wedge that box for every
# later leg and for teardown.
cleanup() {
  local rc=$?
  if [ -n "$BUSY_BOX" ]; then
    if bx "$BUSY_BOX" "
      if [ -r ~/$LOCK_TAG.pid ]; then kill \"\$(cat ~/$LOCK_TAG.pid)\" 2>/dev/null || true; fi
      rm -f ~/$LOCK_TAG.pid ~/duty/.duty.lock.since
    " >/dev/null 2>&1; then
      echo "teardown: released the drill-held duty lock on $BUSY_BOX"
    else
      echo "teardown: WARNING — could not release the drill-held duty lock on $BUSY_BOX; inspect with: box shell $BUSY_BOX" >&2
      [ "$rc" -ne 0 ] || rc=1
    fi
  fi
  rm -rf -- "$TMP"
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== fleet-lifecycle rehearsal (roster: ${TARGETS[*]})"

# The fixture is built the way rehearsal-config.sh builds its one: a real
# `crew init`, and CREW_EXPECT_OPERATOR_CONFIG=1 so a lost export FAILS the run
# rather than quietly exercising examples/ with CONFIG_IS_OPERATOR=0. The
# difference is the roster: three rows, not one.
if ! "$CREW" init "$CONFIG" >"$TMP/init.out" 2>&1; then
  echo "could not build fixture with crew init: $(cat "$TMP/init.out")" >&2
  exit 1
fi
: >"$CONFIG/fleet.roster"
for i in "${!TARGETS[@]}"; do
  printf '%s %s %s\n' "${TARGETS[$i]}" "$AGENT" "${TARGET_ROLES[$i]:-reviewer}" \
    >>"$CONFIG/fleet.roster"
done
ok "fixture fleet built by crew init (${#TARGETS[@]} roster rows)"

export CREW_CONFIG_DIR="$CONFIG"
export CREW_EXPECT_OPERATOR_CONFIG=1
if "$CREW" profiles >/dev/null 2>"$TMP/mode.err"; then
  ok "operator config selected (CONFIG_IS_OPERATOR=1)"
else
  fail "operator config selected (CONFIG_IS_OPERATOR=1)" "$(cat "$TMP/mode.err")"
  exit 1
fi

# --- the busy box ------------------------------------------------------------
# Held by a real `flock` on the real duty lock, in a background process inside
# the box, with the `.since` file a live session writes. Stubbing drain_probe()
# would leave the busy-skip assertion passing on a round where nothing was ever
# busy, which is the assumption this criterion exists to remove.
hold_duty_lock() { # NAME
  local name="$1"
  # shellcheck disable=SC2016  # HOME and the lock path expand inside the box
  bx "$name" '
    set -e
    mkdir -p "$HOME/duty"
    command -v flock >/dev/null 2>&1 || exit 3
    date +%s >"$HOME/duty/.duty.lock.since"
    setsid flock "$HOME/duty/.duty.lock" sleep 900 >/dev/null 2>&1 &
    printf "%s\n" "$!" >"$HOME/'"$LOCK_TAG"'.pid"
    # Confirm the lock is actually HELD before returning: a background flock
    # that lost a race and exited would leave every assertion below reading an
    # idle box and calling it a proved skip.
    for _ in 1 2 3 4 5; do
      if flock -n "$HOME/duty/.duty.lock" true >/dev/null 2>&1; then sleep 1; else exit 0; fi
    done
    exit 1
  ' >/dev/null 2>&1
}

if [ "${#TARGETS[@]}" -lt 2 ]; then
  skip "a box is held busy by a live duty lock" \
    "the round drilled ${#TARGETS[@]} box(es); a busy-skip reading needs one busy box and one that is not"
else
  BUSY_BOX="${TARGETS[1]}"
  if hold_duty_lock "$BUSY_BOX"; then
    ok "a box is held busy by a live duty lock ($BUSY_BOX)"
  else
    BUSY_BOX=""
    fail "a box is held busy by a live duty lock" \
      "could not take the duty lock on ${TARGETS[1]}; the busy-skip readings below are unproved"
  fi
fi

# --- per-box table -----------------------------------------------------------
# The table IS the evidence, not a decoration beside a summary line: #642 and
# #652 each say in their own words that a fleet-level summary alone does not
# satisfy them. It is printed from the classifier's per-box verdicts, and then
# checked against the verb's own counts — a row this leg dropped, or invented,
# disagrees and reds the round.
table_row() { printf '  %-26s %-14s %s\n' "$1" "$2" "${3:-}"; }
table_head() { printf '  %-26s %-14s %s\n' box outcome reading; }

grade_table() { # VERB SUMMARY_LINE ROWS_FILE LABEL
  local verb="$1" summary="$2" rows="$3" label="$4" agreement
  agreement="$(fleet_counts_agree "$verb" "$summary" <"$rows")"
  if [ "$agreement" = agree ]; then
    ok "$label: the per-box table's counts match the verb's own summary"
  else
    fail "$label: the per-box table's counts match the verb's own summary" \
      "$agreement (summary: $summary)"
  fi
}

# --- 1. crew restart --all ---------------------------------------------------
echo
echo "-- crew restart --all"
"$CREW" restart --all >"$TMP/restart.out" 2>&1 || true
cat "$TMP/restart.out"
RESTART_ROWS="$TMP/restart.rows"
: >"$RESTART_ROWS"
echo
echo "  per box:"
table_head
restart_unknown=0
for box_name in "${TARGETS[@]}"; do
  outcome="$(fleet_restart_outcome "$box_name" <"$TMP/restart.out")"
  # The reclaim, as a MEASURED DELTA rather than a line that ran: cycle_box
  # reads free space either side of the stop and prints both figures, so the
  # reading is taken from the verb rather than from a second `df` this leg
  # would have to time correctly.
  reading="$(sed -n "s/^  $box_name: restarted; //p" "$TMP/restart.out" | head -1)"
  [ -n "$reading" ] || reading="$(sed -n "s/^  $box_name: //p" "$TMP/restart.out" | head -1)"
  table_row "$box_name" "$outcome" "$reading"
  printf '%s %s\n' "$box_name" "$outcome" >>"$RESTART_ROWS"
  [ "$outcome" != unknown ] || restart_unknown=$((restart_unknown + 1))
done
if [ "$restart_unknown" -eq 0 ]; then
  ok "restart --all names an outcome for every roster member"
else
  fail "restart --all names an outcome for every roster member" \
    "$restart_unknown box(es) the verb never named"
fi
grade_table restart \
  "$(grep -E '^restart: [0-9]+ restarted, [0-9]+ skipped-busy, [0-9]+ failed$' "$TMP/restart.out" | tail -1)" \
  "$RESTART_ROWS" "restart --all"
if [ -z "$BUSY_BOX" ]; then
  skip "restart --all SKIPS a busy box" "no box was held busy"
elif [ "$(fleet_restart_outcome "$BUSY_BOX" <"$TMP/restart.out")" = skipped-busy ]; then
  ok "restart --all SKIPS a busy box ($BUSY_BOX)"
else
  fail "restart --all SKIPS a busy box" \
    "$BUSY_BOX read $(fleet_restart_outcome "$BUSY_BOX" <"$TMP/restart.out"), not skipped-busy"
fi

# The reclaim is a measured delta on a box that actually cycled — a skipped box
# has no before/after and reporting one would be an invented figure.
reclaim_read=0
for box_name in "${TARGETS[@]}"; do
  if grep -qE "^  $box_name: restarted; /tmp filesystem free [0-9]+ → [0-9]+ KiB \(delta [-+][0-9]+ KiB\)$" \
      "$TMP/restart.out"; then
    reclaim_read=$((reclaim_read + 1))
  fi
done
if [ "$reclaim_read" -gt 0 ]; then
  ok "the reclaim is a measured before/after delta on $reclaim_read cycled box(es)"
else
  fail "the reclaim is a measured before/after delta" \
    "no box printed a before → after free-space reading"
fi

# #642's D6: the snapshot count immediately after the restart, recorded EITHER
# WAY. The question is whether the guest's own init already clears TMPDIR; a
# leg that only recorded a non-zero count would leave D6 open on every green
# round, so both answers are reported and neither is a failure here.
snapshot_box="${TARGETS[0]}"
# shellcheck disable=SC2016  # TMPDIR expands inside the box, not here
if snapshot_count="$(bx "$snapshot_box" 'ls -1 "${TMPDIR:-/tmp}"/duty-snapshot.* 2>/dev/null | wc -l' | tr -d ' \r')" \
   && [ -n "$snapshot_count" ]; then
  if [ "$snapshot_count" -eq 0 ]; then
    ok "duty-snapshot.* count after restart on $snapshot_box: 0 — the guest's init clears TMPDIR, so #642 D6 is REDUNDANT"
  else
    ok "duty-snapshot.* count after restart on $snapshot_box: $snapshot_count — the guest's init does NOT clear TMPDIR, so #642 D6 STANDS"
  fi
else
  fail "duty-snapshot.* count after restart is recorded" \
    "could not read the count on $snapshot_box"
fi

# --- 2. crew down ------------------------------------------------------------
# The other half of drain_probe()'s contract. `restart` skips a busy box and
# `down` WAITS for one, and the two halves are a single predicate read in
# opposite directions — proving one says nothing about the other.
echo
echo "-- crew down"
if [ -n "$BUSY_BOX" ]; then
  # The wait is real and would not end on its own inside this round, so the
  # lock is released on a timer from inside the box while `down` is waiting.
  # Releasing it BEFORE the verb runs would leave nothing to wait for.
  bx "$BUSY_BOX" "
    setsid sh -c 'sleep 20; if [ -r ~/$LOCK_TAG.pid ]; then kill \"\$(cat ~/$LOCK_TAG.pid)\" 2>/dev/null || true; fi; rm -f ~/$LOCK_TAG.pid' \
      >/dev/null 2>&1 &
  " >/dev/null 2>&1 || true
fi
"$CREW" down >"$TMP/down.out" 2>&1 || true
cat "$TMP/down.out"
DOWN_ROWS="$TMP/down.rows"
: >"$DOWN_ROWS"
echo
echo "  per box:"
table_head
down_unknown=0
for box_name in "${TARGETS[@]}"; do
  outcome="$(fleet_down_outcome "$box_name" <"$TMP/down.out")"
  reading="$(sed -n "s/^  $box_name: //p" "$TMP/down.out" | head -1)"
  table_row "$box_name" "$outcome" "$reading"
  printf '%s %s\n' "$box_name" "$outcome" >>"$DOWN_ROWS"
  [ "$outcome" != unknown ] || down_unknown=$((down_unknown + 1))
done
if [ "$down_unknown" -eq 0 ]; then
  ok "down names an outcome for every roster member"
else
  fail "down names an outcome for every roster member" \
    "$down_unknown box(es) the verb never named"
fi
grade_table down \
  "$(grep -E '^down: [0-9]+ stopped, [0-9]+ waited, [0-9]+ absent, [0-9]+ failed$' "$TMP/down.out" | tail -1)" \
  "$DOWN_ROWS" "down"
if [ -z "$BUSY_BOX" ]; then
  skip "down WAITS for a busy box" "no box was held busy"
elif [ "$(fleet_down_outcome "$BUSY_BOX" <"$TMP/down.out")" = waited ]; then
  ok "down WAITS for a busy box ($BUSY_BOX)"
else
  fail "down WAITS for a busy box" \
    "$BUSY_BOX read $(fleet_down_outcome "$BUSY_BOX" <"$TMP/down.out"), not waited"
fi
# BUSY_BOX stays set through cleanup on purpose. The timed release above may or
# may not have fired by now, and a second kill on a dead pid costs nothing —
# whereas a lock this leg took and left held wedges that box for the app phase
# and for teardown.

# Bring the fleet back: a cut reads a box's login, its engine and its disk from
# INSIDE it, so it refuses a stopped box — and the boxes the app and teardown
# phases run against must be standing either way.
echo
echo "-- crew restart --all (returning the fleet from the down above)"
"$CREW" restart --all >"$TMP/restart-back.out" 2>&1 || true
cat "$TMP/restart-back.out"
returned=0
for box_name in "${TARGETS[@]}"; do
  [ "$(fleet_restart_outcome "$box_name" <"$TMP/restart-back.out")" = cycled ] \
    && returned=$((returned + 1))
done
if [ "$returned" -eq "${#TARGETS[@]}" ]; then
  ok "every box the round downed came back (${returned}/${#TARGETS[@]})"
else
  fail "every box the round downed came back" "$returned of ${#TARGETS[@]} cycled"
fi

# --- 3. crew reset --cut --all -----------------------------------------------
echo
echo "-- crew reset --cut --all"
"$CREW" reset --cut --all >"$TMP/cut.out" 2>&1 || true
cat "$TMP/cut.out"
CUT_ROWS="$TMP/cut.rows"
: >"$CUT_ROWS"
echo
echo "  per box:"
table_head
cut_unknown=0
cut_refusals=0
cut_unanswered=0
for box_name in "${TARGETS[@]}"; do
  outcome="$(fleet_cut_outcome "$box_name" <"$TMP/cut.out")"
  reading="$(sed -n "s/^  $box_name: //p" "$TMP/cut.out" | head -1)"
  answer="$(fleet_refusal_answer "$box_name" <"$TMP/cut.out")"
  case "$answer" in
    no-refusal) ;;
    composed) cut_refusals=$((cut_refusals + 1)) ;;
    *) cut_refusals=$((cut_refusals + 1)); cut_unanswered=$((cut_unanswered + 1)) ;;
  esac
  table_row "$box_name" "$outcome" "$reading"
  printf '%s %s\n' "$box_name" "$outcome" >>"$CUT_ROWS"
  [ "$outcome" != unknown ] || cut_unknown=$((cut_unknown + 1))
done
if [ "$cut_unknown" -eq 0 ]; then
  ok "reset --cut --all names an outcome for every roster member"
else
  fail "reset --cut --all names an outcome for every roster member" \
    "$cut_unknown box(es) the verb never named"
fi
grade_table cut \
  "$(grep -E '^reset --cut: [0-9]+ cut, [0-9]+ skipped-busy, [0-9]+ failed$' "$TMP/cut.out" | tail -1)" \
  "$CUT_ROWS" "reset --cut --all"
# #652's own test plan: a refusal that reports only a percentage FAILS. A round
# with no refusal at all cannot answer it either way and says so — the criterion
# is the operator's to read on the candidate, and a silent `ok` here would be
# the leg claiming a reading it never took.
if [ "$cut_refusals" -eq 0 ]; then
  skip "a reset --cut refusal is recorded with its COMPOSITION" \
    "no box was refused this round; the reading is unproved, not passed"
elif [ "$cut_unanswered" -eq 0 ]; then
  ok "a reset --cut refusal is recorded with its COMPOSITION ($cut_refusals refusal(s), all composed)"
else
  fail "a reset --cut refusal is recorded with its COMPOSITION" \
    "$cut_unanswered of $cut_refusals refusal(s) reported a figure and no composition"
fi

# --- 4. crew reset <one box> back to armed -----------------------------------
# One box, not the roster: the restore path is the same code for every member,
# and rolling the whole fleet back would cost the later phases their boxes for
# no additional reading. #589 D4 is the sharp edge — a restore that silently
# fell back to `bootstrapped` or `pristine` FAILS.
echo
echo "-- crew reset ${TARGETS[0]} (restore to armed)"
RESTORE_BOX="${TARGETS[0]}"
if [ "$(fleet_cut_outcome "$RESTORE_BOX" <"$TMP/cut.out")" != cut ]; then
  skip "a box restored to armed comes back on its first tick with its boot gate passing" \
    "$RESTORE_BOX has no checkpoint from this round to restore ($(fleet_cut_outcome "$RESTORE_BOX" <"$TMP/cut.out"))"
else
  "$CREW" reset "$RESTORE_BOX" >"$TMP/restore.out" 2>&1 || true
  cat "$TMP/restore.out"
  RESET_LABEL_NAME="$(sed -n "s/^  $RESTORE_BOX: restored to \([^ ]*\) .*/\1/p" "$TMP/restore.out" | head -1)"
  landing="$(fleet_restore_landing "$RESTORE_BOX" "${RESET_LABEL_NAME:-armed}" <"$TMP/restore.out")"
  # Graded against the label the CUT recorded, so a restore that landed on
  # `bootstrapped` cannot pass by being compared with itself.
  landing_vs_armed="$(fleet_restore_landing "$RESTORE_BOX" armed <"$TMP/restore.out")"
  if [ "$landing_vs_armed" = restored ]; then
    ok "$RESTORE_BOX restored to armed (not bootstrapped, not pristine)"
  else
    fail "$RESTORE_BOX restored to armed (not bootstrapped, not pristine)" \
      "landing read $landing_vs_armed${landing:+; label-relative reading $landing}"
  fi
  # The FIRST tick after the restore. duty.log carries the gate's verdict and
  # boot-check.log carries the probe it was taken from; neither answers it alone.
  # shellcheck disable=SC2016  # HOME expands inside the box, not here
  bx "$RESTORE_BOX" '"$HOME"/duty/bin/tick.sh' >/dev/null 2>&1 || true
  boot_check="$(bx "$RESTORE_BOX" 'tail -40 ~/duty/boot-check.log 2>/dev/null' || true)"
  duty_log="$(bx "$RESTORE_BOX" 'tail -40 ~/duty/duty.log 2>/dev/null' || true)"
  gate="$(fleet_boot_gate_reading "$duty_log" "$boot_check")"
  echo "  boot gate on the first tick after the restore: $gate"
  case "$gate" in
    passing) ok "$RESTORE_BOX's boot gate passes on its first tick after the restore" ;;
    failing) fail "$RESTORE_BOX's boot gate passes on its first tick after the restore" \
      "the gate ran and FAILED — see boot-check.log and duty.log on that box" ;;
    *) fail "$RESTORE_BOX's boot gate passes on its first tick after the restore" \
      "the gate's reading could not be taken from boot-check.log and duty.log" ;;
  esac
fi

# --- 5. crew upgrade across the roster, canary-first -------------------------
# The fleet-wide ORDERING the single-box config leg does not exercise: one box
# upgraded and read first, then the rest. `crew upgrade --all` has no canary of
# its own — canary-first is the operator's discipline (#602), so the leg drives
# it rather than asserting the verb does it.
echo
echo "-- crew upgrade (canary-first across the roster)"
CANARY="${TARGETS[0]}"
"$CREW" upgrade "$CANARY" >"$TMP/upgrade-canary.out" 2>&1 || true
cat "$TMP/upgrade-canary.out"
integrity_of() { # NAME
  "$CREW" status "$1" 2>/dev/null | sed -n 's/^integrity: //p' | head -1
}
canary_integrity="$(integrity_of "$CANARY")"
echo "  canary $CANARY integrity: ${canary_integrity:-<unreadable>}"
case "$canary_integrity" in
  current*) ok "the canary's per-box integrity line reads current before the rest of the roster" ;;
  "") fail "the canary's per-box integrity line reads current before the rest of the roster" \
        "crew status $CANARY printed no integrity line" ;;
  *) fail "the canary's per-box integrity line reads current before the rest of the roster" \
       "read: $canary_integrity" ;;
esac
"$CREW" upgrade --all >"$TMP/upgrade-all.out" 2>&1 || true
cat "$TMP/upgrade-all.out"
echo
echo "  per box:"
table_head
integrity_unreadable=0
integrity_modified=0
for box_name in "${TARGETS[@]}"; do
  reading="$(integrity_of "$box_name")"
  case "$reading" in
    current*) outcome=current ;;
    MODIFIED*) outcome=MODIFIED; integrity_modified=$((integrity_modified + 1)) ;;
    unverified*) outcome=unverified ;;
    *) outcome=unreadable; integrity_unreadable=$((integrity_unreadable + 1)) ;;
  esac
  table_row "$box_name" "$outcome" "$reading"
done
if [ "$integrity_unreadable" -eq 0 ] && [ "$integrity_modified" -eq 0 ]; then
  ok "every roster member carries a readable, unmodified integrity line after the fleet-wide upgrade"
else
  fail "every roster member carries a readable, unmodified integrity line after the fleet-wide upgrade" \
    "$integrity_modified MODIFIED, $integrity_unreadable unreadable"
fi

echo
echo "== fleet-lifecycle rehearsal summary: $PASS ok, ${#FAILS[@]} failed"
# The leg's OWN verdict, for the round's summary row. It cannot travel on this
# script's exit code alone: a leg that skipped every busy-box reading because
# the round drilled one box is not a pass, and the round has to be able to tell
# that apart from a leg that asserted everything.
if [ -n "${REHEARSAL_FLEET_STATUS:-}" ]; then
  fleet_worst_verdict "$VERDICTS" >>"$REHEARSAL_FLEET_STATUS"
fi
[ "${#FAILS[@]}" -eq 0 ]
