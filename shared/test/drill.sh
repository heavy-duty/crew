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
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then tree_rc=0; else tree_rc=$?; fi
t drill-tree-round-rc 0 "$tree_rc"
t drill-tree-role-ships-head "$SECOND" "$(awk '{print $4}' "$ROLE_LOG")"
t drill-tree-installer-ships-head "$SECOND" "$(awk '{print $4}' "$INSTALL_LOG")"
t drill-tree-record-names-head 1 \
  "$(grep -cF "## drilled source: $SECOND (tree $SOURCE)" <<<"$tree_out")"
t drill-tree-phase-zero-names-head 1 \
  "$(grep -cF "phase 0: crew at $SECOND (tree $SOURCE), static checks" <<<"$tree_out")"
t drill-record-enumerates-all-declared-legs 12 \
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
  phase2_rc=0
else
  phase2_rc=$?
fi
t drill-phase2-failure-stays-red 1 "$phase2_rc"
t drill-phase2-failure-reports-role 1 \
  "$(grep -cF 'FAIL       reviewer  (phase 2 failed)' <<<"$phase2_out")"
t drill-phase2-failure-runs-section-a 1 \
  "$(grep -cF 'ok         installer  (Section A record emitted)' <<<"$phase2_out")"
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

# The third historical zero-execution leg also records a discovered host
# blocker rather than disappearing inside app's aggregate result.
if browser_skip_out="$(DRILL_ROLE_LOG="$ROLE_LOG" \
    DRILL_INSTALL_LOG="$INSTALL_LOG" DRILL_SECTION_LOG="$SECTION_LOG" \
    DRILL_BROWSER_STATUS=skip DRILL_REMOTE="$REMOTE" \
    bash "$HARNESS/rehearsal-all.sh" --tree "$SOURCE" --roles reviewer --keep \
      --no-resume-drill --no-attention-drill --no-attention-audit-drill \
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-hygiene-drill --no-breaker-drill --no-notify-drill 2>&1)"; then
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
      --no-breaker-drill --no-notify-drill 2>&1)"; then :; fi
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

t drill-runbook-harness-declares-legs 12 "$(runbook_harness_legs | n)"
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
sed 's/^  installer config app browser app-armed teardown$/  installer config app browser app-armed teardown newleg/' \
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

suite_finish
