#!/usr/bin/env bash
# rehearsal-all.sh — run drill/rehearsal.sh once per role, one box each.
#
#   drill/rehearsal-all.sh [--agent <name>] [--tree <path>] [--remote <url>]
#     [--ref <git-ref>] [--roles "triage builder reviewer"] [--quick]
#     [--app-roster <path>]
#
# Three single-role boxes, not one multi-role box: fleet.roster deploys
# single-role members, and duty.sh gates every module on has_role. A box
# carrying all three would exercise a composite path nobody runs, and would
# hide exactly the class of defect that made a reviewer box quietly run
# triage sweeps for a whole rehearsal (heavy-duty/crew#28).
#
# The three boxes may share ONE gh identity. That is safe only because
# repos.txt is the scope for every module (heavy-duty/crew#7's doctrine
# change) and each box gets its own sandbox — disjoint registries, disjoint
# work. Under the previous org-wide review sweep all three would have seen
# each other's PRs and raced for the same verdicts.
#
# Each role runs to completion before the next starts. They are NOT
# parallelised: the boxes share an identity, and a shared identity means
# shared rate limits and interleaved duty.log evidence that nobody can read.
set -uo pipefail

ROLES="triage builder reviewer"
PASSTHRU=()
AGENT="claude"
# A green round tears itself down. Four boxes at 2 CPU / 4 GiB / 20 GiB, still
# armed and still ticking against their sandboxes, are what a rehearsal that
# passed leaves behind for no reason; a rehearsal that FAILED usually needs
# them, so a red round keeps them and says how to remove them (#217).
KEEP=0
# The fleet app is part of the rehearsal, not a separate errand: it is the
# thing an operator will be looking at when they decide whether the fleet is
# healthy, so a drill that proves the roles but never the console has only
# proved half of what gets trusted. Read-only by default — see
# drill/rehearsal-app.sh for why the control verbs are opt-in.
APP=1
APP_ARGS=()
APP_ROSTER=""
# Operator-config convergence is a real-host rehearsal too. One installed box
# is enough to exercise the registry contract; running the destructive/restore
# cycle once per role adds risk without adding a distinct code path.
CONFIG_DRILL=1
CONFIG_BOX=""
CONFIG_ROLE=""
# The fleet-lifecycle leg (#656) — `crew restart/down/reset --all` over the
# round's own roster. It runs LAST of the independent phases, after the app
# passes and immediately before teardown, and the ordering is load-bearing
# rather than aesthetic: this is the only leg that STOPS boxes, snapshots them
# and rolls one back, so running it earlier would hand the app phase a fleet
# that is half down and turn a real comparison into the "NOT CREATED vs
# offline" non-comparison #494 exists to remove.
FLEET_DRILL=1
FLEET_STATUS=""
# Section A's installer driver runs once, against the first role box this
# session actually reached. It acquires the same tree/ref as the role drills.
# That box is also the config phase's box, on purpose — and the two phases only
# survive sharing it because the installer drill hires it as the identity the
# role drill gave it. When Section A named its own role instead, the config
# phase re-roled the box back: the engine warns "ROLES CHANGED" and installs
# anyway, so the drill ran on duty loops nobody meant to swap (#180).
INSTALL_DRILL=1
INSTALL_TREE=""
INSTALL_REMOTE="${CREW_DRILL_REMOTE:-https://github.com/heavy-duty/crew.git}"
INSTALL_REF="${CREW_DRILL_REF:-main}"
RESOLVED_REF=""
# Where this round's findings go, derived below from the operator's own ref —
# not from RESOLVED_REF, which is a bare commit by construction and names no
# pull request. Empty means nothing was derivable and the summary says nothing
# about where to report rather than naming a PR this round never touched (#492).
REPORT_TARGET=""
RESUME_DRILL=1
ATTENTION_DRILL=1
# The board-audit leg is TRIAGE-role, unlike the two above it: the hygiene slot
# it belongs to is triage-only (duty.sh), so its aggregate row is gated on the
# triage role having run, never the builder's.
ATTENTION_AUDIT_DRILL=1
HYGIENE_DRILL=1
BREAKER_DRILL=1
# The notifier union leg runs inside every role's phase 2, so its verdict is
# the ROUND's, not one role's: a summary row that named a single role would
# hide a half the other two boxes also exercised.
NOTIFY_DRILL=1
# The leg writes its OWN verdict here, one line per role. It cannot travel on
# rehearsal.sh's exit code: rehearsal_notify_drill returns 0 both when the
# union is asserted and when the operator channel is unreachable and the leg
# skips, so reading the role's rc printed `ok notify` for a round that asserted
# nothing — and `FAIL notify` for a role that failed somewhere else entirely.
NOTIFY_STATUS=""
# The builder-only resume leg writes its own verdict here. Its role's exit
# code also covers every other builder assertion and cannot classify this leg.
RESUME_STATUS=""
ATTENTION_STATUS=""
ATTENTION_AUDIT_STATUS=""
# Roles whose drill actually reached a box, for the app phase.
DRILLED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --agent) AGENT="$2"; PASSTHRU+=(--agent "$2"); shift 2 ;;
    --tree)
      INSTALL_TREE="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --remote)
      INSTALL_REMOTE="$2"; shift 2 ;;
    --ref)
      INSTALL_REF="$2"; shift 2 ;;
    --quick) PASSTHRU+=(--quick); shift ;;
    --reuse) PASSTHRU+=(--reuse); shift ;;
    --keep) KEEP=1; shift ;;
    --no-app) APP=0; shift ;;
    --no-config-drill) CONFIG_DRILL=0; shift ;;
    --no-install-drill) INSTALL_DRILL=0; shift ;;
    --no-resume-drill) RESUME_DRILL=0; shift ;;
    --no-attention-drill) ATTENTION_DRILL=0; shift ;;
    --no-attention-audit-drill) ATTENTION_AUDIT_DRILL=0; shift ;;
    --no-hygiene-drill) HYGIENE_DRILL=0; shift ;;
    --no-breaker-drill) BREAKER_DRILL=0; shift ;;
    --no-notify-drill) NOTIFY_DRILL=0; shift ;;
    --no-fleet-drill) FLEET_DRILL=0; shift ;;
    --app-boxes) APP_ARGS+=(--boxes "$2"); shift 2 ;;
    --app-allow-control) APP_ARGS+=(--allow-control); shift ;;
    --app-roster) APP_ROSTER="$2"; shift 2 ;;
    --app-shots) APP_ARGS+=(--shots "$2"); shift 2 ;;
    *) echo "usage: drill/rehearsal-all.sh [--agent <name>] [--roles \"triage builder reviewer\"] [--tree <path>] [--remote <url>] [--ref <git-ref>] [--quick]"
       echo "         [--reuse] [--keep] [--no-app] [--no-config-drill] [--no-install-drill] [--no-resume-drill] [--no-attention-drill] [--no-attention-audit-drill] [--no-hygiene-drill] [--no-notify-drill] [--no-breaker-drill] [--no-fleet-drill] [--app-boxes \"a b\"] [--app-allow-control]"
       echo "         [--app-roster <path>] [--app-shots <dir>]"; exit 1 ;;
  esac
done

# Validate operator input before source acquisition and the role round. The
# named pass runs last; discovering a typo there would otherwise waste the
# whole multi-role rehearsal before producing the same error.
[ -z "$APP_ROSTER" ] || [ -f "$APP_ROSTER" ] \
  || { echo "drill/rehearsal-all.sh: no app roster at '$APP_ROSTER'" >&2; exit 1; }

for role in $ROLES; do
  case "$role" in
    triage|builder|reviewer) ;;
    *) echo "unknown role '$role' (triage, builder or reviewer)"; exit 1 ;;
  esac
done

# Resolve the operator-facing branch, tag or commit once for the whole role
# round. Each role then fetches this exact object from the canonical remote;
# a branch moving after this point cannot split one record across three trees.
# GitHub permits a fork-network commit to be fetched by object ID from the
# canonical repository, so this also needs no fork URL (#490).
if [ -z "$INSTALL_TREE" ]; then
  command -v git >/dev/null \
    || { echo "phase 0: git not found on the host (source resolution needs it)" >&2; exit 1; }
  resolve_tmp="$(mktemp -d)"
  resolve_error="$resolve_tmp/fetch.err"
  git -C "$resolve_tmp" init -q
  if ! GIT_TERMINAL_PROMPT=0 git -C "$resolve_tmp" fetch --quiet --depth=1 \
      "$INSTALL_REMOTE" "$INSTALL_REF" 2>"$resolve_error"; then
    echo "phase 0: cannot resolve remote '$INSTALL_REMOTE' ref '$INSTALL_REF' to one commit: $(cat "$resolve_error")" >&2
    rm -rf -- "$resolve_tmp"
    exit 1
  fi
  RESOLVED_REF="$(git -C "$resolve_tmp" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" \
    || { echo "phase 0: remote '$INSTALL_REMOTE' ref '$INSTALL_REF' did not resolve to a commit" >&2; rm -rf -- "$resolve_tmp"; exit 1; }
  rm -rf -- "$resolve_tmp"
  PASSTHRU+=(--remote "$INSTALL_REMOTE" --ref "$RESOLVED_REF")
  SOURCE_RECORD="remote $INSTALL_REMOTE ref $INSTALL_REF"
else
  INSTALL_TREE="$(cd "$INSTALL_TREE" 2>/dev/null && pwd)" \
    || { echo "phase 0: --tree '$INSTALL_TREE' is not a readable directory" >&2; exit 1; }
  RESOLVED_REF="$(git -C "$INSTALL_TREE" rev-parse --verify HEAD 2>/dev/null)" \
    || { echo "phase 0: --tree '$INSTALL_TREE' is not a resolved git tree" >&2; exit 1; }
  SOURCE_RECORD="tree $INSTALL_TREE"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=drill/rehearsal-report.sh
. "$HERE/rehearsal-report.sh"
# --tree drills a local checkout, so a --ref passed beside it is not what was
# drilled and derives nothing. Otherwise the role boxes get the target too:
# they are handed RESOLVED_REF and could not derive it for themselves, and a
# per-role footer disagreeing with the round's summary is worse than neither.
if [ -z "$INSTALL_TREE" ]; then
  REPORT_TARGET="$(rehearsal_report_target "$INSTALL_REMOTE" "$INSTALL_REF")" \
    || REPORT_TARGET=""
  [ -z "$REPORT_TARGET" ] || PASSTHRU+=(--source-ref "$INSTALL_REF")
fi
# shellcheck source=drill/rehearsal-hygiene.sh
. "$HERE/rehearsal-hygiene.sh"
# shellcheck source=drill/rehearsal-breaker.sh
. "$HERE/rehearsal-breaker.sh"
# Sourced for rehearsal_notify_worst_verdict alone — the fold belongs beside
# the leg that writes the lines, not retyped here where the two could drift.
# shellcheck source=drill/rehearsal-notify.sh
. "$HERE/rehearsal-notify.sh"
# Sourced for fleet_worst_verdict alone, on the same reasoning: the fold belongs
# beside the classifiers the leg writes its verdicts with, not retyped here
# where the two could drift.
# shellcheck source=drill/fleet-lifecycle.sh
. "$HERE/fleet-lifecycle.sh"
NOTIFY_STATUS="$(mktemp)"
RESUME_STATUS="$(mktemp)"
ATTENTION_STATUS="$(mktemp)"
ATTENTION_AUDIT_STATUS="$(mktemp)"
APP_AGREEMENT_STATUS="$(mktemp)"
APP_OUTPUT="$(mktemp)"
FLEET_STATUS="$(mktemp)"
# One row per independently runnable leg. The final record is checked against
# this list before it is printed: adding a leg here without wiring a result is
# therefore a visible red row, never an absence that looks like coverage.
declare -a DECLARED_LEGS=(
  hygiene breaker resume attention attention-audit notify
  installer config app browser app-armed fleet teardown
)

leg_is_declared() {
  local candidate="$1" declared_leg
  for declared_leg in "${DECLARED_LEGS[@]}"; do
    [ "$candidate" != "$declared_leg" ] || return 0
  done
  return 1
}

leg_is_selected_role() {
  case " $ROLES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

declare -a SUMMARY=()
declare -a ROLE_HYGIENE_FILES=()
declare -a ROLE_BREAKER_FILES=()
declare -a ROLE_BREAKER_REASON_FILES=()
declare -a ROLE_SECTION_STATUS_FILES=()
overall=0
hygiene_result=2
breaker_result=2
breaker_reason=""
phase2_attempted=0

# shellcheck disable=SC2317  # invoked indirectly by the EXIT trap
cleanup_role_hygiene_files() {
  local result_file
  for result_file in "${ROLE_HYGIENE_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_BREAKER_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_BREAKER_REASON_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  for result_file in "${ROLE_SECTION_STATUS_FILES[@]}"; do
    rm -f -- "$result_file"
  done
  # The notify leg's verdict file goes here too, and not under a second
  # `trap … EXIT`: bash keeps exactly ONE EXIT handler, so the later trap
  # silently REPLACES the earlier one and whichever leg lost the race leaks
  # its temp file every round. One handler, both legs' temporaries.
  [ -z "${NOTIFY_STATUS:-}" ] || rm -f -- "$NOTIFY_STATUS"
  [ -z "${RESUME_STATUS:-}" ] || rm -f -- "$RESUME_STATUS"
  [ -z "${ATTENTION_STATUS:-}" ] || rm -f -- "$ATTENTION_STATUS"
  [ -z "${ATTENTION_AUDIT_STATUS:-}" ] || rm -f -- "$ATTENTION_AUDIT_STATUS"
  [ -z "${APP_AGREEMENT_STATUS:-}" ] || rm -f -- "$APP_AGREEMENT_STATUS"
  [ -z "${APP_OUTPUT:-}" ] || rm -f -- "$APP_OUTPUT"
  [ -z "${FLEET_STATUS:-}" ] || rm -f -- "$FLEET_STATUS"
}
trap cleanup_role_hygiene_files EXIT

for role in $ROLES; do
  echo
  echo "############################################################"
  echo "## $role — box crew-drill-$role"
  echo "############################################################"
  role_hygiene_file="$(mktemp)"
  role_breaker_file="$(mktemp)"
  role_breaker_reason_file="$(mktemp)"
  role_section_status_file="$(mktemp)"
  ROLE_HYGIENE_FILES+=("$role_hygiene_file")
  ROLE_BREAKER_FILES+=("$role_breaker_file")
  ROLE_BREAKER_REASON_FILES+=("$role_breaker_reason_file")
  ROLE_SECTION_STATUS_FILES+=("$role_section_status_file")
  printf '2\n' >"$role_hygiene_file"
  printf '2\n' >"$role_breaker_file"
  : >"$role_section_status_file"
  REHEARSAL_RESUME_DRILL="$RESUME_DRILL" \
  REHEARSAL_RESUME_STATUS="$RESUME_STATUS" \
  REHEARSAL_ATTENTION_DRILL="$ATTENTION_DRILL" \
  REHEARSAL_ATTENTION_STATUS="$ATTENTION_STATUS" \
  REHEARSAL_ATTENTION_AUDIT_DRILL="$ATTENTION_AUDIT_DRILL" \
  REHEARSAL_ATTENTION_AUDIT_STATUS="$ATTENTION_AUDIT_STATUS" \
  REHEARSAL_HYGIENE_DRILL="$HYGIENE_DRILL" \
  REHEARSAL_HYGIENE_RESULT_FILE="$role_hygiene_file" \
  REHEARSAL_BREAKER_DRILL="$BREAKER_DRILL" \
  REHEARSAL_BREAKER_RESULT_FILE="$role_breaker_file" \
  REHEARSAL_BREAKER_REASON_FILE="$role_breaker_reason_file" \
  REHEARSAL_NOTIFY_DRILL="$NOTIFY_DRILL" \
  REHEARSAL_NOTIFY_STATUS="$NOTIFY_STATUS" \
  REHEARSAL_SECTION_STATUS="$role_section_status_file" \
    "$HERE/rehearsal.sh" --role "$role" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
  rc=$?
  role_section_status="$(cat "$role_section_status_file" 2>/dev/null || true)"
  [ "$role_section_status" != phase2 ] || phase2_attempted=1
  role_hygiene_result="$(cat "$role_hygiene_file" 2>/dev/null || printf '2\n')"
  role_breaker_result="$(cat "$role_breaker_file" 2>/dev/null || printf '2\n')"
  role_breaker_reason="$(cat "$role_breaker_reason_file" 2>/dev/null || true)"
  rm -f -- "$role_hygiene_file"
  rm -f -- "$role_breaker_file"
  rm -f -- "$role_breaker_reason_file"
  rm -f -- "$role_section_status_file"
  case "$role_hygiene_result" in 0|1|2) ;; *) role_hygiene_result=2 ;; esac
  hygiene_result="$(rehearsal_hygiene_combine_result \
    "$hygiene_result" "$role_hygiene_result")"
  case "$role_breaker_result" in 0|1|2) ;; *) role_breaker_result=2 ;; esac
  breaker_result="$(rehearsal_breaker_combine_result \
    "$breaker_result" "$role_breaker_result")"
  if [ -z "$breaker_reason" ] && [ -n "$role_breaker_reason" ]; then
    breaker_reason="$role_breaker_reason"
  fi
  # Roles whose box the drill actually REACHED, for the independent phases
  # below. A phase-2 failure is still an installed box; the explicit status
  # keeps it from being confused with an rc=1 before the box existed (#491).
  # Handing the app drill a box that is not there recreates, in miniature, the
  # "NOT CREATED vs offline" non-comparisons this wiring exists to remove — and
  # they would now count as real comparisons under #50's floor.
  case "$rc:$role_section_status" in
    0:*|2:*|*:installed|*:phase2)
      DRILLED="$DRILLED $role"
      if [ -z "$CONFIG_BOX" ]; then
        CONFIG_BOX="crew-drill-$role"
        CONFIG_ROLE="$role"
      fi
      ;;
  esac
  # 2 is "nothing failed, but phase 2 never ran". It is NOT a pass: the role
  # loop is unproven, and collapsing it into ok is how a rehearsal that
  # tested nothing gets reported as clearing the rollout.
  case "$rc" in
    0) SUMMARY+=("ok         $role  (phase 2 ran)") ;;
    2) SUMMARY+=("INCOMPLETE $role  (phase 2 skipped — loop UNPROVEN)")
       [ "$overall" -eq 1 ] || overall=2 ;;
    *)
      case "$role_section_status" in
        phase2) SUMMARY+=("FAIL       $role  (phase 2 failed)") ;;
        installed) SUMMARY+=("FAIL       $role  (failed after install, before phase 2)") ;;
        *) SUMMARY+=("FAIL       $role  (failed before an installed box existed)") ;;
      esac
      overall=1 ;;
  esac
done

hygiene_incomplete_reason="phase 2 skipped"
[ "$phase2_attempted" -eq 0 ] \
  || hygiene_incomplete_reason="phase 2 ran without a hygiene result"
SUMMARY+=("$(rehearsal_hygiene_summary \
  "$HYGIENE_DRILL" "$DRILLED" "$hygiene_result" "$hygiene_incomplete_reason")")
SUMMARY+=("$(rehearsal_breaker_summary \
  "$BREAKER_DRILL" "$DRILLED" "$breaker_result" "$breaker_reason")")
overall="$(rehearsal_hygiene_round_result "$overall" "$hygiene_result")"
overall="$(rehearsal_breaker_round_result \
  "$overall" "$BREAKER_DRILL" "$breaker_result")"
if [ "$HYGIENE_DRILL" -ne 0 ] && [ -z "${DRILLED// /}" ]; then
  [ "$overall" -eq 1 ] || overall=2
fi

RESUME_VERDICT="$(rehearsal_worst_verdict "$(cat "$RESUME_STATUS" 2>/dev/null)")" \
  || RESUME_VERDICT=""
RESUME_WHY="${RESUME_VERDICT#* }"
RESUME_VERDICT="${RESUME_VERDICT%% *}"
if [ "$RESUME_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       resume  (--no-resume-drill)")
elif [[ " $ROLES " != *" builder "* ]]; then
  SUMMARY+=("INCOMPLETE resume  (builder role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$RESUME_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE resume  (builder phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$RESUME_VERDICT" = ok ]; then
  SUMMARY+=("ok         resume  (wake + zero-action stop)")
elif [ "$RESUME_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE resume  (leg skipped: $RESUME_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       resume  ($RESUME_WHY)")
  overall=1
fi

ATTENTION_VERDICT="$(rehearsal_worst_verdict "$(cat "$ATTENTION_STATUS" 2>/dev/null)")" \
  || ATTENTION_VERDICT=""
ATTENTION_WHY="${ATTENTION_VERDICT#* }"
ATTENTION_VERDICT="${ATTENTION_VERDICT%% *}"
if [ "$ATTENTION_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       attention  (--no-attention-drill)")
elif [[ " $ROLES " != *" builder "* ]]; then
  SUMMARY+=("INCOMPLETE attention  (builder role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$ATTENTION_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE attention  (builder phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$ATTENTION_VERDICT" = ok ]; then
  SUMMARY+=("ok         attention  (dispatch without code + timeout report)")
elif [ "$ATTENTION_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE attention  (leg skipped: $ATTENTION_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       attention  ($ATTENTION_WHY)")
  overall=1
fi

# The triage-role board-audit leg (#441). Same partition as every row above:
# `skip` is an omission the OPERATOR asked for, INCOMPLETE is one the round
# merely discovered, and a leg that never ran is never an `ok`.
ATTENTION_AUDIT_VERDICT="$(rehearsal_worst_verdict "$(cat "$ATTENTION_AUDIT_STATUS" 2>/dev/null)")" \
  || ATTENTION_AUDIT_VERDICT=""
ATTENTION_AUDIT_WHY="${ATTENTION_AUDIT_VERDICT#* }"
ATTENTION_AUDIT_VERDICT="${ATTENTION_AUDIT_VERDICT%% *}"
if [ "$ATTENTION_AUDIT_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       attention-audit  (--no-attention-audit-drill)")
elif [[ " $ROLES " != *" triage "* ]]; then
  SUMMARY+=("INCOMPLETE attention-audit  (triage role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ -z "$ATTENTION_AUDIT_VERDICT" ]; then
  SUMMARY+=("INCOMPLETE attention-audit  (triage phase 2 never reached the leg)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$ATTENTION_AUDIT_VERDICT" = ok ]; then
  SUMMARY+=("ok         attention-audit  (both shapes reported, not repaired, alerts on transition)")
elif [ "$ATTENTION_AUDIT_VERDICT" = skip ]; then
  SUMMARY+=("INCOMPLETE attention-audit  (leg skipped: $ATTENTION_AUDIT_WHY)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       attention-audit  ($ATTENTION_AUDIT_WHY)")
  overall=1
fi

# The leg's own verdict, folded across the roles that wrote one — never the
# role's exit code, which says nothing about this leg either way.
NOTIFY_VERDICT="$(rehearsal_notify_worst_verdict "$(cat "$NOTIFY_STATUS" 2>/dev/null)")" \
  || NOTIFY_VERDICT=""
NOTIFY_WHY="${NOTIFY_VERDICT#* }"
NOTIFY_VERDICT="${NOTIFY_VERDICT%% *}"
if [ "$NOTIFY_DRILL" -eq 0 ]; then
  # An omission the OPERATOR asked for is a skip; one the round merely
  # discovered is INCOMPLETE. That is this file's own partition — `skip` rows
  # are `--no-*-drill` flags and nothing else — and the distinction is the
  # whole point: the operator who knows their host has no channel says so and
  # gets a clean round, and nobody else gets one by accident.
  SUMMARY+=("skip       notify  (--no-notify-drill)")
elif [ -z "$NOTIFY_VERDICT" ]; then
  if [ -z "${DRILLED// /}" ]; then
    SUMMARY+=("INCOMPLETE notify  (no role reached a box — union UNPROVEN)")
  else
    SUMMARY+=("INCOMPLETE notify  (phase 2 never reached the leg — union UNPROVEN)")
  fi
  [ "$overall" -eq 1 ] || overall=2
elif [ "$NOTIFY_VERDICT" = ok ]; then
  SUMMARY+=("ok         notify  (repos.txt + notify-repos.txt union)")
elif [ "$NOTIFY_VERDICT" = skip ]; then
  # Reached only where the leg skipped for a reason nobody asked for — the
  # operator channel. It is NOT a pass: the union was never asserted, and a
  # round that reported one anyway is the invisible regression #423 exists to
  # end, the same shape as the INCOMPLETE role rows above.
  SUMMARY+=("INCOMPLETE notify  (leg skipped: $NOTIFY_WHY — union UNPROVEN)")
  [ "$overall" -eq 1 ] || overall=2
else
  SUMMARY+=("FAIL       notify  ($NOTIFY_WHY)")
  overall=1
fi

if [ "$INSTALL_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## Section A — versioned install and distribution"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (installer phase: no role reached a box this run — nothing safe to inspect)"
    SUMMARY+=("SKIPPED    installer  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    INSTALL_ARGS=(--box "$CONFIG_BOX")
    if [ -n "$INSTALL_TREE" ]; then
      INSTALL_ARGS+=(--tree "$INSTALL_TREE")
    else
      INSTALL_ARGS+=(--remote "$INSTALL_REMOTE" --ref "$RESOLVED_REF")
    fi
    "$HERE/install-drill.sh" "${INSTALL_ARGS[@]}"
    rc=$?
    # shellcheck disable=SC2016  # expanded by bash inside the box
    return_state="$(box exec "$CONFIG_BOX" -- bash -lc \
      'command -v crontab >/dev/null 2>&1 || exit 2
       tmp=$(mktemp) || exit 2
       error=$(mktemp) || { rm -f -- "$tmp"; exit 2; }
       if LC_ALL=C crontab -l >"$tmp" 2>"$error"; then
         if grep -F "/duty/bin/tick.sh" "$tmp" >/dev/null; then
           printf "armed\\n"
         else
           printf "disarmed\\n"
         fi
       else
         read_rc=$?
         [ "$read_rc" -eq 1 ] && grep -q "^no crontab for " "$error" ||
           { rm -f -- "$tmp" "$error"; exit "$read_rc"; }
         printf "absent\\n"
       fi
       rm -f -- "$tmp" "$error"' </dev/null)" || return_state=unreadable
    case "$return_state" in
      disarmed|absent)
        echo "- PASS: Section A returned \`$CONFIG_BOX\` disarmed" ;;
      armed)
        echo "- FAIL: Section A returned \`$CONFIG_BOX\` armed"
        rc=1 ;;
      *)
        echo "- FAIL: Section A returned \`$CONFIG_BOX\` with crontab state unreadable"
        rc=1 ;;
    esac
    case "$rc" in
      0) SUMMARY+=("ok         installer  (Section A record emitted)") ;;
      *) SUMMARY+=("FAIL       installer"); overall=1 ;;
    esac
  fi
else
  SUMMARY+=("skip       installer  (--no-install-drill)")
fi

if [ "$CONFIG_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## operator config — registry convergence on a real box"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (config phase: no role reached a box this run — nothing safe to mutate)"
    SUMMARY+=("SKIPPED    config  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    "$HERE/rehearsal-config.sh" --box "$CONFIG_BOX" --agent "$AGENT" --role "$CONFIG_ROLE"
    rc=$?
    case "$rc" in
      0) SUMMARY+=("ok         config  (operator mode + registry contract)") ;;
      *) SUMMARY+=("FAIL       config"); overall=1 ;;
    esac
  fi
else
  SUMMARY+=("skip       config  (--no-config-drill)")
fi

APP_ROW_EMITTED=0
GENERATED_APP=0
if [ "$APP" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## fleet app — crew floor against this host's boxes"
  echo "############################################################"
  # Point the app drill at the boxes THIS run just drilled, unless the operator
  # named a roster. Without this it fell through to fleet.roster, which on a
  # drill host names the real fleet's members — boxes that do not exist here —
  # so every comparison was "NOT CREATED vs offline": three assertions that
  # agree about nothing being there.
  #
  # --agent goes WITH the roles, and that pairing is the whole point. The agent
  # column selects the vendor profile both the floor and `crew status` probe
  # with, so generating the roles correctly while defaulting the agent to
  # `claude` mislabels every non-default rehearsal — and both readers then share
  # the one wrong file, so their agreement still passes. A generated fact is
  # only safer than a hand-written one if ALL of it is generated from something
  # true; the role came from the drill, the agent silently did not.
  if [ -n "${DRILLED// /}" ]; then
    APP_ARGS+=(--drill-roles "${DRILLED# }" --agent "$AGENT")
    GENERATED_APP=1
  else
    echo "## (generated app pass: no role reached a box this run — no generated member to compare)"
    SUMMARY+=("SKIPPED    app  (generated pass blocked by role install: no installed drill box)")
    SUMMARY+=("SKIPPED    browser  (generated pass blocked by role install: no installed drill box)")
    APP_ROW_EMITTED=1
    [ "$overall" -eq 1 ] || overall=2
  fi
  # Say what was left out rather than quietly narrowing: a shorter roster that
  # nobody announced reads as full coverage.
  if [ "$APP" -eq 1 ] && [ -n "${DRILLED// /}" ] && [ "${DRILLED# }" != "$ROLES" ]; then
    echo "## (app phase covers ${DRILLED# } — roles whose drill never reached a box are excluded)"
  fi
fi

if [ "$APP" -eq 0 ] && [ "$APP_ROW_EMITTED" -eq 0 ]; then
  SUMMARY+=("skip       app  (--no-app)")
  SUMMARY+=("skip       browser  (--no-app)")
  APP_ROW_EMITTED=1
fi

if [ "$APP" -eq 1 ] && [ "$GENERATED_APP" -eq 1 ]; then
  : >"$APP_AGREEMENT_STATUS"
  REHEARSAL_AGREEMENT_STATUS="$APP_AGREEMENT_STATUS" \
    "$HERE/rehearsal-app.sh" ${APP_ARGS[@]+"${APP_ARGS[@]}"} \
      | tee "$APP_OUTPUT"
  # PIPESTATUS belongs on its own line for the same reason the role rc does:
  # the app command's verdict, not tee's, is the round fact (#30).
  rc="${PIPESTATUS[0]}"
  app_agreement="$(cat "$APP_AGREEMENT_STATUS" 2>/dev/null || true)"
  case "$rc" in
    0)
      case "$app_agreement:$APP_ROSTER" in
        compared:*) SUMMARY+=("ok         app  (agreement compared; collector + page)") ;;
        could-not-compare:?*) SUMMARY+=("ok         app  (agreement could-not-compare; armed comparison follows)") ;;
        could-not-compare:)
          SUMMARY+=("INCOMPLETE app  (agreement could-not-compare: no armed, ticking, clock-skewed box)")
          [ "$overall" -eq 1 ] || overall=2 ;;
        *) SUMMARY+=("FAIL       app  (agreement verdict missing)"); overall=1 ;;
      esac ;;
    *) SUMMARY+=("FAIL       app"); overall=1 ;;
  esac
  APP_ROW_EMITTED=1

  if grep -q '^ok   browser walk against the real fleet (read-only)$' "$APP_OUTPUT"; then
    SUMMARY+=("ok         browser  (read-only browser walk executed)")
  elif browser_skip="$(sed -n 's/^skip browser walk[[:space:]]*—[[:space:]]*//p' "$APP_OUTPUT" | head -1)" \
      && [ -n "$browser_skip" ]; then
    SUMMARY+=("INCOMPLETE browser  (not executed: $browser_skip)")
    [ "$overall" -eq 1 ] || overall=2
  elif grep -q '^FAIL browser walk' "$APP_OUTPUT"; then
    SUMMARY+=("FAIL       browser  (browser walk executed and failed)")
    overall=1
  else
    SUMMARY+=("INCOMPLETE browser  (app phase emitted no browser verdict)")
    [ "$overall" -eq 1 ] || overall=2
  fi
fi

# A named roster is an additional reading after the drill-role pass, never a
# replacement for it. It also remains readable when no role reached a generated
# drill member: that failure is recorded above and must not silently suppress
# independent evidence from an already-armed member (#494).
if [ "$APP" -eq 1 ] && [ -n "$APP_ROSTER" ]; then
  echo
  echo "############################################################"
  echo "## fleet app — armed roster comparison"
  echo "############################################################"
  # Comparison-only: repeating browser or control flags would spend a second
  # walk and could mutate the armed member this pass exists only to read.
  : >"$APP_AGREEMENT_STATUS"
  REHEARSAL_AGREEMENT_STATUS="$APP_AGREEMENT_STATUS" \
    "$HERE/rehearsal-app.sh" --roster "$APP_ROSTER" --no-browser
  rc=$?
  app_agreement="$(cat "$APP_AGREEMENT_STATUS" 2>/dev/null || true)"
  case "$rc" in
    0)
      case "$app_agreement" in
        compared) SUMMARY+=("ok         app-armed  (agreement compared; named roster, no additional boxes)") ;;
        could-not-compare)
          SUMMARY+=("INCOMPLETE app-armed  (agreement could-not-compare: no armed, ticking, clock-skewed box)")
          [ "$overall" -eq 1 ] || overall=2 ;;
        *) SUMMARY+=("FAIL       app-armed  (agreement verdict missing)"); overall=1 ;;
      esac ;;
    *) SUMMARY+=("FAIL       app-armed"); overall=1 ;;
  esac
elif [ "$APP" -eq 1 ]; then
  SUMMARY+=("skip       app-armed  (not requested: no --app-roster; requires an armed member)")
else
  SUMMARY+=("skip       app-armed  (--no-app)")
fi

# The fleet-lifecycle leg (#656). LAST of the independent phases, immediately
# before teardown: it is the only one that stops boxes, cuts snapshots and rolls
# one back, so anything downstream of it would be reading a fleet this leg had
# moved. It returns the boxes standing — teardown removes them, and a red round
# leaves them for the operator to inspect the way every other leg does.
#
# The leg's row is its OWN verdict and never this script's rc, for the reason
# the notify row is: the three verbs return one number for a whole roster, so an
# rc can say "something was skipped busy" and never which box, and a leg that
# skipped every busy-box reading because the round drilled one box is not a
# pass. Same partition as every row above it — `skip` is an omission the
# OPERATOR asked for, INCOMPLETE is one the round merely discovered.
if [ "$FLEET_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## fleet lifecycle — restart/down/reset --all over this round's roster"
  echo "############################################################"
  if [ -z "${DRILLED// /}" ]; then
    echo "## (fleet phase: no role reached a box this run — no roster to drive the verbs over)"
    SUMMARY+=("SKIPPED    fleet  (blocked by role install: no installed drill box)")
    [ "$overall" -eq 1 ] || overall=2
  else
    FLEET_BOXES=""
    for drilled_role in $DRILLED; do
      FLEET_BOXES="$FLEET_BOXES crew-drill-$drilled_role"
    done
    : >"$FLEET_STATUS"
    REHEARSAL_FLEET_STATUS="$FLEET_STATUS" \
      "$HERE/rehearsal-fleet.sh" --boxes "${FLEET_BOXES# }" --agent "$AGENT" \
        --roles "${DRILLED# }"
    rc=$?
    FLEET_VERDICT="$(fleet_worst_verdict "$(cat "$FLEET_STATUS" 2>/dev/null)")" \
      || FLEET_VERDICT=""
    FLEET_WHY="${FLEET_VERDICT#* }"
    FLEET_VERDICT="${FLEET_VERDICT%% *}"
    # The rc is read FIRST and only here: a leg that fell over is a FAILURE,
    # and a leg that ran and discovered a blocker is INCOMPLETE. Asking the
    # verdict channel first would collapse the first into the second — a script
    # that died before writing anything looks exactly like one that reached no
    # case — and a round would then report a crashed leg as merely unproven.
    # This is the ONLY thing the rc is consulted for; every per-box reading
    # inside the leg comes out of the verbs' output.
    if [ "$rc" -ne 0 ] || [ "$FLEET_VERDICT" = FAIL ]; then
      SUMMARY+=("FAIL       fleet  (${FLEET_WHY:-the leg exited $rc})")
      overall=1
    elif [ -z "$FLEET_VERDICT" ]; then
      SUMMARY+=("INCOMPLETE fleet  (the leg reached no case — per-box outcomes UNPROVEN)")
      [ "$overall" -eq 1 ] || overall=2
    elif [ "$FLEET_VERDICT" = skip ]; then
      # A reading the round could not take — a one-box roster has no busy-skip
      # to exercise, and a round where nothing was refused cannot answer #652's
      # composition question either way. Not a pass: the mechanism is exactly
      # what this leg exists to prove, and reporting one it never took is the
      # invisible regression the INCOMPLETE partition exists for.
      SUMMARY+=("INCOMPLETE fleet  (leg skipped a reading: $FLEET_WHY)")
      [ "$overall" -eq 1 ] || overall=2
    else
      SUMMARY+=("ok         fleet  (per-box outcomes on restart/down/cut + restore and canary-first upgrade)")
    fi
  fi
else
  SUMMARY+=("skip       fleet  (--no-fleet-drill)")
fi

# Validate the declaration/result agreement before teardown decides whether a
# green round may remove its fixtures. Teardown's own row does not exist yet,
# but its declaration must; every other independently runnable leg must have
# exactly one result, and every non-role result must name a declared leg.
for declared_leg in "${DECLARED_LEGS[@]}"; do
  [ "$declared_leg" = teardown ] && continue
  leg_result_count=0
  for summary_row in "${SUMMARY[@]}"; do
    read -r _state row_leg _detail <<<"$summary_row"
    [ "$row_leg" != "$declared_leg" ] || leg_result_count=$((leg_result_count + 1))
  done
  [ "$leg_result_count" -eq 1 ] || overall=1
done
leg_is_declared teardown || overall=1
for summary_row in "${SUMMARY[@]}"; do
  read -r _state row_leg _detail <<<"$summary_row"
  leg_is_declared "$row_leg" || leg_is_selected_role "$row_leg" || overall=1
done

# Teardown is decided by the WHOLE round's verdict, so it runs after every
# phase and before the summary — and it gets its own summary line, because a
# cleanup that failed must not hide under a green drill.
#
# overall=2 is INCOMPLETE, not a pass: phase 2 never ran, and that is exactly
# the round whose boxes an operator needs standing to find out why. So it
# keeps them, like a failure does.
TEARDOWN_HINT="drill/teardown.sh --roles \"$ROLES\""
if [ "$KEEP" -eq 1 ]; then
  SUMMARY+=("keep       teardown  (--keep: boxes and sandbox repos RETAINED)")
elif [ "$overall" -ne 0 ]; then
  SUMMARY+=("kept       teardown  (round not green — boxes LEFT STANDING to inspect)")
else
  echo
  echo "############################################################"
  echo "## teardown — a green round removes what it created"
  echo "############################################################"
  # --yes because this ran unattended behind three role drills; the operator
  # asked for the round, and a prompt at the end of a two-hour rehearsal is a
  # prompt nobody is sitting in front of. --keep is how they say no.
  "$HERE/teardown.sh" --roles "$ROLES" --yes
  rc=$?
  # 2 is teardown's INCOMPLETE: a class it was asked to clear could not be
  # inspected at all, so `ok teardown (boxes and sandbox repos removed)` would
  # be a claim nobody measured. It gets its own row rather than collapsing
  # into FAIL, because nothing went wrong with the cleanup — the host simply
  # could not be read, and the operator needs to know which of the two it is.
  case "$rc" in
    0) SUMMARY+=("ok         teardown  (boxes and sandbox repos removed)") ;;
    2) SUMMARY+=("INCOMPLETE teardown  (part of the round could NOT be inspected — it may still stand)")
       overall=1 ;;
    *) SUMMARY+=("FAIL       teardown  (the round PASSED — this is cleanup, not the drill)")
       overall=1 ;;
  esac
fi

echo
echo "############################################################"
echo "## fleet rehearsal summary ($AGENT)"
if [ -n "$RESOLVED_REF" ]; then
  echo "## drilled source: $RESOLVED_REF ($SOURCE_RECORD)"
fi

# The inventory is the round's declaration-to-result agreement block. It is
# generated from SUMMARY rather than maintained beside it, so the detailed
# verdict and the executed/not-executed reading cannot disagree. A missing or
# duplicate result is itself recorded and reds the round.
declare -a LEG_RECORD=()
for declared_leg in "${DECLARED_LEGS[@]}"; do
  declare -a leg_rows=()
  for summary_row in "${SUMMARY[@]}"; do
    read -r _state row_leg _detail <<<"$summary_row"
    [ "$row_leg" != "$declared_leg" ] || leg_rows+=("$summary_row")
  done
  if [ "${#leg_rows[@]}" -ne 1 ]; then
    LEG_RECORD+=("not-executed $declared_leg  (recorded ${#leg_rows[@]} results; expected exactly one)")
    overall=1
    continue
  fi
  read -r leg_state _leg_name leg_detail <<<"${leg_rows[0]}"
  case "${leg_rows[0]}" in
    ok\ *|FAIL\ *)
      if [ -z "$leg_detail" ] || [ "$leg_detail" = "()" ]; then
        LEG_RECORD+=("executed $declared_leg  ($leg_state)")
      else
        LEG_RECORD+=("executed $declared_leg  ($leg_state; ${leg_detail#(}")
      fi
      ;;
    *)
      if [ -z "$leg_detail" ] || [ "$leg_detail" = "()" ]; then
        LEG_RECORD+=("not-executed $declared_leg  (missing blocker reason)")
        overall=1
      else
        LEG_RECORD+=("not-executed $declared_leg  ($leg_state; ${leg_detail#(}")
      fi
      ;;
  esac
done
for summary_row in "${SUMMARY[@]}"; do
  read -r _state row_leg _detail <<<"$summary_row"
  if ! leg_is_declared "$row_leg" && ! leg_is_selected_role "$row_leg"; then
    LEG_RECORD+=("undeclared $row_leg  (summary result has no declaration)")
    overall=1
  fi
done

echo "## declared leg states:"
printf '## leg %s\n' "${LEG_RECORD[@]}"
summary_passed=0
summary_failed=0
summary_skipped=0
for summary_row in "${SUMMARY[@]}"; do
  case "$summary_row" in
    ok\ *) summary_passed=$((summary_passed + 1)) ;;
    FAIL\ *) summary_failed=$((summary_failed + 1)) ;;
    skip\ *|SKIPPED\ *|INCOMPLETE\ *|keep\ *|kept\ *)
      summary_skipped=$((summary_skipped + 1)) ;;
  esac
done
echo "## section states: $summary_passed passed, $summary_failed failed, $summary_skipped skipped/not-run"
printf '##   %s\n' "${SUMMARY[@]}"
echo "############################################################"
if [ "$KEEP" -eq 1 ] || [ "$overall" -ne 0 ]; then
  # "remain" rather than "were kept": this line also covers a teardown that
  # ran and failed, where some of the round is gone and the rest is not. What
  # exactly survived is named above, by the teardown's own FAIL lines.
  echo "## drill boxes and sandbox repositories remain on this host."
  echo "## When you are done with them:  $TEARDOWN_HINT"
fi
if [ "$overall" -eq 2 ]; then
  rehearsal_report_footer round-incomplete "$REPORT_TARGET"
fi
exit "$overall"
