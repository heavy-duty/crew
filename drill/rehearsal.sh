#!/usr/bin/env bash
# drill/rehearsal.sh — the duty-engine rehearsal as one host-side script.
#
# Run on a box HOST (box + rig installed), from a crew checkout:
#
#   drill/rehearsal.sh [--agent <name>] [--box <name>]
#     [--tree <clean-git-checkout>]
#     [--remote <url>] [--ref <git-ref>] [--source-ref <git-ref>]
#     [--sandbox <owner/repo>] [--quick]
#
# --source-ref is for an orchestrator, not the operator: it records the ref the
# operator named where --ref carries the commit that ref resolved to, so the
# exit footer can still say which pull request to report on.
#
# Phase 1 (pre-auth) runs unconditionally: install the engine in the drill
# box as the selected agent (claude by default) in the reviewer role and
# verify every creds-free behavior. Phase 2 runs automatically IF the box's
# gh and selected-agent CLIs are authenticated (the
# operator logs the box in between runs; the script never touches
# credentials): it mints its own GitHub fixtures — a sandbox repo under the
# HOST's gh identity, a collaborator invite the box accepts itself, an
# attention-labelled issue, a scratch PR with a review request — and
# verifies the attention wake, the review round through both one-shot
# gates, head dedup, the re-request auto-approve, and gate abuse.
#
# Every check prints `ok <name>` or `FAIL <name>`; the script exits
# non-zero if anything failed. Fixtures and the drill box are LEFT IN
# PLACE for inspection, and the box is always left disarmed with its
# pre-drill repo registry restored. Removing them is `drill/teardown.sh`,
# which rehearsal-all.sh runs for you after a green round; a re-run against
# a box that is still standing REFUSES unless you pass --reuse (#217).
#
# Companion prose: shared/docs/rehearsal.md (what each check means and why).
# shellcheck disable=SC2088  # tildes in bx "…" strings expand in the BOX's
# login shell, which is exactly where those paths live
set -uo pipefail

BOX_NAME=""
# The tracked mainline, not a fork branch. These defaulted to
# dan-claude-bot/crew @ crew/shared-duty — the #16 development branch — so long
# after that work merged the drill still rehearsed a fork's stale branch by
# default, and an operator running `drill/rehearsal.sh` with no flags tested
# code that was not what the fleet deploys. Pass --tree/--remote/--ref to
# override; --tree is what you want when drilling a clean git checkout.
REF="${CREW_DRILL_REF:-main}"
REMOTE="${CREW_DRILL_REMOTE:-https://github.com/heavy-duty/crew.git}"
# The ref the OPERATOR named, when an orchestrator resolved it before passing
# it down. rehearsal-all.sh fetches the operator's ref to one commit and hands
# every role that commit, so that three roles cannot straddle a moving branch
# (#490) — which also means $REF is a bare SHA by the time this script prints
# anything, and a SHA names no pull request. --source-ref carries the shape
# that does. Empty for a standalone run, where $REF is already the operator's.
SOURCE_REF=""
# Where this round's findings go, derived below from the source actually
# drilled. Empty means no target was derivable and the exit footers say
# nothing about where to report rather than naming a PR this round never
# touched (#492).
REPORT_TARGET=""
TREE=""
SANDBOX=""
QUICK=0
AGENT="claude"
# One box, one role — the fleet runs single-role boxes (fleet.roster), and
# a multi-role drill box would exercise a composite path nobody deploys.
# drill/rehearsal-all.sh runs the three in sequence.
ROLE="reviewer"
# A pre-existing box is REFUSED, not silently reused. Reuse is what made the
# 0.1.0 drill skip three pre-auth checks per role and leave the creds-free
# half of phase 1 unexercised (#116) — a box that is already logged in cannot
# prove what a fresh one proves. Reuse is still legitimate when the operator
# means it, so it stays available and says so in the record (#217).
REUSE=0
REUSE_NOTE=""

usage() {
  echo "usage: drill/rehearsal.sh [--agent <name>] [--role triage|builder|reviewer]"
  echo "         [--box <name>] [--tree <clean-git-checkout>] [--remote <url>] [--ref <git-ref>]"
  echo "         [--source-ref <git-ref>] [--sandbox <owner/repo>] [--reuse] [--quick]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="$2"; shift 2 ;;
    --role)    ROLE="$2"; shift 2 ;;
    --box)     BOX_NAME="$2"; shift 2 ;;
    --tree)    TREE="$2"; shift 2 ;;
    --remote)  REMOTE="$2"; shift 2 ;;
    --ref)     REF="$2"; shift 2 ;;
    --source-ref) SOURCE_REF="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --reuse)   REUSE=1; shift ;;
    --quick)   QUICK=1; shift ;;
    *) usage; exit 1 ;;
  esac
done

case "$ROLE" in
  triage|builder|reviewer) ;;
  *) echo "unknown --role '$ROLE' (triage, builder or reviewer)"; usage; exit 1 ;;
esac
# Per-role box and sandbox. Three boxes may share ONE gh identity without
# colliding *because* repos.txt is now the scope for every module: disjoint
# registries mean disjoint work. Under the old org-wide review sweep they
# would all have seen each other's PRs and raced.
[ -n "$BOX_NAME" ] || BOX_NAME="crew-drill-$ROLE"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CONF="$ROOT/shared/conf/agents/$AGENT.conf"
available_agents() {
  local f
  for f in "$ROOT"/shared/conf/agents/*.conf; do
    [ -f "$f" ] && basename "$f" .conf
  done | sort | paste -sd, -
}
case "$AGENT" in
  ''|*[!A-Za-z0-9_-]*)
    echo "unknown agent '$AGENT' — available agents: $(available_agents)" >&2
    exit 1 ;;
esac
if [ ! -f "$AGENT_CONF" ]; then
  echo "unknown agent '$AGENT' — available agents: $(available_agents)" >&2
  exit 1
fi
# The host needs only the human-facing hint. The authentication probe itself
# is sourced again and executed inside the box, against the box's filesystem.
# shellcheck source=/dev/null
. "$AGENT_CONF"
LOGIN_HINT="$AGENT_LOGIN_HINT"

PASS=0
SKIP=0
# Phase 2 is where every role loop lives. A run that never reaches it has
# proved acquisition and install and NOTHING about duty, so it must never
# be reportable as a pass — see the summary at the bottom.
PHASE2_RAN=0
# The orchestrator needs to know whether a non-zero role still left an
# installed box that independent sections can safely exercise. Exit status
# alone cannot distinguish that from a failure before the box existed (#491).
REHEARSAL_SECTION_STATUS="${REHEARSAL_SECTION_STATUS:-}"
rehearsal_section_status() {
  [ -z "$REHEARSAL_SECTION_STATUS" ] \
    || printf '%s\n' "$1" >"$REHEARSAL_SECTION_STATUS"
}
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
skip() { echo "skip $1"; SKIP=$((SKIP + 1)); }
fail() { echo "FAIL $1"; FAILS+=("$1"); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
wait_for() {  # wait_for <seconds> <name> <cmd...>
  local t="$1" name="$2"; shift 2
  local end=$((SECONDS + t))
  while [ "$SECONDS" -lt "$end" ]; do
    if "$@" >/dev/null 2>&1; then ok "$name"; return 0; fi
    sleep 10
  done
  fail "$name (timeout ${t}s)"
  return 1
}
bx() { box exec "$BOX_NAME" -- bash -lc "$1"; }
# shellcheck disable=SC2034  # read and updated by rehearsal-safety.sh
REPOS_BACKUP=""
ACQUIRE_TMP=""
BOX_TOUCHED=0
REHEARSAL_FIXTURE_REPO=""
REHEARSAL_FIXTURE_PRS=""
REHEARSAL_FIXTURE_ISSUES=""
REHEARSAL_FIXTURE_BRANCHES=""
REHEARSAL_FIXTURE_BUILDER_AUTHOR=""
REHEARSAL_FIXTURE_BUILDER_ISSUES=""
# shellcheck source=drill/rehearsal-safety.sh
. "$ROOT/drill/rehearsal-safety.sh"
# shellcheck source=drill/rehearsal-fixtures.sh
. "$ROOT/drill/rehearsal-fixtures.sh"
# shellcheck source=drill/rehearsal-notify.sh
. "$ROOT/drill/rehearsal-notify.sh"
# shellcheck source=drill/rehearsal-boot.sh
. "$ROOT/drill/rehearsal-boot.sh"
# shellcheck source=drill/rehearsal-hygiene.sh
. "$ROOT/drill/rehearsal-hygiene.sh"
# shellcheck source=drill/rehearsal-breaker.sh
. "$ROOT/drill/rehearsal-breaker.sh"
rehearsal_hygiene_record_result 2
rehearsal_breaker_record_result 2
# shellcheck source=drill/review-order.sh
. "$ROOT/drill/review-order.sh"
# shellcheck source=drill/rehearsal-report.sh
. "$ROOT/drill/rehearsal-report.sh"
# Derived once, here, so that every exit below reads one value rather than
# re-deriving it three ways. --tree drills a local checkout and is deliberately
# excluded: a --ref passed beside it is not what was drilled, and deriving a
# target from an ignored ref is the same defect in a new place.
if [ -z "$TREE" ]; then
  REPORT_TARGET="$(rehearsal_report_target "$REMOTE" "${SOURCE_REF:-$REF}")" \
    || REPORT_TARGET=""
fi
cleanup_all() {
  local rc=$?
  if [ "$BOX_TOUCHED" -eq 1 ]; then
    if declare -F rehearsal_resume_restore_cli >/dev/null 2>&1 \
        && [ "${REHEARSAL_RESUME_NOOP_SET:-0}" -eq 1 ]; then
      rehearsal_resume_restore_cli \
        || echo "WARNING: could not restore the builder CLI after the resume drill; stop the box: box down $BOX_NAME" >&2
    fi
    if [ -n "${REHEARSAL_NOTIFY_FIXTURES:-}" ]; then
      rehearsal_notify_close_fixtures || true
    fi
    if declare -F rehearsal_hygiene_cleanup >/dev/null 2>&1; then
      rehearsal_hygiene_cleanup || true
    fi
    if declare -F rehearsal_breaker_cleanup >/dev/null 2>&1; then
      rehearsal_breaker_cleanup || true
    fi
    if declare -F rehearsal_attention_cleanup >/dev/null 2>&1; then
      rehearsal_attention_cleanup || true
    fi
    if declare -F rehearsal_attention_audit_cleanup >/dev/null 2>&1; then
      rehearsal_attention_audit_cleanup || true
    fi
    rehearsal_cleanup_owned_fixtures || true
    # The cleanup's own verdict, not just the run's: it compares both
    # registries against their pre-drill contents and returns non-zero when a
    # restore left the wrong bytes, which is a red round and not a warning
    # (#423). rehearsal_cleanup returns the rc it was handed otherwise, so
    # this only ever worsens.
    rehearsal_cleanup "$rc" || rc=$?
    if command -v box >/dev/null 2>&1 && [ -n "$BOX_NAME" ]; then
      bx "rm -rf ~/.crew-engine-stage ~/.crew-engine.tgz" >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$ACQUIRE_TMP" ] && [ -d "$ACQUIRE_TMP" ]; then
    rm -rf -- "$ACQUIRE_TMP"
  fi
  # exit, not return. This script runs under `set -uo pipefail` with no -e,
  # and a `return` from an EXIT-trap function does not change the shell's
  # exit status — so rehearsal_cleanup's verdict was computed, printed, and
  # then discarded, and a standalone `--role X` round exited 0 on a registry
  # left holding the wrong bytes. `exit` sets it, and does not re-enter the
  # trap. Without this the teardown comparison's only escalation route is the
  # notify verdict, which `--no-notify-drill` switches off first.
  exit "$rc"
}

command -v box >/dev/null || { echo "box CLI not found — this runs on a box host"; exit 1; }
command -v gh  >/dev/null || { echo "gh not found on the host (phase 2 needs it)"; exit 1; }
command -v jq  >/dev/null || { echo "jq not found on the host"; exit 1; }
command -v git >/dev/null || { echo "git not found on the host (source acquisition needs it)"; exit 1; }

trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ACQUIRE_TMP="$(mktemp -d)"
if [ -n "$TREE" ]; then
  SOURCE_TREE="$(cd "$TREE" 2>/dev/null && pwd)" \
    || { echo "phase 0: --tree '$TREE' is not a readable directory"; exit 1; }
  SOURCE_DESC="tree $SOURCE_TREE"
  if ! git -C "$SOURCE_TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "phase 0: --tree '$TREE' must be a git checkout with a clean working tree" >&2
    exit 1
  fi
  TREE_STATUS_ERROR="$ACQUIRE_TMP/tree-status.err"
  if ! TREE_STATUS="$(git -C "$SOURCE_TREE" status --short --untracked-files=all 2>"$TREE_STATUS_ERROR")"; then
    echo "phase 0: could not inspect --tree '$TREE' for uncommitted changes: $(cat "$TREE_STATUS_ERROR")" >&2
    exit 1
  fi
  if [ -n "$TREE_STATUS" ]; then
    echo "phase 0: --tree '$TREE' has uncommitted changes:" >&2
    printf '%s\n' "$TREE_STATUS" >&2
    # shellcheck disable=SC2016  # explain the literal hire argument to the operator
    echo 'phase 0: refusing because SOURCE_SHA must name the tree the operator means to drill; phase 1 installs from crew hire --ref "$SOURCE_SHA"' >&2
    exit 1
  fi
else
  SOURCE_TREE="$ACQUIRE_TMP/source"
  SOURCE_DESC="remote $REMOTE ref $REF"
  git -C "$ACQUIRE_TMP" init -q source
  if ! GIT_TERMINAL_PROMPT=0 git -C "$SOURCE_TREE" fetch --quiet --depth=1 "$REMOTE" "$REF"; then
    echo "phase 0: cannot resolve remote '$REMOTE' ref '$REF'; acquisition aborted before checks" >&2
    exit 1
  fi
  if ! git -C "$SOURCE_TREE" checkout --quiet --detach FETCH_HEAD; then
    echo "phase 0: remote '$REMOTE' ref '$REF' was fetched but could not be checked out; acquisition aborted before checks" >&2
    exit 1
  fi
fi
# The drilled role's conf joins the required inputs, because the drill box is
# now minted at the size that file declares (#607 D4): a source that cannot say
# how big a $ROLE box is cannot be drilled as one. Declared here with the rest
# so the refusal is attributed the way every other missing input is, rather
# than surfacing later as a box step that stopped for its own reasons.
for required in shared/install.sh shared/test/run.sh VERSION "shared/conf/roles/$ROLE.conf"; do
  [ -f "$SOURCE_TREE/$required" ] \
    || { echo "phase 0: $SOURCE_DESC resolved, but '$required' is missing; acquisition aborted before checks" >&2; exit 1; }
done
SOURCE_SHA="$(git -C "$SOURCE_TREE" rev-parse --verify HEAD 2>/dev/null)" \
  || { echo "phase 0: $SOURCE_DESC is not a resolved git tree"; exit 1; }
echo "== phase 0: crew at $SOURCE_SHA ($SOURCE_DESC), static checks"
ENGINE_ARCHIVE="$ACQUIRE_TMP/crew-engine.tgz"
# BEGIN phase-0 archive selection: shared/test/run.sh verifies this contract.
if ! git -C "$SOURCE_TREE" archive --format=tar "$SOURCE_SHA" \
  -- . ':(exclude)fleet-floor/dev' | gzip >"$ENGINE_ARCHIVE"; then
  echo "phase 0: could not archive the tracked tree from $SOURCE_DESC at $SOURCE_SHA"
  exit 1
fi
# END phase-0 archive selection

# --- the drill box -------------------------------------------------------
# Acquisition and the --tree clean-checkout guard stay above this line: an
# input the drill refuses must not create or mutate a box before it says why.

# The drill box is minted at THE ROLE'S OWN SIZE, read out of the drilled
# source's role conf (#607 D4). It used to mint every role at a flat
# `--cpu 2 --memory 4GiB --disk 20GiB`, which is not what `crew new` does for
# any role in the fleet — so role sizing was the one thing a green rehearsal
# could never say anything about, and it took an OOM-killed reviewer to find
# that out. A size literal here is the defect, not the number it holds.
#
# From $SOURCE_TREE and not from this checkout: everything else in phase 0 is
# read out of the source actually being drilled, and a drill that sized its box
# from the operator's working tree while installing a different engine would
# rehearse a pairing that exists nowhere.
#
# Read in a SUBSHELL rather than sourced into this script's scope. A role conf
# is not three variables — it carries TIMEOUT_*, MODEL_* and BUDGET_* too, and
# sourcing it here would land every one of them in the drill's globals for the
# rest of the run. What is wanted is three figures.
ROLE_CONF="$SOURCE_TREE/shared/conf/roles/$ROLE.conf"
[ -f "$ROLE_CONF" ] \
  || { echo "phase 0: no role conf at $ROLE_CONF — the drill cannot size a $ROLE box" >&2; exit 1; }
read -r BOX_CPU BOX_MEMORY BOX_DISK <<<"$(
  bash -c '. "$1"; printf "%s %s %s\n" "${BOX_CPU:-}" "${BOX_MEMORY:-}" "${BOX_DISK:-}"' \
    _ "$ROLE_CONF" 2>/dev/null)"
if [ -z "$BOX_CPU" ] || [ -z "$BOX_MEMORY" ] || [ -z "$BOX_DISK" ]; then
  echo "phase 0: $ROLE_CONF declares no BOX_CPU/BOX_MEMORY/BOX_DISK — refusing to" >&2
  echo "         guess a size the fleet does not use" >&2
  exit 1
fi
if ! box list --json 2>/dev/null | jq -e --arg n "$BOX_NAME" '.[] | select(.name == $n)' >/dev/null; then
  # THE MINT IS NOT SPELLED HERE (#679 D9). It used to carry its own copy of
  # `box new --template "$AGENT-box"`, which box 0.10.0 refuses — so on a host
  # at the version `crew down --force` requires, this drill died at box creation
  # with `exit 1` before a single assertion ran. Gate A could not fail late and
  # be read; it could not start. Fixing cli/crew alone would have left that
  # untouched, and the round that was supposed to prove the fix would have been
  # the round that could not run.
  #
  # From $SOURCE_TREE, for the same reason and by the same rule as the role conf
  # read directly above: everything in phase 0 is read out of the source
  # actually being drilled, and a drill that minted its box by the operator's
  # working tree's sequence while installing a different engine would rehearse a
  # pairing that exists nowhere. A source that predates the helper is refused
  # here rather than falling back to a spelling this file would then own a
  # second copy of.
  MINT_LIB="$SOURCE_TREE/shared/lib/box-mint.sh"
  [ -f "$MINT_LIB" ] \
    || { echo "phase 0: no mint helper at $MINT_LIB — this source predates the" >&2
         echo "         single-writer mint sequence and the drill will not spell one" >&2
         echo "         of its own (crew#679 D9)" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$MINT_LIB"
  echo "== minting $BOX_NAME as the $AGENT tenant at the $ROLE role's size ($BOX_CPU cpu / $BOX_MEMORY / $BOX_DISK), converged by rig as $AGENT-box"
  box_mint_fresh "$BOX_NAME" "$AGENT" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK" || exit 1
elif [ "$REUSE" -eq 0 ]; then
  # `box info --json` returns an ARRAY and its date field has moved before, so
  # this degrades to "unknown" rather than killing the refusal it is only
  # decorating (#47).
  BOX_CREATED="$(box info "$BOX_NAME" --json 2>/dev/null \
    | jq -r 'if type == "array" then (.[0] // {}) else . end
             | .created_at // .createdAt // .created // "unknown"' 2>/dev/null \
    | head -1 | tr -d '\r' || true)"
  echo "phase 0: $BOX_NAME already exists (created ${BOX_CREATED:-unknown})." >&2
  echo "phase 0: refusing to reuse it — a box that is already logged in cannot prove" >&2
  echo "         the creds-free half of phase 1, and reusing one is why the 0.1.0 drill" >&2
  echo "         skipped three pre-auth checks per role (#116). Two ways forward:" >&2
  # teardown removes the drill's OWN names and nothing else, so hinting it for
  # a `--box my-scratch` is printing a command that will be refused — the same
  # complaint #217 makes about install.sh advertising `crew upgrade --all` for
  # boxes that verb cannot reach. A custom box is the operator's to clear.
  case "$BOX_NAME" in
    crew-drill|crew-drill-triage|crew-drill-builder|crew-drill-reviewer)
      echo "           drill/teardown.sh --box $BOX_NAME     # then re-run for a clean drill" >&2 ;;
    *)
      echo "           remove $BOX_NAME yourself (box rm $BOX_NAME) — teardown.sh clears only" >&2
      echo "           the drill's own names and will refuse this one — then re-run" >&2 ;;
  esac
  echo "           drill/rehearsal.sh … --reuse          # keep it, and record why" >&2
  exit 1
else
  # Recorded here AND in the summary: a record is pasted from the tail of a
  # run, and a caveat that scrolled past the top is a caveat nobody read.
  REUSE_NOTE="reused the existing box $BOX_NAME (--reuse): the pre-auth checks
   — login WARN, no .boot-id marker, no sessions spawned — SKIP on a box that is
   already gh-authenticated, so the creds-free half of phase 1 is unexercised (#116)."
  echo "== REUSE: $REUSE_NOTE"
fi
BOX_TOUCHED=1
check "box reachable" bx "true"

# shellcheck disable=SC2016  # expanded by bash inside the box
box exec "$BOX_NAME" -- bash -lc '
  set -euo pipefail
  archive="$HOME/.crew-engine.tgz"
  tmp="$(mktemp "$HOME/.crew-engine.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$archive"
' <"$ENGINE_ARCHIVE" \
  || { echo "phase 0: could not transfer the engine into $BOX_NAME"; exit 1; }
# shellcheck disable=SC2016  # expanded by bash inside the box
bx '
  set -euo pipefail
  stage="$HOME/.crew-engine-stage"
  archive="$HOME/.crew-engine.tgz"
  cleanup_failed() {
    rc=$?
    if [ "$rc" -ne 0 ]; then rm -rf "$stage" "$archive"; fi
    return "$rc"
  }
  trap cleanup_failed EXIT
  rm -rf "$stage"
  mkdir -p "$stage"
  tar xzf "$archive" -C "$stage"
  # BEGIN phase-0 suite roots: shared/test/run.sh verifies this complete set.
  test -d "$stage/.ceremony"
  test -d "$stage/.github"
  test -f "$stage/VERSION"
  test -d "$stage/cli"
  test -d "$stage/dist"
  test -d "$stage/drill"
  test -d "$stage/examples"
  test -d "$stage/fleet-floor"
  test -f "$stage/install.sh"
  test -f "$stage/shared/install.sh"
  test -f "$stage/shared/test/run.sh"
  # END phase-0 suite roots
' || { echo "phase 0: transferred engine failed verification inside $BOX_NAME"; exit 1; }
echo "== phase 0: shipped $SOURCE_SHA from $SOURCE_DESC (creds-free inside box)"
check "fixture tests green" bx "out=\$(~/.crew-engine-stage/shared/test/run.sh); grep -q 'failed 0' <<<\"\$out\""

echo "== phase 1: pre-auth engine install ($AGENT $ROLE)"
# Every drill tick is explicit. Arming cron here created an autonomous
# production bot merely to observe one scheduled boundary (#26).
# The fleet installs via `crew hire` — stage_engine + stage_fleet_definition
# (cli/crew:837) — never by calling install.sh directly. Drilling the raw
# installer exercised a path nobody deploys, and it only broke when #99 stopped
# shipping examples/: install.sh's $HERE/../examples/ fallbacks resolve in a
# checkout and can NEVER resolve on a box.
#
# The drill builds its OWN fleet definition and lists this box in its roster,
# which is hire_guard's FIRST branch — so no --allow-offroster, and no
# production registry is ever consulted, because production_registry() reads
# the SELECTED config dir (cli/crew:1071). What that registry must contain, and
# why it is neither empty nor the production one, is spelled out where it is
# written below.
DRILL_TMP="$(mktemp -d)"
DRILL_CONFIG="$DRILL_TMP/config"
CREW_BIN="$SOURCE_TREE/cli/crew"
# `crew init` takes its target POSITIONALLY and refuses a path that already
# exists (cli/crew:1783), so the target must be a not-yet-created subpath.
# CREW_CONFIG_DIR cannot name it either: that variable is validated as an
# existing fleet definition before init runs. Same shape as
# drill/rehearsal-config.sh, which has always done this correctly.
"$CREW_BIN" init "$DRILL_CONFIG" >"$DRILL_TMP/init.out" 2>&1 \
  || { echo "phase 1: crew init failed: $(cat "$DRILL_TMP/init.out")"; exit 1; }
printf '%s %s %s\n' "$BOX_NAME" "$AGENT" "$ROLE" >"$DRILL_CONFIG/fleet.roster"
# The registry must be NON-EMPTY: production_registry()'s grep exits 1 when it
# matches nothing, and under `set -o pipefail` that kills `crew hire` silently
# via set -e. `crew init` cannot supply one -- since #216 it copies an
# examples/repos.txt that ships EMPTY, precisely so a scaffold is aimed at
# nothing -- and it must never be a production registry either, because
# seeding a drill box from one is how #51 happened. So the drill writes its
# own, naming a sandbox repo it mints itself. The slug is resolvable from the HOST's gh identity
# (the BOX stays creds-free); phase 2 mints the repo itself.
DRILL_HOST_ME="$(gh api user --jq .login 2>/dev/null || echo crew-drill)"
printf '%s/crew-drill-%s\n' "$DRILL_HOST_ME" "$ROLE" >"$DRILL_CONFIG/repos.txt"
CREW_CONFIG_DIR="$DRILL_CONFIG" "$CREW_BIN" hire "$BOX_NAME" --ref "$SOURCE_SHA" \
  || fail "crew hire"
# `crew hire` removes ~/.crew-engine-stage AND ~/.crew-engine.tgz when it is
# done (cleanup_staged_engine). The drill needs the shipped tree on the box
# AFTER the hire -- for the VERSION stamp comparison, the agent-profile auth
# probe, and the raw-install.sh reinstall assertions -- so put it back. This is
# also what gives the raw installer coverage layered ON TOP of the deployed
# path, rather than instead of it.
# shellcheck disable=SC2016  # expanded by bash inside the box
box exec "$BOX_NAME" -- bash -lc '
  set -euo pipefail
  archive="$HOME/.crew-engine.tgz"
  tmp="$(mktemp "$HOME/.crew-engine.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$archive"
  stage="$HOME/.crew-engine-stage"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar xzf "$archive" -C "$stage"
  test -f "$stage/shared/install.sh"
  test -f "$stage/VERSION"
' <"$ENGINE_ARCHIVE" || fail "re-stage engine after hire"
# The drill fleet definition existed only to get through hire_guard by roster
# membership. Nothing reads it afterwards, and a per-role mktemp -d that is
# never removed leaks one fleet definition per drill into /tmp.
rm -rf "$DRILL_TMP"
rehearsal_disarm_cron || { echo "cannot disarm drill cron — refusing before any tick"; exit 1; }
version="$(bx "head -1 ~/.crew-engine-stage/VERSION" | tr -d '\r\n')"
check "VERSION stamps crew@$version" bx "out=\$(head -1 ~/duty/VERSION); grep -q '^crew@$version\\( \\|$\\)' <<<\"\$out\""
check "instance.conf $AGENT/$ROLE" bx "grep -q 'BOT_AGENT=$AGENT' ~/duty/conf/instance.conf && grep -q 'BOT_ROLES=\"$ROLE\"' ~/duty/conf/instance.conf"
check "drill is not cron-armed"    bx "out=\$(crontab -l 2>/dev/null); ! grep -q ~/duty/bin/tick.sh <<<\"\$out\""
# Reinstall with the same explicit drill identity and assert the role survived
# rather than trusting it.
check "reinstall stays disarmed"   bx "~/.crew-engine-stage/shared/install.sh --agent '$AGENT' --role '$ROLE' && { out=\$(crontab -l 2>/dev/null); ! grep -q ~/duty/bin/tick.sh <<<\"\$out\"; }"
check "reinstall keeps role"       bx "grep -q 'BOT_ROLES=\"$ROLE\"' ~/duty/conf/instance.conf"
check "bad role refused"           bx "! ~/.crew-engine-stage/shared/install.sh --agent '$AGENT' --role nosuchrole"

GH_AUTHED=0
bx "gh auth status >/dev/null 2>&1" && GH_AUTHED=1

# A hired box bylines ITSELF, and does so before its first session (#294). The
# gh credential is the source of truth and git is a copy; when the split left
# the copy behind, every commit the claude builder pushed was authored by the
# claude reviewer and the board read a one-box afternoon as a two-box race.
#
# Asserted HERE, between the install above and the tick below, on purpose: the
# engine converges on every tick too, so checking after one would prove the
# engine's half while a box that never ticked stayed wrong. Both forms of the
# address pass — provisioning writes the ID-prefixed one, and the 2026-08-02
# hand sweep wrote the bare one.
if [ "$GH_AUTHED" -eq 1 ]; then
  DRILL_BOX_ME="$(bx "gh api user --jq .login" | tr -d '\r\n')"
  check "hired box bylines itself as $DRILL_BOX_ME, before its first tick" \
    bx "out=\$(git config --global user.email); grep -qiE '^([0-9]+\\+)?$DRILL_BOX_ME@users\\.noreply\\.github\\.com\$' <<<\"\$out\""
else
  skip "hired box bylines itself (box is not gh-authenticated — no identity to copy yet)"
fi

# An authenticated engine can act on its first explicit tick. Preserve the
# operator's registry, then point the drill at nothing until its sandbox
# exists. EXIT/INT/TERM restore it and leave no cron behind.
if [ "$GH_AUTHED" -eq 1 ]; then
  rehearsal_begin_isolation \
    || { echo "cannot isolate repos.txt — refusing before any authenticated tick"; exit 1; }
fi

bx "~/duty/bin/tick.sh" || true
check "tick evidence: run start"   bx "grep -q 'duty run start' ~/duty/duty.log"
check "tick evidence: run end"     bx "grep -q 'duty run end' ~/duty/duty.log"
check "boot check ran"             bx "test -s ~/duty/boot-check.log"
# `test -s` above says the gate ran. What it SAID is the question #240 left:
# that check passes on a log whose probe line reads FAILED and on a log full
# of WARN. Both assertions read the LAST boot block, from one read of the
# box, and both name the agent the round was given — never a name spelled
# here (#427).
#
# The authenticated arm only, and the two rows partition on GH_AUTHED
# together. On a creds-free box `cli probe: FAILED` is the CORRECT verdict
# (shared/docs/rehearsal.md, "one boot block"), so the probe row has no defect
# to assert there. The WARN-free row skips for a reason of a different kind:
# that block is a known-degraded boot whose FAILED probe the row above has
# just declined to vouch for, so a WARN-free green read off it would be a pass
# reported about a boot no other row in the arm stands behind.
#
# Neither reason is the login WARN asserted below. That WARN goes to
# ~/duty/duty.log, which is the file `pre-auth: login WARN logged` reads — a
# different file from the ~/duty/boot-check.log these two read, so no
# contradiction between the rows was ever possible (#427 §5, measured by
# triage 2026-08-09). They fire on the operator's re-run, once the box is
# logged in — the same box state every other assertion in this block
# partitions on.
if [ "$GH_AUTHED" -eq 1 ]; then
  rehearsal_boot_load
  rehearsal_boot_probe_ok "$AGENT"
  rehearsal_boot_warn_free "$AGENT"
else
  skip "boot check: cli probe verdict is ok for $AGENT (box is not gh-authenticated — a FAILED probe is the correct pre-auth verdict)"
  skip "boot check: no WARN for $AGENT (box is not gh-authenticated — the row above has just declined to vouch for this degraded boot block's FAILED probe, so a WARN-free read off it stands behind nothing)"
fi
if [ "$GH_AUTHED" -eq 0 ]; then
  check "pre-auth: login WARN logged"   bx "grep -q 'cannot resolve own login' ~/duty/duty.log"
  check "pre-auth: no .boot-id marker"  bx "! test -f ~/duty/.boot-id"
  check "pre-auth: no sessions spawned" bx "out=\$(ls ~/duty/logs/*.log 2>/dev/null); ! grep -q . <<<\"\$out\""
else
  skip "pre-auth: login WARN check (box was already gh-authenticated)"
  skip "pre-auth: no .boot-id marker check (box was already gh-authenticated)"
  skip "pre-auth: no sessions spawned check (box was already gh-authenticated)"
  check "authed: .boot-id written"      bx "test -f ~/duty/.boot-id"
fi
check "lock contention -> 199 + message" bx "
  flock -n ~/duty/.duty.lock -c 'sleep 6' >/dev/null 2>&1 &
  sleep 1
  out=\$(~/duty/bin/duty.sh 2>&1); rc=\$?
  wait
  [ \$rc -eq 199 ] && grep -q 'already holds' <<<\"\$out\""

if [ "$QUICK" -eq 0 ]; then
  echo "== scheduled-boundary check omitted: rehearsal ticks are explicit and cron stays disarmed (#26)"
fi

# Phase 1 produced a usable installation. A later red assertion must not hide
# Section A, config or app; they are independent of the role's verdict.
rehearsal_section_status installed

# --- phase 2 -------------------------------------------------------------
if [ "$GH_AUTHED" -eq 0 ] || ! bx "set -a; . ~/.crew-engine-stage/shared/conf/agents/$AGENT.conf; bot_cli_probe"; then
  echo
  echo "== phase 2 SKIPPED: box not fully authenticated."
  echo "   The $ROLE loop is therefore UNPROVEN — phase 1 says the engine"
  echo "   installs, not that it works. Log the box in and re-run:"
  echo "     box shell $BOX_NAME"
  echo "     gh auth login"
  echo "     $LOGIN_HINT"
  echo "   Another box may share this identity, but only while its repos.txt"
  echo "   does not name this box's sandbox."
else
  PHASE2_RAN=1
  rehearsal_section_status phase2
  ME2="$(bx "gh api user --jq .login" | tr -d '\r\n')"
  HOST_ME="$(gh api user --jq .login)"
  # One sandbox PER ROLE. The three drill boxes may share one identity, but
  # never a registry: repos.txt is the scope for every module now, so
  # disjoint sandboxes are what keeps three concurrent drills from racing.
  [ -n "$SANDBOX" ] || SANDBOX="$HOST_ME/crew-drill-$ROLE"
  echo
  echo "== phase 2: authenticated $ROLE drills (box identity: $ME2, sandbox: $SANDBOX)"
  echo "   REMINDER: one box per identity PER SANDBOX — another box on $ME2 is safe"
  echo "   only while its repos.txt does not name $SANDBOX."

  # Sandbox repo + collaborator (invited by host, accepted by the box).
  if ! gh repo view "$SANDBOX" >/dev/null 2>&1; then
    gh repo create "$SANDBOX" --public --add-readme >/dev/null || fail "sandbox create"
  fi
  if ! rehearsal_assert_reuse_sandbox_clean "$REUSE" "$SANDBOX"; then
    exit 1
  fi
  if [ "$REUSE" -eq 1 ]; then
    ok "reuse: sandbox starts with no open fixture objects"
  fi
  # Create the whole board vocabulary. Triage reads its queue-label set from
  # the installed configuration below, while the builder keys on ready. A
  # missing label makes a fixture silently unbuildable.
  for _lbl in attention:d93f0b needs-triage:fbca04 ready:0e8a16 claimed:1d76db blocked:b60205 post-merge:006b75 epic:5319e7; do
    gh api "repos/$SANDBOX/labels" -f name="${_lbl%%:*}" -f color="${_lbl##*:}" >/dev/null 2>&1 || true
  done
  if ! gh api "repos/$SANDBOX/collaborators/$ME2" >/dev/null 2>&1; then
    gh api -X PUT "repos/$SANDBOX/collaborators/$ME2" -f permission=push >/dev/null 2>&1 || true
    bx "gh api /user/repository_invitations --jq '.[] | select(.repository.full_name == \"$SANDBOX\") | .id' \
        | while read -r i; do gh api -X PATCH /user/repository_invitations/\$i >/dev/null; done"
  fi
  wait_for 60 "box is a sandbox collaborator" gh api "repos/$SANDBOX/collaborators/$ME2"
  if ! rehearsal_narrow_to_sandbox "$SANDBOX"; then
    echo "repos.txt contains something other than '$SANDBOX' — refusing before a phase 2 tick"
    exit 1
  fi
  # Worded to say what it covers. "repos.txt contains only the sandbox" was
  # true and read as containment of the whole box, which it is not: it bounds
  # every module that consults REPOS_FILE — review, build, triage, hygiene —
  # and attention is not one of them (#52).
  ok "safety interlock: repos.txt narrows review/build/triage/hygiene to the sandbox"

  # The surface repos.txt cannot bound, checked rather than assumed.
  STRAY_ATTENTION="$(rehearsal_attention_is_clear "$SANDBOX" | grep -v '^$' | sort -u | head -5)"
  if [ -n "$STRAY_ATTENTION" ]; then
    echo
    echo "REFUSING before a phase 2 tick: this box's identity ($ME2) has attention demands"
    echo "parked outside $SANDBOX:"
    printf '  %s\n' "$STRAY_ATTENTION"
    echo "Since crew#66 the engine should IGNORE these — the registry bounds the attention"
    echo "wake like every other module — so this check is now the independent verification"
    echo "that the filter holds, not the only thing containing it. It stays a refusal on"
    echo "purpose: a drill is the wrong place to discover the filter regressed, and the"
    echo "cost of being wrong is a real session on a real repo. Clear the label, or re-run"
    echo "on a box whose identity carries no parked demand outside $SANDBOX."
    exit 1
  fi
  ok "safety interlock: no attention demand parked outside the sandbox"

  # -- the operator's watch set: repos.txt ∪ notify-repos.txt (#316) --
  # Here and not in a role block: the notifier is role-independent, and the
  # leg's own precondition is the interlock immediately above — it widens the
  # WATCH set while re-asserting that the WORK set stayed at one sandbox.
  rehearsal_notify_drill "$SANDBOX" "$HOST_ME" "$ROLE"
  notify_rc=$?
  if [ "$notify_rc" -eq 2 ]; then
    echo
    echo "REFUSING to continue: repos.txt moved while the notify union was being"
    echo "staged. The union must widen notifications and nothing else, so a work"
    echo "registry nobody can vouch for aborts the round rather than ticking on."
    exit 1
  fi

  # -- attention wake --
  inum="$(gh api "repos/$SANDBOX/issues" -f title="drill: attention wake $(date -u +%H%M%S)" \
    -f body="Drill demand: reply with exactly one short comment acknowledging this drill, then stop. Do not open PRs." \
    -f "assignees[]=$ME2" -f "labels[]=attention" --jq .number)"
  rehearsal_fixture_record_issue "$SANDBOX" "$inum"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "attention: 📌 pickup comment" bash -c \
    "out=\$(gh api 'repos/$SANDBOX/issues/$inum/comments' --jq '[.[] | select(.user.login == \"$ME2\")] | length'); grep -qE '^[1-9][0-9]*$' <<<\"\$out\""
  # `gh api --jq` prints NOTHING when the filter yields null (real jq prints
  # "null"), so testing for the literal string could never match: label
  # present emitted "0", label absent emitted "". The check failed in BOTH
  # states. Compare inside the filter so a token reaches the shell either way.
  wait_for 300 "attention: label removed (ack re-arms)" bash -c \
    "out=\$(gh api 'repos/$SANDBOX/issues/$inum' --jq '[.labels[].name] | index(\"attention\") == null'); grep -qx true <<<\"\$out\""

  # ---- role-specific loops ---------------------------------------------
  # duty_attention above is role-independent and already ran. What follows
  # is gated on has_role in duty.sh, so each block only means anything on
  # the box that carries that role — which is why the drill is one box per
  # role rather than one box carrying all three.

  if [ "$ROLE" = "triage" ]; then
  # shellcheck source=drill/rehearsal-attention-audit.sh
  . "$ROOT/drill/rehearsal-attention-audit.sh"
  if ! rehearsal_load_installed_queue_labels \
      && [ -z "$REHEARSAL_QUEUE_LABELS" ]; then
    echo "triage: installed queue-label set is empty — refusing before the fixture wait" >&2
    exit 1
  fi
  QUEUE_LABEL_PATTERN="$(printf '%s\n' "$REHEARSAL_QUEUE_LABELS" | paste -sd'|' -)"
  # -- triage: a stray (no queue label) must draw a ruling --
  # duty-triage.sh detects two signals; the STRAY is the one a fixture can
  # create without presupposing triage's own vocabulary: an open issue
  # carrying none of the installed queue labels. The module only DETECTS —
  # the session does the labelling — so the assertion is on what the session
  # leaves behind, not on the signal.
  tnum="$(gh api "repos/$SANDBOX/issues" -f title="drill: triage stray $(date -u +%H%M%S)" \
    -f body="Drill fixture: an unlabelled open issue. Rule on it — leave one short ruling comment and put it in exactly one of ready/claimed/blocked (or epic). Do not open PRs." \
    --jq .number)"
  rehearsal_fixture_record_issue "$SANDBOX" "$tnum"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "triage: stray drew a ruling comment" bash -c \
    "out=\$(gh api 'repos/$SANDBOX/issues/$tnum/comments' --jq '[.[] | select(.user.login == \"$ME2\")] | length'); grep -qE '^[1-9][0-9]*$' <<<\"\$out\""
  # The board invariant: no open issue may remain queue-unlabelled.
  wait_for 300 "triage: stray left the unlabelled queue" bash -c \
    "out=\$(gh api 'repos/$SANDBOX/issues/$tnum' --jq '.labels[].name'); grep -qxE '$QUEUE_LABEL_PATTERN' <<<\"\$out\""
  # Same tick, second time: triage must not re-rule a settled issue.
  TCOMMENTS="$(gh api "repos/$SANDBOX/issues/$tnum/comments" --jq 'length')"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "triage: no second ruling on re-tick" bash -c \
    "[ \"\$(gh api 'repos/$SANDBOX/issues/$tnum/comments' --jq 'length')\" = '$TCOMMENTS' ]"

  # A post-merge issue is already in a valid terminal queue state. Leave it
  # as the only non-conforming-looking fixture, then prove a complete tick
  # neither spends a session on it nor mutates it.
  pnum="$(gh api "repos/$SANDBOX/issues" -f title="drill: triage post-merge $(date -u +%H%M%S)" \
    -f body="Drill fixture: this issue is already in post-merge. Do not comment on it or change its labels." \
    -f "labels[]=post-merge" --jq .number)"
  rehearsal_fixture_record_issue "$SANDBOX" "$pnum"
  PCOMMENTS="$(gh api "repos/$SANDBOX/issues/$pnum/comments" --jq 'length')"
  PLABELS="$(gh api "repos/$SANDBOX/issues/$pnum" --jq '[.labels[].name] | sort | join(" ")')"
  DUTY_LOG_LINES="$(bx "wc -l < ~/duty/duty.log")"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "triage: post-merge drew no comment" bash -c \
    "[ \"\$(gh api 'repos/$SANDBOX/issues/$pnum/comments' --jq 'length')\" = '$PCOMMENTS' ]"
  check "triage: post-merge kept its single label" bash -c \
    "[ \"\$(gh api 'repos/$SANDBOX/issues/$pnum' --jq '[.labels[].name] | sort | join(\" \")')\" = '$PLABELS' ] && [ '$PLABELS' = 'post-merge' ]"
  check "triage: post-merge-only tick launched no session" bx \
    "out=\$(tail -n +$((DUTY_LOG_LINES + 1)) ~/duty/duty.log); grep -Fq '$SANDBOX: quiet — no mentions, no triage signals, no session launched' <<<\"\$out\""

  # -- the hygiene slot's board audit: both malformed shapes, not repaired --
  # Last in the triage block, after the existing assertions, which are
  # unchanged. The slot is triage-only (duty.sh), so this is the one role block
  # it can run in — and it goes last because its own fixtures are two objects
  # the board invariant calls malformed, which every assertion above would
  # otherwise have to be read against.
  rehearsal_attention_audit_drill "$SANDBOX" "$ME2"

  elif [ "$ROLE" = "builder" ]; then
  # shellcheck source=drill/rehearsal-resume.sh
  . "$ROOT/drill/rehearsal-resume.sh"
  # shellcheck source=drill/rehearsal-attention.sh
  . "$ROOT/drill/rehearsal-attention.sh"
  # -- builder: an unassigned `ready` issue must become a PR --
  # ready+ASSIGNED is deliberately NOT pickable (an assignee means mid-claim;
  # counting those launched sessions with nothing to do). The fixture must
  # therefore leave the issue unassigned, or the builder correctly ignores it
  # and the drill would blame the engine for its own bad fixture.
  builder_slot_clear=0
  if ! slot_prs="$(rehearsal_builder_slot_prs "$SANDBOX" "$ME2")"; then
    echo "builder: cannot inspect the build slot for $ME2 in $SANDBOX"
    fail "builder: build slot clear at run start"
  elif [ -n "$slot_prs" ]; then
    echo "builder: occupied build slot at run start for $ME2 in $SANDBOX:"
    while read -r slot_pr; do
      echo "  PR #$slot_pr"
    done <<<"$slot_prs"
    fail "builder: build slot clear at run start"
  else
    builder_slot_clear=1
    ok "builder: build slot clear at run start"
  fi
  if [ "$builder_slot_clear" -eq 0 ]; then
    rehearsal_report_occupied_builder_slot "$ME2"
  else
    # The dedicated sandbox has no repository roster of its own. Give this
    # fixture author one requestable panelist: the host account that owns the
    # sandbox and will close the round. This is test data in the sandbox, not a
    # roster authored in crew.
    check "builder: fixture panel names the host reviewer" \
      rehearsal_install_builder_fixture_panel "$SANDBOX" "$ME2" "$HOST_ME"
    bnum="$(gh api "repos/$SANDBOX/issues" -f title="drill: build me $(date -u +%H%M%S)" \
      -f body="Drill fixture: add a file named drill-build.txt at the repo root containing one line. Open a PR. Keep it to that one change." \
      -f "labels[]=ready" --jq .number)"
    rehearsal_fixture_record_builder_issue "$SANDBOX" "$ME2" "$bnum"
    check "builder fixture is unassigned (ready+assigned is not pickable)" bash -c \
      "out=\$(gh api 'repos/$SANDBOX/issues/$bnum' --jq '.assignees | length'); grep -qx 0 <<<\"\$out\""
    bx "~/duty/bin/tick.sh" || true
    wait_for 1800 "builder: opened a PR for the ready issue" \
      rehearsal_builder_pr_for_issue "$SANDBOX" "$ME2" "$bnum"
    bpr="$(rehearsal_builder_pr_for_issue "$SANDBOX" "$ME2" "$bnum" 2>/dev/null || echo '')"
    if [ -n "$bpr" ]; then
      rehearsal_fixture_record_pr "$SANDBOX" "$bpr"
      echo "builder: resolved PR #$bpr for fixture issue #$bnum"
      ok "builder: PR authored by $ME2 for this run's fixture issue"
      check "builder: PR branch is build/*" bash -c \
        "out=\$(gh api 'repos/$SANDBOX/pulls/$bpr' --jq .head.ref); grep -q '^build/' <<<\"\$out\""
    else
      fail "builder: PR authored by $ME2 for this run's fixture issue"
    fi
    # The claim must be visible on the board, not just in the PR.
    wait_for 300 "builder: issue moved off ready (claimed)" bash -c \
      "out=\$(gh api 'repos/$SANDBOX/issues/$bnum' --jq '[.labels[].name] | index(\"ready\") == null'); grep -qx true <<<\"\$out\""
    # Re-tick must not phantom-rebuild: this issue still resolves to one PR.
    BPR="$bpr"
    bx "~/duty/bin/tick.sh" || true
    sleep 20
    if [ -n "$BPR" ] && \
        retry_bpr="$(rehearsal_builder_pr_for_issue "$SANDBOX" "$ME2" "$bnum")" && \
        [ "$retry_bpr" = "$BPR" ]; then
      ok "builder: no duplicate PR on re-tick"
    else
      fail "builder: no duplicate PR on re-tick"
    fi

    if [ -n "$bpr" ]; then
      wait_for 300 "builder: initial PR is ready for its fixture panel" bash -c \
        "out=\$(gh api 'repos/$SANDBOX/pulls/$bpr' --jq .draft); grep -qx false <<<\"\$out\""
      wait_for 300 "builder: host reviewer requested for initial round" \
        rehearsal_builder_requested "$SANDBOX" "$bpr" "$HOST_ME"
      rehearsal_load_installed_answer_mark

      builder_head="$(gh api "repos/$SANDBOX/pulls/$bpr" --jq .head.sha)"
      builder_check_context="drill/builder-head-settle"
      if builder_round_started_at="$(gh api "repos/$SANDBOX/pulls/$bpr/reviews" \
          -f body="Drill-only blocking point: answer with evidence that drill-build.txt satisfies the fixture. Do not change the tree; push nothing." \
          -f event=REQUEST_CHANGES -f commit_id="$builder_head" --jq .submitted_at)" && \
          [ -n "$builder_round_started_at" ]; then
        ok "builder: host changes-requested review submitted"
      else
        fail "builder: host changes-requested review submitted"
      fi
      if gh api "repos/$SANDBOX/statuses/$builder_head" \
          -f state=pending -f context="$builder_check_context" \
          -f description="drill holds the panel request until the host settles this status" >/dev/null; then
        ok "builder: pending head status established"
      else
        fail "builder: pending head status established"
      fi

      # Observe the author-owned conversion while the tick is alive. The same
      # tick may resume the draft and mark it ready again after answering, so a
      # post-tick-only read can miss the visible state #139 shipped.
      bx "~/duty/bin/tick.sh" </dev/null &
      builder_tick_pid=$!
      wait_for 900 "builder: changes-requested round returns PR to draft" \
        rehearsal_builder_pr_is_draft "$SANDBOX" "$bpr"
      rehearsal_wait_builder_signal_window_with_prereqs \
        1800 "$SANDBOX" "$bpr" "$REHEARSAL_MARK_ANSWERED" \
        "$ME2" "$builder_head" "$builder_round_started_at" \
        "$builder_check_context"
      wait "$builder_tick_pid" || true

      if rehearsal_builder_head_is "$SANDBOX" "$bpr" "$builder_head"; then
        ok "builder: fix round kept the fixture head stable"
        check "builder: panel request withheld while head check is pending" \
          rehearsal_builder_not_requested "$SANDBOX" "$bpr" "$HOST_ME"
        if rehearsal_set_builder_head_status \
            "$SANDBOX" "$builder_head" "$builder_check_context" success \
            "drill releases the settled-head panel request"; then
          ok "builder: settled head status established"
          bx "~/duty/bin/tick.sh" || true
          wait_for 300 "builder: panel request issued after head settles" \
            rehearsal_builder_requested "$SANDBOX" "$bpr" "$HOST_ME"
        else
          fail "builder: settled head status established"
          skip "builder: panel request issued after head settles"
        fi
      else
        fail "builder: fix round kept the fixture head stable"
        skip "builder: panel request withheld while head check is pending"
        skip "builder: settled head status established"
        skip "builder: panel request issued after head settles"
      fi
      # Pending/red heads deliberately keep the ordinary twelve-tick path: an
      # hour of wall clock would re-prove unchanged behaviour. This leg covers
      # the new discriminators — the conclusion wake and bounded bypasses.
      rehearsal_resume_drill "$SANDBOX" "$bpr"
    else
      rehearsal_report_missing_builder_pr
      rehearsal_resume_drill "$SANDBOX" ""
    fi
  fi

  # -- attention: dispatch without code, and the timed-out pickup report --
  # Beside the wake rows above, not instead of them: those read the ACK, this
  # reads what #301 shipped behind it. Last in the builder block and outside
  # the build-slot branch — it needs the fork and the builder route, not the
  # fixture PR, and it files a claim it expects the engine to RELEASE, so an
  # earlier position would leave a ready unassigned fixture standing across
  # every leg above it.
  rehearsal_attention_drill "$SANDBOX" "$ME2"

  else
  # -- review round through the gates --
  main_sha="$(gh api "repos/$SANDBOX/git/ref/heads/main" --jq .object.sha)"
  br="drill-$(date -u +%H%M%S)"
  rehearsal_fixture_record_branch "$SANDBOX" "$br"
  gh api "repos/$SANDBOX/git/refs" -f ref="refs/heads/$br" -f sha="$main_sha" >/dev/null
  gh api -X PUT "repos/$SANDBOX/contents/drill.txt" -f message="drill change" \
    -f branch="$br" -f content="$(printf 'drill %s\n' "$br" | base64 -w0)" >/dev/null
  pr="$(gh api "repos/$SANDBOX/pulls" -f title="drill: review round" -f head="$br" -f base=main \
    -f body="Drill PR: review per your role; a one-line verdict body is fine." --jq .number)"
  rehearsal_fixture_record_pr "$SANDBOX" "$pr"
  gh api "repos/$SANDBOX/pulls/$pr/requested_reviewers" -f "reviewers[]=$ME2" >/dev/null
  head_sha="$(gh api "repos/$SANDBOX/pulls/$pr" --jq .head.sha)"
  bx "~/duty/bin/tick.sh" || true
  wait_for 900 "review: 🔎 announce at head" bash -c \
    "out=\$(gh api 'repos/$SANDBOX/issues/$pr/comments' --jq '.[] | select(.user.login == \"$ME2\") | .body'); grep -q '🔎 reviewing head $head_sha' <<<\"\$out\""
  verdicts() { gh api "repos/$SANDBOX/pulls/$pr/reviews" --paginate | jq -s --arg m "$ME2" --arg h "$head_sha" \
    '[add[] | select(.user.login == $m and .commit_id == $h and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | length'; }
  have_verdict()      { [ "$(verdicts)" -ge 1 ]; }
  verdicts_unchanged() { [ "$(verdicts)" = "$VREF" ]; }
  verdicts_grew()      { [ "$(verdicts)" -gt "$VREF" ]; }
  wait_for 1200 "review: verdict pinned to head" have_verdict
  check "review: announce precedes verdict" \
    rehearsal_review_announce_precedes_verdict "$SANDBOX" "$pr" "$ME2" "$head_sha"

  VREF="$(verdicts)"
  bx "~/duty/bin/tick.sh" || true
  sleep 20
  check "dedup: no second verdict on re-tick" verdicts_unchanged
  # The announce is the other half of dedup and the half a user would see.
  # (The old check here grepped duty.log for the "already covers head" skip.
  # That line is unreachable at this point now: requested_reviewers
  # self-clears on submit, so under the object-endpoint queue a reviewed PR
  # is no longer a candidate at all and there is nothing to skip. It WAS
  # reachable when repos.txt fed the queue through the lagging search index
  # — the branch's own comment says "stale search". Asserting it here tested
  # the search lag, not the guard.)
  check "dedup: no second announce on re-tick" bash -c \
    "[ \"\$(gh api 'repos/$SANDBOX/issues/$pr/comments' --paginate --jq '[.[] | select(.user.login == \"$ME2\") | .body | select(startswith(\"🔎 reviewing head\"))] | length')\" = 1 ]"

  # -- what the flag actually gates, reached deliberately --
  # AUTO_APPROVE_REREQUEST=0 disables the auto-APPROVAL and nothing else
  # (#151): a re-request newer than my standing verdict still queues a REAL
  # re-review at an unchanged head. instance.conf is sourced after fleet.conf,
  # so appending the flag overrides it for this box.
  #
  # This probe used to assert the opposite — that auto=0 fell to the skip
  # branch — and grepped duty.log for "already covers head". That was never a
  # guarantee, it was the bug: the flag sat in front of rereq_decision's whole
  # timestamp comparison, so a standing block plus a newer re-request answered
  # `skip` every tick and the round could not converge (ceremony#207, 37
  # minutes, cleared by hand). Post-fix the branch is unreachable from here for
  # the same reason the announce half above stopped grepping for it: `skip`
  # needs NO re-request newer than my verdict, and requested_reviewers
  # self-clears on submit, so a covered PR becomes a candidate again only BY a
  # re-request, which is newer by construction.
  #
  # The queue holds for APPROVED, CHANGES_REQUESTED and DISMISSED alike, so the
  # probe stays deterministic without staging a particular verdict first — the
  # reviewer's own considered verdict above is whatever it is.
  bx "printf 'AUTO_APPROVE_REREQUEST=0\n' >> ~/duty/conf/instance.conf"
  VREF="$(verdicts)"
  gh api "repos/$SANDBOX/pulls/$pr/requested_reviewers" -f "reviewers[]=$ME2" >/dev/null
  bx "~/duty/bin/tick.sh" || true
  wait_for 1200 "re-request rule: auto off queues a real re-review" verdicts_grew
  # ...and it is a considered verdict, not the auto-approval under another
  # name: the supersede path stamps "re-request rule" into its body. This is
  # the one edge the flag still governs, and nothing asserted it before.
  check "re-request rule: auto off did not auto-approve" bash -c \
    "! gh api 'repos/$SANDBOX/pulls/$pr/reviews' --paginate | jq -se --arg m '$ME2' \
       '[add[] | select(.user.login == \$m) | .body] | any(contains(\"re-request rule\"))'"
  bx "sed -i '/^AUTO_APPROVE_REREQUEST=0$/d' ~/duty/conf/instance.conf"
  check "re-request rule: flag restored" bx "! grep -q '^AUTO_APPROVE_REREQUEST=0$' ~/duty/conf/instance.conf"

  # -- re-request at unchanged head -> auto-approve through the gate --
  gh api "repos/$SANDBOX/pulls/$pr/requested_reviewers" -f "reviewers[]=$ME2" >/dev/null
  bx "~/duty/bin/tick.sh" || true
  wait_for 300 "re-request: auto-approved (supersede)" bash -c \
    "gh api 'repos/$SANDBOX/pulls/$pr/reviews' --paginate | jq -se --arg m \"$ME2\" \
      '[add[] | select(.user.login == \$m) | .body] | any(contains(\"re-request rule\"))'"

  # -- gate abuse: identical resubmit must be a no-op --
  VREF="$(verdicts)"
  check "gate: duplicate submit refused, exit 0" bx "
    printf 'drill duplicate probe' > /tmp/drill-body
    out=\$(~/duty/bin/submit-verdict.sh '$SANDBOX' '$pr' '$head_sha' approve /tmp/drill-body 2>&1); grep -q 'already present' <<<\"\$out\""
  check "gate: verdict count unchanged" verdicts_unchanged
  check "gate: short SHA refused" bx "! ~/duty/bin/submit-verdict.sh '$SANDBOX' '$pr' abc123 approve /tmp/drill-body"
  fi
fi

# Role-independent: exercise the worktree hygiene that runs on every role box
# only after that role's own phase-2 fixtures have finished.
if [ "$PHASE2_RAN" -eq 1 ]; then
  hygiene_failures_before="${#FAILS[@]}"
  if rehearsal_hygiene_drill "$SANDBOX" "$ROLE"; then
    hygiene_drill_rc=0
  else
    hygiene_drill_rc=1
  fi
  if [ "$hygiene_drill_rc" -ne 0 ] \
      || [ "${#FAILS[@]}" -gt "$hygiene_failures_before" ]; then
    rehearsal_hygiene_record_result 1
  else
    rehearsal_hygiene_record_result 0
  fi
fi

# Deliberately last among phase-2 legs: it stops a real session lane before
# restoring it, so no unrelated fixture may depend on dispatch while it runs.
if [ "$PHASE2_RAN" -eq 1 ]; then
  breaker_failures_before="${#FAILS[@]}"
  breaker_drill_rc=0
  rehearsal_breaker_drill "$SANDBOX" "$inum" "$ROLE" \
    || breaker_drill_rc=$?
  if [ "${#FAILS[@]}" -gt "$breaker_failures_before" ]; then
    rehearsal_breaker_record_result 1
  else
    case "$breaker_drill_rc" in
      0) rehearsal_breaker_record_result 0 ;;
      2) rehearsal_breaker_record_result 2 ;;
      *) rehearsal_breaker_record_result 1 ;;
    esac
  fi
fi

if rehearsal_cleanup_owned_fixtures; then
  ok "teardown: close this leg's owned fixtures"
else
  fail "teardown: close this leg's owned fixtures"
fi

check "teardown: drill remains disarmed" bx "out=\$(crontab -l 2>/dev/null); ! grep -q ~/duty/bin/tick.sh <<<\"\$out\""
echo
echo "== rehearsal summary [$ROLE]: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
[ -n "$REUSE_NOTE" ] && echo "   REUSE: $REUSE_NOTE"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILS[@]}"
  rehearsal_report_footer fail "$REPORT_TARGET" "$ROLE" "$BOX_NAME"
  exit 1
fi
# Exit 2, not 0: nothing failed, but the $ROLE loop never ran. Reporting this
# as a pass is how a rehearsal that proved nothing clears a rollout.
if [ "$PHASE2_RAN" -eq 0 ]; then
  rehearsal_report_footer incomplete "$REPORT_TARGET" "$ROLE" "$BOX_NAME"
  exit 2
fi
rehearsal_report_footer pass "$REPORT_TARGET" "$ROLE" "$BOX_NAME"
