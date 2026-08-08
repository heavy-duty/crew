#!/usr/bin/env bash
# rehearsal-all.sh — run drill/rehearsal.sh once per role, one box each.
#
#   drill/rehearsal-all.sh [--agent <name>] [--tree <path>] [--remote <url>]
#     [--ref <git-ref>] [--roles "triage builder reviewer"] [--quick]
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
# Operator-config convergence is a real-host rehearsal too. One installed box
# is enough to exercise the registry contract; running the destructive/restore
# cycle once per role adds risk without adding a distinct code path.
CONFIG_DRILL=1
CONFIG_BOX=""
CONFIG_ROLE=""
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
RESUME_DRILL=1
BUILDER_RC=""
# Roles whose drill actually reached a box, for the app phase.
DRILLED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --agent) AGENT="$2"; PASSTHRU+=(--agent "$2"); shift 2 ;;
    --tree)
      INSTALL_TREE="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --remote)
      INSTALL_REMOTE="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --ref)
      INSTALL_REF="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --quick) PASSTHRU+=(--quick); shift ;;
    --reuse) PASSTHRU+=(--reuse); shift ;;
    --keep) KEEP=1; shift ;;
    --no-app) APP=0; shift ;;
    --no-config-drill) CONFIG_DRILL=0; shift ;;
    --no-install-drill) INSTALL_DRILL=0; shift ;;
    --no-resume-drill) RESUME_DRILL=0; shift ;;
    --app-boxes) APP_ARGS+=(--boxes "$2"); shift 2 ;;
    --app-allow-control) APP_ARGS+=(--allow-control); shift ;;
    --app-roster) APP_ARGS+=(--roster "$2"); shift 2 ;;
    --app-shots) APP_ARGS+=(--shots "$2"); shift 2 ;;
    *) echo "usage: drill/rehearsal-all.sh [--agent <name>] [--roles \"triage builder reviewer\"] [--tree <path>] [--remote <url>] [--ref <git-ref>] [--quick]"
       echo "         [--reuse] [--keep] [--no-app] [--no-config-drill] [--no-install-drill] [--no-resume-drill] [--app-boxes \"a b\"] [--app-allow-control]"
       echo "         [--app-roster <path>] [--app-shots <dir>]"; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -a SUMMARY=()
overall=0

for role in $ROLES; do
  case "$role" in
    triage|builder|reviewer) ;;
    *) echo "unknown role '$role' (triage, builder or reviewer)"; exit 1 ;;
  esac
  echo
  echo "############################################################"
  echo "## $role — box crew-drill-$role"
  echo "############################################################"
  REHEARSAL_RESUME_DRILL="$RESUME_DRILL" \
    "$HERE/rehearsal.sh" --role "$role" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
  rc=$?
  [ "$role" != builder ] || BUILDER_RC="$rc"
  # Roles whose box the drill actually REACHED, for the app phase below. rc=0
  # and rc=2 both mean the box was minted and installed (2 is "phase 2 skipped",
  # not "no box"); rc=1 can be a failure from before the box existed at all.
  # Handing the app drill a box that is not there recreates, in miniature, the
  # "NOT CREATED vs offline" non-comparisons this wiring exists to remove — and
  # they would now count as real comparisons under #50's floor.
  case "$rc" in
    0|2)
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
    2) SUMMARY+=("INCOMPLETE $role  (phase 2 skipped — loop UNPROVEN)"); overall=2 ;;
    *) SUMMARY+=("FAIL       $role"); overall=1 ;;
  esac
done

if [ "$RESUME_DRILL" -eq 0 ]; then
  SUMMARY+=("skip       resume  (--no-resume-drill)")
elif [ -z "$BUILDER_RC" ]; then
  SUMMARY+=("INCOMPLETE resume  (builder role omitted)")
  [ "$overall" -eq 1 ] || overall=2
elif [ "$BUILDER_RC" -eq 0 ]; then
  SUMMARY+=("ok         resume  (wake + zero-action stop)")
elif [ "$BUILDER_RC" -eq 2 ]; then
  SUMMARY+=("INCOMPLETE resume  (builder phase 2 skipped)")
else
  SUMMARY+=("FAIL       resume")
fi

if [ "$INSTALL_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## Section A — versioned install and distribution"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (installer phase: no role reached a box this run — nothing safe to inspect)"
    SUMMARY+=("FAIL       installer  (no installed drill box)")
    overall=1
  else
    INSTALL_ARGS=(--box "$CONFIG_BOX")
    if [ -n "$INSTALL_TREE" ]; then
      INSTALL_ARGS+=(--tree "$INSTALL_TREE")
    else
      INSTALL_ARGS+=(--remote "$INSTALL_REMOTE" --ref "$INSTALL_REF")
    fi
    "$HERE/install-drill.sh" "${INSTALL_ARGS[@]}"
    rc=$?
    case "$rc" in
      0) SUMMARY+=("ok         installer  (Section A record emitted)") ;;
      *) SUMMARY+=("FAIL       installer"); overall=1 ;;
    esac
  fi
fi

if [ "$CONFIG_DRILL" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## operator config — registry convergence on a real box"
  echo "############################################################"
  if [ -z "$CONFIG_BOX" ]; then
    echo "## (config phase: no role reached a box this run — nothing safe to mutate)"
    SUMMARY+=("FAIL       config  (no installed drill box)")
    overall=1
  else
    "$HERE/rehearsal-config.sh" --box "$CONFIG_BOX" --agent "$AGENT" --role "$CONFIG_ROLE"
    rc=$?
    case "$rc" in
      0) SUMMARY+=("ok         config  (operator mode + registry contract)") ;;
      *) SUMMARY+=("FAIL       config"); overall=1 ;;
    esac
  fi
fi

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
  case " ${APP_ARGS[*]-} " in
    *" --roster "*) : ;;
    *)
      if [ -n "${DRILLED// /}" ]; then
        APP_ARGS+=(--drill-roles "${DRILLED# }" --agent "$AGENT")
      else
        echo "## (app phase: no role reached a box this run — nothing to compare against)"
        APP=0
      fi ;;
  esac
  # Say what was left out rather than quietly narrowing: a shorter roster that
  # nobody announced reads as full coverage.
  if [ "$APP" -eq 1 ] && [ "${DRILLED# }" != "$ROLES" ]; then
    echo "## (app phase covers ${DRILLED# } — roles whose drill never reached a box are excluded)"
  fi
fi

if [ "$APP" -eq 1 ]; then
  "$HERE/rehearsal-app.sh" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
  # rc on its own line, like the role loop above — this file's own history is
  # why (crew#30: a bare status read inside a compound).
  rc=$?
  case "$rc" in
    0) SUMMARY+=("ok         app  (collector + page)") ;;
    *) SUMMARY+=("FAIL       app"); overall=1 ;;
  esac
fi

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
  echo "## NOT a pass: at least one role never reached phase 2. Log those boxes"
  echo "## in and re-run before reporting anything on crew PR #16."
fi
exit "$overall"
