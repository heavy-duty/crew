#!/usr/bin/env bash
# test/run.sh — fixture tests for the duty engine's pure logic. No gh, no
# network: everything here runs on bash+jq alone, in CI and on any box.
#
# These exist because three of five bots' self-assessments asked for exactly
# this ("fixture tests for detection predicates", "contract tests for the
# duty scripts", "plumbing one-liners deserve tests") and because the
# corpus-shaped blocker fixtures encode postmortem lesson 9: the parser must
# tolerate real issue-body prose, not parser-shaped strings.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(dirname "$HERE")"
ROOT="$(dirname "$SHARED")"
PASS=0 FAIL=0

t() {  # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

# Source common.sh against a scratch DUTY_DIR.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck disable=SC1091
source "$SHARED/lib/common.sh"

# --- read_repo_list: comments (incl. inline), blanks, whitespace, missing
# trailing newline
printf '# a comment\nheavy-duty/ceremony\n\n  heavy-duty/rig  # inline note\n# tail\nheavy-duty/incubator' >"$TMP/repos.txt"
t repo-list "heavy-duty/ceremony
heavy-duty/rig
heavy-duty/incubator" "$(read_repo_list "$TMP/repos.txt")"
t repo-list-missing "" "$(read_repo_list "$TMP/nope.txt")"

# --- render_prompt: multiple slots, repeated slots, untouched unknowns
mkdir -p "$TMP/prompts"
printf 'You are {{ME}} in {{REPO}}; {{ME}} again; {{UNSET}} stays.' >"$TMP/prompts/x.txt"
t render "You are bot in o/r; bot again; {{UNSET}} stays." \
  "$(render_prompt x.txt ME=bot REPO=o/r)"

# --- has_role
# shellcheck disable=SC2034  # consumed by has_role inside sourced common.sh
BOT_ROLES="builder reviewer"
has_role builder && r1=yes || r1=no
has_role triage && r2=yes || r2=no
t has-role-yes yes "$r1"
t has-role-no no "$r2"

# --- agent profiles and rehearsal selection -----------------------------
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; type bot_cli_probe >/dev/null; test -n "$AGENT_LOGIN_HINT"' _ "$profile"; then
    r1=sourceable
  else
    r1=broken
  fi
  t "agent-conf-$agent-standalone" sourceable "$r1"
done

if unknown_out="$(bash "$ROOT/drill/rehearsal.sh" --agent nosuchagent 2>&1)"; then
  unknown_rc=0
else
  unknown_rc=$?
fi
t rehearsal-unknown-agent-rc 1 "$unknown_rc"
case "$unknown_out" in
  *"unknown agent 'nosuchagent'"*"claude"*"codex"*"grok"*"kimi"*) r1=listed ;;
  *) r1=missing ;;
esac
t rehearsal-unknown-agent-list listed "$r1"

# --- install.sh: crontab preflight and convergence (#25) ----------------
# A curated PATH makes "crontab absent" deterministic even on a workstation
# that happens to have cron installed. Everything install.sh legitimately
# needs is linked in; gh and git are fixture shims.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
for cmd in awk bash basename cat chmod cp date dirname grep head mkdir mktemp mv rm sed sha256sum tr wc; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
# If install.sh ever infers from hostname again, make the regression reproduce
# the dangerous case deterministically rather than depend on this test host.
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

install_fixture() {
  env HOME="$IHOME" DUTY_DIR="$IDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}

if install_out="$(install_fixture 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-no-arm-rc 0 "$r1"
case "$install_out" in *"REPLACE the crontab"*) r1=manual ;; *) r1=missing ;; esac
t install-no-cron-no-arm-instructions manual "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-no-arm-clean clean "$r1"
t install-version-with-provenance \
  "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" "$(head -1 "$IDUTY/VERSION")"

# The installed package shape has no .git. Run that actual shape, rather than
# trusting the Git shim used by the rest of the installer fixtures.
GITLESS_ROOT="$TMP/gitless-crew"
GITLESS_HOME="$TMP/gitless-home"
mkdir -p "$GITLESS_ROOT" "$GITLESS_HOME"
cp -R "$SHARED" "$GITLESS_ROOT/shared"
cp -R "$ROOT/examples" "$GITLESS_ROOT/examples"
cp "$ROOT/VERSION" "$GITLESS_ROOT/VERSION"
if FIXTURE_GITLESS=1 HOME="$GITLESS_HOME" DUTY_DIR="$GITLESS_HOME/duty" \
  PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$GITLESS_ROOT/shared/install.sh" --agent claude --role reviewer \
  >"$TMP/gitless-install.out" 2>&1; then r1=0; else r1=$?; fi
t install-gitless-rc 0 "$r1"
t install-gitless-stamps-version \
  "crew@$(head -1 "$ROOT/VERSION")" "$(head -1 "$GITLESS_HOME/duty/VERSION")"
case "$(head -1 "$GITLESS_HOME/duty/VERSION")" in
  *unknown*) r1=unknown ;;
  *) r1=versioned ;;
esac
t install-gitless-never-unknown versioned "$r1"

printf '15 3 * * * unrelated-job\n' >"$CRON_STATE"
before_cron="$(cat "$CRON_STATE")"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-arm-rc 1 "$r1"
case "$install_out" in
  *"engine installed, but cron is not armed"*"administrator"*"sudo apt-get install cron"*"install.sh --arm-cron"*) r1=actionable ;;
  *) r1=missing ;;
esac
t install-no-cron-arm-message actionable "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-arm-attributed clean "$r1"
t install-no-cron-arm-untouched "$before_cron" "$(cat "$CRON_STATE")"
[ -f "$IDUTY/VERSION" ] && r1=installed || r1=missing
t install-no-cron-arm-files-remain installed "$r1"

# shellcheck disable=SC2016  # fixture script expands these at execution time
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -l) [ ! -f "$CRON_STATE" ] || cat "$CRON_STATE" ;;\n  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\n  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\nesac\n' >"$ISHIM/crontab"
chmod +x "$ISHIM/crontab"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-with-cron-arm-rc 0 "$r1"
case "$install_out" in *"crontab armed"*) r1=armed ;; *) r1=missing ;; esac
t install-with-cron-arm-output armed "$r1"
t install-with-cron-preserves-existing 1 "$(grep -cF 'unrelated-job' "$CRON_STATE")"
t install-with-cron-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"
install_fixture --arm-cron >/dev/null 2>&1
t install-with-cron-rerun-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"

# --- install.sh: fleet.roster is the one agent/role declaration (#35) ----
RHOME="$TMP/roster-home"
RDUTY="$RHOME/duty"
mkdir -p "$RHOME"
roster_install() {
  env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-hire-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-upgrade-keeps-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
t install-roster-agent 'BOT_AGENT=claude' "$(grep '^BOT_AGENT=' "$RDUTY/conf/instance.conf")"

# Flagless means preserve, never infer from a production-looking hostname.
roster_install --agent claude --role reviewer >/dev/null 2>&1
roster_install >/dev/null 2>&1
t install-flagless-keeps-explicit-role 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

while read -r roster_box roster_agent roster_role _roster_from; do
  roster_install --box "$roster_box" >/dev/null 2>&1
  hire_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  roster_install --box "$roster_box" >/dev/null 2>&1
  upgrade_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  t "install-hire-upgrade-stable-$roster_box" "$hire_conf" "$upgrade_conf"
  t "install-roster-declares-$roster_box" \
    "BOT_AGENT=$roster_agent
BOT_ROLES=\"$roster_role\"" "$upgrade_conf"
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/examples/fleet.roster")

# A roster staged by the host beats the shipped fallback.
printf 'claude-builder claude reviewer\n' >"$RDUTY/fleet.roster"
roster_install --box claude-builder >/dev/null 2>&1
t install-staged-roster-wins 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

# Operator config and untouched registries converge; local divergence vetoes.
printf 'FLEET_HUMAN="fixture-human"\nMARK_PICKUP="not-the-protocol"\n' >"$RDUTY/conf/fleet.conf"
rm -f "$RDUTY/repos.txt" "$RDUTY/notify-repos.txt"
printf 'fixture/first\n' >"$RDUTY/.crew-seed-repos.txt"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-operator-conf-transport 'FLEET_HUMAN="fixture-human"' \
  "$(grep '^FLEET_HUMAN=' "$RDUTY/conf/fleet.conf")"
t install-registry-first-convergence fixture/first "$(cat "$RDUTY/repos.txt")"
t install-builder-notify-triage-only absent \
  "$([ -f "$RDUTY/notify-repos.txt" ] && printf present || printf absent)"
t install-seed-payload-discarded absent \
  "$([ -e "$RDUTY/.crew-seed-repos.txt" ] || [ -e "$RDUTY/.crew-seed-notify-repos.txt" ] && printf present || printf absent)"

printf 'fixture/second\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-converges-untouched fixture/second "$(cat "$RDUTY/repos.txt")"
printf 'fixture/contained\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
veto_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-vetoes-divergence fixture/contained "$(cat "$RDUTY/repos.txt")"
case "$veto_out" in *"claude-builder: repos.txt diverged"*"LEFT UNCHANGED"*) r1=named ;; *) r1=silent ;; esac
t install-registry-veto-is-loud named "$r1"

# The documented adoption path must work even when provenance records the
# older transported value: manually matching the incoming bytes adopts it.
printf 'fixture/third\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
adopt_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-adopts-manual-match fixture/third "$(cat "$RDUTY/repos.txt")"
case "$adopt_out" in *"adopted and converged"*) r1=adopted ;; *) r1=missing ;; esac
t install-registry-adoption-is-visible adopted "$r1"

# A current-fleet copy matching the shipped example can be adopted without
# provenance; an unknown local copy cannot.
rm -f "$RDUTY/.repos.txt.crew-provenance"
cp "$ROOT/examples/repos.txt" "$RDUTY/repos.txt"
printf 'fixture/migrated\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-adopts-example fixture/migrated "$(cat "$RDUTY/repos.txt")"
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/unknown-local\n' >"$RDUTY/repos.txt"
printf 'fixture/incoming\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-vetoes-unknown fixture/unknown-local "$(cat "$RDUTY/repos.txt")"

runtime_fleet="$(DUTY_DIR="$RDUTY" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s|%s" "$FLEET_HUMAN" "$MARK_PICKUP"')"
t install-loads-defaults-then-operator 'fixture-human|📌 picked up' "$runtime_fleet"
# MARK_HANDOFF is a protocol mark like the others: an operator fleet.conf must
# not be able to override it (post-once.sh's dedup keys on the first line, so a
# drifted mark would silently double-post the handoff). Same wire-pin (#91).
printf 'MARK_HANDOFF="not-the-protocol"\n' >>"$RDUTY/conf/fleet.conf"
t handoff-mark-wire-pinned '🤝 handed off at head' \
  "$(DUTY_DIR="$RDUTY" bash -c '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s" "$MARK_HANDOFF"')"
printf 'claude-builder claude triage\n' >"$RDUTY/fleet.roster"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-triage-notify-seed fixture/wide "$(cat "$RDUTY/notify-repos.txt")"

if grep -Rsiqw 'manifest' "$SHARED/docs" "$SHARED/README.md" "$SHARED/conf" \
    "$SHARED/lib" "$SHARED/install.sh" "$ROOT/examples/fleet.roster" "$ROOT/cli/crew" \
    "$ROOT/drill"; then
  r1=DUPLICATED
else
  r1=single-source
fi
t install-no-second-role-registry single-source "$r1"
if grep -q -- "--box '\$b'" "$ROOT/cli/crew" || grep -q "install_identity_args.*\\\$b" "$ROOT/cli/crew"; then
  r1=box-keyed
else
  r1=UNKEYED
fi
t upgrade-passes-roster-box-key box-keyed "$r1"

# --- crew upgrade --all is roster-scoped, not host-wide (#37) ------------
# `--all` used to mean box_names(): every box on the host, each installed
# with --arm-cron. That reached off-roster boxes -- a drill box between runs
# carries a real identity and a production registry and is deliberately
# disarmed -- and armed them by routine maintenance.
UROSTER="$TMP/upgrade-roster"
printf '# comment\nclaude-triage    claude  triage\nclaude-builder   claude  builder\n\n' >"$UROSTER"
roster_names_fixture() { grep -vE '^[[:space:]]*(#|$)' "$UROSTER" | awk '{print $1}'; }
host_boxes_fixture() { printf 'claude-triage\ncrew-drill-reviewer\nclaude-builder\nsome-other-box\n'; }
t upgrade-roster-names "claude-triage
claude-builder" "$(roster_names_fixture)"
t upgrade-targets-are-roster-and-host "claude-builder
claude-triage" \
  "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))"
t upgrade-skips-off-roster "crew-drill-reviewer
some-other-box" \
  "$(comm -23 <(host_boxes_fixture | sort) <(roster_names_fixture | sort))"
# The drill box is the case that matters: present on the host, absent from
# the roster, and therefore never touched by --all.
case "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))" in
  *crew-drill*) r1=reached ;; *) r1=untouched ;;
esac
t upgrade-never-reaches-drill-box untouched "$r1"

# --- duty.sh lock sentinel: 199 AND the message --------------------------
# A bare non-zero `flock` under `set -euo pipefail` exited duty.sh AT the
# flock line, so the 199 branch never ran and a contended manual invocation
# printed nothing at all. Both halves are asserted: the exit code alone was
# always correct, which is why this survived unnoticed — only the drill's
# "lock contention -> 199 + message" check saw the silence.
LHOME="$TMP/lock-home"
mkdir -p "$LHOME"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$SHARED/install.sh" --agent claude --role reviewer >/dev/null 2>&1
flock -n "$LHOME/duty/.duty.lock" -c 'sleep 3' >/dev/null 2>&1 &
lock_bg=$!
sleep 1
if lock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/duty.sh" 2>&1)"; then
  lock_rc=0
else
  lock_rc=$?
fi
wait "$lock_bg" 2>/dev/null || true
t duty-lock-sentinel-rc 199 "$lock_rc"
case "$lock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t duty-lock-sentinel-message message "$r1"

# --- count predicates must fail CLOSED on empty and on error output ------
# `grep -qv '^0$'` reads as "the count is not zero", but -v selects lines
# that do NOT match, so it returns 0 for EMPTY input and for gh's error JSON
# — the check went green when the API call failed. Same defect class as the
# null check in #29: a predicate whose failure mode looks like success.
for _in in '' '0' '{"message":"Not Found","status":"404"}'; do
  if printf '%s' "$_in" | grep -qE '^[1-9][0-9]*$'; then r1=passed; else r1=refused; fi
  t "count-predicate-refuses-${_in:-empty}" refused "$r1"
done
if printf '3' | grep -qE '^[1-9][0-9]*$'; then r1=passed; else r1=refused; fi
t count-predicate-accepts-real-count passed "$r1"
# The shape it replaced, pinned so nobody reintroduces it. Uses gh's error
# JSON, not empty input: -v on an empty stream is shell/grep dependent, but
# ANY non-"0" line — which is what a failed gh call prints to stdout — makes
# the old predicate return 0. That is the realistic failure and it is
# deterministic everywhere.
if printf '%s' '{"message":"Not Found","status":"404"}' | grep -qv '^0$'; then r1=fail-open; else r1=fail-closed; fi
t count-predicate-old-shape-was-fail-open fail-open "$r1"

# --- notify.sh lock sentinel: same set -e trap as duty.sh (#30) ----------
# duty.sh was fixed for this; notify.sh has the identical preamble and was
# missed. Asserted the same way: the exit code alone was always right, so
# only the message distinguishes fixed from broken.
flock -n "$LHOME/duty/.notify.lock" -c 'sleep 3' >/dev/null 2>&1 &
nlock_bg=$!
sleep 1
if nlock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/notify.sh" 2>&1)"; then
  nlock_rc=0
else
  nlock_rc=$?
fi
wait "$nlock_bg" 2>/dev/null || true
t notify-lock-sentinel-rc 199 "$nlock_rc"
case "$nlock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t notify-lock-sentinel-message message "$r1"

# --- attention label predicate: never let a null reach the shell ---------
# `gh api --jq` prints NOTHING for a null result (real jq prints "null"), so
# `index("attention") | grep -q null` matched in NEITHER state: present
# emitted "0", absent emitted "". The predicate must emit a token both ways.
t label-predicate-gone    true  "$(printf '{"labels":[]}\n' | jq -r '[.labels[].name] | index("attention") == null')"
t label-predicate-present false "$(printf '{"labels":[{"name":"attention"}]}\n' | jq -r '[.labels[].name] | index("attention") == null')"

# --- rehearsal safety: isolate, fail closed, restore, disarm (#26) -------
RHOME="$TMP/rehearsal-home"
RDUTY="$RHOME/duty"
RCRON="$TMP/rehearsal-crontab"
mkdir -p "$RDUTY"
printf 'heavy-duty/ceremony\nheavy-duty/incubator\nheavy-duty/rig\n' >"$RDUTY/repos.txt"
printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$RDUTY" >"$RCRON"
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
BOX_NAME=fixture
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
REPOS_BACKUP=""
BX_FAIL_WRITE=0
bx() {
  case "$1" in
    "printf "*" > ~/duty/repos.txt") [ "$BX_FAIL_WRITE" -eq 0 ] || return 1 ;;
  esac
  HOME="$RHOME" PATH="$ISHIM" CRON_STATE="$RCRON" bash -c "$1"
}
# shellcheck source=drill/rehearsal-safety.sh
source "$ROOT/drill/rehearsal-safety.sh"

rehearsal_begin_isolation && r1=isolated || r1=failed
t rehearsal-isolates-before-tick isolated "$r1"
t rehearsal-isolation-empty 0 "$(wc -l <"$RDUTY/repos.txt")"
rehearsal_narrow_to_sandbox owner/sandbox && r1=narrowed || r1=failed
t rehearsal-narrow-success narrowed "$r1"
t rehearsal-narrow-exact owner/sandbox "$(cat "$RDUTY/repos.txt")"
BX_FAIL_WRITE=1
rehearsal_narrow_to_sandbox owner/other && r1=continued || r1=refused
t rehearsal-narrow-fails-closed refused "$r1"
BX_FAIL_WRITE=0
rehearsal_cleanup 0
t rehearsal-restores-registry "heavy-duty/ceremony
heavy-duty/incubator
heavy-duty/rig" "$(cat "$RDUTY/repos.txt")"
t rehearsal-disarms-tick 0 "$(grep -cF "$RDUTY/bin/tick.sh" "$RCRON")"
t rehearsal-preserves-unrelated-cron 1 "$(grep -cF unrelated-job "$RCRON")"

# --- rehearsal phase 0: acquisition failures abort before checks (#27) --
P0SHIM="$TMP/phase0-bin"
P0HOME="$TMP/phase0-home"
P0LOG="$TMP/phase0-box.log"
mkdir -p "$P0SHIM" "$P0HOME"
# shellcheck disable=SC2016  # fixture expands state at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0LOG"\ncase "$1" in\n  list) printf "[]\\n" ;;\n  new|exec) exit 0 ;;\n  *) exit 2 ;;\nesac\n' >"$P0SHIM/box"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0SHIM/gh"
chmod +x "$P0SHIM/box" "$P0SHIM/gh"

if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$TMP/no-such-remote" \
    --ref nosuchbranch --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-bad-ref-rc 1 "$r1"
case "$p0out" in *"remote '$TMP/no-such-remote'"*"ref 'nosuchbranch'"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-bad-ref-attributed attributed "$r1"
t rehearsal-bad-ref-no-tick 0 "$(grep -cF 'exec crew-drill -- bash -lc ~/duty/bin/tick.sh' "$P0LOG" || true)"
case "$p0out" in *"fixture tests green"*|*"FAIL install"*) r1=cascaded ;; *) r1=stopped ;; esac
t rehearsal-bad-ref-no-cascade stopped "$r1"

BADTREE="$TMP/bad-tree"
mkdir -p "$BADTREE"
git -C "$BADTREE" init -q
printf 'not the engine\n' >"$BADTREE/README.md"
git -C "$BADTREE" add README.md
git -C "$BADTREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$BADTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-invalid-tree-rc 1 "$r1"
case "$p0out" in *"shared/install.sh"*"missing"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-invalid-tree-attributed attributed "$r1"

# --- validate_sha
validate_sha "0123456789abcdef0123456789abcdef01234567" && r1=ok || r1=bad
validate_sha "0123456" && r2=ok || r2=bad
validate_sha "g123456789abcdef0123456789abcdef01234567" && r3=ok || r3=bad
t sha-full ok "$r1"
t sha-short bad "$r2"
t sha-nonhex bad "$r3"

# --- blockers.jq: corpus-shaped fixtures --------------------------------
BJQ="$SHARED/lib/jq/blockers.jq"
S='{"5":"CLOSED","6":"MERGED","10":"CLOSED","7":"OPEN"}'

# The canonical body shape from the triage contract, all blockers landed —
# including one inside the clause's parentheses; "Blocks #13" is the inverse
# relation and must not parse.
b1='[{"number":21,"body":"Part of #1. Blocked by #5, #6 (and #10 for the bootstrap). Blocks #13 (needs a tag)."}]'
t blockers-landed "21" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b1")"

# One blocker still open → stays blocked.
b2='[{"number":22,"body":"Blocked by #5 and #7."}]'
t blockers-open "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b2")"

# Unknown number → fail-safe: counts as still-open.
b3='[{"number":23,"body":"Blocked by #999."}]'
t blockers-unknown "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b3")"

# Cross-repo blocker must NOT resolve against the local number map — triage
# flips those by hand (TRIAGE.md). #5 is CLOSED locally, but this "#5" is
# other-org/other-repo#5.
b4='[{"number":24,"body":"Blocked by other-org/other-repo#5."}]'
t blockers-crossrepo "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b4")"

# Lowercase clause, sentence-final stop honored: #7 after the period is not
# part of the clause.
b5='[{"number":25,"body":"blocked by #5. Also mentions #7 later."}]'
t blockers-lowercase "25" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b5")"

# No clause at all → no lead.
b6='[{"number":26,"body":"Depends on vibes."},{"number":27,"body":null}]'
t blockers-none "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b6")"

# Two issues, one unblockable → only that one reported.
b7='[{"number":28,"body":"Blocked by #5."},{"number":29,"body":"Blocked by #7."}]'
t blockers-mixed "28" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b7")"

# --- converged.jq: handoff predicate ------------------------------------
CJQ="$SHARED/lib/jq/converged.jq"
PANEL='["rev-a","rev-b"]'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
REVS_STALE='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]'

t converged-true true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-outstanding-req false \
  "$(mk_pr "$H" MERGEABLE '[]' '["rev-b"]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-offpanel-req-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '["danmt"]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-stale-approval false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_STALE" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-already-handed false \
  "$(mk_pr "$H" MERGEABLE '["state:needs-human"]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-unknown-mergeable defer-unknown \
  "$(mk_pr "$H" UNKNOWN '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
t converged-conflicting false \
  "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_OK" | jq -r --argjson panel "$PANEL" --arg needs_human state:needs-human -f "$CJQ")"
# An empty panel must never converge vacuously (bare panel= line).
t converged-empty-panel false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --arg needs_human state:needs-human -f "$CJQ")"

# --- addressing.jq: round-close predicate, the MIRROR of converged.jq (#130) --
# Same payload builder (mk_pr), same panel, same head-scoping — the point is
# that the two predicates agree on every input and differ only in the
# conclusion. Reuses H / REVS_OK from the converged block above.
AJQ="$SHARED/lib/jq/addressing.jq"
OLDH="cccccccccccccccccccccccccccccccccccccccc"
# A closed round without full approval: rev-a requests changes AT the head,
# rev-b approves AT the head. Every panelist opinionated, one is not an approval.
REVS_ADDR='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
# The ceremony#136 mixed round: one approval staled by a push (rev-a at an OLD
# head), the other panelist yet to review at all. NOT closed — still awaiting.
REVS_MIXED_OPEN='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
addr() { jq -r --argjson panel "$PANEL" --arg addressing state:addressing -f "$AJQ"; }

# The core: a landed non-approving verdict with the whole panel opinionated at
# the head → state:addressing. This is the exact inverse of converged-true.
t addressing-closed-without-approval true "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR" | addr)"
# All approved at head → converged, NOT addressing (the two never both fire).
t addressing-all-approved-is-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | addr)"
# The #136 mixed round: a stale approval + an unreviewed panelist is a round
# still OPEN (bots-reviewing), not a closed one — addressing must not fire.
t addressing-mixed-open-round-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_MIXED_OPEN" | addr)"
# A stale approval + a head change-request (rev-a CR@head, rev-b approved OLD
# head) is not all-reviewed-at-head → not closed yet.
REVS_ADDR_STALE='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
t addressing-not-all-at-head-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR_STALE" | addr)"
# Idempotent: the label already stands → writes nothing (re-tick no-op).
t addressing-already-set-false false "$(mk_pr "$H" MERGEABLE '["state:addressing"]' '[]' "$REVS_ADDR" | addr)"
# A live panel request means the round is still open — do not stamp addressing
# over a head that was just (re-)requested; the reconciler would flip it back.
t addressing-live-request-false false "$(mk_pr "$H" MERGEABLE '[]' '["rev-a"]' "$REVS_ADDR" | addr)"
# An empty panel never closes a round vacuously (mirror of converged-empty-panel).
t addressing-empty-panel-false false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --arg addressing state:addressing -f "$AJQ")"
# Mergeability is irrelevant to addressing: a conflicting PR can still owe a fix.
t addressing-conflicting-still-addresses true "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_ADDR" | addr)"

# --- #130 must-fail guards (the issue's test plan, addressing-scoped) ---------
# The engine write is optimistic, the reconciler authoritative: nothing in the
# addressing path may gate a verdict or write a state it does not own.
# state:addressing must never be written before the verdict lands, and the write
# is best-effort — the marker is the `|| warn` trailing the add-label.
if grep -q '_mark_addressing' "$SHARED/lib/duty-review.sh"; then r1=wired; else r1=MISSING; fi
t addressing-wired-after-verdict wired "$r1"
# shellcheck disable=SC2016  # the grep literal contains $LABEL_ADDRESSING on purpose
if grep -q 'could not set \$LABEL_ADDRESSING' "$SHARED/lib/duty-review.sh"; then r1=best-effort; else r1=GATING; fi
t addressing-write-is-best-effort best-effort "$r1"
# The addressing writer never touches state:building (out of scope) or
# state:needs-human (the handoff's, not the reviewer's).
if grep -RIn 'state:building' "$SHARED/lib/duty-review.sh" >/dev/null 2>&1; then r1=WRITES-IT; else r1=absent; fi
t addressing-never-writes-state-building absent "$r1"
# The predicate keys approvals/reviews on the head, same as converged.jq — a
# stale verdict at an old head is not a closed round.
# shellcheck disable=SC2016  # the jq literal contains $pr.headRefOid
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/addressing.jq"; then r1=head-keyed; else r1=CHANGED; fi
t addressing-keys-on-head head-keyed "$r1"

# --- #133: engine (re-)requests the panel, keyed off the session's SIGNAL -----
# Two fixtures + the structural gates. request-panel.jq answers "whom, given the
# engine already holds the licence"; answered-head.jq is that licence — the head
# the session last signalled — and the engine acts only when it equals the
# current head, never on commit activity (#133's hardest must-fail).
RPJQ="$SHARED/lib/jq/request-panel.jq"
AHJQ="$SHARED/lib/jq/answered-head.jq"
RP_OLD="dddddddddddddddddddddddddddddddddddddddd"
RP_MARK="📣 round answered at head"
# payload builder carrying comments (the signal lives there), reviewRequests and
# latestOpinionatedReviews. Reuses H from the converged block.
mk_rp() {  # <head> <reqs-json> <revs-json> <comments-json>
  jq -n --arg head "$1" --argjson reqs "$2" --argjson revs "$3" --argjson coms "$4" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head,
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs},
      comments:{nodes:$coms}}}}}'
}
rp() { jq -r --argjson panel "$PANEL" -f "$RPJQ" | tr '\n' ' ' | sed 's/ $//'; }
ah() { jq -r --arg me me-bot --arg mark "$RP_MARK" -f "$AHJQ"; }
RP_CR_AT_HEAD='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
RP_STALE_BOTH='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$RP_OLD'"}},{"author":{"login":"rev-b"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'

# request-panel.jq — whom to request once licensed.
t rp-first-round-requests-all "rev-a rev-b" "$(mk_rp "$H" '[]' '[]' '[]' | rp)"
# The no-push half #133 exists for: a change-request AT the current head is
# re-requested (the builder answered with argument), the head approver is not.
t rp-no-push-cr-at-head-requests-cr-er "rev-a" "$(mk_rp "$H" '[]' "$RP_CR_AT_HEAD" '[]' | rp)"
t rp-converged-requests-none "" "$(mk_rp "$H" '[]' "$REVS_OK" '[]' | rp)"
# Head moved: every prior review is stale → all re-requested, approvers included.
t rp-head-moved-requests-all "rev-a rev-b" "$(mk_rp "$H" '[]' "$RP_STALE_BOTH" '[]' | rp)"
t rp-already-requested-none "" "$(mk_rp "$H" '["rev-a","rev-b"]' "$RP_STALE_BOTH" '[]' | rp)"
# Never triage: the request derives only from $panel, so an off-panel identity
# (dan-claude-bot) that left a review or a request cannot be returned.
RP_TRIAGE_REV='[{"author":{"login":"dan-claude-bot"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'
t rp-never-targets-triage "rev-a rev-b" "$(mk_rp "$H" '["dan-claude-bot"]' "$RP_TRIAGE_REV" '[]' | rp)"

# answered-head.jq — the signal. This is the WIP-safety property: a mid-fix push
# moves the head away from the last signalled one, so the engine holds.
RP_SIG_H='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
RP_SIG_OLD='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"}]'
RP_SIG_TWO='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"},{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-signal-at-head "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_H" | ah)"
t ah-no-signal-empty "" "$(mk_rp "$H" '[]' '[]' '[]' | ah)"
t ah-latest-signal-wins "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO" | ah)"
# The must-fail made concrete: a WIP push after the last signal (signal at OLD,
# head now H) yields a signalled head != current head, so the engine's
# `answered_head = gql_head` gate is false — it does NOT request. No commit
# inference.
t ah-wip-push-stales-signal "$RP_OLD" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OLD" | ah)"
# Another user's MARK_ANSWERED is not my signal.
RP_SIG_OTHER='[{"author":{"login":"someone"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-other-user-signal-ignored "" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OTHER" | ah)"

# Structural gates (#133 test plan, must-fails).
# The engine acts on the signal, not commits: _request_panel gates on
# answered-head == current head before requesting.
# shellcheck disable=SC2016  # the grep literal contains $gql_head on purpose
if grep -q 'answered-head.jq' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'answered_head" != "\$gql_head"' "$SHARED/lib/duty-builder.sh"; then r1=signal-gated; else r1=UNGATED; fi
t engine-request-requires-signal signal-gated "$r1"
# Green-head precondition, mechanical half only: request on green|none, hold else.
# shellcheck disable=SC2016  # the shell literal contains $check_state
if grep -q 'green|none)' "$SHARED/lib/duty-builder.sh"; then r1=green-gated; else r1=UNGATED; fi
t engine-request-green-gated green-gated "$r1"
# Drafts excluded: the request rides the my_open list, built non-draft.
# shellcheck disable=SC2016
if grep -q 'select(.isDraft | not)' "$SHARED/lib/duty-builder.sh"; then r1=draft-excluded; else r1=EXPOSED; fi
t engine-request-excludes-drafts draft-excluded "$r1"
# bots-reviewing is best-effort (|| warn), never gating.
# shellcheck disable=SC2016
if grep -q 'could not set \$LABEL_BOTS_REVIEWING' "$SHARED/lib/duty-builder.sh"; then r1=best-effort; else r1=GATING; fi
t engine-bots-reviewing-best-effort best-effort "$r1"
# MARK_ANSWERED is defined and wire-protected against operator override.
if grep -q '^MARK_ANSWERED=' "$SHARED/conf/fleet.defaults.conf" \
  && grep -q 'wire_answered' "$SHARED/lib/common.sh"; then r1=wire; else r1=UNPROTECTED; fi
t mark-answered-is-wire-protocol wire "$r1"
# The session posts the signal and no longer requests; the argued-exception and
# the resume re-signal survive.
if grep -q 'MARK_ANSWERED' "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'YOU DO NOT REQUEST' "$SHARED/prompts/fragment-round-rules.txt"; then r1=signals; else r1=STILL-REQUESTS; fi
t round-rules-session-signals signals "$r1"
if grep -qi 'argued exception' "$SHARED/prompts/fragment-round-rules.txt"; then r1=kept; else r1=LOST; fi
t round-rules-argued-exception-kept kept "$r1"
if grep -qi 'round-answered signal' "$SHARED/prompts/resume.txt"; then r1=resignals; else r1=MISSING; fi
t resume-re-signals-after-death resignals "$r1"

# THE ROUND-1 FIX (codex/grok/kimi): the ready→signal death window. The cure is
# ordering — SIGNAL THEN READY, with the signal posted while the PR is still a
# DRAFT (harmless, the engine ignores drafts), so every death lands where resume
# recovers it. Pinned structurally, not by prose grep, in both prompts that flip
# a draft to ready.
for p in build.txt resume.txt; do
  if grep -qiE 'signal[^.]*then[^.]*mark the PR ready-for-review' "$SHARED/prompts/$p"; then r1=signal-first; else r1=WRONG-ORDER; fi
  t "signal-before-ready-$p" signal-first "$r1"
done
# End-to-end of the covered transition: a PR flipped ready with the signal
# already at its head → the engine requests (die-after-ready is safe). The
# die-before-ready arm is a still-draft PR, excluded by my_open
# (engine-request-excludes-drafts) and recovered by resume — proven above.
RP_READY_SIGNALLED="$(mk_rp "$H" '[]' '[]' "$RP_SIG_H")"
t strand-fix-ready-with-signal-requests "rev-a rev-b" "$(printf '%s' "$RP_READY_SIGNALLED" | rp)"
t strand-fix-ready-with-signal-has-signal "$H" "$(printf '%s' "$RP_READY_SIGNALLED" | ah)"
# rebase.txt aligns with the engine: it posts the signal, it does not re-request.
if grep -qi 'MARK_ANSWERED' "$SHARED/prompts/rebase.txt" \
  && ! grep -qi 're-request every panel reviewer' "$SHARED/prompts/rebase.txt"; then r1=aligned; else r1=RACES; fi
t rebase-posts-signal-not-request aligned "$r1"

# --- round-log.jq: mirror each whole round into the PR body (#91) ------------
# Input is the GraphQL pullRequest payload; output is the NEW body when a round
# is un-recorded, or "" when every round is already marked (the crash-retry
# no-op). A round is a head SHA with an opinionated verdict; its reply is the
# author's comments after that round's newest verdict and before the next
# round's first. Each entry is keyed `<!-- round:<sha> -->` for idempotency.
RLJQ="$SHARED/lib/jq/round-log.jq"
RL_ME="me-bot"
RL_O1="1111111111111111111111111111111111111111"
RL_O2="2222222222222222222222222222222222222222"
mk_rl() {  # <body> <reviews-json> <comments-json>
  jq -n --arg body "$1" --argjson reviews "$2" --argjson comments "$3" \
    '{data:{repository:{pullRequest:{
      body:$body, reviews:{nodes:$reviews}, comments:{nodes:$comments}}}}}'
}
RL_REVS="$(printf '[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"},{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T03:00:00Z"}]' "$RL_O1" "$RL_O2")"
RL_REVS1="$(printf '[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"}]' "$RL_O1")"
RL_COMS='[{"author":{"login":"me-bot"},"body":"answering round one","createdAt":"2026-01-01T02:00:00Z"},{"author":{"login":"me-bot"},"body":"answering round two","createdAt":"2026-01-01T04:00:00Z"}]'
# rl = handoff/record-all mode ($final=true): finalize every round including the
# live last one — the record-all semantics these fixtures assert. rl_live =
# per-tick mode ($final=false): defer the live round, record only superseded ones.
rl() { jq -r --arg me "$RL_ME" --argjson final true -f "$RLJQ"; }
rl_live() { jq -r --arg me "$RL_ME" --argjson final false -f "$RLJQ"; }

# Two rounds, both answered, no markers in body → both mirrored, oldest first.
RL_OUT="$(mk_rl "Body preamble." "$RL_REVS" "$RL_COMS" | rl)"
case "$RL_OUT" in *"## Round log"*) r1=yes ;; *) r1=no ;; esac
t roundlog-appends-section yes "$r1"
case "$RL_OUT" in *"round:$RL_O1"*"round:$RL_O2"*) r1=ordered ;; *) r1=no ;; esac
t roundlog-markers-oldest-first ordered "$r1"
case "$RL_OUT" in *"answering round one"*"answering round two"*) r1=both ;; *) r1=no ;; esac
t roundlog-both-replies-present both "$r1"
case "$RL_OUT" in *"Round at 11111111"*) r1=yes ;; *) r1=no ;; esac
t roundlog-short-sha-heading yes "$r1"

# Both markers already in the body → nothing to add (the retried-tick no-op).
RL_OUT2="$(mk_rl "preamble <!-- round:$RL_O1 --> and <!-- round:$RL_O2 -->" "$RL_REVS" "$RL_COMS" | rl)"
t roundlog-idempotent-empty "" "$RL_OUT2"

# A round with a verdict but no author reply is recorded, not skipped.
RL_OUT3="$(mk_rl "Body." "$RL_REVS1" '[]' | rl)"
case "$RL_OUT3" in *"_Round passed with no written reply._"*) r1=yes ;; *) r1=no ;; esac
t roundlog-no-reply-recorded yes "$r1"

# An existing `## Round log` section is extended; sibling sections are kept.
RL_BODY_SEC="$(printf 'Intro.\n\n## Round log\n\nolder entry\n\n## Worklog\n\n- [x] a')"
RL_OUT4="$(mk_rl "$RL_BODY_SEC" "$RL_REVS1" "$RL_COMS" | rl)"
case "$RL_OUT4" in *"## Worklog"*"- [x] a"*) r1=kept ;; *) r1=LOST ;; esac
t roundlog-preserves-sibling-sections kept "$r1"
case "$RL_OUT4" in *"older entry"*"round:$RL_O1"*"## Worklog"*) r1=in-section ;; *) r1=no ;; esac
t roundlog-inserts-into-existing-section in-section "$r1"

# Round 1 already recorded, round 2 not → only round 2 appended (no dup).
RL_OUT5="$(mk_rl "has <!-- round:$RL_O1 --> already" "$RL_REVS" "$RL_COMS" | rl)"
case "$RL_OUT5" in *"round:$RL_O2"*) r1=yes ;; *) r1=no ;; esac
t roundlog-partial-appends-missing yes "$r1"
case "$RL_OUT5" in *"answering round one"*) r1=DUP ;; *) r1=clean ;; esac
t roundlog-partial-skips-recorded clean "$r1"

# --- Live-round deferral (per-tick, $final=false): the regression codex found
# on the mirror-every-tick change. Because the mirror now runs every tick, a
# round's FIRST verdict would otherwise stamp `<!-- round:<head> -->` with "no
# written reply" while the round is still live — and the already-recorded skip
# then locks the real reply out forever. Per-tick records only SUPERSEDED
# rounds; the live last round is deferred to a later tick or to the handoff.

# Tick 1: the live round has one verdict and no reply yet → deferred → nothing
# written. Crucially, NO `<!-- round:O1 -->` marker to lock the reply out.
RL_LIVE1="$(mk_rl "Body." "$RL_REVS1" '[]' | rl_live)"
t roundlog-live-round-no-premature-marker "" "$RL_LIVE1"

# Same live round, now WITH the whole-round reply, still the last round →
# still deferred per-tick (no next round has closed its window yet).
RL_ONECOM='[{"author":{"login":"me-bot"},"body":"the whole-round reply","createdAt":"2026-01-01T02:00:00Z"}]'
RL_LIVE2="$(mk_rl "Body." "$RL_REVS1" "$RL_ONECOM" | rl_live)"
t roundlog-live-round-with-reply-still-deferred "" "$RL_LIVE2"

# Once a NEWER round supersedes it (a verdict on O2), the closed round O1 is
# recorded per-tick WITH its real reply — not "no written reply" — while the
# new live round O2 stays deferred. Proves the reply is never lost, only timed.
RL_SUP="$(mk_rl "Body." "$RL_REVS" "$RL_COMS" | rl_live)"
case "$RL_SUP" in *"round:$RL_O1"*) r1=yes ;; *) r1=no ;; esac
t roundlog-superseded-round-recorded-per-tick yes "$r1"
case "$RL_SUP" in *"answering round one"*) r1=real ;; *) r1=no ;; esac
t roundlog-superseded-round-keeps-real-reply real "$r1"
case "$RL_SUP" in *"round:$RL_O2"*) r1=LEAKED ;; *) r1=deferred ;; esac
t roundlog-live-round-deferred-when-superseded deferred "$r1"
case "$RL_SUP" in *"no written reply"*) r1=PREMATURE ;; *) r1=clean ;; esac
t roundlog-superseded-no-premature-noreply clean "$r1"

# The sequential two-tick regression codex reproduced: after tick 1 defers the
# live round (writing NO marker, above), the round completes and the builder
# replies; the handoff straggler ($final=true) then records the REAL reply —
# not the premature "no written reply" the old code locked in.
RL_HANDOFF="$(mk_rl "Body." "$RL_REVS1" "$RL_ONECOM" | rl)"
case "$RL_HANDOFF" in *"the whole-round reply"*) r1=real ;; *) r1=no ;; esac
t roundlog-handoff-finalizes-real-reply real "$r1"
case "$RL_HANDOFF" in *"no written reply"*) r1=PREMATURE ;; *) r1=clean ;; esac
t roundlog-handoff-not-premature-noreply clean "$r1"

# The terminal no-comment case survives the deferral: a round that genuinely
# passed with no reply is still recorded at handoff ($final=true).
RL_TERM="$(mk_rl "Body." "$RL_REVS1" '[]' | rl)"
case "$RL_TERM" in *"_Round passed with no written reply._"*) r1=yes ;; *) r1=no ;; esac
t roundlog-terminal-no-comment-at-handoff yes "$r1"

# B1 (#91): mirroring must be wired into the per-tick `my_open` builder sweep,
# not only into `_handoff_finalize` — else the Round log fills only at
# convergence and a never-converging PR never mirrors. The sweep call is
# `_mirror_rounds "$R" "$N"` (the handoff call uses the function's own
# repo/num locals), so its presence pins the timing fix against a regression to
# handoff-only. shellcheck-disable: matching the literal call, not expanding it.
# shellcheck disable=SC2016
if grep -q '_mirror_rounds "\$R" "\$N"' "$SHARED/lib/duty-builder.sh"; then r1=per-tick; else r1=handoff-only; fi
t roundlog-mirrored-in-per-tick-sweep per-tick "$r1"

# --- _handoff_finalize under a gh shim: one comment, one request, one label,
# ZERO sessions/clones (#91). The stateful shim answers the two GraphQL reads
# (round-log payload and handoff-comment payload), records the REST writes, and
# a post-once.sh stub records the comment. run_session / ensure_main_clone are
# overridden to tripwire the log — if the handoff ever spends a session or a
# clone the test goes red. This is the issue's must-fail floor: the session/
# clone controls, and the label-not-gated-on-a-failing-request control below.
# post-once.sh lives at $DUTY_DIR/bin — common.sh derives BIN_DIR from DUTY_DIR
# at source time, so an env BIN_DIR would be clobbered; place the stub where the
# engine will look.
HFSHIM="$TMP/hf-shim"; HFDUTY="$TMP/hf-duty"
mkdir -p "$HFSHIM" "$HFDUTY/bin" "$HFDUTY/lib/jq"
cp "$SHARED/lib/jq/round-log.jq" "$HFDUTY/lib/jq/"
HF_CALLS="$TMP/hf-calls.log"
HFP_RL="$TMP/hf-rl-payload.json"; HFP_HC="$TMP/hf-hc-payload.json"
# Round-log payload: a body with no marker and one answered round → non-empty
# newbody → the body PATCH fires (exercises _mirror_rounds end to end).
printf '{"data":{"repository":{"pullRequest":{"body":"Body.","reviews":{"nodes":[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"}]},"comments":{"nodes":[{"author":{"login":"me-bot"},"body":"my round reply","createdAt":"2026-01-01T02:00:00Z"}]}}}}}' "$RL_O1" >"$HFP_RL"
# Handoff-comment payload: both panelists approve the current head.
printf '{"data":{"repository":{"pullRequest":{"headRefOid":"%s","latestOpinionatedReviews":{"nodes":[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"%s"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"%s"}}]}}}}}' "$RL_O2" "$RL_O2" "$RL_O2" >"$HFP_HC"
cat >"$HFSHIM/gh" <<'HFGH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  case "$*" in
    *latestOpinionatedReviews*) cat "$HF_HCPAYLOAD" ;;
    *) cat "$HF_RLPAYLOAD" ;;
  esac
  exit 0
fi
is_patch=0 is_reqrev=0 is_label=0
for a in "$@"; do
  [ "$a" = PATCH ] && is_patch=1
  [ "$a" = --add-label ] && is_label=1
  case "$a" in */requested_reviewers) is_reqrev=1 ;; esac
done
if [ "$is_patch" = 1 ]; then cat >/dev/null; printf 'PATCH\n' >>"$HF_CALLS"; exit 0; fi
if [ "$is_reqrev" = 1 ]; then printf 'REQUEST\n' >>"$HF_CALLS"; [ "${HF_REQ_FAIL:-0}" = 1 ] && exit 1; exit 0; fi
if [ "$is_label" = 1 ]; then printf 'LABEL\n' >>"$HF_CALLS"; exit 0; fi
exit 0
HFGH
cat >"$HFDUTY/bin/post-once.sh" <<'HFPO'
#!/usr/bin/env bash
printf 'COMMENT\n' >>"$HF_CALLS"
exit 0
HFPO
cat >"$TMP/hf-run.sh" <<'HFRUN'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/duty-builder.sh"
run_session(){ printf 'SESSION\n' >>"$HF_CALLS"; }
ensure_main_clone(){ printf 'CLONE\n' >>"$HF_CALLS"; }
_handoff_finalize "$1" "$2"
HFRUN
chmod +x "$HFSHIM/gh" "$HFDUTY/bin/post-once.sh"
hf_run() {  # <req-fail 0|1>
  : >"$HF_CALLS"
  SHARED_DIR="$SHARED" HF_CALLS="$HF_CALLS" HF_RLPAYLOAD="$HFP_RL" HF_HCPAYLOAD="$HFP_HC" \
  HF_REQ_FAIL="$1" DUTY_DIR="$HFDUTY" ME=me-bot FLEET_HUMAN=the-human \
  LABEL_NEEDS_HUMAN=state:needs-human MARK_HANDOFF='🤝 handed off at head' \
  PATH="$HFSHIM:$PATH" bash "$TMP/hf-run.sh" the/repo 7 >/dev/null 2>&1
}
hfc() { grep -c "^$1\$" "$HF_CALLS"; }

hf_run 0
t handoff-posts-one-comment 1 "$(hfc COMMENT)"
t handoff-requests-human-once 1 "$(hfc REQUEST)"
t handoff-sets-label-once 1 "$(hfc LABEL)"
t handoff-writes-body-once 1 "$(hfc PATCH)"
t handoff-spends-no-session 0 "$(hfc SESSION)"
t handoff-spends-no-clone 0 "$(hfc CLONE)"

# The label is notify.sh's poll signal, so it must NOT be gated on a review
# request that can fail — a failed request with the label set still pings the
# human. Must-fail: gate the label on the request and this goes red.
hf_run 1
t handoff-request-attempted-on-fail 1 "$(hfc REQUEST)"
t handoff-label-set-even-if-request-fails 1 "$(hfc LABEL)"

# --- rotate_log
printf 'x' >"$TMP/small.log"
rotate_log "$TMP/small.log"
[ -f "$TMP/small.log" ] && r1=kept || r1=gone
t rotate-small kept "$r1"

# --- seen-ledgers: ledger_filter / ledger_commit (the refire fix) ---------
# A wake whose signal is present but UNCHANGED must not re-launch a session;
# it may only wake on new-or-advanced activity. This is what stops the mention
# and held-discussion refire that burned the triage box's Fable quota.
LG="$TMP/ledger"
n() { awk 'NF{c++} END{print c+0}'; }
# cold ledger (first look): everything is new
t ledger-cold 2 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_commit "$LG"
# same state again: SUPPRESSED (the burn fix)
t ledger-suppress 0 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
# one timestamp advanced: only that id re-wakes
t ledger-advance "111 2026-07-24T20:30:00Z" "$(printf '111 2026-07-24T20:30:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG")"
# brand-new id wakes
t ledger-newid 1 "$(printf '333 2026-07-25T01:00:00Z\n' | ledger_filter "$LG" | n)"
# commit is monotonic: a stale (older) commit must not lower the mark
printf '111 2026-07-24T20:30:00Z\n' | ledger_commit "$LG"
printf '111 2026-07-01T00:00:00Z\n' | ledger_commit "$LG"
t ledger-monotonic 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"
# empty input is safe and preserves the ledger (no session -> nothing to commit)
printf '' | ledger_commit "$LG"
t ledger-empty-safe 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"

# cross-repo collision: discussion numbers are PER-REPO but the ledger is one
# file across every repo in repos.txt, so keys must be repo-qualified. After
# committing ceremony#1, an unchanged/older rig#1 must still wake — a bare "1"
# key would shadow it and triage would never see rig's discussion (codex, #16).
LG2="$TMP/ledger-disc"
printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_commit "$LG2"
t ledger-crossrepo-distinct 1 "$(printf 'heavy-duty/rig#1 2026-07-20T00:00:00Z\n' | ledger_filter "$LG2" | n)"
t ledger-crossrepo-samekey  0 "$(printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_filter "$LG2" | n)"

# --- ledger_suppressed: the exact inverse of ledger_filter (#59) ------------
# The two must partition the input between them. If they can ever disagree, the
# engine either pays for work it meant to suppress or goes quiet about work it
# meant to report — and the second is the dangerous one.
LG3="$TMP/ledger-inv"
printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | ledger_commit "$LG3"
IN3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T11:00:00Z\no/r#3 2026-07-27T09:00:00Z\n')"
# #1 unchanged -> suppressed; #2 advanced -> fresh; #3 unseen -> fresh
t suppressed-unchanged "o/r#1 2026-07-27T10:00:00Z" "$(printf '%s\n' "$IN3" | ledger_suppressed "$LG3")"
t suppressed-fresh-count 2 "$(printf '%s\n' "$IN3" | ledger_filter "$LG3" | n)"
# Partition: filter + suppressed together account for every input line, exactly
# once. Asserted rather than assumed — the set-arithmetic version of this that
# I wrote first reported NOTHING suppressed whenever the fresh list was empty.
t suppressed-partitions 3 "$(printf '%s\n' "$IN3" | { ledger_filter "$LG3"; printf '%s\n' "$IN3" | ledger_suppressed "$LG3"; } | n)"
t suppressed-disjoint 0 "$(comm -12 \
  <(printf '%s\n' "$IN3" | ledger_filter "$LG3" | sort) \
  <(printf '%s\n' "$IN3" | ledger_suppressed "$LG3" | sort) | n)"
# A cold ledger hides nothing.
t suppressed-cold 0 "$(printf 'o/r#9 2026-07-27T10:00:00Z\n' | ledger_suppressed "$TMP/nope" | n)"

# --- report_suppressed: stop paying, do NOT stop saying (#59) ---------------
# A ledger converts a burn into silence. An unactioned item is still a live
# board-invariant violation, so the suppressed set has to surface — but at one
# tick per five minutes, a line every tick would bury the log it informs. So:
# warn when the SET CHANGES, and again from scratch after it clears.
ST="$TMP/suppressed-state"
r1="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r1" in *"1 item(s)"*"o/r#1"*) r2=warned ;; *) r2="$r1" ;; esac
t report-first warned "$r2"
# Same set again: silent.
t report-repeat "" "$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
# Set grows: speaks again.
r3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r3" in *"2 item(s)"*) r4=warned ;; *) r4="$r3" ;; esac
t report-grew warned "$r4"
# Emptied: silent, and the state file goes, so a recurrence is reported afresh
# rather than being swallowed as "same as last time".
t report-cleared "" "$(printf '' | report_suppressed "$ST" "o/r: board")"
if [ -f "$ST" ]; then r5=kept; else r5=removed; fi
t report-state-removed removed "$r5"
r6="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r6" in *"1 item(s)"*) r7=warned ;; *) r7="$r6" ;; esac
t report-recurrence-speaks warned "$r7"
# Blank lines are not items and must not render as the malformed `()`.
r8="$(printf '\no/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$TMP/sup-blank" "review")"
case "$r8" in *'()'*) r9=MALFORMED ;; *) r9=clean ;; esac
t report-blank-line-format clean "$r9"

# An incomplete sweep cannot compare its partial set with the previous complete
# set. Preserve the state byte-for-byte; otherwise one flaky repo makes every
# healthy repo's standing suppression look changed twice (drop + return).
ST_PART="$TMP/sup-partial"
printf 'o/a#1 T1\no/b#1 T1\n' | report_suppressed "$ST_PART" "review" >/dev/null
before_part="$(cat "$ST_PART")"
printf 'o/a#1 T1\n' \
  | report_suppressed_if_complete 0 "$ST_PART" "review" >/dev/null
t report-partial-preserves-state "$before_part" "$(cat "$ST_PART")"
# The next complete steady set remains silent, proving the partial tick did not
# replace the state and manufacture a second warning when repo B returns.
t report-after-partial-still-settled "" \
  "$(printf 'o/a#1 T1\no/b#1 T1\n' \
      | report_suppressed_if_complete 1 "$ST_PART" "review")"

# --- suppression state must be PER REPO (#60 review) ------------------------
# Both duty modules call report_suppressed inside a per-repo loop. With ONE
# shared state file, repo B's set replaces repo A's, and a repo with nothing
# suppressed rm -f's the file outright — so A's unchanged set looks new on the
# next tick and warns again, every tick, on exactly the 3-repo production box
# this was written to protect. codex-bot and grok-bot both caught it; grok-bot
# reproduced the flip-flop with these helpers.
sup_says() { if grep -q 'item(s)'; then echo warned; else echo silent; fi; }
SUP_A='o/a#1 2026-07-27T10:00:00Z'
SUP_B='o/b#1 2026-07-27T10:00:00Z'

# Per-repo files: each repo settles independently and stays quiet.
STA="$TMP/sup.o_a"; STB="$TMP/sup.o_b"
printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" >/dev/null
t report-perrepo-a-settles silent "$(printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" | sup_says)"
t report-perrepo-b-settles silent "$(printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" | sup_says)"

# The shape that was wrong, kept as a negative control: sharing one file makes
# A speak again after B has been through it. If this ever reads `silent` the
# helper has changed and the per-repo keying above may no longer be load-bearing.
SUP_SHARED="$TMP/sup.shared"
printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$SUP_SHARED" "o/b: board" >/dev/null
t report-shared-state-refires warned "$(printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" | sup_says)"

# ...and the modules must actually key by repo, not just be capable of it.
for pair in "duty-triage.sh:suppressed-triage-board" "duty-builder.sh:suppressed-build"; do
  mod="${pair%%:*}"; sfile="${pair##*:}"
  if grep -qE "$sfile\.\\\$\{?(R|slug)" "$SHARED/lib/$mod"; then r1=perrepo; else r1=SHARED; fi
  t "suppression-state-perrepo-$mod" perrepo "$r1"
done

# --- every state signal is ledgered (#59) -----------------------------------
# The engine had TWO ledgers, both in triage, while builder and reviewer had
# none — so any signal cleared by an in-session action the agent may DECLINE
# re-fired a model session every tick forever. These pin the wiring: a new
# signal site added without a ledger is the regression.
for pair in "duty-triage.sh:.seen-triage-board" "duty-builder.sh:.seen-build" \
            "duty-review.sh:.seen-review" "duty-attention.sh:.seen-attention"; do
  mod="${pair%%:*}"; led="${pair##*:}"
  if grep -q "$led" "$SHARED/lib/$mod"; then r1=ledgered; else r1=UNGUARDED; fi
  t "signal-ledgered-$mod" ledgered "$r1"
  # ...and committed only after a session that actually completed.
  if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/$mod"; then r1=gated; else r1=UNGATED; fi
  t "ledger-commit-gated-$mod" gated "$r1"
  # ...and what it hides must be reported.
  if grep -q 'report_suppressed' "$SHARED/lib/$mod"; then r1=reported; else r1=SILENT; fi
  t "suppression-reported-$mod" reported "$r1"
done

# The reviewer must carry updated_at from the existing pulls page, partition
# before assembling per-repo prompts, and commit that repo's exact fresh set.
REVIEW_MOD="$SHARED/lib/duty-review.sh"
if grep -Fq "\\(.updated_at) \\(\$sr) \\(.number)" "$REVIEW_MOD"; then r1=carried; else r1=MISSING; fi
t review-carries-updated-at carried "$r1"
if grep -q 'fresh_items=.*ledger_filter.*seen-review' "$REVIEW_MOD" &&
   grep -q 'suppressed=.*ledger_suppressed.*seen-review' "$REVIEW_MOD"; then
  r1=partitioned
else
  r1=UNPARTITIONED
fi
t review-partitions-before-prompt partitioned "$r1"
commit_block="$(awk '
  /if \[ "\$\{RUN_SESSION_RC:-1\}" -eq 0 \]; then/ { inside=1 }
  inside { print }
  inside && /^[[:space:]]*fi$/ { exit }
' "$REVIEW_MOD")"
if grep -Fq "\${repo_items[\$SR]}" <<<"$commit_block" &&
   grep -Fq "ledger_commit \"\$DUTY_DIR/.seen-review\"" <<<"$commit_block"; then
  r1=exact
else
  r1=MISMATCH
fi
t review-commits-prompted-set exact "$r1"
if grep -q 'report_suppressed_if_complete.*sweep_complete' "$REVIEW_MOD"; then
  r1=guarded
else
  r1=UNGUARDED
fi
t review-partial-sweep-preserves-report-state guarded "$r1"

# Behavioral mixed case: #5 is unchanged and suppressed; #6 in the same repo
# is fresh. Only #6 enters the prompted/committed set. After that successful
# commit both are settled; advancing #5's updated_at wakes it again.
RLG="$TMP/review-ledger"
printf 'o/r#5 T1\n' | ledger_commit "$RLG"
RQ="$(printf 'o/r#5 T1\no/r#6 T1\n')"
RP="$(printf '%s\n' "$RQ" | ledger_filter "$RLG")"
RS="$(printf '%s\n' "$RQ" | ledger_suppressed "$RLG")"
t review-mixed-prompt-only-fresh "o/r#6 T1" "$RP"
t review-mixed-report-only-suppressed "o/r#5 T1" "$RS"
printf '%s\n' "$RP" | ledger_commit "$RLG"
t review-mixed-commit-settles-both 0 "$(printf '%s\n' "$RQ" | ledger_filter "$RLG" | n)"
t review-advanced-suppressed-rewakes "o/r#5 T2" \
  "$(printf 'o/r#5 T2\n' | ledger_filter "$RLG")"

# --- the registry bounds EVERY module, attention included (#52, #66) ------
# drill/rehearsal.sh narrows repos.txt to a single sandbox repo and REFUSES to
# tick if it cannot. That is containment only for modules which actually
# consult the file, so it is asserted rather than believed.
#
# The list was review, builder, triage, hygiene. The reviewer was the exception
# until 2026-07-25 (an org-wide requested_reviewers sweep no registry could
# bound) — which is what #52 was filed doubting — and the attention wake was
# the exception until 2026-07-27, when danmt ruled on #66 that the registry
# bounds it too. `examples/repos.txt` asserted the universal for two days longer
# than the engine honoured it, and that header is what an operator reads when
# deciding whether narrowing the file contains a box.
for mod in review builder triage hygiene attention; do
  if grep -q 'REPOS_FILE' "$SHARED/lib/duty-$mod.sh"; then r1=scoped; else r1=UNSCOPED; fi
  t "registry-scoped-$mod" scoped "$r1"
done

# ...and scoped BEHAVIOURALLY, not just by mentioning the file. The partition
# is the ruling, so it is exercised directly: a grep for REPOS_FILE would pass
# against a module that read the registry and then ignored it.
# Definition-only at the top level, so sourcing costs nothing and runs nothing.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-attention.sh"
ATT_REG="$(printf 'heavy-duty/ceremony\nheavy-duty/rig\n')"
ATT_ROWS="$(printf 'heavy-duty/ceremony 12 T1\nouter/thing 7 T2\nheavy-duty/rig 3 T3\n')"
ATT_OUT="$(printf '%s\n' "$ATT_ROWS" | _attention_partition "$ATT_REG")"
t attention-in-registry-acted "IN heavy-duty/ceremony 12 T1
IN heavy-duty/rig 3 T3" "$(printf '%s\n' "$ATT_OUT" | grep '^IN ')"
t attention-outside-registry-not-acted "OUT outer/thing 7 T2" \
  "$(printf '%s\n' "$ATT_OUT" | grep '^OUT ')"
# A prefix must not count as membership: `heavy-duty/rig` in the registry must
# not authorize `heavy-duty/rig-fork`. grep -qxF, never a substring match.
t attention-prefix-is-not-membership "OUT heavy-duty/rig-fork 9 T4" \
  "$(printf 'heavy-duty/rig-fork 9 T4\n' | _attention_partition "$ATT_REG" | grep '^OUT ')"
# An empty registry authorizes nothing — it must not read as "no filter".
t attention-empty-registry-acts-on-nothing "" \
  "$(printf '%s\n' "$ATT_ROWS" | _attention_partition "" | grep '^IN ' || true)"

# --- the attention wake is ledgered too (#59's last site) --------------------
# It looked exempt: the pickup session acks by REMOVING the label, so the
# signal self-clears, and the module documents a deliberate crash-only retry.
# Both true, and neither covers a session that COMPLETES and correctly declines
# to ack — needs a ruling, not this box's to answer, already handled. Nothing
# removes the label and the wake re-fires every tick.
#
# It is the worst place in the engine for that: TIMEOUT_ATTENTION is 1800s,
# duty_attention runs FIRST, and it runs for EVERY role on EVERY box, where
# every other signal site is confined to one role.
ALG="$TMP/attention-ledger"
ATT_IN="$(printf 'o/r#4 T1\no/r#9 T1\n')"
t attention-first-tick-both-fire 2 "$(printf '%s\n' "$ATT_IN" | ledger_filter "$ALG" | n)"
# #4's session completed and acked (the row is gone from the query next tick);
# #9's completed and declined, so only #9's id was committed.
printf 'o/r#9 T1\n' | ledger_commit "$ALG"
t attention-declined-does-not-refire 0 "$(printf 'o/r#9 T1\n' | ledger_filter "$ALG" | n)"
# ...but it is still SAID, once per change to the set.
t attention-declined-is-reported "o/r#9" \
  "$(printf 'o/r#9 T1\n' | ledger_suppressed "$ALG" | cut -d' ' -f1)"
# A comment, an edit or a re-label advances updated_at — look again, which is
# exactly when the box should.
t attention-touched-demand-rewakes 1 "$(printf 'o/r#9 T2\n' | ledger_filter "$ALG" | n)"
# A CRASHED session commits nothing, so the same id is still fresh next tick:
# the module's documented crash-only retry has to survive the ledger.
t attention-crashed-session-retries 1 "$(printf 'o/r#4 T1\n' | ledger_filter "$ALG" | n)"
# The commit is gated on the session's own rc, per demand — a sibling that
# succeeded must not settle one that died.
if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/duty-attention.sh"; then r1=gated; else r1=UNGATED; fi
t attention-ledger-commit-gated gated "$r1"
# ...and the WAKE PATH must be the filtered set, which everything above this
# line fails to prove: the assertions exercise ledger_filter, and the module
# would still mention .seen-attention (in the suppression report) with the
# filter deleted from the wake. Ripping `ledger_filter` out of the assignment
# left all of them green. So the structure is pinned too — the same shape
# duty-review.sh's `review-partitions-before-prompt` pins, and for the same
# reason.
ATT_MOD="$SHARED/lib/duty-attention.sh"
# The SAME hole, one level up, and this one shipped to review: the behavioural
# assertions call _attention_partition directly, so they cannot see a wake path
# that computes the partition and then ignores it. kimi ran exactly that
# mutation against d849f16 —
#
#   inside="$(printf '%s\n' "$rows" | awk '{ print $1 "#" $2, $3 }')"
#
# keeping the registry read and the partition function intact, and the suite
# stayed 185 ok / 0 failed. So the wiring is pinned too: the acted set and the
# reported set must both come from $partitioned, and $outside must be what
# feeds the suppression report the operator alert keys on.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
if grep -q 'inside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'outside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'printf .* "\$outside" *\\*$' "$ATT_MOD"; then
  r1=wired
else
  r1=UNWIRED
fi
t attention-acted-set-comes-from-the-partition wired "$r1"

# The two withheld sets are different events and must not read alike in
# duty.log: a ledger suppression is an item a session SAW and declined; an
# out-of-scope demand was never actionable by this box and no session ever saw
# it. The default phrase stays for the three ledger callers.
RSW="$TMP/rsw-state"
t report-suppressed-default-phrase reported \
  "$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" 2>&1 \
     | grep -q 'unactioned since a previous session' && echo reported || echo MISSING)"
rm -f "$RSW"
t report-suppressed-custom-phrase reported \
  "$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" "never actionable here" 2>&1 \
     | grep -q 'never actionable here' && echo reported || echo MISSING)"
rm -f "$RSW"
if grep -q 'report_suppressed .*sc_state.*\\$' "$ATT_MOD" &&
   grep -q 'this box does not carry' "$ATT_MOD"; then r1=distinct; else r1=BORROWED; fi
t attention-scope-report-has-its-own-phrase distinct "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -q 'fresh=.*ledger_filter.*\.seen-attention' "$ATT_MOD" &&
   grep -q 'rows="\$fresh"' "$ATT_MOD"; then
  r1=filtered
else
  r1=UNFILTERED
fi
t attention-wake-set-is-the-filtered-set filtered "$r1"

# The bound must not be silent, and for THIS module not only in duty.log: an
# attention demand is somebody deliberately handing this box work, so a bound
# that only logged would read to them as the box ignoring them.
if grep -q 'report_suppressed' "$SHARED/lib/duty-attention.sh"; then r1=reported; else r1=SILENT; fi
t attention-out-of-scope-reported reported "$r1"
if grep -q 'alert ' "$SHARED/lib/duty-attention.sh"; then r1=pinged; else r1=LOG-ONLY; fi
t attention-out-of-scope-pings-operator pinged "$r1"

# The drill's separate check survives the ruling, with a changed job: it used
# to be the ONLY containment for this module, and is now an independent
# verification that the filter above actually holds. Keeping it is the
# difference between testing the invariant and trusting it.
if grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal-safety.sh" &&
   grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal.sh"; then r1=checked; else r1=ASSUMED; fi
t "drill-checks-attention-outside-sandbox" checked "$r1"

# --- an idle tick is not a silent one (#53) -------------------------------
# The floor's SILENT rule is "no duty.log line for two tick boundaries", which
# is sound only if a tick that finds no work still writes. duty.sh logs
# `duty run start` before any role dispatch and `duty run end` on every exit
# path, and tick.sh covers the rest (skipped, FAILED) — so a duty.log with
# nothing new means no tick RAN, which is a cron problem, never a healthy idle
# box. That is the diagnosis #53 needed, and this keeps it true: an early
# `exit` added between the two lines would turn an idle box into an offline one
# on the console, and a silent box into an ambiguous one.
t duty-start-unconditional 1 "$(grep -c '^log "duty run start"' "$SHARED/bin/duty.sh")"
# Every exit path after the start line must have logged the end line first.
# A linear scan, deliberately: it is an approximation of control flow, but it
# catches the shape that actually regresses — a new early `exit` on a branch
# that forgot the evidence line.
t duty-end-on-every-exit "" "$(awk '
  /^log "duty run start"/ { started = 1; next }
  !started { next }
  /log "duty run end"/    { ended = 1 }
  /^[[:space:]]*exit / && !ended { print "line " NR; exit }
' "$SHARED/bin/duty.sh")"
# `crontab armed` must not be the last word: the crontab holding a line says
# nothing about a cron daemon existing to run it, and that gap is why three
# boxes reported armed and one ticked.
if grep -q 'cron_daemon_running' "$SHARED/install.sh"; then r1=checked; else r1=ASSUMED; fi
t install-verifies-cron-daemon checked "$r1"

# --- credential state reported by the flow (replaces the polled probes) ----
# These run against the REAL common.sh sourced above, with DUTY_DIR pointed at
# a scratch dir, so the marker contract the floor reads is asserted here and
# not merely described in a comment.

# alert() would try to curl Telegram from a unit test; the token files do not
# exist so it returns early, but stub it anyway — a test that depends on the
# absence of a file in $HOME is a test that fails on somebody's laptop.
alert() { :; }

AUTHDIR="$TMP/authstate"; mkdir -p "$AUTHDIR"
DUTY_DIR="$AUTHDIR"

note_auth_failure gh "401 Bad credentials"
t authfail-file-per-service present "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo present || echo MISSING)"
t authfail-does-not-touch-other-service absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo LEAKED || echo absent)"
t authfail-records-reason found \
  "$(grep -q '401 Bad credentials' "$AUTHDIR/.auth-fail.gh" && echo found || echo MISSING)"

# The first failure must win. Rewriting every tick resets mtime, so a
# credential that died on Monday reads as having died just now — and "when did
# this break" is the only question the file exists to answer.
FIRST="$(cat "$AUTHDIR/.auth-fail.gh")"
sleep 1
note_auth_failure gh "403 something else entirely"
t authfail-first-failure-wins "$FIRST" "$(cat "$AUTHDIR/.auth-fail.gh")"

clear_auth_failure gh
t authfail-cleared absent "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo PRESENT || echo absent)"
clear_auth_failure gh   # must be idempotent, not an error under set -e
t authfail-clear-idempotent 0 "$?"

# Multi-line reasons: gh's errors routinely are, and one record must stay one
# line or probe.sh's ::key contract silently gains phantom keys.
note_auth_failure vendor "$(printf 'line one\nline two\nline three')"
t authfail-single-line 1 "$(wc -l < "$AUTHDIR/.auth-fail.vendor")"
clear_auth_failure vendor

# check_vendor_credential's tri-state. 2 means "this profile cannot tell from
# local state" and MUST change nothing: neither raise an alarm nor clear a
# real failure someone still has to fix.
# shellcheck disable=SC2034  # read by check_vendor_credential in common.sh
AGENT_LOGIN_HINT="run the thing"
# shellcheck disable=SC2317  # invoked indirectly, by check_vendor_credential
bot_cli_present() { return 0; }
check_vendor_credential
t vendor-present-no-failure absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo PRESENT || echo absent)"

# shellcheck disable=SC2317
bot_cli_present() { return 1; }
check_vendor_credential
t vendor-absent-raises present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo MISSING)"

# shellcheck disable=SC2317
bot_cli_present() { return 2; }
check_vendor_credential
t vendor-unknown-does-not-clear present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo CLEARED)"
rm -f "$AUTHDIR/.auth-fail.vendor"
check_vendor_credential
t vendor-unknown-does-not-raise absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"
unset -f bot_cli_present

# An older agent profile with neither function must be a no-op, not a failure:
# install.sh does not upgrade confs in place, so mid-rollout boxes will have
# exactly this shape.
check_vendor_credential
t vendor-legacy-profile-silent absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"

# --- each agent profile reads its OWN credential store, locally -------------
# Driven against the real conf files with a fabricated HOME, because the whole
# claim of bot_cli_present is that it needs nothing but local disk.

CREDH="$TMP/credhome"; mkdir -p "$CREDH"
cred_rc() {  # cred_rc <agent> <home> -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="" CODEX_HOME="" GROK_HOME="" \
    ANTHROPIC_API_KEY="" XAI_API_KEY=""
    # shellcheck disable=SC1090
    source "$SHARED/conf/agents/$1.conf"; bot_cli_present ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# base64url with the padding stripped, the way a JWT actually arrives.
b64url() { base64 -w0 | tr '/+' '_-' | tr -d '='; }

# -- claude: refreshTokenExpiresAt, in MILLISECONDS
CH="$CREDH/claude"; mkdir -p "$CH/.claude"
CLAUDE_EXP_MS=$(( ($(date +%s) + 20 * 86400) * 1000 ))
jq -n --argjson r "$CLAUDE_EXP_MS" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-present 0 "$(cred_rc claude "$CH")"

# THE trap, and the reason this profile reads refreshTokenExpiresAt: an access
# token that lapsed hours ago while the refresh token is still good is the
# ordinary steady state, refreshed silently on next use. A profile testing
# `expiresAt` would call a perfectly healthy box logged out three times a day.
jq -n --argjson r "$CLAUDE_EXP_MS" --argjson a "$(( ($(date +%s) - 3600) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:$a,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-stale-access-token-is-fine 0 "$(cred_rc claude "$CH")"

# An expired REFRESH token is the real logout: nothing can renew it but a human.
jq -n --argjson r "$(( ($(date +%s) - 86400) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-expired-refresh 1 "$(cred_rc claude "$CH")"
t cred-claude-no-file 1 "$(cred_rc claude "$CREDH/nothing")"

# -- kimi: the refresh token is a JWT; its exp claim is the relogin deadline
KH="$CREDH/kimi"; mkdir -p "$KH/.kimi-code/credentials"
KIMI_EXP=$(( $(date +%s) + 30 * 86400 ))
# A payload sized so base64url PADDING is required — the case a naive decoder
# silently fails on.
KJWT="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code","sub":"u"}' "$KIMI_EXP" | b64url).sig"
jq -n --arg rt "$KJWT" \
  '{access_token:"a",refresh_token:$rt,expires_at:1,token_type:"Bearer"}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-present 0 "$(cred_rc kimi "$KH")"
t cred-kimi-no-file 1 "$(cred_rc kimi "$CREDH/nothing")"
# An expired refresh JWT is a logout, not merely "cannot tell".
KJWT_OLD="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code"}' "$(( $(date +%s) - 86400 ))" | b64url).sig"
jq -n --arg rt "$KJWT_OLD" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-expired-refresh 1 "$(cred_rc kimi "$KH")"
# Garbage in the JWT slot must be "cannot tell" (2), never a confident logout.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-unparseable-is-unknown 2 "$(cred_rc kimi "$KH")"

# -- codex: file-backed vs keyring-backed, and NO expiry at all
DH="$CREDH/codex"; mkdir -p "$DH/.codex"
jq -n '{auth_mode:"chatgpt",tokens:{access_token:"a.b.c",refresh_token:"opaque"}}' > "$DH/.codex/auth.json"
t cred-codex-present 0 "$(cred_rc codex "$DH")"
t cred-codex-no-file-is-logout 1 "$(cred_rc codex "$CREDH/nothing")"
# ...unless the box keeps its credential in the desktop keyring, where a
# missing auth.json is normal and must not be reported as a logout.
KB="$CREDH/codexkeyring"; mkdir -p "$KB/.codex"
echo 'cli_auth_credentials_store = "keyring"' > "$KB/.codex/config.toml"
t cred-codex-keyring-is-unknown 2 "$(cred_rc codex "$KB")"

# -- grok: its probe was already a local file test, so it is authoritative
# -- grok: a MAP of "<issuer>::<client_id>" slots, refresh token opaque
GH_="$CREDH/grok"; mkdir -p "$GH_/.grok"
jq -n '{"https://auth.x.ai::abc":{key:"j.w.t",refresh_token:"opaque",expires_at:"2026-07-27T19:54:18Z"}}' \
  > "$GH_/.grok/auth.json"
t cred-grok-present 0 "$(cred_rc grok "$GH_")"
t cred-grok-no-file 1 "$(cred_rc grok "$CREDH/nothing")"
# An empty map is a non-empty FILE. The old `[ -s ]` test called this logged
# in; it is a failed login, and the honest answer is "cannot tell".
echo '{}' > "$GH_/.grok/auth.json"
t cred-grok-empty-map-is-unknown 2 "$(cred_rc grok "$GH_")"

# No profile may define bot_cli_expiry: the floor tracks no expiry dates, and
# a profile still exporting one would be dead code drifting out of sync.
for agent in claude codex grok kimi; do
  r1=absent
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$agent.conf"; command -v bot_cli_expiry >/dev/null ) 2>/dev/null && r1=DEFINED
  t "cred-$agent-defines-no-expiry" absent "$r1"
done

# --- the per-tick path must not have reacquired a network auth probe -------
# `gh auth status` in the tick is the exact cost this change removed; it would
# pass every assertion above while restoring 7k requests/day.
# The boot gate ABOVE the identity call may still pay for a real probe once
# per boot — certainty is worth one round-trip there. What must never come
# back is a probe in the per-tick path, so the assertion is positional:
# nothing after `ME="$(gh_identity)"` may call it.
r1="$(awk '
  /ME="\$\(gh_identity\)"/ { after = 1 }
  after && /^[^#]*gh auth status/ { print "POLLED"; exit }
' "$SHARED/bin/duty.sh")"
r1="${r1:-clean}"
t tick-does-not-poll-gh-auth clean "$r1"
# ...and the identity call must be the one that harvests the expiry header.
if grep -q 'gh_identity' "$SHARED/bin/duty.sh"; then r1=wired; else r1=MISSING; fi
t tick-uses-gh-identity wired "$r1"
# No expiry date is tracked anywhere any more: four providers express it four
# ways and two cannot answer locally at all, so the countdown was the flaky
# half of the idea. A reintroduced record_token_expiry would put it back.
if grep -q 'record_token_expiry\|token-expiry' "$SHARED/lib/common.sh"; then r1=TRACKED; else r1=clean; fi
t no-expiry-date-tracked clean "$r1"

# Every agent profile must define bot_cli_present, or its box silently never
# reports vendor credential state at all.
missing=""
for agent in claude codex grok kimi; do
  grep -q 'bot_cli_present()' "$SHARED/conf/agents/$agent.conf" || missing="$missing $agent"
done
t agent-profiles-define-present "" "$missing"

# --- the two-boundary rule must exist once, not once per reader -----------
# floor.py derives it (2 * TICK_S), cli/crew names it, and probe.sh must not
# hold it at all: the box ships ::tickage and the HOST decides. A third copy
# inside the box, in a second language, meant changing TICK_S would leave the
# floor calling a box SILENT while both credential readers still said flowing
# — and rehearsal-app.sh asserts those two readers agree, so the drill would
# fail for a reason nobody would trace to a constant.
CREW_CLI="$(cd "$(dirname "$SHARED")" && pwd)/cli/crew"
FLOOR_PY="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/floor.py"

FL_TICK="$(sed -n 's/^TICK_S = \([0-9]*\).*/\1/p' "$FLOOR_PY" | head -1)"
FL_SILENT=$(( ${FL_TICK:-0} * 2 ))
# shellcheck disable=SC2016  # matching crew's literal ${CREW_SILENT_AFTER:-600}
CL_SILENT="$(sed -n 's/^SILENT_AFTER_S="${CREW_SILENT_AFTER:-\([0-9]*\)}".*/\1/p' "$CREW_CLI" | head -1)"
t silent-rule-floor-derived 600 "$FL_SILENT"
t silent-rule-cli-matches-floor "$FL_SILENT" "$CL_SILENT"

# ...and the box must hold no threshold of its own. Comments and the log-tail
# line count are stripped before looking, so only real code counts.
PROBE_SH="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/probe.sh"
if sed -e 's/#.*//' -e '/tail -n/d' "$PROBE_SH" | grep -qE '\b(600|SILENT_AFTER)\b'; then
  r1=BAKED
else
  r1=clean
fi
t probe-holds-no-threshold clean "$r1"
# The datum it ships instead:
if grep -q 'emit tickage' "$PROBE_SH"; then r1=emitted; else r1=MISSING; fi
t probe-emits-tickage emitted "$r1"
# --- head-checks.jq: the check at the head, and the round it gates (#45/#17) --
# The engine never read statusCheckRollup at all, which is both bugs at once: a
# fix round opened on a red head (#45) and a red head that woke nothing (#17).
HC="$SHARED/lib/jq/head-checks.jq"
hc() {  # hc <panel-json> <pr-array-json> -> rows
  printf '%s' "$2" | jq -r --argjson panel "$1" --arg repo "o/r" -f "$HC"
}
mk_prc() {  # mk_prc <rollup> [opinionated-reviews] [requests] [isDraft]
  jq -cn --argjson c "$1" --argjson lr "${2:-[]}" --argjson rr "${3:-[]}" \
     --argjson d "${4:-false}" \
     '[{number:1, isDraft:$d, updatedAt:"T1", headRefOid:"abc1234",
        statusCheckRollup:$c, latestOpinionatedReviews:$lr, reviewRequests:$rr}]'
}
CHK_OK='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"}]'
CHK_BAD='[{"__typename":"CheckRun","name":"release-exercise / fixture-chain","status":"COMPLETED","conclusion":"FAILURE"}]'
CHK_RUNNING='[{"__typename":"CheckRun","name":"check","status":"IN_PROGRESS","conclusion":null}]'
CHK_CANCEL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"CANCELLED"}]'
CHK_STALE='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"STALE"}]'
CHK_NEUTRAL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"NEUTRAL"}]'
CHK_SKIPPED='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SKIPPED"}]'
# A conclusion this engine has never heard of. GitHub adds these.
CHK_UNKNOWN='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"QUANTUM_FAILURE"}]'
# The StatusContext shape. THIS is the fixture that matters: crew's own CI is a
# single CheckRun, so an implementation that discriminates on __typename and
# reads only .conclusion passes every other test in this file and reports a
# FAILING status context as green — a pass for a reason unrelated to the claim,
# which is #50's shape. Reintroduce that discrimination and these two go red.
SC_BAD='[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
SC_ERR='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
SC_MIX='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'

state_of() { hc '[]' "$(mk_prc "$1")" | cut -f4; }
t head-check-run-success      green   "$(state_of "$CHK_OK")"
t head-check-run-failure      red     "$(state_of "$CHK_BAD")"
t head-status-context-failure red     "$(state_of "$SC_BAD")"
t head-status-context-error   red     "$(state_of "$SC_ERR")"
t head-mixed-shapes-one-red   red     "$(state_of "$SC_MIX")"
t head-check-still-running    pending "$(state_of "$CHK_RUNNING")"
t head-no-checks-is-not-green none    "$(state_of '[]')"
# GREEN IS A WHITELIST; ANYTHING ELSE IS RED (codex, #64). The first version
# enumerated the failing conclusions and let the rest fall through to green,
# arguing a CANCELLED run is one superseded by a newer push. Wrong: the rollup
# is already scoped to the CURRENT head, so a superseded run is not in it — a
# cancelled one there is a manual or same-head-concurrency cancel, i.e. a head
# that is not passing. Reading it green defeated #45's gate and blinded #17's
# wake at the same time. This test previously asserted `green` and locked that
# in, which is why it is called out here rather than quietly flipped.
t head-cancelled-is-red       red     "$(state_of "$CHK_CANCEL")"
t head-stale-is-red           red     "$(state_of "$CHK_STALE")"
# ...and the point of a whitelist: a conclusion nobody has written a branch for
# fails CLOSED. Enumerating the bad ones would have gotten this wrong the same
# way, silently, the next time GitHub adds one.
t head-unknown-conclusion-is-red red  "$(state_of "$CHK_UNKNOWN")"
# The genuinely-not-a-failure conclusions stay green, or every skipped matrix
# leg would wake a builder.
t head-neutral-is-green       green   "$(state_of "$CHK_NEUTRAL")"
t head-skipped-is-green       green   "$(state_of "$CHK_SKIPPED")"
# Drafts are never rows: a panel is never requested on a draft, and a draft's
# red CI is the author's in-flight business (resume owns it).
t head-drafts-excluded "" "$(hc '[]' "$(mk_prc "$CHK_BAD" '[]' '[]' true)")"

# The failing check's name reaches the operator and the prompt, spaces and all
# — which is why the row is TAB-delimited and the names are last.
t head-failing-names-carried "release-exercise / fixture-chain (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_BAD")" | cut -f6)"
t head-green-names-dash "-" "$(hc '[]' "$(mk_prc "$CHK_OK")" | cut -f6)"

# Round-owed, and the two facts arriving on one row.
CR_REQ='[{"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"}}]'
t head-round-owed-green owed "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-still-owed owed "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-is-red red "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f4)"
# Verdicts are opinions about a tree. A stale change request does not wake the
# builder for a head that reviewer has not seen.
CR_STALE='[{"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"oldhead"}}]'
t head-round-stale-change-request - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_STALE")" | cut -f5)"
# latestOpinionatedReviews retains the standing blocker even if a later plain
# review comment displaced it from gh-pr-list's latestReviews. Carry the empty
# commit oid that listing exposes as a trap: reading or head-filtering that
# field would turn this owed round into a silent stall.
COMMENT_MASKED="$(mk_prc "$CHK_OK" "$CR_REQ" \
  | jq '.[0].latestReviews=[
      {state:"COMMENTED",author:{login:"p1"},commit:{oid:""}}
    ]')"
t head-round-comment-does-not-mask-change owed \
  "$(hc '["p1"]' "$COMMENT_MASKED" | cut -f5)"
# GraphQL has already reduced a same-head request-changes → approve flip to the
# reviewer's latest opinionated verdict.
CR_FLIPPED='[{"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}}]'
t head-round-flipped-to-approve - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_FLIPPED")" | cut -f5)"
# An outstanding panel request means the round is not whole yet.
t head-round-not-whole - \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$CR_REQ" '[{"login":"p2"}]')" | cut -f5)"
# An all-approved completed round is not builder work.
ALL_APPROVED='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"APPROVED","author":{"login":"p2"},"commit":{"oid":"abc1234"}}
]'
t head-round-all-approved - \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$ALL_APPROVED")" | cut -f5)"
# ceremony#207: two current-head blockers and one approval, with the whole
# requested panel returned, produces one owed row (and therefore one wake).
CEREMONY_207='[
  {"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"CHANGES_REQUESTED","author":{"login":"p2"},"commit":{"oid":"abc1234"}},
  {"state":"APPROVED","author":{"login":"p3"},"commit":{"oid":"abc1234"}}
]'
t head-round-ceremony-207-one-wake 1 \
  "$(hc '["p1","p2","p3"]' "$(mk_prc "$CHK_OK" "$CEREMONY_207")" \
    | awk -F'\t' '$5 == "owed" {n++} END {print n+0}')"
# The row's existing number+updatedAt identity remains ledger-compatible: once
# a completed session acknowledges this exact round, the next tick is quiet.
ACK_ROUND="$TMP/head-round-ack"
ACK_ITEM="$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_REQ")" \
  | awk -F'\t' '$5 == "owed" {print $1, $2}')"
printf '%s\n' "$ACK_ITEM" | ledger_commit "$ACK_ROUND"
t head-round-already-acknowledged 0 \
  "$(printf '%s\n' "$ACK_ITEM" | ledger_filter "$ACK_ROUND" | n)"

# The three round-close siblings agree on the same closed, non-approved round.
# addressing=true, round_owed=owed, converged=false.
CROSS_PR="$(jq -cn --argjson reviews "$CEREMONY_207" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-addressing true \
  "$(printf '%s' "$CROSS_PR" | jq -r --argjson panel '["p1","p2","p3"]' \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-round-owed owed \
  "$(hc '["p1","p2","p3"]' "$(mk_prc "$CHK_OK" "$CEREMONY_207")" | cut -f5)"
t round-siblings-converged false \
  "$(printf '%s' "$CROSS_PR" | jq -r --argjson panel '["p1","p2","p3"]' \
    --arg needs_human state:needs-human -f "$SHARED/lib/jq/converged.jq")"

# --- the ci-red ledger key: why the head is the ID, not the value (#17) -------
# ledger_filter re-fires when the value sorts GREATER, and a SHA has no order.
# This is the negative control for the scheme NOT used: keyed the ordinary way,
# a corrective push whose oid happens to sort below the previous one is
# suppressed — the wake would be lost exactly when the builder fixed something.
CLG_NAIVE="$TMP/ci-naive"
printf 'o/r#7 fff0000\n' | ledger_commit "$CLG_NAIVE"
t ci-red-naive-sha-value-loses-the-push 0 \
  "$(printf 'o/r#7 000ffff\n' | ledger_filter "$CLG_NAIVE" | n)"
# The scheme the module uses: head in the id, fixed sentinel value.
CLG="$TMP/ci-red"
printf 'o/r#7@fff0000\thead\n' | ledger_commit "$CLG"
t ci-red-new-head-wakes 1 "$(printf 'o/r#7@000ffff\thead\n' | ledger_filter "$CLG" | n)"
t ci-red-same-head-quiet 0 "$(printf 'o/r#7@fff0000\thead\n' | ledger_filter "$CLG" | n)"
# ...and an unchanged red head is reported rather than silently dropped (#59).
t ci-red-same-head-reported "o/r#7@fff0000" \
  "$(printf 'o/r#7@fff0000\thead\n' | ledger_suppressed "$CLG" | cut -f1)"

# --- the module's row slicing ------------------------------------------------
# The awk programs are asserted literally against the module AND run here on a
# fixture. Neither alone is enough: the grep proves the module still contains
# this expression, the fixture proves the expression is right. Edit both and
# the behaviour is still checked; edit the module alone and the grep fails.
BMOD="$SHARED/lib/duty-builder.sh"
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_ROUNDS='$5 == "owed" && ($4 == "green" || $4 == "none") { print $1, $2 }'
# shellcheck disable=SC2016
AWK_BLOCKED='$5 == "owed" && $4 == "red" { print $1 }'
# shellcheck disable=SC2016
AWK_HELD='$5 == "owed" && $4 == "pending" { print $1 }'
# shellcheck disable=SC2016
AWK_RED='$4 == "red" { print $1 "@" $3 "\thead\t" $6 }'
for pair in "rounds:$AWK_ROUNDS" "blocked:$AWK_BLOCKED" "held:$AWK_HELD" "red:$AWK_RED"; do
  if grep -Fq "${pair#*:}" "$BMOD"; then r1=present; else r1=MISSING; fi
  t "ci-red-awk-in-module-${pair%%:*}" present "$r1"
done
ROWS="$(printf '%s\n' \
  "$(printf 'o/r#1\tT1\taaa\tred\towed\tcheck (FAILURE)')" \
  "$(printf 'o/r#2\tT2\tbbb\tgreen\towed\t-')" \
  "$(printf 'o/r#3\tT3\tccc\tred\t-\tcheck (FAILURE)')" \
  "$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# #45: the red-headed round is NOT a build wake — and neither is the pending
# one (danmt's ruling, #64). Opening a round while the check is still running
# spends the panel on a head that may go red, which is what #45 measured on
# crew#40. Only o/r#2 (green) survives; o/r#4 (pending) is now held.
t ci-red-rounds-exclude-red "$(printf 'o/r#2 T2')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$ROWS")"
# ...but neither hold is silent — the operator is told which round is held and
# why, and the two reasons are NOT interchangeable: red is the author's own
# work, pending is a wait that nobody owes anything for.
t ci-red-blocked-round-named "o/r#1" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$ROWS")"
t ci-red-held-round-named "o/r#4" "$(awk -F'\t' "$AWK_HELD" <<<"$ROWS")"
# A pending head must NOT wake ci-red: nothing has failed, so there is no
# investigation to launch and no rerun to cap.
t pending-head-does-not-wake-ci-red "" \
  "$(awk -F'\t' "$AWK_RED" <<<"$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# The two hold messages must not be the same string, or the pending hold reads
# as "CI first, fix it" and tells the operator the author owes work.
RED_MSG="$(grep -c 'the check at its head is RED' "$BMOD")"
HELD_MSG="$(grep -c 'has not finished' "$BMOD")"
t hold-messages-are-distinct "1 1" "$RED_MSG $HELD_MSG"
# #17: every red head wakes, round owed or not.
t ci-red-items-both-heads "$(printf 'o/r#1@aaa\thead\tcheck (FAILURE)\no/r#3@ccc\thead\tcheck (FAILURE)')" \
  "$(awk -F'\t' "$AWK_RED" <<<"$ROWS")"

# codex's regression ask, end to end rather than at the classifier: a CANCELLED
# head with a round owed must not reach the build wake, and must reach the
# ci-red wake instead. The classifier tests above prove `red`; these prove the
# consequence, which is what #45 and #17 are actually about.
CANCEL_ROW="$(hc '["p1"]' "$(mk_prc "$CHK_CANCEL" "$CR_REQ")")"
t head-cancelled-round-is-blocked "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$CANCEL_ROW")"
t head-cancelled-wakes-ci-red "o/r#1@abc1234" \
  "$(awk -F'\t' "$AWK_RED" <<<"$CANCEL_ROW" | cut -f1)"
t head-cancelled-named-in-the-wake "check (CANCELLED)" "$(cut -f6 <<<"$CANCEL_ROW")"

# --- the ceremony#163 regression case (#17's last acceptance criterion) ------
# The incident this issue was filed from, modelled end to end: a PR with
# current-head approvals from the full panel, mergeable, no changes requested,
# no conflict, no outstanding review request — and `release-exercise /
# fixture-chain` failed during job SETUP on an HTTP 429 fetching
# actions/checkout, so none of the PR's code ever ran. Every wake condition the
# builder had looked past it, and the PR sat.
C163_REVIEWS='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"deadbee"}},
  {"state":"APPROVED","author":{"login":"p2"},"commit":{"oid":"deadbee"}}
]'
C163="$(jq -cn --argjson lr "$C163_REVIEWS" --argjson c "$CHK_BAD" \
  '[{number:163, isDraft:false, updatedAt:"T9", headRefOid:"deadbee",
     statusCheckRollup:$c, latestOpinionatedReviews:$lr, reviewRequests:[]}]')"
C163_ROW="$(hc '["p1","p2"]' "$C163")"
# It owes no round — which is precisely why nothing woke for it before.
t c163-no-round-owed - "$(cut -f5 <<<"$C163_ROW")"
# It is red, so it wakes now.
t c163-head-is-red red "$(cut -f4 <<<"$C163_ROW")"
t c163-wakes-the-author "o/r#163@deadbee" \
  "$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW" | cut -f1)"
t c163-names-the-failing-job "release-exercise / fixture-chain (FAILURE)" \
  "$(cut -f6 <<<"$C163_ROW")"
# ...and it must NOT become a build wake: claiming a new issue is the thing
# that was wrong to do while this PR sat red.
t c163-not-a-build-wake "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$C163_ROW")"
# One session per head, then quiet. A second tick on the same red head must not
# buy a second rerun — the "no blind-rerun loop" criterion, as data.
C163_LG="$TMP/c163"
C163_ITEM="$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW")"
t c163-first-tick-fires 1 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
printf '%s\n' "$C163_ITEM" | ledger_commit "$C163_LG"
t c163-second-tick-quiet 0 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
# A corrective push is a new head, and wakes regardless of how the oid sorts.
t c163-corrective-push-wakes 1 \
  "$(printf 'o/r#163@0000001\thead\n' | ledger_filter "$C163_LG" | n)"

# --- wiring (#45/#17) --------------------------------------------------------
if grep -q 'statusCheckRollup' "$BMOD"; then r1=fetched; else r1=MISSING; fi
t ci-red-rollup-fetched fetched "$r1"
# No new API call: the rollup rides the listing the round signal was already
# fetching. Asserted as "requested exactly once on the authored-PR listing" —
# a second listing added for handoff would be a second occurrence.
# Comment lines are stripped first. The block above EXPLAINS that the rollup
# rides an existing call, so counting raw occurrences counts the explanation —
# a detector tripping on its own documentation, which this repo has now managed
# three separate times.
t ci-red-rollup-rides-round-listing 1 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'statusCheckRollup')"
if grep -q 'number,isDraft,reviewRequests,updatedAt,headRefOid,statusCheckRollup' "$BMOD"; then
  r1=shared
else
  r1=SEPARATE
fi
t ci-red-rollup-on-the-round-call shared "$r1"
# GitHub GraphQL connections cap first/last at 100. The later payload carries
# comments for round-answer detection; pin its live-valid page size.
if grep -q 'comments(last:100)' "$BMOD" \
  && ! grep -Eq 'comments\\((first|last):([1-9][0-9]{2,}|[2-9][0-9]{2})\\)' "$BMOD"; then
  r1=bounded
else
  r1=EXCESSIVE
fi
t builder-comments-page-live-valid bounded "$r1"
# round_owed reads before sessions, while request/convergence reads fresh
# afterward. Two GraphQL snapshots encode that separation; the meaningful
# hc_head/gql_head guard then catches a push between them.
t builder-review-payload-has-early-and-late-snapshots 2 \
  "$(grep -c 'pr_payload=.*gh api graphql' "$BMOD")"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '[ "$hc_head" = "$gql_head" ]' "$BMOD"; then r1=guarded; else r1=MISSING; fi
t builder-late-head-drift-defers-request guarded "$r1"
if grep -q '.seen-ci-red' "$BMOD"; then r1=ledgered; else r1=UNGUARDED; fi
t ci-red-signal-ledgered ledgered "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '.suppressed-ci-red.$slug' "$BMOD"; then r1=perrepo; else r1=SHARED; fi
t ci-red-suppression-perrepo perrepo "$r1"
# An idle tick must still write a line (#53): a block that logs only when it
# fires makes a quiet box and a busy box look identical.
if grep -q 'no ci-red duty' "$BMOD"; then r1=logged; else r1=SILENT; fi
t ci-red-idle-logs logged "$r1"
# #17's first acceptance criterion: the builder wakes for its own red PR BEFORE
# claiming another issue. Ordering in the file is the ordering in the tick.
ci_at="$(grep -n -- '--- CI-RED' "$BMOD" | head -1 | cut -d: -f1)"
build_at="$(grep -n -- '--- BUILD' "$BMOD" | head -1 | cut -d: -f1)"
if [ -n "$ci_at" ] && [ -n "$build_at" ] && [ "$ci_at" -lt "$build_at" ]; then
  r1=before
else
  r1=AFTER
fi
t ci-red-wakes-before-build before "$r1"
t ci-red-prompt-exists yes "$([ -f "$SHARED/prompts/ci-red.txt" ] && echo yes || echo NO)"
t ci-red-budget-defined yes \
  "$(grep -q '^TIMEOUT_CIRED=' "$SHARED/conf/roles/builder.conf" && echo yes || echo NO)"
# The doctrine half of #45, now the request half of #133: the green-check
# precondition is enforced by the ENGINE (_request_panel requests only on a
# green or absent head) and the prompt keeps green as a ruled term for the
# argued-exception the session still owns.
# shellcheck disable=SC2016  # the shell literal contains $check_state
if grep -q 'green|none)' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'GREEN IS A RULED TERM' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=stated
else
  r1=SILENT
fi
t round-rules-state-green-head stated "$r1"
# ...including the exception, or the rule becomes one agents route around
# silently instead of arguing with in the open.
if grep -q 'argued exception' "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
t round-rules-state-exception stated "$r1"

# --- re-request by head, not by verdict (danmt, #64 round) -------------------
# BUILDER.md and build.txt both said to re-request "exactly the non-approvers",
# while converged.jq counts an approval ONLY at the current head:
#
#   map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid) | ...)
#     as $head_approvers
#   | (($panel - $head_approvers) | length == 0) as $panel_approves
#
# So the moment a fix round pushes a commit, an earlier approver goes stale, is
# not re-requested, never re-approves, and $panel - $head_approvers is never
# empty — the handoff wake cannot fire and the PR stalls looking finished. The
# same silent-stall shape as the reviewDecision bug (ceremony#26/#39). This PR
# was itself a live instance: grok approved at e13b0dd, the rebase onto #57
# moved the head, and re-requesting only the two change-requesters would have
# left it unconvergeable.
#
# rebase.txt already had the principle right — it is the one prompt where a
# push is guaranteed. Asserting the invariant rather than the prose: the
# predicate keys on the head, so the prompts that tell a builder whom to
# re-request must say head.
# shellcheck disable=SC2016  # the jq literal converged.jq contains
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/converged.jq"; then
  r1=head-keyed
else
  r1=CHANGED
fi
t converged-counts-approvals-at-head head-keyed "$r1"
# The invariant is unchanged; #133 MOVED the actor. "Re-request by head, not by
# verdict" now lives in request-panel.jq, which returns every panelist not
# approving the CURRENT head (approvers included after a push) — so the
# head-keying that used to have to survive in prompt prose survives as code.
# shellcheck disable=SC2016  # the jq literal contains $pr.headRefOid
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/request-panel.jq"; then r1=head-keyed; else r1=CHANGED; fi
t requestpanel-keys-on-head head-keyed "$r1"
# The prompts must tell the builder the ENGINE requests — a builder still told to
# re-request would race the engine and the reconciler.
for p in build.txt fragment-round-rules.txt; do
  if grep -qi 'engine' "$SHARED/prompts/$p" && grep -qiE 'do not request|engine requests|engine (does|then requests)' "$SHARED/prompts/$p"; then
    r1=stated
  else
    r1=SILENT
  fi
  t "rerequest-moved-to-engine-$p" stated "$r1"
done
# The no-push half survives, now engine-side: request-panel.jq re-requests a
# change-requester still AT the current head once the round is signalled answered
# (proved by rp-no-push-cr-at-head-requests-cr-er above), and the prompt names
# that case so the builder knows an argument-only answer still reaches the panel.
if grep -qi 'pushed nothing' "$SHARED/prompts/fragment-round-rules.txt"; then r1=carved; else r1=MISSING; fi
t rerequest-no-push-half-engine-side carved "$r1"
if grep -q 'AUTO_APPROVE_REREQUEST' "$SHARED/conf/fleet.defaults.conf"; then r1=present; else r1=GONE; fi
t auto-approve-rerequest-still-backs-the-carveout present "$r1"

# --- #114: the auto-approve must read the verdict's STATE, not just its head -
# The re-request rule (ceremony#94) existed to stop a STALE verdict blocking a
# tree that has not changed. It never consulted the verdict's state, so a
# re-request over a standing CHANGES_REQUESTED at an unchanged head was answered
# with a boilerplate approval — 3 of its 4 recorded fires rubber-stamped a live
# block. rereq_decision is that policy as a pure function; pin every transition.
# A live block (CHANGES_REQUESTED / DISMISSED) queues a real review; only a
# standing APPROVED still auto-approves. Definition-only at the top level, so
# sourcing costs nothing and runs nothing.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-review.sh"
RR_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RR_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RR_T1="2026-07-28T10:00:00Z"; RR_T2="2026-07-28T11:00:00Z"
t rereq-approved-rerequest-auto-approves auto-approve "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 1)"
t rereq-changes-requested-queues         queue        "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 1)"
t rereq-dismissed-queues                 queue        "$(rereq_decision "$RR_H" "$RR_H" DISMISSED "$RR_T1" "$RR_T2" 1)"
t rereq-moved-head-queues                queue        "$(rereq_decision "$RR_OLD" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 1)"
t rereq-covered-no-newer-request-skips   skip         "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T2" "$RR_T1" 1)"
t rereq-covered-no-request-at-all-skips  skip         "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" - 1)"
# --- #151: AUTO_APPROVE_REREQUEST gates the APPROVE, never the re-request -----
# The flag sat in front of the whole timestamp comparison, so auto=0 collapsed
# both branches to skip: a standing block plus a newer re-request at an
# unchanged head was answered `skip` every tick, forever, and the round could
# not converge (ceremony#207, 37 minutes, cleared by hand). The suite had the
# hole too — five transitions pinned at auto=1 and exactly one at auto=0, and
# that one was the APPROVED case, so nothing asked what a live block did with
# the flag off. The flag now decides one thing only: approve, or queue a real
# review. Whether a newer re-request is consulted at all is not its business.
t rereq-auto-off-block-queues-not-skips  queue        "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 0)"
t rereq-auto-off-dismissed-queues        queue        "$(rereq_decision "$RR_H" "$RR_H" DISMISSED "$RR_T1" "$RR_T2" 0)"
t rereq-auto-off-never-approves          skip         "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 0)"
# Double-submit protection is untouched at BOTH flag values (#26/#29/#39): a
# request no newer than my verdict is the genuine mid-clear/stale-index case.
t rereq-auto-off-no-newer-request-skips  skip         "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T2" "$RR_T1" 0)"
t rereq-auto-off-no-request-at-all-skips skip         "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" - 0)"
t rereq-auto-off-moved-head-queues       queue        "$(rereq_decision "$RR_OLD" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 0)"

# --- #114: submit-verdict admits the queued round's verdict, still refuses a
# bare re-post. The compounding half of the bug: once duty-review routes a
# post-CHANGES_REQUESTED re-request to a real review session, that session's
# considered verdict is at the SAME head my old verdict already covers, so the
# (me, PR, head) coverage gate refused it — a WRONG approval became a SILENTLY
# dropped verdict. The gate is now keyed (me, PR, head, round). A stateful gh
# shim exercises the real gate end-to-end: GET reviews cats a JSON array, POST
# appends to it so mine_at_head's post-count rises, graphql returns the round's
# "<mine_at> <req_at>", the head is fixed. This block is ALSO the regression
# guard the issue names as "must fail": revert submit-verdict's re-key and
# Scenario 1 refuses the verdict (count stays 1) and goes red.
SV="$SHARED/bin/submit-verdict.sh"
SVSHIM="$TMP/sv-shim"; mkdir -p "$SVSHIM"
cat >"$SVSHIM/gh" <<'SHIM'
#!/usr/bin/env bash
set -eu
[ "$1" = api ] || exit 3
sub="$2"
case "$sub" in
  user)    printf '%s\n' "$SVSHIM_ME";    exit 0 ;;
  graphql) printf '%s\n' "$SVSHIM_ROUND"; exit 0 ;;
esac
is_post=0; cid=""; event=""
for a in "$@"; do
  [ "$a" = POST ] && is_post=1
  case "$a" in commit_id=*) cid="${a#commit_id=}" ;; event=*) event="${a#event=}" ;; esac
done
case "$sub" in
  */reviews)
    if [ "$is_post" = 1 ]; then
      case "$event" in APPROVE) st=APPROVED ;; REQUEST_CHANGES) st=CHANGES_REQUESTED ;; *) st="$event" ;; esac
      tmp="$(mktemp)"
      jq --arg me "$SVSHIM_ME" --arg st "$st" --arg cid "$cid" \
        '. + [{user:{login:$me},state:$st,commit_id:$cid}]' "$SVSHIM_REVIEWS" >"$tmp"
      mv "$tmp" "$SVSHIM_REVIEWS"
      printf '{}\n'; exit 0
    fi
    cat "$SVSHIM_REVIEWS"; exit 0 ;;
  repos/*/pulls/*) printf '%s\n' "$SVSHIM_HEAD"; exit 0 ;;
esac
exit 3
SHIM
chmod +x "$SVSHIM/gh"
SV_H="cccccccccccccccccccccccccccccccccccccccc"
SV_BODY="$TMP/sv-body.txt"; printf 'considered verdict\n' >"$SV_BODY"
sv_reviews() { printf '%s' "$1" >"$TMP/sv-reviews.json"; }
sv_count()   { jq 'length' "$TMP/sv-reviews.json"; }
sv_run() {  # <round-ts "mine req"> <verdict> [--supersede-own]
  local round="$1" verdict="$2"; shift 2
  SVSHIM_ME=kimi-bot SVSHIM_HEAD="$SV_H" SVSHIM_ROUND="$round" \
  SVSHIM_REVIEWS="$TMP/sv-reviews.json" PATH="$SVSHIM:$PATH" DUTY_DIR="$TMP" \
    bash "$SV" o/r 1 "$SV_H" "$verdict" "$SV_BODY" "$@" >/dev/null 2>&1
}
SV_CR="[{\"user\":{\"login\":\"kimi-bot\"},\"state\":\"CHANGES_REQUESTED\",\"commit_id\":\"$SV_H\"}]"
SV_AP="[{\"user\":{\"login\":\"kimi-bot\"},\"state\":\"APPROVED\",\"commit_id\":\"$SV_H\"}]"

# Scenario 1 (AC3): a standing CR at head + a re-request NEWER than it → the
# queued round's verdict is ADMITTED and lands (count 1 → 2), exit 0.
sv_reviews "$SV_CR"
if sv_run "2026-07-28T10:00:00Z 2026-07-28T11:00:00Z" request-changes; then r1=0; else r1=$?; fi
t submit-newround-admitted-rc 0 "$r1"
t submit-newround-verdict-landed 2 "$(sv_count)"

# Scenario 2 (AC4): a standing CR at head + NO newer re-request (my review is
# newer than the last request) → refused as already-present, no post (count 1).
sv_reviews "$SV_CR"
if sv_run "2026-07-28T11:00:00Z 2026-07-28T10:00:00Z" request-changes; then r1=0; else r1=$?; fi
t submit-bare-repost-rc 0 "$r1"
t submit-bare-repost-no-verdict 1 "$(sv_count)"

# Scenario 3: --supersede-own (the auto-approve path) never reaches the new
# gate — it still supersedes and lands regardless of round state (count 1 → 2).
sv_reviews "$SV_AP"
if sv_run "2026-07-28T11:00:00Z 2026-07-28T10:00:00Z" approve --supersede-own; then r1=0; else r1=$?; fi
t submit-supersede-still-lands-rc 0 "$r1"
t submit-supersede-still-lands 2 "$(sv_count)"

# --- the gate is a whitelist: green or none (danmt's ruling, #64) ------------
# Codex asked for `$4 == "green"`. The ruling took the pending half of that and
# refused the `none` half, because the two are not the same fact: pending is
# transient and resolves itself, `none` is terminal. These tests pin BOTH
# halves, so neither can be reintroduced by someone who reads only one of them.
GATE_ROWS="$(printf '%s\n' \
  "$(printf 'o/noci#1\tT1\taaa\tnone\towed\t-')" \
  "$(printf 'o/q#2\tT2\tbbb\tpending\towed\t-')" \
  "$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')" \
  "$(printf 'o/x#4\tT4\tddd\tred\towed\tcheck (FAILURE)')")"
t gate-admits-green-and-none "$(printf 'o/noci#1 T1\no/g#3 T3')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$GATE_ROWS")"
t gate-holds-red "o/x#4" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$GATE_ROWS")"
t gate-holds-pending "o/q#2" "$(awk -F'\t' "$AWK_HELD" <<<"$GATE_ROWS")"
# The `none` half, as a standing negative control. A repo with no CI configured
# is `none` FOREVER, so a gate of `$4 == "green"` does not delay its owed
# rounds — it retires them, and the engine can never open a review round in
# that repo again. head-checks.jq rules `none` a state of its own for exactly
# this reason; the gate has to agree with the classifier.
t gate-green-only-would-strand-the-ci-less-repo "o/g#3 T3" \
  "$(awk -F'\t' '$5 == "owed" && $4 == "green" { print $1, $2 }' <<<"$GATE_ROWS")"
# Every owed round is accounted for — admitted, held-red or held-pending. A
# state that falls out of all three is a round nobody wakes for and nobody
# reports, which is the silent-stall shape this whole PR is against.
t gate-partitions-every-owed-round 4 \
  "$(awk -F'\t' '$5 == "owed" && ($4 == "green" || $4 == "none" || $4 == "red" || $4 == "pending") { c++ } END { print c+0 }' <<<"$GATE_ROWS")"

# What the gate owes for admitting a head with NO evidence: name it. Same
# assert-the-literal-AND-run-it discipline as the row slicing above.
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_NOCHECK='$5 == "owed" && $4 == "none" { s = s (s ? "; " : "") $1 " (no checks configured)" } END { print s }'
if grep -Fq "$AWK_NOCHECK" "$BMOD"; then r1=present; else r1=MISSING; fi
t nocheck-awk-in-module present "$r1"
t nocheck-heads-named "o/noci#1 (no checks configured)" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$GATE_ROWS")"
# A green-only set must produce the empty string, which is what the module
# turns into "-" — a literal "" reaching the prompt would read as a bug.
t nocheck-empty-when-all-green "" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')")"
# The datum has to REACH the session, or naming it in the log helps nobody:
# the slot exists in the prompt and the module fills it.
if grep -q '{{HEAD_CHECKS}}' "$SHARED/prompts/build.txt"; then r1=slotted; else r1=MISSING; fi
t build-prompt-has-head-checks-slot slotted "$r1"
# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q 'HEAD_CHECKS="\$head_checks"' "$BMOD"; then r1=rendered; else r1=MISSING; fi
t build-prompt-head-checks-rendered rendered "$r1"
# render_prompt leaves an unfilled slot in place verbatim, so a slot nobody
# fills would ship "{{HEAD_CHECKS}}" to the model as if it were prose.
printf 'checks: {{HEAD_CHECKS}}' >"$TMP/prompts/hc.txt"
t head-checks-slot-substitutes "checks: o/q#2 (pending)" \
  "$(render_prompt hc.txt HEAD_CHECKS="o/q#2 (pending)")"

# Pending-is-not-green is now the ENGINE's gate (head-checks.jq is_pending; the
# request holds on anything but green/none — wait, do not abandon), and the
# prompt still says a queued or running check has not answered, so the session
# waits to signal until the check settles.
if grep -q 'def is_pending' "$SHARED/lib/jq/head-checks.jq" \
  && grep -qi 'queued or running check has not answered' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=ruled
else
  r1=SILENT
fi
t round-rules-rule-pending ruled "$r1"
# ...with the one carve-out that keeps a CI-less repo from waiting forever for
# a check that is never coming — the same `none` case as the gate above.
if grep -qi 'NO checks configured' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=carved
else
  r1=MISSING
fi
t round-rules-carve-out-no-checks carved "$r1"
# The ruled classification is ceremony's (BUILDER.md, operator 2026-07-27) and
# the classifier already implements it; the prompt must not disagree with
# either. cancelled/stale not green, skipped/neutral green.
for term in 'cancelled or stale' 'skipped or neutral'; do
  if grep -qi "$term" "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
  t "round-rules-ruled-classification-${term// /-}" stated "$r1"
done

# --- the duty order on paper matches the duty order in the code -------------
# FLEET.md states the fleet-standard order and points at these files as the
# mechanism; ceremony#190 merged that order with ci-red in it. A header that
# lags the module order is how the #149 drift went unnoticed, so it is
# asserted rather than remembered (grok, #64).
for f in bin/duty.sh lib/duty-builder.sh README.md; do
  if grep -q 'resume → ci-red' "$SHARED/$f"; then r1=named; else r1=STALE; fi
  t "duty-order-names-ci-red-${f//\//-}" named "$r1"
done
# Handoff is deliberately NOT gated on a green head, and the reason has to sit
# where the "obvious improvement" would be typed (grok, #64): ci-red fires once
# per head, so a green-gated handoff strands exactly ceremony#163 again.
if awk '/--- HANDOFF/,/--- REBASE/' "$BMOD" | grep -q 'NOT GATED ON A GREEN HEAD'; then
  r1=called-out
else
  r1=SILENT
fi
t handoff-green-gating-called-out called-out "$r1"

# --- configurable doctrine keeps the shipped prompts byte-identical (#76) ---
saved_prompts_dir="$PROMPTS_DIR"
PROMPTS_DIR="$SHARED/prompts"
# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=AGENTS.md DOCTRINE_TRIAGE=TRIAGE.md \
  DOCTRINE_BUILDER=BUILDER.md DOCTRINE_REVIEWER=REVIEWER.md
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  expected="$(sed \
    -e 's/{{DOCTRINE_ENTRYPOINT}}/AGENTS.md/g' \
    -e 's/{{DOCTRINE_TRIAGE}}/TRIAGE.md/g' \
    -e 's/{{DOCTRINE_BUILDER}}/BUILDER.md/g' \
    -e 's/{{DOCTRINE_REVIEWER}}/REVIEWER.md/g' "$prompt_path")"
  t "doctrine-default-byte-identical-$prompt_name" "$expected" \
    "$(render_prompt "$prompt_name")"
done

# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=GUIDE.md DOCTRINE_TRIAGE=OPERATE.md \
  DOCTRINE_BUILDER=CREATE.md DOCTRINE_REVIEWER=VERIFY.md
doctrine_leaks=""
doctrine_unresolved=""
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  rendered="$(render_prompt "$prompt_name")"
  if printf '%s' "$rendered" | grep -Eq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md'; then
    doctrine_leaks="$doctrine_leaks $prompt_name"
  fi
  if printf '%s' "$rendered" | grep -q '{{DOCTRINE_'; then
    doctrine_unresolved="$doctrine_unresolved $prompt_name"
  fi
done
t doctrine-custom-no-shipped-name-leaks "" "$doctrine_leaks"
t doctrine-custom-no-unresolved-slots "" "$doctrine_unresolved"
if grep -REq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md' "$SHARED/prompts"; then
  r1=HARDCODED
else
  r1=slotted
fi
t doctrine-templates-have-no-hardcoded-paths slotted "$r1"
PROMPTS_DIR="$saved_prompts_dir"

# --- crew host: one repo belongs to one fleet (#70) ----------------------
# The check consumes GitHub's shared board state, never another fleet's
# machine. Exercise it through `up --dry-run`: no box or registry mutation is
# needed to notice a foreign claim, and the same checkpoint runs for hire.
OFROOT="$TMP/overlap-fleet"
OFSHIM="$TMP/overlap-bin"
mkdir -p "$OFROOT" "$OFSHIM"
printf 'fixture-box claude builder\n' >"$OFROOT/fleet.roster"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
printf 'FLEET_BENCH="local-reviewer"\nFLEET_TRIAGE="local-triage"\nFLEET_HUMAN="local-operator"\n' \
  >"$OFROOT/fleet.conf"
cat >"$OFSHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$OFSHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "${FOREIGN_ACTOR:-}" in
  "") printf '[{"type":"IssuesEvent","actor":{"login":"local-triage"},"payload":{"action":"opened"}}]\n' ;;
  *)  printf '[{"type":"IssuesEvent","actor":{"login":"%s"},"payload":{"action":"assigned","assignee":{"login":"%s"}}}]\n' \
        "$FOREIGN_ACTOR" "$FOREIGN_ACTOR" ;;
esac
EOF
chmod +x "$OFSHIM/box" "$OFSHIM/gh"
before_registry="$(cat "$OFROOT/repos.txt")"
GH_CALLS="$TMP/overlap-gh-calls"
overlap_out="$(env CREW_CONFIG_DIR="$OFROOT" FOREIGN_ACTOR=other-builder GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$overlap_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-names-repo-and-foreign-actor named "$r1"
case "$overlap_out" in *"registries LEFT UNCHANGED"*"operators must decide"*) r1=operator ;; *) r1=actioned ;; esac
t fleet-overlap-resolution-is-operator operator "$r1"
t fleet-overlap-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

disjoint_out="$(env CREW_CONFIG_DIR="$OFROOT" GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$disjoint_out" in *"WARN one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-disjoint-is-silent silent "$r1"
t fleet-disjoint-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"
if grep -q 'repos/fixture/outside/events' "$GH_CALLS"; then r1=QUERIED; else r1=silent; fi
t fleet-out-of-scope-activity-is-not-queried silent "$r1"

# --- install.sh: the operator agent-profile transport contract (#75) --------
# The ordering is the whole difficulty (codex Blocking 4 on #73): install.sh
# refuses an unknown agent BEFORE it creates conf/agents, so a profile that
# arrived only with the conf copy would fail its own validation — a vendor
# that lists in `crew profiles` and dies at `crew hire`. The host stages
# operator profiles into ~/duty/.crew-seed-agents ahead of the run; these
# fixtures assert every clause: a seeded profile passes validation, the
# operator copy is what conf/agents carries (same-name wins where load_conf
# reads), the seed is consumed on success AND failure, and an unseeded
# unknown agent still dies.
PHOME="$TMP/profile-home"
PDUTY="$PHOME/duty"
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/vendorx.conf" <<'EOF'
# vendorx — operator-supplied fixture vendor (never shipped)
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="vendorx"
AGENT_LOGIN_HINT="vendorx auth login"
bot_cli_probe() { return 0; }
bot_cli_present() { command -v vendorx >/dev/null 2>&1; }
EOF
profile_install() {
  env HOME="$PHOME" DUTY_DIR="$PDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
if profile_install --agent vendorx --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-validates-before-conf-exists 0 "$r1"
[ -f "$PDUTY/conf/agents/vendorx.conf" ] && r1=installed || r1=missing
t operator-profile-lands-in-conf-agents installed "$r1"
if grep -q 'operator-supplied fixture vendor' "$PDUTY/conf/agents/vendorx.conf" 2>/dev/null; then
  r1=operator
else
  r1=other
fi
t operator-profile-is-the-operator-copy operator "$r1"
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed consumed "$r1"
# The shipped set still installs whole beside the operator's addition.
[ -f "$PDUTY/conf/agents/claude.conf" ] && r1=present || r1=missing
t operator-profile-shipped-set-intact present "$r1"

# Same-name precedence: an operator claude.conf beats the shipped one — and
# the win must hold at RUNTIME, where load_conf sources whatever
# conf/agents carries (common.sh:34); settled in the copy, not by a reader.
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/claude.conf" <<'EOF'
# claude — operator override fixture
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="claude"
AGENT_LOGIN_HINT="operator override wins"
bot_cli_probe() { return 0; }
bot_cli_present() { return 0; }
EOF
profile_install --agent claude --role reviewer >/dev/null 2>&1
if grep -q 'operator override fixture' "$PDUTY/conf/agents/claude.conf" 2>/dev/null; then
  r1=operator
else
  r1=shipped
fi
t operator-profile-same-name-wins operator "$r1"
# shellcheck disable=SC2016  # $DUTY_DIR and $AGENT_LOGIN_HINT expand in the child shell
runtime_hint="$(env DUTY_DIR="$PDUTY" HOME="$PHOME" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_conf; printf %s "$AGENT_LOGIN_HINT"')"
t operator-profile-wins-at-load_conf "operator override wins" "$runtime_hint"

# The gap the contract closes, inverted: an agent nobody transported and
# nobody ships must still die at validation, not at first duty tick.
if profile_install --agent vendory --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-unknown-still-refused 1 "$r1"

# A one-install transport on FAILURE too: a failing install (here: a role
# that does not exist, checked after the agent) must not leave seeds behind
# for a later bare run to resurrect.
mkdir -p "$PDUTY/.crew-seed-agents"
printf '# vendorz — fixture\n' >"$PDUTY/.crew-seed-agents/vendorz.conf"
profile_install --agent vendorz --role nosuchrole >/dev/null 2>&1 || true
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed-on-failure consumed "$r1"

# --- valid_version: ONE gate, in install.sh and cli/crew, must not drift.
# The installer builds versions/<v> paths from a version, and cli/crew builds
# them for `crew use`/`uninstall` (heavy-duty/crew#96); a divergence is how a
# crafted version slips past one gate and into an rm/ln behind the other. box's
# test/cli.sh diffs its pair the same way. Assert the two copies are
# byte-identical, then drive the gate against the path-escaping shapes it exists
# to refuse.
vv_extract() { awk '/^valid_version\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$1"; }
t valid_version-parity "$(vv_extract "$ROOT/install.sh")" "$(vv_extract "$ROOT/cli/crew")"
eval "$(vv_extract "$ROOT/cli/crew")"
for bad in "" "." ".hidden" "-rf" "../evil" "a/b" "a b" "a;b"; do
  if valid_version "$bad"; then got=accept; else got=reject; fi
  t "valid_version-refuses[$bad]" reject "$got"
done
for ok in "0.1.0" "0.1.0-dev" "0.1.0-rc1" "1.2.3+meta"; do
  if valid_version "$ok"; then got=accept; else got=reject; fi
  t "valid_version-accepts[$ok]" accept "$got"
done

# --- cli/crew's self-description: the table is the source of truth (#97) ----
# The property under test is ANTI-DRIFT, not cosmetics. Before #97 the command
# list lived three times — the header comment printed as help, a hand-written
# dispatch case, and each verb's usage string — and it had already diverged.
# These assertions are what make "the help cannot drift from the code" a fact
# rather than a comment.
CLIBIN="$ROOT/cli/crew"
CLISHIM="$TMP/cli-bin"
mkdir -p "$CLISHIM"
cat >"$CLISHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CLISHIM/box"
crewcli() { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@"; }
crewrc()  { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1; echo $?; }

# Every row's function EXISTS. This is the assertion that makes the table safe
# to dispatch from: a row naming a function nobody wrote is a runtime
# "command not found" on a verb the help advertises.
missing_fn=""
while IFS='^' read -r verb _ _ fn; do
  [ -n "$verb" ] || continue
  grep -q "^$fn()" "$CLIBIN" || missing_fn="$missing_fn $verb->$fn"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-functions-exist "" "$missing_fn"

# Every row has a summary — an empty one renders a blank line in `crew help`,
# which is how a verb becomes invisible while still being dispatchable.
empty_sum=""
while IFS='^' read -r verb _ sum _; do
  [ -n "$verb" ] || continue
  [ -n "$sum" ] || empty_sum="$empty_sum $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-summaries-present "" "$empty_sum"

# ...and the REVERSE, which is the direction that actually rots: a verb
# implemented but never added to the table. The first version of this suite
# only checked table -> function, so a `cmd_usage` added by a later PR would
# have been dispatchable-by-nobody and invisible in `crew help` with every
# assertion green. Found while rebasing onto #95, which is exactly when a
# sibling PR could have introduced one.
orphan=""
while read -r fn; do
  grep -qF "^$fn\"" "$CLIBIN" || orphan="$orphan $fn"
done < <(grep -oE '^cmd_[a-z_]+\(\)' "$CLIBIN" | sed 's/()//')
t cli-every-verb-has-a-table-row "" "$orphan"

# Every verb appears in `crew help`, and `crew help <verb>` works for each.
help_all="$(crewcli help 2>&1)"
absent="" helpfail=""
while IFS='^' read -r verb _ _ _; do
  [ -n "$verb" ] || continue
  case "$help_all" in *"  $verb "*) : ;; *) absent="$absent $verb" ;; esac
  [ "$(crewrc help "$verb")" = 0 ] || helpfail="$helpfail $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-help-lists-every-verb "" "$absent"
t cli-help-per-command-works "" "$helpfail"

# The two exit codes, which is the whole reason for the split: a caller must
# be able to tell "you typo'd" from "the fleet is broken".
t cli-unknown-command-is-2   2 "$(crewrc nonsensecommand)"
t cli-missing-arg-is-2       2 "$(crewrc hire)"
t cli-unknown-flag-is-2      2 "$(crewrc floor --bogus)"
t cli-flag-before-verb-is-2  2 "$(crewrc --dry-run up)"
t cli-absent-box-is-1        1 "$(crewrc status nosuchbox)"
t cli-help-is-0              0 "$(crewrc help)"
t cli-version-is-0           0 "$(crewrc --version)"

# A value-taking flag with NO value is a malformed invocation, so it must exit
# 2 like every other one — not die through bash's own `set -u` unbound-variable
# handler at exit 1, which is what `$2` and `${2:?...}` both did (codex, review
# of #106). Every value-taking option on every verb, because the defect was
# per-site and so is the fix.
badval=""
for spec in "new --role" "new --agent" "new --name" "new --from" \
            "hire b --role" "hire b --agent" "hire b --ref" "hire-all --ref" \
            "floor --port" "floor --bind" "floor --user" "floor --pass" \
            "floor --interval" "floor --roster"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badval="$badval [$spec->$rc]"
done
t cli-missing-option-value-is-2 "" "$badval"

# ...and an EMPTY value is refused the same way, which is what the `${2:?}`
# sites already did and what the plain `$2` sites silently accepted.
t cli-empty-option-value-is-2 2 "$(crewrc new --agent "")"

# An unknown flag on the two one-liner parsers was SILENTLY IGNORED — worse
# than the wrong exit code, because `crew hire-all --dry-run` hired the whole
# fleet while reading like a rehearsal.
t cli-hire-all-unknown-flag-is-2 2 "$(crewrc hire-all --dry-run)"
t cli-up-unknown-flag-is-2       2 "$(crewrc up --bogus)"
t cli-up-dry-run-still-works     0 "$(crewrc up --dry-run)"
# ...and `crew upgrade --bogus` took the flag as a BOX NAME, printing
# "upgrade FAILED on --bogus" and exiting 0 — a report, not a verdict (kimi).
t cli-upgrade-unknown-flag-is-2  2 "$(crewrc upgrade --bogus)"

# The mirror of the missing-value case: an argument BEYOND the synopsis was
# silently ignored. `crew help hire unexpected` printed hire's help and exited
# 0 (codex, round 2). The verbs with while-loop parsers already refused these;
# the ones reading "${1:-}" positionally never looked.
overrun=""
for spec in "help hire junk" "status a b" "profiles junk" "down junk" \
            "create-all junk" "gold a b c"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || overrun="$overrun [$spec->$rc]"
done
t cli-excess-arguments-are-2 "" "$overrun"
# ...and the accepted forms still work, so the guard cannot over-reach.
t cli-help-one-arg-still-ok  0 "$(crewrc help hire)"
t cli-help-no-arg-still-ok   0 "$(crewrc help)"

# resolve_engine's ref failures split the same way (codex, round 3). Three are
# invocation faults — a shape that can never be valid, a ref resolving to
# nothing, a ref in the wrong form for the mode — and exit 2. Shared by
# `hire --ref`, `hire-all --ref` and `upgrade --ref`, so assert it on each.
badref=""
for spec in "upgrade --all --ref -bad" "hire somebox --ref -bad" "hire-all --ref -bad" \
            "upgrade --all --ref nosuchref-xyz"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badref="$badref [$spec->$rc]"
done
t cli-malformed-ref-is-2 "" "$badref"

# A typo points somewhere rather than only failing.
case "$(crewcli hier 2>&1)" in *"did you mean 'hire'"*) r1=suggested ;; *) r1=SILENT ;; esac
t cli-typo-suggests suggested "$r1"

# --version names the version AND the root: with two installs on PATH, the
# root is how you settle which crew you just ran.
ver_out="$(crewcli --version 2>&1)"
case "$ver_out" in "crew $(head -1 "$ROOT/VERSION" | tr -d '\r\n') ("*")") r1=named ;; *) r1="$ver_out" ;; esac
t cli-version-names-version-and-root named "$r1"

# `adopt` is retired but must not break a caller — and must not be advertised.
case "$(crewcli adopt 2>&1)" in *"'adopt' is now 'hire'"*) r1=warned ;; *) r1=SILENT ;; esac
t cli-adopt-alias-warns warned "$r1"
case "$help_all" in *adopt*) r1=ADVERTISED ;; *) r1=hidden ;; esac
t cli-adopt-not-in-help hidden "$r1"

# The header comment is no longer a second command list. It used to BE the
# help output, and it drifted; a reader who re-adds a verb table there
# re-creates the defect #97 closed.
# The shape being forbidden is a LISTING — an indented comment line that
# begins with `crew <verb>`, which is exactly how the old table was written
# and how it drifted. Prose that quotes a command mid-sentence is fine and is
# not what re-creates the defect; matching on that would forbid explaining it.
relisted="$(sed -n '2,/^set -euo pipefail/p' "$CLIBIN" | grep -cE '^#[[:space:]]+crew [a-z-]+' || true)"
t cli-header-is-not-a-command-list 0 "$relisted"

# --- shared-ci's draft gate: the suite does not run on unfinished trees (#136)
# Repo furniture, in the same family as valid_version-parity above: assertions
# about a file the engine never executes, kept here because the property is
# anti-drift and every way of losing it is silent. A reverted gate just starts
# costing the fleet 51% of its Actions minutes again; a gate that loses
# `ready_for_review` is worse, because it leaves a PR marked ready with no
# check at its head, which the round protocol cannot tell apart from a tree
# that failed.
CI_YML="$ROOT/.github/workflows/shared-ci.yml"

# The trigger must fire when the PR stops being a draft. Naming `types:` at all
# replaces GitHub's default set, so the default three are asserted alongside it
# — dropping `reopened` reintroduces the checkless-head case by omission.
ci_types=",$(sed -n 's/^ *types: *\[\(.*\)\].*$/\1/p' "$CI_YML" | tr -d ' '),"
for ev in opened synchronize reopened ready_for_review; do
  case "$ci_types" in *",$ev,"*) r1=present ;; *) r1=MISSING ;; esac
  t "shared-ci-trigger-fires-on[$ev]" present "$r1"
done

# The gate itself: the first `if:` under the `check` job.
ci_if="$(awk '/^  check:/{p=1} p && /^    if:/{print; exit}' "$CI_YML")"
case "$ci_if" in *github.event.pull_request.draft*) r1=payload ;; *) r1=MISSING ;; esac
t shared-ci-gates-on-the-draft-payload payload "$r1"

# MUST FAIL: a label gate. `state:building` is derived from this same draft bit
# by ceremony's reconciler, so gating on it would read a shadow of a fact
# already in the payload and inherit the reconciler's timing — and a label
# write that fails leaves a ready head with no check, in the merge path.
case "$ci_if" in *state:*|*label*) r1=LABEL ;; *) r1=payload-only ;; esac
t shared-ci-gate-is-not-a-label payload-only "$r1"

# The push-to-main path has no draft concept, and stays exempt in the
# expression rather than through GitHub's null-to-false coercion — which is
# correct but invisible in the source, on the branch that gates main.
case "$ci_if" in *github.event_name*) r1=explicit ;; *) r1=COERCION ;; esac
t shared-ci-push-exemption-is-explicit explicit "$r1"
t shared-ci-still-triggers-on-push-to-main 1 "$(grep -c '^    branches: \[main\]$' "$CI_YML")"

# Both triggers keep the SAME path filter. #136 touched the trigger types and
# added a job gate and must not have touched these; a list that drifts between
# the two means a file is guarded on main but not on PRs, or the reverse.
t shared-ci-has-two-path-filters 2 "$(grep -c '^    paths: ' "$CI_YML")"
t shared-ci-path-filters-agree   1 "$(grep '^    paths: ' "$CI_YML" | sort -u | wc -l | tr -d ' ')"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
