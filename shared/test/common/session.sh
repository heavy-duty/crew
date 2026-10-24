#!/usr/bin/env bash
# shared/test/common/session.sh — standalone suite for shared/lib/common/session.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

# --- session action telemetry is best-effort and additive (#256) ----------
SA_LOG="$TMP/session-action.log"
printf 'OpenAI Codex\nfinal answer: Please connect a plugin.\n' >"$SA_LOG"
t session-hookless-is-unknown unknown "$(session_acted "$SA_LOG")"
t session-reply-tail-captured 'final answer: Please connect a plugin.' \
  "$(session_reply_tail "$SA_LOG" | base64 -d)"

codex_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/codex.conf"
  bot_session_acted "$SA_LOG" && printf yes || printf no
}
t session-codex-no-tool-is-no no "$(codex_acted)"
printf 'OpenAI Codex\nexec\n/bin/bash -lc git status\nfinal answer: done\n' >"$SA_LOG"
t session-codex-exec-is-yes yes "$(codex_acted)"

claude_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  session_acted "$SA_LOG"
}
printf 'Claude Code\nfinal answer: I need more information.\n' >"$SA_LOG"
t session-claude-print-log-is-unknown unknown "$(claude_acted)"

# The transcript classifier is profile-owned: its id/cwd inputs name one
# artifact without discovery, and its three answers keep missing or malformed
# vendor state distinct from a valid transcript with no tool use (#723).
claude_cli_transcript_dir() { # DIR
  local cwd
  cwd="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  # shellcheck disable=SC2001  # independent oracle for the profile expansion
  printf '%s/.claude/projects/%s' "$HOME" \
    "$(sed 's/[^A-Za-z0-9-]/-/g' <<<"$cwd")"
}

claude_productive_fixture() ( # MODE
  local mode="$1" dir="$TMP/claude_productive.dot dir/work" sid transcript_dir
  sid=01a06ef6-ca2a-7fd0-a487-25913257471d
  HOME="$TMP/claude-productive-home"; export HOME
  mkdir -p "$dir"
  transcript_dir="$(claude_cli_transcript_dir "$dir")" || return 2
  mkdir -p "$transcript_dir"
  rm -f "$transcript_dir/$sid.jsonl"
  case "$mode" in
    tool)
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' \
        >"$transcript_dir/$sid.jsonl" ;;
    idle)
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"waiting"}]}}' \
        >"$transcript_dir/$sid.jsonl" ;;
    malformed)
      printf '%s\n' '{not-json' \
        >"$transcript_dir/$sid.jsonl" ;;
    absent) : ;;
    invalid) sid='../another-session' ;;
    uppercase)
      sid=01A06EF6-CA2A-7FD0-A487-25913257471D
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' \
        >"$transcript_dir/$sid.jsonl" ;;
  esac
  # shellcheck disable=SC1091  # production profile under test
  source "$SHARED/conf/agents/claude.conf"
  bot_session_productive "$sid" "$dir" && rc=0 || rc=$?
  case "$rc" in 0) printf yes ;; 1) printf no ;; *) printf unknown ;; esac
)
t session-claude-transcript-tool-use-is-productive yes \
  "$(claude_productive_fixture tool)"
t session-claude-transcript-without-tool-use-is-idle no \
  "$(claude_productive_fixture idle)"
t session-claude-missing-transcript-is-unknown unknown \
  "$(claude_productive_fixture absent)"
t session-claude-malformed-transcript-is-unknown unknown \
  "$(claude_productive_fixture malformed)"
t session-claude-invalid-transcript-id-is-unknown unknown \
  "$(claude_productive_fixture invalid)"
t session-claude-uppercase-transcript-id-is-valid yes \
  "$(claude_productive_fixture uppercase)"

# Exercise run_session itself so a helper-only implementation cannot pass.
SA_WORK="$TMP/session-work"; mkdir -p "$SA_WORK"
BOT_CLI_CMD=(bash -c 'printf "exec\ncommand output\nfinal reply\n"')
# shellcheck disable=SC2317  # invoked indirectly by session_acted
bot_session_acted() { grep -qx exec "$1"; }
sa_end="$(run_session build fixture/test "$SA_WORK" 5 prompt | tail -1)"
case "$sa_end" in
  *'outcome=ok acted=yes reply_tail='*) r1=present ;;
  *) r1=MISSING ;;
esac
t session-end-fields-written present "$r1"
t session-end-outcome-token-unchanged ok \
  "$(printf '%s\n' "$sa_end" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p')"
unset -f bot_session_acted

# --- completion evidence: log bytes and surviving processes (#529) --------
#
# Each case drives run_session, because a helper-only test could pass while the
# dispatch forgot to export its stamp or the SESSION END emitter misplaced the
# fields ahead of reply_tail. The two timeout fixtures distinguish the process
# group timeout owns from one descendant that deliberately escapes with setsid.
session_evidence_run() ( # session_evidence_run KEY TMO PROC_ROOT COMMAND...
  local key="$1" tmo="$2" proc_root="$3"; shift 3
  local edir="$TMP/evidence-$key"
  mkdir -p "$edir/logs" "$edir/work"
  DUTY_DIR="$edir"; LOG_DIR="$edir/logs"; DUTY_TICK_ID="tick-evidence"
  SESSION_PROC_ROOT="$proc_root"
  BOT_CLI_CMD=("$@")
  alert() { :; }
  run_session build "fixture/$key" "$edir/work" "$tmo" prompt
  local run_rc=$?
  printf 'returned=%s rc=%s\n' "$run_rc" "$RUN_SESSION_RC"
)

session_end_value() { # session_end_value FIELD OUTPUT
  sed -n "/SESSION END /s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"
}

evidence_empty="$(session_evidence_run empty 5 /proc bash -c : 2>&1)"
t session-evidence-empty-log-is-zero 0 "$(session_end_value log "$evidence_empty")"
t session-evidence-ordinary-session-leaves-zero 0 "$(session_end_value left "$evidence_empty")"

evidence_output="$(session_evidence_run output 5 /proc bash -c 'printf 12345' 2>&1)"
t session-evidence-output-log-has-true-size 5 "$(session_end_value log "$evidence_output")"

evidence_group="$(session_evidence_run group 1 /proc \
  bash -c 'sleep 30 & wait' 2>&1)"
t session-evidence-timeout-reaps-in-group-child 0 \
  "$(session_end_value left "$evidence_group")"

LEFT_PID_FILE="$TMP/session-left-pid"
export LEFT_PID_FILE
# shellcheck disable=SC2016  # expanded by the nested fixture shell
evidence_escape="$(session_evidence_run escape 1 /proc bash -c \
  'setsid bash -c '\''printf "%s\n" "$$" >"$LEFT_PID_FILE"; exec sleep 30'\'' & wait' \
  2>&1)"
t session-evidence-setsid-child-survives 1 \
  "$(session_end_value left "$evidence_escape")"
if [ -s "$LEFT_PID_FILE" ]; then
  kill "$(cat "$LEFT_PID_FILE")" 2>/dev/null || true
fi

evidence_noproc="$(session_evidence_run no-proc 5 "$TMP/no-such-proc" \
  bash -c 'exit 3' 2>&1)"
t session-evidence-missing-proc-is-unknown unknown \
  "$(session_end_value left "$evidence_noproc")"
t session-evidence-missing-proc-keeps-verdict '3|FAILED' \
  "$(sed -n 's/.*SESSION END .* rc=\([^ ]*\) dur=[^ ]* outcome=\([^ ]*\).*/\1|\2/p' \
    <<<"$evidence_noproc")"
t session-evidence-missing-proc-cannot-fail-run-session 'returned=0 rc=3' \
  "$(grep '^returned=' <<<"$evidence_noproc" || true)"

session_left_source="$(awk '/_session_left\(\) \{/{on=1} on{print} on && /^}/{exit}' \
  "$SHARED/lib/common/session.sh")"
case "$session_left_source" in
  *'/environ'* ) r1=environ ;;
  *) r1=NOT-ENVIRON ;;
esac
t session-evidence-count-reads-process-environments environ "$r1"
if grep -Eq 'pgrep|ps[[:space:]]|/cmdline' <<<"$session_left_source"; then
  r1=COMMAND-LINE-MATCH
else
  r1=environment-only
fi
t session-evidence-count-never-matches-command-lines environment-only "$r1"

# Compatibility is asserted against the shipped floor expression itself. The
# old line proves the new floor still reads old boxes; the actual new line
# proves deployed floors retain every pre-existing capture through the suffix.
evidence_end="$(grep 'SESSION END' <<<"$evidence_output")"
t session-evidence-floor-parses-old-and-new-identically same \
  "$(SESSION_EVIDENCE_END="$evidence_end" python3 - \
      "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    match = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, match.group(1)), ns)
new = "2026-08-29T00:00:00Z " + os.environ["SESSION_EVIDENCE_END"]
old = re.sub(r" log=\S+ left=\S+", "", new)
old_groups = ns["RE_END"].search(old).groups()[1:]
new_groups = ns["RE_END"].search(new).groups()[1:]
print("same" if new_groups == old_groups else "CHANGED")
PY
)"

case "$evidence_end" in
  *' reply_tail='*' log=5 left=0 tier='*) r1=appended ;;
  *) r1=NOT-APPENDED ;;
esac
t session-evidence-fields-follow-reply-tail appended "$r1"

# --- the kernel's OOM record, sampled around one dispatch (#600) ----------
oom_counter_run() ( # oom_counter_run KEY BEFORE AFTER RC OUTPUT
  local key="$1" before="$2" after="$3" rc="$4" output="$5"
  local odir="$TMP/oom-counter-$key" events="$TMP/oom-counter-$key.events"
  mkdir -p "$odir/logs" "$odir/work"
  printf 'oom_kill %s\n' "$before" >"$events"
  DUTY_DIR="$odir"; LOG_DIR="$odir/logs"; DUTY_TICK_ID="tick_oom_counter"
  _SESSION_OOM_EVENTS_FILE="$events"
  export OOM_EVENTS="$events" OOM_AFTER="$after" OOM_RC="$rc" OOM_OUTPUT="$output"
  # shellcheck disable=SC2016  # expanded by the nested fixture shell
  BOT_CLI_CMD=(bash -c \
    'printf "%s" "$OOM_OUTPUT"; printf "oom_kill %s\n" "$OOM_AFTER" >"$OOM_EVENTS"; exit "$OOM_RC"')
  # shellcheck disable=SC2317  # invoked indirectly by session_acted
  bot_session_acted() { return 0; }
  bot_session_terminal() { grep -qx 'Execution error' "$1"; }
  # A deterministic peak makes the new field's position assertable without a
  # scheduler race in the real watcher.
  _session_peak_rss_start() { printf '42\n' >"$1"; }
  _session_peak_rss_stop() { :; }
  run_session build "fixture/$key" "$odir/work" 5 prompt
)

oom_dirty="$(oom_counter_run dirty 10 11 124 'partial work' 2>&1)"
t oom-dirty-timeout-is-memory '124|MEMORY|1' \
  "$(sed -n 's/.*SESSION END .* rc=\([^ ]*\).* outcome=\([^ ]*\).* oom=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$oom_dirty")"
oom_clean="$(oom_counter_run clean 20 22 0 'final reply' 2>&1)"
t oom-unrelated-clean-session-stays-ok '0|ok|2' \
  "$(sed -n 's/.*SESSION END .* rc=\([^ ]*\).* outcome=\([^ ]*\).* oom=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$oom_clean")"
oom_none="$(oom_counter_run none 30 30 3 'ordinary failure' 2>&1)"
t oom-unchanged-counter-is-zero '3|FAILED|0' \
  "$(sed -n 's/.*SESSION END .* rc=\([^ ]*\).* outcome=\([^ ]*\).* oom=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$oom_none")"
oom_dirty_end="$(grep 'SESSION END' <<<"$oom_dirty")"
case "$oom_dirty_end" in
  *' peak_rss=42 oom=1 '*) r1=ordered ;;
  *) r1=MISORDERED ;;
esac
t oom-follows-peak-rss ordered "$r1"
t oom-floor-re-end-keeps-existing-captures 'build|yes' \
  "$(OOM_END="$oom_dirty_end" python3 - "$ROOT/fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-09-04T00:00:00Z " + os.environ["OOM_END"])
print("|".join([m.group(2), m.group(7)]) if m else "NO-MATCH")
PY
)"

# The source prefers this process's cgroup-v2 counter and falls back to the
# node-wide vmstat counter when that narrower file is absent.
OOM_SOURCE_ROOT="$TMP/oom-source"
mkdir -p "$OOM_SOURCE_ROOT/proc/self" "$OOM_SOURCE_ROOT/cgroup/unit"
printf '0::/unit\n' >"$OOM_SOURCE_ROOT/proc/self/cgroup"
printf 'oom_kill 7\n' >"$OOM_SOURCE_ROOT/cgroup/unit/memory.events"
printf 'oom_kill 9\n' >"$OOM_SOURCE_ROOT/proc/vmstat"
t oom-source-prefers-current-cgroup "$OOM_SOURCE_ROOT/cgroup/unit/memory.events" \
  "$(SESSION_PROC_ROOT="$OOM_SOURCE_ROOT/proc" _SESSION_CGROUP_ROOT="$OOM_SOURCE_ROOT/cgroup" \
    _session_oom_source)"
rm -f "$OOM_SOURCE_ROOT/cgroup/unit/memory.events"
t oom-source-falls-back-to-vmstat "$OOM_SOURCE_ROOT/proc/vmstat" \
  "$(SESSION_PROC_ROOT="$OOM_SOURCE_ROOT/proc" _SESSION_CGROUP_ROOT="$OOM_SOURCE_ROOT/cgroup" \
    _session_oom_source)"
oom_unreadable_run() (
  local odir="$TMP/oom-unreadable"
  mkdir -p "$odir/logs" "$odir/work" "$odir/proc/self" "$odir/cgroup"
  printf '0::/missing\n' >"$odir/proc/self/cgroup"
  DUTY_DIR="$odir"; LOG_DIR="$odir/logs"; DUTY_TICK_ID=tick_oom_unreadable
  SESSION_PROC_ROOT="$odir/proc"; _SESSION_CGROUP_ROOT="$odir/cgroup"
  BOT_CLI_CMD=(bash -c 'printf "ordinary failure\n"; exit 3')
  # shellcheck disable=SC2317  # invoked indirectly by session_acted
  bot_session_acted() { return 0; }
  _session_peak_rss_start() { :; }
  _session_peak_rss_stop() { :; }
  run_session build fixture/unreadable "$odir/work" 5 prompt
)
t oom-unreadable-counter-is-numeric-unknown '3|FAILED|-' \
  "$(sed -n 's/.*SESSION END .* rc=\([^ ]*\).* outcome=\([^ ]*\).* oom=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$(oom_unreadable_run 2>&1)")"
oom_run_source="$(awk '/^run_session\(\) \{/{on=1} on{print} on && /^}/{exit}' \
  "$SHARED/lib/common/session.sh")"
# shellcheck disable=SC2016  # grep matches the subject's literal variable
t oom-counter-is-sampled-exactly-at-dispatch-and-reap 2 \
  "$(grep -c '_session_oom_count "$oom_source"' <<<"$oom_run_source" || true)"
t oom-accounting-adds-no-fleet-setting 0 \
  "$(grep -c 'SESSION_OOM' "$SHARED/conf/fleet.defaults.conf" || true)"

# --- session identity, and the one resume it buys (#538) -----------------
#
# Every case drives run_session with a stub CLI that records its own argv,
# because the whole claim is about WHAT WAS INVOKED and with WHICH id. A
# helper-only test would let an implementation mint an id, log it on both lines
# and never pin it on the launch — which is the one bug that makes `sid=` a
# fiction rather than a pointer at a transcript.
#
# The stub's shapes are the ones D6 reads: a session that replies, one that
# hangs having said something (a wall-clock kill with context worth resuming),
# one that hangs having said nothing (D6.3), and one that leaves a `setsid`
# escapee behind (D6.4).
SID_CLI="$TMP/sid-cli.sh"
cat >"$SID_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SID_ARGV"
sid=""; previous=""
for argument in "$@"; do
  case "$previous" in --session-id|--resume) sid="$argument" ;; esac
  previous="$argument"
done
sid_tool_transcript() {
  [ -n "${SID_TRANSCRIPT_DIR:-}" ] && [ -n "$sid" ] || return 0
  mkdir -p "$SID_TRANSCRIPT_DIR"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' \
    >"$SID_TRANSCRIPT_DIR/$sid.jsonl"
}
sid_idle_transcript() {
  [ -n "${SID_TRANSCRIPT_DIR:-}" ] && [ -n "$sid" ] || return 0
  mkdir -p "$SID_TRANSCRIPT_DIR"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"waiting"}]}}' \
    >"$SID_TRANSCRIPT_DIR/$sid.jsonl"
}
case "${SID_SHAPE:-reply}" in
  reply) printf 'final reply\n' ;;
  fail) printf 'final reply\n'; exit 3 ;;
  oom-progress)
    printf 'partial work\n'
    printf 'oom_kill %s\n' "$(( $(awk '$1 == "oom_kill" { print $2 }' "$SID_OOM_EVENTS") + 1 ))" \
      >"$SID_OOM_EVENTS"
    exit 124
    ;;
  oom-error)
    printf 'Execution error'
    printf 'oom_kill %s\n' "$(( $(awk '$1 == "oom_kill" { print $2 }' "$SID_OOM_EVENTS") + 1 ))" \
      >"$SID_OOM_EVENTS"
    exit 124
    ;;
  oom-terminal)
    printf "%s\n" "You've hit your weekly limit · resets 9am (UTC)"
    printf 'oom_kill %s\n' "$(( $(awk '$1 == "oom_kill" { print $2 }' "$SID_OOM_EVENTS") + 1 ))" \
      >"$SID_OOM_EVENTS"
    exit 137
    ;;
  mute-hang) exec sleep 30 ;;
  talk-hang) printf 'partial work\n'; exec sleep 30 ;;
  mute-tool-hang) sid_tool_transcript; exec sleep 30 ;;
  error-tool-hang) sid_tool_transcript; printf 'Execution error'; exec sleep 30 ;;
  mute-idle-hang) sid_idle_transcript; exec sleep 30 ;;
  terminal)
    printf "%s\n" "You've hit your weekly limit · resets 9am (UTC)"
    exit 1
    ;;
  escape-hang)
    printf 'partial work\n'
    setsid bash -c 'printf "%s\n" "$$" >"$SID_ESCAPEE"; exec sleep 30' &
    wait
    ;;
esac
STUB
chmod +x "$SID_CLI"

# sid_box BOX — a per-case box directory whose work tree is a real repository,
# so `_session_head` has a head to read and D6.2 has something to compare.
sid_box() {
  local sdir="$TMP/sid-$1"
  [ -d "$sdir/work_dir.dot space/.git" ] && { printf '%s' "$sdir"; return 0; }
  mkdir -p "$sdir/logs" "$sdir/work_dir.dot space"
  git -C "$sdir/work_dir.dot space" init -q 2>/dev/null
  git -C "$sdir/work_dir.dot space" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m one 2>/dev/null
  printf '%s' "$sdir"
}

# sid_commit DIR — move the head, for D6.2's "the world changed" case.
sid_commit() {
  git -C "$1" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m next 2>/dev/null
}

# sid_run BOX KEY TMO SHAPE [HOOKS] [WORK] [KIND] — one dispatch into BOX,
# with the profile hooks D2 lets a CLI carry independently.
#
#   both      a profile that can pin and resume — `claude`'s shape
#   claude    the shipped claude profile, including both classifiers
#   pin-only  a CLI that can pin an id and cannot continue one (D6.6)
#   observed  a CLI that emits an id after launch and resumes through a
#             whole-command hook, Codex's #673 shape
#   observed-missing / observed-malformed
#             provider observations that must fail closed
#   none      a profile with neither hook — the pre-#538 lane, unchanged
#   refusing  hooks that are defined and render nothing, the contract
#             `bot_cli_structured_cmd` already has
#
# A subshell, so each case's hooks, exports and DUTY_DIR die with it; the box
# directory itself persists across calls, which is what lets a timeout in one
# call be resumed by the next.
sid_run() (
  local box="$1" key="$2" tmo="$3" shape="$4" hooks="${5:-both}" work="${6:-}"
  local kind="${7:-build}"
  local sdir; sdir="$(sid_box "$box")"
  DUTY_DIR="$sdir"; LOG_DIR="$sdir/logs"; DUTY_TICK_ID="tick-sid"
  unset -f bot_session_acted bot_session_terminal bot_session_productive
  if [ "$hooks" = claude ]; then
    HOME="$sdir/home"; export HOME
    # shellcheck disable=SC1091  # production profile under test
    source "$SHARED/conf/agents/claude.conf"
  fi
  BOT_CLI_CMD=(bash "$SID_CLI" -p)
  work="${work:-$sdir/work_dir.dot space}"
  export SID_ARGV="$sdir/argv" SID_SHAPE="$shape" SID_ESCAPEE="$sdir/escapee"
  SID_TRANSCRIPT_DIR="$(claude_cli_transcript_dir "$work")" || return 2
  export SID_TRANSCRIPT_DIR
  [ -e "$sdir/memory.events" ] || printf 'oom_kill 0\n' >"$sdir/memory.events"
  export SID_OOM_EVENTS="$sdir/memory.events"
  _SESSION_OOM_EVENTS_FILE="$sdir/memory.events"
  # shellcheck disable=SC1090  # test-selected mutated copy of the subject
  [ -z "${SID_SESSION_MUTANT:-}" ] || source "$SID_SESSION_MUTANT"
  alert() { :; }
  if [ "$hooks" != claude ]; then
    # shellcheck disable=SC2317  # invoked indirectly by session_acted
    bot_session_acted() { grep -qx 'partial work' "$1"; }
    bot_session_terminal() { grep -qx 'Execution error' "$1"; }
  fi
  case "$hooks" in
    both)
      bot_cli_session_id_args() { BOT_CLI_SESSION_ID_ARGS=(--session-id "$1"); }
      bot_cli_resume_args() { BOT_CLI_RESUME_ARGS=(--resume "$1"); } ;;
    pin-only)
      bot_cli_session_id_args() { BOT_CLI_SESSION_ID_ARGS=(--session-id "$1"); } ;;
    observed | observed-missing | observed-malformed)
      bot_cli_observed_session_id() {
        case "$hooks" in
          observed) printf '%s' '01a06ef6-ca2a-7fd0-a487-25913257471d' ;;
          observed-malformed) printf '%s' '------------------------------------' ;;
          observed-missing) return 1 ;;
        esac
      }
      bot_cli_resume_cmd() {
        local sid="${!#}"
        local -a base=("${@:1:$#-1}")
        local last=$(( ${#base[@]} - 1 ))
        [ "$last" -ge 0 ] && [ "${base[last]}" = -p ] || return 1
        BOT_CLI_RESUME_CMD=("${base[@]:0:last}" --resume "$sid" -p)
      } ;;
    refusing)
      bot_cli_session_id_args() { BOT_CLI_SESSION_ID_ARGS=(); return 1; }
      bot_cli_resume_args() { BOT_CLI_RESUME_ARGS=(); return 1; } ;;
    claude | none) : ;;
  esac
  rm -f "$sdir/argv"
  # `log` writes to stdout, so the box's own record file is where the two lines
  # accumulate across dispatches — appended, because a resume is only readable
  # beside the timeout it continues.
  run_session "$kind" "$key" "$work" "$tmo" prompt >>"$sdir/records" 2>&1
  printf 'returned=%s rc=%s\n' "$?" "$RUN_SESSION_RC"
  printf -- '--argv--\n'
  cat "$sdir/argv" 2>/dev/null
)

sid_mutant() { # sid_mutant NAME SED-EXPR
  local out="$TMP/session-sid-mutant-$1.sh"
  sed "$2" "$SHARED/lib/common/session.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/session.sh"; then
    t "sid-mutation-$1-applies" applied INERT
  else
    t "sid-mutation-$1-applies" applied applied
  fi
}

# The record the LAST dispatch into this box wrote.
sid_line() { # sid_line BOX RECORD
  grep " SESSION $2 " "$TMP/sid-$1/records" 2>/dev/null | tail -1
}
sid_of() { # sid_of BOX RECORD — the sid token, or nothing
  sed -n 's/.* sid=\([^ ]*\).*/\1/p' <<<"$(sid_line "$1" "$2")"
}
# sid_shape VALUE — uuid | unknown | OTHER(<value>). The glob pins the four
# dashes by position, and the alphabet check then reads ONLY the positions the
# glob left free. Folding `[0-9a-f-]` over the whole value — what this helper
# did — calls `------------------------------------` a `uuid`, which is the
# same classification `_session_sid_valid` was making, so a suite built on this
# helper could not see the validator's own hole (#596 review).
sid_shape() {
  case "$1" in
    unknown) printf unknown ;;
    ????????-????-????-????-????????????)
      case "${1:0:8}${1:9:4}${1:14:4}${1:19:4}${1:24:12}" in
        *[!0-9a-f]*) printf 'OTHER(%s)' "$1" ;; *) printf uuid ;;
      esac ;;
    *) printf 'OTHER(%s)' "$1" ;;
  esac
}
# sid_valid_says VALUE — ACCEPT | reject, straight off the shipped validator.
# The stub cases below read the classification through a whole dispatch, which
# is the behaviour that matters; this reads the guard itself, so a hole is
# named where it lives as well as where it is felt.
sid_valid_says() {
  _session_sid_valid "$1" && printf ACCEPT || printf reject
  return 0
}
# sid_same A B — same | DIFFERENT | EMPTY. The third answer is the point of the
# helper: every identity assertion below compares two values that are both
# ABSENT on a tree without this change, and a bare `[ "$a" = "$b" ]` reports
# `same` for two empty strings. That is a test which passes against the code it
# was written to require, so emptiness is named rather than compared.
sid_same() {
  [ -n "$1" ] || { printf EMPTY; return 0; }
  [ "$1" = "$2" ] && printf same || printf DIFFERENT
  return 0
}
sid_stub() { printf '%s/.session-resume.build.%s' "$TMP/sid-$1" "$2"; }
sid_stub_kind() { printf '%s/.session-resume.%s.%s' "$TMP/sid-$1" "$2" "$3"; }
sid_stub_field() { # sid_stub_field FILE KEY
  sed -n "s/^$2=//p" "$1" 2>/dev/null
}
sid_argv_flag() { # sid_argv_flag OUTPUT FLAG — the value following FLAG, or nothing
  sed -n "/^--argv--$/,\$p" <<<"$1" | grep -A1 -Fx -- "$2" | tail -1
}

# --- the id itself: minted, pinned, and the same on both lines ------------
sid_pinned="$(sid_run pinned fixture/pin 5 reply both)"
t sid-start-carries-a-minted-uuid uuid "$(sid_shape "$(sid_of pinned START)")"
t sid-end-carries-the-same-id-as-start same \
  "$(sid_same "$(sid_of pinned START)" "$(sid_of pinned END)")"
t sid-is-the-last-token-on-start 1 \
  "$(grep -c ' sid=[^ ]*$' <<<"$(sid_line pinned START)" || true)"
t sid-is-the-last-token-on-end 1 \
  "$(grep -c ' sid=[^ ]*$' <<<"$(sid_line pinned END)" || true)"
# The pin is on the LAUNCH and not only in the log, which is the whole of D1.
t sid-the-launch-carries-the-id-the-record-names same \
  "$(sid_same "$(sid_argv_flag "$sid_pinned" --session-id)" "$(sid_of pinned START)")"

# D2's neutral answer, both halves: no hook, no pin, `sid=unknown`, and a
# session otherwise unchanged — the argv is the profile's own array.
sid_hookless="$(sid_run hookless fixture/hookless 5 reply none)"
t sid-hookless-profile-reports-unknown unknown "$(sid_shape "$(sid_of hookless START)")"
t sid-hookless-profile-pins-nothing 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_hookless" | grep -c -- '--session-id' || true)"
t sid-hookless-profile-keeps-its-invocation prompt \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_hookless" | tail -1)"

# A hook that is defined and renders nothing leaves the invocation alone and
# says `unknown` rather than claiming an id nothing on disk is keyed by.
sid_refusing="$(sid_run refusing fixture/refusing 5 reply refusing)"
t sid-refusing-hook-reports-unknown unknown "$(sid_shape "$(sid_of refusing START)")"
t sid-refusing-hook-pins-nothing 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_refusing" | grep -c -- '--session-id' || true)"

# Codex cannot accept an engine-minted id on a fresh invocation. Its observed
# id therefore belongs in the resume stub but not on either fresh record.
sid_observed_fresh="$(sid_run observed-fresh fixture/observed-fresh 5 reply observed)"
t sid-observed-fresh-start-stays-unknown unknown \
  "$(sid_of observed-fresh START)"
t sid-observed-fresh-end-stays-unknown unknown \
  "$(sid_of observed-fresh END)"
t sid-observed-fresh-invocation-is-not-pinned 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_observed_fresh" \
    | grep -Ec -- '--session-id|--resume' || true)"

sid_run observed fixture/observed 1 talk-hang observed >/dev/null
SID_OBSERVED_STUB="$(sid_stub observed fixture_observed)"
SID_OBSERVED_KILLED='01a06ef6-ca2a-7fd0-a487-25913257471d'
t sid-observed-timeout-writes-a-stub present \
  "$([ -s "$SID_OBSERVED_STUB" ] && printf present || printf MISSING)"
t sid-observed-stub-carries-provider-id "$SID_OBSERVED_KILLED" \
  "$(sid_stub_field "$SID_OBSERVED_STUB" sid)"
sid_observed_resumed="$(sid_run observed fixture/observed 5 reply observed)"
t sid-observed-whole-command-resumes-the-killed-thread same \
  "$(sid_same \
    "$(sid_argv_flag "$sid_observed_resumed" --resume)" "$SID_OBSERVED_KILLED")"
t sid-observed-resume-start-carries-provider-id "$SID_OBSERVED_KILLED" \
  "$(sid_of observed START)"
t sid-observed-resume-end-carries-provider-id "$SID_OBSERVED_KILLED" \
  "$(sid_of observed END)"
t sid-observed-resume-consumes-its-stub gone \
  "$([ -e "$SID_OBSERVED_STUB" ] && printf PRESENT || printf gone)"

sid_run observed-missing fixture/observed-missing 1 talk-hang observed-missing >/dev/null
t sid-missing-observed-id-writes-no-stub gone \
  "$([ -e "$(sid_stub observed-missing fixture_observed-missing)" ] \
    && printf PRESENT || printf gone)"
sid_run observed-malformed fixture/observed-malformed 1 talk-hang observed-malformed >/dev/null
t sid-malformed-observed-id-writes-no-stub gone \
  "$([ -e "$(sid_stub observed-malformed fixture_observed-malformed)" ] \
    && printf PRESENT || printf gone)"

# --- the stub: written on 124, and on nothing else (D5) ------------------
sid_run timeout fixture/tmo 1 talk-hang both >/dev/null
SID_TMO_STUB="$(sid_stub timeout fixture_tmo)"
t sid-timeout-writes-a-stub present \
  "$([ -s "$SID_TMO_STUB" ] && printf present || printf MISSING)"
t sid-stub-carries-the-killed-session-id same \
  "$(sid_same "$(sid_stub_field "$SID_TMO_STUB" sid)" "$(sid_of timeout START)")"
t sid-stub-carries-the-head-it-worked-at "$(git -C "$TMP/sid-timeout/work_dir.dot space" rev-parse HEAD)" \
  "$(sid_stub_field "$SID_TMO_STUB" head)"
t sid-stub-carries-the-wall-that-was-hit 1 "$(sid_stub_field "$SID_TMO_STUB" wall)"
t sid-stub-carries-a-try-count 0 "$(sid_stub_field "$SID_TMO_STUB" try)"
t sid-stub-outcome-is-the-timeout TIMEOUT \
  "$(sed -n 's/.* outcome=\([^ ]*\).*/\1/p' <<<"$(sid_line timeout END)")"

# An ordinary end writes none, and DELETES the one a previous timeout left —
# which is what stops a stub outliving the episode that produced it.
t sid-ok-session-deletes-the-stub gone \
  "$(sid_run timeout fixture/tmo 5 reply both >/dev/null
     [ -e "$SID_TMO_STUB" ] && printf PRESENT || printf gone)"
sid_run plain fixture/plain 5 reply both >/dev/null
t sid-ok-session-writes-no-stub gone \
  "$([ -e "$(sid_stub plain fixture_plain)" ] && printf PRESENT || printf gone)"
sid_run failed fixture/failed 5 fail both >/dev/null
t sid-failed-session-writes-no-stub gone \
  "$([ -e "$(sid_stub failed fixture_failed)" ] && printf PRESENT || printf gone)"

# --- the resume, end to end (D6) -----------------------------------------
sid_run resume fixture/res 1 talk-hang both >/dev/null
SID_KILLED="$(sid_of resume START)"
sid_resumed="$(sid_run resume fixture/res 5 reply both)"
t sid-resume-continues-the-killed-session same \
  "$(sid_same "$(sid_argv_flag "$sid_resumed" --resume)" "$SID_KILLED")"
t sid-resumed-session-reports-the-killed-id same \
  "$(sid_same "$(sid_of resume START)" "$SID_KILLED")"
# A resume carries --resume and NOT --session-id: measured on the claude CLI,
# re-pinning an existing id fails the session at rc=1 (claude.conf, #538 D2).
t sid-resume-does-not-also-pin-the-id 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_resumed" | grep -c -- '--session-id' || true)"
t sid-resume-consumes-its-stub gone \
  "$([ -e "$(sid_stub resume fixture_res)" ] && printf PRESENT || printf gone)"
t sid-timeout-resume-names-the-wall-clock-cause 1 \
  "$(grep -c 'previous attempt reached its wall-clock limit' <<<"$sid_resumed" || true)"

# A killed Claude session's final reply is precisely the artifact that cannot
# be trusted to exist. The profile's addressable JSONL transcript therefore
# outranks both an empty log and the observed 15-byte error banner when it
# carries tool use (#723). These are full dispatch/resume paths, not hook-only
# classifications, and the inverse assertion pins acted=unknown alongside
# productive=yes on the same end.
sid_run transcript-empty fixture/transcript-empty 1 mute-tool-hang claude '' review >/dev/null
SID_TRANSCRIPT_EMPTY="$(sid_of transcript-empty START)"
SID_TRANSCRIPT_EMPTY_STUB="$(sid_stub_kind transcript-empty review fixture_transcript-empty)"
t sid-empty-log-tool-transcript-records-productive yes \
  "$(sid_stub_field "$SID_TRANSCRIPT_EMPTY_STUB" productive)"
t sid-empty-log-fixture-is-zero-bytes 0 \
  "$(sid_stub_field "$SID_TRANSCRIPT_EMPTY_STUB" log)"
t sid-empty-log-stays-action-unknown 1 \
  "$(grep -c 'acted=unknown' <<<"$(sid_line transcript-empty END)" || true)"
sid_transcript_empty_resumed="$(sid_run transcript-empty fixture/transcript-empty 5 reply claude '' review)"
t sid-empty-log-tool-transcript-resumes-the-same-session same \
  "$(sid_same "$(sid_argv_flag "$sid_transcript_empty_resumed" --resume)" \
    "$SID_TRANSCRIPT_EMPTY")"

sid_run transcript-error fixture/transcript-error 1 error-tool-hang claude >/dev/null
SID_TRANSCRIPT_ERROR="$(sid_of transcript-error START)"
SID_TRANSCRIPT_ERROR_STUB="$(sid_stub transcript-error fixture_transcript-error)"
t sid-error-banner-tool-transcript-records-productive yes \
  "$(sid_stub_field "$SID_TRANSCRIPT_ERROR_STUB" productive)"
t sid-error-banner-fixture-is-fifteen-bytes 15 \
  "$(sid_stub_field "$SID_TRANSCRIPT_ERROR_STUB" log)"
t sid-error-banner-stays-action-unknown 1 \
  "$(grep -c 'acted=unknown' <<<"$(sid_line transcript-error END)" || true)"
sid_transcript_error_resumed="$(sid_run transcript-error fixture/transcript-error 5 reply claude)"
t sid-error-banner-tool-transcript-resumes-the-same-session same \
  "$(sid_same "$(sid_argv_flag "$sid_transcript_error_resumed" --resume)" \
    "$SID_TRANSCRIPT_ERROR")"

# The third archived-log shape is the second observed 15-byte banner. Keeping
# it as an independent dispatch guards against accidentally keying productivity
# to a previous lane's artifact rather than this session id.
sid_run transcript-error-two fixture/transcript-error-two 1 error-tool-hang claude >/dev/null
t sid-third-archived-log-shape-records-productive yes \
  "$(sid_stub_field "$(sid_stub transcript-error-two fixture_transcript-error-two)" productive)"
t sid-third-archived-log-fixture-is-fifteen-bytes 15 \
  "$(sid_stub_field "$(sid_stub transcript-error-two fixture_transcript-error-two)" log)"

sid_run transcript-idle fixture/transcript-idle 1 mute-idle-hang claude >/dev/null
sid_transcript_idle_killed="$(sid_of transcript-idle START)"
t sid-no-tool-transcript-records-unproductive no \
  "$(sid_stub_field "$(sid_stub transcript-idle fixture_transcript-idle)" productive)"
sid_transcript_idle_next="$(sid_run transcript-idle fixture/transcript-idle 5 reply claude)"
t sid-no-tool-transcript-does-not-resume 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_transcript_idle_next" \
    | grep -c -- '--resume' || true)"
t sid-no-tool-transcript-starts-a-fresh-session DIFFERENT \
  "$(sid_same "$(sid_of transcript-idle START)" "$sid_transcript_idle_killed")"

sid_run transcript-absent fixture/transcript-absent 1 mute-hang claude >/dev/null
sid_transcript_absent_killed="$(sid_of transcript-absent START)"
t sid-missing-transcript-falls-back-to-unproductive no \
  "$(sid_stub_field "$(sid_stub transcript-absent fixture_transcript-absent)" productive)"
sid_transcript_absent_next="$(sid_run transcript-absent fixture/transcript-absent 5 reply claude)"
t sid-missing-transcript-does-not-resume 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_transcript_absent_next" \
    | grep -c -- '--resume' || true)"
t sid-missing-transcript-starts-a-fresh-session DIFFERENT \
  "$(sid_same "$(sid_of transcript-absent START)" "$sid_transcript_absent_killed")"

sid_run transcript-terminal fixture/transcript-terminal 5 terminal claude >/dev/null
t sid-non-timeout-terminal-stays-terminal TERMINAL \
  "$(sed -n 's/.* outcome=\([^ ]*\).*/\1/p' <<<"$(sid_line transcript-terminal END)")"
t sid-non-timeout-terminal-writes-no-resume-stub gone \
  "$([ -e "$(sid_stub transcript-terminal fixture_transcript-terminal)" ] \
    && printf PRESENT || printf gone)"

# A kernel memory kill buys the same one resume, but the prompt makes the
# continuation informed: it names the cause and forbids replaying the suspect
# last command before handing the lane's original prompt back to it.
sid_run memresume fixture/memresume 5 oom-progress both >/dev/null
SID_MEMORY_KILLED="$(sid_of memresume START)"
SID_MEMORY_STUB="$(sid_stub memresume fixture_memresume)"
t sid-memory-kill-is-recorded '124|MEMORY|1' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).* oom=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$(sid_line memresume END)")"
t sid-memory-kill-writes-a-stub present \
  "$([ -s "$SID_MEMORY_STUB" ] && printf present || printf MISSING)"
t sid-memory-stub-carries-cause MEMORY "$(sid_stub_field "$SID_MEMORY_STUB" outcome)"
t sid-memory-stub-records-productive-log yes \
  "$(sid_stub_field "$SID_MEMORY_STUB" productive)"
sid_memory_resumed="$(sid_run memresume fixture/memresume 5 reply both)"
t sid-memory-resume-continues-the-killed-session same \
  "$(sid_same "$(sid_argv_flag "$sid_memory_resumed" --resume)" "$SID_MEMORY_KILLED")"
t sid-memory-resume-names-oom-cause 1 \
  "$(grep -c 'previous attempt was terminated because this box ran out of memory' \
    <<<"$sid_memory_resumed" || true)"
t sid-memory-resume-forbids-the-suspect-command 1 \
  "$(grep -c 'do not run it again' <<<"$sid_memory_resumed" || true)"
t sid-memory-resume-keeps-the-original-prompt 1 \
  "$(grep -c '^prompt$' <<<"$sid_memory_resumed" || true)"

# MUST FAIL: restoring the old non-empty byte test admits the real 15-byte
# error body, and dropping the informed preamble hides why the resume exists.
# shellcheck disable=SC2016  # sed matches the subject's literal variables
sid_mutant nonempty-log \
  's/^  \[ "$productive" = yes \] || return 0$/  [ "$logb" != unknown ] \&\& [ "$logb" -gt 0 ] || return 0/'
sid_run memerror-mut fixture/memerror-mut 5 oom-error both >/dev/null
sid_error_mut_killed="$(sid_of memerror-mut START)"
sid_error_mut_resumed="$(SID_SESSION_MUTANT="$TMP/session-sid-mutant-nonempty-log.sh" \
  sid_run memerror-mut fixture/memerror-mut 5 reply both)"
t sid-mutation-nonempty-log-wrongly-resumes-the-error RESUMED \
  "$([ "$(sid_argv_flag "$sid_error_mut_resumed" --resume)" = "$sid_error_mut_killed" ] \
    && printf RESUMED || printf ordinary)"

sid_mutant no-preamble \
  's/^    resume_preamble=.*$/    resume_preamble=""/'
sid_run memprompt-mut fixture/memprompt-mut 5 oom-progress both >/dev/null
sid_prompt_mut="$(SID_SESSION_MUTANT="$TMP/session-sid-mutant-no-preamble.sh" \
  sid_run memprompt-mut fixture/memprompt-mut 5 reply both)"
t sid-mutation-dropping-preamble-hides-the-cause 0 \
  "$(grep -c 'previous attempt was terminated because this box ran out of memory' \
    <<<"$sid_prompt_mut" || true)"

# The landed #538 guard admitted only rc=124 + TIMEOUT. Restoring it must drop
# the memory stub even though the kernel evidence resolved the outcome.
# shellcheck disable=SC2016  # sed matches the subject's literal variables
sid_mutant timeout-only \
  's/^  if ! _session_resume_admitted "$rc" "$verdict"; then$/  if [ "$rc" -ne 124 ] || [ "$verdict" != TIMEOUT ]; then/'
SID_SESSION_MUTANT="$TMP/session-sid-mutant-timeout-only.sh" \
  sid_run memguard-mut fixture/memguard-mut 5 oom-progress both >/dev/null
t sid-mutation-timeout-only-drops-the-memory-stub MISSING \
  "$([ -s "$(sid_stub memguard-mut fixture_memguard-mut)" ] \
    && printf present || printf MISSING)"

# --- the six refusals, one case each (D6) --------------------------------
#
# Each drives a real timeout, changes exactly one of the six facts, and then
# dispatches again. The assertion is the same every time and is deliberately
# two-sided: no `--resume` on the launch, and a FRESH id on the record — a
# refusal that dispatched nothing, or dispatched under the dead session's id,
# would pass a one-sided check.
sid_refusal() { # sid_refusal OUTPUT BOX KILLED — ordinary | RESUMED | NOT-FRESH
  if [ -n "$(sid_argv_flag "$1" --resume)" ]; then printf RESUMED
  elif [ "$(sid_of "$2" START)" = "$3" ]; then printf NOT-FRESH
  elif [ "$(sid_shape "$(sid_of "$2" START)")" != uuid ]; then printf NOT-MINTED
  else printf ordinary
  fi
}

# 1 — the head moved: the carried context is about a tree that is gone.
sid_run moved fixture/moved 1 talk-hang both >/dev/null
sid_moved_killed="$(sid_of moved START)"
sid_commit "$TMP/sid-moved/work_dir.dot space"
t sid-refuses-when-the-head-moved ordinary \
  "$(sid_refusal "$(sid_run moved fixture/moved 5 reply both)" moved "$sid_moved_killed")"

# 2 — no head at all: `$dir` is not a work tree, so the stub records `unknown`,
# and `unknown` is never equal to anything.
mkdir -p "$TMP/sid-nogit-work"
sid_run nohead fixture/nohead 1 talk-hang both "$TMP/sid-nogit-work" >/dev/null
sid_nohead_killed="$(sid_of nohead START)"
t sid-stub-records-an-unreadable-head-as-unknown unknown \
  "$(sid_stub_field "$(sid_stub nohead fixture_nohead)" head)"
t sid-refuses-when-the-head-is-unknown ordinary \
  "$(sid_refusal "$(sid_run nohead fixture/nohead 5 reply both "$TMP/sid-nogit-work")" \
    nohead "$sid_nohead_killed")"

# 3 — the killed session's log must classify as productive. The real incident
# body is 15 bytes and non-empty, so the old byte-floor resumed it; the shipped
# profile action classifier names it as unknown and refuses it on that fact.
sid_run errorlog fixture/errorlog 5 oom-error claude >/dev/null
sid_error_killed="$(sid_of errorlog START)"
t sid-error-output-stub-records-the-classifier no \
  "$(sid_stub_field "$(sid_stub errorlog fixture_errorlog)" productive)"
t sid-error-output-fixture-is-the-real-15-byte-body 15 \
  "$(sid_stub_field "$(sid_stub errorlog fixture_errorlog)" log)"
t sid-refuses-the-real-execution-error-body ordinary \
  "$(sid_refusal "$(sid_run errorlog fixture/errorlog 5 reply claude)" \
    errorlog "$sid_error_killed")"

# A dirty non-124 kill carrying a vendor-terminal tail would feed the breaker
# if kernel OOM promotion did not outrank terminal classification.
sid_run membreaker fixture/membreaker 5 oom-terminal claude >/dev/null
t sid-memory-kill-feeds-no-vendor-breaker 0 \
  "$(find "$TMP/sid-membreaker" -maxdepth 1 -name '.session-terminal.*' | wc -l)"
# shellcheck disable=SC2016  # sed matches the subject's literal variables
sid_mutant no-oom-promotion \
  '/^  elif \[ "$oom_hit" = yes \] \&\& \[ "$verdict" != ok \]; then$/,+1d'
SID_SESSION_MUTANT="$TMP/session-sid-mutant-no-oom-promotion.sh" \
  sid_run membreaker-mut fixture/membreaker-mut 5 oom-terminal claude >/dev/null
t sid-mutation-dropping-oom-promotion-feeds-the-breaker 1 \
  "$(find "$TMP/sid-membreaker-mut" -maxdepth 1 -name '.session-terminal.*' | wc -l)"

# 4 — something of that session is still alive. THE LOAD-BEARING ONE: resuming
# a lane while a process of the previous session still runs puts two live
# sessions on one key, and #529's counter is the only thing that can see it.
sid_run escape fixture/esc 1 escape-hang both >/dev/null
sid_escape_killed="$(sid_of escape START)"
t sid-stub-records-a-survivor 1 \
  "$(sid_stub_field "$(sid_stub escape fixture_esc)" left)"
t sid-refuses-while-something-of-it-is-alive ordinary \
  "$(sid_refusal "$(sid_run escape fixture/esc 5 reply both)" escape "$sid_escape_killed")"
if [ -s "$TMP/sid-escape/escapee" ]; then
  kill "$(cat "$TMP/sid-escape/escapee")" 2>/dev/null || true
fi

# 5 — the bound is spent. Written by hand at the bound rather than by driving
# two timeouts, so this case fails for the try count alone; the two-timeout
# path is asserted on its own below.
sid_run bound fixture/bound 1 talk-hang both >/dev/null
sid_bound_killed="$(sid_of bound START)"
# The bound is read from the module rather than retyped, so raising it moves
# this case with it. The `:-1` is reachable only on a tree where the module
# defines no bound at all — which is what this suite's must-fail run against
# `main` is — and it keeps that run from aborting under `set -u` before the
# rest of the section has had its say.
sed -i "s/^try=.*/try=${SESSION_RESUME_MAX_TRIES:-1}/" "$(sid_stub bound fixture_bound)"
t sid-refuses-once-the-bound-is-spent ordinary \
  "$(sid_refusal "$(sid_run bound fixture/bound 5 reply both)" bound "$sid_bound_killed")"

# 6 — the profile can pin an id and cannot continue one. A CLI may have the
# first capability without the second, and then this lane behaves exactly as it
# did before #538.
sid_run pinonly fixture/pinonly 1 talk-hang pin-only >/dev/null
sid_pinonly_killed="$(sid_of pinonly START)"
t sid-refuses-a-profile-that-cannot-resume ordinary \
  "$(sid_refusal "$(sid_run pinonly fixture/pinonly 5 reply pin-only)" \
    pinonly "$sid_pinonly_killed")"

# …and the same condition read at the GATE rather than through the dispatch,
# because the dispatch enforces it twice. `_session_identity` also falls back
# to a fresh session when the hook refuses to render, so the case above stays
# green with D6.6 deleted from `_session_resume_plan` — a guard the suite
# cannot see is a guard that can be removed. This pair drives the plan
# directly, with a stub whose other five conditions all hold, so the only
# thing that differs between the two answers is the hook.
SID_PLAN_BOX="$(sid_box planonly)"
sid_plan_verdict() ( # sid_plan_verdict none|both
  local stub="$SID_PLAN_BOX/.session-resume.build.fixture_plan"
  printf 'kind=build\nkey=fixture/plan\nsid=%s\nhead=%s\nwall=1\ntry=0\nlog=14\noutcome=TIMEOUT\nproductive=yes\nleft=0\n' \
    "$(_session_mint_sid)" "$(git -C "$SID_PLAN_BOX/work_dir.dot space" rev-parse HEAD)" >"$stub"
  DUTY_DIR="$SID_PLAN_BOX"
  unset -f bot_cli_resume_args
  [ "$1" = none ] || eval 'bot_cli_resume_args() { BOT_CLI_RESUME_ARGS=(--resume "$1"); }'
  _session_resume_plan build fixture/plan "$SID_PLAN_BOX/work_dir.dot space"
  printf '%s' "$_SESSION_RESUMED"
)
t sid-the-gate-itself-refuses-without-the-resume-hook no "$(sid_plan_verdict none)"
t sid-the-gate-resumes-when-only-the-hook-was-missing yes "$(sid_plan_verdict both)"
# The stub names the task the killed session was on; a dispatch for other
# work never resumes it (#763 re-review: a review of PR A resumed into PR B).
sid_plan_task() ( # sid_plan_task STUB-TASK DISPATCH-TASK
  local stub="$SID_PLAN_BOX/.session-resume.build.fixture_plan"
  printf 'kind=build\nkey=fixture/plan\nsid=%s\nhead=%s\nwall=1\ntry=0\nlog=14\noutcome=TIMEOUT\nproductive=yes\nleft=0\ntask=%s\n' \
    "$(_session_mint_sid)" "$(git -C "$SID_PLAN_BOX/work_dir.dot space" rev-parse HEAD)" "$1" >"$stub"
  DUTY_DIR="$SID_PLAN_BOX"
  eval 'bot_cli_resume_args() { BOT_CLI_RESUME_ARGS=(--resume "$1"); }'
  SESSION_TASK="$2" _session_resume_plan build fixture/plan "$SID_PLAN_BOX/work_dir.dot space"
  printf '%s' "$_SESSION_RESUMED"
)
t sid-a-stub-resumes-into-its-own-task yes "$(sid_plan_task o/r#1 o/r#1)"
t sid-a-stub-never-resumes-into-another-task no "$(sid_plan_task o/r#1 o/r#2)"
t sid-a-stub-with-no-task-resumes-as-before yes "$(sid_plan_task - '')"

# --- a stub that is not one is absent, never resumable -------------------
sid_corrupt_case() { # sid_corrupt_case BOX MUTATION...
  local box="$1"; shift
  sid_run "$box" "fixture/$box" 1 talk-hang both >/dev/null
  local killed; killed="$(sid_of "$box" START)"
  "$@" "$(sid_stub "$box" "fixture_$box")"
  sid_refusal "$(sid_run "$box" "fixture/$box" 5 reply both)" "$box" "$killed"
}
sid_truncate() { head -3 "$1" >"$1.t" && mv "$1.t" "$1"; }
sid_garble() { printf 'this is not a stub\n' >"$1"; }
sid_repeat() { cat "$1" "$1" >"$1.t" && mv "$1.t" "$1"; }
# The same ambiguity as `sid_repeat`, in the one shape that guard structurally
# CANNOT reach: the duplicate's FIRST occurrence is EMPTY. `sid_repeat` copies
# the whole stub, so every duplicated field arrives at its non-empty value and
# a reader that marks a field seen by "its value is non-empty" refuses it
# correctly — which is why that case passed while this one resumed. Here line
# one stores "", line two is waved through, `kind` ends up valid, and the
# all-fields check reads FINAL values so it cannot see the ambiguity either.
# Measured on the unfixed reader: all six resume fields returned and the
# dispatch carried `--resume` (#596 review, found by two reviewers).
sid_repeat_empty_first() { printf 'kind=\n' | cat - "$1" >"$1.t" && mv "$1.t" "$1"; }
sid_forge_sid() { sed -i 's/^sid=.*/sid=not-a-uuid/' "$1"; }
# Two ids that are the RIGHT LENGTH with dashes in the right places and are
# still not ids. `not-a-uuid` above is refused by the length glob alone, so it
# says nothing about the alphabet guard; these two are refused by the alphabet
# guard alone, and both were ACCEPTED before the review — the all-dash value
# reached `--resume` and spent the episode's one try on an id the CLI rejects.
sid_forge_all_dashes() {
  sed -i 's/^sid=.*/sid=------------------------------------/' "$1"
}
sid_forge_shifted_dash() {
  sed -i 's/^sid=.*/sid=-d7d876b-ae67-47d5-ba46-ce4a32081d20/' "$1"
}
sid_remove() { rm -f "$1"; }
# A stub whose required fields are all present and valid, carrying one field
# this reader does not know. It is the only corrupt shape here that reaches the
# END of the parse with everything D6 asks for in hand, so it is the only one
# the unknown-field arm alone decides: with that arm removed the stub parses
# clean and RESUMES, and every other case in this section still passes. It is
# also the forward-compatible shape rather than a hypothetical one — a later
# engine writing a seventh field leaves exactly this for an older reader — and
# refusing it is D6's failure direction, not a gap in it.
sid_extra_field() { printf 'mode=fast\n' >>"$1"; }
t sid-truncated-stub-is-absent ordinary "$(sid_corrupt_case truncated sid_truncate)"
t sid-unparseable-stub-is-absent ordinary "$(sid_corrupt_case garbled sid_garble)"
t sid-ambiguous-stub-is-absent ordinary "$(sid_corrupt_case repeated sid_repeat)"
t sid-empty-first-duplicate-is-absent ordinary \
  "$(sid_corrupt_case emptydup sid_repeat_empty_first)"
t sid-malformed-id-is-absent ordinary "$(sid_corrupt_case forged sid_forge_sid)"
t sid-all-dash-id-is-absent ordinary "$(sid_corrupt_case alldash sid_forge_all_dashes)"
t sid-shifted-dash-id-is-absent ordinary \
  "$(sid_corrupt_case shifted sid_forge_shifted_dash)"
# …and the same two read at the guard rather than through the dispatch, so the
# classification is pinned where it is made. The third assertion is the control
# that keeps the pair from passing on a validator that refuses everything.
t sid-validator-refuses-an-all-dash-id reject \
  "$(sid_valid_says '------------------------------------')"
t sid-validator-refuses-a-shifted-dash-id reject \
  "$(sid_valid_says '-d7d876b-ae67-47d5-ba46-ce4a32081d20')"
t sid-validator-accepts-the-observed-id ACCEPT \
  "$(sid_valid_says d7d876b7-ae67-47d5-ba46-ce4a32081d20)"
t sid-unknown-field-stub-is-absent ordinary "$(sid_corrupt_case extra sid_extra_field)"
t sid-missing-stub-is-absent ordinary "$(sid_corrupt_case removed sid_remove)"

# --- D5's gate is the VERDICT and not the raw rc --------------------------
#
# The case that separates them cannot be staged through a dispatch: it needs a
# memory kill whose signal lands in the same instant as the deadline, so that
# `timeout` reports 124 for a session the ENGINE killed. So this reads the
# writer directly, where the classification is made — the treatment the sid
# validator gets above, for the same reason.
#
# The stale-file assertion preserves the writer's placement: an outcome this
# issue does not admit must still delete a previous timeout's stub.
sid_record_says() ( # sid_record_says RC VERDICT [STALE] — WROTE | deleted
  local state slog
  DUTY_DIR="$TMP/sid-record"; mkdir -p "$DUTY_DIR"
  _SESSION_SID=d7d876b7-ae67-47d5-ba46-ce4a32081d20
  _SESSION_TRY=1
  state="$(_session_resume_state build fixture/rec)"
  rm -f "$state"
  [ -z "${3-}" ] || printf 'kind=build\n' >"$state"
  slog="$TMP/sid-record.log"
  printf 'partial work\n' >"$slog"
  bot_session_terminal() { return 1; }
  _session_resume_record build fixture/rec "$TMP" "$1" 5 100 0 "$2" yes "$slog"
  [ -s "$state" ] && printf WROTE || printf deleted
  return 0
)
t sid-a-timeout-writes-the-stub WROTE "$(sid_record_says 124 TIMEOUT)"
t sid-a-memory-kill-at-124-writes-the-stub WROTE "$(sid_record_says 124 MEMORY)"
t sid-an-ordinary-end-deletes-a-stale-stub deleted "$(sid_record_says 0 ok stale)"
# The stub names the task the killed session was on (#763 re-review).
t sid-the-record-names-its-task 1 "$(SESSION_TASK=o/r#3 sid_record_says 124 TIMEOUT >/dev/null; grep -c '^task=o/r#3$' "$TMP/sid-record/.session-resume.build.fixture_rec")"

# --- two keys, one filename: the tuple decides, never the path -----------
#
# `_session_resume_state` folds the key to a filename alphabet and the fold is
# lossy, so `fixture/coll_x` and `fixture_coll/x` reach one file. Both
# dispatches below run in ONE box against ONE work tree, which is the shape a
# lane actually has — `$dir` is the repo clone, shared by every key in that
# repo — so the recorded head EQUALS the reading dispatch's head and D6.2
# cannot be what refuses. Before the tuple was written into the stub, the
# second lane resumed the first lane's transcript here.
SID_COLL_A=fixture/coll_x
SID_COLL_B=fixture_coll/x
sid_coll_path() ( DUTY_DIR="$TMP/sid-collide"; _session_resume_state build "$1" )
t sid-two-keys-fold-to-one-stub-path same \
  "$(sid_same "$(sid_coll_path "$SID_COLL_A")" "$(sid_coll_path "$SID_COLL_B")")"

# The control first, in its own box: this key shape resumes ITSELF. Without it
# the refusal below would also pass on an engine that had simply stopped
# resuming keys containing a slash.
sid_run collctl "$SID_COLL_A" 1 talk-hang both >/dev/null
sid_coll_ctl_killed="$(sid_of collctl START)"
t sid-a-colliding-key-shape-still-resumes-its-own-lane same \
  "$(sid_same \
    "$(sid_argv_flag "$(sid_run collctl "$SID_COLL_A" 5 reply both)" --resume)" \
    "$sid_coll_ctl_killed")"

sid_run collide "$SID_COLL_A" 1 talk-hang both >/dev/null
sid_coll_killed="$(sid_of collide START)"
SID_COLL_STUB="$(sid_coll_path "$SID_COLL_A")"
t sid-the-collision-is-at-the-same-head same \
  "$(sid_same "$(sid_stub_field "$SID_COLL_STUB" head)" \
    "$(git -C "$TMP/sid-collide/work_dir.dot space" rev-parse HEAD)")"
t sid-the-stub-names-the-lane-that-wrote-it "$SID_COLL_A" \
  "$(sid_stub_field "$SID_COLL_STUB" key)"
t sid-a-colliding-key-does-not-resume-the-other-lane ordinary \
  "$(sid_refusal "$(sid_run collide "$SID_COLL_B" 5 reply both)" collide \
    "$sid_coll_killed")"
# The cost of a collision, asserted rather than assumed: a LOST resume. The
# refusing dispatch consumes the stub it refused, exactly as every other
# refusal does, so the lane that wrote it dispatches fresh too.
t sid-a-refused-collision-consumes-the-stub gone \
  "$([ -e "$SID_COLL_STUB" ] && printf PRESENT || printf gone)"

# --- two consecutive timeouts, exactly one resume (D7) -------------------
#
# The bound is one resume per episode, and the shape that proves it is a second
# timeout on a key that has already spent its resume: the stub the resumed
# session leaves carries try=1, and the dispatch after it is ordinary.
sid_run pair fixture/pair 1 talk-hang both >/dev/null
sid_pair_first="$(sid_of pair START)"
sid_pair_two="$(sid_run pair fixture/pair 1 talk-hang both)"
t sid-first-timeout-is-resumed same \
  "$(sid_same "$(sid_argv_flag "$sid_pair_two" --resume)" "$sid_pair_first")"
t sid-a-resumed-timeout-records-its-spent-try 1 \
  "$(sid_stub_field "$(sid_stub pair fixture_pair)" try)"
sid_pair_three="$(sid_run pair fixture/pair 5 reply both)"
t sid-second-timeout-is-not-resumed-again 0 \
  "$(sed -n '/^--argv--$/,$p' <<<"$sid_pair_three" | grep -c -- '--resume' || true)"
sid_pair_resumes=0
[ -z "$(sid_argv_flag "$sid_pair_two" --resume)" ] || sid_pair_resumes=$((sid_pair_resumes + 1))
[ -z "$(sid_argv_flag "$sid_pair_three" --resume)" ] || sid_pair_resumes=$((sid_pair_resumes + 1))
t sid-two-timeouts-produce-exactly-one-resume 1 "$sid_pair_resumes"

# --- run_session cannot be failed by any of this -------------------------
#
# An instrument or a recovery must never be able to fail a session, so every
# shape above is re-asserted on the one thing every caller reads.
sid_returns() { sed -n 's/^returned=\([0-9]*\).*/\1/p' <<<"$1"; }
t sid-run-session-returns-zero-when-pinning 0 "$(sid_returns "$sid_pinned")"
t sid-run-session-returns-zero-without-hooks 0 "$(sid_returns "$sid_hookless")"
t sid-run-session-returns-zero-when-a-hook-refuses 0 "$(sid_returns "$sid_refusing")"
t sid-run-session-returns-zero-on-a-resume 0 "$(sid_returns "$sid_resumed")"
t sid-run-session-returns-zero-on-a-timeout 'returned=0 rc=124' \
  "$(grep '^returned=' <<<"$(sid_run rczero fixture/rczero 1 talk-hang both)")"

# --- the shipped floor still reads both lines, both ways ------------------
#
# Asserted against the regexes AS SHIPPED — read out of units.py rather than
# retyped here — because the compatibility claim is about the deployed floor
# and not about a copy that agrees with this file. Both directions: the line
# without `sid=` is what every box wrote before this change and must keep
# parsing, and the line with it must return the SAME fields, the new token
# simply unread.
sid_floor_result() { # sid_floor_result START END
  SID_FLOOR_START="$1" SID_FLOOR_END="$2" python3 - \
    "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_START", "RE_END"):
    match = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, match.group(1)), ns)
out = []
for name, line in (("START", os.environ["SID_FLOOR_START"]),
                   ("END", os.environ["SID_FLOOR_END"])):
    new = "2026-08-30T00:00:00Z " + line
    old = re.sub(r" sid=\S+", "", new)
    rx = ns["RE_START"] if name == "START" else ns["RE_END"]
    old_m, new_m = rx.search(old), rx.search(new)
    if not old_m or not new_m:
        out.append("%s:UNPARSED" % name)
    elif old_m.groups()[1:] != new_m.groups()[1:]:
        out.append("%s:CHANGED" % name)
    else:
        out.append("%s:same" % name)
print(" ".join(out))
PY
}
if command -v python3 >/dev/null 2>&1; then
  t sid-floor-parses-both-records-identically-with-and-without 'START:same END:same' \
    "$(sid_floor_result "$(sid_line pinned START)" "$(sid_line pinned END)")"
fi

# --- the fences, read structurally (D4, D7, D10) -------------------------
#
# D4 is the claim that no duty lane changed, and it is asserted as a property
# of those files rather than of this diff: the resume decision lives in
# run_session, so a lane that learned to make it would be a regression this
# suite can see at any later head.
t sid-resume-decision-is-in-no-duty-lane 0 \
  "$(grep -lE '_session_identity|_session_resume|bot_cli_resume_args|bot_cli_session_id_args|SESSION_RESUME_MAX_TRIES' \
      "$SHARED/lib/duty-builder.sh" "$SHARED/lib/duty-review.sh" \
      "$SHARED/lib/duty-triage.sh" 2>/dev/null | wc -l)"

# D7 — the bound is not a config knob, and that is a property of the source.
# An env fallback here would be the tunable the decision refuses, so the
# assertion is that the assignment has none and that no conf file names it.
t sid-resume-bound-has-no-env-fallback 'SESSION_RESUME_MAX_TRIES=1' \
  "$(grep -m1 '^SESSION_RESUME_MAX_TRIES=' "$SHARED/lib/common/session.sh")"
t sid-resume-bound-is-in-no-conf-file 0 \
  "$(grep -rl 'SESSION_RESUME_MAX_TRIES' "$SHARED/conf" 2>/dev/null | wc -l)"

# The claude profile's two hooks are independently defined and neither renders
# the other's flag — the separation the CLI's own `already in use` error forces.
sid_claude_hook() { # sid_claude_hook NAME ARG
  ( # shellcheck disable=SC1091
    source "$SHARED/conf/agents/claude.conf"
    BOT_CLI_SESSION_ID_ARGS=(); BOT_CLI_RESUME_ARGS=()
    "$1" "$2" >/dev/null 2>&1
    printf '%s' "${BOT_CLI_SESSION_ID_ARGS[*]}${BOT_CLI_RESUME_ARGS[*]}" )
}
t sid-claude-pins-with-session-id '--session-id abc' \
  "$(sid_claude_hook bot_cli_session_id_args abc)"
t sid-claude-resumes-with-resume '--resume abc' \
  "$(sid_claude_hook bot_cli_resume_args abc)"

# --- structured usage and credential-pool identity (#475) ----------------
#
# The stub is the CLI, not the parser: it receives Claude's profile-built
# argv and emits the vendor JSON shape. That makes the invocation, prose
# reconstruction and SESSION END record one behavioral path.
USAGE_CLI="$TMP/usage-cli.sh"
cat >"$USAGE_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$USAGE_ARGV"
case "${USAGE_SHAPE:-valid}" in
  valid)
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/one","total_cost_usd":0.0125,"usage":{"input_tokens":120,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":77},"modelUsage":{"claude-sonnet-4-6":{"outputTokens":34}}}'
    ;;
  valid-with-warning)
    printf '%s\n' 'vendor warning' >&2
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/one","total_cost_usd":0.0125,"usage":{"input_tokens":120,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":77},"modelUsage":{"claude-sonnet-4-6":{"outputTokens":34}}}'
    ;;
  no-cost)
    printf '%s\n' '{"type":"result","subtype":"success","result":"Tokens still count.","session_id":"session/no-cost","usage":{"input_tokens":90,"output_tokens":12},"modelUsage":{"claude-haiku-4-5":{"outputTokens":12}}}'
    ;;
  partial-cost)
    printf '%s\n' '{"type":"result","subtype":"success","result":"Partial cost omitted.","session_id":"session/partial","total_cost_usd":0.5,"hasUnknownModelCost":true,"usage":{"input_tokens":80,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":4},"modelUsage":{"claude-opus-4-1":{"outputTokens":20}}}'
    ;;
  unknown-model)
    printf '%s\n' '{"type":"result","subtype":"success","result":"No model named.","session_id":"session/unknown","usage":{"input_tokens":50,"output_tokens":10}}'
    ;;
  two-models)
    printf '%s\n' '{"type":"result","subtype":"success","result":"Two models ran.","session_id":"session/two-models","usage":{"input_tokens":200,"output_tokens":20},"modelUsage":{"claude-opus-4":{"outputTokens":15},"claude-haiku-4":{"outputTokens":5}}}'
    ;;
  malformed)
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/two","total_cost_usd":0.5,"usage":{"input_tokens":"many","output_tokens":4}}'
    ;;
  observe-log)
    find "$USAGE_LIVE_LOG_DIR" -maxdepth 1 -type f -name '*.log' \
      | wc -l >"$USAGE_LIVE_OBSERVED"
    printf '%s\n' '{"type":"result","subtype":"success","result":"I pushed the fix.","session_id":"session/one","total_cost_usd":0.0125,"usage":{"input_tokens":120,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":77},"modelUsage":{"claude-sonnet-4-6":{"outputTokens":34}}}'
    ;;
esac
STUB
chmod +x "$USAGE_CLI"

# shellcheck disable=SC2030,SC2031,SC2317
usage_run() ( # usage_run POOL SHAPE [TIER] — one independent box-shaped dispatch
  local pool="$1" shape="$2" tier="${3:-}" udir
  udir="$TMP/usage-$pool-$shape-$RANDOM"
  mkdir -p "$udir/logs" "$udir/work"
  DUTY_DIR="$udir"; LOG_DIR="$udir/logs"; DUTY_TICK_ID="tick-usage"
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  BOT_CLI_CMD=(bash "$USAGE_CLI" -p)
  SESSION_CREDENTIAL_POOL="$pool"
  export MODEL_BUILD="$tier"
  export USAGE_SHAPE="$shape" USAGE_ARGV="$udir/argv"
  export USAGE_LIVE_LOG_DIR="$udir/logs" USAGE_LIVE_OBSERVED="$udir/live-log"
  run_session build fixture/usage "$udir/work" 5 theprompt \
    2>&1 | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  printf '%s\n' -- '--prose--'
  cat "$udir"/logs/*.log
  printf '%s\n' -- '--argv--'
  cat "$udir/argv"
  if [ -f "$udir/live-log" ]; then
    printf '%s\n' -- '--live-log--'
    cat "$udir/live-log"
  fi
)

usage_valid="$(usage_run shared-a valid)"
usage_end="$(grep 'SESSION END' <<<"$usage_valid")"
t usage-claude-profile-selects-json-output 1 \
  "$(sed -n '/^--argv--$/,$p' <<<"$usage_valid" | grep -c '^json$' || true)"
t usage-claude-session-records-input 120 \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-output 34 \
  "$(sed -n 's/.* output_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cache-create 5 \
  "$(sed -n 's/.* cache_creation_input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cache-read 77 \
  "$(sed -n 's/.* cache_read_input_tokens=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-cost 0.0125 \
  "$(sed -n 's/.* cost_usd=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-session-id session%2Fone \
  "$(sed -n 's/.* session_id=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-claude-session-records-actual-model claude-sonnet-4-6 \
  "$(sed -n 's/.* model=\([^ ]*\).*/\1/p' <<<"$usage_end")"
t usage-single-model-omits-model-count 0 \
  "$(grep -c ' models=' <<<"$usage_end" || true)"
# D1's ordering, pinned where the suffixes `sid=` must follow ACTUALLY EXIST.
# `sid-is-the-last-token-on-end` runs on a fixture defining no `bot_cli_usage`,
# so `$usage_suffix` and `$pool_suffix` are both empty there and `sid=` is last
# wherever the interpolation sits — that assertion is true but weaker than its
# name reads, and the kill for moving `$sid_suffix` came entirely from the
# ledger suite's source-derived order guard (#596 review). This box reports
# usage AND names a credential pool, so both suffixes are non-empty and this is
# the assertion in THIS suite that fails if `sid=` stops being last. The second
# line is its control: it keeps the first from going vacuous again if the
# fixture ever stops reporting usage.
t usage-sid-is-the-last-token-past-the-usage-block 1 \
  "$(grep -c ' sid=[^ ]*$' <<<"$usage_end" || true)"
t usage-end-really-carries-the-suffixes-sid-must-follow 2 \
  "$(grep -o ' input_tokens=\| pool=' <<<"$usage_end" | wc -l | tr -d ' ')"
t usage-structured-run-restores-the-prose-log 'I pushed the fix.' \
  "$(sed -n '/^--prose--$/{n;p;}' <<<"$usage_valid")"
t usage-structured-scratch-does-not-survive 0 \
  "$(find "$TMP" -name '*.structured' | wc -l)"

usage_live="$(usage_run shared-a observe-log)"
t usage-structured-advertised-log-exists-while-running 1 \
  "$(sed -n '/^--live-log--$/{n;p;}' <<<"$usage_live")"

usage_tier="$(usage_run shared-a valid opus)"
# The prompt is still the final argument, and the session-id pin sits AHEAD of
# the `-p` that makes it one — which is the whole reason `_session_splice_cli_args`
# splices rather than appends (#538). The minted id is normalised because it is
# random per dispatch; that it is a UUID at all is asserted by the pattern.
t usage-tiered-structured-command-keeps-prompt-last \
  '--model opus --output-format json --session-id <uuid> -p theprompt' \
  "$(sed -n '/^--argv--$/,$p' <<<"$usage_tier" | tail -n +2 | head -8 \
    | sed -E 's/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/<uuid>/' \
    | paste -sd ' ' -)"
t usage-requested-tier-keeps-own-meaning 'opus|claude-sonnet-4-6' \
  "$(grep 'SESSION END' <<<"$usage_tier" \
    | sed -n 's/.* tier=\([^ ]*\).* model=\([^ ]*\).*/\1|\2/p')"

# Tokens are the required measurement. Cost and cache counters are optional
# enrichment, while actual-model attribution never borrows the requested tier.
usage_no_cost="$(usage_run shared-a no-cost)"
usage_no_cost_end="$(grep 'SESSION END' <<<"$usage_no_cost")"
t usage-token-pair-does-not-require-cost '90|12|claude-haiku-4-5|shared-a' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).* model=\([^ ]*\).* pool=\([^ ]*\).*/\1|\2|\3|\4/p' <<<"$usage_no_cost_end")"
t usage-absent-cost-stays-absent 0 \
  "$(grep -c ' cost_usd=' <<<"$usage_no_cost_end" || true)"
t usage-absent-cache-concept-stays-absent 0 \
  "$(grep -Ec ' cache_(creation|read)_input_tokens=' <<<"$usage_no_cost_end" || true)"

usage_partial="$(usage_run shared-a partial-cost)"
usage_partial_end="$(grep 'SESSION END' <<<"$usage_partial")"
t usage-unknown-or-partial-cost-is-omitted '80|0|4|0' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* cache_creation_input_tokens=\([^ ]*\).* cache_read_input_tokens=\([^ ]*\).*/\1|\2|\3/p' <<<"$usage_partial_end")|$(grep -c ' cost_usd=' <<<"$usage_partial_end" || true)"

usage_unknown_model="$(usage_run shared-a unknown-model opus)"
usage_unknown_model_end="$(grep 'SESSION END' <<<"$usage_unknown_model")"
t usage-unnamed-model-is-unknown-not-tier 'opus|unknown' \
  "$(sed -n 's/.* tier=\([^ ]*\).* model=\([^ ]*\).*/\1|\2/p' <<<"$usage_unknown_model_end")"

usage_two_models="$(usage_run shared-a two-models)"
usage_two_models_end="$(grep 'SESSION END' <<<"$usage_two_models")"
t usage-two-models-selects-largest-output-and-counts 'claude-opus-4|2' \
  "$(sed -n 's/.* model=\([^ ]*\).* models=\([^ ]*\).*/\1|\2/p' <<<"$usage_two_models_end")"

# Vendor diagnostics are prose, not structured stdout: both surfaces survive
# independently, and a harmless warning cannot silently disable accounting.
usage_noisy="$(usage_run shared-a valid-with-warning)"
usage_noisy_end="$(grep 'SESSION END' <<<"$usage_noisy")"
usage_noisy_prose="$(sed -n '/^--prose--$/,/^--argv--$/p' <<<"$usage_noisy")"
t usage-structured-stderr-keeps-accounting '120|shared-a|0|ok' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).* input_tokens=\([^ ]*\).* pool=\([^ ]*\).*/\3|\4|\1|\2/p' <<<"$usage_noisy_end")"
t usage-structured-stderr-keeps-diagnostic 1 \
  "$(grep -c '^vendor warning$' <<<"$usage_noisy_prose" || true)"
t usage-structured-stderr-keeps-result-prose 1 \
  "$(grep -c '^I pushed the fix\.$' <<<"$usage_noisy_prose" || true)"
t usage-structured-stderr-hides-json-envelope 0 \
  "$(grep -c '^{"type":"result"' <<<"$usage_noisy_prose" || true)"

# Two independent directories stand in for two boxes: pool identity is the
# operator's declaration, not a session-local or box-local derivative.
usage_same="$(usage_run shared-a valid)"
usage_other="$(usage_run shared-b valid)"
t usage-same-pool-is-stable-across-boxes shared-a \
  "$(grep 'SESSION END' <<<"$usage_same" | sed -n 's/.* pool=\([^ ]*\).*/\1/p')"
t usage-different-pool-is-distinguishable shared-b \
  "$(grep 'SESSION END' <<<"$usage_other" | sed -n 's/.* pool=\([^ ]*\).*/\1/p')"

usage_unsafe="$(usage_run 'bad pool' valid)"
usage_unsafe_end="$(grep 'SESSION END' <<<"$usage_unsafe")"
t usage-unsafe-pool-warns-separately 1 \
  "$(grep -c '^WARN: session accounting:' <<<"$usage_unsafe" || true)"
t usage-unsafe-pool-keeps-one-session-end 1 \
  "$(grep -c '^SESSION END ' <<<"$usage_unsafe" || true)"
t usage-unsafe-pool-keeps-parseable-session-id session%2Fone \
  "$(sed -n 's/.* session_id=\([^ ]*\).*/\1/p' <<<"$usage_unsafe_end")"
t usage-unsafe-pool-is-omitted 0 \
  "$(grep -c ' pool=' <<<"$usage_unsafe_end" || true)"

# Malformed accounting is absent, while the work's result, rc, outcome and
# prose survive. This is the failure direction the instrument must never own.
usage_bad="$(usage_run shared-a malformed)"
usage_bad_end="$(grep 'SESSION END' <<<"$usage_bad")"
t usage-malformed-block-does-not-fail-session '0|ok' \
  "$(sed -n 's/.* rc=\([^ ]*\).* outcome=\([^ ]*\).*/\1|\2/p' <<<"$usage_bad_end")"
t usage-malformed-block-claims-no-input-token 0 \
  "$(grep -c ' input_tokens=' <<<"$usage_bad_end" || true)"
t usage-malformed-block-claims-no-pool 0 \
  "$(grep -c ' pool=' <<<"$usage_bad_end" || true)"
t usage-malformed-block-keeps-prose 'I pushed the fix.' \
  "$(sed -n '/^--prose--$/{n;p;}' <<<"$usage_bad")"

# A usage reporter is not synonymous with structured stdout. This fixture's
# ordinary command writes an artifact in the session directory; its profile
# hook selects that artifact from the context run_session supplies.
usage_artifact_dir="$TMP/usage-artifact"
mkdir -p "$usage_artifact_dir/logs" "$usage_artifact_dir/work"
usage_artifact="$({
  unset -f bot_cli_structured_cmd bot_cli_structured_prose 2>/dev/null || true
  # This profile PINS an id, which is what an artifact-backed one must do to
  # have a transcript to find (#571 D4). Without it the fourth argument below
  # would be `unknown` on both sides of the comparison and the assertion would
  # pass while measuring nothing — the failure that named this fixture.
  bot_cli_session_id_args() { BOT_CLI_SESSION_ID_ARGS=(--session "$1"); }
  bot_cli_usage() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >"$usage_artifact_dir/context"
    jq -ce . "$2/usage.json"
  }
  DUTY_DIR="$usage_artifact_dir"; LOG_DIR="$usage_artifact_dir/logs"
  DUTY_TICK_ID="tick-usage-artifact"; SESSION_CREDENTIAL_POOL="shared-a"
  BOT_CLI_CMD=(bash -c 'printf '\''%s\n'\'' '\''{"input_tokens":7,"output_tokens":3,"session_id":"artifact/one","model":"artifact-model","models":1}'\'' >usage.json; printf '\''exec\nartifact prose\n'\''')
  run_session build fixture/artifact "$usage_artifact_dir/work" 5 prompt \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //'
})"
usage_artifact_end="$(grep 'SESSION END' <<<"$usage_artifact")"
t usage-artifact-reporter-needs-no-structured-command \
  '7|3|artifact-model|shared-a' \
  "$(sed -n 's/.* input_tokens=\([^ ]*\).* output_tokens=\([^ ]*\).* model=\([^ ]*\).* pool=\([^ ]*\).*/\1|\2|\3|\4/p' <<<"$usage_artifact_end")"
t usage-artifact-reporter-receives-empty-structured-source '' \
  "$(cut -f1 "$usage_artifact_dir/context")"
t usage-artifact-reporter-receives-session-directory "$usage_artifact_dir/work" \
  "$(cut -f2 "$usage_artifact_dir/context")"
t usage-artifact-reporter-receives-prose-log 1 \
  "$([ "$(cut -f3 "$usage_artifact_dir/context")" = "$(find "$usage_artifact_dir/logs" -name '*.log')" ] && printf 1 || printf 0)"
t usage-artifact-command-keeps-legacy-prose 'exec' \
  "$(sed -n '1p' "$usage_artifact_dir"/logs/*.log)"
# The fourth argument, and the cross-reader pin that holds it (#571 D4). An
# artifact-backed profile finds its transcript by the session's id, so the id
# has to reach the hook — and it has to be THIS dispatch's, not a mirror the
# profile kept, which would go stale exactly when the pin failed. Asserted by
# EQUALITY WITH THE `sid=` ON THE SAME LINE rather than against a literal: the
# id is minted per dispatch, and the property that matters is that the figures
# and the transcript named beside them describe one session.
t usage-artifact-reporter-receives-dispatch-session-id 1 \
  "$([ "$(cut -f4 "$usage_artifact_dir/context")" \
      = "$(sed -n 's/.* sid=\([^ ]*\).*/\1/p' <<<"$usage_artifact_end")" ] \
    && printf 1 || printf 0)"
t usage-artifact-reporter-receives-a-real-id-not-unknown 0 \
  "$(grep -cx 'unknown' <<<"$(cut -f4 "$usage_artifact_dir/context")" || true)"

# The same hook on a profile that pins NOTHING. `unknown` is what the engine
# puts in `sid=` when no id could be pinned, and it is what the hook is handed
# — never an empty string that a profile might read as "not supplied" and
# never a silent fabrication. An artifact profile refuses it, because only the
# profile knows whether it needed an addressable transcript.
usage_unpinned_dir="$TMP/usage-unpinned"
mkdir -p "$usage_unpinned_dir/logs" "$usage_unpinned_dir/work"
usage_unpinned="$({
  unset -f bot_cli_structured_cmd bot_cli_structured_prose 2>/dev/null || true
  unset -f bot_cli_session_id_args bot_cli_resume_args 2>/dev/null || true
  bot_cli_usage() {
    printf '%s\n' "$4" >"$usage_unpinned_dir/context"
    jq -ce . "$2/usage.json"
  }
  DUTY_DIR="$usage_unpinned_dir"; LOG_DIR="$usage_unpinned_dir/logs"
  DUTY_TICK_ID="tick-usage-unpinned"; SESSION_CREDENTIAL_POOL="shared-a"
  BOT_CLI_CMD=(bash -c 'printf '\''%s\n'\'' '\''{"input_tokens":1,"output_tokens":1,"session_id":"unpinned/one","model":"m","models":1}'\'' >usage.json; printf '\''done\n'\''')
  run_session build fixture/unpinned "$usage_unpinned_dir/work" 5 prompt \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //'
})"
t usage-unpinned-reporter-receives-unknown unknown \
  "$(cat "$usage_unpinned_dir/context")"
t usage-unpinned-reporter-agrees-with-the-record unknown \
  "$(sed -n 's/.* sid=\([^ ]*\).*/\1/p' <<<"$(grep 'SESSION END' <<<"$usage_unpinned")")"

# A hookless profile is the exact old command/log/line shape: the existing
# budget golden below pins the whole line byte-for-byte; this focused case
# additionally proves no usage/pool field can appear merely because the
# engine learned the optional protocol.
usage_legacy="$(
  unset -f bot_cli_structured_cmd bot_cli_structured_prose bot_cli_usage 2>/dev/null || true
  SESSION_CREDENTIAL_POOL="configured-but-unmeasured"
  BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
  # shellcheck disable=SC2317  # invoked indirectly through session_acted
  bot_session_acted() { grep -qx exec "$1"; }
  run_session build fixture/legacy "$SA_WORK" 5 prompt | tail -1
)"
t usage-hookless-profile-claims-no-accounting 0 \
  "$(grep -Ec ' (input_tokens|cost_usd|session_id|pool)=' <<<"$usage_legacy" || true)"

# --- budgets off is byte-identical to today (#464) ------------------------
#
# This is what makes the change safe to land while the fleet is stopped, so it
# is asserted as a DIFF of the log output over a fixture run rather than by
# reading the code: with no budget configured, run_session's behaviour, its
# log lines and its state files must be exactly what they were.
#
# Two arms, because "not configured" has two shapes in the field — a conf that
# predates the budget and names no BUDGET_* at all, and the conf this change
# actually ships, which names them and sets them to 0.

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
budget_off_run() ( # budget_off_run absent|explicit
  local bdir="$TMP/budget-off-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID="tick-1"
  if [ "$1" = explicit ]; then
    BUDGET_SESSIONS_BUILD=0; BUDGET_MINUTES_BUILD=0; BUDGET_WINDOW_BUILD=0
  fi
  BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  # Normalised on exactly four tokens, all of which move between any two runs
  # of anything: the leading UTC stamp, the session log's timestamped path, the
  # measured duration, and the dispatching process's identity (#478).
  # Everything else is compared verbatim, which is where a stray budget line
  # would show up.
  for i in 1 2 3; do run_session build "fixture/test$i" "$bdir/work" 5 prompt; done \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //' \
          -e 's#log=[^ ]*/[0-9TZ]*-build#log=<slog>-build#' \
          -e 's/ dur=[0-9]*s / dur=<n>s /' \
          -e 's/ holder=[^ ]*/ holder=<holder>/'
  printf 'state-files=%s alerts=%s\n' \
    "$(find "$bdir" -name '.session-budget.*' | wc -l)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)"
)
t budget-off-log-output-is-byte-identical \
  "$(budget_off_run absent)" "$(budget_off_run explicit)"
t budget-off-writes-no-state-and-raises-nothing 'state-files=0 alerts=0' \
  "$(budget_off_run absent | sed -n '$p')"
# The gate is silent, not merely harmless: an "off" implementation that logged
# `reason=budget over=no` every tick would pass the diff above and still change
# every duty log in the fleet. Case-INSENSITIVE, because `BUDGET` and `Budget`
# are the same new line in a duty log and only one of the three spellings would
# have been caught.
t budget-off-says-nothing-about-budgets 0 \
  "$(budget_off_run absent | grep -ci budget || true)"

# THE BASELINE, which the diff above is not: two off-shapes of the same build
# agree with each other even when both are wrong, because a line emitted on the
# off path appears in BOTH arms and the diff stays clean. This is the log three
# sessions produce when no budget exists at all, written down — so a line the
# off path grows, in any spelling the grep above might miss, moves this instead.
#
# Nothing in it is budget-specific on purpose. It is what run_session said
# before #464 and must go on saying after it.
#
# It moved once, for #478: SESSION START gained `holder=`, the identity of the
# process the orphan reconciler asks about later. That is a deliberate change
# to what run_session says and so belongs in the golden — which is exactly the
# tripwire working, and the reason the field is normalised above rather than
# quietly excluded from the comparison.
#
# It has now moved twice. #469 appended `tier=` to SESSION END, and it is
# present on EVERY line rather than only on overridden ones, because D5's field
# is "the resolved invocation's tier, or `default`" — an aggregate cannot
# separate "hygiene got cheaper" from "hygiene got rarer" off a field that is
# missing whenever the answer is boring. So `tier=default` is what an
# unconfigured fleet writes, deliberately, and it is written down here for the
# same reason `holder=` was.
#
# It has now moved three times. #538 appended `sid=` to BOTH lines, and the
# value here is `unknown` on every one of them — which is the golden earning
# its keep rather than a gap in it. This fixture sets `BOT_CLI_CMD` directly
# and loads no agent profile, so it defines no `bot_cli_session_id_args`, and
# D2's stated neutral answer for a profile without that hook is exactly this:
# no id pinned, `sid=unknown`, and the session otherwise unchanged. The rest of
# both lines is byte-identical to what it was before, which is the other half
# of that same clause.
#
# The `holder=` normaliser above lost its `$` anchor in the same change. It had
# one only because `holder=` happened to be the last token on `SESSION START`;
# `sid=` is now, and an anchored normaliser would have left the real pid in the
# comparison and reported a mismatch that had nothing to do with what moved.
budget_off_golden() {
  cat <<'GOLDEN'
SESSION START kind=build key=fixture/test1 timeout=5s log=<slog>-build-fixture_test1.log holder=<holder> sid=unknown
SESSION END kind=build key=fixture/test1 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= log=17 left=0 tier=default oom=0 why=cron sid=unknown
SESSION START kind=build key=fixture/test2 timeout=5s log=<slog>-build-fixture_test2.log holder=<holder> sid=unknown
SESSION END kind=build key=fixture/test2 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= log=17 left=0 tier=default oom=0 why=cron sid=unknown
SESSION START kind=build key=fixture/test3 timeout=5s log=<slog>-build-fixture_test3.log holder=<holder> sid=unknown
SESSION END kind=build key=fixture/test3 rc=0 dur=<n>s outcome=ok acted=yes reply_tail=ZmluYWwgcmVwbHk= log=17 left=0 tier=default oom=0 why=cron sid=unknown
GOLDEN
}
# The last line is the state-file/alert tally the case above reads; everything
# before it is the log itself.
t budget-off-log-output-matches-its-golden "$(budget_off_golden)" \
  "$(budget_off_run absent | sed '$d')"

# --- the per-duty model tier (#469) ---------------------------------------
#
# The CLI stub is a real script that records its own argv, because the whole
# claim of D1 is about WHAT WAS INVOKED. A stub that only prints a reply would
# let an implementation resolve the override, log a tier for it and still
# dispatch the profile's default array — which is the one bug this issue
# exists to make impossible.
MODEL_CLI="$TMP/model-cli.sh"
cat >"$MODEL_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MODEL_CAPTURE"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$MODEL_CLI"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
model_run() ( # model_run KIND [MODEL_VAR=VALUE ...] — one dispatch, argv captured
  local kind="$1"; shift
  local mdir="$TMP/model-$kind-$RANDOM" setting
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  export MODEL_CAPTURE="$mdir/argv"; : >"$MODEL_CAPTURE"
  BOT_AGENT=fixtureagent
  BOT_CLI_CMD=(bash "$MODEL_CLI" --base-flag -p)
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  for setting in "$@"; do
    [ -n "$setting" ] || continue
    export "${setting?}"
  done
  run_session "$kind" "fixture/$kind" "$mdir/work" 5 theprompt \
    | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  printf -- '--argv--\n'
  cat "$MODEL_CAPTURE"
)

# The profile's translation, for the arms that have one. Mirrors what
# claude.conf ships: built FROM BOT_CLI_CMD, spliced ahead of a trailing -p.
#
# SC2031: BOT_CLI_CMD is set by model_run inside its own subshell, and this
# hook is CALLED from there — reading it is the point, not a lost write. That
# is the same reason the runners above carry the disable.
# shellcheck disable=SC2317,SC2031
model_hook() {
  bot_cli_model_cmd() {
    local tier="${1:-}"
    case "$tier" in ''|-*|*[[:space:]]*) return 1 ;; esac
    case "$tier" in unsayable) return 1 ;; esac
    local -a base=("${BOT_CLI_CMD[@]}")
    local last=$(( ${#base[@]} - 1 ))
    if [ "$last" -ge 0 ] && [ "${base[last]}" = "-p" ]; then
      BOT_CLI_MODEL_CMD=("${base[@]:0:last}" --model "$tier" -p)
    else
      BOT_CLI_MODEL_CMD=("${base[@]}" --model "$tier")
    fi
  }
}

# D1/D4 — unset resolves to the profile's own array, and the argv proves it.
model_default="$( model_hook; model_run build )"
t model-unset-invokes-the-profile-array "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_default" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-unset-logs-tier-default default \
  "$(printf '%s\n' "$model_default" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# D1 — a configured kind IS invoked with the override, and the flag lands
# ahead of the trailing -p so the prompt stays the prompt.
model_over="$( model_hook; model_run mention MODEL_MENTION=cheapo )"
t model-configured-kind-invokes-the-override \
  "$(printf -- '--base-flag\n--model\ncheapo\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_over" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-configured-kind-logs-its-tier cheapo \
  "$(printf '%s\n' "$model_over" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# ...and EVERY OTHER KIND IS NOT. The override is per kind, so a configured
# mention must not re-price the build lane running beside it in the same tick.
model_other="$( model_hook; model_run build MODEL_MENTION=cheapo )"
t model-override-does-not-leak-to-another-kind \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_other" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-other-kind-still-logs-tier-default default \
  "$(printf '%s\n' "$model_other" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# The kind→variable fold, which is BUDGET_*'s and not the timeout's:
# `ci-red` reads MODEL_CI_RED. Worth its own case because TIMEOUT_CIRED sits
# in the same conf with the other spelling.
model_cired="$( model_hook; model_run ci-red MODEL_CI_RED=cheapo )"
t model-kind-suffix-folds-non-alnum cheapo \
  "$(printf '%s\n' "$model_cired" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"

# D3 — a profile with NO translation at all leaves the duty on the default and
# WARNS, naming the profile and the kind. Silently ignoring a configured
# override is the failure that makes an operator think they saved something.
model_hookless="$( model_run hygiene MODEL_HYGIENE=cheapo )"
t model-hookless-profile-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_hookless" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-hookless-profile-logs-tier-default default \
  "$(printf '%s\n' "$model_hookless" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"
t model-hookless-profile-warns 1 \
  "$(printf '%s\n' "$model_hookless" | grep -c '^WARN: session model:' || true)"
# The warn is only useful if it says WHICH profile and WHICH duty — an operator
# reading it has four profiles and nine lanes to choose between.
model_warn="$(printf '%s\n' "$model_hookless" | sed -n 's/^WARN: session model: //p')"
case "$model_warn" in
  *kind=hygiene*fixtureagent*|*fixtureagent*kind=hygiene*) r1=named ;;
  *) r1="UNNAMED($model_warn)" ;;
esac
t model-hookless-warn-names-profile-and-kind named "$r1"
case "$model_warn" in *cheapo*) r1=named ;; *) r1=MISSING ;; esac
t model-hookless-warn-names-the-refused-tier named "$r1"

# D3, the other half — a profile that HAS a translation but cannot express
# THIS tier. Same outcome, same warn: never silently.
model_refused="$( model_hook; model_run hygiene MODEL_HYGIENE=unsayable )"
t model-refused-tier-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_refused" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-refused-tier-logs-tier-default default \
  "$(printf '%s\n' "$model_refused" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p')"
t model-refused-tier-warns 1 \
  "$(printf '%s\n' "$model_refused" | grep -c '^WARN: session model:' || true)"

# A hook that returns 0 without writing the array is a broken profile, not a
# licence to dispatch whatever the previous kind left in the global. It must
# fall back and warn like any other profile that could not answer.
# shellcheck disable=SC2317
model_silent_hook() { bot_cli_model_cmd() { return 0; }; }
model_silent="$( model_silent_hook; model_run hygiene MODEL_HYGIENE=cheapo )"
t model-hook-that-writes-nothing-stays-on-default \
  "$(printf -- '--base-flag\n-p\ntheprompt')" \
  "$(printf '%s\n' "$model_silent" | sed -n '/^--argv--$/,$p' | tail -n +2)"
t model-hook-that-writes-nothing-warns 1 \
  "$(printf '%s\n' "$model_silent" | grep -c '^WARN: session model:' || true)"

# An override must not buy its way past #464's budget gate: the gate runs
# FIRST, so an over-budget lane produces its SESSION SKIP, dispatches nothing,
# and says nothing about models — there is no invocation to have a tier.
#
# A ceiling of 1 admits the first session, so the refusal has to be asserted on
# a SECOND dispatch against the same rolling counter. Hence a pair in one
# directory rather than two calls to model_run, which deliberately gets a fresh
# DUTY_DIR each time.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
model_budget_pair() ( # model_budget_pair hook|nohook
  local mdir="$TMP/model-budget-$1" i
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  export MODEL_CAPTURE="$mdir/argv"; : >"$MODEL_CAPTURE"
  BOT_AGENT=fixtureagent
  BOT_CLI_CMD=(bash "$MODEL_CLI" --base-flag -p)
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  MODEL_HYGIENE=cheapo BUDGET_SESSIONS_HYGIENE=1 BUDGET_MINUTES_HYGIENE=0
  export MODEL_HYGIENE BUDGET_SESSIONS_HYGIENE BUDGET_MINUTES_HYGIENE
  [ "$1" = nohook ] || model_hook
  for i in 1 2; do
    run_session hygiene "fixture/h$i" "$mdir/work" 5 theprompt \
      | sed -e 's/^[0-9-]*T[0-9:]*Z //'
  done
  printf -- '--argv--\n'
  cat "$MODEL_CAPTURE"
)
model_budget="$(model_budget_pair hook)"
# The first is bought at the override; the second is refused by the budget.
t model-budget-gate-still-fires-first 1 \
  "$(printf '%s\n' "$model_budget" | grep -c 'SESSION SKIP kind=hygiene .* reason=budget' || true)"
t model-budget-refused-dispatch-invokes-nothing 1 \
  "$(printf '%s\n' "$model_budget" | sed -n '/^--argv--$/,$p' | grep -c '^theprompt$' || true)"
t model-budget-refused-dispatch-says-nothing-about-models 0 \
  "$(printf '%s\n' "$model_budget" | sed -n '/^--argv--$/q;p' \
     | grep -c '^WARN: session model:' || true)"
# THE ORDER ITSELF, and it needs a HOOKLESS profile to be observable at all.
#
# The case above passes whether the invocation is resolved before or after the
# gate, because a profile that CAN express the tier resolves it silently either
# way — a mutation moving _session_cli_cmd ahead of _session_budget_gate reds
# nothing in it. Measured, not assumed: that mutation was run and it was the
# one that killed no assertion.
#
# With no translation on the profile, resolving is no longer silent — it warns
# — so the count separates the two orders. Two dispatches, a ceiling of 1: the
# first runs and warns, the second is refused by the budget and must warn about
# NOTHING, because a dispatch that never happens has no invocation to resolve
# and no tier to fail to buy. One warn, not two.
model_budget_nohook="$(model_budget_pair nohook)"
t model-tier-resolved-only-for-a-dispatch-that-happens 1 \
  "$(printf '%s\n' "$model_budget_nohook" | sed -n '/^--argv--$/q;p' \
     | grep -c '^WARN: session model:' || true)"
# The one session that DID run was bought at the override, so the gate and the
# override are independent rather than one silencing the other.
t model-budget-armed-lane-still-honours-the-override cheapo \
  "$(printf '%s\n' "$model_budget" | sed -n 's/.*SESSION END .* tier=\([^ ]*\).*/\1/p' | head -1)"

# D5's compatibility, asserted against the two readers that exist rather than
# by eye.
#
# 1. The operator's own aggregate — the awk from #467, which splits every
#    token on `=` into a map. It must still find kind and acted, and it now
#    gains a tier column for free.
model_end_line="$(printf '%s\n' "$model_over" | grep 'SESSION END')"
t model-operator-aggregate-still-parses 'mention acted=yes tier=cheapo' \
  "$(printf '%s\n' "$model_end_line" | awk '/SESSION END/ {
      for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
      printf "%s acted=%s tier=%s", f["kind"], f["acted"], f["tier"]
    }')"
# 2. The FLOOR's RE_END (fleet-floor/server/floor/units.py), which D7 fences
#    this issue out of editing — so the field's position has to keep it working
#    with no change there. The regex is read out of the floor's own source
#    rather than retyped, so this red-lines if either side moves.
if command -v python3 >/dev/null 2>&1; then
  t model-floor-re-end-still-matches 'mention|yes|cheapo-unread' \
    "$(MODEL_END="$model_end_line" python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
# Execute just the two assignments the pattern is built from.
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_]+ =|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["MODEL_END"])
print("|".join([m.group(2), m.group(7), "cheapo-unread"]) if m else "NO-MATCH")
PY
)"
fi

# The mechanism is the engine's and no duty module learns the word (D7), the
# same rule #464 set for budgets. Asserted over the tree, not promised.
t model-no-duty-module-knows-about-models 0 \
  "$(grep -rlE 'MODEL_[A-Z_]+|bot_cli_model_cmd' "$SHARED/lib/duty-"*.sh 2>/dev/null | wc -l)"

# --- the session's peak RSS (#473) -----------------------------------------
#
# The fixture allocates in a GRANDCHILD of the dispatch subshell and RELEASES
# it before exiting, and that shape is what both must-fail cases need: at exit
# its resident size is small and the kernel's high-water mark is not, and a
# walk that never descends the tree sees neither. `sleep` after the release,
# because a process that has already exited has no `/proc` entry to read — the
# fixture is the runaway that is still alive, which is the case that matters.
PEAK_CLI="$TMP/peak-cli.sh"
cat >"$PEAK_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c '
import time
x = bytearray(256 * 1024 * 1024)
del x
time.sleep(3)
'
printf 'exec\nfinal reply\n'
STUB
chmod +x "$PEAK_CLI"

# The SECOND fixture is the first one's opposite, and it exists to pin what
# the walk cannot see. Its allocating descendant does not sleep: it exits the
# moment it has given the memory back, so its `mm` — and the `VmHWM` the
# kernel recorded in it — is torn down long before any read lands. The root
# then outlives several intervals, so the session IS measured; the figure is
# just the root's and the spike is not in it.
#
# This is the shape codex-bot-andresmgsl drove in round 1, and pinning it is
# the answer to that finding rather than a mechanism change: the limit was
# stated in `common/session.sh`'s prose and in the PR body, and prose is the
# weaker thing this suite keeps converting into an assertion. A ruling that
# moves the reader to `getrusage(RUSAGE_CHILDREN)` or to a per-session cgroup
# `memory.peak` — both of which retain an exited descendant — flips this case
# rather than passing quietly beside it, which is exactly what a limit ought
# to do when it stops being one.
PEAK_TRANSIENT_CLI="$TMP/peak-transient-cli.sh"
cat >"$PEAK_TRANSIENT_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c 'x = bytearray(256 * 1024 * 1024); del x'
sleep 7
printf 'exec\nfinal reply\n'
STUB
chmod +x "$PEAK_TRANSIENT_CLI"

# peak_run MUTANT|- POLL CMD… — one dispatch under a poll interval, its own
# log, and a tally of the scratch files it left behind.
# shellcheck disable=SC2030,SC2031,SC2317
peak_run() (
  local mutant="$1" poll="$2"; shift 2
  local pdir="$TMP/peak-$RANDOM$RANDOM"
  mkdir -p "$pdir/logs" "$pdir/work"
  DUTY_DIR="$pdir"; LOG_DIR="$pdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  # shellcheck disable=SC1090
  [ "$mutant" = - ] || source "$mutant"
  SESSION_PEAK_POLL_S="$poll"
  run_session build fixture/peak "$pdir/work" 30 theprompt
  # The scratch file is the session's, not the log directory's: it must not
  # outlive the line it fed.
  printf 'scratch=%s\n' "$(find "$pdir/logs" -name '*.peak' | wc -l | tr -d ' ')"
)
peak_of() { sed -n 's/.* peak_rss=\([^ ]*\).*/\1/p' <<<"$1"; }
# rc, outcome and acted as one token, for the cases whose claim is that the
# REST of the line did not move.
peak_rest() {
  sed -n 's/.*SESSION END .* rc=\([^ ]*\) dur=[^ ]* outcome=\([^ ]*\) acted=\([^ ]*\).*/\1|\2|\3/p' \
    <<<"$1"
}
peak_atleast() { # peak_atleast KiB VALUE
  case "$2" in
    '' | *[!0-9]*) printf 'NOT-A-FIGURE(%s)' "$2" ;;
    *) [ "$2" -ge "$1" ] && printf 'at-least' || printf 'TOO-SMALL(%s)' "$2" ;;
  esac
}
peak_mutant() { # peak_mutant NAME SED-EXPR — mutate the module under test
  local out="$TMP/session-mutant-$1.sh"
  sed "$2" "$SHARED/lib/common/session.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/session.sh"
  then t "peak-mutation-$1-applies" applied INERT
  else t "peak-mutation-$1-applies" applied applied; fi
}

# The unit reads first, because every case below rests on them: no live
# process, no figure — which is exactly what a platform with no `VmHWM`
# produces, and it must never come back as a zero.
t peak-no-reading-from-a-dead-pid '' "$(_session_proc_hwm 2147483647)"
t peak-no-reading-from-a-dead-tree '' "$(_session_tree_hwm 2147483647)"
t peak-reader-refuses-a-missing-file '' "$(session_peak_rss "$TMP/absent.peak")"
printf 'not-a-number\n' >"$TMP/bad.peak"
t peak-reader-refuses-a-non-integer '' "$(session_peak_rss "$TMP/bad.peak")"
printf '4096\n' >"$TMP/good.peak"
t peak-reader-reads-an-integer 4096 "$(session_peak_rss "$TMP/good.peak")"

# The watcher is the session's and dies with it. A leaked one would poll a pid
# that no longer exists for as long as the box lives, once per session.
SESSION_PEAK_POLL_S=30
( sleep 0.3 ) & peak_root=$!
_session_peak_rss_start "$TMP/live.peak" "$peak_root"
peak_watcher="$_SESSION_PEAK_PID"
wait "$peak_root"
_session_peak_rss_stop
if kill -0 "$peak_watcher" 2>/dev/null; then r1=STILL-RUNNING; else r1=reaped; fi
t peak-watcher-is-reaped-with-the-session reaped "$r1"
t peak-watcher-pid-is-cleared '' "$_SESSION_PEAK_PID"
SESSION_PEAK_POLL_S=5

# D2's absence, and the rule that makes it mean one thing: a session that does
# not outlive one interval is not measured. The rest of the line is untouched
# — an unmeasured session is not a failed one.
peak_short="$(peak_run - 30 bash -c 'printf "exec\nfinal reply\n"' 2>&1)"
t peak-short-session-carries-no-field '' "$(peak_of "$peak_short")"
t peak-short-session-line-otherwise-unchanged '0|ok|yes' "$(peak_rest "$peak_short")"
t peak-scratch-file-does-not-outlive-the-session scratch=0 \
  "$(sed -n 's/^scratch=/scratch=/p' <<<"$peak_short")"

# D4, and the only shape in which measuring could ever have ended a session:
# an interval an operator mistyped, which kills the watcher on its first
# sleep. The session still runs, still reports, and the failure says NOTHING —
# a duty log is evidence, and the watcher shares its stdout.
peak_broken="$(peak_run - notanumber bash -c 'sleep 1; printf "exec\nfinal reply\n"' 2>&1)"
t peak-broken-watcher-still-completes-the-session '0|ok|yes' "$(peak_rest "$peak_broken")"
t peak-broken-watcher-carries-no-field '' "$(peak_of "$peak_broken")"
t peak-broken-watcher-says-nothing-on-the-log 0 \
  "$(grep -c 'invalid time interval' <<<"$peak_broken" || true)"

# The measured cases need a process that can allocate on demand and give it
# back. Guarded rather than assumed, as the floor's RE_END case above is.
if command -v python3 >/dev/null 2>&1; then
  peak_ctl="$(peak_run - 1 bash "$PEAK_CLI" 2>&1)"
  peak_val="$(peak_of "$peak_ctl")"
  t peak-rss-recorded-on-session-end at-least "$(peak_atleast 204800 "$peak_val")"
  t peak-measured-session-line-otherwise-unchanged '0|ok|yes' "$(peak_rest "$peak_ctl")"
  # The token is LAST, past tier=, which is what keeps every reader that
  # matched the line before this field still matching it.
  case "$peak_ctl" in
    *"tier=default peak_rss=$peak_val"*) r1=appended ;;
    *) r1=NOT-APPENDED ;;
  esac
  t peak-field-is-appended-past-tier appended "$r1"

  # Must fail: RSS read at exit instead of the kernel's high-water mark. The
  # fixture has already given the memory back by the time the first read
  # lands, so this mutation reports the small figure that hid the incident
  # this issue is built on.
  peak_mutant exit-rss 's/VmHWM:/VmRSS:/'
  peak_mut_rss="$(peak_run "$TMP/session-mutant-exit-rss.sh" 1 bash "$PEAK_CLI" 2>&1)"
  t peak-mutation-exit-rss-reports-the-freed-figure TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_mut_rss")" | sed 's/(.*//')"

  # Must fail: a walk that does not descend. The allocation is two generations
  # below the dispatch subshell, so a reader that measures only the pid it was
  # given sees `timeout` and nothing else.
  # shellcheck disable=SC2016  # the sed matches the module's literal variable
  peak_mutant no-descend 's/kids="\$(_session_proc_children "\$pid")"/kids=""/'
  peak_mut_flat="$(peak_run "$TMP/session-mutant-no-descend.sh" 1 bash "$PEAK_CLI" 2>&1)"
  t peak-mutation-no-descend-never-sees-the-allocation TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_mut_flat")" | sed 's/(.*//')"

  # THE LIMIT, asserted rather than promised. A five-second interval against a
  # descendant that lives well under one second is not a race the scheduler
  # can decide: the allocator is gone before the first read by two orders of
  # magnitude, so this reports the same thing on a loaded box as on an idle
  # one. Three claims, and the last two are why this is a limit and not a
  # defect — the session is still measured and its line is still sound.
  peak_gone="$(peak_run - 5 bash "$PEAK_TRANSIENT_CLI" 2>&1)"
  t peak-transient-descendant-is-missed TOO-SMALL \
    "$(peak_atleast 204800 "$(peak_of "$peak_gone")" | sed 's/(.*//')"
  t peak-transient-descendant-still-measures-the-root at-least \
    "$(peak_atleast 1 "$(peak_of "$peak_gone")")"
  t peak-transient-descendant-line-otherwise-unchanged '0|ok|yes' \
    "$(peak_rest "$peak_gone")"

  # Compatibility, against the two readers that exist rather than by eye —
  # the same pair #469 asserted for tier=, now with the field behind it.
  peak_end_line="$(grep 'SESSION END' <<<"$peak_ctl")"
  t peak-operator-aggregate-still-parses "build acted=yes tier=default" \
    "$(awk '/SESSION END/ {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
        printf "%s acted=%s tier=%s", f["kind"], f["acted"], f["tier"]
      }' <<<"$peak_end_line")"
  t peak-operator-aggregate-gains-the-column "$peak_val" \
    "$(awk '/SESSION END/ {
        for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
        printf "%s", f["peak_rss"]
      }' <<<"$peak_end_line")"
  t peak-floor-re-end-still-matches 'build|yes' \
    "$(PEAK_END="$peak_end_line" python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["PEAK_END"])
print("|".join([m.group(2), m.group(7)]) if m else "NO-MATCH")
PY
)"

  # Must fail (test plan, triage 2026-08-27): the field INSERTED ahead of
  # `acted=` instead of appended. This is the sharpest of the must-fails
  # because it does not look like a failure: `RE_END` ends in an OPTIONAL
  # `acted=… reply_tail=…` group, so the line still matches — the group simply
  # stops participating, and `acted` and `reply_tail` go silently missing from
  # every line the floor reads, on every box, for as long as nobody notices.
  # The mutation removes the appended field at the same time, so what is
  # measured is the POSITION and not the presence of a second token.
  # shellcheck disable=SC2016  # the sed matches the module's literal variables
  peak_mutant inserted-field \
    's/ acted=$acted/ peak_rss=999999 acted=$acted/; s/${peak_rss:+ peak_rss=$peak_rss}//'
  peak_mut_ins="$(peak_run "$TMP/session-mutant-inserted-field.sh" 30 \
    bash -c 'printf "exec\nfinal reply\n"' 2>&1)"
  t peak-mutation-inserted-field-drops-acted-and-reply-tail 'build|None|None' \
    "$(PEAK_END="$(grep 'SESSION END' <<<"$peak_mut_ins")" \
       python3 - "$SHARED/../fleet-floor/server/floor/units.py" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
ns = {"re": re}
for name in ("TS", "RE_END"):
    m = re.search(r"^%s = (.+?)(?=\n[A-Z_#]|\n\n)" % name, src, re.S | re.M)
    exec("%s = %s" % (name, m.group(1)), ns)
m = ns["RE_END"].search("2026-08-26T00:00:00Z " + os.environ["PEAK_END"])
# group(2) is the kind, which still matches; 7 and 8 are acted and reply_tail
# (units.py reads reply_tail as group(8)), and `None` is the whole finding —
# the line PARSED and lost two fields, which is why nothing would have caught
# this at the seam. A non-match would have been the safe failure.
print("|".join(str(g) for g in (m.group(2), m.group(7), m.group(8))) if m else "NO-MATCH")
PY
)"
fi

# --- D5: naming the session changed no dispatch guarantee (#473) ------------
#
# The walk needs a NAME for the session's tree before it can measure one, and
# `$!` is that name — so the dispatch is `( … ) &` plus a `wait` where it used
# to be a foreground list. D5 fences that: obtaining the name is in scope,
# changing what the line guarantees is not. Each case below is one of D5's
# properties, driven WITH the measurement live, because the claim is about the
# dispatch under the walk and not about the dispatch in isolation.
#
# `set -e` inside the runner is the point of three of them: the engine's ticks
# run under it, and the failure mode being excluded is a session ending a tick
# rather than reporting.
# shellcheck disable=SC2030,SC2031,SC2317
d5_run() ( # d5_run TMO CMD… — one dispatch, under the caller's `set -e`
  local tmo="$1"; shift
  local ddir="$TMP/d5-$RANDOM$RANDOM"
  mkdir -p "$ddir/logs" "$ddir/work"
  DUTY_DIR="$ddir"; LOG_DIR="$ddir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  SESSION_PEAK_POLL_S=1
  set -e
  run_session build fixture/d5 "$ddir/work" "$tmo" theprompt
  # Reached only if a failing session did not abort its caller — which is the
  # whole of "RUN_SESSION_RC carries the status and run_session returns 0".
  printf 'reached=yes rc=%s\n' "$RUN_SESSION_RC"
)
d5_verdict() { sed -n 's/.*SESSION END .* rc=\([^ ]*\) dur=[^ ]* outcome=\([^ ]*\).*/\1|\2/p' <<<"$1"; }
d5_atmost() { # d5_atmost SECONDS OUTPUT — the dur= on the line, bounded
  local d; d="$(sed -n 's/.*SESSION END .* dur=\([0-9]*\)s .*/\1/p' <<<"$2")"
  case "$d" in
    '' | *[!0-9]*) printf 'NO-DURATION(%s)' "$d" ;;
    *) [ "$d" -le "$1" ] && printf 'at-most' || printf 'TOO-LATE(%s)' "$d" ;;
  esac
}

# A fired timeout, beside the walk. Both halves matter: the deadline still
# fires, and its 124 still reaches the line as TIMEOUT rather than as a
# FAILED with a strange rc.
d5_slow="$(d5_run 1 bash -c 'sleep 30' 2>&1)"
t d5-a-fired-timeout-still-reports-124-and-TIMEOUT '124|TIMEOUT' "$(d5_verdict "$d5_slow")"
# `timeout -k 60` is a SECOND deadline, and a dispatch that waited it out
# would report the same rc sixty seconds late. The session's own deadline is
# the one the engine budgets against, so the bound is on the clock, not the
# status.
t d5-the-timeout-is-not-delayed-past-its-own-deadline at-most "$(d5_atmost 10 "$d5_slow")"

# A failing session: its own rc, and no abort. `set -e` is live in d5_run, so
# `reached=yes` is not decoration — it is the assertion.
d5_fail="$(d5_run 30 bash -c 'printf "exec\nfinal reply\n"; exit 3' 2>&1)"
t d5-a-failing-sessions-rc-reaches-the-line '3|FAILED' "$(d5_verdict "$d5_fail")"
t d5-a-failing-session-cannot-abort-the-caller 'reached=yes rc=3' \
  "$(grep '^reached=' <<<"$d5_fail" || true)"

# The `</dev/null` defect, driven rather than trusted: the CLI reads piped
# stdin to EOF as context, and the caller's stdin here is a while-read work
# list. Without the redirection the FIRST session swallows the rest of the
# sweep and the loop runs once — the one-iteration-loop the module's comment
# records. The stub reads stdin exactly as a CLI would.
#
# What this asserts is D5's PROPERTY and deliberately not the line, and the
# distinction is load-bearing here rather than pedantic. Measured while
# writing this: bash redirects an ASYNC command's stdin from /dev/null of its
# own accord when job control is off, which is every script — so under
# `( … ) &` the work list is held by two mechanisms, and deleting the explicit
# `</dev/null` is not observable from here. Removing it anyway would be wrong
# (it is what the shape guarantees, not what today's bash happens to do for
# it), but a case claiming to catch that would be claiming something this
# suite cannot see, so this one claims what it can: the sweep survives the
# session, which is the guarantee D5 actually fences.
d5_items="$(printf 'a\nb\nc\n' | while read -r d5_item; do
  d5_run 10 bash -c 'cat >/dev/null; printf "exec\nfinal reply\n"' >/dev/null 2>&1
  printf '%s' "$d5_item"
done)"
t d5-the-session-does-not-swallow-the-callers-work-list abc "$d5_items"

# The process group, asserted as a DIFFERENTIAL — and the differential is the
# point, because the flat reading of D5 is false and was false before this
# issue existed. Measured: GNU `timeout` puts itself in a new process group
# (`setpgid(0,0)`, absent `--foreground`) and runs the CLI there, so the
# session has never sat in the engine's own group. Job control is off in a
# script, so `&` does not create a group and did not change this; `timeout`
# did, in both shapes.
#
# So what D5 fences — "a signal delivered to the engine reaches it exactly as
# it does today" — is a claim about SAMENESS, and the honest test runs both
# dispatch shapes against one stub and compares. The old shape is spelled out
# here rather than referenced, because the thing being compared against is the
# line as it stood before this change.
#
# `/proc` and not `ps`: after `) ` the fields are state, ppid, pgrp, so f3 is
# the group. The split is on `) ` because comm can contain spaces and
# parentheses. The GROUP LEADER is identified by name rather than by pid,
# because the leader's pid is the dispatch's own and the stub has no way to
# be told it — and `comm=timeout` is the fact the verdict actually rests on.
# (Not the stub's ppid: the reads run in a pipeline, so a CLI's ppid is its
# own shell, which says nothing about the group.)
D5_PG_STUB="$TMP/d5-pg-stub.sh"
cat >"$D5_PG_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 — where to write "<pgrp> <comm of that group's leader>"
pg="$(sed 's/.*) //' /proc/self/stat | cut -d' ' -f3)"
printf '%s %s\n' "$pg" "$(cat "/proc/$pg/comm" 2>/dev/null)" >"$1"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$D5_PG_STUB"
d5_engine_pg="$(sed 's/.*) //' /proc/self/stat | cut -d' ' -f3)"
d5_pg_verdict() { # d5_pg_verdict "<pgrp> <leader comm>"
  local pg="${1%% *}" comm="${1##* }"
  [ -n "$1" ] || { printf 'NO-READING'; return; }
  [ "$pg" = "$d5_engine_pg" ] && { printf 'engines'; return; }
  [ "$comm" = timeout ] && printf 'its-own-timeouts' || printf 'SOME-OTHER-GROUP(%s)' "$comm"
}

d5_pg_new="$TMP/d5-pg-new"; rm -f "$d5_pg_new"
d5_run 10 bash "$D5_PG_STUB" "$d5_pg_new" >/dev/null 2>&1

# The dispatch exactly as it read before the measurement named it: a
# FOREGROUND list, same redirections, same `timeout -k`. Spelled out rather
# than referenced, because the thing under comparison is that old line.
d5_pg_old="$TMP/d5-pg-old"; rm -f "$d5_pg_old"
d5_oldwork="$TMP/d5-oldwork"; mkdir -p "$d5_oldwork"
( cd "$d5_oldwork" && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
    timeout -k 60 10 bash "$D5_PG_STUB" "$d5_pg_old" ) </dev/null >/dev/null 2>&1

t d5-the-dispatchs-process-group-is-what-it-was-before-the-name \
  "$(d5_pg_verdict "$(cat "$d5_pg_old" 2>/dev/null)")" \
  "$(d5_pg_verdict "$(cat "$d5_pg_new" 2>/dev/null)")"
# …and the shared value is named, so a run where BOTH shapes broke the same
# way cannot pass as agreement.
t d5-the-session-runs-in-its-own-timeouts-group its-own-timeouts \
  "$(d5_pg_verdict "$(cat "$d5_pg_new" 2>/dev/null)")"

# --- the memory ceiling (#474) ----------------------------------------------
#
# Two halves, and they fail differently. D1 (`oom_score_adj`) is asserted from
# INSIDE the CLI, because the claim is about the process the kernel will score
# and nothing the engine can observe from outside says which process that is.
# D2 (the ceiling) is asserted against a fixture that really allocates, because
# the failure being excluded is a session that keeps running.
#
# MemTotal is STUBBED in every driven case below, and that is the design rather
# than a shortcut. The ceiling is a percentage of the box, so a case that used
# the real MemTotal would have to allocate a percentage of whatever box the
# suite is on — gigabytes on a large runner, and a different figure on each.
# Stubbing the one function that reads `/proc/meminfo` fixes the ceiling at 64
# MiB everywhere; the read itself is asserted separately, against `/proc`.

# mem_run MUTANT|- POLL CONF CMD… — one dispatch under a memory ceiling. CONF
# is shell text eval'd in the runner: the conf keys, and the MemTotal stub.
# shellcheck disable=SC2030,SC2031,SC2317
mem_run() (
  local mutant="$1" poll="$2" conf="$3"; shift 3
  local mdir="$TMP/mem-$RANDOM$RANDOM"
  mkdir -p "$mdir/logs" "$mdir/work"
  DUTY_DIR="$mdir"; LOG_DIR="$mdir/logs"; DUTY_TICK_ID="tick-1"
  BOT_CLI_CMD=("$@")
  bot_session_acted() { grep -qx exec "$1"; }
  alert() { :; }
  # shellcheck disable=SC1090
  [ "$mutant" = - ] || source "$mutant"
  SESSION_PEAK_POLL_S="$poll"
  SESSION_MEM_KILL_GRACE_S=1
  eval "$conf"
  run_session build fixture/mem "$mdir/work" 60 theprompt
  # `reached=` is the assertion and not decoration: the must-fail this suite
  # owes is a ceiling that ends the ENGINE rather than the session, and the
  # engine here is this subshell. A line printed after run_session returned is
  # the only evidence that survives it.
  #
  # `terminal=` is the second: a session the ceiling killed is not a vendor
  # failure, so it must leave no per-lane terminal-breaker state behind.
  printf 'reached=yes rc=%s scratch=%s terminal=%s engine-adj=%s\n' \
    "$RUN_SESSION_RC" \
    "$(find "$mdir/logs" \( -name '*.peak' -o -name '*.mem' \) | wc -l | tr -d ' ')" \
    "$(find "$mdir" -name '.session-terminal.*' | wc -l | tr -d ' ')" \
    "$( { read -r a </proc/self/oom_score_adj; printf '%s' "$a"; } 2>/dev/null )"
)
mem_field() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2" | tail -1; }
mem_outcome() { sed -n 's/.*SESSION END .* outcome=\([^ ]*\).*/\1/p' <<<"$1"; }
mem_dur() { sed -n 's/.*SESSION END .* dur=\([0-9]*\)s .*/\1/p' <<<"$1"; }
mem_mutant() { # mem_mutant NAME SED-EXPR — mutate the module under test
  local out="$TMP/session-mem-mutant-$1.sh"
  sed "$2" "$SHARED/lib/common/session.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/session.sh"
  then t "mem-mutation-$1-applies" applied INERT
  else t "mem-mutation-$1-applies" applied applied; fi
}
# The stub every driven case shares: a 256 MiB box, so 25% is a 64 MiB ceiling
# and the allocating fixture below is four times over it.
MEM_STUB_CONF='_session_mem_total_kib() { printf 262144; }'

# --- D3: what the conf resolves to, before anything is dispatched -----------
#
# `_session_mem_pct` is the whole of the per-role rule, so it is asserted
# directly rather than inferred from a session's fate. Each case runs in its
# own subshell: these are conf variables, and one leaking into the next would
# make the suite's own order load-bearing.
mem_pct() ( eval "$1"; _session_mem_pct )
t mem-pct-unset-is-no-ceiling '' "$(mem_pct 'BOT_ROLES=builder')"
t mem-pct-zero-is-no-ceiling '' "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=0')"
t mem-pct-fleet-value-is-read 60 "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60')"
# The acceptance criterion, in the direction that actually distinguishes an
# override from a minimum: the role value wins even when it is LARGER.
t mem-pct-role-override-wins-downward 20 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_BUILDER=20')"
t mem-pct-role-override-wins-upward 70 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=20; SESSION_MEM_MAX_PCT_BUILDER=70')"
# A role this box does not carry says nothing about it.
t mem-pct-other-roles-override-is-not-read 60 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_TRIAGE=20')"
# BOT_ROLES is a list, and the box is one box: the tighter bound governs.
t mem-pct-multi-role-takes-the-tightest 30 \
  "$(mem_pct 'BOT_ROLES="builder reviewer"; SESSION_MEM_MAX_PCT_BUILDER=70; SESSION_MEM_MAX_PCT_REVIEWER=30')"
# …and 0 means "this role names no ceiling", never "this role forbids one".
t mem-pct-a-role-at-zero-does-not-disarm-a-sibling 30 \
  "$(mem_pct 'BOT_ROLES="builder reviewer"; SESSION_MEM_MAX_PCT_BUILDER=0; SESSION_MEM_MAX_PCT_REVIEWER=30')"
t mem-pct-a-non-numeric-override-is-ignored 60 \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=60; SESSION_MEM_MAX_PCT_BUILDER=half')"
t mem-pct-a-non-numeric-fleet-value-is-no-ceiling '' \
  "$(mem_pct 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=most')"

# The conf file ships the mechanism OFF, which is the last acceptance
# criterion read at its source rather than through a dispatch.
t mem-conf-ships-every-value-off 0 \
  "$(grep -c '^SESSION_MEM_MAX_PCT\(_[A-Z]*\)\?=[^0]' "$SHARED/conf/fleet.defaults.conf" || true)"
t mem-conf-declares-a-row-per-shipped-role 3 \
  "$(grep -c '^SESSION_MEM_MAX_PCT_' "$SHARED/conf/fleet.defaults.conf" || true)"

# The MemTotal read, against `/proc` and not against a stub — the one case the
# stub above would otherwise hide.
t mem-total-matches-proc-meminfo \
  "$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)" "$(_session_mem_total_kib)"
mem_ceiling() ( eval "$1"; eval "$MEM_STUB_CONF"; _session_mem_ceiling_kib )
t mem-ceiling-is-a-percentage-of-memtotal 65536 \
  "$(mem_ceiling 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=25')"
t mem-ceiling-unconfigured-is-nothing '' "$(mem_ceiling 'BOT_ROLES=builder')"
# A percentage so small it rounds to nothing is nothing, never a ceiling of 0
# that every session is instantly over.
t mem-ceiling-rounding-to-zero-is-no-ceiling '' \
  "$(mem_ceiling 'BOT_ROLES=builder; SESSION_MEM_MAX_PCT=0')"

# --- the walk, and the process it must never return ------------------------
t mem-no-pids-from-a-dead-tree '' "$(_session_tree_pids 2147483647)"
t mem-no-pids-from-pid-one '' "$(_session_tree_pids 1)"
t mem-reader-refuses-a-missing-mark '' "$(session_mem_hit "$TMP/absent.mem")"
printf 'not-a-number\n' >"$TMP/bad.mem"
t mem-reader-refuses-a-non-integer '' "$(session_mem_hit "$TMP/bad.mem")"
printf '70000\n' >"$TMP/good.mem"
t mem-reader-reads-an-integer 70000 "$(session_mem_hit "$TMP/good.mem")"

# MUST FAIL (test plan): a ceiling that terminates the engine's own process
# rather than the session tree. Asserted at the guard that decides it and NOT
# by driving a mutant kill — a mutation that really signalled `$$` from inside
# a dispatch would take this suite's own shell down with it, so the case that
# proves the guard has to be the one that does not need it.
mem_self() { grep -c "\\b$$\\b" <<<" $(_session_tree_pids "$$") " || true; }
t mem-the-walk-never-returns-the-engines-own-pid 0 "$(mem_self)"
# shellcheck disable=SC2016  # the sed matches the module's literal guard
mem_mutant no-self-guard 's/^      \[ "\$pid" != "\$\$" \] || continue$//'
# shellcheck disable=SC1090,SC1091,SC2317
mem_self_mutant() ( source "$TMP/session-mem-mutant-no-self-guard.sh"; mem_self )
t mem-mutation-no-self-guard-returns-the-engine 1 "$(mem_self_mutant)"

# --- the containment identity: what the walk alone cannot hold (round 1) ----
#
# A pid walk is not a bound. A descendant that handles TERM by forking a
# replacement and exiting leaves that replacement reparented to PID 1, so it is
# in neither the pre-TERM snapshot (it did not exist) nor the post-grace re-walk
# (nothing rooted at the session reaches it) — the session's record says it was
# bounded while something holding its allocation runs on with no clock and no
# ceiling over it. That is the 2026-08-14 shape one level down, and it is what
# the session's own process group closes: `timeout` calls `setpgid(0,0)` absent
# `--foreground`, and a reparented child that never called `setsid()` never
# leaves the group it was forked into.

# The group read, first. The parse is past the LAST `)` because `comm` is
# parenthesised and may itself contain spaces and parentheses — the case below
# is a real process with a real name that a field-5-from-the-start parse gets
# wrong, not a synthetic string.
mem_pgid_naive() { awk '{ print $5 }' "/proc/$1/stat" 2>/dev/null; }
t mem-pgid-of-a-dead-pid-is-nothing '' "$(_session_proc_pgid 2147483647)"
sleep 30 & mem_plain_pid=$!
MEM_PAREN_BIN="$TMP/a (b) c"
cp "$(command -v sleep)" "$MEM_PAREN_BIN"
"$MEM_PAREN_BIN" 30 & mem_paren_pid=$!
# Both are background children of THIS shell, and job control is off in a
# script, so `&` creates no group: they are both in the suite's own group. That
# is the oracle — no external `ps` and no second copy of the parse.
t mem-pgid-agrees-with-a-naive-parse-on-a-plain-comm \
  "$(mem_pgid_naive "$mem_plain_pid")" "$(_session_proc_pgid "$mem_plain_pid")"
t mem-pgid-survives-parentheses-in-comm \
  "$(_session_proc_pgid "$mem_plain_pid")" "$(_session_proc_pgid "$mem_paren_pid")"
# …and the hazard is real rather than theoretical: the naive parse returns the
# STATE letter for this process, which is what shifting on the first `)` does.
mem_paren_naive_verdict() {
  [ "$(mem_pgid_naive "$mem_paren_pid")" = "$(_session_proc_pgid "$mem_paren_pid")" ] \
    && printf 'NAIVE-PARSE-WOULD-HAVE-DONE' || printf differs
}
t mem-pgid-a-naive-parse-is-what-this-avoids differs "$(mem_paren_naive_verdict)"
t mem-pgid-of-a-comm-with-parens-is-still-the-suites-group \
  "$(mem_pgid_naive "$mem_plain_pid")" "$(_session_proc_pgid "$mem_paren_pid")"
kill -KILL "$mem_plain_pid" "$mem_paren_pid" 2>/dev/null || :
wait "$mem_plain_pid" "$mem_paren_pid" 2>/dev/null || :

# The refusal, which is `_session_tree_pids`'s `$$` guard one level up and the
# more important of the two: a group kill aimed at the engine's group takes the
# engine, this watchdog and every sibling session with it.
mem_groups_of() { # mem_groups_of PIDS… — the group list, whitespace-normalised
  local -a g=()
  read -r -a g <<<"$(_session_mem_groups "$@")"
  printf '%s' "${g[*]-}"
}
t mem-the-groups-never-name-the-engines-own-group '' "$(mem_groups_of "$$")"
# A group that is NOT the engine's is named — otherwise the case above would
# pass on a function that always returns nothing. `timeout` puts itself in a
# group of its own with `setpgid(0,0)`, so the group id is its own pid: an
# expectation that does not go through the function under test.
timeout 30 sleep 30 & mem_tmo_pid=$!
sleep 0.5
t mem-a-group-outside-the-engines-is-named "$mem_tmo_pid" "$(mem_groups_of "$mem_tmo_pid")"
t mem-a-group-is-named-once-however-many-pids-sit-in-it "$mem_tmo_pid" \
  "$(mem_groups_of "$mem_tmo_pid" "$mem_tmo_pid" "$mem_tmo_pid")"
kill -KILL "$mem_tmo_pid" 2>/dev/null || :
wait "$mem_tmo_pid" 2>/dev/null || :
# MUST FAIL: the refusal removed. The mutation is the guard deleted, and under
# it the engine's own group is returned — the list a group kill is taken from.
# shellcheck disable=SC2016  # the sed matches the module's literal guard
mem_mutant no-group-self-guard 's/^    \[ "\$grp" != "\$self" \] || continue$//'
# shellcheck disable=SC1090,SC1091,SC2317
mem_group_self_mutant() (
  source "$TMP/session-mem-mutant-no-group-self-guard.sh"
  [ -n "$(_session_mem_groups "$$")" ] && printf RETURNS-THE-ENGINES-GROUP || printf refused
)
t mem-mutation-no-group-self-guard-returns-the-engines-group \
  RETURNS-THE-ENGINES-GROUP "$(mem_group_self_mutant)"

# The escape itself, driven end to end against `_session_mem_terminate`.
#
# Driven HERE rather than only through a dispatch, and the reason is coverage
# on every runner: the ceiling's own cases need a fixture that really allocates
# and so sit behind `python3`, while the defect this closes is about signals
# and not about memory at all. This case needs neither python3 nor a ceiling.
MEM_ESCAPE_STUB="$TMP/mem-escape-stub.sh"
cat >"$MEM_ESCAPE_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 — where to record the replacement's pid; $2 — the readiness file.
# The escape, exactly as both reviewers drove it: handle TERM by forking a
# replacement and exiting. The replacement is reparented to PID 1 the moment
# this shell goes, and it never calls setsid(), so the session's GROUP is the
# only identity that still holds it.
trap 'sleep 30 & printf "%s\n" "$!" >"$1"; exit 0' TERM
printf ready >"$2"
# `wait` and not a bare `sleep`: bash runs a trap when a foreground `wait` is
# interrupted, which is what makes the handler above reachable at all.
sleep 30 &
wait $!
STUB
# mem_escape MUTANT|- — start a session-shaped tree, terminate it, and say
# whether the replacement outlived the terminator. Prints the verdict.
# shellcheck disable=SC2030,SC2031,SC2317
mem_escape() (
  local pidfile="$TMP/escape-$RANDOM$RANDOM.pid" ready="$TMP/escape-$RANDOM$RANDOM.ready"
  local root rep i
  rm -f "$pidfile" "$ready"
  SESSION_MEM_KILL_GRACE_S=1
  # shellcheck disable=SC1090
  [ "$1" = - ] || source "$1"
  # The dispatch's own shape: `timeout` is the root, so the tree's group is the
  # one `timeout` made for itself — the same identity a real session has.
  timeout -k 60 30 bash "$MEM_ESCAPE_STUB" "$pidfile" "$ready" >/dev/null 2>&1 &
  root=$!
  for i in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.1; done
  [ -s "$ready" ] || { printf 'FIXTURE-NEVER-READY'; kill -KILL "$root" 2>/dev/null; return 0; }
  _session_mem_terminate "$root"
  wait "$root" 2>/dev/null || :
  rep="$(cat "$pidfile" 2>/dev/null)"
  case "$rep" in '' | *[!0-9]*) printf 'NO-REPLACEMENT-FORKED(%s)' "$rep"; return 0 ;; esac
  if kill -0 "$rep" 2>/dev/null; then
    kill -KILL "$rep" 2>/dev/null || :
    printf 'SURVIVED'
  else
    printf reaped
  fi
)
t mem-a-term-handler-that-forks-does-not-outlive-the-terminator reaped "$(mem_escape -)"
# MUST FAIL (round 1): the group pass removed. One line — the collector made to
# return nothing — which is "forgetting the group" in its smallest form, and
# under it the very same replacement survives the terminator. This is the case
# that reds against the head this round was opened on.
# shellcheck disable=SC2016  # the sed matches the module's literal assignment
mem_mutant no-group-pass 's/^  self="\$(_session_proc_pgid "\$\$")"$/  return 0/'
t mem-mutation-no-group-pass-lets-the-replacement-survive SURVIVED \
  "$(mem_escape "$TMP/session-mem-mutant-no-group-pass.sh")"

# The grace between TERM and KILL is validated like every other numeric in the
# module. An unvalidated one makes `sleep` fail instantly and collapses the
# grace to zero, landing TERM and KILL back to back — which defeats the one
# reason TERM goes first, letting the CLI flush the transcript this outcome is
# going to be read against.
mem_grace() ( eval "$1"; _session_mem_kill_grace_s )
t mem-grace-unset-is-the-default 5 "$(mem_grace 'unset SESSION_MEM_KILL_GRACE_S')"
t mem-grace-a-configured-value-is-read 2 "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=2')"
t mem-grace-a-non-numeric-value-is-the-default 5 \
  "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=soon')"
t mem-grace-an-empty-value-is-the-default 5 "$(mem_grace 'SESSION_MEM_KILL_GRACE_S=')"

# Armed but no bound applied: the operator is TOLD. The three shapes are
# separated from the unconfigured SILENCE, which is an acceptance criterion —
# reading only the resolved ceiling made "armed but unresolvable" and "not
# armed" the same answer, so the procfs-less guest the comment named was
# exactly the case that got no warning.
# shellcheck disable=SC2317
mem_start_warn() ( # mem_start_warn CONF — the warn line, if any
  # Measurable by default, so a case that is not about measurability does not
  # have to say so; CONF is eval'd after, and may take it away.
  _SESSION_PEAK_PID=1
  eval "$1"
  _session_mem_watch_start "$TMP/absent.peak" "$TMP/warn-$RANDOM.mem" 2147483647 build 2>&1 \
    | sed -n 's/.*\(session memory: .*\)/\1/p'
)
t mem-armed-but-no-memtotal-is-warned \
  'session memory: kind=build a ceiling of 25% is configured but this box'"'"'s MemTotal is unreadable — no memory bound applied' \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=25; _session_mem_total_kib() { :; }')"
t mem-armed-but-unmeasurable-is-warned 1 \
  "$(mem_start_warn "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF; _SESSION_PEAK_PID=''" \
     | grep -c 'this session is not measurable' || true)"
t mem-armed-but-rounding-to-nothing-is-warned 1 \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=1; _session_mem_total_kib() { printf 10; }' \
     | grep -c 'rounds to nothing' || true)"
# …and the silence, which is the acceptance criterion the warn must not eat.
t mem-unconfigured-warns-about-nothing '' \
  "$(mem_start_warn 'SESSION_MEM_MAX_PCT=0; _session_mem_total_kib() { :; }')"

# --- D1: oom_score_adj, read from inside the CLI ---------------------------
#
# The AC is about the process the kernel will score at the moment the CLI is
# `exec`'d, and only that process can say what its own adjustment is. The stub
# reads its own `/proc/self/oom_score_adj` — after the exec, in the process
# that will be doing the allocating.
OOM_STUB="$TMP/oom-stub.sh"
cat >"$OOM_STUB" <<'STUB'
#!/usr/bin/env bash
{ read -r adj </proc/self/oom_score_adj; } 2>/dev/null || adj=UNREADABLE
printf '%s\n' "$adj" >"$1"
printf 'exec\nfinal reply\n'
STUB
chmod +x "$OOM_STUB"
mem_oom_out="$TMP/oom-adj"; rm -f "$mem_oom_out"
mem_oom_run="$(mem_run - 30 '' bash "$OOM_STUB" "$mem_oom_out" 2>&1)"
mem_cli_adj="$(cat "$mem_oom_out" 2>/dev/null)"
mem_engine_adj="$(mem_field engine-adj "$mem_oom_run")"
mem_adj_verdict() { # mem_adj_verdict CLI ENGINE
  case "$1" in '' | *[!0-9-]*) printf 'NO-READING(%s)' "$1"; return ;; esac
  case "$2" in '' | *[!0-9-]*) printf 'NO-ENGINE-READING(%s)' "$2"; return ;; esac
  [ "$1" -gt "$2" ] || { printf 'NOT-ABOVE-ENGINE(%s<=%s)' "$1" "$2"; return; }
  # `cron` and `sshd` run at the kernel default, so clearing 0 is what the AC's
  # other two names come to. Read as a value rather than by probing their pids:
  # neither is guaranteed to be running on a box, and a case that silently
  # skips itself proves nothing.
  [ "$1" -gt 0 ] && printf 'above-engine-and-default' \
    || printf 'NOT-ABOVE-DEFAULT(%s)' "$1"
}
t mem-oom-adj-is-raised-on-the-process-that-execs-the-cli above-engine-and-default \
  "$(mem_adj_verdict "$mem_cli_adj" "$mem_engine_adj")"
t mem-oom-arming-does-not-disturb-the-session '0|ok|yes' "$(peak_rest "$mem_oom_run")"

# MUST FAIL (test plan): `oom_score_adj` set on the engine instead of on the
# child. The mutation hoists the arm out of the dispatch subshell, which is the
# single most plausible way to write this wrong — it still runs before the CLI,
# it still raises an adjustment the CLI inherits, and the only thing that moves
# is WHOSE. So the verdict cannot be "is the CLI raised": it is whether the CLI
# sits ABOVE the engine or merely level with it, which is the difference
# between the kernel preferring the session and the kernel preferring both.
# shellcheck disable=SC2016  # the sed matches the module's literal dispatch
mem_mutant oom-on-the-engine \
  's/^  ( cd "\$dir" \&\& _session_oom_arm \&\& env /  _session_oom_arm; ( cd "$dir" \&\& env /'
rm -f "$mem_oom_out"
mem_oom_mut="$(mem_run "$TMP/session-mem-mutant-oom-on-the-engine.sh" 30 '' \
  bash "$OOM_STUB" "$mem_oom_out" 2>&1)"
t mem-mutation-oom-on-the-engine-leaves-the-cli-level-with-it \
  NOT-ABOVE-ENGINE \
  "$(mem_adj_verdict "$(cat "$mem_oom_out" 2>/dev/null)" \
       "$(mem_field engine-adj "$mem_oom_mut")" | sed 's/(.*//')"

# --- D2/D4: the ceiling fires, and what it leaves behind -------------------
#
# The fixture HOLDS its allocation rather than releasing it: the case is a
# runaway that is still growing, which is the only shape a ceiling can act on.
# Its sleep is long enough that a session reaching the end of it has not been
# terminated at all — the duration bound below is what turns that into a
# verdict rather than a slow pass.
MEM_CLI="$TMP/mem-cli.sh"
cat >"$MEM_CLI" <<'STUB'
#!/usr/bin/env bash
python3 -c '
import time
x = bytearray(256 * 1024 * 1024)
time.sleep(30)
'
printf 'exec\nfinal reply\n'
STUB
chmod +x "$MEM_CLI"

# A session UNDER the ceiling, with the ceiling armed: the acceptance criterion
# that the bound is not felt by the sessions it does not bind.
mem_under="$(mem_run - 1 "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF" \
  bash -c 'sleep 3; printf "exec\nfinal reply\n"' 2>&1)"
t mem-a-session-under-the-ceiling-is-untouched '0|ok|yes' "$(peak_rest "$mem_under")"
t mem-a-session-under-the-ceiling-says-nothing 0 \
  "$(grep -c 'session memory:' <<<"$mem_under" || true)"

if command -v python3 >/dev/null 2>&1; then
  mem_hit="$(mem_run - 1 "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  t mem-crossing-the-ceiling-carries-its-own-outcome MEMORY "$(mem_outcome "$mem_hit")"
  # The kill, and not merely the label: the fixture sleeps 30s, so a session
  # that ran to its own end would report a duration near it.
  mem_killed() {
    local d; d="$(mem_dur "$1")"
    case "$d" in
      '' | *[!0-9]*) printf 'NO-DURATION(%s)' "$d" ;;
      *) [ "$d" -le 20 ] && printf terminated || printf 'RAN-TO-COMPLETION(%ss)' "$d" ;;
    esac
  }
  t mem-crossing-the-ceiling-terminates-the-session terminated "$(mem_killed "$mem_hit")"
  # The engine survives it, which is the other half of the incident: on
  # 2026-08-14 the kernel took a process out of the session's tree and the box
  # stayed down. `reached=yes` is printed after run_session returned.
  t mem-the-engine-survives-the-kill 'reached=yes' \
    "$(grep -o 'reached=yes' <<<"$mem_hit" || true)"
  # (c) logs WHY before it acts — the property it was ruled over (a) and (b)
  # for. The figure and the ceiling are both on the line.
  t mem-the-kill-is-logged-with-both-figures 1 \
    "$(grep -c 'session memory: kind=build reached [0-9]* KiB against a ceiling of 65536 KiB' <<<"$mem_hit" || true)"
  # The scratch files are the session's, not the log directory's — the `.mem`
  # marker joins `.peak` under that rule.
  t mem-scratch-files-do-not-outlive-the-session 0 "$(mem_field scratch "$mem_hit")"
  # The peak that crossed is still reported: this session is measured like any
  # other, and the figure on the line is the evidence for the outcome beside it.
  t mem-the-crossing-figure-is-still-on-the-line at-least \
    "$(peak_atleast 65536 "$(peak_of "$mem_hit")")"

  # D4's other half: a memory kill is not a VENDOR failure. With a terminal
  # hook that says yes to everything, the old ordering would have classified
  # this TERMINAL and fed the per-lane breaker — stopping a lane for a reason
  # the vendor had nothing to do with.
  mem_term="$(mem_run - 1 \
    "SESSION_MEM_MAX_PCT=25; $MEM_STUB_CONF; bot_session_terminal() { return 0; }" \
    bash "$MEM_CLI" 2>&1)"
  t mem-a-kill-is-not-a-vendor-terminal MEMORY "$(mem_outcome "$mem_term")"
  t mem-a-kill-feeds-no-terminal-breaker-state 0 "$(mem_field terminal "$mem_term")"

  # MUST FAIL (test plan): an unconfigured ceiling changing any behaviour. The
  # mutation is the one-character version of forgetting the guard — an unarmed
  # ceiling defaulting to a number instead of to nothing — and under it the
  # very same unconfigured run is killed. It targets the PERCENTAGE guard since
  # round 1 split the armed-but-unresolvable warn out of it: that guard is now
  # the one place "nothing is configured" is decided, so it is the one place
  # forgetting it can be written.
  # shellcheck disable=SC2016  # the sed matches the module's literal guard
  mem_mutant unconfigured-arms 's/^  \[ -n "\$pct" \] || return 0$/  pct="${pct:-1}"/'
  mem_unconf_ctl="$(mem_run - 1 "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  mem_unconf_mut="$(mem_run "$TMP/session-mem-mutant-unconfigured-arms.sh" 1 \
    "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  t mem-unconfigured-is-exactly-todays-behaviour ok "$(mem_outcome "$mem_unconf_ctl")"
  t mem-unconfigured-starts-no-watchdog 0 \
    "$(grep -c 'session memory:' <<<"$mem_unconf_ctl" || true)"
  t mem-mutation-unconfigured-arms-kills-an-unbounded-session MEMORY \
    "$(mem_outcome "$mem_unconf_mut")"

  # MUST FAIL (test plan, triage 2026-08-27): a change that lets
  # `_session_peak_rss_watch` end a session. This is #473's D4 as landed, and
  # the reason this issue's watchdog is a third process rather than a branch
  # inside that one. Driven with NO ceiling configured, so what the mutation
  # demonstrates is the measurement killing on its own account.
  # shellcheck disable=SC2016  # the sed matches the module's literal assignment
  mem_mutant measurement-kills 's/^      hwm="\$v"$/      hwm="$v"; kill -TERM "$root"/'
  mem_meas_mut="$(mem_run "$TMP/session-mem-mutant-measurement-kills.sh" 1 \
    "$MEM_STUB_CONF" bash "$MEM_CLI" 2>&1)"
  mem_meas_verdict() {
    case "$(mem_outcome "$1")" in
      ok) printf untouched ;;
      *) printf 'ENDED-BY-THE-MEASUREMENT(%s)' "$(mem_outcome "$1")" ;;
    esac
  }
  t mem-the-measurement-does-not-end-a-session untouched "$(mem_meas_verdict "$mem_unconf_ctl")"
  t mem-mutation-measurement-kills-ends-the-session ENDED-BY-THE-MEASUREMENT \
    "$(mem_meas_verdict "$mem_meas_mut" | sed 's/(.*//')"
fi

# …and the same must-fail read structurally, which holds on a box with no
# python3 and states the constraint rather than one of its consequences: every
# `kill` inside the measurement is a liveness probe. `kill -0` is the loop's
# own condition; anything else in there would be the measurement acting.
mem_watch_signals() {
  local body; body="$(declare -f _session_peak_rss_watch)"
  printf '%s' "$(( $(grep -c 'kill' <<<"$body" || true) \
                  - $(grep -c 'kill -0' <<<"$body" || true) ))"
}
t mem-the-measurement-only-ever-probes-liveness 0 "$(mem_watch_signals)"
t mem-the-measurement-does-not-reach-the-terminator 0 \
  "$(declare -f _session_peak_rss_watch | grep -c '_session_mem_terminate' || true)"

# ── #759 — every SESSION END says why the session was bought ──────────────
# The host writes the wake's reason; duty.sh exports it as WAKE_REASON; the
# line carries it as `why=`, one token, ahead of `sid=` which stays last.
W759_WORK="$TMP/why-work"; mkdir -p "$W759_WORK"
BOT_CLI_CMD=(bash -c 'printf "exec\nfinal reply\n"')
# shellcheck disable=SC2317  # invoked indirectly by session_acted
bot_session_acted() { grep -qx exec "$1"; }
# shellcheck disable=SC2031  # DUTY_DIR here is the suite's own; the subshell edits above were theirs
rm -f "$DUTY_DIR/.tick-acted"
w759_end="$(WAKE_REASON='ready#o/r#12,attention#o/r#3' run_session build fixture/why "$W759_WORK" 5 prompt | tail -1)"
t why-the-host-reason-is-on-the-line 1 "$(grep -c ' why=ready#o/r#12,attention#o/r#3 ' <<<"$w759_end")"
t why-sid-stays-last 1 "$(grep -cE ' why=[^ ]+ sid=[^ ]+$' <<<"$w759_end")"
# shellcheck disable=SC2031  # as above
t why-the-session-stamps-the-tick 1 "$([ -e "$DUTY_DIR/.tick-acted" ] && echo 1 || echo 0)"
w759_end="$( (unset WAKE_REASON; run_session build fixture/why2 "$W759_WORK" 5 prompt) | tail -1)"
t why-cron-when-nothing-was-written 1 "$(grep -c ' why=cron ' <<<"$w759_end")"
# shellcheck disable=SC2016  # the literal \$punct is the point: the token is sanitised, not expanded
w759_end="$(WAKE_REASON='two words; and $punct' run_session build fixture/why3 "$W759_WORK" 5 prompt | tail -1)"
t why-is-one-sanitised-token 1 "$(grep -c ' why=two_words__and__punct ' <<<"$w759_end")"
unset -f bot_session_acted

# ── #759 — tier aliases: `cheap` is what the profile says it is ────────────
w759_tier() {  # w759_tier <MODEL_BUILD value> [BOT_CLI_TIER_CHEAP value]
  # shellcheck disable=SC2034  # read by the alias resolution in _session_cli_cmd
  ( MODEL_BUILD="$1"; BOT_CLI_TIER_CHEAP="${2-}"; [ -n "${2-}" ] || unset BOT_CLI_TIER_CHEAP
    BOT_CLI_CMD=(vendor -p)
    # shellcheck disable=SC2317  # the profile hook, reached through _session_cli_cmd
    bot_cli_model_cmd() { BOT_CLI_MODEL_CMD=(vendor --model "$1" -p); }
    _session_cli_cmd build >/dev/null 2>&1; printf '%s|%s' "$_SESSION_TIER" "${_SESSION_CLI_CMD[*]}" )
}
t tier-cheap-resolves-through-the-profile "haiku|vendor --model haiku -p" "$(w759_tier cheap haiku)"
t tier-an-undefined-alias-stays-on-the-default "default|vendor -p" "$(w759_tier cheap)"
t tier-a-vendor-name-passes-through "sonnet|vendor --model sonnet -p" "$(w759_tier sonnet)"
t tier-unset-is-the-default "default|vendor -p" "$(w759_tier "")"
unset -f w759_tier
# The shipped levers are ON: every budget ceiling is a positive number and the
# repair and sweep lanes name the cheap tier.
w759_zero="$(grep -hE '^BUDGET_(SESSIONS|MINUTES)_[A-Z_]+=0$' "$SHARED/conf/fleet.defaults.conf" "$SHARED"/conf/roles/*.conf | tr '\n' ' ')"
t budgets-ship-on "" "$w759_zero"
t repair-lanes-ship-on-the-cheap-tier "MODEL_CI_RED=cheap MODEL_HYGIENE=cheap MODEL_REBASE=cheap" \
  "$(grep -hE '^MODEL_(REBASE|CI_RED|HYGIENE)=' "$SHARED"/conf/roles/*.conf | sort | tr '\n' ' ' | sed 's/ $//')"
t hygiene-sweeps-daily 1 "$(grep -c '^HYGIENE_INTERVAL=86400$' "$SHARED/conf/roles/triage.conf")"

# ── #760 — resume by default: an ok session is continued by the next dispatch ──
# The kill-resume above answers a wall-clock kill once per head; this answers
# the ordinary case — a session that ended ok and a next dispatch on the same
# kind and key — by resuming the recorded id, so the next session starts from
# where the last one stopped instead of re-reading the world.
cont_stub() { printf '%s/.session-continue.build.%s' "$TMP/sid-$1" "$2"; }
# A continuation is OF A TASK: the caller names it (SESSION_TASK), or the key
# does when it is task-shaped. These chains are all about one task.
export SESSION_TASK=task-a
c1="$(sid_run cont fixture/cont 5 reply both)"
CONT_SID="$(sid_argv_flag "$c1" --session-id)"
t cont-first-dispatch-is-pinned-not-resumed "" "$(sid_argv_flag "$c1" --resume)"
t cont-first-dispatch-minted-an-id uuid "$(sid_shape "$CONT_SID")"
t cont-an-ok-session-writes-the-continue-stub present \
  "$([ -s "$(cont_stub cont fixture_cont)" ] && printf present || printf MISSING)"
t cont-the-stub-carries-the-id "$CONT_SID" "$(sid_stub_field "$(cont_stub cont fixture_cont)" sid)"
c2="$(sid_run cont fixture/cont 5 reply both)"
t cont-the-next-dispatch-resumes-the-recorded-id "$CONT_SID" "$(sid_argv_flag "$c2" --resume)"
t cont-a-resumed-dispatch-is-not-pinned "" "$(sid_argv_flag "$c2" --session-id)"
cont_starts="$(grep 'SESSION START' "$TMP/sid-cont/records" | sed -n 's/.* sid=\([^ ]*\).*/\1/p')"
t cont-both-records-carry-one-id "$CONT_SID $CONT_SID" "$(printf '%s' "$cont_starts" | sed -n 1,2p | paste -sd' ' -)"
t cont-the-try-counts-the-chain 1 "$(sid_stub_field "$(cont_stub cont fixture_cont)" try)"
c3="$(sid_run cont fixture/elsewhere 5 reply both)"
t cont-another-key-is-another-chain "" "$(sid_argv_flag "$c3" --resume)"
# Another TASK on the same key is another chain — a build for #13 never
# resumes #12's transcript — and a session with no task identity is never
# continued at all; a task-shaped key (`repo#num`) names its own task.
c3b="$(SESSION_TASK=task-b sid_run cont fixture/cont 5 reply both)"
t cont-another-task-on-the-same-key-is-fresh "" "$(sid_argv_flag "$c3b" --resume)"
t cont-another-task-replaces-the-stub task-b "$(sid_stub_field "$(cont_stub cont fixture_cont)" task)"
(unset SESSION_TASK; sid_run cont fixture/notask 5 reply both >/dev/null)
t cont-no-task-writes-no-stub gone "$([ -e "$(cont_stub cont fixture_notask)" ] && printf present || printf gone)"
(unset SESSION_TASK; sid_run cont 'fixture/cont#5' 5 reply both >/dev/null)
t cont-a-task-shaped-key-is-its-own-task present "$([ -s "$(cont_stub cont fixture_cont_5)" ] && printf present || printf MISSING)"
c3c="$(sid_run cont fixture/cont 5 reply both)"
t cont-the-first-task-starts-over-after-the-other "" "$(sid_argv_flag "$c3c" --resume)"
# A failure breaks the chain: the next dispatch is fresh, not a resume of a
# session that failed, and the stub is gone.
sid_run cont fixture/cont 5 fail both >/dev/null
t cont-a-failed-session-forgets-the-chain gone \
  "$([ -e "$(cont_stub cont fixture_cont)" ] && printf present || printf gone)"
c4="$(sid_run cont fixture/cont 5 reply both)"
t cont-after-a-failure-the-dispatch-is-fresh "" "$(sid_argv_flag "$c4" --resume)"
# The cap: a chain at SESSION_CONTINUE_MAX_TRIES starts over.
SESSION_CONTINUE_MAX_TRIES=1
c5="$(sid_run cont fixture/cont 5 reply both)"
t cont-the-first-continuation-is-within-the-cap present "$([ -n "$(sid_argv_flag "$c5" --resume)" ] && printf present || printf MISSING)"
c6="$(sid_run cont fixture/cont 5 reply both)"
t cont-past-the-cap-the-dispatch-is-fresh "" "$(sid_argv_flag "$c6" --resume)"
SESSION_CONTINUE_MAX_TRIES=12
# A profile that cannot resume gets a fresh pinned session every time.
sid_run contpin fixture/pin 5 reply pin-only >/dev/null
c7="$(sid_run contpin fixture/pin 5 reply pin-only)"
t cont-a-profile-without-resume-stays-fresh "" "$(sid_argv_flag "$c7" --resume)"
# A transcript the profile says is gone starts fresh and clears the stub —
# read straight off the plan, with the hook answering no.
cont_plan_verdict="$(
  DUTY_DIR="$TMP/sid-contplan"; mkdir -p "$DUTY_DIR"
  printf 'sid=01a06ef6-ca2a-7fd0-a487-25913257471d\ntry=0\n' >"$DUTY_DIR/.session-continue.build.k"
  # shellcheck disable=SC2317  # invoked indirectly by the continuation path
  bot_cli_resume_args() { BOT_CLI_RESUME_ARGS=(--resume "$1"); }
  bot_session_transcript_present() { return 1; }
  _SESSION_RESUMED=no
  _session_continue_plan build k "$DUTY_DIR"
  printf '%s %s' "$_SESSION_RESUMED" "$([ -e "$DUTY_DIR/.session-continue.build.k" ] && printf present || printf gone)"
)"
t cont-a-missing-transcript-starts-fresh-and-clears-the-stub "no gone" "$cont_plan_verdict"
unset SESSION_TASK
unset -f cont_stub

suite_finish
