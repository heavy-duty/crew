#!/usr/bin/env bash
# Focused fixtures for drill orchestration and immutable source acquisition.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"

SOURCE="$TMP/source"
REMOTE="$TMP/canonical.git"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name fixture
git -C "$SOURCE" config user.email fixture@example.invalid
mkdir -p "$SOURCE/shared/test"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SOURCE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$SOURCE/shared/test/run.sh"
printf '0.0.0-test\n' >"$SOURCE/VERSION"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm first
FIRST="$(git -C "$SOURCE" rev-parse HEAD)"
printf 'second\n' >"$SOURCE/SECOND"
git -C "$SOURCE" add SECOND
git -C "$SOURCE" commit -qm second
SECOND="$(git -C "$SOURCE" rev-parse HEAD)"
git clone -q --bare "$SOURCE" "$REMOTE"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
# Model GitHub's fork-network exact-object service: SECOND is in the canonical
# object store but no canonical ref advertises it.
git --git-dir="$REMOTE" config uploadpack.allowAnySHA1InWant true
git --git-dir="$REMOTE" config uploadpack.allowReachableSHA1InWant true

HARNESS="$TMP/harness"
mkdir -p "$HARNESS"
cp "$ROOT/drill/rehearsal-all.sh" "$ROOT/drill/rehearsal-notify.sh" \
  "$ROOT/drill/rehearsal-verdict.sh" "$ROOT/drill/rehearsal-hygiene.sh" \
  "$ROOT/drill/rehearsal-breaker.sh" "$ROOT/drill/rehearsal-safety.sh" \
  "$HARNESS/"
# The orchestrator sources this one for fleet_worst_verdict. Without it in the
# harness every fleet row would be produced by an UNDEFINED function, which
# under `set -uo pipefail` is a stderr line and an empty verdict — a leg that
# graded itself as "reached no case" for a reason that exists only in the
# fixture (#656).
cp "$ROOT/drill/fleet-lifecycle.sh" "$HARNESS/"
cp "$ROOT/drill/rehearsal-report.sh" "$HARNESS/"
cat >"$HARNESS/rehearsal.sh" <<'ROLE'
#!/usr/bin/env bash
role="" remote="" ref="" tree="" source_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --source-ref) source_ref="$2"; shift 2 ;;
    --tree) tree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$tree" ]; then
  shipped="$(git -C "$tree" rev-parse HEAD)"
elif [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
  shipped="$ref"
else
  shipped="$(git --git-dir="$DRILL_REMOTE" rev-parse "refs/heads/$ref")"
fi
remote="${remote:--}"
ref="${ref:--}"
source_ref="${source_ref:--}"
printf '%s %s %s %s %s\n' "$role" "$remote" "$ref" "$shipped" "$source_ref" \
  >>"$DRILL_ROLE_LOG"
[ -z "${REHEARSAL_SECTION_STATUS:-}" ] \
  || printf '%s\n' "${DRILL_ROLE_STAGE:-phase2}" >"$REHEARSAL_SECTION_STATUS"
if [ -n "$tree" ]; then
  echo "== phase 0: crew at $shipped (tree $tree), static checks"
else
  echo "== phase 0: shipped $shipped from remote $remote ref $ref (creds-free inside box)"
fi
if [ "$(wc -l <"$DRILL_ROLE_LOG")" -eq 1 ] && [ -n "${DRILL_MOVE_TO:-}" ]; then
  git --git-dir="$DRILL_REMOTE" update-ref refs/heads/main "$DRILL_MOVE_TO"
fi
exit "${DRILL_ROLE_RC:-0}"
ROLE
chmod +x "$HARNESS/rehearsal.sh"
cat >"$HARNESS/install-drill.sh" <<'INSTALL'
#!/usr/bin/env bash
remote="" ref="" tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --tree) tree="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$tree" ]; then shipped="$(git -C "$tree" rev-parse HEAD)"; else shipped="$ref"; fi
remote="${remote:--}"
ref="${ref:--}"
printf 'installer %s %s %s\n' "$remote" "$ref" "$shipped" >>"$DRILL_INSTALL_LOG"
exit 0
INSTALL
chmod +x "$HARNESS/install-drill.sh"
cat >"$HARNESS/box" <<'BOX'
#!/usr/bin/env bash
[ "${1:-}" = exec ] || exit 1
[ "${DRILL_SECTION_A_UNREADABLE:-0}" -eq 0 ] || exit 2
if [ "${DRILL_SECTION_A_ARMED:-0}" -eq 1 ]; then
  printf 'armed\n'
else
  printf 'disarmed\n'
fi
BOX
chmod +x "$HARNESS/box"
PATH="$HARNESS:$PATH"
export PATH
cat >"$HARNESS/rehearsal-config.sh" <<'CONFIG'
#!/usr/bin/env bash
printf 'config\n' >>"$DRILL_SECTION_LOG"
exit 0
CONFIG
cat >"$HARNESS/rehearsal-app.sh" <<'APP'
#!/usr/bin/env bash
printf 'app\n' >>"$DRILL_SECTION_LOG"
[ -z "${DRILL_APP_LOG:-}" ] || printf '%s\n' "$*" >>"$DRILL_APP_LOG"
[ -z "${REHEARSAL_AGREEMENT_STATUS:-}" ] || {
  case " $* " in
    *" --roster "*)
      case "${DRILL_APP_ROSTER_STATUS:-compared}" in
        missing) : ;;
        *) printf '%s\n' "${DRILL_APP_ROSTER_STATUS:-compared}" >"$REHEARSAL_AGREEMENT_STATUS" ;;
      esac ;;
    *) printf '%s\n' "${DRILL_APP_STATUS:-compared}" >"$REHEARSAL_AGREEMENT_STATUS" ;;
  esac
}
skip() { echo "skip $1${2:+  — $2}"; }
case " $* " in
  *" --no-browser "*) ;;
  *)
    case "${DRILL_BROWSER_STATUS:-ok}" in
      ok) echo 'ok   browser walk against the real fleet (read-only)' ;;
      skip) skip "browser walk" "playwright-core not installed" ;;
      fail) echo 'FAIL browser walk against the real fleet (read-only)' ;;
      missing) : ;;
    esac ;;
esac
exit "${DRILL_APP_RC:-0}"
APP
chmod +x "$HARNESS/rehearsal-config.sh" "$HARNESS/rehearsal-app.sh"

round_run() {  # <script> <roles> <ref>
  local script="$1" roles="$2" ref="$3"
  DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_MOVE_TO="${DRILL_MOVE_TO:-}" \
    DRILL_ROLE_STAGE="${DRILL_ROLE_STAGE:-phase2}" \
    DRILL_ROLE_RC="${DRILL_ROLE_RC:-0}" \
    bash "$script" --remote "$REMOTE" --ref "$ref" --roles "$roles" \
      --keep --no-app --no-config-drill \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1
}

# Resolve main once, then move it after the first role. Every role still gets
# and reports FIRST because the mutable name never crosses the orchestrator.
ROLE_LOG="$TMP/roles.log"
INSTALL_LOG="$TMP/installer.log"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO="$SECOND"
if round_out="$(round_run "$HARNESS/rehearsal-all.sh" \
    'triage builder reviewer' main)"; then round_rc=0; else round_rc=$?; fi
t drill-one-resolution-round-rc 0 "$round_rc"
t drill-one-resolution-three-roles 3 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-one-resolution-one-passed-ref 1 "$(awk '{print $3}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-one-resolution-passed-full-sha "$FIRST" "$(awk 'NR == 1 {print $3}' "$ROLE_LOG")"
t drill-moving-branch-one-shipped-tree 1 "$(awk '{print $4}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-moving-branch-ships-original "$FIRST" "$(awk 'NR == 3 {print $4}' "$ROLE_LOG")"
t drill-moving-branch-installer-passed-full-sha "$FIRST" "$(awk '{print $3}' "$INSTALL_LOG")"
t drill-moving-branch-installer-ships-original "$FIRST" "$(awk '{print $4}' "$INSTALL_LOG")"
t drill-moving-branch-one-tree-across-round 1 \
  "$(awk '{print $4}' "$ROLE_LOG" "$INSTALL_LOG" | sort -u | wc -l | tr -d ' ')"
t drill-record-names-resolved-sha 1 \
  "$(grep -cF "## drilled source: $FIRST (remote $REMOTE ref main)" <<<"$round_out")"
t drill-three-phase-zero-lines 3 "$(grep -cF "phase 0: shipped $FIRST" <<<"$round_out")"

# Mutation: forwarding the mutable operator ref recreates the split as soon as
# the fixture moves main. This proves the moving-branch case is discriminating.
MUTABLE="$HARNESS/rehearsal-all-mutable.sh"
# shellcheck disable=SC2016  # mutate the literal production variable
sed 's/--ref "$RESOLVED_REF"/--ref "$INSTALL_REF"/' \
  "$HARNESS/rehearsal-all.sh" >"$MUTABLE"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO="$SECOND"
round_run "$MUTABLE" 'triage builder reviewer' main >/dev/null || true
t drill-moving-branch-mutation-diverges 2 \
  "$(awk '{print $4}' "$ROLE_LOG" | sort -u | wc -l | tr -d ' ')"

# A commit with no advertised canonical ref remains acquirable by its full ID.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if hidden_out="$(round_run "$HARNESS/rehearsal-all.sh" reviewer "$SECOND")"; then
  hidden_rc=0
else
  hidden_rc=$?
fi
t drill-hidden-commit-round-rc 0 "$hidden_rc"
t drill-hidden-commit-from-canonical "$REMOTE $SECOND $SECOND" \
  "$(awk '{print $2, $3, $4}' "$ROLE_LOG")"
t drill-hidden-commit-recorded 1 \
  "$(grep -cF "## drilled source: $SECOND (remote $REMOTE ref $SECOND)" <<<"$hidden_out")"
t drill-hidden-commit-installer-ref "$SECOND" "$(awk '{print $3}' "$INSTALL_LOG")"

# Tree mode identifies the actual local checkout and commit in both phase-0
# role evidence and the paste-ready summary; remote/ref defaults stay silent.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if tree_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then tree_rc=0; else tree_rc=$?; fi
t drill-tree-round-rc 0 "$tree_rc"
t drill-tree-role-ships-head "$SECOND" "$(awk '{print $4}' "$ROLE_LOG")"
t drill-tree-installer-ships-head "$SECOND" "$(awk '{print $4}' "$INSTALL_LOG")"
t drill-tree-record-names-head 1 \
  "$(grep -cF "## drilled source: $SECOND (tree $SOURCE)" <<<"$tree_out")"
t drill-tree-phase-zero-names-head 1 \
  "$(grep -cF "phase 0: crew at $SECOND (tree $SOURCE), static checks" <<<"$tree_out")"
t drill-record-enumerates-all-declared-legs 13 \
  "$(grep -c '^## leg \(executed\|not-executed\) ' <<<"$tree_out")"
t drill-record-names-browser-exclusion 1 \
  "$(grep -c '^## leg not-executed browser  (skip; --no-app)' <<<"$tree_out")"
t drill-record-names-unrequested-armed-leg-with-app-disabled 1 \
  "$(grep -c '^## leg not-executed app-armed  (skip; --no-app)' \
    <<<"$tree_out")"

# The original three zero-execution findings remain visible with their actual
# states: breaker and notify name the operator exclusions in this fixture, and
# the browser is positively recorded as executed.
for excluded_leg in breaker notify; do
  t "drill-record-names-$excluded_leg-exclusion" 1 \
    "$(grep -c "^## leg not-executed $excluded_leg  (skip; --no-$excluded_leg-drill)" \
      <<<"$tree_out")"
done

# A new declaration with no call site cannot disappear. Mutate only the list:
# the runtime agreement check must add a named missing-result row and red.
UNWIRED="$HARNESS/rehearsal-all-unwired.sh"
sed 's/hygiene breaker resume/hygiene never-wired breaker resume/' \
  "$HARNESS/rehearsal-all.sh" >"$UNWIRED"
if unwired_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$UNWIRED" --tree "$SOURCE" --roles reviewer \
      --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  unwired_rc=0
else
  unwired_rc=$?
fi
t drill-unwired-declared-leg-reds 1 "$unwired_rc"
t drill-unwired-declared-leg-is-visible 1 \
  "$(grep -c '^## leg not-executed never-wired  (recorded 0 results; expected exactly one)' \
    <<<"$unwired_out")"
t drill-unwired-declared-leg-prevents-teardown 1 \
  "$(grep -cF 'kept       teardown  (round not green — boxes LEFT STANDING to inspect)' \
    <<<"$unwired_out")"

# Agreement is two-way: a summary result without a declaration must remain
# visible and red rather than falling outside the generated inventory.
UNDECLARED="$HARNESS/rehearsal-all-undeclared.sh"
sed 's/hygiene breaker resume/hygiene resume/' \
  "$HARNESS/rehearsal-all.sh" >"$UNDECLARED"
if undeclared_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$UNDECLARED" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  undeclared_rc=0
else
  undeclared_rc=$?
fi
t drill-undeclared-summary-leg-reds 1 "$undeclared_rc"
t drill-undeclared-summary-leg-is-visible 1 \
  "$(grep -c '^## leg undeclared breaker  (summary result has no declaration)' \
    <<<"$undeclared_out")"

# Not-executed is not a sufficient record by itself: the blocker is the fact
# that makes an exclusion evidence. Remove one reason and require a red row.
NO_REASON="$HARNESS/rehearsal-all-no-reason.sh"
sed 's/SUMMARY+=("skip       browser  (--no-app)")/SUMMARY+=("skip       browser")/' \
  "$HARNESS/rehearsal-all.sh" >"$NO_REASON"
if no_reason_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" bash "$NO_REASON" --tree "$SOURCE" --roles reviewer \
      --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  no_reason_rc=0
else
  no_reason_rc=$?
fi
t drill-unrun-leg-without-blocker-reds 1 "$no_reason_rc"
t drill-unrun-leg-without-blocker-is-visible 1 \
  "$(grep -c '^## leg not-executed browser  (missing blocker reason)' \
    <<<"$no_reason_out")"

# A red assertion inside phase 2 must not silently void the independent
# installer, config and app sections. The explicit stage channel distinguishes
# this from a role failure before an installed box existed (#491).
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
SECTION_LOG="$TMP/sections.log"
: >"$SECTION_LOG"
if phase2_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_ROLE_STAGE=phase2 DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --keep --no-resume-drill --no-attention-drill \
      --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  phase2_rc=0
else
  phase2_rc=$?
fi
t drill-phase2-failure-stays-red 1 "$phase2_rc"
t drill-phase2-failure-reports-role 1 \
  "$(grep -cF 'FAIL       reviewer  (phase 2 failed)' <<<"$phase2_out")"
t drill-phase2-failure-runs-section-a 1 \
  "$(grep -cF 'ok         installer  (Section A record emitted)' <<<"$phase2_out")"
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-phase2-section-a-return-is-recorded 1 \
  "$(grep -cF 'PASS: Section A returned `crew-drill-reviewer` disarmed' <<<"$phase2_out")"
t drill-phase2-failure-runs-config 1 \
  "$(grep -cF 'ok         config  (operator mode + registry contract)' <<<"$phase2_out")"
t drill-phase2-failure-runs-app 1 \
  "$(grep -cF 'ok         app  (agreement compared; collector + page)' <<<"$phase2_out")"
t drill-phase2-records-browser-executed 1 \
  "$(grep -c '^## leg executed browser  (ok; read-only browser walk executed)' \
    <<<"$phase2_out")"
t drill-phase2-records-app-armed-blocker 1 \
  "$(grep -c '^## leg not-executed app-armed  (skip; not requested: no --app-roster; requires an armed member)' \
    <<<"$phase2_out")"
t drill-phase2-failure-invokes-config-and-app $'config\napp' "$(cat "$SECTION_LOG")"
t drill-phase2-summary-counts-four-passed 1 \
  "$(grep -cE '^## section states: 4 passed, 1 failed, [0-9]+ skipped/not-run$' <<<"$phase2_out")"

if armed_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_SECTION_A_ARMED=1 bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  armed_rc=0
else
  armed_rc=$?
fi
t drill-section-a-armed-return-reds 1 "$armed_rc"
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-section-a-armed-return-is-recorded 1 \
  "$(grep -cF 'FAIL: Section A returned `crew-drill-reviewer` armed' <<<"$armed_out")"

if unreadable_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_SECTION_A_UNREADABLE=1 bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  unreadable_rc=0
else
  unreadable_rc=$?
fi
t drill-section-a-unreadable-return-reds 1 "$unreadable_rc"
# shellcheck disable=SC2016  # literal Markdown backticks in the record row
t drill-section-a-unreadable-return-is-recorded 1 \
  "$(grep -cF 'FAIL: Section A returned `crew-drill-reviewer` with crontab state unreadable' \
    <<<"$unreadable_out")"

# The third historical zero-execution leg also records a discovered host
# blocker rather than disappearing inside app's aggregate result.
if browser_skip_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_BROWSER_STATUS=skip DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  browser_skip_rc=0
else
  browser_skip_rc=$?
fi
t drill-browser-blocker-makes-round-incomplete 2 "$browser_skip_rc"
t drill-browser-blocker-is-named-in-record 1 \
  "$(grep -c '^## leg not-executed browser  (INCOMPLETE; not executed: playwright-core not installed)' \
    <<<"$browser_skip_out")"

# A named app roster adds an armed comparison after the generated drill-role
# comparison. It does not replace that pass and it does not invoke another
# role drill (therefore cannot mint another box).
APP_LOG="$TMP/app-passes.log"
: >"$TMP/armed.roster"
: >"$APP_LOG"
: >"$ROLE_LOG"
if app_roster_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  app_roster_rc=0
else
  app_roster_rc=$?
fi
t drill-armed-roster-second-pass-rc 0 "$app_roster_rc"
t drill-armed-roster-runs-two-app-passes 2 \
  "$(wc -l <"$APP_LOG" | tr -d ' ')"
t drill-armed-roster-first-pass-is-generated 1 \
  "$(sed -n '1p' "$APP_LOG" | grep -cF -- '--drill-roles reviewer --agent claude')"
t drill-armed-roster-second-pass-is-named 1 \
  "$(sed -n '2p' "$APP_LOG" | grep -cFx -- "--roster $TMP/armed.roster --no-browser")"
t drill-armed-roster-second-pass-is-read-only 0 \
  "$(sed -n '2p' "$APP_LOG" | grep -cE -- '--allow-control|--boxes' || true)"
t drill-armed-roster-mints-no-extra-role-box 1 \
  "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-armed-roster-is-distinct-in-record 1 \
  "$(grep -cF 'ok         app-armed  (agreement compared; named roster, no additional boxes)' \
    <<<"$app_roster_out")"

# The named pass carries its own honest verdict. Exercise both non-green
# summaries rather than letting a stubbed `compared` make them dead branches.
if app_roster_incomplete_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_ROSTER_STATUS=could-not-compare \
    DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  app_roster_incomplete_rc=0
else
  app_roster_incomplete_rc=$?
fi
t drill-armed-roster-noncomparable-is-incomplete 2 "$app_roster_incomplete_rc"
t drill-armed-roster-noncomparable-recorded 1 \
  "$(grep -cF 'INCOMPLETE app-armed  (agreement could-not-compare: no armed, ticking, clock-skewed box)' \
    <<<"$app_roster_incomplete_out")"

if app_roster_missing_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_ROSTER_STATUS=missing DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  app_roster_missing_rc=0
else
  app_roster_missing_rc=$?
fi
t drill-armed-roster-missing-verdict-is-red 1 "$app_roster_missing_rc"
t drill-armed-roster-missing-verdict-recorded 1 \
  "$(grep -cF 'FAIL       app-armed  (agreement verdict missing)' \
    <<<"$app_roster_missing_out")"

if app_failure_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_APP_RC=1 DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  app_failure_rc=0
else
  app_failure_rc=$?
fi
t drill-app-failure-is-red 1 "$app_failure_rc"
t drill-detail-less-failure-record-closes-parenthesis 1 \
  "$(grep -c '^## leg executed app-armed  (FAIL)$' <<<"$app_failure_out")"

# The named reading is independent of generated-role availability. A failed
# role still keeps the round red, but it must not erase the armed evidence leg.
: >"$APP_LOG"
: >"$ROLE_LOG"
if no_generated_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_LOG="$APP_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_ROLE_STAGE=none DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/armed.roster" --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  no_generated_rc=0
else
  no_generated_rc=$?
fi
t drill-armed-roster-without-generated-member-stays-red 1 "$no_generated_rc"
t drill-armed-roster-without-generated-member-still-runs 1 \
  "$(grep -cFx -- "--roster $TMP/armed.roster --no-browser" "$APP_LOG")"
t drill-armed-roster-without-generated-member-records-both-legs 2 \
  "$(grep -cE '^##   (SKIPPED +app |ok +app-armed )' <<<"$no_generated_out")"
t drill-armed-roster-without-generated-member-prints-no-empty-scope 0 \
  "$(grep -cF 'app phase covers  —' <<<"$no_generated_out" || true)"

# Reject a typo before any role or installer work starts.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if missing_roster_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --app-roster "$TMP/missing.roster" 2>&1)"; then
  missing_roster_rc=0
else
  missing_roster_rc=$?
fi
t drill-missing-app-roster-fails-early 1 "$missing_roster_rc"
t drill-missing-app-roster-names-path 1 \
  "$(grep -cF "no app roster at '$TMP/missing.roster'" <<<"$missing_roster_out")"
t drill-missing-app-roster-runs-no-role 0 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"
t drill-missing-app-roster-runs-no-installer 0 "$(wc -l <"$INSTALL_LOG" | tr -d ' ')"

# D1: valid disarmed comparisons are evidence, but not evidence for the armed
# criterion. With no second roster they make the round incomplete, not green.
if disarmed_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_APP_STATUS=could-not-compare DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  disarmed_rc=0
else
  disarmed_rc=$?
fi
t drill-disarmed-only-round-is-incomplete 2 "$disarmed_rc"
t drill-disarmed-only-record-says-could-not-compare 1 \
  "$(grep -cF 'INCOMPLETE app  (agreement could-not-compare: no armed, ticking, clock-skewed box)' \
    <<<"$disarmed_out")"
t drill-disarmed-only-record-has-no-green-app-row 0 \
  "$(grep -cE '^##   ok +app  ' <<<"$disarmed_out" || true)"

summary_count_matches_rows() {
  local record="$1" headline counted rows
  headline="$(sed -nE \
    's/^## section states: ([0-9]+) passed, ([0-9]+) failed, ([0-9]+) skipped\/not-run$/\1 \2 \3/p' \
    <<<"$record")"
  read -r passed failed skipped <<<"$headline"
  counted=$((passed + failed + skipped))
  rows="$(grep -c '^##   ' <<<"$record")"
  [ "$counted" -eq "$rows" ]
}

if summary_count_matches_rows "$phase2_out"; then r1=equal; else r1=MISMATCH; fi
t drill-phase2-keep-summary-counts-every-row equal "$r1"

if phase2_retained_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_STAGE=phase2 DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  phase2_retained_rc=0
else
  phase2_retained_rc=$?
fi
t drill-phase2-retained-stays-red 1 "$phase2_retained_rc"
t drill-phase2-retained-reports-kept-teardown 1 \
  "$(grep -cF 'kept       teardown  (round not green' <<<"$phase2_retained_out")"
t drill-phase2-retained-does-not-call-hygiene-skipped 1 \
  "$(grep -cF \
    'INCOMPLETE hygiene  (phase 2 ran without a hygiene result)' \
    <<<"$phase2_retained_out")"
if summary_count_matches_rows "$phase2_retained_out"; then r1=equal; else r1=MISMATCH; fi
t drill-phase2-retained-summary-counts-every-row equal "$r1"

: >"$SECTION_LOG"
if preinstall_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_STAGE=none DRILL_ROLE_RC=1 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then
  preinstall_rc=0
else
  preinstall_rc=$?
fi
t drill-preinstall-failure-stays-red 1 "$preinstall_rc"
t drill-preinstall-failure-reports-role 1 \
  "$(grep -cF 'FAIL       reviewer  (failed before an installed box existed)' <<<"$preinstall_out")"
for section in installer config; do
  t "drill-preinstall-skips-$section-by-role-install" 1 \
    "$(grep -cF "SKIPPED    $section  (blocked by role install: no installed drill box)" \
      <<<"$preinstall_out")"
done
t drill-preinstall-skips-app-by-role-install 1 \
  "$(grep -cF 'SKIPPED    app  (generated pass blocked by role install: no installed drill box)' \
    <<<"$preinstall_out")"
t drill-preinstall-invokes-no-independent-section 0 \
  "$(wc -l <"$SECTION_LOG" | tr -d ' ')"
if summary_count_matches_rows "$preinstall_out"; then r1=equal; else r1=MISMATCH; fi
t drill-preinstall-summary-counts-every-row equal "$r1"

required_later_sections() {
  local record="$1" section
  for section in installer config app; do
    grep -Eq "^##   (ok|FAIL|skip|SKIPPED|INCOMPLETE) +$section  " <<<"$record" \
      || return 1
  done
}
if required_later_sections "$phase2_out"; then r1=complete; else r1=MISSING; fi
t drill-phase2-record-names-every-later-section complete "$r1"
phase2_missing_app="$(sed '/^##   ok         app  /d' <<<"$phase2_out")"
if required_later_sections "$phase2_missing_app"; then r1=FALSE_PASS; else r1=red; fi
t drill-phase2-absent-section-mutation-reds red "$r1"
phase2_wrong_count="${phase2_out/4 passed, 1 failed/5 passed, 0 failed}"
if grep -qE '^## section states: 4 passed, 1 failed, [0-9]+ skipped/not-run$' \
    <<<"$phase2_wrong_count"; then r1=FALSE_PASS; else r1=red; fi
t drill-phase2-summary-count-mutation-reds red "$r1"

# Resolution failures belong to phase 0 and name both inputs before a role
# begins, so the operator can distinguish a bad ref from a role failure.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if bad_out="$(round_run "$HARNESS/rehearsal-all.sh" reviewer no-such-ref)"; then
  bad_rc=0
else
  bad_rc=$?
fi
t drill-unresolved-ref-rc 1 "$bad_rc"
case "$bad_out" in
  *"phase 0:"*"remote '$REMOTE'"*"ref 'no-such-ref'"*"to one commit"*) bad_named=named ;;
  *) bad_named=missing ;;
esac
t drill-unresolved-ref-names-reason named "$bad_named"
t drill-unresolved-ref-starts-no-role 0 "$(wc -l <"$ROLE_LOG" | tr -d ' ')"

# Invalid local role input is rejected before any remote resolution attempt.
if role_bad_out="$(round_run "$HARNESS/rehearsal-all.sh" not-a-role no-such-ref)"; then
  role_bad_rc=0
else
  role_bad_rc=$?
fi
t drill-invalid-role-rc 1 "$role_bad_rc"
case "$role_bad_out" in *"unknown role 'not-a-role'"*) role_bad_named=named ;; *) role_bad_named=missing ;; esac
t drill-invalid-role-named named "$role_bad_named"
t drill-invalid-role-skips-resolution 0 "$(grep -c 'cannot resolve remote' <<<"$role_bad_out" || true)"

# The record assertion itself must reject a summary that drops the SHA.
NO_RECORD="$HARNESS/rehearsal-all-no-record.sh"
# shellcheck disable=SC2016  # remove the literal production summary line
sed '/echo "## drilled source: \$RESOLVED_REF /d' \
  "$HARNESS/rehearsal-all.sh" >"$NO_RECORD"
: >"$ROLE_LOG"
if no_record_out="$(round_run "$NO_RECORD" reviewer "$FIRST")"; then :; fi
t drill-missing-record-sha-mutation-is-caught 0 \
  "$(grep -cF "## drilled source: $FIRST" <<<"$no_record_out" || true)"

# The role acquisition primitive is exact-object fetch plus detached checkout;
# clone --branch cannot accept the full SHA the orchestrator now passes.
# shellcheck disable=SC2016  # match literal production shell source
acquire_block="$(sed -n '/SOURCE_TREE="\$ACQUIRE_TMP\/source"/,/^fi$/p' \
  "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match literal production shell source
case "$acquire_block" in
  *'git -C "$ACQUIRE_TMP" init'*'fetch --quiet --depth=1'*'checkout --quiet --detach FETCH_HEAD'*) acquire_shape=exact ;;
  *) acquire_shape=other ;;
esac
t drill-role-acquires-exact-object exact "$acquire_shape"
t drill-role-does-not-clone-branch 0 \
  "$(grep -c 'git clone.*--branch' <<<"$acquire_block" || true)"

# --- #492: the report target is derived from the ref actually drilled ---

# shellcheck source=drill/rehearsal-report.sh
. "$ROOT/drill/rehearsal-report.sh"
GH_REMOTE="https://github.com/heavy-duty/crew.git"
derive() { rehearsal_report_target "$1" "$2" || printf '(none)\n'; }

# Every ref shape that names a pull request, and the ones that only look like
# they do. A branch, a tag and a bare commit each name a tree any number of
# pull requests may carry, so none of them derives a target.
t drill-report-target-pull-head 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" refs/pull/450/head)"
t drill-report-target-pull-merge 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" refs/pull/450/merge)"
t drill-report-target-pull-unprefixed 'heavy-duty/crew PR #450' \
  "$(derive "$GH_REMOTE" pull/450/head)"
# The suffix is required. `pull/452` is an ordinary ref shape a branch may
# occupy, so deriving from it would route findings to a PR the round never
# drilled — the end-to-end half of this is the collision round below.
t drill-report-target-pull-bare-none '(none)' "$(derive "$GH_REMOTE" pull/450)"
t drill-report-target-refs-pull-bare-none '(none)' \
  "$(derive "$GH_REMOTE" refs/pull/450)"
t drill-report-target-scp-remote 'heavy-duty/crew PR #7' \
  "$(derive git@github.com:heavy-duty/crew.git refs/pull/7/head)"
t drill-report-target-ssh-url-remote 'heavy-duty/crew PR #12' \
  "$(derive ssh://git@github.com/heavy-duty/crew.git pull/12/merge)"
t drill-report-target-branch-none '(none)' "$(derive "$GH_REMOTE" main)"
t drill-report-target-tag-none '(none)' "$(derive "$GH_REMOTE" 0.1.2)"
t drill-report-target-sha-none '(none)' "$(derive "$GH_REMOTE" "$FIRST")"
t drill-report-target-empty-ref-none '(none)' "$(derive "$GH_REMOTE" '')"
t drill-report-target-nonnumeric-none '(none)' \
  "$(derive "$GH_REMOTE" refs/pull/abc/head)"
t drill-report-target-branch-named-pull-none '(none)' \
  "$(derive "$GH_REMOTE" refs/heads/pull/450/head)"
# A remote naming no owner/repo still routes: the number is the routing and the
# slug only disambiguates it.
t drill-report-target-local-remote-keeps-number 'PR #450' \
  "$(derive "$REMOTE" refs/pull/450/head)"

# Each exit, with a target and without one. The four kinds are every footer the
# drill prints, which is what "every exit path, not just the failure path" asks
# for.
TARGET='heavy-duty/crew PR #450'
footer() { rehearsal_report_footer "$1" "$2" reviewer crew-drill-reviewer; }
t drill-report-exit-fail-names-target 1 \
  "$(grep -cF "Report findings on $TARGET with" <<<"$(footer fail "$TARGET")")"
# The only footer whose instruction and evidence share a sentence: with no
# target the report instruction goes entirely, rather than surviving as a
# `Report findings with` that routes nowhere (D2, AC1's "or no instruction at
# all"). The box line below proves the evidence half is what stayed.
t drill-report-exit-fail-no-target-drops-instruction 0 \
  "$(grep -ciF 'report findings' <<<"$(footer fail '')" || true)"
t drill-report-exit-fail-no-target-still-collects 1 \
  "$(grep -cF 'Fixtures and box are left in place. Collect' \
    <<<"$(footer fail '')")"
t drill-report-exit-incomplete-names-target 1 \
  "$(grep -cF "must not be reported as one on $TARGET." \
    <<<"$(footer incomplete "$TARGET")")"
t drill-report-exit-incomplete-no-target-drops-instruction 1 \
  "$(grep -cF 'must not be reported as one.' <<<"$(footer incomplete '')")"
t drill-report-exit-pass-names-target 1 \
  "$(grep -cF "Report the pass on $TARGET." <<<"$(footer pass "$TARGET")")"
# The pass footer's instruction is its whole second sentence, so with no target
# the sentence goes rather than becoming a bare "Report the pass."
t drill-report-exit-pass-no-target-drops-sentence 1 \
  "$(grep -cxF 'All green, phase 2 included — the reviewer loop ran.' \
    <<<"$(footer pass '')")"
t drill-report-exit-round-incomplete-names-target 1 \
  "$(grep -cF "before reporting anything on $TARGET." \
    <<<"$(footer round-incomplete "$TARGET")")"
t drill-report-exit-round-incomplete-no-target-drops-instruction 1 \
  "$(grep -cF 'before reporting anything.' <<<"$(footer round-incomplete '')")"
# The footer that routes to a box keeps the box either way: what is dropped is
# the target, never the evidence the operator has to collect.
t drill-report-exit-fail-keeps-box-either-way 2 \
  "$(grep -cF 'box shell crew-drill-reviewer' \
    <<<"$(footer fail "$TARGET"; footer fail '')")"

targeted_exits=""
untargeted_exits=""
for exit_kind in fail incomplete pass round-incomplete; do
  targeted_exits+="$(footer "$exit_kind" "$TARGET")"$'\n'
  untargeted_exits+="$(footer "$exit_kind" '')"$'\n'
done
t drill-report-every-exit-names-the-target 4 \
  "$(grep -cF "$TARGET" <<<"$targeted_exits")"
t drill-report-no-exit-names-a-pr-without-one 0 \
  "$(grep -cE 'PR #' <<<"$untargeted_exits" || true)"
if rehearsal_report_footer not-an-exit "$TARGET" reviewer box >/dev/null 2>&1; then
  unknown_kind_rc=0
else
  unknown_kind_rc=$?
fi
t drill-report-unknown-exit-kind-refused 1 "$unknown_kind_rc"

# Mutation: the literal this issue exists to remove. No exit may reach a PR
# number except through the derivation.
t drill-report-scripts-hardcode-no-pr-number 0 \
  "$(cat "$ROOT/drill/rehearsal.sh" "$ROOT/drill/rehearsal-all.sh" \
    "$ROOT/drill/rehearsal-report.sh" | grep -cE 'PR #[0-9]' || true)"

# Mutation: a stale default standing in where nothing is derivable. The
# no-target cases above must red on it, or they are asserting nothing.
STALE_LIB="$TMP/rehearsal-report-stale.sh"
# shellcheck disable=SC2016  # mutate the literal production guard
sed 's/\[ -z "\$target" \] || on=" on \$target"/on=" on ${target:-crew PR #16}"/' \
  "$ROOT/drill/rehearsal-report.sh" >"$STALE_LIB"
t drill-report-stale-mutation-applied 1 "$(grep -cF 'crew PR #16' "$STALE_LIB")"
stale_exits="$(bash -c '
  . "$1"
  for kind in fail incomplete pass round-incomplete; do
    rehearsal_report_footer "$kind" "" reviewer crew-drill-reviewer
  done' _ "$STALE_LIB")"
if grep -qE 'PR #' <<<"$stale_exits"; then r1=red; else r1=FALSE_PASS; fi
t drill-report-stale-target-mutation-is-caught red "$r1"

# End to end. The orchestrator resolves the operator's ref to a commit before
# handing it to a role (#490), so a role could not derive a target from what it
# receives — the unresolved ref travels beside it as --source-ref, and the
# resolution invariant is unchanged.
git --git-dir="$REMOTE" update-ref refs/pull/450/head "$FIRST"
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
DRILL_MOVE_TO=""
if pull_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    refs/pull/450/head)"; then pull_rc=0; else pull_rc=$?; fi
t drill-report-pull-round-is-incomplete 2 "$pull_rc"
t drill-report-pull-round-names-target 1 \
  "$(grep -cF '## in and re-run before reporting anything on PR #450.' \
    <<<"$pull_out")"
t drill-report-pull-round-passes-source-ref refs/pull/450/head \
  "$(awk '{print $5}' "$ROLE_LOG")"
t drill-report-pull-round-still-resolves-ref "$FIRST" \
  "$(awk '{print $3}' "$ROLE_LOG")"

# A branch round derives nothing and says nothing, and hands the role no
# source ref to derive from either.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
git --git-dir="$REMOTE" update-ref refs/heads/main "$FIRST"
if main_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    main)"; then :; fi
t drill-report-branch-round-drops-instruction 1 \
  "$(grep -cF '## in and re-run before reporting anything.' <<<"$main_out")"
t drill-report-branch-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$main_out" || true)"
t drill-report-branch-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

# The collision, end to end: an ordinary branch whose name occupies the pull
# ref shape. `git fetch <remote> pull/452` drills the BRANCH — the round never
# goes near pull request 452 — so a footer naming it would route findings to a
# PR this round did not touch, which is this issue's own defect in a new place.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
git --git-dir="$REMOTE" update-ref refs/heads/pull/452 "$FIRST"
if collide_out="$(DRILL_ROLE_RC=2 round_run "$HARNESS/rehearsal-all.sh" reviewer \
    pull/452)"; then :; fi
t drill-report-branch-named-pull-round-resolves "$FIRST" \
  "$(awk '{print $3}' "$ROLE_LOG")"
t drill-report-branch-named-pull-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$collide_out" || true)"
t drill-report-branch-named-pull-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

# The role script's own wiring is stubbed out by the fixture above, so these
# three pins stand in for it — each one is a mutation that would otherwise
# leave the whole suite green while the footers named the wrong thing, or
# nothing.
role_script="$(cat "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # the needles are production source, not expansions
t drill-report-role-derives-from-source-ref 1 \
  "$(grep -cF 'rehearsal_report_target "$REMOTE" "${SOURCE_REF:-$REF}"' \
    <<<"$role_script")"
# shellcheck disable=SC2016  # ditto
t drill-report-role-derivation-guarded-by-tree 1 \
  "$(grep -B 2 -F 'rehearsal_report_target "$REMOTE"' <<<"$role_script" \
    | grep -cF 'if [ -z "$TREE" ]; then')"
# shellcheck disable=SC2016  # ditto
t drill-report-role-exits-pass-the-target 3 \
  "$(grep -cE '^ *rehearsal_report_footer (fail|incomplete|pass) "\$REPORT_TARGET"' \
    <<<"$role_script")"

# --tree drills a local checkout, so a ref passed beside it is not what was
# drilled and derives nothing.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if tree_report_out="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_REMOTE="$REMOTE" DRILL_ROLE_RC=2 \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --ref refs/pull/450/head \
      --roles reviewer --keep --no-app --no-config-drill --no-resume-drill \
      --no-attention-drill --no-attention-audit-drill --no-hygiene-drill \
      --no-breaker-drill --no-notify-drill --no-fleet-drill 2>&1)"; then :; fi
t drill-report-tree-round-names-no-pr 0 \
  "$(grep -cE 'PR #[0-9]' <<<"$tree_report_out" || true)"
t drill-report-tree-round-passes-no-source-ref '-' \
  "$(awk '{print $5}' "$ROLE_LOG")"

# --- the runbook documents exactly the legs the harness declares (#497) ------
# shared/docs/rehearsal.md is the prose an operator reads before a round, and
# it went a whole release without describing a single leg that release added.
# A census catches that once; this diff catches it every time. Both directions
# are asserted because they are different defects: a leg in the harness and not
# in the runbook is an operator running something nobody explained, and a leg
# in the runbook and not in the harness is an operator preparing for a leg that
# will never appear in the record.
#
# Neither side is a list maintained here. The harness's side is its own
# DECLARED_LEGS array — the same declaration the round checks its record
# against — and the runbook's side is the headings under `## The legs`, which
# that section states are the leg names. A third copy in this file would be the
# thing that drifts.
RUNBOOK="$ROOT/shared/docs/rehearsal.md"

runbook_harness_legs() {  # the harness's own declaration, one per line
  sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$ROOT/drill/rehearsal-all.sh" \
    | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort -u
}

runbook_documented_legs() {  # the `### <leg>` headings under `## The legs`
  awk '/^## The legs$/ { inside = 1; next }
       /^## / { inside = 0 }
       inside' "$RUNBOOK" \
    | sed -n 's/^### \([a-z][a-z-]*\)[^a-z-].*$/\1/p' | sort -u
}

runbook_prose_legs() {  # the enumerating sentence, read to its blank line
  # shellcheck disable=SC2016  # the backticks are Markdown in the runbook
  awk '/^The declared legs are:/ { inside = 1 }
       inside && /^$/ { exit }
       inside' "$RUNBOOK" \
    | grep -oE '`[a-z][a-z-]*`' | tr -d '`' | sort -u
}

t drill-runbook-harness-declares-legs 13 "$(runbook_harness_legs | n)"
t drill-runbook-documents-every-declared-leg '' \
  "$(comm -23 <(runbook_harness_legs) <(runbook_documented_legs) | paste -sd, -)"
t drill-runbook-documents-no-undeclared-leg '' \
  "$(comm -13 <(runbook_harness_legs) <(runbook_documented_legs) | paste -sd, -)"
# The section's own enumerating sentence is a third surface and drifts like any
# other, so it is held to the same declaration rather than to the headings.
t drill-runbook-prose-list-matches-declaration '' \
  "$(comm -3 <(runbook_harness_legs) <(runbook_prose_legs) | tr -d '\t' \
    | paste -sd, -)"

# Mutation: the leg the harness gained but nobody wrote up — the exact shape of
# this issue's own finding. Both the census and the runbook go stale silently,
# so the assertion above has to red on a declaration it has never seen.
MUTATED_ALL="$TMP/rehearsal-all-extra-leg.sh"
sed 's/^  installer config app browser app-armed fleet teardown$/  installer config app browser app-armed fleet teardown newleg/' \
  "$ROOT/drill/rehearsal-all.sh" >"$MUTATED_ALL"
t drill-runbook-extra-leg-mutation-applied 1 \
  "$(sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$MUTATED_ALL" \
    | grep -cw newleg || true)"
t drill-runbook-extra-leg-is-undocumented newleg \
  "$(comm -23 \
      <(sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$MUTATED_ALL" \
        | sed '1d;$d' | tr ' ' '\n' | sed '/^$/d' | sort -u) \
      <(runbook_documented_legs) | paste -sd, -)"

# Mutation: a leg described in prose that the harness does not have. An
# operator prepares a prerequisite for a leg that can never reach the record.
MUTATED_DOC="$TMP/rehearsal-ghost-leg.md"
awk '{ print }
     /^### teardown — / { print ""; print "### ghostleg — a leg the harness does not have" }' \
  "$RUNBOOK" >"$MUTATED_DOC"
t drill-runbook-ghost-leg-mutation-applied 1 \
  "$(grep -cF '### ghostleg — ' "$MUTATED_DOC" || true)"
t drill-runbook-ghost-leg-is-undeclared ghostleg \
  "$(comm -13 <(runbook_harness_legs) \
      <(RUNBOOK="$MUTATED_DOC" runbook_documented_legs) | paste -sd, -)"

# The runbook describes the harness AFTER this window's repairs: the record it
# sends an operator to is the declared-leg block #495 landed, and the routing
# it describes is #492's derivation rather than the literal PR number that
# stood at :63 and :233. A number here is the same defect as a number in the
# scripts, which the assertion above already forbids.
t drill-runbook-names-the-declared-leg-record present \
  "$(grep -qF '## declared leg states:' "$RUNBOOK" && echo present || echo absent)"
t drill-runbook-hardcodes-no-pr-number 0 \
  "$(grep -cE 'PR #[0-9]' "$RUNBOOK" || true)"

# --- the drill box is minted at the drilled role's own size (#607 D4) -------
# rehearsal.sh minted every role at a flat 2 cpu / 4GiB / 20GiB, which is not
# what `crew new` does for any role in the fleet — so the one thing a green
# rehearsal could never say anything about was role sizing, and it took an
# OOM-killed reviewer to find that out.
#
# The production block is EXTRACTED AND RUN, not grepped: what matters is the
# three figures it resolves for a given role, and a grep would go green on a
# block that read the right file and resolved nothing from it.
# shellcheck disable=SC2016  # match literal production shell source
size_block="$(sed -n '/^ROLE_CONF="\$SOURCE_TREE/,/^fi$/p' "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # the printf runs in the CHILD, on its variables
drill_size_for() { # ROLE [TREE]
  env SOURCE_TREE="${2:-$ROOT}" ROLE="$1" bash -c \
    "$size_block"'; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' 2>&1
}
conf_size_for() { # ROLE
  bash -c '. "$1"; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' \
    _ "$SHARED/conf/roles/$1.conf"
}
for drill_role in reviewer triage builder; do
  t "drill-box-sized-at-$drill_role-role-size" "$(conf_size_for "$drill_role")" \
    "$(drill_size_for "$drill_role")"
done
# ...and the roles must not all resolve to one size, which is the defect this
# replaces and the state three equal comparisons above would still pass in.
t drill-box-size-differs-by-role different \
  "$([ "$(drill_size_for reviewer)" != "$(drill_size_for triage)" ] \
      && echo different || echo identical)"

# No size literal remains in that file. Comments are excluded from the
# population on purpose — the block's own comment quotes the literal it
# removed, and a guard that could not survive being explained would be
# rewritten rather than kept.
t drill-role-script-holds-no-size-literal 0 \
  "$(grep -vE '^[[:space:]]*#' "$ROOT/drill/rehearsal.sh" \
     | grep -cE -- '--(cpu|memory|disk)[= ]+[0-9]' || true)"

# The role conf is a REQUIRED INPUT, declared with the drill's other three, so
# a source that cannot say how big a $ROLE box is is refused at acquisition and
# attributed like every other missing input — not later, as a box step that
# stopped for reasons of its own.
# shellcheck disable=SC2016  # match literal production shell source
t drill-role-conf-is-a-required-input 1 \
  "$(grep -c '^for required in .*shared/conf/roles/\$ROLE\.conf' "$ROOT/drill/rehearsal.sh" || true)"

# A conf that declares no figures is REFUSED, not guessed past: minting at a
# size the fleet does not use is what this leg exists to stop.
DRILL_NOSIZE="$TMP/nosize-tree"
mkdir -p "$DRILL_NOSIZE/shared/conf/roles"
printf 'TIMEOUT_REVIEW=1\n' >"$DRILL_NOSIZE/shared/conf/roles/reviewer.conf"
nosize_out="$(drill_size_for reviewer "$DRILL_NOSIZE")"; nosize_rc=$?
t drill-box-size-undeclared-is-refused 1 "$nosize_rc"
t drill-box-size-undeclared-says-why 1 \
  "$(grep -c 'declares no BOX_CPU' <<<"$nosize_out" || true)"
missing_out="$(drill_size_for reviewer "$TMP/no-such-tree")"; missing_rc=$?
t drill-box-size-missing-conf-is-refused 1 "$missing_rc"
t drill-box-size-missing-conf-names-the-path 1 \
  "$(grep -c 'no role conf at' <<<"$missing_out" || true)"

# --- the drill mints through the ONE writer (#679 D9) -----------------------
# The drill carried its own copy of `box new --template "$AGENT-box"`, and box
# 0.10.0 refuses that spelling — so on a host at the version `crew down --force`
# requires, phase 0 died at box creation with `exit 1` before a single assertion
# ran. Gate A could not fail late and be read; it could not START.
#
# PINNED IN TWO PLACES, BECAUSE ONE OF THEM CANNOT FAIL ON ITS OWN. This suite
# stubs the role script wholesale, so nothing here executes rehearsal.sh's mint
# and a source-text guard is all this file can offer for the call site. What it
# CAN do is drive the helper that call site now runs — the same function, the
# same argv, against a stub box — so the sequence itself is asserted
# behaviourally and the drill's line is asserted to be a call into it. Between
# them, reintroducing a hand-spelled mint in rehearsal.sh reds here.

# The call site: one call into the writer, and no mint of its own. Comments are
# stripped first — this file explains the retirement it is subject to, and a
# guard that could not survive being explained would be rewritten rather than
# kept, which is the rule the size-literal guard above already states.
DRILL_CODE="$(grep -vE '^[[:space:]]*#' "$ROOT/drill/rehearsal.sh")"
t drill-mint-names-no-retired-template 0 \
  "$(grep -c -- '--template' <<<"$DRILL_CODE" || true)"
t drill-mint-spells-no-box-new-of-its-own 0 \
  "$(grep -cE '(^|[^_[:alnum:]])box new' <<<"$DRILL_CODE" || true)"
# shellcheck disable=SC2016  # match the literal production shell source
t drill-mint-calls-the-one-writer 1 \
  "$(grep -c 'box_mint_fresh "\$BOX_NAME" "\$AGENT"' <<<"$DRILL_CODE" || true)"
# The log line named a template that no longer exists, which is the half a fix
# to the command alone leaves behind: a green drill narrating a retired object.
t drill-mint-log-line-names-no-template 0 \
  "$(grep -c 'minting .*template' <<<"$DRILL_CODE" || true)"

# The helper is read out of $SOURCE_TREE and the drill refuses a source that
# predates it, rather than falling back to a spelling it would then own a second
# copy of.
t drill-mint-helper-is-a-required-input 1 \
  "$(grep -c 'no mint helper at' <<<"$DRILL_CODE" || true)"

# ONE writer in the whole tree (#679 D9's criterion, read directly): exactly one
# site invokes the bootstrap. Comments are stripped, and cli/crew's operator
# recovery line — which PRINTS the command for a human to type rather than
# running it — is not an invocation and is excluded by the leading-`rig` anchor.
t drill-bootstrap-has-exactly-one-writer 1 \
  "$(grep -rn --include='*.sh' --include=crew -hE '^[[:space:]]*rig bootstrap ' \
       "$ROOT/cli" "$ROOT/shared/lib" "$ROOT/drill" 2>/dev/null | wc -l | tr -d ' ')"

# ...and behaviourally, at the box transport boundary. This is the drill's own
# mint: the same function phase 0 calls, driven with a stub `box` on PATH.
MINT_SHIM="$TMP/mint-shim"
MINT_STATE="$TMP/mint-state"
mkdir -p "$MINT_SHIM" "$MINT_STATE"
cat >"$MINT_SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  new) shift; printf 'new %s\n' "$*" >>"$MINT_STATE/calls" ;;
  root) printf 'root %s\n' "$2" >>"$MINT_STATE/calls"; cat >"$MINT_STATE/script-$2" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MINT_SHIM/box"
mint_out="$(
  export MINT_STATE PATH="$MINT_SHIM:$PATH"
  # shellcheck source=shared/lib/box-mint.sh
  . "$ROOT/shared/lib/box-mint.sh"
  box_mint_fresh crew-drill-reviewer kimi 4 8GiB 60GiB 2>&1
)"; mint_rc=$?
t drill-mint-sequence-exits-zero 0 "$mint_rc"
# A mint that worked says nothing: the repair advice below is for the box that
# was created and then not converged, and printing it on the success path would
# make it noise a reader learns to skip.
t drill-mint-sequence-is-quiet-when-it-works "" "$mint_out"
t drill-mint-sequence-is-blank-at-the-roles-size \
  "new --name crew-drill-reviewer --user kimi --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$MINT_STATE/calls")"
t drill-mint-sequence-opens-the-root-door \
  "root crew-drill-reviewer" "$(grep '^root ' "$MINT_STATE/calls")"
t drill-mint-sequence-bootstraps-the-agents-role \
  "rig bootstrap kimi-box" \
  "$(grep -E '^rig bootstrap ' "$MINT_STATE/script-crew-drill-reviewer" || true)"
t drill-mint-sequence-emits-no-template 0 \
  "$(grep -c -- '--template' "$MINT_STATE/calls" || true)"
t drill-mint-sequence-bootstrap-names-no-user 0 \
  "$(grep -c -- '--user' "$MINT_STATE/script-crew-drill-reviewer" || true)"

# --- #729: phase 2 needs a counterparty for builder and reviewer ------------
#
# The comparison is a pure pre-fixture guard so CI drives both sides without
# a box host or GitHub identity. Matching identities refuse only the two roles
# whose fixtures require GitHub to act across accounts; differing identities,
# and triage under either identity shape, pass.
phase2_identity_guard() {
  (
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    rehearsal_phase2_identity_guard "$@"
  )
}
for phase2_role in builder reviewer; do
  phase2_same_out="$(phase2_identity_guard "$phase2_role" danmt danmt 2>&1)"
  phase2_same_rc=$?
  t "drill-phase2-$phase2_role-equal-identities-refused" 1 "$phase2_same_rc"
  t "drill-phase2-$phase2_role-refusal-names-role" 1 \
    "$(grep -cF "phase 2 $phase2_role refused" <<<"$phase2_same_out")"
  t "drill-phase2-$phase2_role-refusal-names-both-identities" 2 \
    "$(grep -oF "'danmt'" <<<"$phase2_same_out" | wc -l | tr -d ' ')"
  t "drill-phase2-$phase2_role-refusal-names-fork-prohibition" 1 \
    "$(grep -cF 'forking a repository into its own owner' <<<"$phase2_same_out")"
  t "drill-phase2-$phase2_role-refusal-names-review-prohibitions" 1 \
    "$(grep -cF "requesting or submitting a review on one's own pull request" <<<"$phase2_same_out")"
  phase2_identity_guard "$phase2_role" dan-claude-bot danmt >/dev/null
  t "drill-phase2-$phase2_role-different-identities-pass" 0 "$?"
done
phase2_identity_guard triage danmt danmt >/dev/null
t drill-phase2-triage-equal-identities-pass 0 "$?"
phase2_identity_guard triage dan-claude-bot danmt >/dev/null
t drill-phase2-triage-different-identities-pass 0 "$?"
unset -f phase2_identity_guard

# --- the attention census: recorded, then asserted, never refused (#714) -----
#
# Phase 2 used to exit 1 the moment the box identity carried an `attention`
# demand in any repository outside the sandbox, which is a real account's
# normal state — so Gate A could not run on the operator's own host and every
# role loop stayed UNPROVEN. Both halves of the replacement are driven here:
# the census that records those demands before the first authenticated tick,
# and the assertion that reads the engine's own suppressed report back after
# it. Every box read goes through the caller's bx(), so none of this needs a
# drill host, credentials, or a network.
ATT_SANDBOX="host/crew-drill-builder"
ATT_MARK="📌 picked up"
ATT_CENSUS=""
ATT_CENSUS_PAGE2=""
ATT_CENSUS_RC=0
ATT_MARK_CONF="$ATT_MARK"
ATT_LABEL_CONF="attention"
ATT_LOG_BASE=10
ATT_LOG_GEN=111
ATT_SLICE=current
ATT_SCOPE=""
ATT_LOG=""
ATT_PICKUPS_BEFORE=""
ATT_PICKUPS_AFTER=""
# Set to a directory and the log reads stop being fixture strings: the command
# the host composed is EVAL'd against a real duty.log under that HOME, so
# `stat`, `tail` and a real `mv` decide the answer. Group (h) is the only
# caller, because that is the only group about the file moving. A fixture that
# re-implemented the branch host-side would pass under its own mutation.
ATT_BOX_HOME=""
# What the box did BETWEEN the two halves — which, on the real host, is the
# tick. Eval'd inside att_drive's subshell.
ATT_BETWEEN=""
# When set, the comment read must carry this mark or the box declines.
ATT_MARK_EXPECT=""

# att_box_conf DEFAULTS_LABEL DEFAULTS_MARK [FLEET_LABEL FLEET_MARK] — the two
# real configuration files under ATT_BOX_HOME, so the conf read is executed
# rather than answered. With no third argument the box has no operator file.
att_box_conf() {
  mkdir -p "$ATT_BOX_HOME/duty/conf"
  printf 'LABEL_ATTENTION="%s"\nMARK_PICKUP="%s"\n' "$1" "$2" \
    >"$ATT_BOX_HOME/duty/conf/fleet.defaults.conf"
  rm -f "$ATT_BOX_HOME/duty/conf/fleet.conf"
  [ "$#" -lt 3 ] || printf 'LABEL_ATTENTION="%s"\nMARK_PICKUP="%s"\n' "$3" "$4" \
    >"$ATT_BOX_HOME/duty/conf/fleet.conf"
}

# The box, in the reads the two halves make of it. Each answer is a fixture
# variable, and `X` in a pickup table is the box declining to answer — the
# state the predicates must red on rather than read as zero.
att_bx() {
  local cmd="$1" key table v
  case "$cmd" in
    *'/issues?filter=assigned'*)
      [ "$ATT_CENSUS_RC" -eq 0 ] || return 1
      # The endpoint answers the label it was ASKED for, and nothing else. A
      # census keyed on a name the operator moved away from reads an empty set
      # off a board that is full — group (i).
      case "$cmd" in
        *"labels=$ATT_LABEL_CONF"*) ;;
        *) return 0 ;;
      esac
      [ -z "$ATT_CENSUS" ] || printf '%s\n' "$ATT_CENSUS"
      # ...and a second page that exists on the server and is invisible to a
      # read which does not ask for it, which is how the endpoint behaves and
      # what group (f) is about. Empty everywhere else, so every other case
      # sees the single-page box it always saw.
      case "$cmd" in
        *--paginate*) [ -z "$ATT_CENSUS_PAGE2" ] || printf '%s\n' "$ATT_CENSUS_PAGE2" ;;
      esac
      ;;
    # A REAL BOX HOME RUNS THE COMMAND IN A FRESH SHELL, not `eval`. The real
    # transport is `box exec … bash -lc` (drill/rehearsal.sh), which starts
    # with bash's default options; `eval` runs it inside THIS suite, which sets
    # `-u` and `pipefail` on line 3. A composed command that relies on either
    # then passes here and fails in the box — and worse, one that SETS
    # `pipefail` for itself cannot be mutated away in a harness that was
    # supplying it anyway: dropping it left drill.sh green while the shipped
    # read laundered a failed `head` into the checksum of nothing (round 1).
    # A fixture must not hand the implementation an option the box will not.
    #
    # Its stderr is dropped, and only its stderr: the composed command does not
    # muffle its own reads — in a real drill those messages belong on the
    # operator's console — and the two unreadable-log groups make them shout. A
    # suite that prints `error reading` while passing teaches a reader to skim
    # past the word. What the fixture actually claims is a graded row, not
    # noise: `…-fixture-really-cannot-read` asserts the read fails.
    #
    # One read, two values, resolved two different ways (the label takes the
    # operator's fleet.conf, the wire mark does not) — so the fixture answers
    # with the pair the box's own configuration would.
    *fleet.defaults.conf*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else printf '%s\n%s\n' "$ATT_LABEL_CONF" "$ATT_MARK_CONF"; fi ;;
    # The line count AND the generation it was counted against.
    *'wc -l < ~/duty/duty.log'*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else printf '%s %s\n' "$ATT_LOG_BASE" "$ATT_LOG_GEN"; fi ;;
    # The duty.log slice read — matched on a string only the composed command
    # carries, so it cannot be confused with the count above.
    *'slice: lost'*)
      if [ -n "$ATT_BOX_HOME" ]; then ( HOME="$ATT_BOX_HOME"; bash -c "$cmd" 2>/dev/null )
      else
        printf 'slice: %s\n' "$ATT_SLICE"
        [ "$ATT_SLICE" = lost ] || [ -z "$ATT_LOG" ] || printf '%s\n' "$ATT_LOG"
      fi ;;
    *suppressed-attention-scope*) [ -z "$ATT_SCOPE" ] || printf '%s\n' "$ATT_SCOPE" ;;
    *'/comments?per_page=100'*)
      # A comment search for a mark nothing writes finds nothing, and this box
      # says so by declining rather than by answering 0 — the delta's own
      # fail-closed branch. Group (i) sets this to the WIRE mark, so a read
      # that let fleet.conf move it is killed on behaviour.
      case "${ATT_MARK_EXPECT:-}" in
        '') ;;
        *) case "$cmd" in *"$ATT_MARK_EXPECT"*) ;; *) return 1 ;; esac ;;
      esac
      key="$(sed -n "s|.*repos/\([^']*\)/issues/\([0-9]*\)/comments.*|\1#\2|p" <<<"$cmd")"
      if [ "${ATT_PHASE:-before}" = before ]; then table="$ATT_PICKUPS_BEFORE"; else table="$ATT_PICKUPS_AFTER"; fi
      v="$(awk -v k="$key" '$1 == k { print $2; exit }' <<<"$table")"
      [ "$v" != X ] || return 1
      printf '%s\n' "${v:-0}"
      ;;
    *) return 1 ;;
  esac
}

# att_drive take|both [drain] — run the halves against the fixture box and
# print the rows they emit. The caller supplies ok()/fail() exactly as
# rehearsal.sh does, so a row's GRADE is observed and not inferred from a
# return code.
#
# `drain` is the REAL transport's stdin behaviour, and without it this harness
# cannot see the defect it is here to pin: rehearsal.sh's bx() is `box exec …
# bash -lc`, and `box exec` DRAINS the stdin it inherits (drill/rehearsal-app.sh
# :540-550, found by running that leg and not by reading it). A plain att_bx
# never touches stdin, so a per-demand box read that eats its own loop reads
# green through it. The subshell's own stdin is /dev/null so the drain
# terminates on every call rather than on a terminal — the loop input a
# truncating implementation eats is its `<<<` here-string, which is inside the
# function either way.
att_drive() {
  (
    ok()   { echo "ok $1"; }
    fail() { echo "FAIL $1"; }
    if [ "${2:-}" = drain ]; then
      bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    else
      bx() { att_bx "$1"; }
    fi
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    rehearsal_attention_census_take "$ATT_SANDBOX" || echo "TAKE-RC=$?"
    [ "$1" = both ] || exit 0
    # The tick, in whatever the group needs it to have done to the box.
    [ -z "$ATT_BETWEEN" ] || eval "$ATT_BETWEEN"
    ATT_PHASE=after
    rehearsal_attention_census_assert "$ATT_SANDBOX" || echo "ASSERT-RC=$?"
  ) </dev/null
}

# att_pickup_rows ROWS — the pickup census in isolation, through a draining
# box, so a truncated table is unambiguously that function's and not a grading
# artifact somewhere above it.
att_pickup_rows() {
  (
    bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    rehearsal_attention_pickup_counts "$1" "$ATT_MARK"
  ) </dev/null
}
att_ok()   { grep -c '^ok ' <<<"$1" || true; }
att_fail() { grep -c '^FAIL ' <<<"$1" || true; }

# (a) two demands parked outside the sandbox, and a tick that suppressed both.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_BEFORE="$(printf 'heavy-duty/incubator#468 0\nheavy-duty/incubator#469 3\n')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
ATT_BOTH="$(att_drive both)"
# The demand is RECORDED and the round continues. This is the case that made
# Gate A unrunnable on the operator's host: before #714 the preamble exited 1
# here, and there was no census to take.
t drill-attention-census-records-two 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_BOTH" || true)"
t drill-attention-census-names-each-demand 2 \
  "$(grep -c '^  census: heavy-duty/incubator#46[89]$' <<<"$ATT_BOTH" || true)"
t drill-attention-census-suppressed-both-green 0 "$(att_fail "$ATT_BOTH")"
# Six rows, counted rather than approximated: the census row, the one negative
# session row, and a suppressed + no-pickup pair PER recorded demand. A leg
# that graded the demands as a set would read green here with two rows.
t drill-attention-census-suppressed-rows 7 "$(att_ok "$ATT_BOTH")"
# A demand that already carried pickup comments from an earlier life is not a
# failure: the assertion is a DELTA across the tick, and #469 arrives with 3.
t drill-attention-census-standing-pickups-are-not-a-pickup 1 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#469 drew no pickup$' <<<"$ATT_BOTH" || true)"

# The log line alone is enough when the state file has been emptied: both
# records are accepted, because report_suppressed writes the line only on a
# CHANGE and removes the file when the set empties.
ATT_SCOPE=""
t drill-attention-census-log-line-alone-is-evidence 0 "$(att_fail "$(att_drive both)")"
# ...and the state file alone is enough when the line was written on an earlier
# tick, which is every --reuse pass.
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
t drill-attention-census-scope-state-alone-is-evidence 0 "$(att_fail "$(att_drive both)")"

# (b) one recorded demand with neither record naming it — the D3 miss.
ATT_SCOPE='heavy-duty/incubator#468 2026-09-10T21:00:00Z'
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 1 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_MISS="$(att_drive both)"
t drill-attention-census-unsuppressed-demand-fails 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#469 seen and suppressed$' <<<"$ATT_MISS" || true)"
t drill-attention-census-unsuppressed-names-what-it-read 1 \
  "$(grep -c '^  read: neither ~/duty/.suppressed-attention-scope nor an "attention: outside repos.txt" line names heavy-duty/incubator#469$' <<<"$ATT_MISS" || true)"
# ...and the round stops: the half returns non-zero, which is what rehearsal.sh
# exits on before another tick can strike.
t drill-attention-census-unsuppressed-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_MISS" || true)"
# The demand that WAS suppressed still reads green beside it — a miss is per
# demand, not a verdict on the census.
t drill-attention-census-miss-is-per-demand 1 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#468 seen and suppressed$' <<<"$ATT_MISS" || true)"

# (c) a session dispatched to a repository other than the sandbox.
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=heavy-duty/incubator#468 timeout=1800s log=/l holder=x sid=2')"
ATT_STRAY="$(att_drive both)"
t drill-attention-census-outside-session-fails 1 \
  "$(grep -c '^FAIL attention census: no attention session launched outside host/crew-drill-builder$' <<<"$ATT_STRAY" || true)"
t drill-attention-census-outside-session-quotes-the-record 1 \
  "$(grep -c '^  read: SESSION START kind=attention key=heavy-duty/incubator#468 ' <<<"$ATT_STRAY" || true)"
t drill-attention-census-outside-session-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_STRAY" || true)"

# A new pickup comment across the tick is the third miss, and the one that says
# the wake actually ACTED on a demand outside the registry.
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_AFTER="$(printf 'heavy-duty/incubator#468 1\nheavy-duty/incubator#469 3\n')"
ATT_PICKED="$(att_drive both)"
t drill-attention-census-new-pickup-fails 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#468 drew no pickup$' <<<"$ATT_PICKED" || true)"
t drill-attention-census-new-pickup-quotes-the-delta 1 \
  "$(grep -c '^  read: heavy-duty/incubator#468 drew 1 new "📌 picked up" comment(s) across the tick (0 -> 1)$' <<<"$ATT_PICKED" || true)"
# A comment read the box would not answer is a red, not a zero: an absence is
# established by reading the source, never by failing to read it.
ATT_PICKUPS_AFTER="$(printf 'heavy-duty/incubator#468 X\nheavy-duty/incubator#469 3\n')"
ATT_UNREAD="$(att_drive both)"
t drill-attention-census-unreadable-comments-fail 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#468 drew no pickup$' <<<"$ATT_UNREAD" || true)"
t drill-attention-census-unreadable-comments-say-so 1 \
  "$(grep -c '^  read: could not read the "📌 picked up" comment count of heavy-duty/incubator#468 (before: 0, after: unreadable)$' <<<"$ATT_UNREAD" || true)"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# (d) an identity carrying nothing outside the sandbox: the census reports 0
# and the leg asserts nothing, which is the behaviour that shipped before this.
ATT_CENSUS=""
ATT_ZERO="$(att_drive both)"
t drill-attention-census-zero-reports-zero 1 \
  "$(grep -c '^ok attention census: 0 demand(s) parked outside host/crew-drill-builder$' <<<"$ATT_ZERO" || true)"
t drill-attention-census-zero-asserts-nothing 1 "$(att_ok "$ATT_ZERO")"
t drill-attention-census-zero-is-green 0 "$(att_fail "$ATT_ZERO")"

# The census fails CLOSED. The read it replaced ended in `|| true`, so a box
# that would not answer read as a clean bill of health; the caller refuses on
# this rc, and the reason it prints comes back in the same variable.
ATT_CENSUS_RC=1
ATT_UNANSWERED="$(att_drive take)"
t drill-attention-census-unreadable-box-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$ATT_UNANSWERED" || true)"
t drill-attention-census-unreadable-box-emits-no-row 0 "$(att_ok "$ATT_UNANSWERED")"
ATT_CENSUS_RC=0
# ...and so does a box whose installed configuration resolves no MARK_PICKUP: a
# no-pickup assertion counting a needle nothing writes is green on every board.
ATT_CENSUS='heavy-duty/incubator 468'
ATT_MARK_CONF=""
t drill-attention-census-no-mark-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_MARK_CONF="$ATT_MARK"

# The refusal itself is gone from the preamble. A census that reads everything
# correctly and is still guarded by an `exit` on a non-empty result would leave
# Gate A exactly where #714 found it, and no fixture above would notice.
t drill-attention-census-preamble-refuses-no-parked-demand 0 \
  "$(grep -c 'no parked demand outside' "$ROOT/drill/rehearsal.sh" || true)"
# shellcheck disable=SC2016  # a literal source match: "$SANDBOX" is the text
t drill-attention-census-preamble-calls-both-halves 2 \
  "$(grep -cE 'rehearsal_attention_census_(take|assert) "\$SANDBOX"' "$ROOT/drill/rehearsal.sh" || true)"
# The assertion must run AFTER the wake rows: the suppressed report it reads is
# written by the same duty_attention call, above the same partition, that
# dispatched the sandbox demand. Read earlier it would be some other tick's.
t drill-attention-census-asserts-after-the-wake ordered \
  "$(awk '/rehearsal_attention_census_take/{take=NR}
          /label removed \(ack re-arms\)/{wake=NR}
          /rehearsal_attention_census_assert/{assert=NR}
          END{print (take && wake && assert && take < wake && wake < assert) ? "ordered" : "OUT-OF-ORDER"}' \
      "$ROOT/drill/rehearsal.sh")"
# ...and the sandbox demand must be minted BEFORE the census is taken (#714,
# round 4). Both reads are one page of an endpoint that answers newest first,
# so minting after the census displaces the OLDEST outside demand off the page
# the engine will fetch, and the assert half then grades a row no correct
# engine can hold a record for. Group (g) below drives that failure; this row
# is the ordering it turns on, and no fixture driving the two halves can pin
# it, because the mint is the caller's and not theirs.
#
# The census still precedes the wake marker: it captures duty.log's length,
# and D3's negative-session assertion reads only what was written after it.
t drill-attention-census-mints-the-sandbox-demand-first ordered \
  "$(awk '/drill: attention wake /{ if (!mint) mint = NR }
          /rehearsal_attention_census_take/{ if (!take) take = NR }
          /-- attention wake --/{ if (!wake) wake = NR }
          END{print (mint && take && wake && mint < take && take < wake) ? "ordered" : "OUT-OF-ORDER"}' \
      "$ROOT/drill/rehearsal.sh")"

# (e) THE PER-DEMAND BOX READ MUST NOT EAT THE LOOP IT RUNS IN (#714, round 1).
#
# Every case above drives a box that never touches stdin, and the real one
# drains it. A pickup census whose read swallowed its own row list counted the
# FIRST demand and nothing else — and did not fail quietly: demands 2..N took
# the fail-closed `could not read` branch, the assert half returned 1, and
# rehearsal.sh refused the round. That is acceptance criterion 1 unmet on every
# identity carrying more than one parked demand, which is the host this issue
# was minted from (heavy-duty/incubator #468, #469, #470 on dan-office-workstation).
#
# THREE demands, not two: one cannot tell a loop that ran once from a loop that
# ran, and two cannot tell a loop that ran once from a loop that read the row
# list one line short.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\nheavy-duty/incubator 470\n')"
ATT_SCOPE="$(printf '%s\n' \
  'heavy-duty/incubator#468 2026-09-10T21:00:00Z' \
  'heavy-duty/incubator#469 2026-09-10T21:00:01Z' \
  'heavy-duty/incubator#470 2026-09-10T21:00:02Z')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 3 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) heavy-duty/incubator#470(2026-09-10T21:00:02Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
ATT_PICKUPS_BEFORE="$(printf '%s\n' \
  'heavy-duty/incubator#468 0' 'heavy-duty/incubator#469 0' 'heavy-duty/incubator#470 0')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
# The function alone, so a short table is unambiguously its own doing.
t drill-attention-census-pickup-read-does-not-eat-its-loop 3 \
  "$(att_pickup_rows "$ATT_CENSUS" | grep -c . || true)"
t drill-attention-census-pickup-read-names-the-last-demand 1 \
  "$(att_pickup_rows "$ATT_CENSUS" | grep -c '^heavy-duty/incubator#470 0$' || true)"
# ...and the whole leg through the same box: eight rows (the census row, the
# negative session row, and a suppressed + no-pickup pair per demand), no FAIL,
# and no refusal. A truncating read reds the last two pairs on the branch
# written for a box that will not answer, which reads as a real finding.
ATT_DRAIN="$(att_drive both drain)"
t drill-attention-census-draining-box-grades-every-demand 3 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#4[0-9]* drew no pickup$' <<<"$ATT_DRAIN" || true)"
t drill-attention-census-draining-box-is-green 0 "$(att_fail "$ATT_DRAIN")"
t drill-attention-census-draining-box-rows 9 "$(att_ok "$ATT_DRAIN")"
t drill-attention-census-draining-box-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_DRAIN" || true)"
# The OTHER direction the drain runs in, and the second guard's own kill: the
# read closes its own stdin, so it cannot eat a CALLER's loop either. Nothing
# drives this function per row today; the fd-3 guard above protects its own
# loop and could not protect that one, which is why the redirect is on the call
# as well. Both rows red if either guard is dropped, and neither is a grep for
# source text.
att_pickup_rows_nested() {
  (
    bx() { cat >/dev/null 2>&1 || true; att_bx "$1"; }
    # shellcheck source=drill/rehearsal-safety.sh
    . "$ROOT/drill/rehearsal-safety.sh"
    ATT_PHASE=before
    local repo num
    while read -r repo num; do
      [ -n "${num:-}" ] || continue
      rehearsal_attention_pickup_counts "$repo $num" "$ATT_MARK"
    done <<<"$1"
  ) </dev/null
}
t drill-attention-census-pickup-read-does-not-eat-a-caller-loop 3 \
  "$(att_pickup_rows_nested "$ATT_CENSUS" | grep -c . || true)"

# (f) THE CENSUS'S WINDOW IS THE ENGINE'S WINDOW (#714, round 2).
#
# The census is not an independent enumeration of what the identity carries:
# it is a mirror of the page duty_attention itself fetched, because the assert
# half then demands, per recorded row, that the engine has a suppressed record
# for it. The engine's read is unpaginated (shared/lib/duty-attention.sh:115)
# and its .suppressed-attention-scope file is re-derived from that one page's
# partition — so on a host carrying more than a page of demands, a record
# exists for page 1 and cannot exist for page 2, no matter how correct the
# engine is. That is exactly the box modelled here: page 1 answers a plain
# read, pages 1+2 answer a `--paginate`d one, and the scope file names page 1.
#
# Today's code records the page-1 set and the leg is green. Add `--paginate`
# to the census read and all four rows below red: the census row names three
# demands, #470 is graded, `…#470 seen and suppressed` FAILs against an engine
# that did nothing wrong, and the round stops — the false refusal this issue
# removes, re-created one tick later. So this is the kill the window did not
# have, and it is behaviour, not a grep for the absence of a flag.
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
ATT_CENSUS_PAGE2="$(printf 'heavy-duty/incubator 470\n')"
ATT_SCOPE="$(printf '%s\n' \
  'heavy-duty/incubator#468 2026-09-10T21:00:00Z' \
  'heavy-duty/incubator#469 2026-09-10T21:00:01Z')"
ATT_LOG="$(printf '%s\n' \
  'WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) ' \
  'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1')"
# #470 is in the pickup tables so that a paginating census reds on the ONE
# thing it should — no engine record — and not on a table lookup that happens
# to be short.
ATT_PICKUPS_BEFORE="$(printf '%s\n' \
  'heavy-duty/incubator#468 0' 'heavy-duty/incubator#469 0' 'heavy-duty/incubator#470 0')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"
ATT_WINDOW="$(att_drive both drain)"
t drill-attention-census-window-is-the-engines-window 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_WINDOW" || true)"
t drill-attention-census-window-omits-the-second-page 0 \
  "$(grep -c '470' <<<"$ATT_WINDOW" || true)"
t drill-attention-census-window-is-green 0 "$(att_fail "$ATT_WINDOW")"
t drill-attention-census-window-rows 7 "$(att_ok "$ATT_WINDOW")"
ATT_CENSUS_PAGE2=""

# (g) THE PAGE BOUNDARY: THE DRILL'S OWN FIXTURE MOVES THE ENGINE'S PAGE
# (#714, round 4).
#
# Group (f) proves the census does not read WIDER than the engine, holding both
# pages static across the tick. That is not the only way the two windows come
# apart, and the other way is the drill's own doing. `/issues?filter=assigned`
# answers newest first, and the census and duty_attention each read one
# `per_page=100` page of it — so minting the sandbox `attention` demand INSERTS
# a row at the head of that page and displaces the oldest outside demand off
# the engine's next fetch. A census taken before the mint records 100 rows; the
# engine correctly writes records for the 99 it fetched; the displaced
# hundredth reds and the round stops. That is the false refusal this issue
# removes, re-created one tick later at the boundary.
#
# 100 rows, the engine's real per_page, because the cap IS the boundary: below
# it both orderings record the same set and there is nothing to see. Newest
# first, so `#1` is the oldest demand and the one that falls off.
#
# The two orderings are driven against ONE correct engine — its suppressed
# scope is the post-mint page either way, because the tick always runs after
# the mint. What differs is only which page the census read.
att_page() { # att_page STAGED — the rows one per_page=100 read yields, with
             # the sandbox demand dropped as the census's own --jq drops it
  { [ "$1" = 1 ] && printf '%s 7\n' "$ATT_SANDBOX"
    awk 'BEGIN { for (i = 100; i >= 1; i--) printf "heavy-duty/incubator %d\n", i }'
  } | head -n 100 | awk -v s="$ATT_SANDBOX" '$1 != s'
}
ATT_SCOPE="$(att_page 1 | awk '{ printf "%s#%s 2026-09-11T00:00:00Z\n", $1, $2 }')"
ATT_LOG='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
# Explicit zeroes for every row of the WIDER page, so the displaced demand reds
# on the one thing it should — no engine record — and never on a pickup table
# that happened to be short.
ATT_PICKUPS_BEFORE="$(att_page 0 | awk '{ print $1 "#" $2 " 0" }')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# The ordering that shipped through round 3: census first, mint second.
ATT_CENSUS="$(att_page 0)"
ATT_EARLY="$(att_drive both drain)"
t drill-attention-census-boundary-early-census-records-100 1 \
  "$(grep -c '^ok attention census: 100 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_EARLY" || true)"
t drill-attention-census-boundary-early-census-fails-the-displaced-demand 1 \
  "$(grep -c '^FAIL attention census: heavy-duty/incubator#1 seen and suppressed$' <<<"$ATT_EARLY" || true)"
t drill-attention-census-boundary-early-census-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_EARLY" || true)"
# One red, and it is a red against an engine that did nothing wrong: the other
# 99 demands are graded and green beside it.
t drill-attention-census-boundary-early-census-reds-only-that-one 1 "$(att_fail "$ATT_EARLY")"
t drill-attention-census-boundary-early-census-grades-every-row 202 "$(att_ok "$ATT_EARLY")"

# The ordering this round ships: mint first, so the census's page IS the page
# the engine will fetch.
ATT_CENSUS="$(att_page 1)"
ATT_STAGED="$(att_drive both drain)"
t drill-attention-census-boundary-staged-census-records-the-engines-page 1 \
  "$(grep -c '^ok attention census: 99 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_STAGED" || true)"
t drill-attention-census-boundary-staged-census-omits-the-displaced-demand 0 \
  "$(grep -c '^  census: heavy-duty/incubator#1$' <<<"$ATT_STAGED" || true)"
t drill-attention-census-boundary-staged-census-is-green 0 "$(att_fail "$ATT_STAGED")"
t drill-attention-census-boundary-staged-census-grades-every-row 201 "$(att_ok "$ATT_STAGED")"
t drill-attention-census-boundary-staged-census-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_STAGED" || true)"

# ...and the two above are the two sides, documented. THIS is the kill: which
# page the census reads is not a property of either half — it is decided by the
# order rehearsal.sh calls them in — so the fixture READS that order off the
# production file and drives the page it implies. Move the mint back below the
# census and these two rows red on behaviour, through the real functions,
# against an engine that did nothing wrong.
att_staged_by_source() {
  awk '/drill: attention wake /{ if (!mint) mint = NR }
       /rehearsal_attention_census_take/{ if (!take) take = NR }
       END { print (mint && take && mint < take) ? 1 : 0 }' \
    "$ROOT/drill/rehearsal.sh"
}
ATT_CENSUS="$(att_page "$(att_staged_by_source)")"
ATT_SOURCED="$(att_drive both drain)"
t drill-attention-census-boundary-source-ordering-is-green 0 "$(att_fail "$ATT_SOURCED")"
t drill-attention-census-boundary-source-ordering-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_SOURCED" || true)"

# (h) DUTY.LOG ROTATES UNDER THE CENSUS (#714, round 5).
#
# The take half counts duty.log's lines; the assert half reads what was written
# after them. shared/bin/tick.sh:31-34 moves that file to duty.log.1 once it
# passes 5 MiB, BEFORE opening the append redirect for the run — deliberately,
# and its own comment says why. A drill box is reused between passes and its
# cron has been striking since install, so the tick this leg is about can put
# the round's records near line 1 of a FRESH file and leave `tail -n +<count+1>`
# returning nothing. Every D2 row then reads green over evidence nobody read:
# an absence established by failing to read, which is the exact failure this
# leg exists to stop, one file down from the demands.
#
# THE BOX HERE IS A REAL DIRECTORY. The command the host composes is eval'd
# against it, `stat` reads real inodes, and the rotation between the halves is
# a real `mv` — because a fixture that re-implements the branch host-side
# passes under its own mutation and proves nothing about the command that ships.
ATT_BOX_HOME="$TMP/att-box"
mkdir -p "$ATT_BOX_HOME/duty"
ATT_ROT_WARN='WARN attention: outside repos.txt: 2 item(s) in repos this box does not carry, never picked up — heavy-duty/incubator#468(2026-09-10T21:00:00Z) heavy-duty/incubator#469(2026-09-10T21:00:01Z) '
# The generation the census counts: 100 lines of an EARLIER pass, one of them
# an attention session dispatched outside the sandbox. It is a previous life's
# and must stay out of this round's slice — which is what the line count is for
# and why a rotation-aware read still has to apply it to the rotated file.
att_rot_setup() {
  att_box_conf attention "$ATT_MARK"
  rm -f "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { awk 'BEGIN { for (i = 1; i <= 49; i++) printf "tick %d duty run end\n", i }'
    echo 'SESSION START kind=attention key=heavy-duty/incubator#470 timeout=1800s log=/l holder=x sid=0'
    awk 'BEGIN { for (i = 51; i <= 100; i++) printf "tick %d duty run end\n", i }'
  } >"$ATT_BOX_HOME/duty/duty.log"
}
# What the ticks did. Tick 1 appends this round's suppressed report to the
# generation the census counted; tick 2 finds it over the threshold, rotates,
# and writes its own records into a fresh one. BOTH halves are this round's,
# which is why the slice has to span them.
att_rot_tick() {
  printf '%s\n' "$ATT_ROT_WARN" >>"$ATT_BOX_HOME/duty/duty.log"
  mv "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { echo 'tick 2026-09-11T18:00:00Z duty run start'
    printf '%s\n' "$ATT_ROT_FRESH"
  } >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_rot_tick'
ATT_CENSUS="$(printf 'heavy-duty/incubator 468\nheavy-duty/incubator 469\n')"
# NO state file: the suppressed evidence exists only in the rotated tail, so a
# read that misses that tail cannot pass by another route.
ATT_SCOPE=""
ATT_PICKUPS_BEFORE="$(printf 'heavy-duty/incubator#468 0\nheavy-duty/incubator#469 0\n')"
ATT_PICKUPS_AFTER="$ATT_PICKUPS_BEFORE"

# h1 — the case codex-bot reported: the saved line number exceeds the fresh
# log's length, and the fresh generation carries an outside attention session.
ATT_ROT_FRESH='SESSION START kind=attention key=outside/repo#7 timeout=1800s log=/l holder=x sid=9'
att_rot_setup
ATT_ROTATED="$(att_drive both drain)"
t drill-attention-census-rotation-sees-the-outside-session 1 \
  "$(grep -c '^FAIL attention census: no attention session launched outside host/crew-drill-builder$' <<<"$ATT_ROTATED" || true)"
t drill-attention-census-rotation-quotes-the-outside-session 1 \
  "$(grep -c '^  read: SESSION START kind=attention key=outside/repo#7 ' <<<"$ATT_ROTATED" || true)"
t drill-attention-census-rotation-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROTATED" || true)"

# h2 — the same rotation with a fresh generation that did nothing wrong. This
# is the row that kills three implementations at once: the shipped one (an
# empty slice, so the suppressed report in the rotated tail is missed and both
# demands red), a read of the new generation alone (same), and a whole-file
# read (the previous pass's outside session at line 50 reds a correct round).
# Only a slice spanning duty.log.1's tail and all of duty.log is green here.
ATT_ROT_FRESH='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
att_rot_setup
ATT_ROT_CLEAN="$(att_drive both drain)"
t drill-attention-census-rotation-clean-is-green 0 "$(att_fail "$ATT_ROT_CLEAN")"
t drill-attention-census-rotation-reads-the-rotated-tail 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_ROT_CLEAN" || true)"
t drill-attention-census-rotation-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_ROT_CLEAN" || true)"

# h3 — the generation is on NEITHER file: two rotations, or a box rebuilt under
# the round. Nothing can be concluded from what is left, so the leg says so and
# stops — and emits no other assert row at all, because a red bounding row
# beside four vacuous greens is the same lie in a longer form.
#
# Note what decides this row and what does not. The second `mv` frees the
# counted generation's inode, and whether the kernel then hands that very
# number back to the `echo` below is the FILESYSTEM's business: tmpfs does not,
# ext4 does. This row must land `lost` either way, which it does only because
# the mark carries the counted lines' checksum as well as the inode — a reused
# inode arrives under a first line the census never counted. h4 drives the
# reuse case deterministically rather than waiting for a filesystem to do it.
att_rot_lose() {
  att_rot_tick
  mv "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  echo 'tick 2026-09-11T18:05:00Z duty run start' >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_rot_lose'
att_rot_setup
ATT_ROT_LOST="$(att_drive both drain)"
t drill-attention-census-lost-generation-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_ROT_LOST" || true)"
t drill-attention-census-lost-generation-says-what-it-read 1 \
  "$(grep -c '^  read: the duty.log generation the census counted is now neither duty.log nor duty.log.1' <<<"$ATT_ROT_LOST" || true)"
t drill-attention-census-lost-generation-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROT_LOST" || true)"
# One ok row, and it is the take half's census row: nothing downstream of the
# slice is graded at all.
t drill-attention-census-lost-generation-grades-nothing-after-it 1 "$(att_ok "$ATT_ROT_LOST")"

# h4 — THE COUNTED GENERATION'S NUMBER, WORN BY A FILE THAT IS NOT IT. The log
# is truncated in place and rewritten: `>` re-uses the open inode by
# construction, on every filesystem, so this forges the identity h3 can only
# forge when the kernel happens to co-operate. It is also a real state — a
# rebuilt box, or anything that rewrites the log in place — and the round's
# suppressed report, appended before the truncation, is destroyed with it.
#
# This is the row that kills an inode-only mark, which is what this leg shipped
# with until ci-shell graded it on ext4: that implementation reads `current`,
# runs `tail -n +101` off the end of a two-line file, and returns an empty
# slice, so the bounding row greens and four vacuous assertions are graded
# against evidence that no longer exists. The fresh generation is deliberately
# INNOCENT — it names the sandbox, not an outside repo — so nothing but the
# bounding row can red here, and a mark that cannot tell the files apart is
# caught by the greens it produces and not by a coincidence.
att_rot_truncate() {
  printf '%s\n' "$ATT_ROT_WARN" >>"$ATT_BOX_HOME/duty/duty.log"
  printf '%s\n' 'tick 2026-09-11T18:05:00Z duty run start' "$ATT_ROT_FRESH" \
    >"$ATT_BOX_HOME/duty/duty.log"
}
ATT_ROT_FRESH='SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1'
ATT_BETWEEN='att_rot_truncate'
att_rot_setup
ATT_ROT_SAME_INODE_GEN="$(stat -c %i "$ATT_BOX_HOME/duty/duty.log")"
ATT_ROT_REUSED="$(att_drive both drain)"
# The fixture only proves what it claims if the inode really did survive: a
# truncation that silently replaced the file would make this an expensive
# duplicate of h3.
t drill-attention-census-reused-inode-fixture-kept-the-inode "$ATT_ROT_SAME_INODE_GEN" \
  "$(stat -c %i "$ATT_BOX_HOME/duty/duty.log")"
t drill-attention-census-reused-inode-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-says-what-it-read 1 \
  "$(grep -c '^  read: the duty.log generation the census counted is now neither duty.log nor duty.log.1' <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_ROT_REUSED" || true)"
t drill-attention-census-reused-inode-grades-nothing-after-it 1 "$(att_ok "$ATT_ROT_REUSED")"

# h5 — NOTHING ROTATED, AND THE COUNT STILL DECIDES WHOSE LINES THESE ARE.
# The offset is what makes a reused drill box safe: `--reuse` passes leave
# their records behind, and one of them is an attention session dispatched
# outside the sandbox by a PREVIOUS life. It sits above the census mark, so it
# is not this round's and the negative assertion must not see it.
#
# This is the row claude-bot's round-1 nit asked for: the same expression is
# killed one branch down by h2, but only where the log rotated. Every other
# fixture that lands on `current` either answers a canned string instead of
# running the composed command, or starts from an empty log — where
# `tail -n +1` and `cat` are the same read and no mutation can tell them
# apart. Here they differ by exactly one line, and it is a damning one.
att_prev_setup() {
  att_box_conf attention "$ATT_MARK"
  rm -f "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
  { awk 'BEGIN { for (i = 1; i <= 49; i++) printf "tick %d duty run end\n", i }'
    echo 'SESSION START kind=attention key=heavy-duty/incubator#470 timeout=1800s log=/l holder=x sid=0'
  } >"$ATT_BOX_HOME/duty/duty.log"
}
# This round, appended to that same file: the suppressed report both demands
# are graded against, and a session that names the sandbox. No `mv` anywhere.
att_prev_tick() {
  printf '%s\n' "$ATT_ROT_WARN" \
    'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1' \
    >>"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_prev_tick'
att_prev_setup
ATT_PREV="$(att_drive both drain)"
# The seed is the whole fixture: without that line above the mark, a whole-file
# read and a bounded one agree and the row below proves nothing.
t drill-attention-census-previous-pass-fixture-seeded-the-line 1 \
  "$(grep -c 'key=heavy-duty/incubator#470 ' "$ATT_BOX_HOME/duty/duty.log" || true)"
t drill-attention-census-previous-pass-is-not-this-round 0 "$(att_fail "$ATT_PREV")"
t drill-attention-census-previous-pass-suppressed-both 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_PREV" || true)"
t drill-attention-census-previous-pass-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_PREV" || true)"

# h6 — A DUTY.LOG THAT IS THERE AND WILL NOT READ (round 1, codex-bot).
#
# The third state again, on the file rather than on the board: not "the log was
# empty" and not "the generation is gone", but "nobody read it". Before this
# round every read on this path laundered its own failure — `wc -l … || echo 0`
# made an unopenable log a log of length 0, `head | cksum` with no `pipefail`
# made a failed read the checksum of nothing, and the slice recomputed the mark
# the SAME way, matched itself, and returned `slice: current` with an empty
# body. Every D2 row then graded green over a file nobody had read.
#
# THE FIXTURE DOES NOT USE `chmod 000`. Root reads a 0000 file, and neither a
# builder box nor a CI runner is guaranteed to be non-root, so a permission
# fixture can pass vacuously on the machine that is supposed to grade it — the
# exact failure mode this group is about, wearing a fixture's clothes. A
# duty.log that is a DIRECTORY fails `wc -l <`, `head` and `tail` with EISDIR
# under every uid, which is the state under test: it exists, and it will not
# read.
att_unreadable_make() {
  rm -rf "$ATT_BOX_HOME/duty/duty.log"
  mkdir "$ATT_BOX_HOME/duty/duty.log"
}
att_unreadable_cannot_read() {
  if wc -l <"$ATT_BOX_HOME/duty/duty.log" >/dev/null 2>&1; then echo readable; else echo unreadable; fi
}
# (h6a) unreadable at the census: the take half refuses, and rehearsal.sh's
# caller stops the round there. NOTHING is graded — not even the census row,
# which is emitted after this read for exactly that reason.
att_box_conf attention "$ATT_MARK"
rm -f "$ATT_BOX_HOME/duty/duty.log.1"
att_unreadable_make
ATT_BETWEEN=""
ATT_UNREADABLE_TAKE="$(att_drive take drain)"
t drill-attention-census-unreadable-fixture-really-cannot-read unreadable \
  "$(att_unreadable_cannot_read)"
t drill-attention-census-unreadable-log-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$ATT_UNREADABLE_TAKE" || true)"
t drill-attention-census-unreadable-log-grades-nothing 0 "$(att_ok "$ATT_UNREADABLE_TAKE")"
t drill-attention-census-unreadable-log-fails-nothing 0 "$(att_fail "$ATT_UNREADABLE_TAKE")"
# ...and the directory goes before the next block seeds a file there. `rm -f`
# cannot remove one, so a setup that assumes a file would silently leave THIS
# state standing and grade the next case against it.
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6b) readable at the census and unreadable by the time the evidence is read
# — a rebuilt box, a mount that went away under the round. The census is taken,
# so there IS something to grade; the bounding row is what grades it, and it
# reds rather than certifying a read that did not happen. `unreadable` and not
# `lost`: a file that will not open cannot be ruled out as the counted
# generation either, and `lost` would be a conclusion the leg did not earn.
att_prev_setup
ATT_BETWEEN='att_unreadable_make'
ATT_UNREADABLE_MID="$(att_drive both drain)"
t drill-attention-census-unreadable-mid-round-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNREADABLE_MID" || true)"
t drill-attention-census-unreadable-mid-round-says-what-it-read 1 \
  "$(grep -c '^  read: the box has a duty.log it could not read' <<<"$ATT_UNREADABLE_MID" || true)"
t drill-attention-census-unreadable-mid-round-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNREADABLE_MID" || true)"
# The census row, and nothing downstream of the slice.
t drill-attention-census-unreadable-mid-round-grades-nothing-after-it 1 \
  "$(att_ok "$ATT_UNREADABLE_MID")"
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6c) the box had NO duty.log at the census, and the one it has now will not
# read. The `fresh` branch is the one path whose read is not vouched for by the
# generation mark — there was no generation to mark — so it is the branch where
# a `cat` hidden behind `2>/dev/null || true` returns an empty slice that looks
# exactly like a box which simply wrote nothing this round.
att_box_conf attention "$ATT_MARK"
rm -rf "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"
ATT_BETWEEN='att_unreadable_make'
ATT_UNREADABLE_FRESH="$(att_drive both drain)"
t drill-attention-census-unreadable-fresh-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNREADABLE_FRESH" || true)"
t drill-attention-census-unreadable-fresh-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNREADABLE_FRESH" || true)"
t drill-attention-census-unreadable-fresh-grades-nothing-after-it 1 \
  "$(att_ok "$ATT_UNREADABLE_FRESH")"
rm -rf "$ATT_BOX_HOME/duty/duty.log"

# (h6d) ...and the other side of that judgement, which is why `unreadable` is
# asked LAST. A drill box reused across passes can carry a duty.log.1 nobody
# can open — a rebuild left it root-owned, a mount went away. It says nothing
# about a generation that has already been identified BY READING IT: `cur`
# matched on both the inode and the counted lines, so this round's lines are
# exactly where the census said they were. A leg that asked "did every read
# succeed?" before "do I know where my lines are?" would stop a sound round
# over a file it never needed.
att_prev_setup
rm -rf "$ATT_BOX_HOME/duty/duty.log.1"
mkdir "$ATT_BOX_HOME/duty/duty.log.1"
ATT_BETWEEN='att_prev_tick'
ATT_UNREADABLE_ROT="$(att_drive both drain)"
t drill-attention-census-unreadable-rotated-file-is-not-this-rounds-problem 0 \
  "$(att_fail "$ATT_UNREADABLE_ROT")"
t drill-attention-census-unreadable-rotated-file-does-not-stop-the-round 0 \
  "$(grep -c '^ASSERT-RC=' <<<"$ATT_UNREADABLE_ROT" || true)"
t drill-attention-census-unreadable-rotated-file-still-grades-both 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_UNREADABLE_ROT" || true)"
rm -rf "$ATT_BOX_HOME/duty/duty.log" "$ATT_BOX_HOME/duty/duty.log.1"

ATT_BOX_HOME=""
ATT_BETWEEN=""

# ...and a box that does not answer the slice read in the shape it was asked
# reds the same way. `slice:` with no generation word is the third state again:
# not "the log was empty", but "nobody read it".
ATT_SLICE=unanswered
ATT_SCOPE="$(printf 'heavy-duty/incubator#468 2026-09-10T21:00:00Z\nheavy-duty/incubator#469 2026-09-10T21:00:01Z\n')"
ATT_UNBOUNDED="$(att_drive both)"
t drill-attention-census-unbounded-slice-fails 1 \
  "$(grep -c "^FAIL attention census: this round's duty.log lines are bounded$" <<<"$ATT_UNBOUNDED" || true)"
t drill-attention-census-unbounded-slice-stops-the-round 1 \
  "$(grep -c '^ASSERT-RC=1$' <<<"$ATT_UNBOUNDED" || true)"
ATT_SLICE=current
# ...and the take half refuses outright when the box will not say WHICH
# generation it counted, for the reason the census itself refuses: a slice
# resolved against nothing would silently be the whole file, every tick.
ATT_LOG_GEN=""
t drill-attention-census-no-log-generation-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_LOG_GEN=111

# (i) THE LABEL IS THE BOX'S, NOT THIS FILE'S (#714, round 5).
#
# duty_attention fetches `labels=$LABEL_ATTENTION` (duty-attention.sh:115), and
# LABEL_ATTENTION is NOT one of the six wire marks load_fleet_conf restores
# over fleet.conf (common/conf.sh:14-24) — so an operator file moves it. A
# census keyed on the literal `attention` then reads an EMPTY set off a board
# that is full: zero demands recorded, nothing asserted, and the leg reports a
# clean bill of health for a filter it never exercised. Same defect as the
# --paginate window and the page boundary, third disguise.
# ...and the wire mark goes the OTHER way, from the SAME read: load_fleet_conf
# restores MARK_PICKUP over fleet.conf, so an override of it must be read and
# then discarded exactly as the loader discards it. One box, both resolutions,
# and this box is real — the two configuration files exist and the read is
# executed against them, so neither direction is pinned by a grep for source
# text and a read that mixed them up is killed on behaviour.
ATT_BOX_HOME="$TMP/att-conf-box"
mkdir -p "$ATT_BOX_HOME/duty"
# The operator moved BOTH names. Only one of them is theirs to move.
att_box_conf attention "$ATT_MARK" needs-human '🔧 not the wire mark'
ATT_LABEL_CONF="needs-human"   # what the endpoint will answer to
ATT_MARK_EXPECT="$ATT_MARK"    # ...and the comment read must still carry the wire mark
: >"$ATT_BOX_HOME/duty/duty.log"
att_conf_tick() {
  printf '%s\n%s\n' "$ATT_ROT_WARN" \
    'SESSION START kind=attention key=host/crew-drill-builder#7 timeout=1800s log=/l holder=x sid=1' \
    >>"$ATT_BOX_HOME/duty/duty.log"
}
ATT_BETWEEN='att_conf_tick'
ATT_RENAMED="$(att_drive both)"
t drill-attention-census-renamed-label-records-the-demands 1 \
  "$(grep -c '^ok attention census: 2 demand(s) parked outside host/crew-drill-builder' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-renamed-label-asserts-them 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] seen and suppressed$' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-wire-mark-ignores-the-operator-file 2 \
  "$(grep -c '^ok attention census: heavy-duty/incubator#46[89] drew no pickup$' <<<"$ATT_RENAMED" || true)"
t drill-attention-census-renamed-label-is-green 0 "$(att_fail "$ATT_RENAMED")"
ATT_BOX_HOME=""
ATT_BETWEEN=""
ATT_MARK_EXPECT=""
ATT_LABEL_CONF="attention"
# A box whose configuration resolves no LABEL_ATTENTION refuses, like the mark.
ATT_LABEL_CONF=""
t drill-attention-census-no-label-refuses 1 \
  "$(grep -c '^TAKE-RC=1$' <<<"$(att_drive take)" || true)"
ATT_LABEL_CONF="attention"

# --- the board vocabulary is the box's, not this file's (#735) ---------------
#
# The sibling of group (i), one layer out. That group proved the attention
# CENSUS asks the endpoint for the box's own effective LABEL_ATTENTION; the
# drill's other half — the mints, the waits, the predicates, the cleanup
# DELETEs and the triage queue pattern — still spelled the shipped English
# names. Two halves of one round disagreeing about where a label name comes
# from, and only one of them saying so.
#
# Every LABEL_* is operator-configurable: load_fleet_conf restores exactly the
# six MARK_* wire values over fleet.conf (shared/lib/common/conf.sh:13-25) and
# not one label is among them. On a fleet whose operator moved a name, a
# fixture minted under the shipped one is a demand the engine never fetches —
# the phase-2 wake spends its 900 seconds and reds on a CORRECT engine — and a
# queue pattern built from shipped names grades the stray assertion against
# labels the session was never asked to use.
#
# THE BOX IS REAL: both configuration files exist under BV_HOME and the shipped
# read is executed against them through a HOME-scoped bash, so a mint and a
# predicate that disagree about which file wins are killed on behaviour rather
# than pinned by a grep for source text. The DEFAULTS are the repository's own
# shared/conf/fleet.defaults.conf, so group (d) asserts the names crew actually
# ships rather than a copy of them that can drift.
BV_HOME="$TMP/bv-box"
BV_TRACE="$TMP/bv-trace"
BV_BOARD="$TMP/bv-board"
BV_NEXT=100

bv_note() { printf '%s\n' "$1" >>"$BV_TRACE"; }

# bv_box_conf [FLEET_CONF_LINE...] — the shipped defaults, plus an operator
# file only when one is asked for. With no argument the box has no fleet.conf,
# which is group (d) and is the configuration every round to date has run on.
bv_box_conf() {
  rm -rf "$BV_HOME"
  mkdir -p "$BV_HOME/duty/conf"
  cp "$ROOT/shared/conf/fleet.defaults.conf" "$BV_HOME/duty/conf/fleet.defaults.conf"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$BV_HOME/duty/conf/fleet.conf"
  : >"$BV_TRACE"
  : >"$BV_BOARD"
}

# A REAL BOX RUNS THE COMMAND IN A FRESH SHELL — `box exec … bash -lc` — so the
# composed read is run rather than eval'd inside this suite, for the reason
# att_bx states at length. Anything else is a box that declines, which is what
# the refusal rows are about.
#
# BV_CRLF=1 makes the box answer in CRLF, which is the transport and not the
# operator: `box exec` hands the guest's stdout back through a channel that may
# translate line endings, which is the only reason the reads strip a CR at all.
# Group (e6) is the pair of rows that keeps that strip as narrow as it is.
BV_CRLF=0
bv_bx() {
  case "$1" in
    *fleet.defaults.conf*)
      if [ "$BV_CRLF" = 1 ]; then
        ( HOME="$BV_HOME"; bash -c "$1" 2>/dev/null ) | sed 's/$/\r/'
      else
        ( HOME="$BV_HOME"; bash -c "$1" 2>/dev/null )
      fi ;;
    *) return 1 ;;
  esac
}

# The board, as a table of `<number> <labels-csv>` lines. Appended rather than
# rewritten, and read newest-last, so a label added after a mint is visible to
# the next read without this fixture needing an in-place edit.
bv_board_put()    { printf '%s %s\n' "$1" "$2" >>"$BV_BOARD"; }
bv_board_labels() { awk -v n="$1" '$1 == n { v = $2 } END { print v }' "$BV_BOARD"; }

# `gh --jq` MARSHALS the value: a filter yielding null prints NOTHING, where
# real jq prints "null". Modelled rather than approximated, because it is why no
# predicate under test reads a boolean back through `--jq` — one that did would
# see "" for both answers — and because the `.number` and `join(" ")` reads that
# DO go through it would otherwise pass here on output a drill never produces.
# A read with no filter hands back the whole issue JSON, which is what the two
# `jq -e --arg` predicates grade.
bv_emit() {
  local json="$1" filter="${2:-}"
  if [ -z "$filter" ]; then printf '%s\n' "$json"; return 0; fi
  jq -r "$filter" <<<"$json" 2>/dev/null | sed '/^null$/d'
}

bv_gh() {
  local url="" method=GET filter="" field name="" color="" labels="" num prev
  while [ "$#" -gt 0 ]; do
    case "$1" in
      api) shift ;;
      -X) method="$2"; shift 2 ;;
      --jq) filter="$2"; shift 2 ;;
      --paginate) shift ;;
      -f)
        field="$2"; shift 2
        case "$field" in
          'labels[]='*) labels="${labels:+$labels,}${field#labels[]=}" ;;
          name=*)  name="${field#name=}" ;;
          color=*) color="${field#color=}" ;;
        esac ;;
      *) url="$1"; shift ;;
    esac
  done
  # Traced by URL, not by field: the label cleanup DELETEs is in the PATH, so a
  # `-f`-only trace cannot see which name the leg is disarming.
  case "$method:$url" in
    DELETE:*) bv_note "delete:$url"; return 0 ;;
    PUT:*)    return 0 ;;
  esac
  case "$url" in
    */labels)
      if [ -n "$name" ]; then
        # The vocabulary mint. Colour traced beside the name, because D3 says
        # only the name side moves and a patch that resolved the colour too
        # would otherwise read green.
        bv_note "mint-label:$name:$color"
      else
        num="${url%/labels}"; num="${num##*/}"
        prev="$(bv_board_labels "$num")"
        bv_board_put "$num" "${prev:+$prev,}$labels"
        bv_note "add-label:$num:$labels"
      fi ;;
    */issues)
      num="$BV_NEXT"; BV_NEXT=$((BV_NEXT + 1))
      bv_board_put "$num" "$labels"
      bv_note "mint:$num:$labels"
      [ "$filter" != .number ] || printf '%s\n' "$num" ;;
    # Traced apart from the issue mints: a pull request is created carrying no
    # labels and flagged afterwards through the add endpoint, so folding it in
    # would put an empty row in the middle of the fixture-label sequence.
    */pulls)
      num="$BV_NEXT"; BV_NEXT=$((BV_NEXT + 1))
      bv_board_put "$num" ""
      bv_note "mint-pr:$num"
      [ "$filter" != .number ] || printf '%s\n' "$num" ;;
    */git/ref/heads/*)
      bv_emit '{"object":{"sha":"1111111111111111111111111111111111111111"}}' "$filter" ;;
    */git/refs) ;;
    */issues/*)
      num="${url##*/}"
      case "$num" in ''|*[!0-9]*) return 1 ;; esac
      bv_emit "$(jq -nc --arg l "$(bv_board_labels "$num")" \
        '{labels: ($l | split(",") | map(select(length > 0) | {name: .}))}')" "$filter" ;;
    *) return 1 ;;
  esac
  return 0
}

# bv_drive SNIPPET — source the three legs, resolve the board vocabulary off
# the fixture box, then run the snippet against it. Everything the snippet
# touches is subshell-local, so a drive's result is its stdout and the files it
# wrote. A read that refuses prints LOAD-RC and runs nothing, which is the
# refusal rehearsal.sh turns into its exit-1 above the first mint.
# shellcheck disable=SC2317  # the stubs are reached only through the legs, which shellcheck cannot follow
bv_drive() {
  (
    # shellcheck source=drill/rehearsal-fixtures.sh
    . "$ROOT/drill/rehearsal-fixtures.sh"
    # shellcheck source=drill/rehearsal-attention.sh
    . "$ROOT/drill/rehearsal-attention.sh"
    # shellcheck source=drill/rehearsal-attention-audit.sh
    . "$ROOT/drill/rehearsal-attention-audit.sh"
    bx()   { bv_bx "$1"; }
    gh()   { bv_gh "$@"; }
    ok()   { echo "ok $1"; }
    fail() { echo "FAIL $1"; }
    rehearsal_load_installed_board_labels || {
      echo "LOAD-RC=$?"
      echo "REASON=$REHEARSAL_BOARD_LABEL_REASON"
      exit 0
    }
    eval "$1"
  )
}

# The phase-2 fixture path, in the drill's own order: the vocabulary, the
# attention demand, the builder's ready issue,
# the attention leg's claimed+flagged demand, the audit leg's two malformed
# shapes, then both disarming cleanups. Every mint and every DELETE in one
# trace, so a site left literal is visible as a wrong name rather than as a
# missing row somewhere else.
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_PHASE2='
  rehearsal_mint_board_vocabulary owner/repo
  inum="$(rehearsal_mint_attention_demand owner/repo box-identity t b)"
  rehearsal_mint_builder_ready_fixture owner/repo t b >/dev/null
  rehearsal_attention_file_fixture owner/repo box-identity t b
  rehearsal_attention_audit_file_fixtures owner/repo stamp
  rehearsal_attention_close_fixture owner/repo "$inum"
  rehearsal_attention_cleanup
  rehearsal_attention_audit_clear_flags
'
bv_minted()  { grep -c "^mint:[0-9]*:$1\$" "$BV_TRACE" || true; }
bv_vocab()   { grep '^mint-label:' "$BV_TRACE" | sed 's/^mint-label://' | paste -sd' ' -; }
bv_mints()   { grep '^mint:' "$BV_TRACE" | sed 's/^mint:[0-9]*://' | paste -sd' ' -; }
bv_deletes() { grep '^delete:' "$BV_TRACE" | sed 's|^delete:.*/labels/||' | sort -u | paste -sd' ' -; }

# (a) THE OPERATOR MOVED TWO NAMES, and every mint asks for the moved one.
#
# LABEL_ATTENTION and LABEL_READY, the two the spec names: the first is what
# duty_attention fetches, the second is what the builder's queue keys on, and
# between them they cover the role-independent half and both role blocks.
bv_box_conf 'LABEL_ATTENTION="needs-human"' 'LABEL_READY="queued"'
# Driven for its TRACE, not its rows: every assertion below reads the requests
# the path made, which is the only place a mint's label name is observable.
bv_drive "$BV_PHASE2" >/dev/null
t drill-board-vocab-moved-mint-names 1 \
  "$(grep -c '^needs-human:d93f0b needs-triage:fbca04 queued:0e8a16 claimed:1d76db blocked:b60205 epic:5319e7$' <<<"$(bv_vocab)" || true)"
# ...and the FIXTURES, in order: the attention demand, the ready issue, the
# claimed+flagged demand, the audit's unassigned issue, its PR.
t drill-board-vocab-moved-fixture-labels 1 \
  "$(grep -c '^needs-human queued claimed,needs-human needs-human,blocked$' <<<"$(bv_mints)" || true)"
t drill-board-vocab-moved-attention-demand 1 "$(bv_minted needs-human)"
t drill-board-vocab-moved-ready-fixture 1 "$(bv_minted queued)"
# The audit leg labels its PR through the add endpoint, not at creation.
t drill-board-vocab-moved-pr-flag 1 \
  "$(grep -c '^add-label:[0-9]*:needs-human$' "$BV_TRACE" || true)"
# ...and every disarming DELETE names the label the leg actually SET. A cleanup
# spelling `attention` here 404s quietly and leaves the board armed.
t drill-board-vocab-moved-cleanup-deletes 1 \
  "$(grep -c '^needs-human$' <<<"$(bv_deletes)" || true)"
# Not one request in the whole path spells either shipped name. Neither string
# is a substring of any name this board resolves — needs-human, needs-triage,
# queued, claimed, blocked, epic — so a bare match is the assertion
# and needs no word boundary to be exact.
t drill-board-vocab-moved-mints-no-shipped-name 0 \
  "$(grep -cE 'attention|ready' "$BV_TRACE" || true)"

# (b) EVERY WAIT AND PREDICATE MATCHES THE MOVED NAME. Each is driven twice:
# once against a board carrying the moved name and once against a board
# carrying only the shipped one. A predicate still spelling `attention` or
# `ready` answers both the same way, which is the shape that reds here.
#
# The JSON the two swap reads are graded on lives out here, in variables the
# drive's subshell inherits: a `'`-quoted snippet cannot carry a `'` of its own
# and a here-string built inside it would be this fixture writing the board
# rather than reading it.
# shellcheck disable=SC2034  # read inside bv_drive's eval'd snippet
BV_JSON_MOVED='{"labels":[{"name":"queued"}]}'
# shellcheck disable=SC2034  # read inside bv_drive's eval'd snippet
BV_JSON_SHIPPED='{"labels":[{"name":"ready"}]}'
# shellcheck disable=SC2034  # read inside bv_drive's eval'd snippet
BV_JSON_HALF='{"labels":[{"name":"queued"},{"name":"claimed"}]}'
bv_board_put 200 needs-human           # still flagged under the moved name
bv_board_put 201 attention             # flagged under a name nobody moved to
bv_board_put 202 queued                # the builder's issue, not yet claimed
bv_board_put 203 ready                 # ...the shipped name, on a moved board
bv_board_put 205 queued,needs-human    # ruled into the moved queue
bv_board_put 206 ready                 # ruled into the SHIPPED queue name
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_PRED="$(bv_drive '
  rehearsal_attention_flag_cleared owner/repo 200 && echo cleared-200 || echo armed-200
  rehearsal_attention_flag_cleared owner/repo 201 && echo cleared-201 || echo armed-201
  rehearsal_builder_left_the_queue owner/repo 202 && echo off-202 || echo on-202
  rehearsal_builder_left_the_queue owner/repo 203 && echo off-203 || echo on-203
  rehearsal_load_installed_queue_labels
  echo "QUEUESET=$(paste -sd, - <<<"$REHEARSAL_QUEUE_LABELS")"
  rehearsal_stray_left_the_queue owner/repo 205 && echo ruled-205 || echo stray-205
  rehearsal_stray_left_the_queue owner/repo 206 && echo ruled-206 || echo stray-206
  rehearsal_attention_is_ready_from_json "$BV_JSON_MOVED" >/dev/null \
    && echo swapped-moved || echo unswapped-moved
  rehearsal_attention_is_ready_from_json "$BV_JSON_SHIPPED" >/dev/null \
    && echo swapped-shipped || echo unswapped-shipped
  rehearsal_attention_is_ready_from_json "$BV_JSON_HALF" >/dev/null \
    && echo swapped-half || echo unswapped-half
')"
t drill-board-vocab-flag-armed-under-moved-name 1 "$(grep -cx armed-200 <<<"$BV_PRED" || true)"
t drill-board-vocab-flag-clear-ignores-shipped-name 1 "$(grep -cx cleared-201 <<<"$BV_PRED" || true)"
t drill-board-vocab-queue-holds-under-moved-name 1 "$(grep -cx on-202 <<<"$BV_PRED" || true)"
t drill-board-vocab-queue-off-ignores-shipped-name 1 "$(grep -cx off-203 <<<"$BV_PRED" || true)"
t drill-board-vocab-ready-swap-reads-moved-name 1 "$(grep -cx swapped-moved <<<"$BV_PRED" || true)"
t drill-board-vocab-ready-swap-ignores-shipped-name 1 "$(grep -cx unswapped-shipped <<<"$BV_PRED" || true)"
# ...and the swap is a SWAP: the moved ready set with claimed still standing is
# not a release, which is the half that reads the claimed name.
t drill-board-vocab-ready-swap-needs-claimed-gone 1 "$(grep -cx unswapped-half <<<"$BV_PRED" || true)"

# The other name a fixture sends, on a board that moved IT: `claimed` is half
# of both the attention leg's demand and the swap above. Moving LABEL_ATTENTION
# and LABEL_READY leaves that site passing under the shipped name by
# coincidence, so it gets a board of its own.
bv_box_conf 'LABEL_CLAIMED="wip"'
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
bv_drive '
  rehearsal_attention_file_fixture owner/repo box-identity t b
' >/dev/null
t drill-board-vocab-moved-claimed-mint 1 "$(bv_minted wip,attention)"

# (c) THE RESOLVED QUEUE SET CARRIES THE MOVED `ready`, and the stray assertion
# grades against it: an issue ruled into `queued` has left the unlabelled
# queue, and one carrying the shipped `ready` on this board has not.
t drill-board-vocab-queue-labels-resolve-six 1 \
  "$(grep -c '^ok triage: installed queue-label set resolves five names$' <<<"$BV_PRED" || true)"
t drill-board-vocab-queue-set-carries-moved-ready 1 \
  "$(grep -cxF 'QUEUESET=blocked,claimed,epic,needs-triage,queued' <<<"$BV_PRED" || true)"
t drill-board-vocab-stray-ruled-into-moved-queue 1 "$(grep -cx ruled-205 <<<"$BV_PRED" || true)"
t drill-board-vocab-stray-shipped-name-is-still-stray 1 "$(grep -cx stray-206 <<<"$BV_PRED" || true)"

# ...and a fleet.conf that COLLIDES two names onto one string resolves five
# through `sort -u` and must red exactly as it does today (D2). The row text is
# the same row text.
bv_box_conf 'LABEL_READY="blocked"'
BV_COLLIDED="$(bv_drive 'rehearsal_load_installed_queue_labels')"
t drill-board-vocab-collided-queue-set-reds 1 \
  "$(grep -c '^FAIL triage: installed queue-label set resolves five names$' <<<"$BV_COLLIDED" || true)"

# (d) A BOX WITH NO fleet.conf MINTS AND MATCHES THE SHIPPED NAMES, exactly as
# today. This is the configuration the defect is invisible under — every round
# to date ran on it — so it is here as the non-regression half and never as
# evidence for the rest.
bv_box_conf
bv_drive "$BV_PHASE2" >/dev/null   # driven for its trace, like the moved board
t drill-board-vocab-shipped-mint-names 1 \
  "$(grep -c '^attention:d93f0b needs-triage:fbca04 ready:0e8a16 claimed:1d76db blocked:b60205 epic:5319e7$' <<<"$(bv_vocab)" || true)"
t drill-board-vocab-shipped-fixture-labels 1 \
  "$(grep -c '^attention ready claimed,attention attention,blocked$' <<<"$(bv_mints)" || true)"
t drill-board-vocab-shipped-cleanup-deletes 1 \
  "$(grep -c '^attention$' <<<"$(bv_deletes)" || true)"
bv_board_put 300 ready
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_SHIPPED_PRED="$(bv_drive '
  rehearsal_builder_left_the_queue owner/repo 300 && echo off-300 || echo on-300
  rehearsal_load_installed_queue_labels >/dev/null
  echo "QUEUESET=$(paste -sd, - <<<"$REHEARSAL_QUEUE_LABELS")"
')"
t drill-board-vocab-shipped-queue-holds 1 "$(grep -cx on-300 <<<"$BV_SHIPPED_PRED" || true)"
t drill-board-vocab-shipped-queue-set 1 \
  "$(grep -cxF 'QUEUESET=blocked,claimed,epic,needs-triage,ready' <<<"$BV_SHIPPED_PRED" || true)"

# ...and a box whose configuration resolves no usable name REFUSES, like the
# census's own read and for the same reason: a vocabulary half-minted under
# names nothing resolved is a fixture fault every row below would be blamed
# for. Both shapes — an empty name and one carrying whitespace GitHub would
# accept but every `grep -qx` downstream would have to agree about.
bv_box_conf 'LABEL_EPIC=""'
t drill-board-vocab-empty-name-refuses 1 \
  "$(grep -c '^LOAD-RC=1$' <<<"$(bv_drive 'echo unreachable')" || true)"
bv_box_conf 'LABEL_CLAIMED="in progress"'
t drill-board-vocab-whitespace-name-refuses 1 \
  "$(grep -c '^LOAD-RC=1$' <<<"$(bv_drive 'echo unreachable')" || true)"
# The refusal NAMES the label it read, so a red is diagnosable off the console
# rather than from the source of the read.
t drill-board-vocab-refusal-names-the-label 1 \
  "$(grep -c '^REASON=.*LABEL_CLAIMED (whitespace)$' <<<"$(bv_drive 'echo unreachable')" || true)"
# A box that will not answer at all is the third state, and it refuses too
# rather than minting a board of empty names.
BV_HOME="$TMP/bv-no-such-box"
t drill-board-vocab-unreadable-box-refuses 1 \
  "$(grep -c '^LOAD-RC=1$' <<<"$(bv_drive 'echo unreachable')" || true)"
BV_HOME="$TMP/bv-box"

# (e) THE RESOLVED NAME IS DATA, never a pattern and never jq source.
#
# Groups (a)-(d) move each name onto another plain English word, which is the
# realistic rename and the one the spec names. It is not the only one an
# operator can write: GitHub accepts `.`, `+`, `|` and `"` in a label name, and
# every one of them means something to a regular expression or to a jq filter. A
# predicate that interpolates a resolved name into either grades the operator's
# DATA as CODE — and then answers about a board it never matched, which is this
# issue's own defect pointed the other way rather than a separate one.
#
# So each shape is driven against the near-match it used to accept. The needles
# here are `grep -cxF`, because they carry metacharacters themselves.

# (e1) `.` is an ERE wildcard and `"` ends a jq string literal. One board
# carries both, plus a `+` in the third name a fixture sends.
bv_box_conf 'LABEL_READY="ready.v2"' "LABEL_ATTENTION='needs\"human'" "LABEL_CLAIMED='claimed+1'"
bv_drive "$BV_PHASE2" >/dev/null
t drill-board-vocab-meta-mint-names 1 \
  "$(grep -cxF 'needs"human:d93f0b needs-triage:fbca04 ready.v2:0e8a16 claimed+1:1d76db blocked:b60205 epic:5319e7' <<<"$(bv_vocab)" || true)"
t drill-board-vocab-meta-fixture-labels 1 \
  "$(grep -cxF 'needs"human ready.v2 claimed+1,needs"human needs"human,blocked' <<<"$(bv_mints)" || true)"
bv_board_put 400 readyXv2        # the near-match the ERE wildcard used to accept
bv_board_put 401 ready.v2        # ...and the name the box actually resolved
bv_board_put 402 'needs"human'   # flagged, under a name that is not a jq string
bv_board_put 403 attention       # ...and the shipped name, on this board
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_META="$(bv_drive '
  rehearsal_load_installed_queue_labels >/dev/null
  echo "QUEUESET=$(paste -sd, - <<<"$REHEARSAL_QUEUE_LABELS")"
  rehearsal_stray_left_the_queue owner/repo 400 && echo ruled-400 || echo stray-400
  rehearsal_stray_left_the_queue owner/repo 401 && echo ruled-401 || echo stray-401
  rehearsal_attention_flag_cleared owner/repo 402 && echo cleared-402 || echo armed-402
  rehearsal_attention_flag_cleared owner/repo 403 && echo cleared-403 || echo armed-403
  rehearsal_builder_left_the_queue owner/repo 400 && echo off-400 || echo on-400
  rehearsal_builder_left_the_queue owner/repo 401 && echo off-401 || echo on-401
')"
t drill-board-vocab-meta-queue-set-carries-the-dotted-ready 1 \
  "$(grep -cxF 'QUEUESET=blocked,claimed+1,epic,needs-triage,ready.v2' <<<"$BV_META" || true)"
# THE ROW THE WILDCARD FAILS: `readyXv2` is not a label this board has, so the
# issue carrying it has not left the unlabelled queue. Joined into an ERE, it
# did.
t drill-board-vocab-meta-near-match-is-still-stray 1 "$(grep -cx stray-400 <<<"$BV_META" || true)"
t drill-board-vocab-meta-exact-name-is-ruled 1 "$(grep -cx ruled-401 <<<"$BV_META" || true)"
# ...and the jq half: the filter has to COMPILE against a quote-bearing name
# before it can grade anything. Interpolated, it does not, and the predicate
# then answers "still armed" about every board — including this one, which is
# why the cleared row is the one that dies and the armed row is not.
t drill-board-vocab-meta-quote-name-armed 1 "$(grep -cx armed-402 <<<"$BV_META" || true)"
t drill-board-vocab-meta-quote-name-clear-ignores-shipped 1 \
  "$(grep -cx cleared-403 <<<"$BV_META" || true)"
t drill-board-vocab-meta-builder-queue-holds 1 "$(grep -cx on-401 <<<"$BV_META" || true)"
t drill-board-vocab-meta-builder-near-match-left 1 "$(grep -cx off-400 <<<"$BV_META" || true)"

# (e2) `|` is the join character itself, so a name carrying one re-partitions
# the alternation and each fragment becomes a queue name the board does not
# have. The same value carries the `"` that breaks the builder read's filter, so
# one board drives both predicates against it.
bv_box_conf "LABEL_READY='queued|ready\"x'"
bv_board_put 410 queued            # a FRAGMENT of the resolved name, not a name
bv_board_put 411 'queued|ready"x'  # ...the whole resolved name
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_META_ALT="$(bv_drive '
  rehearsal_load_installed_queue_labels
  rehearsal_stray_left_the_queue owner/repo 410 && echo ruled-410 || echo stray-410
  rehearsal_stray_left_the_queue owner/repo 411 && echo ruled-411 || echo stray-411
  rehearsal_builder_left_the_queue owner/repo 410 && echo off-410 || echo on-410
  rehearsal_builder_left_the_queue owner/repo 411 && echo off-411 || echo on-411
')"
# Six names still resolve: a `|` inside one of them is one name, not two.
t drill-board-vocab-meta-alternation-resolves-six 1 \
  "$(grep -c '^ok triage: installed queue-label set resolves five names$' <<<"$BV_META_ALT" || true)"
t drill-board-vocab-meta-alternation-fragment-is-stray 1 \
  "$(grep -cx stray-410 <<<"$BV_META_ALT" || true)"
t drill-board-vocab-meta-alternation-whole-name-is-ruled 1 \
  "$(grep -cx ruled-411 <<<"$BV_META_ALT" || true)"
t drill-board-vocab-meta-quote-ready-off-the-queue 1 "$(grep -cx off-410 <<<"$BV_META_ALT" || true)"
t drill-board-vocab-meta-quote-ready-holds 1 "$(grep -cx on-411 <<<"$BV_META_ALT" || true)"

# (e3) A NAME CARRYING A NEWLINE is the shape emptiness cannot catch. Eight
# emitted lines fill seven slots, so every slot below it is one place out and
# the LAST value is dropped — leaving all seven non-empty, which is the one
# state the whitespace guard never sees. The box's terminator is what catches
# it, and the refusal says which shape it was. Two fleet.conf LINES, because
# that is how a newline gets into a sourced value.
bv_box_conf 'LABEL_READY="que' 'ued"'
t drill-board-vocab-newline-name-refuses 1 \
  "$(grep -c '^LOAD-RC=1$' <<<"$(bv_drive 'echo unreachable')" || true)"
t drill-board-vocab-newline-refusal-names-the-shift 1 \
  "$(grep -c '^REASON=.*seven names in seven lines.*one place out$' <<<"$(bv_drive 'echo unreachable')" || true)"

# (e4) AND EVERY PREDICATE GRADED ON A NAME GUARDS AN UNRESOLVED ONE, rc 2.
# `index("") == null` is true, so a predicate holding an empty name would report
# the flag cleared, the queue left and the swap done — green on every correct
# engine, for the reason the swap read's own comment gives. Unreachable in the
# shipped tree, where the read refuses above the first mint and every caller is
# below it; driven here because that is the only thing that makes it stay true.
bv_box_conf
bv_board_put 420 attention
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_UNRESOLVED="$(bv_drive '
  REHEARSAL_LABEL_ATTENTION=""
  REHEARSAL_LABEL_READY=""
  REHEARSAL_LABEL_CLAIMED=""
  rehearsal_attention_flag_cleared owner/repo 420; echo "flag-rc=$?"
  rehearsal_builder_left_the_queue owner/repo 420; echo "queue-rc=$?"
  swap_out="$(rehearsal_attention_is_ready_from_json "$BV_JSON_MOVED")"; echo "swap-rc=$?"
  echo "swap-out=$swap_out"
')"
t drill-board-vocab-unresolved-flag-returns-2 1 "$(grep -cx 'flag-rc=2' <<<"$BV_UNRESOLVED" || true)"
t drill-board-vocab-unresolved-queue-returns-2 1 "$(grep -cx 'queue-rc=2' <<<"$BV_UNRESOLVED" || true)"
t drill-board-vocab-unresolved-swap-returns-2 1 "$(grep -cx 'swap-rc=2' <<<"$BV_UNRESOLVED" || true)"
t drill-board-vocab-unresolved-swap-names-the-gap 1 \
  "$(grep -cxF 'swap-out=<no effective ready/claimed name resolved off the box>' <<<"$BV_UNRESOLVED" || true)"

# (e5) A NAME BEGINNING WITH `-` IS STILL DATA, and the resolved set is an
# OPERAND. Groups (e1) and (e2) cover the name read as a PATTERN; this one
# covers it read as an OPTION, which is the same class one layer further out and
# the one the loader cannot help with — `-alert` is non-empty and
# whitespace-free, so it is a name the read must accept.
#
# A leading hyphen sorts the name to the front of the set, so the operand
# `grep -qxF` receives begins with `-`. WHICH FAILURE FOLLOWS DEPENDS ONLY ON
# THE LETTERS, so both are driven: (e5a) is the silent one and (e5b) is the loud
# one.
#
# THE COLLATION IS THE FIXTURE'S PREMISE, AND IS ASSERTED RATHER THAN ASSUMED.
# `sort -u` runs host-side in the host's locale, and a UTF-8 collation ignores
# punctuation at the first level: `-queued` collates as `queued` and lands LAST,
# where under LC_ALL=C it lands first. A row written on `-queued` would
# therefore pass on one host for the wrong reason and catch the defect on
# another. `-alert` and `-active` sort first under BOTH — `-` before letters in
# C, `alert`/`active` before `blocked` in a UTF-8 locale — and the
# `…-sorts-first` rows below pin exactly that, so a collation that ever moves
# them reds with the reason rather than quietly disarming the group.

# (e5a) THE SILENT ONE. `-alert` parses as the bundle `-a -l -e`, and `-e` takes
# the REST of the operand — newlines and all — as its pattern argument, so the
# patterns actually compared are `rt`, `blocked`, `claimed`, `epic`,
# `needs-triage`. The exact name reads STRAY and the fragment `rt`
# reads RULED, on a board that carries neither.
bv_box_conf 'LABEL_READY="-alert"'
bv_drive "$BV_PHASE2" >/dev/null
t drill-board-vocab-dash-mint-names 1 \
  "$(grep -cxF 'attention:d93f0b needs-triage:fbca04 -alert:0e8a16 claimed:1d76db blocked:b60205 epic:5319e7' <<<"$(bv_vocab)" || true)"
t drill-board-vocab-dash-fixture-labels 1 \
  "$(grep -cxF 'attention -alert claimed,attention attention,blocked' <<<"$(bv_mints)" || true)"
bv_board_put 430 '-alert'  # the exact name the box resolved
bv_board_put 431 rt        # the `-e` argument fragment, which is no name at all
bv_board_put 432 alert     # the dash-less near-miss
bv_board_put 433 blocked   # ...and an ordinary name, unrelated to the hyphen
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_DASH="$(bv_drive '
  rehearsal_load_installed_queue_labels >/dev/null
  echo "FIRST=$(head -1 <<<"$REHEARSAL_QUEUE_LABELS")"
  echo "QUEUESET=$(paste -sd, - <<<"$REHEARSAL_QUEUE_LABELS")"
  rehearsal_stray_left_the_queue owner/repo 430 && echo ruled-430 || echo stray-430
  rehearsal_stray_left_the_queue owner/repo 431 && echo ruled-431 || echo stray-431
  rehearsal_stray_left_the_queue owner/repo 432 && echo ruled-432 || echo stray-432
  rehearsal_stray_left_the_queue owner/repo 433 && echo ruled-433 || echo stray-433
  rehearsal_builder_left_the_queue owner/repo 430 && echo off-430 || echo on-430
  rehearsal_builder_left_the_queue owner/repo 432 && echo off-432 || echo on-432
')"
t drill-board-vocab-dash-name-sorts-first 1 "$(grep -c '^FIRST=-' <<<"$BV_DASH" || true)"
t drill-board-vocab-dash-queue-set-carries-the-hyphen 1 \
  "$(grep -cxF 'QUEUESET=-alert,blocked,claimed,epic,needs-triage' <<<"$BV_DASH" || true)"
# THE TWO ROWS THE OPTION BUNDLE FAILS.
t drill-board-vocab-dash-exact-name-is-ruled 1 "$(grep -cx ruled-430 <<<"$BV_DASH" || true)"
t drill-board-vocab-dash-fragment-is-stray 1 "$(grep -cx stray-431 <<<"$BV_DASH" || true)"
# ...and the two that hold either way, so the fix is shown not to have bought
# them by matching more loosely: the dash-less near-miss is not this board's
# `ready`, and an ordinary queue name is still ruled.
t drill-board-vocab-dash-near-miss-is-stray 1 "$(grep -cx stray-432 <<<"$BV_DASH" || true)"
t drill-board-vocab-dash-ordinary-name-is-ruled 1 "$(grep -cx ruled-433 <<<"$BV_DASH" || true)"
# The builder read takes the same name through `jq --arg`, where an operand
# never forms. Driven to show the two halves agree about this board.
t drill-board-vocab-dash-builder-queue-holds 1 "$(grep -cx on-430 <<<"$BV_DASH" || true)"
t drill-board-vocab-dash-builder-near-miss-left 1 "$(grep -cx off-432 <<<"$BV_DASH" || true)"

# (e5b) THE LOUD ONE. `-active` reaches `-t`, which is no grep option at all, so
# grep exits 2 with a usage message and EVERY issue reads stray — including one
# carrying a name the board plainly has. stderr is dropped on this drive alone,
# because the pre-fix shape writes grep's usage text to it and a mutation probe
# should print its rows and not a manual page.
bv_box_conf 'LABEL_READY="-active"'
bv_board_put 440 '-active'
bv_board_put 441 blocked
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_DASH_LOUD="$(bv_drive '
  rehearsal_load_installed_queue_labels >/dev/null
  echo "FIRST=$(head -1 <<<"$REHEARSAL_QUEUE_LABELS")"
  rehearsal_stray_left_the_queue owner/repo 440 && echo ruled-440 || echo stray-440
  rehearsal_stray_left_the_queue owner/repo 441 && echo ruled-441 || echo stray-441
' 2>/dev/null)"
t drill-board-vocab-dash-invalid-option-name-sorts-first 1 \
  "$(grep -c '^FIRST=-' <<<"$BV_DASH_LOUD" || true)"
t drill-board-vocab-dash-invalid-option-exact-is-ruled 1 \
  "$(grep -cx ruled-440 <<<"$BV_DASH_LOUD" || true)"
t drill-board-vocab-dash-invalid-option-spares-the-rest 1 \
  "$(grep -cx ruled-441 <<<"$BV_DASH_LOUD" || true)"

# (e6) THE CR THE READ REPAIRS IS THE TRANSPORT'S, AND ONLY THAT ONE. The box's
# stdout comes back through a channel that may translate line endings, so a CR
# at END OF LINE is the transport and is stripped. A CR anywhere else is a byte
# inside the operator's value, and the read has no business removing it: it is
# exactly the name no `-f "labels[]=…"` or jq needle downstream could agree
# about, which is the whitespace guard's own reason for existing. Stripped
# wholesale, the guard never sees it and the board mints under a name the
# operator did not write.
BV_CRLF=1
bv_box_conf 'LABEL_ATTENTION="needs-human"' 'LABEL_READY="queued"'
bv_drive "$BV_PHASE2" >/dev/null
t drill-board-vocab-crlf-box-mints-the-moved-names 1 \
  "$(grep -cxF 'needs-human:d93f0b needs-triage:fbca04 queued:0e8a16 claimed:1d76db blocked:b60205 epic:5319e7' <<<"$(bv_vocab)" || true)"
# The queue set too, which had no strip at all before this round: it was only
# counted, and five names each ending in CR count as five.
# shellcheck disable=SC2016  # the snippet is eval'd by bv_drive, which is where it expands
BV_CRLF_SET="$(bv_drive '
  rehearsal_load_installed_queue_labels
  echo "QUEUESET=$(paste -sd, - <<<"$REHEARSAL_QUEUE_LABELS")"
')"
t drill-board-vocab-crlf-queue-set-resolves-six 1 \
  "$(grep -c '^ok triage: installed queue-label set resolves five names$' <<<"$BV_CRLF_SET" || true)"
t drill-board-vocab-crlf-queue-set-carries-no-carriage-return 1 \
  "$(grep -cxF 'QUEUESET=blocked,claimed,epic,needs-triage,queued' <<<"$BV_CRLF_SET" || true)"
# ...and the other side of the line: an INTERIOR CR is the operator's, survives
# the strip, and is refused as whitespace like any other. A literal CR inside
# the quoted value, because that is how one gets into a sourced string.
BV_CRLF=0
bv_box_conf "$(printf 'LABEL_READY="que\rued"')"
t drill-board-vocab-interior-cr-refuses 1 \
  "$(grep -c '^LOAD-RC=1$' <<<"$(bv_drive 'echo unreachable')" || true)"
t drill-board-vocab-interior-cr-refusal-names-the-name 1 \
  "$(grep -c '^REASON=.*LABEL_READY (whitespace)' <<<"$(bv_drive 'echo unreachable')" || true)"

# --- the breaker leg grades only what it CONFIRMED (#724) --------------------
#
# The 0.1.3-rc2 round failed seven breaker assertions on `triage` and six on
# `reviewer`, and passed outright on `builder` — same engine, same threshold,
# same lane, three roles. What varied was not the engine but whether the tick
# the leg fired ever reached the lane, and the leg had no way to tell the
# difference. Both directions were live: two roles red on the engine's behalf,
# and an absence that happened to look right would have read green.
#
# The two shapes are staged here rather than on a box, because a defect whose
# trigger is "an earlier leg closed the fixture" or "the previous run still
# holds the lock" cannot be scheduled on a real host — the rc2 round produced
# one of each by accident, five weeks apart from the code that grades them.
#
# THE BOX IS A REAL FILE. duty.log is written by the tick stub and read by the
# shipped `tail -n +$first` through a HOME-scoped bash, so the slice boundary
# is exercised rather than handed to the predicate ready-made: a leg that lost
# track of `first` would grade a previous tick's lines and pass a fixture that
# only ever returned the slice it was asked for.
BRK_HOME="$TMP/brk-box"
BRK_TRACE="$TMP/brk-trace"
BRK_REASON="$TMP/brk-reason"
BRK_TS="2026-09-12T15:54:29Z"
BRK_KIND=attention
BRK_LABEL=attention
BRK_THRESHOLD=3
BRK_TRIES=3
BRK_SLICES=(SILENT)
BRK_ISSUE_STATE=open
BRK_ISSUE_LABELS=""
BRK_ISSUE_READABLE=1
BRK_ISSUE_JSON=""
BRK_REOPEN_WORKS=1
BRK_LABEL_STICKS=1
BRK_RECOVERY_CLEARS=1
BRK_WC_READABLE=1
BRK_LOG_READABLE=1
BRK_TICK_RC=0
BRK_TICK_N=0
BRK_REOPENS=0

brk_note() { printf '%s\n' "$1" >>"$BRK_TRACE"; }

# The SESSION lines the JOB writes inside a tick, without tick.sh's own framing.
brk_session_lines() {
  case "$1" in
    TERMINAL)
      printf '%s SESSION START kind=%s key=owner/repo#1 timeout=5s log=/tmp/t\n' \
        "$BRK_TS" "$BRK_KIND"
      printf '%s SESSION END kind=%s key=owner/repo#1 rc=1 dur=1s outcome=TERMINAL acted=no\n' \
        "$BRK_TS" "$BRK_KIND" ;;
    TRIP)
      brk_session_lines TERMINAL
      printf '%s WARN: session breaker: kind=%s tripped after %s consecutive terminal failures\n' \
        "$BRK_TS" "$BRK_KIND" "$BRK_THRESHOLD" ;;
    SUPPRESSED)
      printf '%s SESSION SKIP kind=%s key=owner/repo#1 reason=terminal-breaker count=%s\n' \
        "$BRK_TS" "$BRK_KIND" "$BRK_THRESHOLD" ;;
    RECOVERED)
      printf '%s session breaker: kind=%s recovered; dispatch resumed\n' \
        "$BRK_TS" "$BRK_KIND"
      printf '%s SESSION START kind=%s key=owner/repo#1 timeout=5s log=/tmp/r\n' \
        "$BRK_TS" "$BRK_KIND" ;;
  esac
}

# One tick's worth of duty.log, by name — in the shapes tick.sh's evidence
# contract guarantees (shared/bin/tick.sh:4-8), because that contract is what
# the leg now reads. A tick that RAN is framed by `duty run start` / `duty run
# end` (duty.sh:61,234); the three shapes that are NOT evidence each say so in
# their own way:
#
#   LOCK    the lock refused it     — retried within the bound
#   FAILED  the job exited non-zero — a partial run, not a lane reading
#   SILENT  nothing was written     — the invocation never landed
#
# SILENT is the one that matters most: it is what a failed `box exec` leaves
# behind, and before #724's round the leg read it as "not a lock-skip, so it
# must have run" and graded the empty slice as lane behaviour.
brk_slice_lines() {
  case "$1" in
    LOCK)
      printf '%s duty tick skipped: previous run still holds the lock (running unknown)\n' \
        "$BRK_TS" ;;
    SILENT) ;;
    FAILED)
      printf '%s duty run start\n' "$BRK_TS"
      printf '%s duty tick FAILED: duty.sh exited 1\n' "$BRK_TS" ;;
    *)
      printf '%s duty run start\n' "$BRK_TS"
      brk_session_lines "$1"
      printf '%s duty run end\n' "$BRK_TS" ;;
  esac
}

# The Nth tick writes the Nth scripted slice; past the end the last one repeats,
# so an unbounded lock is spelled `BRK_SLICES=(LOCK)` rather than by counting.
brk_tick() {
  local spec
  BRK_TICK_N=$((BRK_TICK_N + 1))
  brk_note tick
  if [ "$BRK_TICK_N" -le "${#BRK_SLICES[@]}" ]; then
    spec="${BRK_SLICES[$((BRK_TICK_N - 1))]}"
  else
    spec="${BRK_SLICES[$((${#BRK_SLICES[@]} - 1))]}"
  fi
  # The recovered session acks the demand, which is what the post-recovery
  # clear assertion reads. Modelled here so that row is graded against the
  # board rather than against a stub that always says yes. BRK_RECOVERY_CLEARS=0
  # is the board where the demand is still PARKED after recovery: the clear
  # assertion must red there, and it only can if it reads the label the leg
  # armed rather than the literal `attention`.
  if [ "$spec" = RECOVERED ] && [ "$BRK_RECOVERY_CLEARS" -eq 1 ]; then
    BRK_ISSUE_LABELS=""
  fi
  brk_slice_lines "$spec" >>"$BRK_HOME/duty/duty.log"
  return "$BRK_TICK_RC"
}

brk_bx() {
  local cmd="$1"
  case "$cmd" in
    *alerts.log*)
      printf '🚨 crew-drill: %s session dispatch stopped after %s terminal failures (acted=no) — /tmp/s.log\n' \
        "$BRK_KIND" "$BRK_THRESHOLD" ;;
    # Both box reads can fail on a real host, and a leg that grades their
    # output without grading their status reads a failure as a fact.
    *'wc -l < ~/duty/duty.log'*)
      [ "$BRK_WC_READABLE" -eq 1 ] || return 1
      wc -l <"$BRK_HOME/duty/duty.log" ;;
    *'duty/bin/tick.sh'*) brk_tick ;;
    # A real box runs the command in a fresh shell with `~` expanded against
    # its own HOME, which is how the slice boundary gets exercised at all.
    *'tail -n +'*)
      [ "$BRK_LOG_READABLE" -eq 1 ] || return 1
      ( HOME="$BRK_HOME"; bash -c "$cmd" 2>/dev/null ) ;;
    *) return 0 ;;
  esac
}

# The board. A label POST on a CLOSED issue succeeds and arms nothing, which is
# the whole point: this stub accepts it exactly as GitHub does, so a leg that
# grades the request still reads green here and is killed by the state rows.
brk_gh() {
  local url="" method=GET field
  while [ "$#" -gt 0 ]; do
    case "$1" in
      api) shift ;;
      -X) method="$2"; shift 2 ;;
      -f)
        field="$2"; shift 2
        case "$field" in
          state=open)
            BRK_REOPENS=$((BRK_REOPENS + 1))
            brk_note reopen
            [ "$BRK_REOPEN_WORKS" -ne 1 ] || BRK_ISSUE_STATE=open ;;
          'labels[]='*)
            brk_note "label:${field#labels[]=}"
            if [ "$BRK_LABEL_STICKS" -eq 1 ]; then
              BRK_ISSUE_LABELS="${BRK_ISSUE_LABELS:+$BRK_ISSUE_LABELS,}${field#labels[]=}"
            fi ;;
        esac ;;
      *) url="$1"; shift ;;
    esac
  done
  case "$method:$url" in
    GET:*)
      [ "$BRK_ISSUE_READABLE" -eq 1 ] || return 1
      # A board that answers with something that is not JSON: the read
      # SUCCEEDS and is non-empty, so only parsing it says otherwise.
      if [ -n "$BRK_ISSUE_JSON" ]; then
        printf '%s\n' "$BRK_ISSUE_JSON"
      else
        jq -nc --arg s "$BRK_ISSUE_STATE" --arg l "$BRK_ISSUE_LABELS" \
          '{state:$s,labels:($l|split(",")|map(select(length>0)|{name:.}))}'
      fi ;;
    # Traced by URL, not by field: the label cleanup DELETEs is in the PATH,
    # so a `-f`-only trace cannot see which name the leg is disarming.
    DELETE:*) brk_note "delete:$url" ;;
  esac
  return 0
}

brk_reset() {
  rm -rf "$BRK_HOME"
  mkdir -p "$BRK_HOME/duty"
  : >"$BRK_HOME/duty/duty.log"
  : >"$BRK_TRACE"
  rm -f "$BRK_REASON"
  BRK_TICK_N=0
  BRK_REOPENS=0
}

# brk_drive — run the shipped leg against the fixture box and print the rows it
# emits, then its verdict. ok()/fail()/skip()/check()/wait_for() are supplied
# exactly as rehearsal.sh supplies them, so a row's GRADE is observed and not
# inferred: `INCOMPLETE, reason named, never FAIL` is a claim about which of
# these four a row went to, and nothing else can see that.
# The subshell-locality is the point: every drive gets a pristine copy of the
# leg's globals and its own stubs, and nothing here is read back afterwards —
# a drive's result is its stdout and the files it wrote. SC2030 only began
# firing once brk_cleanup_drive sourced the leg a second time.
# shellcheck disable=SC2030
brk_drive() {
  (
    export REHEARSAL_BREAKER_TICK_TRIES="$BRK_TRIES"
    export REHEARSAL_BREAKER_TICK_WAIT=0
    # The breaker's label predicate is the shared one in rehearsal-fixtures.sh
    # since #749, so the leg is sourced with it, as rehearsal.sh sources both.
    # shellcheck source=drill/rehearsal-fixtures.sh
    . "$ROOT/drill/rehearsal-fixtures.sh"
    # shellcheck source=drill/rehearsal-breaker.sh
    . "$ROOT/drill/rehearsal-breaker.sh"
    AGENT=kimi
    FAILS=()
    REHEARSAL_BREAKER_REASON_FILE="$BRK_REASON"
    # The facts are the fixture's, so the rows below are about grading and not
    # about the box read that resolves them; that read is driven against the
    # real shipped conf in shared/test/common.sh.
    rehearsal_breaker_load_installed_facts() {
      REHEARSAL_BREAKER_THRESHOLD="$BRK_THRESHOLD"
      REHEARSAL_BREAKER_KIND="$BRK_KIND"
      REHEARSAL_BREAKER_STATE=/tmp/breaker-state
      REHEARSAL_BREAKER_LABEL="$BRK_LABEL"
    }
    rehearsal_breaker_profile_has_hook() { return 0; }
    rehearsal_breaker_terminal_fixture_is_classified() { return 0; }
    rehearsal_breaker_install_fixture() {
      REHEARSAL_BREAKER_DIR=/tmp/breaker-fixture
      return 0
    }
    rehearsal_breaker_restore_cli_for_recovery() { return 0; }
    rehearsal_breaker_restore_cli() { return 0; }
    # shellcheck disable=SC2317  # reached only through check "$@", which shellcheck cannot follow
    rehearsal_breaker_profile_is_restored() { return 0; }
    bx() { brk_bx "$1"; }
    gh() { brk_gh "$@"; }
    ok()   { echo "ok $1"; }
    fail() { FAILS+=("$1"); echo "FAIL $1"; }
    skip() { echo "skip $1"; }
    check()    { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
    wait_for() { local n="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
    wait_for_lane() { shift; wait_for 0 "$@"; }
    rc=0
    rehearsal_breaker_drill owner/repo 1 reviewer || rc=$?
    printf 'RC=%s\nTICKS=%s\nREOPENS=%s\n' "$rc" "$BRK_TICK_N" "$BRK_REOPENS"
  )
}
# brk_cleanup_drive LABEL — the teardown path, driven directly. It has to be:
# `rehearsal_breaker_cleanup` is reached through rehearsal.sh's `cleanup_all`
# (drill/rehearsal.sh:210) and never through the leg, so the round above cannot
# reach it and its DELETE goes out unobserved.
brk_cleanup_drive() {
  (
    # shellcheck source=drill/rehearsal-breaker.sh
    . "$ROOT/drill/rehearsal-breaker.sh"
    bx() { brk_bx "$1"; }
    gh() { brk_gh "$@"; }
    REHEARSAL_BREAKER_REPO=owner/repo
    REHEARSAL_BREAKER_ISSUE=1
    REHEARSAL_BREAKER_LABEL="$1"
    REHEARSAL_BREAKER_STATE=/tmp/breaker-state
    REHEARSAL_BREAKER_DIR=""
    rehearsal_breaker_cleanup
  )
}

brk_ok()   { grep -c '^ok ' <<<"$1" || true; }
brk_fail() { grep -c '^FAIL ' <<<"$1" || true; }
brk_v()    { grep -c "^$2=$3\$" <<<"$1" || true; }
brk_trace() { awk "NR<=$1" "$BRK_TRACE" | paste -sd' ' -; }

# (a) THE NON-REGRESSION SHAPE, and the baseline every row below is a delta
# from: an open fixture whose ticks all run. This is `builder`'s round in rc2,
# which passed outright and must keep passing.
BRK_SLICES=(TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED RECOVERED)
brk_reset
BRK_GREEN="$(brk_drive)"
t drill-breaker-running-ticks-round-is-green 0 "$(brk_fail "$BRK_GREEN")"
t drill-breaker-running-ticks-round-returns-pass 1 "$(brk_v "$BRK_GREEN" RC 0)"
t drill-breaker-running-ticks-grades-every-row 18 "$(brk_ok "$BRK_GREEN")"
t drill-breaker-running-ticks-fires-six-ticks 1 "$(brk_v "$BRK_GREEN" TICKS 6)"
t drill-breaker-open-fixture-is-not-reopened 1 "$(brk_v "$BRK_GREEN" REOPENS 0)"
t drill-breaker-running-ticks-trips-the-lane 1 \
  "$(grep -c '^ok breaker: lane trips once at installed threshold for kimi$' <<<"$BRK_GREEN" || true)"

# (b) THE FIXTURE AN EARLIER LEG CLOSED — the `triage` role's round.
#
# `gh api -X POST …/labels` returns 201 on a closed issue and arms nothing:
# duty_attention fetches `/issues?filter=assigned&state=open`, so a closed
# issue is not a candidate. The leg reopens it BEFORE firing, and the trace row
# is the one that says "before": a reopen that happened after the first tick
# would leave every assertion below still green.
BRK_ISSUE_STATE=closed
brk_reset
BRK_CLOSED="$(brk_drive)"
t drill-breaker-closed-fixture-is-reopened 1 "$(brk_v "$BRK_CLOSED" REOPENS 1)"
t drill-breaker-closed-fixture-reopened-before-any-tick 'reopen label:attention tick' \
  "$(brk_trace 3)"
t drill-breaker-reopened-fixture-arms 1 \
  "$(grep -c '^ok breaker: attention lane fixture armed$' <<<"$BRK_CLOSED" || true)"
t drill-breaker-reopened-fixture-round-is-green 0 "$(brk_fail "$BRK_CLOSED")"
t drill-breaker-reopened-fixture-round-returns-pass 1 "$(brk_v "$BRK_CLOSED" RC 0)"

# (c) ...and the re-read is the assertion, not the reopen request. A board that
# accepts the PATCH and stays closed is exactly what the old code could not
# see, because the only thing it ever looked at was an exit status.
BRK_ISSUE_STATE=closed
BRK_REOPEN_WORKS=0
brk_reset
BRK_STUCK="$(brk_drive)"
t drill-breaker-unreopenable-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_STUCK" || true)"
t drill-breaker-unreopenable-fixture-names-what-it-read 1 \
  "$(grep -c '^  read: state=closed labels=attention$' <<<"$BRK_STUCK" || true)"
# The point of failing there: nothing downstream is graded, because there is
# no armed lane for any of it to be about.
t drill-breaker-unreopenable-fixture-fires-no-tick 1 "$(brk_v "$BRK_STUCK" TICKS 0)"
t drill-breaker-unreopenable-fixture-reds-the-leg 1 "$(brk_v "$BRK_STUCK" RC 1)"
BRK_ISSUE_STATE=open
BRK_REOPEN_WORKS=1

# (d) The other half of the same re-read: an OPEN issue the label did not stick
# to. Same row, same silence downstream, and the reading distinguishes the two
# without the operator opening the board.
BRK_LABEL_STICKS=0
brk_reset
BRK_UNLABELLED="$(brk_drive)"
t drill-breaker-unlabelled-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_UNLABELLED" || true)"
t drill-breaker-unlabelled-fixture-names-what-it-read 1 \
  "$(grep -c '^  read: state=open labels=$' <<<"$BRK_UNLABELLED" || true)"
t drill-breaker-unlabelled-fixture-fires-no-tick 1 "$(brk_v "$BRK_UNLABELLED" TICKS 0)"
BRK_LABEL_STICKS=1

# (e) A BOARD THAT WILL NOT READ is not an armed lane either. The third state
# again: not "the fixture is wrong" but "nobody looked at it".
BRK_ISSUE_READABLE=0
brk_reset
BRK_UNREADABLE="$(brk_drive)"
t drill-breaker-unreadable-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_UNREADABLE" || true)"
t drill-breaker-unreadable-fixture-says-so 1 \
  "$(grep -c '^  read: the fixture issue could not be read$' <<<"$BRK_UNREADABLE" || true)"
t drill-breaker-unreadable-fixture-fires-no-tick 1 "$(brk_v "$BRK_UNREADABLE" TICKS 0)"
BRK_ISSUE_READABLE=1

# (f) THE LABEL IS THE BOX'S, NOT THIS FILE'S. LABEL_ATTENTION is not one of
# the six wire marks load_fleet_conf restores over fleet.conf, so an operator
# file moves it and duty_attention then fetches that name. Arming the literal
# `attention` on such a box sets a label the engine never asks for — the lane
# is unarmed, every row below is about a dispatch nobody requested, and the
# arming row says it succeeded. Same defect as (b), keyed on the name instead
# of on the state.
BRK_LABEL=needs-human
brk_reset
BRK_RENAMED="$(brk_drive)"
t drill-breaker-renamed-label-is-the-one-posted 1 \
  "$(grep -c '^label:needs-human$' "$BRK_TRACE" || true)"
t drill-breaker-renamed-label-never-posts-the-literal 0 \
  "$(grep -c '^label:attention$' "$BRK_TRACE" || true)"
t drill-breaker-renamed-label-round-is-green 0 "$(brk_fail "$BRK_RENAMED")"
BRK_LABEL=attention

# (g) THE SKIP-ONLY SLICE — the `reviewer` role's round.
#
# tick.sh takes the box flock with `-n` and logs one line when a previous run
# still holds it. That tick returns immediately, so the leg's back-to-back loop
# spent its whole budget inside two seconds and graded five slices describing
# ticks that never executed. Nothing here is FAIL: the leg never reached the
# lane, so it has nothing to say about it, and saying it anyway is what put
# seven red rows against a working engine.
BRK_SLICES=(LOCK)
brk_reset
BRK_LOCKED="$(brk_drive)"
t drill-breaker-skip-only-slice-is-never-graded 0 \
  "$(grep -c 'remains below installed threshold' <<<"$BRK_LOCKED" || true)"
t drill-breaker-skip-only-slice-fails-nothing 0 "$(brk_fail "$BRK_LOCKED")"
t drill-breaker-skip-only-slice-is-incomplete 1 "$(brk_v "$BRK_LOCKED" RC 2)"
t drill-breaker-skip-only-slice-names-the-reason 1 \
  "$(grep -c '^skip breaker: terminal dispatch 1 never ran; leg INCOMPLETE$' <<<"$BRK_LOCKED" || true)"
t drill-breaker-skip-only-slice-records-the-reason \
  'terminal dispatch 1 never ran: 3 ticks refused by a held lock' \
  "$(cat "$BRK_REASON" 2>/dev/null)"
# ...and it re-fired rather than giving up on the first refusal. The bound is
# the fixture's 3, so a leg that fired once and a leg that fired forever are
# both distinguished from the one shipped here.
t drill-breaker-skip-only-slice-refires-to-the-bound 1 "$(brk_v "$BRK_LOCKED" TICKS 3)"

# (h) ...and the rc2 reviewer shape exactly: dispatch 1 LANDED, and everything
# after it was refused. This is the row that separates the fix from a leg that
# merely checks its first tick — the graded row for dispatch 1 is real and must
# survive, while the round still stops rather than grading what came after.
BRK_SLICES=(TERMINAL LOCK)
brk_reset
BRK_MIXED="$(brk_drive)"
t drill-breaker-landed-dispatch-still-graded 1 \
  "$(grep -c '^ok breaker: terminal dispatch 1 remains below installed threshold$' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-is-not-graded 0 \
  "$(grep -c 'dispatch 2 remains below installed threshold' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-fails-nothing 0 "$(brk_fail "$BRK_MIXED")"
t drill-breaker-refused-dispatch-is-incomplete 1 "$(brk_v "$BRK_MIXED" RC 2)"
t drill-breaker-refused-dispatch-names-which-one 1 \
  "$(grep -c '^skip breaker: terminal dispatch 2 never ran; leg INCOMPLETE$' <<<"$BRK_MIXED" || true)"
t drill-breaker-refused-dispatch-fires-one-plus-the-bound 1 \
  "$(brk_v "$BRK_MIXED" TICKS 4)"

# (i) A LOCK THAT CLEARS is the case the bound exists for, and the one the
# other two groups cannot show: the leg WAITS and re-fires, and the round then
# grades a lane it really did reach. Without this row, "never grade a skip"
# would be satisfied by a leg that simply gave up.
BRK_SLICES=(LOCK LOCK TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED RECOVERED)
BRK_TRIES=5
brk_reset
BRK_CLEARS="$(brk_drive)"
t drill-breaker-lock-that-clears-is-waited-out 0 "$(brk_fail "$BRK_CLEARS")"
t drill-breaker-lock-that-clears-round-returns-pass 1 "$(brk_v "$BRK_CLEARS" RC 0)"
t drill-breaker-lock-that-clears-grades-every-row 18 "$(brk_ok "$BRK_CLEARS")"
t drill-breaker-lock-that-clears-counts-the-refusals 1 "$(brk_v "$BRK_CLEARS" TICKS 8)"
BRK_TRIES=3

# (j) The stopped-lane ticks and the recovery tick go through the same gate.
# Three tick sites, and a fix applied to one of them leaves the other two
# grading refusals — which is how this defect survived #424's own fixtures.
BRK_SLICES=(TERMINAL TERMINAL TRIP LOCK)
brk_reset
BRK_STOPPED_LOCKED="$(brk_drive)"
t drill-breaker-stopped-lane-refusal-is-incomplete 1 \
  "$(brk_v "$BRK_STOPPED_LOCKED" RC 2)"
t drill-breaker-stopped-lane-refusal-fails-nothing 0 \
  "$(brk_fail "$BRK_STOPPED_LOCKED")"
t drill-breaker-stopped-lane-refusal-names-the-tick 1 \
  "$(grep -c '^skip breaker: stopped-lane tick 1 never ran; leg INCOMPLETE$' <<<"$BRK_STOPPED_LOCKED" || true)"
t drill-breaker-stopped-lane-refusal-does-not-grade-suppression 0 \
  "$(grep -c 'following ticks skip the stopped lane' <<<"$BRK_STOPPED_LOCKED" || true)"

BRK_SLICES=(TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED LOCK)
brk_reset
BRK_RECOVERY_LOCKED="$(brk_drive)"
t drill-breaker-recovery-refusal-is-incomplete 1 \
  "$(brk_v "$BRK_RECOVERY_LOCKED" RC 2)"
t drill-breaker-recovery-refusal-fails-nothing 0 \
  "$(brk_fail "$BRK_RECOVERY_LOCKED")"
t drill-breaker-recovery-refusal-names-the-tick 1 \
  "$(grep -c '^skip breaker: recovery tick never ran; leg INCOMPLETE$' <<<"$BRK_RECOVERY_LOCKED" || true)"
t drill-breaker-recovery-refusal-does-not-grade-recovery 0 \
  "$(grep -c 'later tick recovers and launches a session' <<<"$BRK_RECOVERY_LOCKED" || true)"

# (k) A TICK THAT WROTE NOTHING. The absence of the lock-skip line is not
# evidence that a tick ran: an invocation that failed, or a box exec that never
# landed, leaves an EMPTY slice, and reading "not a lock-skip, therefore it ran"
# grades that emptiness as lane behaviour. This is the same defect as (b) and
# (g) one layer in — a request's shape standing in for a confirmed state — and
# it is the one an unreachable box actually produces.
#
# Unlike a held lock this is not retried: a box that ran a tick which wrote no
# evidence is not a condition the bound outlasts, so the leg says so once.
BRK_SLICES=(SILENT)
brk_reset
BRK_SILENT="$(brk_drive)"
t drill-breaker-silent-tick-is-never-graded 0 \
  "$(grep -c 'remains below installed threshold' <<<"$BRK_SILENT" || true)"
t drill-breaker-silent-tick-fails-nothing 0 "$(brk_fail "$BRK_SILENT")"
t drill-breaker-silent-tick-is-incomplete 1 "$(brk_v "$BRK_SILENT" RC 2)"
t drill-breaker-silent-tick-names-the-tick 1 \
  "$(grep -c '^skip breaker: terminal dispatch 1 never ran; leg INCOMPLETE$' <<<"$BRK_SILENT" || true)"
t drill-breaker-silent-tick-records-the-reason \
  'terminal dispatch 1 never ran: the tick wrote no evidence line (tick.sh rc 0)' \
  "$(cat "$BRK_REASON" 2>/dev/null)"
t drill-breaker-silent-tick-does-not-refire 1 "$(brk_v "$BRK_SILENT" TICKS 1)"

# (l) A TICK THAT LOGGED FAILED — the third shape of tick.sh's contract. The
# job began and aborted, so the slice is a partial run and a lane graded on it
# is graded on however far the job got. The invocation's own rc rides into the
# reason: a leg that discards it with `|| true` cannot name it.
BRK_SLICES=(FAILED)
BRK_TICK_RC=1
brk_reset
BRK_TICK_FAILED="$(brk_drive)"
t drill-breaker-failed-tick-is-never-graded 0 \
  "$(grep -c 'remains below installed threshold' <<<"$BRK_TICK_FAILED" || true)"
t drill-breaker-failed-tick-fails-nothing 0 "$(brk_fail "$BRK_TICK_FAILED")"
t drill-breaker-failed-tick-is-incomplete 1 "$(brk_v "$BRK_TICK_FAILED" RC 2)"
t drill-breaker-failed-tick-records-the-reason-and-the-rc \
  'terminal dispatch 1 never ran: the tick logged FAILED (tick.sh rc 1)' \
  "$(cat "$BRK_REASON" 2>/dev/null)"
BRK_TICK_RC=0

# (m) THE SLICE BOUNDARY IS A BOX READ, AND IT IS GRADED TOO. Written as
# `first="$(( $(bx "wc -l < ~/duty/duty.log") + 1 ))"`, a failed read leaves the
# substitution empty, `$(( + 1 ))` is 1, and the "slice" becomes the WHOLE log
# — so the leg grades every earlier tick's lines and can PASS on stale
# evidence. A failed boundary read is not a smaller slice, it is the wrong one.
# The no-tick row is what says so: the boundary is read BEFORE the tick fires.
BRK_SLICES=(TERMINAL TERMINAL TRIP SUPPRESSED SUPPRESSED RECOVERED)
BRK_WC_READABLE=0
brk_reset
BRK_UNMEASURED="$(brk_drive)"
t drill-breaker-unmeasurable-log-fails-nothing 0 "$(brk_fail "$BRK_UNMEASURED")"
t drill-breaker-unmeasurable-log-is-incomplete 1 "$(brk_v "$BRK_UNMEASURED" RC 2)"
t drill-breaker-unmeasurable-log-records-the-reason \
  "terminal dispatch 1 never ran: the box's duty.log could not be measured" \
  "$(cat "$BRK_REASON" 2>/dev/null)"
t drill-breaker-unmeasurable-log-fires-no-tick 1 "$(brk_v "$BRK_UNMEASURED" TICKS 0)"
BRK_WC_READABLE=1

# (n) ...and so is the read-back. `tail -n +$first` runs on the box and can
# fail there; its output inside a command substitution is an empty string
# either way, which is indistinguishable from a tick that wrote nothing unless
# the status is read. The tick DID fire here, which is what separates this row
# from (m).
BRK_LOG_READABLE=0
brk_reset
BRK_UNREADABLE_LOG="$(brk_drive)"
t drill-breaker-unreadable-log-fails-nothing 0 "$(brk_fail "$BRK_UNREADABLE_LOG")"
t drill-breaker-unreadable-log-is-incomplete 1 "$(brk_v "$BRK_UNREADABLE_LOG" RC 2)"
t drill-breaker-unreadable-log-records-the-reason \
  "terminal dispatch 1 never ran: the box's duty.log could not be read back" \
  "$(cat "$BRK_REASON" 2>/dev/null)"
t drill-breaker-unreadable-log-fired-the-tick 1 "$(brk_v "$BRK_UNREADABLE_LOG" TICKS 1)"
BRK_LOG_READABLE=1

# (o) THE POST-RECOVERY CLEAR READS THE ARMED LABEL. Group (f) cannot show
# this: its recovery ACKS the demand, so the board reads clear under either
# name and a clear keyed on the literal `attention` passes it. Here the demand
# is still parked after recovery on a box that moved the label — the one board
# where the two readings disagree, and the assertion must red.
BRK_LABEL=needs-human
BRK_RECOVERY_CLEARS=0
brk_reset
BRK_STANDING="$(brk_drive)"
t drill-breaker-standing-renamed-label-reds-the-clear 1 \
  "$(grep -c '^FAIL breaker: needs-human label removed after recovered session$' <<<"$BRK_STANDING" || true)"
t drill-breaker-standing-renamed-label-never-certifies-the-literal 0 \
  "$(grep -c '^ok breaker: attention label removed after recovered session$' <<<"$BRK_STANDING" || true)"
BRK_RECOVERY_CLEARS=1
brk_reset
BRK_ACKED="$(brk_drive)"
t drill-breaker-acked-renamed-label-passes-the-clear 1 \
  "$(grep -c '^ok breaker: needs-human label removed after recovered session$' <<<"$BRK_ACKED" || true)"
BRK_LABEL=attention

# (p) ...and so does cleanup's DELETE, which disarms the lane on the way out.
# Nothing above reaches it: rehearsal.sh calls it through `cleanup_all`, not
# through the leg. Keyed on the literal, a box that moved the label keeps the
# demand standing after the drill — the leg would leave the lane it armed armed.
brk_reset
brk_cleanup_drive needs-human
t drill-breaker-cleanup-deletes-the-effective-label 1 \
  "$(grep -c '^delete:repos/owner/repo/issues/1/labels/needs-human$' "$BRK_TRACE" || true)"
t drill-breaker-cleanup-never-deletes-the-literal 0 \
  "$(grep -c '^delete:repos/owner/repo/issues/1/labels/attention$' "$BRK_TRACE" || true)"
# The documented fallback: a cleanup that runs before the facts resolved armed
# nothing, and the DELETE is a no-op under either name.
brk_reset
brk_cleanup_drive ""
t drill-breaker-cleanup-falls-back-to-the-literal 1 \
  "$(grep -c '^delete:repos/owner/repo/issues/1/labels/attention$' "$BRK_TRACE" || true)"

# (q) A BOARD THAT ANSWERS WITH SOMETHING THAT IS NOT JSON. The read succeeds
# and is non-empty, so only parsing it says otherwise — the one arming branch
# the groups above do not drive.
BRK_ISSUE_JSON='<html>502 Bad Gateway</html>'
brk_reset
BRK_JUNK="$(brk_drive)"
t drill-breaker-unparseable-fixture-fails-arming 1 \
  "$(grep -c '^FAIL breaker: attention lane fixture armed$' <<<"$BRK_JUNK" || true)"
t drill-breaker-unparseable-fixture-names-what-it-read 1 \
  "$(grep -c '^  read: the fixture issue read back unparseable$' <<<"$BRK_JUNK" || true)"
t drill-breaker-unparseable-fixture-fires-no-tick 1 "$(brk_v "$BRK_JUNK" TICKS 0)"
BRK_ISSUE_JSON=""
BRK_SLICES=(SILENT)

# --- #725: the resume leg's log predicates -----------------------------------
#
# `drill/rehearsal-resume.sh` opens by saying the live leg runs only from an
# authenticated drill host "so CI can mutate their inputs without a drill
# host". Nothing did: the predicates shipped with no fixture at all, and the
# `0.1.3-rc2` round was the first thing that ever ran them. It read two rows
# FAIL and the record could say no more than the verdict strings, because the
# negative rows asked whether ANY resume session started in the sandbox — true
# of every resume that repository buys for any reason, and a question whose
# answer is not about the head under test.
#
# The fixtures below are `duty.log` windows, which is the one input these
# predicates have. The engine's line shapes are pinned in shared/test/builder.sh
# against the engine itself; what is pinned here is what the leg CONCLUDES from
# them.
# shellcheck source=drill/rehearsal-resume.sh
. "$ROOT/drill/rehearsal-resume.sh"
D725_REPO=danmt/crew-drill-builder
D725_PR=12
D725_HEAD="$(printf 'b%.0s' $(seq 1 40))"
d725_log() { printf '%s\n' "$@"; }
# The tick the leg wants on a pending head: the roll-call names nothing, and
# nothing dispatched.
D725_QUIET="$(d725_log "$D725_REPO: no resume duty")"
# The tick the leg is FOR: the green-head bypass named this PR and resumed.
D725_RESUMED="$(d725_log \
  "$D725_REPO#$D725_PR: green head owed a signal — resuming this tick instead of the twelfth, dispatch 1 of 3 at $D725_HEAD (#384)" \
  "$D725_REPO: resume duty (drafts: none; orphaned claims: none; unsignalled ready PRs: $D725_PR; of those, signals that missed the wire: none, green heads owed a signal: $D725_PR; drafts owed a flip: none)" \
  "SESSION START kind=resume key=$D725_REPO")"
# THE READING THAT MINTED #725, and the one this block exists for: a resume
# session for something else entirely. An orphaned claim — the leg's own fixture
# issue is claimed for the length of the leg, and an earlier pass can leave
# another — buys a session on every tick, and the old predicate reported it as
# this PR's pending head being resumed. Nothing here names PR 12.
D725_OTHER="$(d725_log \
  "$D725_REPO: resume duty (drafts: none; orphaned claims: 41; unsignalled ready PRs: none; of those, signals that missed the wire: none, green heads owed a signal: none; drafts owed a flip: none)" \
  "SESSION START kind=resume key=$D725_REPO")"
t d725-pending-quiet-tick-passes 0 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" "$D725_QUIET"; echo $?)"
t d725-pending-row-catches-a-real-resume 1 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" "$D725_RESUMED"; echo $?)"
t d725-pending-row-ignores-another-lanes-session 0 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" "$D725_OTHER"; echo $?)"
# An orphaned claim whose ISSUE number equals this PR's number is the conflation
# in miniature, and the field is cut before the scan for exactly that reason.
D725_CLAIM_COLLIDES="$(d725_log \
  "$D725_REPO: resume duty (drafts: none; orphaned claims: $D725_PR; unsignalled ready PRs: none; of those, signals that missed the wire: none, green heads owed a signal: none; drafts owed a flip: none)")"
t d725-orphan-claim-number-is-not-a-pr-number 0 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" "$D725_CLAIM_COLLIDES"; echo $?)"
# A PR number that is a PREFIX of a dispatched one is not a dispatch of it: 1
# against a roll-call naming 12 must read clean, or every leg with a
# single-digit fixture PR reds on its neighbour.
t d725-prefix-number-is-not-a-dispatch 0 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" 1 "$D725_RESUMED"; echo $?)"
# Every dispatching lane, not just the bypass the row's verdict string names:
# a near-miss or stranded dispatch at a pending head is the same defect. These
# two are the lane lines `_resume_lane_breaker` writes, verbatim.
for d725_lane in near-miss stranded; do
  t "d725-pending-row-catches-$d725_lane" 1 \
    "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" \
       "$(d725_log "$D725_REPO#$D725_PR: $d725_lane resume dispatch 1 of 3 at $D725_HEAD")"; echo $?)"
done
# The DRAFT lane logs no per-dispatch line — only a trip warning at the
# threshold — so it is caught by the roll-call's `drafts:` field and by nothing
# else. A fixture for a `draft resume dispatch` line would assert against a
# shape no log can carry, which is the dead branch head-checks.jq's round 2
# names; this is the shape the engine does write.
t d725-pending-row-catches-a-draft-dispatch 1 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" \
     "$(d725_log "$D725_REPO: resume duty (drafts: $D725_PR; orphaned claims: none; unsignalled ready PRs: none; of those, signals that missed the wire: none, green heads owed a signal: none; drafts owed a flip: none)")"; echo $?)"
# MUST FAIL — the lane alternation above is the engine's, or it is decoration.
# `draft` is absent from it on purpose and the engine must keep writing the two
# that are there.
# shellcheck disable=SC2016  # matching shell source literally
t d725-lane-lines-are-the-engines 1 \
  "$(grep -c 'log "\$repo#\$num: \$lane resume dispatch \$count of \$breaker at \$head"' \
     "$SHARED/lib/duty-builder.sh")"
t d725-no-draft-lane-dispatch-line 0 \
  "$(grep -c 'draft resume dispatch' "$SHARED/lib/duty-builder.sh")"
# A roll-call for ANOTHER repository in the same tick window says nothing about
# this one — every tick sweeps every repo in the registry.
t d725-other-repos-roll-call-is-not-ours 0 \
  "$(rehearsal_resume_pending_tick_from_log "$D725_REPO" "$D725_PR" \
     "$(d725_log "other/repo: resume duty (drafts: $D725_PR; orphaned claims: none; unsignalled ready PRs: none; of those, signals that missed the wire: none, green heads owed a signal: none; drafts owed a flip: none)")"; echo $?)"

# THE STOP ROW, both halves. The lane must SAY it stopped — a suppression
# nobody can see is the failure #59 names, not a fix — and this PR must be
# absent from the roll-call.
D725_STOP="$(d725_log \
  "no resume duty: $D725_REPO#$D725_PR near-miss lane suppressed at $D725_HEAD after 3 zero-action dispatches — only a push clears it (#314)" \
  "$D725_REPO: no resume duty")"
t d725-stop-row-passes-on-a-said-stop 0 \
  "$(rehearsal_resume_suppressed_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 3 "$D725_STOP"; echo $?)"
t d725-stop-row-fails-on-silence 1 \
  "$(rehearsal_resume_suppressed_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 3 "$D725_QUIET"; echo $?)"
# The threshold is part of the assertion: a lane that stopped at a DIFFERENT
# count than the installed one is not the contract the leg reads.
t d725-stop-row-is-threshold-scoped 1 \
  "$(rehearsal_resume_suppressed_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 4 "$D725_STOP"; echo $?)"
# A stop that is said while the same tick dispatches for this PR anyway is not a
# stop, and this is the half the roll-call scan adds.
t d725-stop-row-fails-when-it-dispatches-anyway 1 \
  "$(rehearsal_resume_suppressed_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 3 \
     "$(d725_log "$D725_STOP" \
        "$D725_REPO: resume duty (drafts: none; orphaned claims: none; unsignalled ready PRs: $D725_PR; of those, signals that missed the wire: none, green heads owed a signal: none; drafts owed a flip: none)")"; echo $?)"
# ...and a stop said while ANOTHER claim buys the tick's session still passes:
# that is the reading the round could not make.
t d725-stop-row-ignores-another-lanes-session 0 \
  "$(rehearsal_resume_suppressed_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 3 \
     "$(d725_log "$D725_STOP" "$D725_OTHER")"; echo $?)"

# THE POSITIVE ROWS ARE UNCHANGED, and are fixtured here for the first time so
# that "scope the negatives" cannot quietly become "assert nothing". Both keep
# the repo-wide SESSION START: a session is what the wake BUYS, and no unrelated
# session can forge the per-PR dispatch line beside it.
t d725-wake-row-reads-a-real-wake 0 \
  "$(rehearsal_resume_wake_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" "$D725_RESUMED"; echo $?)"
t d725-wake-row-fails-on-a-quiet-tick 1 \
  "$(rehearsal_resume_wake_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" "$D725_QUIET"; echo $?)"
D725_NEAR="$(d725_log \
  "$D725_REPO#$D725_PR: comment 77 opens with an unrendered marker slot and names head $D725_HEAD — not a signal (#133), but the round was answered there; resuming this tick instead of the twelfth (#319)" \
  "$D725_REPO#$D725_PR: near-miss resume dispatch 1 of 3 at $D725_HEAD" \
  "SESSION START kind=resume key=$D725_REPO")"
t d725-near-miss-row-reads-a-real-near-miss 0 \
  "$(rehearsal_resume_near_miss_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 77 "$D725_NEAR"; echo $?)"
t d725-near-miss-row-fails-on-a-quiet-tick 1 \
  "$(rehearsal_resume_near_miss_tick_from_log "$D725_REPO" "$D725_PR" "$D725_HEAD" 77 "$D725_QUIET"; echo $?)"
# THE EVIDENCE A FAILING ROW LEAVES. The rc2 record carries the verdict strings
# and nothing else, which is why #725 had to be opened against two candidates at
# once. A failing row now prints the tick's roll-call.
t d725-roll-call-is-recoverable 1 \
  "$(rehearsal_resume_roll_call_from_log "$D725_REPO" "$D725_OTHER" | grep -c 'orphaned claims: 41')"
t d725-roll-call-falls-back-to-the-quiet-line 1 \
  "$(rehearsal_resume_roll_call_from_log "$D725_REPO" "$D725_QUIET" | grep -c 'no resume duty')"
unset -f d725_log

# ── #749 / #750 — wait_for grades STATES, and the two label rows grade on the ──
# ── lane's installed budget ──────────────────────────────────────────────────
# The real wait_for, extracted from rehearsal.sh and run with ok()/fail()
# supplied as rehearsal.sh defines them, so the ROW it prints is what the
# transcript shows — the grade is observed, never inferred from a return code.
w749_run() {  # w749_run <budget> <name> <cmd...> — the rows, then "rc=N"
  (
    # shellcheck disable=SC2317  # supplied to the extracted wait_for
    ok()   { echo "ok   $1"; }
    # shellcheck disable=SC2317
    fail() { echo "FAIL $1"; }
    # shellcheck disable=SC2034  # read by the extracted wait_for
    WAIT_FOR_INTERVAL=0
    eval "$(sed -n '/^wait_for() {/,/^}/p' "$ROOT/drill/rehearsal.sh")"
    wait_for "$@"; echo "rc=$?"
  ) </dev/null
}
# shellcheck disable=SC2317  # the predicates are invoked by wait_for, indirectly
w749_say() {  # w749_say <rc> <stderr...> — a predicate answering one state, noisily on stdout
  local rc="$1"; shift
  printf '%s\n' "$@" >&2
  echo "stdout-noise"
  return "$rc"
}
W749_COUNT="$TMP/w749-count"
# shellcheck disable=SC2317
w749_counted() { echo x >>"$W749_COUNT"; echo "labels on o/r#1: [ready]" >&2; return "$1"; }

w749_out="$(w749_run 1 row w749_say 0 'labels on o/r#1: []')"
t w749-satisfied-is-the-ok-row 1 "$(grep -cx 'ok   row' <<<"$w749_out")"
t w749-satisfied-rc 1 "$(grep -cx 'rc=0' <<<"$w749_out")"
w749_out="$(w749_run 1 row w749_say 1 'labels on o/r#1: [ready]')"
t w749-not-yet-runs-out-the-budget-and-prints-what-it-saw 1 \
  "$(grep -cx 'FAIL row (timeout 1s; last observed: labels on o/r#1: \[ready\])' <<<"$w749_out")"
t w749-not-yet-rc 1 "$(grep -cx 'rc=1' <<<"$w749_out")"
: >"$W749_COUNT"
w749_out="$(w749_run 30 row w749_counted 2)"
t w749-cannot-grade-refuses-at-once 1 "$(wc -l <"$W749_COUNT" | tr -d ' ')"
t w749-cannot-grade-names-the-reason 1 \
  "$(grep -cx 'FAIL row (cannot grade: labels on o/r#1: \[ready\])' <<<"$w749_out")"
t w749-cannot-grade-rc 1 "$(grep -cx 'rc=2' <<<"$w749_out")"
w749_out="$(w749_run 1 row w749_say 3 'could not read repos/o/r/issues/1')"
t w749-could-not-read-is-its-own-state 1 \
  "$(grep -cx 'FAIL row (could not read within 1s: could not read repos/o/r/issues/1)' <<<"$w749_out")"
t w749-could-not-read-never-reads-as-false 0 "$(grep -c 'timeout' <<<"$w749_out")"
t w749-could-not-read-rc 1 "$(grep -cx 'rc=3' <<<"$w749_out")"
w749_out="$(w749_run 1 row w749_say 1 'first line' 'second line')"
t w749-multi-line-diagnostics-stay-on-the-row 1 \
  "$(grep -cx 'FAIL row (timeout 1s; last observed: first line | second line)' <<<"$w749_out")"
t w749-predicate-stdout-is-still-discarded 0 \
  "$(w749_run 1 row w749_say 1 'x' | grep -c stdout-noise)"
t w749-a-silent-not-yet-says-nothing-observed 1 \
  "$(w749_run 1 row w749_say 1 '' | grep -cx 'FAIL row (timeout 1s; last observed: nothing)')"
# A predicate outside the protocol — the `bash -c` rows, grep's 1 — is not-yet.
t w749-off-protocol-status-reads-as-not-yet 1 \
  "$(w749_run 1 row bash -c 'exit 7' | grep -cx 'rc=1')"

# The two predicates, against a gh that answers each state. Sourced AFTER the
# label names are set? No — rehearsal-fixtures.sh resets them at source time,
# so they are set after, exactly as rehearsal.sh's board read sets them.
W749_GH="$TMP/gh749"
mkdir -p "$W749_GH"
cat >"$W749_GH/gh" <<'GH'
#!/usr/bin/env bash
case "${GH749:-}" in
  fail)    echo "gh: HTTP 502 from the fixture" >&2; exit 1 ;;
  present) printf '{"labels":[{"name":"ready"},{"name":"attention"}]}\n' ;;
  absent)  printf '{"labels":[{"name":"claimed"}]}\n' ;;
  garbage) printf 'not json\n' ;;
esac
GH
chmod +x "$W749_GH/gh"
w749_grade() {  # w749_grade <mode> <predicate> — "rc=N", then the predicate's stderr
  (
    export GH749="$1"
    # The predicates call `gh api …`; a function is the stub, so PATH is not
    # modified in a subshell (SC2030/SC2031 pair with the mint shim above).
    # shellcheck disable=SC2317
    gh() { "$W749_GH/gh" "$@"; }
    # shellcheck disable=SC2317  # the sourced file's reads go through bx
    bx() { return 1; }
    # shellcheck source=drill/rehearsal-fixtures.sh
    . "$ROOT/drill/rehearsal-fixtures.sh"
    REHEARSAL_LABEL_READY=ready
    REHEARSAL_LABEL_ATTENTION=attention
    [ "$1" != unnamed ] || { REHEARSAL_LABEL_READY=""; REHEARSAL_LABEL_ATTENTION=""; }
    err="$("$2" owner/repo 1 2>&1 >/dev/null)"; rc=$?
    echo "rc=$rc"; printf '%s\n' "$err"
  ) </dev/null
}
for w749_fn in rehearsal_builder_left_the_queue rehearsal_attention_flag_cleared; do
  w749_out="$(w749_grade fail "$w749_fn")"
  t "w749-$w749_fn-read-failure-is-3" 1 "$(grep -cx 'rc=3' <<<"$w749_out")"
  t "w749-$w749_fn-read-failure-says-so" 1 "$(grep -c 'could not read repos/owner/repo/issues/1' <<<"$w749_out")"
  t "w749-$w749_fn-read-failure-keeps-gh-stderr" 1 "$(grep -c 'HTTP 502' <<<"$w749_out")"
  w749_out="$(w749_grade present "$w749_fn")"
  t "w749-$w749_fn-present-is-not-yet" 1 "$(grep -cx 'rc=1' <<<"$w749_out")"
  t "w749-$w749_fn-present-prints-the-set" 1 "$(grep -cx 'labels on owner/repo#1: \[ready attention\]' <<<"$w749_out")"
  w749_out="$(w749_grade absent "$w749_fn")"
  t "w749-$w749_fn-absent-is-satisfied" 1 "$(grep -cx 'rc=0' <<<"$w749_out")"
  t "w749-$w749_fn-absent-still-prints-the-set" 1 "$(grep -cx 'labels on owner/repo#1: \[claimed\]' <<<"$w749_out")"
  w749_out="$(w749_grade garbage "$w749_fn")"
  t "w749-$w749_fn-unparsable-answer-is-3" 1 "$(grep -cx 'rc=3' <<<"$w749_out")"
  w749_out="$(w749_grade unnamed "$w749_fn")"
  t "w749-$w749_fn-empty-name-is-2" 1 "$(grep -cx 'rc=2' <<<"$w749_out")"
  t "w749-$w749_fn-empty-name-says-so" 1 "$(grep -c 'cannot grade: the label name is empty' <<<"$w749_out")"
done

# #750 — the budget is the box's, read the way the engine reads it.
w750_budget() {  # w750_budget <bx-stdout> <bx-rc> <kind> — "rc=N value=V"
  (
    W750_ANSWER="$1" W750_RC="$2"
    # shellcheck disable=SC2317
    bx() { printf '%s' "$W750_ANSWER"; return "$W750_RC"; }
    # shellcheck source=drill/rehearsal-fixtures.sh
    . "$ROOT/drill/rehearsal-fixtures.sh"
    v="$(rehearsal_lane_budget "$3")"; echo "rc=$? value=$v"
  ) </dev/null
}
t w750-budget-is-the-installed-timeout "rc=0 value=1800" "$(w750_budget $'1800\n' 0 ATTENTION)"
t w750-budget-survives-the-transport-cr "rc=0 value=3600" "$(w750_budget $'3600\r\n' 0 BUILD)"
t w750-budget-takes-the-last-line "rc=0 value=1800" "$(w750_budget $'noise from a login shell\n1800\n' 0 ATTENTION)"
t w750-no-answer-is-a-refusal "rc=1 value=" "$(w750_budget '' 0 ATTENTION)"
t w750-a-word-is-a-refusal "rc=1 value=" "$(w750_budget $'abc\n' 0 ATTENTION)"
t w750-zero-is-a-refusal "rc=1 value=" "$(w750_budget $'0\n' 0 ATTENTION)"
t w750-a-failed-box-read-is-a-refusal "rc=1 value=" "$(w750_budget $'1800\n' 2 ATTENTION)"
t w750-a-kind-outside-the-alphabet-is-a-refusal "rc=1 value=" "$(w750_budget $'1800\n' 0 'ATTENTION; rm -rf /')"
w750_read="$(sed -n '/^rehearsal_lane_budget() {/,/^}/p' "$ROOT/drill/rehearsal-fixtures.sh")"
# shellcheck disable=SC2016  # the markers are the box-side text, $ included
t w750-the-read-layers-every-file-load-conf-does "1,1,1,1,1" \
  "$(for w750_m in 'fleet.defaults.conf' 'fleet.conf' 'instance.conf' 'agents/"$BOT_AGENT".conf' 'roles/"$role".conf'; do
       grep -cF -- "$w750_m" <<<"$w750_read"; done | paste -sd,)"
# wait_for_lane: the row refuses when the box cannot say, and delegates when it can.
w750_lane() {  # w750_lane <budget-or-empty> — the row, then "rc=N"
  (
    # shellcheck disable=SC2317  # supplied to the extracted wait_for_lane
    ok()   { echo "ok   $1"; }
    # shellcheck disable=SC2317
    fail() { echo "FAIL $1"; }
    W750_B="$1"
    # shellcheck disable=SC2317
    rehearsal_lane_budget() { [ -n "$W750_B" ] || return 1; printf '%s\n' "$W750_B"; }
    # shellcheck disable=SC2034  # read by the extracted wait_for
    WAIT_FOR_INTERVAL=0
    eval "$(sed -n '/^wait_for() {/,/^}/p; /^wait_for_lane() {/,/^}/p' "$ROOT/drill/rehearsal.sh")"
    wait_for_lane ATTENTION row true; echo "rc=$?"
  ) </dev/null
}
t w750-unreadable-budget-refuses-the-row 1 \
  "$(w750_lane '' | grep -cx 'FAIL row (cannot grade: the installed TIMEOUT_ATTENTION could not be read from the box)')"
t w750-unreadable-budget-rc 1 "$(w750_lane '' | grep -cx 'rc=2')"
t w750-readable-budget-grades-the-row 1 "$(w750_lane 1 | grep -cx 'ok   row')"
# The two rows name the lane and carry no literal, so a literal cannot drift back.
t w750-attention-row-grades-on-the-lane 1 \
  "$(grep -c 'wait_for_lane ATTENTION "attention: label removed (ack re-arms)"' "$ROOT/drill/rehearsal.sh")"
t w750-builder-row-grades-on-the-lane 1 \
  "$(grep -c 'wait_for_lane BUILD "builder: issue moved off ready (claimed)"' "$ROOT/drill/rehearsal.sh")"
t w750-neither-row-carries-a-literal 0 \
  "$(grep -cE 'wait_for [0-9]+ "(attention: label removed|builder: issue moved off ready)' "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # the row's own text, $ included
t w750-breaker-row-grades-on-the-lane 1 \
  "$(grep -c 'wait_for_lane ATTENTION "breaker: \$REHEARSAL_BREAKER_LABEL label removed' "$ROOT/drill/rehearsal-breaker.sh")"
t w750-breaker-row-carries-no-literal 0 \
  "$(grep -cE 'wait_for [0-9]+ "breaker: .*label removed' "$ROOT/drill/rehearsal-breaker.sh")"
unset -f w749_run w749_say w749_counted w749_grade w750_budget w750_lane

# --- #656: the fleet-lifecycle leg's classifiers, and its row ---------------
# The leg itself needs a box host, real boxes and an operator fleet definition.
# What is testable here is the part that decides what a round SAW, and that is
# deliberately all of it: every verdict the leg reaches comes out of
# drill/fleet-lifecycle.sh, so these fixtures EXECUTE the classifiers against
# the verbs' real line shapes rather than pinning the leg's source text — the
# drill/agreement.sh precedent, which is what made #494's armed/skewed verdict
# testable without a host.
# shellcheck source=drill/fleet-lifecycle.sh
. "$ROOT/drill/fleet-lifecycle.sh"

# Case 1: a roster whose boxes report mixed states. Three boxes, three
# different outcomes, in the shapes cli/crew actually prints.
FLEET_RESTART_MIXED='restart plan (72h force-after): crew-drill-triage crew-drill-builder crew-drill-reviewer
  crew-drill-triage: restarted; /tmp filesystem free 1048576 → 1310720 KiB (delta +262144 KiB)
  crew-drill-builder: SKIPPED busy — duty lock held for 4m 10s
  restart FAILED on crew-drill-reviewer — start command failed

restart: 1 restarted, 1 skipped-busy, 1 failed
  skipped: crew-drill-builder
  failed: crew-drill-reviewer'
t fleet-restart-names-the-cycled-box cycled \
  "$(fleet_restart_outcome crew-drill-triage <<<"$FLEET_RESTART_MIXED")"
t fleet-restart-names-the-busy-box skipped-busy \
  "$(fleet_restart_outcome crew-drill-builder <<<"$FLEET_RESTART_MIXED")"
t fleet-restart-names-the-failed-box failed \
  "$(fleet_restart_outcome crew-drill-reviewer <<<"$FLEET_RESTART_MIXED")"
# A box the verb never mentioned is `unknown` and never a pass. This is the
# reading that stops a roster row silently dropping out of the table.
t fleet-restart-unmentioned-box-is-unknown unknown \
  "$(fleet_restart_outcome crew-drill-absent <<<"$FLEET_RESTART_MIXED")"
# A box that was already stopped is still a cycle: `crew restart` documents
# that state, and grading it `unknown` would red a round for a success.
t fleet-restart-already-stopped-box-is-a-cycle cycled \
  "$(fleet_restart_outcome crew-drill-triage <<<'  crew-drill-triage: already stopped; starting
  crew-drill-triage: started from stopped; /tmp filesystem free 900000 KiB (no pre-stop reading)')"
# A longer name sharing a prefix is a different box. Without the literal `: `
# these two would fold into one row and the table would name an outcome the
# verb gave to somebody else.
t fleet-restart-prefix-name-does-not-fold unknown \
  "$(fleet_restart_outcome crew-drill-build <<<"$FLEET_RESTART_MIXED")"

# ...and the counts match the rows. The table IS the evidence: #642 and #652
# each say a fleet-level summary line alone does not satisfy them.
FLEET_RESTART_ROWS='crew-drill-triage cycled
crew-drill-builder skipped-busy
crew-drill-reviewer failed'
t fleet-restart-table-agrees-with-the-summary agree \
  "$(fleet_counts_agree restart 'restart: 1 restarted, 1 skipped-busy, 1 failed' \
    <<<"$FLEET_RESTART_ROWS")"
# A dropped row is the degenerate case of a summary-only reading, and it must
# not be absorbed: the leg printed fewer boxes than the verb acted on.
t fleet-restart-dropped-row-disagrees disagree:cycled=0/1 \
  "$(fleet_counts_agree restart 'restart: 1 restarted, 1 skipped-busy, 1 failed' \
    <<<'crew-drill-builder skipped-busy
crew-drill-reviewer failed')"
t fleet-restart-empty-table-against-a-real-summary-disagrees disagree:cycled=0/1 \
  "$(fleet_counts_agree restart 'restart: 1 restarted, 1 skipped-busy, 1 failed' </dev/null)"
t fleet-restart-invented-row-disagrees disagree:cycled=2/1 \
  "$(fleet_counts_agree restart 'restart: 1 restarted, 1 skipped-busy, 1 failed' \
    <<<'crew-drill-triage cycled
crew-drill-extra cycled
crew-drill-builder skipped-busy
crew-drill-reviewer failed')"

# Case 6, and it is the whole design rather than one assertion: a patch that
# satisfied a criterion by reading the verb's EXIT CODE could not tell these
# two rounds apart. `crew restart --all` returns 3 for both — one box skipped
# and every box skipped are the same number — and they are materially
# different rounds. The classifier separates them; an rc cannot.
FLEET_RESTART_ALL_BUSY='  crew-drill-triage: SKIPPED busy — duty lock held for 1m 0s
  crew-drill-builder: SKIPPED busy — duty lock held for 4m 10s
  crew-drill-reviewer: SKIPPED busy — duty lock age unavailable

restart: 0 restarted, 3 skipped-busy, 0 failed'
t fleet-rc-identical-rounds-differ-in-the-table cycled/skipped-busy \
  "$(printf '%s/%s' \
    "$(fleet_restart_outcome crew-drill-triage <<<"$FLEET_RESTART_MIXED")" \
    "$(fleet_restart_outcome crew-drill-triage <<<"$FLEET_RESTART_ALL_BUSY")")"
# The mutation that proves the assertion above is discriminating: a classifier
# collapsed to one constant — which is all an rc reading can be — stops
# agreeing with the verb's own counts on the mixed round.
fleet_restart_outcome_rc_only() { printf 'skipped-busy\n'; }
FLEET_RC_ONLY_ROWS="$(for b in crew-drill-triage crew-drill-builder crew-drill-reviewer; do
  printf '%s %s\n' "$b" "$(fleet_restart_outcome_rc_only)"
done)"
t fleet-rc-only-classifier-mutation-disagrees disagree:cycled=0/1 \
  "$(fleet_counts_agree restart 'restart: 1 restarted, 1 skipped-busy, 1 failed' \
    <<<"$FLEET_RC_ONLY_ROWS")"

# Case 2, the other half of drain_probe()'s contract: `restart` SKIPS a busy
# box and `down` WAITS for one. Proving one says nothing about the other, so
# both are read, and `waited` outranks `stopped` — a box that was waited for
# and then stopped must not become indistinguishable from an idle box that
# stopped at once, or the assertion passes on a round where nothing was busy.
FLEET_DOWN='  crew-drill-triage: stopped
  crew-drill-builder: waiting for duty lock held 4m 10s; use crew down --force to stop without draining
  crew-drill-builder: stopped
  crew-drill-absent: not present, skipping
  down FAILED on crew-drill-reviewer (stop command failed)

down: 2 stopped, 1 waited, 1 absent, 1 failed'
t fleet-down-waits-for-the-busy-box waited \
  "$(fleet_down_outcome crew-drill-builder <<<"$FLEET_DOWN")"
t fleet-down-names-the-idle-box stopped \
  "$(fleet_down_outcome crew-drill-triage <<<"$FLEET_DOWN")"
t fleet-down-names-the-absent-box absent \
  "$(fleet_down_outcome crew-drill-absent <<<"$FLEET_DOWN")"
t fleet-down-names-the-failed-box failed \
  "$(fleet_down_outcome crew-drill-reviewer <<<"$FLEET_DOWN")"
t fleet-down-unreadable-lock-still-counts-as-a-wait waited \
  "$(fleet_down_outcome crew-drill-x <<<'  crew-drill-x: waiting because duty lock state is unreadable; use crew down --force to stop without draining
  crew-drill-x: stopped')"
# A box the verb waited for is also one it then stopped, so the table's waited
# row counts into both columns. Reconciled rather than asserted loosely: both
# of the verb's numbers stay checked.
t fleet-down-table-agrees-with-the-summary agree \
  "$(fleet_counts_agree down 'down: 2 stopped, 1 waited, 1 absent, 1 failed' \
    <<<'crew-drill-triage stopped
crew-drill-builder waited
crew-drill-absent absent
crew-drill-reviewer failed')"
# Must fail: a leg that graded the busy box `stopped` — the collapse this
# precedence exists to prevent — disagrees with the verb's own waited count.
t fleet-down-busy-box-graded-stopped-disagrees disagree:waited=0/1 \
  "$(fleet_counts_agree down 'down: 2 stopped, 1 waited, 1 absent, 1 failed' \
    <<<'crew-drill-triage stopped
crew-drill-builder stopped
crew-drill-absent absent
crew-drill-reviewer failed')"

# Case 3: a refusal payload carrying only a percentage is graded `unanswered`,
# never ok. #652's own test plan, in its own words.
FLEET_CUT_COMPOSED='  crew-drill-triage: armed cut at crew@0.1.3; root filesystem 41% used
  crew-drill-builder: SKIPPED busy — duty lock held for 4m 10s
  crew-drill-reviewer: REFUSED — root filesystem 93% used after reclaiming, over the 85% ceiling
      largest: /var/lib/incus 4.1G; /home/bot/duty/logs 900M
      whatever is in an armed image is the floor every later reset returns to; clear it before cutting

reset --cut: 1 cut, 1 skipped-busy, 1 failed
  failed: crew-drill-reviewer'
FLEET_CUT_PERCENTAGE_ONLY='  crew-drill-triage: armed cut at crew@0.1.3; root filesystem 41% used
  crew-drill-builder: SKIPPED busy — duty lock held for 4m 10s
  crew-drill-reviewer: REFUSED — root filesystem 93% used after reclaiming, over the 85% ceiling

reset --cut: 1 cut, 1 skipped-busy, 1 failed'
t fleet-cut-names-the-cut-box cut \
  "$(fleet_cut_outcome crew-drill-triage <<<"$FLEET_CUT_COMPOSED")"
t fleet-cut-names-the-busy-box skipped-busy \
  "$(fleet_cut_outcome crew-drill-builder <<<"$FLEET_CUT_COMPOSED")"
t fleet-cut-names-the-refused-box refused \
  "$(fleet_cut_outcome crew-drill-reviewer <<<"$FLEET_CUT_COMPOSED")"
t fleet-cut-table-agrees-with-the-summary agree \
  "$(fleet_counts_agree cut 'reset --cut: 1 cut, 1 skipped-busy, 1 failed' \
    <<<'crew-drill-triage cut
crew-drill-builder skipped-busy
crew-drill-reviewer refused')"
t fleet-refusal-with-a-composition-is-composed composed \
  "$(fleet_refusal_answer crew-drill-reviewer <<<"$FLEET_CUT_COMPOSED")"
# MUST FAIL: the same refusal with the composition line gone.
t fleet-refusal-percentage-only-is-unanswered unanswered \
  "$(fleet_refusal_answer crew-drill-reviewer <<<"$FLEET_CUT_PERCENTAGE_ONLY")"
# ...and an honest report that the composition could NOT be taken is still not
# the reading #652 asked for. Grading this `composed` would let a host whose
# boxes have no passwordless sudo tick the criterion forever without ever
# producing the figure.
t fleet-refusal-unavailable-composition-is-unanswered unanswered \
  "$(fleet_refusal_answer crew-drill-reviewer <<<'  crew-drill-reviewer: REFUSED — root filesystem 93% used after reclaiming, over the 85% ceiling
      largest: unavailable (no passwordless sudo in the box to read / as root)')"
# A refusal that names its cause in words carries its own composition.
t fleet-refusal-worded-cause-is-composed composed \
  "$(fleet_refusal_answer crew-drill-builder <<<'  crew-drill-builder: REFUSED — not logged in to GitHub (an armed checkpoint of a box without credentials restores to a box that cannot work); log it in with: box shell crew-drill-builder')"
# The backstop, on a payload that was only ever a figure.
t fleet-refusal-bare-figure-is-unanswered unanswered \
  "$(fleet_refusal_answer crew-drill-builder <<<'  crew-drill-builder: REFUSED — 93% (85%)')"
t fleet-refusal-absent-is-reported-as-such no-refusal \
  "$(fleet_refusal_answer crew-drill-triage <<<"$FLEET_CUT_COMPOSED")"
# A composition belonging to ANOTHER box cannot answer this one's refusal: the
# block ends at the next box line.
t fleet-refusal-does-not-borrow-a-neighbours-composition unanswered \
  "$(fleet_refusal_answer crew-drill-reviewer <<<'  crew-drill-reviewer: REFUSED — root filesystem 93% used after reclaiming, over the 85% ceiling
  crew-drill-triage: REFUSED — root filesystem 91% used after reclaiming, over the 85% ceiling
      largest: /var/lib/incus 4.1G')"

# Case 4: a restore that lands on `bootstrapped` MUST FAIL. #589 D4 — both
# fallbacks return a creds-free, unhired box, which is a bootstrap and not a
# maintenance, and the failure mode is that it happens SILENTLY.
t fleet-restore-to-armed-is-a-restore restored \
  "$(fleet_restore_landing crew-drill-triage armed \
    <<<'  crew-drill-triage: restored to armed (crew@0.1.3) and started')"
t fleet-restore-to-bootstrapped-fails wrong-label \
  "$(fleet_restore_landing crew-drill-triage armed \
    <<<'  crew-drill-triage: restored to bootstrapped (crew@0.1.3) and started')"
t fleet-restore-to-pristine-fails wrong-label \
  "$(fleet_restore_landing crew-drill-triage armed \
    <<<'  crew-drill-triage: restored to pristine (crew@0.1.3) and started')"
t fleet-restore-refusal-is-not-a-restore refused \
  "$(fleet_restore_landing crew-drill-triage armed \
    <<<'  crew-drill-triage: REFUSED — no armed checkpoint (crew reset --cut crew-drill-triage takes one); it is NOT rolled back to any other label')"
t fleet-restore-failure-is-not-a-restore failed \
  "$(fleet_restore_landing crew-drill-triage armed \
    <<<'  crew-drill-triage: FAILED — restore failed; the box is stopped and NOT started')"
t fleet-restore-silence-is-not-a-restore unknown \
  "$(fleet_restore_landing crew-drill-triage armed </dev/null)"

# The restored box's own first-tick evidence. Two files, because neither
# answers it alone: duty.log carries the gate's verdict and boot-check.log the
# probe it was taken from.
FLEET_BOOT_OK='== boot check 2026-09-11T12:00:00+00:00 ==
github.com
  ✓ Logged in to github.com account claude-bot
/dev/sda1  20G  8.1G  11G  43% /
cli probe: ok'
t fleet-boot-gate-passes passing \
  "$(fleet_boot_gate_reading 'boot gate: new boot id 1a2b3c4d — the box restarted since the last tick' "$FLEET_BOOT_OK")"
t fleet-boot-gate-first-tick-shape-passes passing \
  "$(fleet_boot_gate_reading 'boot gate: first tick on this box (boot id 1a2b3c4d)' "$FLEET_BOOT_OK")"
t fleet-boot-gate-auth-failure-is-a-failure failing \
  "$(fleet_boot_gate_reading 'boot gate: auth probe failed — duty continues degraded, re-checking every tick' "$FLEET_BOOT_OK")"
t fleet-boot-gate-cli-probe-failure-is-a-failure failing \
  "$(fleet_boot_gate_reading 'boot gate: new boot id 1a2b3c4d — the box restarted since the last tick' \
    '== boot check 2026-09-11T12:00:00+00:00 ==
cli probe: FAILED')"
# A gate that never ran on this boot is `unreadable` and NOT a pass: a restored
# box that never reached its gate has proved nothing, and D4 asks for the
# reading on the FIRST tick.
t fleet-boot-gate-never-ran-is-unreadable unreadable \
  "$(fleet_boot_gate_reading 'boot gate: new boot id 1a2b3c4d — the box restarted since the last tick' '')"
t fleet-boot-gate-without-a-duty-log-verdict-is-unreadable unreadable \
  "$(fleet_boot_gate_reading '' "$FLEET_BOOT_OK")"

# The leg's own fold. An empty input stays empty so the caller can say "the leg
# reached no case" rather than reporting a pass over zero assertions.
t fleet-verdict-fold-is-worst-first FAIL \
  "$(fleet_worst_verdict 'ok a
skip b
FAIL c
ok d' | awk '{print $1}')"
t fleet-verdict-fold-prefers-skip-over-ok skip \
  "$(fleet_worst_verdict 'ok a
skip b' | awk '{print $1}')"
t fleet-verdict-fold-of-nothing-is-empty '' "$(fleet_worst_verdict '')"

# --- #656: the leg's row in the round's record ------------------------------
# Case 5: a leg that returns early out of a block must report `not-executed`,
# never an absence that looks like coverage. The stub writes whatever the case
# needs to the status channel and the round's own agreement check does the rest.
cat >"$HARNESS/rehearsal-fleet.sh" <<'FLEET'
#!/usr/bin/env bash
printf 'fleet\n' >>"${DRILL_SECTION_LOG:-/dev/null}"
[ -z "${DRILL_FLEET_LOG:-}" ] || printf '%s\n' "$*" >>"$DRILL_FLEET_LOG"
[ -z "${REHEARSAL_FLEET_STATUS:-}" ] || [ -z "${DRILL_FLEET_VERDICT:-}" ] \
  || printf '%s\n' "$DRILL_FLEET_VERDICT" >>"$REHEARSAL_FLEET_STATUS"
exit "${DRILL_FLEET_RC:-0}"
FLEET
chmod +x "$HARNESS/rehearsal-fleet.sh"

fleet_round() {  # <verdict> <rc> [extra args...]
  local verdict="$1" rc="$2"; shift 2
  DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_FLEET_VERDICT="$verdict" DRILL_FLEET_RC="$rc" \
    DRILL_FLEET_LOG="${DRILL_FLEET_LOG:-}" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-app --no-config-drill --no-resume-drill --no-attention-drill \
      --no-attention-audit-drill --no-hygiene-drill --no-breaker-drill \
      --no-notify-drill "$@" 2>&1
}

: >"$ROLE_LOG"
: >"$INSTALL_LOG"
: >"$SECTION_LOG"
FLEET_OK_OUT="$(fleet_round 'ok per-box outcomes' 0)"; FLEET_OK_RC=$?
t fleet-leg-green-round-rc 0 "$FLEET_OK_RC"
t fleet-leg-green-row-is-executed 1 \
  "$(grep -c '^## leg executed fleet  (ok; per-box outcomes on restart/down/cut + restore and canary-first upgrade)' \
    <<<"$FLEET_OK_OUT")"
t fleet-leg-produces-exactly-one-result-row 1 \
  "$(grep -c '^##   .*  fleet  ' <<<"$FLEET_OK_OUT")"
t fleet-leg-is-declared 1 \
  "$(sed -n '/^declare -a DECLARED_LEGS=(/,/^)/p' "$ROOT/drill/rehearsal-all.sh" \
    | grep -cw fleet)"

# Case 5 proper: the leg ran, returned early, and wrote no verdict. The round
# must record `not-executed` with the blocker named, and must not be green.
FLEET_EARLY_OUT="$(fleet_round '' 0)"; FLEET_EARLY_RC=$?
t fleet-leg-early-return-is-incomplete 2 "$FLEET_EARLY_RC"
t fleet-leg-early-return-is-not-executed 1 \
  "$(grep -c '^## leg not-executed fleet  (INCOMPLETE; the leg reached no case — per-box outcomes UNPROVEN)' \
    <<<"$FLEET_EARLY_OUT")"

# A reading the round could not take is INCOMPLETE and never an `ok`: the
# mechanism is what this leg exists to prove, so a round that skipped a busy-box
# reading has not proved it.
FLEET_SKIP_OUT="$(fleet_round 'skip no box was held busy' 0)"; FLEET_SKIP_RC=$?
t fleet-leg-skipped-reading-is-incomplete 2 "$FLEET_SKIP_RC"
t fleet-leg-skipped-reading-names-what-was-skipped 1 \
  "$(grep -c '^## leg not-executed fleet  (INCOMPLETE; leg skipped a reading: no box was held busy)' \
    <<<"$FLEET_SKIP_OUT")"

FLEET_FAIL_OUT="$(fleet_round 'FAIL crew-drill-builder read cycled, not skipped-busy' 1)"
FLEET_FAIL_RC=$?
t fleet-leg-failure-reds-the-round 1 "$FLEET_FAIL_RC"
t fleet-leg-failure-names-the-box 1 \
  "$(grep -c '^## leg executed fleet  (FAIL; crew-drill-builder read cycled, not skipped-busy)' \
    <<<"$FLEET_FAIL_OUT")"
# A leg whose script died without a verdict is still a FAIL and not an
# INCOMPLETE: the difference is whether the round DISCOVERED a blocker or the
# leg fell over, and collapsing them would hide the second.
FLEET_CRASH_OUT="$(fleet_round '' 1)"; FLEET_CRASH_RC=$?
t fleet-leg-crash-without-a-verdict-reds 1 "$FLEET_CRASH_RC"
t fleet-leg-crash-is-recorded-as-a-failure 1 \
  "$(grep -c '^## leg executed fleet  (FAIL; the leg exited 1)' <<<"$FLEET_CRASH_OUT")"

# The operator's own exclusion is a `skip` row, and it is the ONLY shape that
# is one — the partition every other leg in this file keeps.
# The section log is reset first: it accumulates across every round above, so
# a count taken over the whole file would be answering a different question.
: >"$SECTION_LOG"
FLEET_OPTOUT_OUT="$(fleet_round 'ok unused' 0 --no-fleet-drill)"; FLEET_OPTOUT_RC=$?
t fleet-leg-opt-out-round-rc 0 "$FLEET_OPTOUT_RC"
t fleet-leg-opt-out-is-named 1 \
  "$(grep -c '^## leg not-executed fleet  (skip; --no-fleet-drill)' <<<"$FLEET_OPTOUT_OUT")"
# An opt-out that still RAN the leg would be a skip row over a real mutation of
# the host's boxes — the one row in this file where that is not merely wrong.
t fleet-leg-opt-out-does-not-invoke-the-leg 0 \
  "$(grep -cx fleet "$SECTION_LOG" || true)"

# The leg is driven from the round's OWN roster, and it runs after the app
# phase. Both are read from what the orchestrator actually passed.
DRILL_FLEET_LOG="$TMP/fleet-args.log"
: >"$DRILL_FLEET_LOG"
: >"$SECTION_LOG"
FLEET_ARGS_OUT="$(DRILL_FLEET_LOG="$DRILL_FLEET_LOG" fleet_round 'ok per-box outcomes' 0)"
t fleet-leg-is-driven-from-the-drilled-roster 1 \
  "$(grep -cFx -- '--boxes crew-drill-reviewer --agent claude --roles reviewer' "$DRILL_FLEET_LOG")"
# Exactly once. A leg invoked twice would produce two result rows, which the
# round's own agreement check reds — but it would also have cut two snapshots.
t fleet-leg-runs-exactly-once-per-round 1 "$(wc -l <"$DRILL_FLEET_LOG" | tr -d ' ')"
t fleet-leg-green-round-with-args-row 1 \
  "$(grep -c '^## leg executed fleet  (ok; ' <<<"$FLEET_ARGS_OUT")"

# No role reached a box: the leg has no roster to drive the verbs over, and
# that is a blocker the round DISCOVERED rather than one anybody asked for.
: >"$ROLE_LOG"
: >"$INSTALL_LOG"
if FLEET_NOBOX_OUT="$(DRILL_ROLE_LOG="$ROLE_LOG" DRILL_INSTALL_LOG="$INSTALL_LOG" \
    DRILL_SECTION_LOG="$SECTION_LOG" DRILL_REMOTE="$REMOTE" \
    DRILL_ROLE_STAGE=pre-install DRILL_ROLE_RC=1 \
    DRILL_FLEET_VERDICT='ok unused' \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-app --no-config-drill --no-resume-drill --no-attention-drill \
      --no-attention-audit-drill --no-hygiene-drill --no-breaker-drill \
      --no-notify-drill 2>&1)"; then
  FLEET_NOBOX_RC=0
else
  FLEET_NOBOX_RC=$?
fi
t fleet-leg-without-a-box-is-blocked-not-skipped 1 \
  "$(grep -c '^## leg not-executed fleet  (SKIPPED; blocked by role install: no installed drill box)' \
    <<<"$FLEET_NOBOX_OUT")"
t fleet-leg-without-a-box-keeps-the-round-red 1 "$FLEET_NOBOX_RC"

# The runbook documents it, in both directions, through the same derivation the
# #497 guard above uses rather than a third list maintained here.
t fleet-leg-is-documented-in-the-runbook 1 \
  "$(runbook_documented_legs | grep -cx fleet)"
t fleet-leg-is-in-the-runbook-prose 1 \
  "$(runbook_prose_legs | grep -cx fleet)"

suite_finish
