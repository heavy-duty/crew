#!/usr/bin/env bash
# install-drill.sh — Section A of the release rehearsal.
#
# The offline install and artifact assertions stay in their CI harnesses. This
# driver invokes them, then adds only the observations that require a real box:
# switch skew, hire/skip from a git-less install, no box-side crew repository,
# full-uninstall refusal, and engine survival after the console is removed.
#
# It borrows a box the role rehearsal installed, and gives it back unchanged:
# its fixture roster is built from the identity that box already carries, so
# the hires below are version events, never identity events. An unhired box
# has no identity to preserve, and is the one case where this drill picks one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT"
REMOTE="https://github.com/heavy-duty/crew.git"
REF="main"
ACQUIRE=0
BOX_NAME=""
REGISTRY=""
DRY_RUN=0

usage() {
  echo "usage: drill/install-drill.sh --box crew-drill-<name> [--tree <path>]"
  echo "       [--remote <url> --ref <git-ref>] [--registry <narrow-repos.txt>] [--dry-run]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --box)      [ $# -ge 2 ] || { usage; exit 2; }; BOX_NAME="$2"; shift 2 ;;
    --tree)     [ $# -ge 2 ] || { usage; exit 2; }; TREE="$2"; ACQUIRE=0; shift 2 ;;
    --remote)   [ $# -ge 2 ] || { usage; exit 2; }; REMOTE="$2"; ACQUIRE=1; shift 2 ;;
    --ref)      [ $# -ge 2 ] || { usage; exit 2; }; REF="$2"; ACQUIRE=1; shift 2 ;;
    --registry) [ $# -ge 2 ] || { usage; exit 2; }; REGISTRY="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$BOX_NAME" ] || { usage; exit 2; }
case "$BOX_NAME" in
  crew-drill-*) ;;
  *) echo "refusing non-drill box '$BOX_NAME' — installer rehearsal targets crew-drill-* only" >&2; exit 1 ;;
esac
WORK="$(mktemp -d)"
# shellcheck disable=SC2317  # invoked indirectly by the EXIT trap
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
if [ "$ACQUIRE" -eq 1 ]; then
  TREE="$WORK/source"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$REF" --single-branch "$REMOTE" "$TREE" ||
    { echo "cannot resolve remote '$REMOTE' ref '$REF'" >&2; exit 1; }
else
  TREE="$(cd "$TREE" 2>/dev/null && pwd)" ||
    { echo "tree '$TREE' is not a readable directory" >&2; exit 1; }
fi
for required in install.sh cli/crew VERSION shared/test/install-lifecycle.sh shared/test/artifact.sh \
                dist/make-installer.sh; do
  [ -f "$TREE/$required" ] || { echo "tree is missing $required" >&2; exit 1; }
done

normalize_registry() {
  sed 's/[[:space:]]*#.*$//' "$1" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u
}

if [ -z "$REGISTRY" ]; then
  REGISTRY="$WORK/repos.txt"
  printf 'drill/installer-rehearsal\n' >"$REGISTRY"
fi
[ -f "$REGISTRY" ] || { echo "registry '$REGISTRY' is not a file" >&2; exit 1; }
if [ "$(normalize_registry "$REGISTRY")" = "$(normalize_registry "$TREE/examples/repos.txt")" ]; then
  echo "refusing registry '$REGISTRY' — it is byte-equivalent to the shipped examples/repos.txt scaffold; an installer drill box must use a narrowed, non-production repos.txt" >&2
  exit 1
fi
registry_count="$(normalize_registry "$REGISTRY" | grep -c . || true)"
[ "$registry_count" -eq 1 ] ||
  { echo "refusing registry '$REGISTRY' — installer drill requires exactly one sandbox repo, found $registry_count" >&2; exit 1; }
SANDBOX="$(normalize_registry "$REGISTRY")"

echo "## Section A — versioned install and distribution"
echo
echo "- Target tree: \`$TREE\`"
echo "- Drill box: \`$BOX_NAME\`"
echo "- Narrow registry: \`$SANDBOX\`"
echo

bx() { box exec "$BOX_NAME" -- bash -lc "$1" </dev/null; }
# shellcheck source=drill/install-survival.sh
. "$ROOT/drill/install-survival.sh"
# shellcheck source=drill/install-payload.sh
. "$ROOT/drill/install-payload.sh"
# The identity this box already carries, read from the same file the
# installer's own change guard reads. Sourcing is safe here: it happens in a
# throwaway shell inside the box, not in this one.
#
# Three answers, and the difference between the last two decides whether
# Section A may choose an identity. `absent` is a box that was never hired:
# there is no identity to preserve, so choosing one overwrites nobody. Any
# other failure is a box that may well be carrying an identity this driver
# merely failed to read, and choosing there is #180 firing for real.
read_box_identity() {
  # shellcheck disable=SC2016  # expanded by bash inside the box
  bx 'conf=~/duty/conf/instance.conf
      [ -e "$conf" ] || { printf "absent\n"; exit 0; }
      . "$conf" 2>/dev/null || { printf "unreadable\n"; exit 0; }
      [ -n "${BOT_AGENT:-}" ] && [ -n "${BOT_ROLES:-}" ] ||
        { printf "unreadable\n"; exit 0; }
      printf "present %s %s\n" "$BOT_AGENT" "$BOT_ROLES"' 2>/dev/null |
    tr -d '\r' | head -1
}

# The one case where Section A must choose, per #180's task list: a box with
# no instance.conf at all.
FALLBACK_AGENT=claude
FALLBACK_ROLES=reviewer

# Is there a box host here, carrying this box? Discovery is a fact, not yet a
# refusal: --dry-run runs anywhere, and reports more when the box is reachable.
BOX_PRESENT=0
if command -v box >/dev/null && command -v jq >/dev/null &&
   box list --json 2>/dev/null | jq -e --arg n "$BOX_NAME" '.[] | select(.name == $n)' >/dev/null; then
  BOX_PRESENT=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "- WOULD INVOKE: \`shared/test/install-lifecycle.sh\` (offline assertions)"
  echo "- WOULD INVOKE: \`shared/test/artifact.sh\` (offline artifact assertions)"
  if [ "$BOX_PRESENT" -eq 1 ]; then
    dry_state=""; dry_agent=""; dry_roles=""
    read -r dry_state dry_agent dry_roles <<<"$(read_box_identity)"
    case "$dry_state" in
      present)
        echo "- WOULD HIRE \`$BOX_NAME\` as the identity it already carries: agent \`$dry_agent\`, roles \`$dry_roles\`" ;;
      absent)
        echo "- WOULD HIRE \`$BOX_NAME\` as agent \`$FALLBACK_AGENT\`, roles \`$FALLBACK_ROLES\` — it carries no \`~/duty/conf/instance.conf\`, so there is no identity to preserve" ;;
      *)
        echo "- WOULD REFUSE: \`$BOX_NAME\` has an \`~/duty/conf/instance.conf\` this drill cannot read — it may be carrying an identity, and Section A will not guess over one" ;;
    esac
  else
    echo "- WOULD ADOPT \`$BOX_NAME\`'s installed agent and roles from \`~/duty/conf/instance.conf\` (no box host here to read them)"
  fi
  echo "- WOULD OBSERVE the payload (#365) on three installed trees — the first synthetic version, the second (the upgrade path) and the offline artifact's — each carrying none of \`install.sh\`'s excluded roots, by path, and each within the size bound read from the offline guards"
  echo "- WOULD OBSERVE step 4: \`crew use\` names \`$BOX_NAME\` at the old engine version"
  echo "- WOULD OBSERVE steps 5–6: installed-tree hire stamps a git-less engine; second \`crew up\` skips; no box-side crew repo is consulted"
  echo "- WOULD OBSERVE step 8: \`crew uninstall --all\` refuses and names \`$BOX_NAME\`"
  echo "- WOULD OBSERVE step 9: forced console removal leaves \`$BOX_NAME\`'s engine and armed cron in place, and its latest tick evidence — an unchanged last \`duty.log\` line on a box that arrived with history, a tick landing after the removal itself completed, within one cron boundary plus grace, on a box that had none"
  echo "- WOULD OBSERVE identity: \`$BOX_NAME\` carries the agent and roles declared above after Section A, unchanged by its hires and uninstalls"
  echo "- WOULD OBSERVE host checkout: installer warning and \`command -v crew\` agree about PATH order"
  exit 0
fi

if [ "$BOX_PRESENT" -eq 0 ]; then
  command -v box >/dev/null || { echo "box CLI not found — this runs on a box host" >&2; exit 1; }
  command -v jq >/dev/null || { echo "jq not found on the host" >&2; exit 1; }
  echo "drill box '$BOX_NAME' does not exist — run drill/rehearsal-all.sh first" >&2
  exit 1
fi

# Section A hires this box, so it must hire it as WHAT IT IS. A fixture roster
# that names a role of its own re-roles the box behind the rehearsal's back —
# silently, because the engine only warns on ROLES CHANGED and installs anyway
# — and the phases that share this box by design then run against duty loops
# nobody asked for (#180).
IDENTITY_STATE=""; BOX_AGENT=""; BOX_ROLES=""
read -r IDENTITY_STATE BOX_AGENT BOX_ROLES <<<"$(read_box_identity)"
case "$IDENTITY_STATE" in
  present)
    IDENTITY_ORIGIN="adopted from the box, not changed"
    echo "- Box identity: agent \`$BOX_AGENT\`, roles \`$BOX_ROLES\` ($IDENTITY_ORIGIN)" ;;
  absent)
    BOX_AGENT="$FALLBACK_AGENT"; BOX_ROLES="$FALLBACK_ROLES"
    IDENTITY_ORIGIN="chosen by Section A — the box arrived unhired, carrying none"
    echo "- Box identity: agent \`$BOX_AGENT\`, roles \`$BOX_ROLES\` ($IDENTITY_ORIGIN)" ;;
  *)
    echo "cannot read the installed identity of '$BOX_NAME' from ~/duty/conf/instance.conf" >&2
    echo "— the file is there but unreadable, so this box may be carrying an identity" >&2
    echo "— Section A adopts a box's identity or chooses for an unhired one; it never guesses over one" >&2
    exit 1 ;;
esac
echo

FAIL=0
pass() { echo "- PASS: $1"; }
fail() { echo "- FAIL: $1${2:+ — $2}"; FAIL=1; }

if lifecycle_out="$(CREW_LIFECYCLE_SOURCE="$TREE" "$TREE/shared/test/install-lifecycle.sh" 2>&1)" &&
   lifecycle_summary="$(printf '%s\n' "$lifecycle_out" | tail -1)" &&
   [[ "$lifecycle_summary" == *"failed 0"* ]]; then
  pass "offline install lifecycle invoked — $lifecycle_summary"
else
  fail "offline install lifecycle" "$(printf '%s\n' "${lifecycle_out:-no output}" | tail -3 | tr '\n' ' ')"
fi
if artifact_out="$("$TREE/shared/test/artifact.sh" 2>&1)" &&
   artifact_summary="$(printf '%s\n' "$artifact_out" | tail -1)" &&
   [[ "$artifact_summary" == *"failed 0"* ]]; then
  pass "offline artifact harness invoked — $artifact_summary"
else
  fail "offline artifact harness" "$(printf '%s\n' "${artifact_out:-no output}" | tail -3 | tr '\n' ' ')"
fi
[ "$FAIL" -eq 0 ] || exit 1

# Two stable synthetic versions let `crew up` prove a true skip even when the
# tree under test is a -dev checkout (dev engines intentionally always rebake).
VA=0.0.0-install-drill-a
VB=0.0.0-install-drill-b
SA="$WORK/source-a"; SB="$WORK/source-b"
mkdir -p "$SA" "$SB"
tar -C "$TREE" --exclude=.git -cf - . | tar -xf - -C "$SA"
tar -C "$TREE" --exclude=.git -cf - . | tar -xf - -C "$SB"
printf '%s\n' "$VA" >"$SA/VERSION"
printf '%s\n' "$VB" >"$SB/VERSION"

DRILL_HOME="$WORK/home"
OPERATOR_HOME="$HOME"
export CREW_HOME="$DRILL_HOME/share" CREW_BIN="$DRILL_HOME/bin" CREW_YES=1
mkdir -p "$DRILL_HOME/crew/.git" "$DRILL_HOME/crew/cli"
cp "$TREE/cli/crew" "$DRILL_HOME/crew/cli/crew"
install_a_out="$(HOME="$DRILL_HOME" CREW_INSTALL_SOURCE="$SA" bash "$TREE/install.sh" 2>&1)" ||
  { fail "install first synthetic version" "$(tail -3 <<<"$install_a_out")"; exit 1; }
case "$install_a_out" in
  *"crew git checkout also exists"*"$DRILL_HOME/crew"*PATH*) pass "host checkout warning names PATH order" ;;
  *) fail "host checkout warning names PATH order" ;;
esac
case "$(PATH="$CREW_BIN:$PATH" command -v crew)" in
  "$CREW_BIN/crew") pass "\`command -v crew\` selects the scratch install when its bin directory is first" ;;
  *) fail "\`command -v crew\` agrees with installer PATH warning" ;;
esac
# Read once, against the source: the drill walks every installed tree below
# against this root whether or not the installer still declares it, so a
# declaration that quietly lost it is reported here rather than inferred from
# three identical reds.
if install_payload_installer_names_sentinel "$TREE"; then
  pass "payload: the installer still excludes \`$INSTALL_PAYLOAD_SENTINEL_ROOT\`"
else
  fail "payload: the installer still excludes \`$INSTALL_PAYLOAD_SENTINEL_ROOT\`" \
    "\`PAYLOAD_EXCLUDED_PATHS\` no longer names it"
fi

# THE PAYLOAD (#365), on the tree this host just installed. Asserted at the
# versioned directory rather than at `current`, because `current` is about to
# move: this is the FIRST install's tree, and the second one below is the
# upgrade path an operator's box actually walks (#421).
install_payload_assert "payload first install" "$TREE" "$CREW_HOME/versions/$VA"

HOME="$DRILL_HOME" CREW_INSTALL_SOURCE="$SB" bash "$TREE/install.sh" >/dev/null 2>&1 ||
  { fail "install second synthetic version"; exit 1; }
# …and on the upgraded tree, measured at `current` — the path an operator's
# `crew` resolves through, and the one a `du -sk` without -L would report as a
# symlink and pass at any size.
install_payload_assert "payload upgrade" "$TREE" "$CREW_HOME/current"

# The scp-able channel, measured as a channel and not assumed from the two
# above: `crew-<version>.sh` reimplements no install logic, but it acquires its
# tree by unpacking rather than by copying a directory, and that is the branch
# that shipped the whole 52M repository until round 1 of #365. This is the
# channel #210 publishes for every release — the one an operator scp's to a box
# with no network — so it is drilled where the release cut can see it.
ARTIFACT="$WORK/crew-$VB.sh"
ARTIFACT_HOME="$WORK/artifact-home"
mkdir -p "$ARTIFACT_HOME"
if bash "$TREE/dist/make-installer.sh" --name crew --version "$VB" --root "$SB" \
     --out "$ARTIFACT" >"$WORK/artifact.out" 2>&1 && [ -x "$ARTIFACT" ] &&
   HOME="$ARTIFACT_HOME" CREW_HOME="$ARTIFACT_HOME/share" CREW_BIN="$ARTIFACT_HOME/bin" \
     bash "$ARTIFACT" >>"$WORK/artifact.out" 2>&1; then
  pass "offline artifact \`crew-$VB.sh\` built and installed on this host"
  install_payload_assert "payload artifact" "$TREE" "$ARTIFACT_HOME/share/current"
else
  fail "offline artifact built and installed on this host" "$(tail -3 "$WORK/artifact.out" 2>/dev/null | tr '\n' ' ')"
fi

CONFIG="$WORK/config"
"$CREW_BIN/crew" init "$CONFIG" >/dev/null 2>&1 ||
  { fail "create drill fleet definition"; exit 1; }
printf '%s %s %s\n' "$BOX_NAME" "$BOX_AGENT" "${BOX_ROLES// /,}" >"$CONFIG/fleet.roster"
cp "$REGISTRY" "$CONFIG/repos.txt"
export CREW_CONFIG_DIR="$CONFIG" CREW_EXPECT_OPERATOR_CONFIG=1
export HOME="$OPERATOR_HOME"

if "$CREW_BIN/crew" hire "$BOX_NAME" --force >"$WORK/hire.out" 2>&1 &&
   engine_before="$(bx "head -1 ~/duty/VERSION 2>/dev/null" | tr -d '\r\n')" &&
   [[ "$engine_before" == "crew@$VB"* ]]; then
  pass "steps 5–6: installed-tree hire stamped git-less engine \`$engine_before\`"
else
  fail "steps 5–6: installed-tree hire/stamp" "$(tail -5 "$WORK/hire.out")"
fi
if bx "test -f ~/duty/VERSION && test ! -d ~/duty/.git"; then
  pass "step 6: box engine is self-contained and has no crew repository metadata"
else
  fail "step 6: box engine has no crew repository dependency"
fi
if "$CREW_BIN/crew" up >"$WORK/up.out" 2>&1 &&
   grep -qF "$BOX_NAME: already hired at crew@$VB" "$WORK/up.out"; then
  pass "step 5: second \`crew up\` skipped the already-current engine"
else
  fail "step 5: second \`crew up\` skips" "$(tail -6 "$WORK/up.out")"
fi

if use_out="$("$CREW_BIN/crew" use "$VA" 2>&1)" &&
   grep -qF "$BOX_NAME: $VB" <<<"$use_out"; then
  pass "step 4: host switch named \`$BOX_NAME\` still on engine \`$VB\`"
else
  fail "step 4: switch skew names box and old engine" "$use_out"
fi

if CREW_YES='' "$CREW_BIN/crew" uninstall --all >"$WORK/refuse.out" 2>&1; then
  fail "step 8: full uninstall refused under hired box"
elif grep -qF "$BOX_NAME" "$WORK/refuse.out" &&
     grep -qF "keeps running autonomously" "$WORK/refuse.out"; then
  pass "step 8: full uninstall refused and named \`$BOX_NAME\` plus the unattended-fleet consequence"
else
  fail "step 8: refusal names box and consequence" "$(cat "$WORK/refuse.out")"
fi

install_survival_before
if ! "$CREW_BIN/crew" uninstall --all --force >"$WORK/remove.out" 2>&1; then
  fail "step 9: forced console removal" "$(tail -3 "$WORK/remove.out" 2>/dev/null | tr '\n' ' ')"
elif install_survival_check; then
  pass "step 9: console removed; \`$BOX_NAME\` kept engine \`$INSTALL_SURVIVAL_ENGINE\`, armed cron, and latest tick \`$INSTALL_SURVIVAL_TICK\` ($INSTALL_SURVIVAL_PATH_LABEL)"
else
  # The detail is the surfaces, never remove.out: that transcript holds the
  # removal's own success message and says nothing about what went missing
  # after it, which is how a true survival got reported as a failure (#341).
  fail "step 9: positive engine/cron/tick survival observation" "$INSTALL_SURVIVAL_DETAIL"
fi

# Last, because it covers every mutation above: Section A hires, re-hires and
# uninstalls, and none of that may leave the box carrying an identity other
# than the one declared at the top — the box's own when it had one, Section A's
# fallback when it arrived unhired. The phases after this one share the box.
after_state=""; after_agent=""; after_roles=""
read -r after_state after_agent after_roles <<<"$(read_box_identity)"
if [ "$after_state" = present ] &&
   [ "$after_agent" = "$BOX_AGENT" ] && [ "$after_roles" = "$BOX_ROLES" ]; then
  pass "identity: \`$BOX_NAME\` carries agent \`$BOX_AGENT\`, roles \`$BOX_ROLES\` after Section A ($IDENTITY_ORIGIN)"
else
  fail "identity: Section A left \`$BOX_NAME\` carrying the identity it declared" \
    "declared '$BOX_AGENT $BOX_ROLES', now '$after_state ${after_agent:-} ${after_roles:-}'"
fi

echo
echo "Section A result: $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
exit "$FAIL"
