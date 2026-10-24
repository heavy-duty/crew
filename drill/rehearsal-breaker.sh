#!/usr/bin/env bash
# Sourceable terminal-breaker drill helpers. The live leg runs last in phase 2;
# the log predicates stay here so CI can mutate their inputs without a box host.
# shellcheck disable=SC2016  # quoted commands expand HOME inside the drill box

REHEARSAL_BREAKER_DIR=""
REHEARSAL_BREAKER_ROLE_CONF=""
REHEARSAL_BREAKER_STATE=""
REHEARSAL_BREAKER_REPO=""
REHEARSAL_BREAKER_ISSUE=""
# The box's own effective LABEL_ATTENTION, resolved in _load_installed_facts.
REHEARSAL_BREAKER_LABEL=""
# What the arming re-read actually saw, printed beside a failed arming row.
REHEARSAL_BREAKER_ARM_READING=""
# The slice of duty.log written by the last tick this leg CONFIRMED ran.
REHEARSAL_BREAKER_TICK_LOG=""
# Why the last fire produced no evidence, in the operator's words. Read into
# the INCOMPLETE reason so the summary line distinguishes a tick that was
# locked out from one that never landed at all.
REHEARSAL_BREAKER_TICK_REASON=""

# The bound on re-firing a tick the box refused, and the pause between tries.
# A lock-skipped tick returns immediately, so the five ticks the rc2 round
# fired after a held lock all landed inside two seconds; without the pause the
# bound is spent before the holder could plausibly have finished. Both are
# overridable so the suite can exhaust the bound without spending minutes.
REHEARSAL_BREAKER_TICK_TRIES="${REHEARSAL_BREAKER_TICK_TRIES:-10}"
REHEARSAL_BREAKER_TICK_WAIT="${REHEARSAL_BREAKER_TICK_WAIT:-30}"

rehearsal_breaker_record_result() {
  local result="$1" result_file="${REHEARSAL_BREAKER_RESULT_FILE:-}"
  [ -z "$result_file" ] || printf '%s\n' "$result" >"$result_file"
}

rehearsal_breaker_record_reason() {
  local reason="$1" reason_file="${REHEARSAL_BREAKER_REASON_FILE:-}"
  [ -z "$reason_file" ] || printf '%s\n' "$reason" >"$reason_file"
}

rehearsal_breaker_combine_result() {
  local current="$1" role_rc="$2"
  if [ "$current" -eq 1 ] || { [ "$role_rc" -ne 0 ] && [ "$role_rc" -ne 2 ]; }; then
    printf '1\n'
  elif [ "$role_rc" -eq 0 ]; then
    printf '0\n'
  else
    printf '%s\n' "$current"
  fi
}

rehearsal_breaker_round_result() {
  local current="$1" enabled="$2" breaker_result="$3"
  if [ "$enabled" -eq 0 ]; then
    printf '%s\n' "$current"
  elif [ "$breaker_result" -eq 1 ]; then
    printf '1\n'
  elif [ "$breaker_result" -eq 2 ] && [ "$current" -ne 1 ]; then
    printf '2\n'
  else
    printf '%s\n' "$current"
  fi
}

rehearsal_breaker_summary() {
  local enabled="$1" drilled="$2" result="$3" reason="${4:-}"
  if [ "$enabled" -eq 0 ]; then
    printf '%s\n' "skip       breaker  (--no-breaker-drill)"
  elif [ "$result" -eq 0 ]; then
    printf '%s\n' "ok         breaker  (trip + single alert + recovery)"
  elif [ "$result" -eq 1 ]; then
    printf '%s\n' "FAIL       breaker"
  elif [ -z "${drilled// /}" ]; then
    printf '%s\n' "INCOMPLETE breaker  (no role reached a box)"
  elif [ -n "$reason" ]; then
    printf '%s\n' "INCOMPLETE breaker  ($reason)"
  else
    printf '%s\n' "INCOMPLETE breaker  (phase 2 skipped)"
  fi
}

rehearsal_breaker_load_installed_facts() {
  local threshold kind state label unresolved
  # Read the installed engine's effective value: the shipped conf may defer
  # the default to OPERATING_LIMITS, and parsing that conf would lose it.
  threshold="$(bx "set -a; . ~/duty/conf/fleet.defaults.conf; . ~/duty/lib/common.sh; _session_terminal_threshold")" \
    || threshold=""
  kind="$(bx "sed -n 's/^[[:space:]]*run_session \([^ ]*\) .*/\1/p' ~/duty/lib/duty-attention.sh | head -1")" \
    || kind=""
  # ...and the lane's LABEL, read through load_fleet_conf ITSELF rather than
  # through a copy of its order. LABEL_ATTENTION is NOT one of the six wire
  # marks the loader restores over fleet.conf (shared/lib/common/conf.sh:14-24),
  # so an operator file genuinely moves it and duty_attention then fetches that
  # name (duty-attention.sh:115). Arming the lane with the literal `attention`
  # on a box that moved it sets a label the engine never asks for: the leg would
  # then grade a dispatch it never requested, which is this issue's defect in
  # its other direction. Re-implementing the order inline would assert the leg
  # against itself — if the loader's order or its wire-mark set ever moves, an
  # inline copy drifts silently and its test still passes.
  #
  # DUTY_DIR is exported before the source and not CONF_DIR after it: common.sh
  # derives `CONF_DIR="$DUTY_DIR/conf"` unconditionally at source time
  # (shared/lib/common.sh:11,17), so a CONF_DIR set by this read is overwritten,
  # and an inherited DUTY_DIR would then point the loader at another tree's conf.
  #
  # No `| head -1` and no `| tr`: this file runs under rehearsal.sh's
  # `pipefail`, where a downstream command that exits early can SIGPIPE the box
  # read and turn a resolved label into an empty one intermittently (#449).
  # The trimming is parameter expansion, which cannot fail.
  label="$(bx 'export DUTY_DIR=$HOME/duty
               . ~/duty/lib/common.sh
               load_fleet_conf
               printf "%s\n" "$LABEL_ATTENTION"')" || label=""
  label="${label%%$'\n'*}"
  label="${label//$'\r'/}"
  case "$threshold" in ''|*[!0-9]*|0) threshold="" ;; esac
  case "$kind" in ''|*[!A-Za-z0-9_-]*) kind="" ;; esac
  # A label carrying whitespace is refused rather than half-supported: GitHub
  # allows the name, but it would also need percent-encoding in cleanup's
  # DELETE path, and a lane this leg can arm and cannot disarm is worse than
  # one it refuses. Fail-closed is only a favour to the operator if they can
  # tell WHICH of the three refused, hence the reading printed beside the row.
  case "$label" in *[[:space:]]*) label="" ;; esac
  unresolved=""
  [ -n "$threshold" ] || unresolved="terminal threshold"
  [ -n "$kind" ] || unresolved="$unresolved${unresolved:+, }lane kind"
  [ -n "$label" ] || unresolved="$unresolved${unresolved:+, }attention label"
  if [ -n "$unresolved" ]; then
    fail "breaker: installed threshold, lane kind and attention label resolve for $AGENT"
    echo "  unresolved: $unresolved"
    return 1
  fi
  state="$(bx "set -a; . ~/duty/conf/fleet.defaults.conf; . ~/duty/lib/common.sh; DUTY_DIR=\$HOME/duty; _session_terminal_state '$kind'")" \
    || state=""
  if [ -z "$state" ]; then
    fail "breaker: installed state path resolves for $AGENT"
    return 1
  fi
  REHEARSAL_BREAKER_THRESHOLD="$threshold"
  REHEARSAL_BREAKER_KIND="$kind"
  REHEARSAL_BREAKER_STATE="$state"
  REHEARSAL_BREAKER_LABEL="$label"
  ok "breaker: installed threshold, lane kind and attention label resolve for $AGENT"
}

rehearsal_breaker_profile_has_hook() {
  local hook="$1"
  bx "set -a; . ~/duty/conf/agents/$AGENT.conf; declare -F '$hook' >/dev/null"
}

rehearsal_breaker_terminal_fixture() {
  bx "set -a
    . ~/duty/conf/agents/$AGENT.conf
    bot_session_terminal_fixture
  "
}

rehearsal_breaker_terminal_fixture_is_classified() {
  bx "set -a
    . ~/duty/conf/agents/$AGENT.conf
    bot_session_terminal_fixture > /tmp/crew-breaker-terminal.log
    rc=0
    bot_session_terminal /tmp/crew-breaker-terminal.log || rc=\$?
    rm -f /tmp/crew-breaker-terminal.log
    exit \$rc
  "
}

rehearsal_breaker_install_fixture() {
  local role="$1" encoded box_home fixture fixture_dir role_conf
  box_home="$(bx 'printf %s "$HOME"')" || return 1
  [ -n "$box_home" ] || return 1
  fixture_dir="$box_home/.crew-breaker-drill"
  role_conf="$box_home/duty/conf/roles/$role.conf"
  # Refuse a stale fixture before arming cleanup with its old backup. Restoring
  # an unknown prior run over today's installed profile would be destructive.
  bx "test ! -e '$fixture_dir'" || return 1
  REHEARSAL_BREAKER_DIR="$fixture_dir"
  REHEARSAL_BREAKER_ROLE_CONF="$role_conf"
  fixture="$(rehearsal_breaker_terminal_fixture)" || return 1
  [ -n "$fixture" ] || return 1
  encoded="$(printf '%s\n' "$fixture" | base64 -w0)"
  bx "set -e
    mkdir -p '$REHEARSAL_BREAKER_DIR/bin'
    cp '$REHEARSAL_BREAKER_ROLE_CONF' '$REHEARSAL_BREAKER_DIR/role.conf'
    printf '%s' '$encoded' | base64 -d > '$REHEARSAL_BREAKER_DIR/terminal.txt'
    cat > '$REHEARSAL_BREAKER_DIR/bin/agent' <<'EOF'
#!/usr/bin/env bash
cat '$REHEARSAL_BREAKER_DIR/terminal.txt'
exit 1
EOF
    chmod +x '$REHEARSAL_BREAKER_DIR/bin/agent'
    cat >> '$REHEARSAL_BREAKER_ROLE_CONF' <<'EOF'
# rehearsal-breaker begin
BOT_CLI_CMD=(\"$REHEARSAL_BREAKER_DIR/bin/agent\")
bot_cli_probe() { return 1; }
alert() { printf '%s\\n' \"\$*\" >>\"$REHEARSAL_BREAKER_DIR/alerts.log\"; }
# rehearsal-breaker end
EOF
  "
}

rehearsal_breaker_restore_cli() {
  [ -n "$REHEARSAL_BREAKER_DIR" ] || return 0
  if bx "set -e
    if [ -f '$REHEARSAL_BREAKER_DIR/role.conf' ] && [ -n '$REHEARSAL_BREAKER_ROLE_CONF' ]; then
      cp '$REHEARSAL_BREAKER_DIR/role.conf' '$REHEARSAL_BREAKER_ROLE_CONF'
    fi
    rm -rf '$REHEARSAL_BREAKER_DIR'
  "; then
    REHEARSAL_BREAKER_DIR=""
    return 0
  fi
  return 1
}

rehearsal_breaker_restore_cli_for_recovery() {
  [ -n "$REHEARSAL_BREAKER_DIR" ] || return 1
  bx "set -e
    cp '$REHEARSAL_BREAKER_DIR/role.conf' '$REHEARSAL_BREAKER_ROLE_CONF'
    cat >> '$REHEARSAL_BREAKER_ROLE_CONF' <<'EOF'
# rehearsal-breaker recovery begin
alert() { printf '%s\n' \"\$*\" >>\"$REHEARSAL_BREAKER_DIR/alerts.log\"; }
# rehearsal-breaker recovery end
EOF
  "
}

rehearsal_breaker_attention_is_clear_from_json() {
  jq -e --arg l "${2:-attention}" '[.labels[].name] | index($l) == null' \
    >/dev/null <<<"$1"
}

# Speaks wait_for's state protocol through the shared predicate (#749): a read
# that fails is 3, never "the label is still there".
rehearsal_breaker_attention_is_clear() {
  rehearsal_issue_lacks_label "$1" "$2" "${3:-attention}"
}

# --- arming is graded on the FIXTURE'S STATE, not on a request's rc (#724) ---
#
# `gh api -X POST …/labels` on a CLOSED issue returns 201 and arms nothing:
# duty_attention fetches `/issues?filter=assigned&state=open`
# (shared/lib/duty-attention.sh:115), so a closed issue is not a candidate.
# In the 0.1.3-rc2 round the triage role's fixture had been closed by an
# earlier leg at 13:00:54 and this leg labelled it at 13:05:13; the arming row
# passed, all five ticks logged `attention: none in registry`, and every lane
# row below failed — seven assertions reported against an engine that was
# behaving correctly. `builder` passed outright in the same round, against the
# same engine, which is how the harness was identified as the variable.
#
# So the arming does three things and grades only the last: reopen a closed
# fixture, request the label, then RE-READ the issue and assert what it now is.
#
# JSON first, then the label — the same order as
# rehearsal_breaker_attention_is_clear_from_json two functions above, which
# took the opposite one until #724's round.
rehearsal_breaker_fixture_is_armed_from_json() {
  local label="$2"
  # stderr silenced like every other read here: an unparseable body already has
  # its own reading printed beside the row, and a raw jq parse error in the
  # transcript sends the operator to the parser rather than to the board.
  jq -e --arg l "$label" \
    '.state == "open" and ([.labels[]?.name] | index($l) != null)' \
    >/dev/null 2>&1 <<<"$1"
}

# What a failed arming row prints beside itself. A bare FAIL sends the operator
# to the engine; `state=closed labels=claimed` sends them to the harness.
rehearsal_breaker_fixture_reading_from_json() {
  jq -r '"state=\(.state // "?") labels=\([.labels[]?.name] | join(",") )"' \
    <<<"$1" 2>/dev/null
}

rehearsal_breaker_arm_fixture() {
  local repo="$1" issue="$2" label="$3" json=""
  REHEARSAL_BREAKER_ARM_READING=""
  if ! json="$(gh api "repos/$repo/issues/$issue" 2>/dev/null)" || [ -z "$json" ]; then
    REHEARSAL_BREAKER_ARM_READING="the fixture issue could not be read"
    return 1
  fi
  # An earlier leg's own teardown closes this fixture, and the round is
  # ordered so that it can have. Reopen before arming rather than refusing:
  # the lane needs an open issue, and minting a second one would leave the
  # first behind for `teardown: close this leg's owned fixtures` to find.
  if ! jq -e '.state == "open"' >/dev/null <<<"$json" 2>/dev/null; then
    gh api -X PATCH "repos/$repo/issues/$issue" -f state=open >/dev/null 2>&1 || true
  fi
  gh api -X POST "repos/$repo/issues/$issue/labels" \
    -f "labels[]=$label" >/dev/null 2>&1 || true
  # The re-read IS the assertion. Both mutations above are allowed to fail
  # quietly on purpose: neither exit status is evidence about the issue's
  # state, and grading one of them is the defect this function replaces.
  if ! json="$(gh api "repos/$repo/issues/$issue" 2>/dev/null)" || [ -z "$json" ]; then
    REHEARSAL_BREAKER_ARM_READING="the fixture issue could not be read back"
    return 1
  fi
  REHEARSAL_BREAKER_ARM_READING="$(rehearsal_breaker_fixture_reading_from_json "$json")"
  [ -n "$REHEARSAL_BREAKER_ARM_READING" ] \
    || REHEARSAL_BREAKER_ARM_READING="the fixture issue read back unparseable"
  rehearsal_breaker_fixture_is_armed_from_json "$json" "$label"
}

rehearsal_breaker_profile_is_restored() {
  [ -n "$REHEARSAL_BREAKER_ROLE_CONF" ] || return 1
  bx "test -f '$REHEARSAL_BREAKER_ROLE_CONF' && ! grep -qF '# rehearsal-breaker ' '$REHEARSAL_BREAKER_ROLE_CONF'"
}

rehearsal_breaker_cleanup() {
  rehearsal_breaker_restore_cli || true
  [ -z "$REHEARSAL_BREAKER_STATE" ] || bx "rm -f '$REHEARSAL_BREAKER_STATE'" >/dev/null 2>&1 || true
  if [ -n "$REHEARSAL_BREAKER_REPO" ] && [ -n "$REHEARSAL_BREAKER_ISSUE" ]; then
    # The label this leg actually set, which is the box's own effective one.
    # `attention` stays the fallback for a cleanup that runs before the facts
    # resolved, where nothing was armed and the DELETE is a no-op either way.
    gh api -X DELETE \
      "repos/$REHEARSAL_BREAKER_REPO/issues/$REHEARSAL_BREAKER_ISSUE/labels/${REHEARSAL_BREAKER_LABEL:-attention}" \
      >/dev/null 2>&1 || true
  fi
}

rehearsal_breaker_below_threshold_from_log() {
  local kind="$1" log_text="$2"
  grep -Fq "SESSION START kind=$kind" <<<"$log_text" \
    && grep -Fq "outcome=TERMINAL" <<<"$log_text" \
    && ! grep -Fq "session breaker: kind=$kind tripped" <<<"$log_text"
}

rehearsal_breaker_trip_from_log() {
  local kind="$1" threshold="$2" log_text="$3"
  [ "$(grep -cF "SESSION START kind=$kind" <<<"$log_text")" -eq "$threshold" ] \
    && [ "$(grep -cF "session breaker: kind=$kind tripped after $threshold consecutive terminal failures" <<<"$log_text")" -eq 1 ]
}

rehearsal_breaker_suppressed_from_log() {
  local kind="$1" threshold="$2" expected="$3" log_text="$4" matching_skips
  matching_skips="$(
    grep -F "SESSION SKIP kind=$kind" <<<"$log_text" \
      | grep -cF "reason=terminal-breaker count=$threshold" || true
  )"
  [ "$matching_skips" -eq "$expected" ] \
    && ! grep -Fq "SESSION START kind=$kind" <<<"$log_text"
}

rehearsal_breaker_recovered_from_log() {
  local kind="$1" log_text="$2"
  grep -Fq "session breaker: kind=$kind recovered; dispatch resumed" <<<"$log_text" \
    && grep -Fq "SESSION START kind=$kind" <<<"$log_text"
}

rehearsal_breaker_alert_count_is_one() {
  local kind="$1" alerts="$2"
  [ "$(grep -cF ": $kind session dispatch stopped after" <<<"$alerts" || true)" -eq 1 ]
}

rehearsal_breaker_tick_log() {
  local first="$1"
  bx "tail -n +$first ~/duty/duty.log"
}

# --- a slice is only evidence if the tick RAN (#724) -------------------------
#
# `tick.sh` takes the box's `flock` with `-n` and, when a previous run still
# holds it, logs one line and exits (shared/bin/tick.sh:85-90). A skipped tick
# returns immediately, so this leg's back-to-back loop spends its whole budget
# inside two seconds: in the 0.1.3-rc2 round the reviewer role's dispatch 1
# landed and the five ticks after it were all lock-skips, logged between
# 15:54:29Z and 15:54:31Z. Each of those slices was then graded as lane
# behaviour, and the lane was reported broken.
#
# That slice says nothing about the lane in either direction. It is the third
# state the census groups in rehearsal-safety.sh are about, on the tick rather
# than on the log: not "the lane did not trip" and not "the lane tripped", but
# "nothing was asked of it". The leg waits and re-fires instead of grading it,
# and when the bound is spent it says INCOMPLETE with the reason — never FAIL
# against a lane it never reached.
#
# The diagnostic the message reads was #726's, and #726 split it in two: a
# refused boundary now says either that the previous run still holds the lock
# or that the lock outlived it on an inherited descriptor. Both are the same
# reading HERE, which is what the sentence above already said — this leg
# declines to grade a tick that did not run, whatever the holder turns out to
# have been — so both wordings are matched and neither is ranked.
rehearsal_breaker_tick_was_skipped_from_log() {
  grep -Fq -e 'tick skipped: previous run still holds the lock' \
           -e 'tick skipped: lock held with no live holder' <<<"$1"
}

# Which of tick.sh's evidence shapes this slice carries. The contract at the
# top of shared/bin/tick.sh guarantees exactly one line per boundary, in one of
# three shapes, and silence is itself a fourth reading:
#
#   <ts> duty run start          — the tick RAN (written by duty.sh:61)
#   <ts> duty tick skipped: ...  — the lock refused it        -> `locked`
#   <ts> duty tick FAILED: ...   — the job exited non-zero    -> `failed`
#   (nothing)                    — the invocation never landed -> `silent`
#
# Absence of the lock-skip line is NOT evidence that a tick ran: an invocation
# that failed, or a log that could not be read, produces a slice that carries
# no line at all, and grading that as lane behaviour is this issue's defect
# with the tick in place of the fixture. So the leg reads the POSITIVE mark.
#
# `failed` is checked before `run start` deliberately. tick.sh writes FAILED
# after the job has usually already written its own start record
# (shared/lib/common/tick-health.sh:60), so the pair means the job began and
# then aborted: that slice is a partial run, and a lane graded on it is graded
# on however far the job got. INCOMPLETE with the reason named is the honest
# reading, and it is the safe direction — never a FAIL against an engine the
# tick never reached.
#
# The job is `duty` because the leg fires tick.sh with no argument, which is
# what makes these marks constants here rather than a parameter.
rehearsal_breaker_tick_outcome_from_log() {
  local slice="$1"
  if rehearsal_breaker_tick_was_skipped_from_log "$slice"; then
    printf 'locked\n'
  elif grep -Fq ' duty tick FAILED:' <<<"$slice"; then
    printf 'failed\n'
  elif grep -Fq ' duty run start' <<<"$slice"; then
    printf 'ran\n'
  else
    printf 'silent\n'
  fi
}

# Fire one tick and leave its slice in REHEARSAL_BREAKER_TICK_LOG. rc 0 means a
# tick RAN and the slice is evidence; rc 2 means there is nothing to grade and
# REHEARSAL_BREAKER_TICK_REASON says why. The result is a global rather than
# stdout precisely so the caller reads it without a command substitution: a
# subshell would lose the retry state along with it.
#
# Only a held lock is retried. A box that cannot be measured, cannot be read
# back, or ran a tick that wrote no evidence is not a condition the bound
# outlasts — it is a box this leg cannot grade, said once.
rehearsal_breaker_fire_tick() {
  local first try=1 slice outcome lines rc
  REHEARSAL_BREAKER_TICK_LOG=""
  REHEARSAL_BREAKER_TICK_REASON=""
  while [ "$try" -le "$REHEARSAL_BREAKER_TICK_TRIES" ]; do
    # The boundary read is graded too. Left as `$(( $(bx …) + 1 ))`, a failed
    # read makes the substitution empty, `$(( + 1 ))` is 1, and the "slice"
    # becomes the WHOLE log — so the leg grades every earlier tick's lines and
    # can PASS on stale evidence. A failed boundary read is not a smaller
    # slice, it is the wrong one.
    lines="$(bx "wc -l < ~/duty/duty.log")" || lines=""
    lines="${lines//[[:space:]]/}"
    case "$lines" in
      ''|*[!0-9]*)
        REHEARSAL_BREAKER_TICK_REASON="the box's duty.log could not be measured"
        return 2 ;;
    esac
    first=$((lines + 1))
    rc=0
    bx '$HOME/duty/bin/tick.sh' || rc=$?
    if ! slice="$(rehearsal_breaker_tick_log "$first")"; then
      REHEARSAL_BREAKER_TICK_REASON="the box's duty.log could not be read back"
      return 2
    fi
    outcome="$(rehearsal_breaker_tick_outcome_from_log "$slice")"
    case "$outcome" in
      ran)
        REHEARSAL_BREAKER_TICK_LOG="$slice"
        return 0 ;;
      failed)
        REHEARSAL_BREAKER_TICK_REASON="the tick logged FAILED (tick.sh rc $rc)"
        return 2 ;;
      silent)
        REHEARSAL_BREAKER_TICK_REASON="the tick wrote no evidence line (tick.sh rc $rc)"
        return 2 ;;
    esac
    if [ "$try" -lt "$REHEARSAL_BREAKER_TICK_TRIES" ]; then
      sleep "$REHEARSAL_BREAKER_TICK_WAIT"
    fi
    try=$((try + 1))
  done
  REHEARSAL_BREAKER_TICK_REASON="$REHEARSAL_BREAKER_TICK_TRIES ticks refused by a held lock"
  return 2
}

# rehearsal_breaker_tick_or_incomplete WHAT — the call site's whole handling of
# an unreachable box, so no site can forget half of it. The caller returns 2,
# FAILS is untouched, and rehearsal.sh's `case` maps that to INCOMPLETE.
rehearsal_breaker_tick_or_incomplete() {
  local what="$1"
  rehearsal_breaker_fire_tick && return 0
  skip "breaker: $what never ran; leg INCOMPLETE"
  rehearsal_breaker_record_reason "$what never ran: $REHEARSAL_BREAKER_TICK_REASON"
  return 2
}

rehearsal_breaker_drill() {
  local repo="$1" issue="$2" role="$3" log_text all_log="" attempt
  local fixture_dir stopped_log="" stopped_ticks=0
  local threshold kind alerts failures_before
  if [ "${REHEARSAL_BREAKER_DRILL:-1}" -eq 0 ]; then
    skip "breaker: terminal lane trip and recovery (--no-breaker-drill)"
    return 0
  fi
  failures_before="${#FAILS[@]}"
  REHEARSAL_BREAKER_REPO="$repo"
  REHEARSAL_BREAKER_ISSUE="$issue"
  rehearsal_breaker_load_installed_facts || return 1
  threshold="$REHEARSAL_BREAKER_THRESHOLD"
  kind="$REHEARSAL_BREAKER_KIND"
  if bx "test ! -e '$REHEARSAL_BREAKER_STATE'"; then
    ok "breaker: $kind lane starts closed for $AGENT"
  else
    fail "breaker: $kind lane starts closed for $AGENT"
    return 1
  fi
  if ! rehearsal_breaker_profile_has_hook bot_session_terminal; then
    skip "breaker: $AGENT profile missing bot_session_terminal; leg INCOMPLETE"
    rehearsal_breaker_record_reason \
      "$AGENT profile missing bot_session_terminal"
    return 2
  fi
  check "breaker: $AGENT profile defines bot_session_terminal_fixture" \
    rehearsal_breaker_profile_has_hook bot_session_terminal_fixture
  if ! rehearsal_breaker_profile_has_hook bot_session_terminal_fixture; then
    return 1
  fi
  check "breaker: $AGENT profile defines bot_session_acted" \
    rehearsal_breaker_profile_has_hook bot_session_acted
  if ! rehearsal_breaker_profile_has_hook bot_session_acted; then
    return 1
  fi
  check "breaker: terminal fixture is classified for $AGENT" \
    rehearsal_breaker_terminal_fixture_is_classified
  rehearsal_breaker_terminal_fixture_is_classified || return 1
  if rehearsal_breaker_install_fixture "$role"; then
    ok "breaker: staged $AGENT CLI installed"
  else
    fail "breaker: staged $AGENT CLI installed"
    return 1
  fi
  fixture_dir="$REHEARSAL_BREAKER_DIR"
  if rehearsal_breaker_arm_fixture "$repo" "$issue" "$REHEARSAL_BREAKER_LABEL"; then
    ok "breaker: $kind lane fixture armed"
  else
    fail "breaker: $kind lane fixture armed"
    echo "  read: $REHEARSAL_BREAKER_ARM_READING"
    return 1
  fi

  attempt=1
  while [ "$attempt" -le "$threshold" ]; do
    rehearsal_breaker_tick_or_incomplete "terminal dispatch $attempt" || return 2
    log_text="$REHEARSAL_BREAKER_TICK_LOG"
    all_log="$all_log${all_log:+$'\n'}$log_text"
    if [ "$attempt" -lt "$threshold" ]; then
      check "breaker: terminal dispatch $attempt remains below installed threshold" \
        rehearsal_breaker_below_threshold_from_log "$kind" "$log_text"
    fi
    attempt=$((attempt + 1))
  done
  check "breaker: lane trips once at installed threshold for $AGENT" \
    rehearsal_breaker_trip_from_log "$kind" "$threshold" "$all_log"

  while [ "$stopped_ticks" -lt 2 ]; do
    rehearsal_breaker_tick_or_incomplete \
      "stopped-lane tick $((stopped_ticks + 1))" || return 2
    log_text="$REHEARSAL_BREAKER_TICK_LOG"
    stopped_log="$stopped_log${stopped_log:+$'\n'}$log_text"
    stopped_ticks=$((stopped_ticks + 1))
  done
  check "breaker: following ticks skip the stopped lane" \
    rehearsal_breaker_suppressed_from_log \
      "$kind" "$threshold" "$stopped_ticks" "$stopped_log"
  alerts="$(bx "cat '$REHEARSAL_BREAKER_DIR/alerts.log' 2>/dev/null || true")"
  check "breaker: $kind operator alert emitted exactly once while stopped" \
    rehearsal_breaker_alert_count_is_one "$kind" "$alerts"

  if rehearsal_breaker_restore_cli_for_recovery; then
    ok "breaker: real $AGENT CLI restored"
  else
    fail "breaker: real $AGENT CLI restored"
    return 1
  fi
  rehearsal_breaker_tick_or_incomplete "recovery tick" || return 2
  log_text="$REHEARSAL_BREAKER_TICK_LOG"
  check "breaker: later tick recovers and launches a session" \
    rehearsal_breaker_recovered_from_log "$kind" "$log_text"
  wait_for_lane ATTENTION "breaker: $REHEARSAL_BREAKER_LABEL label removed after recovered session" \
    rehearsal_breaker_attention_is_clear "$repo" "$issue" \
      "$REHEARSAL_BREAKER_LABEL"
  check "breaker: state is cleared after recovery" bx "test ! -e '$REHEARSAL_BREAKER_STATE'"
  if rehearsal_breaker_restore_cli; then
    ok "breaker: recovery alert interceptor removed"
  else
    fail "breaker: recovery alert interceptor removed"
    return 1
  fi
  check "breaker: teardown leaves no staged CLI" bx "test ! -e '$fixture_dir'"
  check "breaker: teardown restores the role profile" \
    rehearsal_breaker_profile_is_restored
  if [ "${#FAILS[@]}" -gt "$failures_before" ]; then return 1; fi
}
