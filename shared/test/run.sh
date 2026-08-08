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

assert_doctrine_quote() {  # <prompt-file> <substring> <name> [doctrine-heading]
  local prompt_file="$1" substring="$2" name="$3" doctrine_heading="${4-}"
  local prompt_text doctrine_text result
  prompt_text="$(tr -s '[:space:]' ' ' <"$prompt_file")"
  doctrine_text="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/BUILDER.md")"
  result=DIVERGED
  if grep -Fq -- "$substring" <<<"$prompt_text"; then
    if [ -n "$doctrine_heading" ]; then
      # A cited section must be an exact Markdown heading. This deliberate
      # line-based exception distinguishes a heading from matching prose.
      grep -Fxq -- "$doctrine_heading" "$ROOT/.ceremony/BUILDER.md" \
        && result=agreed
    elif grep -Fq -- "$substring" <<<"$doctrine_text"; then
      result=agreed
    fi
  fi
  t "$name" agreed "$result"
}

# Phase 0 stages the whole tracked tree except fleet-floor/dev, then verifies
# the repository roots this suite names before running it. Keep that explicit
# verifier and archive selection from falling behind new literal root paths.
phase0_suite_paths() {  # phase0_suite_paths <suite>
  # shellcheck disable=SC2016  # match literal root expressions in the suite
  grep -oE '\$(ROOT|\{ROOT\})/[.[:alnum:]_/-]+' "$1" \
    | sed -E 's#^\$(ROOT|\{ROOT\})/##' \
    | sort -u || true
}

phase0_suite_roots() {  # phase0_suite_roots <suite>
  phase0_suite_paths "$1" | cut -d/ -f1 | sort -u
}

phase0_verified_roots() {  # phase0_verified_roots <rehearsal>
  # shellcheck disable=SC2016  # match the literal stage expression in rehearsal
  sed -n '/BEGIN phase-0 suite roots/,/END phase-0 suite roots/p' "$1" \
    | grep -oE '\$stage/[.[:alnum:]_-]+' \
    | sed 's|^\$stage/||' \
    | sort -u || true
}

phase0_archive_result() {  # phase0_archive_result <rehearsal>
  local selection archive_commands exclusions
  selection="$(sed -n '/BEGIN phase-0 archive selection/,/END phase-0 archive selection/p' "$1")"
  [ -n "$selection" ] || { printf '%s\n' empty-archive-selection; return; }
  # shellcheck disable=SC2016  # match literal phase-0 variable references
  archive_commands="$(printf '%s\n' "$selection" \
    | grep -cF 'git -C "$SOURCE_TREE" archive --format=tar "$SOURCE_SHA"' || true)"
  exclusions="$(printf '%s\n' "$selection" | grep -oF ':(exclude)' | wc -l)"
  if [ "$archive_commands" -ne 1 ] \
    || ! printf '%s\n' "$selection" | grep -Fq -- "-- . ':(exclude)fleet-floor/dev'" \
    || [ "$exclusions" -ne 1 ]; then
    printf '%s\n' archive-selection-mismatch
  else
    printf '%s\n' covered
  fi
}

phase0_coverage_result() {  # phase0_coverage_result <suite> <rehearsal>
  local paths roots verified missing archive_result
  paths="$(phase0_suite_paths "$1")"
  [ -n "$paths" ] || { printf '%s\n' empty-suite-roots; return; }
  roots="$(phase0_suite_roots "$1")"
  verified="$(phase0_verified_roots "$2")"
  [ -n "$verified" ] || { printf '%s\n' empty-verified-roots; return; }
  missing="$(comm -23 \
    <(printf '%s\n' "$roots") \
    <(printf '%s\n' "$verified"))"
  if [ -n "$missing" ]; then
    printf 'missing:%s\n' "$(printf '%s\n' "$missing" | paste -sd, -)"
  elif printf '%s\n' "$paths" | grep -Eq '^fleet-floor/dev(/|$)'; then
    printf '%s\n' excluded:fleet-floor/dev
  else
    archive_result="$(phase0_archive_result "$2")"
    [ "$archive_result" = covered ] \
      && printf '%s\n' covered \
      || printf 'archive:%s\n' "$archive_result"
  fi
}

t phase0-verifier-covers-suite-roots covered \
  "$(phase0_coverage_result "$HERE/run.sh" "$ROOT/drill/rehearsal.sh")"

# Source common.sh against a scratch DUTY_DIR.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck disable=SC1091
source "$SHARED/lib/common.sh"
# shellcheck disable=SC1091
source "$SHARED/lib/duty-builder.sh"

# #411: force the box-existence producer to pause after its matching line.
# The stub is deliberately `box list`, so this exercises the predicate's
# contract at its real boundary. The former pipeline returns 141 when the
# producer wakes and writes the final name after grep has exited successfully.
box_exists_source="$(sed -n '/^box_exists()/p' "$ROOT/cli/crew")"
eval "$box_exists_source"
# shellcheck disable=SC2317  # called by the box_exists body loaded through eval
box() {
  [ "${1:-}" = list ] || return 2
  printf '%s\n' crew-drill crew-drill-triage
  sleep 0.05
  printf '%s\n' crew-drill-builder
}
# shellcheck disable=SC2317  # called by the box_exists body loaded through eval
box_names() { box list; }
if box_exists crew-drill-triage; then r1=found; else r1=MISSED; fi
t box-exists-survives-a-descheduled-producer found "$r1"
if box_exists someone-elses-box; then r1=FALSE-POSITIVE; else r1=absent; fi
t box-exists-keeps-the-negative-direction absent "$r1"
unset -f box box_names box_exists
unset box_exists_source

# Keep ambient operator configuration out of fixture resolution. These static
# assertions make removing either half of the suite guard fail visibly.
if grep -Fqx 'unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG' "$HERE/run.sh"; then r1=guarded; else r1=MISSING; fi
t suite-unsets-ambient-crew-config guarded "$r1"
# shellcheck disable=SC2016  # Match the literal assignment in this file.
if grep -Fqx 'export XDG_CONFIG_HOME="$TMP/xdg-empty"' "$HERE/run.sh"; then r1=guarded; else r1=MISSING; fi
t suite-pins-empty-xdg-config guarded "$r1"

# --- #285: per-author repository panels ------------------------------------
PANEL_REPO="$TMP/panel-repo"
git init -q "$PANEL_REPO"
mkdir -p "$PANEL_REPO/.github"
cat >"$PANEL_REPO/.github/labels.conf" <<'EOF'
panel=full-a full-b builder-one
panel[builder-one]=author-a author-b builder-one
panel[hyphen-builder]=hyphen-a hyphen-b
EOF
git -C "$PANEL_REPO" add .github/labels.conf
git -C "$PANEL_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_REPO" update-ref refs/remotes/origin/main HEAD
t panel-author-line-preferred '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one)"
t panel-author-safety-subtraction '["author-a","author-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one | jq -c --arg me builder-one '. - [$me]')"
t panel-hyphen-author-literal '["hyphen-a","hyphen-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" hyphen-builder)"
t panel-missing-author-falls-back '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" unknown-builder)"

# A repo absent locally must choose the same author line from the contents API.
PANEL_API_CONF="$(base64 -w0 "$PANEL_REPO/.github/labels.conf")"
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-api-author-line '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/api "$TMP/not-cloned" builder-one)"
unset -f gh

# A stale/local config with no panel row retains the old contents-API fallback.
PANEL_EMPTY_REPO="$TMP/panel-empty-repo"
git init -q "$PANEL_EMPTY_REPO"
mkdir -p "$PANEL_EMPTY_REPO/.github"
printf '%s\n' 'scope:test|C5DEF5|fixture' >"$PANEL_EMPTY_REPO/.github/labels.conf"
git -C "$PANEL_EMPTY_REPO" add .github/labels.conf
git -C "$PANEL_EMPTY_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_EMPTY_REPO" update-ref refs/remotes/origin/main HEAD
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-local-without-panel-uses-api '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/stale "$PANEL_EMPTY_REPO" unknown-builder)"
unset -f gh

# With neither repository config path available, the fleet bench is unchanged.
# shellcheck disable=SC2034  # consumed dynamically by sourced panel_for_repo
PANEL_SAVED_BENCH="${FLEET_BENCH-}"
PANEL_BENCH_WAS_SET="${FLEET_BENCH+x}"
FLEET_BENCH='bench-a bench-b'
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { return 1; }
t panel-bench-fallback '["bench-a","bench-b"]' \
  "$(panel_for_repo owner/missing "$TMP/not-cloned" builder-one)"
unset -f gh
if [ -n "$PANEL_BENCH_WAS_SET" ]; then
  FLEET_BENCH="$PANEL_SAVED_BENCH"
else
  unset FLEET_BENCH
fi

# Both request and convergence paths must receive an author-aware roster.
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$R" "$dir" "$ME"' "$SHARED/lib/duty-builder.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-builder-resolution author_aware "$r1"
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$repo" "$WORK_DIR/${repo//\//__}-review" "$author"' "$SHARED/lib/duty-review.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-reviewer-resolution author_aware "$r1"
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq '_mark_addressing "$SRa" "$Na"' "$SHARED/lib/duty-review.sh" && \
    ! grep -Fq 'repos/$SRa/pulls/$Na' "$SHARED/lib/duty-review.sh"; then r1=payload-author; else r1=EXTRA-FETCH; fi
t panel-reviewer-reuses-payload-author payload-author "$r1"

# List prompt slots omitted by engine render sites. Calls are folded to one
# logical line first; advancing past only the opening "$(`` also finds nested
# render_prompt calls such as review.txt's ONESHOT_RULES argument.
render_site_missing_slots() {  # render_site_missing_slots PROMPTS SOURCE...
  local prompts="$1" source site call rest prompt slot supplied
  shift
  for source in "$@"; do
    while IFS='|' read -r site call; do
      [ -n "$call" ] || continue
      rest="${call#*render_prompt }"
      prompt="${rest%%[[:space:]]*}"
      [ -f "$prompts/$prompt" ] || continue
      supplied="$(printf '%s\n' "$call" | grep -oE '[A-Z_][A-Z_]*=' | tr -d '=' | sort -u)"
      while read -r slot; do
        [ -n "$slot" ] || continue
        case "$slot" in
          DOCTRINE_ENTRYPOINT|DOCTRINE_TRIAGE|DOCTRINE_BUILDER|DOCTRINE_REVIEWER) continue ;;
        esac
        if ! grep -qx "$slot" <<<"$supplied"; then
          printf '%s:%s: %s missing %s\n' "$source" "$site" "$prompt" "$slot"
        fi
      done < <(grep -oE '\{\{[A-Z_][A-Z_]*\}\}' "$prompts/$prompt" \
        | tr -d '{}' | sort -u)
    done < <(awk '
      function calls(text, line, rest, tail, endpos, call) {
        rest = text
        while (match(rest, /\$\(render_prompt[[:space:]]+/)) {
          tail = substr(rest, RSTART)
          endpos = index(tail, ")")
          call = endpos ? substr(tail, 1, endpos) : tail
          print line "|" call
          rest = substr(rest, RSTART + 2)
        }
      }
      {
        if (buf == "") start = NR
        buf = buf $0
        if (sub(/\\[[:space:]]*$/, "", buf)) next
        calls(buf, start)
        buf = ""
      }
      END { if (buf != "") calls(buf, start) }
    ' "$source")
  done
}

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
  if sed -n '/^AGENT_LOGIN_HINT=.*${/p' "$profile" | grep -q .; then
    r1=deferred
  else
    r1=literal
  fi
  t "agent-conf-$agent-login-hint-literal" literal "$r1"
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

# --- rehearsal builder fixtures: tie checks to this run (#179) -----------
# shellcheck source=drill/rehearsal-fixtures.sh
source "$ROOT/drill/rehearsal-fixtures.sh"

# --- rehearsal triage fixtures: installed queue labels and cleanup (#417) --
QUEUE_LABEL_SIX_HOME="$TMP/queue-label-six-home"
QUEUE_LABEL_FIVE_HOME="$TMP/queue-label-five-home"
ANSWER_MARK_HOME="$TMP/answer-mark-home"
mkdir -p \
  "$QUEUE_LABEL_SIX_HOME/duty/conf" \
  "$QUEUE_LABEL_FIVE_HOME/duty/conf" \
  "$ANSWER_MARK_HOME/duty/conf"
printf '%s\n' \
  'LABEL_READY=ready' \
  'LABEL_CLAIMED=claimed' \
  'LABEL_BLOCKED=blocked' \
  'LABEL_POST_MERGE=post-merge' \
  'LABEL_EPIC=epic' \
  'LABEL_NEEDS_TRIAGE=needs-triage' \
  >"$QUEUE_LABEL_SIX_HOME/duty/conf/fleet.defaults.conf"
printf '%s\n' \
  'LABEL_READY=ready' \
  'LABEL_CLAIMED=claimed' \
  'LABEL_BLOCKED=blocked' \
  'LABEL_EPIC=epic' \
  'LABEL_NEEDS_TRIAGE=needs-triage' \
  >"$QUEUE_LABEL_FIVE_HOME/duty/conf/fleet.defaults.conf"
printf '%s\n' 'MARK_ANSWERED="fixture answered at head"' \
  >"$ANSWER_MARK_HOME/duty/conf/fleet.defaults.conf"

bx() { HOME="$QUEUE_LABEL_FIXTURE_HOME" bash -c "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; }

QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_SIX_HOME"
if queue_label_six_out="$(rehearsal_load_installed_queue_labels 2>&1)"; then
  queue_label_six_rc=0
else
  queue_label_six_rc=$?
fi
t rehearsal-queue-label-six-rc 0 "$queue_label_six_rc"
t rehearsal-queue-label-six-records-ok 1 \
  "$(grep -cFx 'ok   triage: installed queue-label set resolves six names' \
    <<<"$queue_label_six_out")"

QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_FIVE_HOME"
if queue_label_five_out="$(rehearsal_load_installed_queue_labels 2>&1)"; then
  queue_label_five_rc=0
else
  queue_label_five_rc=$?
fi
t rehearsal-queue-label-five-rc 1 "$queue_label_five_rc"
t rehearsal-queue-label-five-records-fail 1 \
  "$(grep -cFx 'FAIL triage: installed queue-label set resolves six names' \
    <<<"$queue_label_five_out")"
t rehearsal-queue-label-five-names-values 'blocked claimed epic needs-triage ready' \
  "$(sed -n 's/^  //p' <<<"$queue_label_five_out" | paste -sd' ' -)"
QUEUE_LABEL_FIXTURE_HOME="$ANSWER_MARK_HOME"
if rehearsal_load_installed_answer_mark >/dev/null; then
  answer_mark_rc=0
else
  answer_mark_rc=$?
fi
t rehearsal-answer-mark-load-rc 0 "$answer_mark_rc"
t rehearsal-answer-mark-loads-installed-value 'fixture answered at head' \
  "$REHEARSAL_MARK_ANSWERED"
REHEARSAL_MARK_ANSWERED=stale-value
QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_SIX_HOME"
if rehearsal_load_installed_answer_mark >/dev/null; then
  answer_mark_missing_rc=0
else
  answer_mark_missing_rc=$?
fi
t rehearsal-answer-mark-missing-rc 1 "$answer_mark_missing_rc"
t rehearsal-answer-mark-missing-clears-output '' "$REHEARSAL_MARK_ANSWERED"
unset -f bx ok fail

REHEARSAL_ISSUE_GH_CALLS="$TMP/rehearsal-issue-gh-calls"
gh() { printf '%s\n' "$*" >>"$REHEARSAL_ISSUE_GH_CALLS"; }
if rehearsal_close_issue_fixtures owner/sandbox '41 42' >/dev/null; then
  issue_cleanup_rc=0
else
  issue_cleanup_rc=$?
fi
t rehearsal-issue-teardown-success-rc 0 "$issue_cleanup_rc"
t rehearsal-issue-teardown-success-attempts-both 2 \
  "$(wc -l <"$REHEARSAL_ISSUE_GH_CALLS")"

: >"$REHEARSAL_ISSUE_GH_CALLS"
gh() {
  printf '%s\n' "$*" >>"$REHEARSAL_ISSUE_GH_CALLS"
  [[ "$*" != *repos/owner/sandbox/issues/41* ]]
}
if rehearsal_close_issue_fixtures owner/sandbox '41 42' >/dev/null 2>&1; then
  issue_cleanup_rc=0
else
  issue_cleanup_rc=$?
fi
t rehearsal-issue-teardown-partial-failure-rc 1 "$issue_cleanup_rc"
t rehearsal-issue-teardown-partial-failure-attempts-both 2 \
  "$(wc -l <"$REHEARSAL_ISSUE_GH_CALLS")"
t rehearsal-issue-teardown-partial-failure-attempts-first 1 \
  "$(grep -cF 'repos/owner/sandbox/issues/41' "$REHEARSAL_ISSUE_GH_CALLS")"
t rehearsal-issue-teardown-partial-failure-attempts-second 1 \
  "$(grep -cF 'repos/owner/sandbox/issues/42' "$REHEARSAL_ISSUE_GH_CALLS")"
unset -f gh

EMPTY_BUILDER_PRS='[]'
STALE_BUILDER_PRS='[{"number":6,"body":"Closes #5"}]'
RIGHT_BUILDER_PRS='[{"number":6,"body":"Closes #5"},{"number":12,"body":"Closes #179"}]'
PREFIX_BUILDER_PRS='[{"number":13,"body":"Closes #1790"}]'
DUPLICATE_BUILDER_PRS='[{"number":12,"body":"Closes #179"},{"number":14,"body":"Fixes #179"}]'

t rehearsal-builder-stale-pr-occupies-slot 6 \
  "$(rehearsal_builder_slot_prs_from_json "$STALE_BUILDER_PRS")"
if empty_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$EMPTY_BUILDER_PRS")"; then
  empty_builder_rc=0
else
  empty_builder_rc=$?
fi
t rehearsal-builder-empty-response-refused '' "$empty_builder_out"
t rehearsal-builder-empty-response-lookup-fails 1 "$empty_builder_rc"
if stale_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$STALE_BUILDER_PRS")"; then
  stale_builder_rc=0
else
  stale_builder_rc=$?
fi
t rehearsal-builder-stale-pr-cannot-satisfy-this-run '' "$stale_builder_out"
t rehearsal-builder-stale-pr-lookup-fails 1 "$stale_builder_rc"
t rehearsal-builder-run-specific-pr-resolves 12 \
  "$(rehearsal_builder_pr_for_issue_from_json 179 "$RIGHT_BUILDER_PRS")"
if prefix_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$PREFIX_BUILDER_PRS")"; then
  prefix_builder_rc=0
else
  prefix_builder_rc=$?
fi
t rehearsal-builder-wrong-issue-prefix-refused '' "$prefix_builder_out"
t rehearsal-builder-wrong-issue-prefix-lookup-fails 1 "$prefix_builder_rc"
if duplicate_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$DUPLICATE_BUILDER_PRS")"; then
  duplicate_builder_rc=0
else
  duplicate_builder_rc=$?
fi
t rehearsal-builder-duplicate-current-prs-refused '' "$duplicate_builder_out"
t rehearsal-builder-duplicate-current-prs-lookup-fails 1 "$duplicate_builder_rc"

BUILDER_HEAD="$(printf 'b%.0s' {1..40})"
BUILDER_OTHER_HEAD="$(printf 'c%.0s' {1..40})"
BUILDER_MARK='📣 round answered at head'
BUILDER_ROUND_STARTED_AT='2026-08-08T12:01:00Z'
BUILDER_PANEL_CONTENT="$(rehearsal_builder_fixture_panel_content builder host-reviewer)"
t rehearsal-builder-fixture-panel-is-author-specific \
  'panel[builder]=host-reviewer' "$BUILDER_PANEL_CONTENT"

if rehearsal_builder_is_draft_from_json '{"draft":true}'; then builder_draft_result=draft; else builder_draft_result=ready; fi
t rehearsal-builder-draft-object-read draft "$builder_draft_result"
if rehearsal_builder_is_draft_from_json '{"draft":false}'; then builder_draft_result=DRAFT; else builder_draft_result=refused; fi
t rehearsal-builder-ready-object-refused refused "$builder_draft_result"

BUILDER_COMMENTS='[
  {"user":{"login":"builder"},"body":"📣 round answered at head '"$BUILDER_HEAD"'","created_at":"2026-08-08T12:02:00Z"},
  {"user":{"login":"somebody-else"},"body":"📣 round answered at head '"$BUILDER_OTHER_HEAD"'","created_at":"2026-08-08T12:02:00Z"}
]'
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_COMMENTS"; then builder_signal_result=found; else builder_signal_result=missing; fi
t rehearsal-builder-current-head-signal-found found "$builder_signal_result"
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_OTHER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_COMMENTS"; then builder_signal_result=WRONG; else builder_signal_result=refused; fi
t rehearsal-builder-other-author-signal-refused refused "$builder_signal_result"
BUILDER_TRAILING_SIGNALS="$(jq -cn \
  --arg head "$BUILDER_HEAD" --arg mark "$BUILDER_MARK" '[
    {user:{login:"builder"},body:($mark + " " + $head + " — all points answered"),created_at:"2026-08-08T12:02:00Z"},
    {user:{login:"builder"},body:($mark + " " + $head + "\n"),created_at:"2026-08-08T12:02:00Z"}
  ]')"
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_TRAILING_SIGNALS"; then
  builder_signal_result=found
else
  builder_signal_result=missing
fi
t rehearsal-builder-engine-compatible-trailing-signal-found found \
  "$builder_signal_result"

if rehearsal_builder_head_is_from_json \
    "$BUILDER_HEAD" '{"head":{"sha":"'"$BUILDER_HEAD"'"}}'; then
  builder_head_result=stable
else
  builder_head_result=moved
fi
t rehearsal-builder-fixture-head-stability-read stable "$builder_head_result"

BUILDER_PENDING_STATUS='{"statuses":[
  {"context":"drill/builder-head-settle","state":"success","created_at":"2026-08-08T12:00:00Z"},
  {"context":"drill/builder-head-settle","state":"pending","created_at":"2026-08-08T12:01:00Z"},
  {"context":"other","state":"failure","created_at":"2026-08-08T12:02:00Z"}
]}'
t rehearsal-builder-latest-check-state-is-pending pending \
  "$(rehearsal_builder_check_state_from_json \
    drill/builder-head-settle "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-missing-check-context-is-empty '' \
  "$(rehearsal_builder_check_state_from_json missing "$BUILDER_PENDING_STATUS")"

BUILDER_REQUESTED='{"users":[{"login":"host-reviewer"}],"teams":[]}'
BUILDER_UNREQUESTED='{"users":[],"teams":[]}'
if rehearsal_builder_requested_from_json host-reviewer "$BUILDER_REQUESTED"; then builder_request_result=requested; else builder_request_result=missing; fi
t rehearsal-builder-settled-head-request-found requested "$builder_request_result"
if rehearsal_builder_requested_from_json host-reviewer "$BUILDER_UNREQUESTED"; then builder_request_result=EARLY; else builder_request_result=withheld; fi
t rehearsal-builder-pending-head-request-withheld withheld "$builder_request_result"

gh() {
  case "$*" in
    *pulls/9/requested_reviewers*) return 1 ;;
    *) return 2 ;;
  esac
}
if rehearsal_builder_not_requested owner/sandbox 9 host-reviewer; then
  builder_request_result=FAIL_OPEN
else
  builder_request_result=refused
fi
t rehearsal-builder-request-fetch-error-fails-closed refused \
  "$builder_request_result"
unset -f gh

t rehearsal-builder-signal-window-waits-before-signal waiting \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    '[]' "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-signal-window-caught-at-pending caught \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-stale-same-head-signal-waits waiting \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" '2026-08-08T12:03:00Z' drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_PENDING_STATUS")"
BUILDER_SETTLED_STATUS='{"statuses":[
  {"context":"drill/builder-head-settle","state":"success","created_at":"2026-08-08T12:03:00Z"}
]}'
t rehearsal-builder-immediate-check-conclusion-is-named-skip-state closed:success \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_SETTLED_STATUS")"
gh() {
  case "$*" in
    *issues/9/comments*) printf '%s\n' "$BUILDER_COMMENTS" ;;
    *commits/"$BUILDER_HEAD"/status*) printf '%s\n' "$BUILDER_SETTLED_STATUS" ;;
    *) return 2 ;;
  esac
}
BUILDER_WINDOW_SKIP_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  rehearsal_wait_builder_signal_window \
    1 owner/sandbox 9 "$BUILDER_MARK" builder "$BUILDER_HEAD" \
    "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle
})"
t rehearsal-builder-immediate-check-conclusion-names-window 1 \
  "$(grep -cFx \
    'skip builder: pending-check signal window closed before it could be observed (check success); round answer signal was present' \
    <<<"$BUILDER_WINDOW_SKIP_OUT")"
unset -f gh

for builder_prereq_case in mark boundary; do
  builder_prereq_mark="$BUILDER_MARK"
  builder_prereq_after="$BUILDER_ROUND_STARTED_AT"
  builder_prereq_reason='changes-requested review boundary unresolved'
  if [ "$builder_prereq_case" = mark ]; then
    builder_prereq_mark=''
    builder_prereq_reason='installed answer mark unresolved'
  else
    builder_prereq_after=''
  fi
  gh() { printf 'unexpected gh call\n'; return 1; }
  BUILDER_PREREQ_OUT="$({
    ok() { printf 'ok   %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_wait_builder_signal_window_with_prereqs \
      1 owner/sandbox 9 "$builder_prereq_mark" builder "$BUILDER_HEAD" \
      "$builder_prereq_after" drill/builder-head-settle
  })"
  t "rehearsal-builder-$builder_prereq_case-prereq-skips-window" 1 \
    "$(grep -cFx \
      "skip builder: round answer signal window unavailable ($builder_prereq_reason)" \
      <<<"$BUILDER_PREREQ_OUT")"
  t "rehearsal-builder-$builder_prereq_case-prereq-cannot-pass-window" 0 \
    "$(grep -c '^ok   builder: round answer' <<<"$BUILDER_PREREQ_OUT")"
  t "rehearsal-builder-$builder_prereq_case-prereq-does-not-query" 0 \
    "$(grep -cFx 'unexpected gh call' <<<"$BUILDER_PREREQ_OUT")"
  unset -f gh
done

# Mutation required by #418: stage the disabled draft-return path as the PR
# object the sourceable assertion reads. It must name the live leg assertion,
# never silently pass a ready PR as if conversion happened.
BUILDER_DRAFT_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: changes-requested round returns PR to draft" \
    rehearsal_builder_is_draft_from_json '{"draft":false}'
})"
t rehearsal-builder-disabled-draft-return-reds 1 \
  "$(grep -cFx 'FAIL builder: changes-requested round returns PR to draft' \
    <<<"$BUILDER_DRAFT_MUTATION_OUT")"

# A premature request at the unsettled head must red the same assertion the
# live leg runs after the builder tick has completed.
# shellcheck disable=SC2317  # gh is invoked indirectly through the sourced helper
gh() {
  case "$*" in
    *pulls/9/requested_reviewers*) printf '%s\n' "$BUILDER_REQUESTED" ;;
    *) return 2 ;;
  esac
}
BUILDER_REQUEST_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: panel request withheld while head check is pending" \
    rehearsal_builder_not_requested owner/sandbox 9 host-reviewer
})"
t rehearsal-builder-premature-request-reds 1 \
  "$(grep -cFx \
    'FAIL builder: panel request withheld while head check is pending' \
    <<<"$BUILDER_REQUEST_MUTATION_OUT")"
unset -f gh

# A failed drill-owned success status must red at setup rather than waiting on
# the downstream request assertion for a transition that never happened.
# shellcheck disable=SC2317  # gh is invoked indirectly through the sourced helper
gh() { return 1; }
BUILDER_SETTLE_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: settled head status established" \
    rehearsal_set_builder_head_status owner/sandbox "$BUILDER_HEAD" \
    drill/builder-head-settle success 'drill releases the settled-head panel request'
})"
t rehearsal-builder-settle-write-failure-reds-at-setup 1 \
  "$(grep -cFx 'FAIL builder: settled head status established' \
    <<<"$BUILDER_SETTLE_MUTATION_OUT")"
unset -f gh

# Pin the live sequence too: host verdict, pending status, concurrent draft
# observation, signal-at-pending assertion, withheld request, success, request.
BUILDER_LIVE_BLOCK="$(sed -n '/builder_head=.*pulls.*head.sha/,/panel request issued after head settles/p' \
  "$ROOT/drill/rehearsal.sh")"
while IFS='|' read -r builder_live_case builder_live_token; do
  if grep -Fq "$builder_live_token" <<<"$BUILDER_LIVE_BLOCK"; then
    t "rehearsal-builder-live-fix-round-$builder_live_case" wired wired
  else
    t "rehearsal-builder-live-fix-round-$builder_live_case" wired MISSING
  fi
done <<'EOF'
1|event=REQUEST_CHANGES
2|host changes-requested review submitted
3|state=pending
4|pending head status established
5|builder_tick_pid=$!
6|changes-requested round returns PR to draft
7|rehearsal_wait_builder_signal_window_with_prereqs
8|builder_round_started_at
9|panel request withheld while head check is pending
10|rehearsal_set_builder_head_status
11|settled head status established
12|panel request issued after head settles
EOF
# shellcheck disable=SC2016  # match the literal background-pid wait in the drill
case "$BUILDER_LIVE_BLOCK" in
  *'wait "$builder_tick_pid"'*'panel request withheld while head check is pending'*'rehearsal_set_builder_head_status'*)
    builder_gate_order=ordered ;;
  *) builder_gate_order=WRONG ;;
esac
t rehearsal-builder-pending-gate-probed-after-tick ordered \
  "$builder_gate_order"

OCCUPIED_BUILDER_OUT="$({
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_report_occupied_builder_slot builder
})"
t rehearsal-builder-occupied-slot-fails-opened-pr 1 \
  "$(grep -cFx 'FAIL builder: opened a PR for the ready issue' <<<"$OCCUPIED_BUILDER_OUT")"
t rehearsal-builder-occupied-slot-fails-run-specific-authorship 1 \
  "$(grep -cFx "FAIL builder: PR authored by builder for this run's fixture issue" \
    <<<"$OCCUPIED_BUILDER_OUT")"
t rehearsal-builder-occupied-slot-skips-unreachable-checks \
  'builder fixture is unassigned (ready+assigned is not pickable)|builder: PR branch is build/*|builder: issue moved off ready (claimed)|builder: no duplicate PR on re-tick|builder: fixture panel names the host reviewer|builder: initial PR is ready for its fixture panel|builder: host reviewer requested for initial round|builder: installed round-answer mark resolves|builder: host changes-requested review submitted|builder: pending head status established|builder: changes-requested round returns PR to draft|builder: round answer is signalled while head check is pending|builder: fix round kept the fixture head stable|builder: panel request withheld while head check is pending|builder: settled head status established|builder: panel request issued after head settles' \
  "$(sed -n 's/^skip //p' <<<"$OCCUPIED_BUILDER_OUT" | paste -sd'|' -)"

MISSING_BUILDER_PR_OUT="$({
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_report_missing_builder_pr
})"
t rehearsal-builder-missing-pr-skips-unreachable-checks \
  'builder: initial PR is ready for its fixture panel|builder: host reviewer requested for initial round|builder: installed round-answer mark resolves|builder: host changes-requested review submitted|builder: pending head status established|builder: changes-requested round returns PR to draft|builder: round answer is signalled while head check is pending|builder: fix round kept the fixture head stable|builder: panel request withheld while head check is pending|builder: settled head status established|builder: panel request issued after head settles' \
  "$(sed -n 's/^skip //p' <<<"$MISSING_BUILDER_PR_OUT" | paste -sd'|' -)"

REHEARSAL_GH_CALLS="$TMP/rehearsal-gh-calls"
gh() {
  case "$1 $2" in
    "api repos/owner/sandbox/pulls?state=open&per_page=100")
      jq '[.[] | .user = {login:"builder"}]' <<<"$RIGHT_BUILDER_PRS" ;;
    "api -X") printf '%s\n' "$*" >>"$REHEARSAL_GH_CALLS" ;;
    *) return 2 ;;
  esac
}
rehearsal_close_builder_fixture_prs owner/sandbox builder >/dev/null
t rehearsal-builder-teardown-closes-all-fixture-prs 2 \
  "$(wc -l <"$REHEARSAL_GH_CALLS")"
t rehearsal-builder-teardown-closes-first 1 \
  "$(grep -cF 'repos/owner/sandbox/pulls/6' "$REHEARSAL_GH_CALLS")"
t rehearsal-builder-teardown-closes-current 1 \
  "$(grep -cF 'repos/owner/sandbox/pulls/12' "$REHEARSAL_GH_CALLS")"
unset -f gh

# --- rehearsal reviewer announce ordering (#192) --------------------------
# shellcheck source=drill/review-order.sh
source "$ROOT/drill/review-order.sh"
REVIEW_HEAD="$(printf 'a%.0s' {1..40})"
REVIEW_BEFORE_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:00:00Z","guest_clock":"2099-01-01T00:00:00Z"}]'
REVIEW_AFTER_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:06:00Z","guest_clock":"2000-01-01T00:00:00Z"}]'
REVIEW_VERDICTS='[{"user":{"login":"reviewer"},"commit_id":"'"$REVIEW_HEAD"'","state":"APPROVED","submitted_at":"2026-07-30T10:05:00Z"}]'

if rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_BEFORE_COMMENTS" "$REVIEW_VERDICTS"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-before-verdict-rc 0 "$review_order_rc"

if review_order_out="$(rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_AFTER_COMMENTS" "$REVIEW_VERDICTS" 2>&1)"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-after-verdict-rc 5 "$review_order_rc"
case "$review_order_out" in
  *"review ordering: announce must precede verdict"*) r1=named ;;
  *) r1=missing ;;
esac
t rehearsal-review-announce-after-verdict-names-ordering named "$r1"
# The mutation leaves the two existing predicates satisfied: the announce is
# still present at this head and still appears exactly once.
t rehearsal-review-after-verdict-presence-still-passes 1 \
  "$(jq -r --arg h "$REVIEW_HEAD" '[.[] | select(.body == ("🔎 reviewing head " + $h))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"
t rehearsal-review-after-verdict-dedup-still-passes 1 \
  "$(jq -r '[.[] | select(.body | startswith("🔎 reviewing head"))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"

# --- install.sh: crontab preflight and convergence (#25) ----------------
# A curated PATH makes "crontab absent" deterministic even on a workstation
# that happens to have cron installed. Everything install.sh legitimately
# needs is linked in; gh and git are fixture shims.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
# find/sort/tail/xargs joined the list with #159's engine manifest: the curated
# PATH is the box's whole world here, and a tool missing from it degrades the
# install to `unverified` instead of failing, which would hide the very thing
# these fixtures assert.
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
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
  case " $* " in
    *" --converge-registries "*)
      [ -f "$RDUTY/.crew-seed-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
      [ -f "$RDUTY/.crew-example-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
      [ -f "$RDUTY/.crew-example-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
      [ -f "$RDUTY/.crew-seed-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
      ;;
  esac
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
printf 'fixture/shipped-example\n' >"$RDUTY/repos.txt"
printf 'fixture/shipped-example\n' >"$RDUTY/.crew-example-repos.txt"
printf 'fixture/migrated\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-adopts-example fixture/migrated "$(cat "$RDUTY/repos.txt")"
t install-transported-example-discarded absent \
  "$([ -e "$RDUTY/.crew-example-repos.txt" ] && printf present || printf absent)"
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/unknown-local\n' >"$RDUTY/repos.txt"
printf 'fixture/incoming\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-vetoes-unknown fixture/unknown-local "$(cat "$RDUTY/repos.txt")"

# Convergence must fail closed when any one-shot transport leg is absent.
# Call install.sh directly: roster_install deliberately backfills the payloads
# so the ordinary convergence cases exercise the complete host transport.
printf 'fixture/notify-contained\n' >"$RDUTY/notify-repos.txt"
for missing_payload in \
  .crew-seed-repos.txt \
  .crew-seed-notify-repos.txt \
  .crew-example-repos.txt \
  .crew-example-notify-repos.txt; do
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
  rm -f "$RDUTY/$missing_payload"
  before_repos="$(cat "$RDUTY/repos.txt")"
  before_notify_repos="$(cat "$RDUTY/notify-repos.txt")"
  if refusal_out="$(env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" \
    CRON_STATE="$CRON_STATE" /bin/bash "$SHARED/install.sh" \
    --box claude-builder --converge-registries 2>&1)"; then
    r1=0
  else
    r1=$?
  fi
  t "install-incomplete-$missing_payload-refused" 1 "$r1"
  case "$refusal_out" in
    *"missing transported registry payload $missing_payload"*) r1=named ;;
    *) r1="missing: $refusal_out" ;;
  esac
  t "install-incomplete-$missing_payload-named" named "$r1"
  t "install-incomplete-$missing_payload-keeps-repos" \
    "$before_repos" "$(cat "$RDUTY/repos.txt")"
  t "install-incomplete-$missing_payload-keeps-notify-repos" \
    "$before_notify_repos" "$(cat "$RDUTY/notify-repos.txt")"
done
rm -f "$RDUTY/notify-repos.txt"

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

# The role registry is conf/roles/*.conf and nothing else; a second list — a
# "role manifest" — is what this refuses. Two unrelated manifests have since
# turned up, so rather than delete the guard it subtracts exactly those two
# uses: the content hash of the installed ENGINE tree (#159), and rig's
# PROVENANCE file (#220 — /etc/rig/manifest, which rig owns and crew only
# reads; crew declares no roles in it and could not, since it never writes it).
# A `manifest` that is neither is still a duplicated registry, and the
# subtraction is per LINE, so the qualified phrase has to be written out every
# time it appears in these files.
manifest_hits="$(grep -Rsinw 'manifest' "$SHARED/docs" "$SHARED/README.md" "$SHARED/conf" \
    "$SHARED/lib" "$SHARED/install.sh" "$ROOT/examples/fleet.roster" "$ROOT/cli/crew" \
    "$ROOT/drill" 2>/dev/null \
    | grep -vi 'engine[ ._-]manifest' | grep -vi 'rig[ /._-]manifest' || true)"
if [ -n "$manifest_hits" ]; then
  r1="DUPLICATED: $manifest_hits"
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

# #283 — every reader of the armed state must agree that only a live tick
# line counts. A paused line contains tick.sh too, so an unanchored probe makes
# routine maintenance silently resume a box the operator deliberately paused.
status_tick_pattern="$(sed -n 's/.*grep -cE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | head -1)"
upgrade_tick_pattern="$(sed -n 's/.*grep -qE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | tail -1)"
floor_tick_pattern="$(sed -n "s/.*grep -cE '\([^']*tick\\\\\.sh\)'.*/\1/p" "$ROOT/fleet-floor/server/probe.sh" | head -1)"
t upgrade-status-armed-pattern-is-present present "$([ -n "$status_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-is-present present "$([ -n "$upgrade_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-floor-armed-pattern-is-present present "$([ -n "$floor_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-matches-status "$status_tick_pattern" "$upgrade_tick_pattern"
t upgrade-armed-pattern-matches-floor "$floor_tick_pattern" "$upgrade_tick_pattern"

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

# --- notify repo set: work repos union additive handoff targets (#316) ----
# Run the real notifier with an empty-board gh shim. This observes every
# repository it queries without network access or duplicating its set logic in
# the test. A repo in repos.txt is always covered; notify-repos.txt only adds
# cross-repo targets; overlap is queried once.
NSHIM="$TMP/notify-bin"
NLOG="$TMP/notify-gh.log"
mkdir -p "$NSHIM"
cat >"$NSHIM/gh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-R" ]; then printf '%s\n' "$2" >>"$NLOG"; break; fi
  shift
done
printf '[]\n'
EOF
chmod +x "$NSHIM/gh"
printf '\nBOT_PATH_PREPEND=%q\n' "$NSHIM" >>"$LHOME/duty/conf/agents/claude.conf"
printf 'fixture/work-only\nfixture/both\n' >"$LHOME/duty/repos.txt"
printf 'fixture/notify-only\nfixture/both\n' >"$LHOME/duty/notify-repos.txt"
printf 'fixture-token\n' >"$LHOME/.tg_bot_token"
printf 'fixture-chat\n' >"$LHOME/.tg_chat_id"
: >"$NLOG"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh" >/dev/null
t notify-repos-union "fixture/both
fixture/notify-only
fixture/work-only" "$(sort "$NLOG")"
t notify-repos-overlap-once 1 "$(grep -cxF fixture/both "$NLOG")"

# A present but unreadable additive registry takes the same explicit fallback
# path: the work set remains covered, the sweep succeeds, and the operator is
# told that only repos.txt participated.
chmod 000 "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
if notify_unreadable_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"; then
  notify_unreadable_rc=0
else
  notify_unreadable_rc=$?
fi
t notify-repos-unreadable-rc 0 "$notify_unreadable_rc"
t notify-repos-unreadable-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_unreadable_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-unreadable-fallback-is-logged logged "$r1"
chmod 600 "$LHOME/duty/notify-repos.txt"

# With no additive registry the work set is still watched, and the existing
# fallback log remains explicit.
rm -f "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
notify_fallback_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"
t notify-repos-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_fallback_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-fallback-is-logged logged "$r1"

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


# --- the 0.1.2 operator surfaces: every assertion red on a staged answer -
# drill/rehearsal-app-surfaces.sh holds the seven assertions drill/rehearsal-
# app.sh makes about what 0.1.2 shipped into the operator's view (#420). They
# run on a drill HOST, which CI does not have — so they are exercised the way
# the other rehearsal helpers already are here: the leg's reporters stubbed,
# the file sourced, and a WRONG answer staged into the input each assertion
# reads. An assertion nobody can red is an assertion nobody has checked, which
# is #50's defect stated once more.
SURF="$TMP/app-surfaces"
mkdir -p "$SURF"

# One truthful fleet, four boxes: two hired and answering, one never created,
# one deployed but not talking. Every payload below is this one with exactly
# one field moved, so a red is attributable to that field and nothing else.
surf_payload() {  # surf_payload '<python mutating p>' → the fleet payload
  python3 - "$1" <<'PY'
import json, sys
p = {
    "version": "crew 0.1.2 (/opt/crew)",
    # `state`, `paused` and `disarmed` are the three fields fleetState() reads
    # (fleet-floor/src/app.js:1282-1285): a DRAWN unit that is offline lands in
    # Disarmed when either flag is set and in Silent when neither is. They are
    # here because the filter assertion compares the page's groups against the
    # sets they imply — crew-b disarmed, crew-d silent — rather than only
    # against whoever the page happened to list.
    "units": [
        {"box": "crew-a", "engine": "0.1.2", "integrity": "current",
         "hired": "yes", "note": "", "state": "idle",
         "paused": False, "disarmed": False},
        {"box": "crew-b", "engine": "0.1.2", "integrity": "modified",
         "hired": "yes", "note": "", "state": "offline",
         "paused": False, "disarmed": True},
        {"box": "crew-c", "engine": "", "integrity": "",
         "hired": "no", "note": "not created — crew new crew-c",
         "state": "offline", "paused": False, "disarmed": False},
        {"box": "crew-d", "engine": "0.1.2", "integrity": "unverified",
         "hired": "unknown", "note": "stopped", "state": "offline",
         "paused": False, "disarmed": False},
    ],
}
u = {b["box"]: b for b in p["units"]}
exec(sys.argv[1])
print(json.dumps(p))
PY
}
surf_payload 'pass'                                     >"$SURF/fleet.json"
surf_payload 'p["version"] = "crew 9.9.9 (/staged)"'    >"$SURF/fleet-wrong-version.json"
surf_payload 'p["version"] = "version unavailable"'     >"$SURF/fleet-no-version.json"
surf_payload 'u["crew-b"]["integrity"] = "current"'     >"$SURF/fleet-integrity-lie.json"
surf_payload 'u["crew-c"]["note"] = "not created"'      >"$SURF/fleet-no-repair-verb.json"
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-d"]' \
                                                        >"$SURF/fleet-drops-a-box.json"
# The same drop, of the one box that IS a measured absence — so the payload is
# short AND nothing in it carries `hired=no`, which is the pair that used to
# read as "every roster box is deployed".
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]' \
                                                        >"$SURF/fleet-drops-the-undeployed-box.json"
surf_payload 'u["crew-c"]["note"] = "box inventory unreadable: box list failed"' \
                                                        >"$SURF/fleet-inventory-unreadable.json"
# Short BECAUSE the inventory failed: an unmeasured fleet, which must keep
# skipping rather than being read as the dropped-box regression.
surf_payload '
u["crew-b"]["note"] = "box inventory unreadable: box list failed"
p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]
'                                                       >"$SURF/fleet-inventory-unreadable-and-short.json"
surf_payload 'u["crew-c"].update(hired="yes", engine="0.1.2", integrity="current", note="")' \
                                                        >"$SURF/fleet-all-deployed.json"
surf_payload 'u["crew-d"]["note"] = ""'                 >"$SURF/fleet-all-answered.json"
# Every declared box undeployed — #204's empty floor, the state the panel
# naming `crew hire` exists for.
surf_payload '
for b in p["units"]:
    b.update(hired="no", engine="", integrity="", state="offline",
             note="not hired — crew hire " + b["box"])
'                                                       >"$SURF/fleet-all-undeployed.json"
# The floor and the CLI disagreeing about one box: the payload says crew-b is
# deliberately stopped and `crew status` does not.
surf_payload 'u["crew-b"]["disarmed"] = False'          >"$SURF/fleet-b-not-disarmed.json"
# Two boxes deliberately stopped — an ordinary fleet, and the one that puts two
# members into the disarmed direction's blind set.
surf_payload 'u["crew-d"]["disarmed"] = True'           >"$SURF/fleet-two-disarmed.json"
# Nothing quiet at all: every drawn box is ticking, so neither state group has
# a member and the filter has nothing to classify.
surf_payload '
for b in p["units"]:
    b["state"] = "idle"
'                                                       >"$SURF/fleet-none-quiet.json"

printf 'crew-a claude builder\ncrew-b codex reviewer\ncrew-c grok triage\ncrew-d kimi builder\n' \
  >"$SURF/roster"
SURF_ROSTER="$SURF/roster"
# What each box answers to `engine-manifest.sh --state`, standing in for the
# `box exec` the leg does — the second reader #190's assertion cross-checks the
# floor against.
printf 'crew-a current\ncrew-b modified\ncrew-d unverified\n' >"$SURF/integrity"
printf 'crew-a current\ncrew-b tampered\ncrew-d unverified\n' >"$SURF/integrity-fourth-word"
: >"$SURF/integrity-silent"
SURF_INTEG="$SURF/integrity"

# The leg's reporters, in a SUBSHELL so run.sh's own t() survives the stubbing:
# each verdict comes back as one "<ok|FAIL|skip> <label> <reason>" line on
# stdout, which is the whole interface the assertions below match against.
# The REASON is on the line and not only the label, because criterion 3 is
# about the reason: "no assertion silently passes when its precondition is
# absent" is a claim about what the skip SAYS, and a skip whose stated reason
# is not true is the defect the #204 gate below exists to close. Newlines are
# flattened so one verdict stays one line.
# shellcheck disable=SC2317  # the stubs are reached through "$@", which is an
# indirection shellcheck cannot follow — every one of them is called by the
# sourced assertions below.
surf() {  # surf <fn> [args...] → one verdict line per assertion the fn makes
  (
    emit() { local v="$1" m; shift; m="$*"; printf '%s %s\n' "$v" "${m//$'\n'/ }"; }
    ok()   { emit ok "$@"; }
    fail() { emit FAIL "$@"; }
    skip() { emit skip "$@"; }
    t()    { if [ "$2" = "$3" ]; then printf 'ok %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; }
    jqf()  { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
    roster_rows()   { grep -vE '^[[:space:]]*(#|$)' "$SURF_ROSTER"; }
    # The caller supplies this reader, and on a real host it shells into a box.
    # SURF_GREEDY_READER makes it behave like the one that does — `box exec`
    # inherits the loop's stdin and drains it — which truncated the roster loop
    # to its first box on the host, silently, while the label kept claiming the
    # fleet.
    box_integrity() {
      # Bounded, because the drain must not outlive the thing it is draining:
      # once the roster moved to fd 3 this `cat` no longer meets the loop's
      # pipe at all, it meets whatever stdin the suite was STARTED with — and
      # an unbounded read of a socket that nobody is going to close hangs the
      # whole suite forever. It reaches EOF instantly against a pipe or
      # /dev/null (which is CI, and is the pre-fix code path this case reds
      # on), so the bound costs nothing where it is not needed.
      [ -n "${SURF_GREEDY_READER:-}" ] && { timeout 1 cat >/dev/null 2>&1 || true; }
      awk -v b="$1" '$1 == b { print $2 }' "$SURF_INTEG"
    }
    # shellcheck source=drill/rehearsal-app-surfaces.sh
    source "$ROOT/drill/rehearsal-app-surfaces.sh"
    "$@"
  )
}
surf_says() {  # surf_says <verdict lines> <label substring> → ok|FAIL|skip|absent
  local line
  line="$(printf '%s\n' "$1" | grep -F -- "$2" | head -1)"
  [ -n "$line" ] || { printf 'absent'; return 0; }
  printf '%s' "${line%% *}"
}

# --- #347: the header names the version of the crew SERVING the page -----
SURF_V="floor: the API names the serving host"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-truthful-header ok "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet-wrong-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-staged-wrong-version FAIL "$(surf_says "$r1" "$SURF_V")"
# The server dropped what the launcher passed and served its placeholder.
r1="$(surf app_surface_version "$SURF/fleet-no-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-placeholder-served FAIL "$(surf_says "$r1" "$SURF_V")"
# The launcher and the page agree on a version this tree is not: the half that
# stops the assertion being a fixture comparing itself to itself.
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.1)"
t app-surface-347-stale-release-named FAIL "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" '')"
t app-surface-347-no-version-file FAIL "$(surf_says "$r1" "$SURF_V")"

# --- #190: the verdict on the tile is the BOX's own word -----------------
SURF_I="floor: every hired box's integrity verdict"
SURF_IV="floor: every integrity verdict is one of the three words"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-truthful-verdicts ok "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-truthful-vocabulary ok "$(surf_says "$r1" "$SURF_IV")"
# The label names how many boxes were compared, and it must be all three that
# answered — not the one the loop happened to reach.
t app-surface-190-compares-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The reader that shells into a box drains the loop's stdin. Reading the roster
# on fd 3 is what keeps that from truncating the loop to its first member — a
# real host defect, found by running the leg, invisible to a stub reader that
# does not touch stdin.
r1="$(SURF_GREEDY_READER=1 surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-greedy-reader-visits-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The floor prints `current` for a box whose own manifest says `modified` —
# exactly the reassurance #190 exists to stop the page inventing.
r1="$(surf app_surface_integrity "$SURF/fleet-integrity-lie.json")"
t app-surface-190-staged-floor-lie FAIL "$(surf_says "$r1" "$SURF_I")"
SURF_INTEG="$SURF/integrity-fourth-word"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-fourth-word-red FAIL "$(surf_says "$r1" "$SURF_IV")"
SURF_INTEG="$SURF/integrity-silent"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
# No box answered the second reader, so there is nothing to compare — and the
# precondition is NAMED rather than passing quietly.
t app-surface-190-unanswerable-skips skip "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-names-the-silent-box skip "$(surf_says "$r1" "integrity: crew-a")"
SURF_INTEG="$SURF/integrity"

# --- #204: not deployed is COUNTED and not DRAWN -------------------------
SURF_ND="floor: a roster box that is not deployed is counted"
SURF_NC="floor: the not-deployed boxes are counted but not drawn"
r1="$(surf app_surface_not_deployed "$SURF/fleet.json" 4)"
t app-surface-204-truthful-repair-verb ok "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-truthful-counts ok "$(surf_says "$r1" "$SURF_NC")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-no-repair-verb.json" 4)"
t app-surface-204-staged-silent-note FAIL "$(surf_says "$r1" "$SURF_ND")"
# The filter applied one layer too high: the box is gone from the payload, so
# the fleet silently shrinks instead of keeping its declared size. Reds at the
# completeness gate now, which owns this direction and names the missing box —
# so the arithmetic assertion downstream is never reached and is `absent`.
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-a-box.json" 4)"
t app-surface-204-staged-shrunk-fleet FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-shrunk-fleet-names-the-box FAIL "$(surf_says "$r1" "never reported: crew-d")"
t app-surface-204-shrunk-fleet-stops-at-the-gate absent "$(surf_says "$r1" "$SURF_NC")"
# The same drop, of the box that is the fleet's ONLY measured absence. This is
# the direction the mutation above cannot reach: with `crew-c` gone no unit
# carries `hired=no`, so the empty-set branch used to conclude "every one of
# the 4 roster boxes is deployed" over a three-unit payload — #204's own
# regression reported as a fleet that does not exercise it. It must FAIL, not
# skip (codex-bot at 4bde9ce; triage's Must-fail in #420's test plan).
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-the-undeployed-box.json" 4)"
t app-surface-204-drops-the-undeployed-box FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-drops-the-undeployed-box-named FAIL "$(surf_says "$r1" "never reported: crew-c")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable.json" 4)"
t app-surface-204-unmeasured-absence-skips skip "$(surf_says "$r1" "$SURF_ND")"
# ...and it keeps that precedence when the failed inventory ALSO cost the
# payload a unit: an unmeasured fleet is not the dropped-box regression, so it
# must still skip by its own reason rather than red at the gate.
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable-and-short.json" 4)"
t app-surface-204-unreadable-outranks-the-gate skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-unreadable-names-its-reason skip "$(surf_says "$r1" "the box inventory did not answer for: crew-b")"
# The gate must not red a correct fleet: a complete payload with no measured
# absence still skips, with the one reason that is now true of it.
r1="$(surf app_surface_not_deployed "$SURF/fleet-all-deployed.json" 4)"
t app-surface-204-no-such-box-skips skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-complete-fleet-skip-reason skip "$(surf_says "$r1" "every one of the 4 roster boxes is deployed")"

# --- #218: `crew up --dry-run` names every box and touches nothing -------
printf 'crew-a: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-b: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-c: WOULD create (grok/triage)\ncrew-c: WOULD hire (new box — engine crew@0.1.2, cron armed)\ncrew-d: WOULD start\ncrew-d: WOULD SKIP — not converged; crew hire crew-d would refuse\n\nup --dry-run: 1 would be created, 1 started, 3 hired\n' \
  >"$SURF/up-dry.txt"
grep -v '^crew-d: ' "$SURF/up-dry.txt" >"$SURF/up-dry-silent.txt"
grep -v '^up --dry-run: ' "$SURF/up-dry.txt" >"$SURF/up-dry-no-summary.txt"
printf 'roster deadbeef\nboxes crew-a:running,crew-b:running,crew-d:stopped\ncron crew-a c0ffee\ncron crew-b c0ffee\ncron crew-d c0ffee\n' \
  >"$SURF/before.fp"
cp "$SURF/before.fp" "$SURF/after.fp"
# The one thing --dry-run promises never to do: a box that did not exist before
# the command exists after it.
sed 's/^boxes .*/boxes crew-a:running,crew-b:running,crew-c:running,crew-d:stopped/' \
  "$SURF/before.fp" >"$SURF/after-created.fp"
sed 's/^boxes .*/boxes UNREADABLE/' "$SURF/before.fp" >"$SURF/before-unreadable.fp"
# A component that did not answer, marked as such rather than hashed. Both of
# these used to be INVISIBLE: a failed `box_read` was piped straight into
# sha256sum, so two failed reads produced the same hash of the empty string and
# compared equal — "unchanged" over a crontab nobody read.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/before-cron-unreadable.fp"
awk '{ $NF = "UNREADABLE"; print }' "$SURF/before.fp" \
  >"$SURF/before-all-unreadable.fp"
# ...and the box that answered and genuinely has no crontab. Its read succeeded,
# so it is a measured fact and must still compare: the fix must not turn every
# un-armed box into an unreadable one.
EMPTY_SHA='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
sed "s/^cron crew-d .*/cron crew-d $EMPTY_SHA/" "$SURF/before.fp" \
  >"$SURF/before-cron-empty.fp"
# One side read it, the other did not: there is no comparison to make, and the
# side that answered is not evidence about the side that did not.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/after-cron-unreadable.fp"
# A component that was there before and is gone after is movement, not silence.
grep -v '^cron crew-d ' "$SURF/before.fp" >"$SURF/after-box-gone.fp"

SURF_D0="crew up --dry-run exits 0"
SURF_DN="crew up --dry-run names a planned action"
SURF_DS="crew up --dry-run summarises"
SURF_DC="crew up --dry-run changed nothing"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-truthful-rc ok "$(surf_says "$r1" "$SURF_D0")"
t app-surface-218-truthful-per-box ok "$(surf_says "$r1" "$SURF_DN")"
t app-surface-218-truthful-summary ok "$(surf_says "$r1" "$SURF_DS")"
t app-surface-218-truthful-unchanged ok "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-created.fp" 0)"
t app-surface-218-staged-created-a-box FAIL "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-silent.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-unnamed-box FAIL "$(surf_says "$r1" "$SURF_DN")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-no-summary.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-no-summary FAIL "$(surf_says "$r1" "$SURF_DS")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 1)"
t app-surface-218-nonzero-rc-red FAIL "$(surf_says "$r1" "$SURF_D0")"
# Half the fingerprint was never taken, so "unchanged" is split rather than
# claimed over a comparison that compared less than it says. Both fingerprints
# are the SAME FILE here, which is the point: identical failures are identical,
# and `diff` called that agreement.
SURF_DP="crew up --dry-run moved none of the"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-unreadable.fp" "$SURF/before-unreadable.fp" 0)"
t app-surface-218-unreadable-inventory-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-inventory-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# The crontab half of the same defect, and the one with no marker at all before
# this: an unreachable box and a timed-out box both hashed to the empty string.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-unreadable.fp" "$SURF/before-cron-unreadable.fp" 0)"
t app-surface-218-unreadable-crontab-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# Nothing answered on either side. There is no partial claim left to make, so
# the partial `ok` must not be printed either.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-all-unreadable.fp" "$SURF/before-all-unreadable.fp" 0)"
t app-surface-218-nothing-readable-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-nothing-readable-claims-nothing absent "$(surf_says "$r1" "$SURF_DP")"
# One side answered and the other did not: still no comparison, and the side
# that answered is not evidence about the side that did not.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-cron-unreadable.fp" 0)"
t app-surface-218-one-sided-read-skips skip "$(surf_says "$r1" "$SURF_DC")"
# ...but a box that ANSWERED and has no crontab is a measured fact, and must
# still compare. The repair must not turn every un-armed box into an unread one.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-empty.fp" "$SURF/before-cron-empty.fp" 0)"
t app-surface-218-empty-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DC")"
# A component present before and absent after is movement, not silence — the
# shape a dry run that deleted something would leave.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-box-gone.fp" 0)"
t app-surface-218-component-vanished FAIL "$(surf_says "$r1" "$SURF_DC")"

# --- #308: an unanswered probe is unknown, never never-hired -------------
t app-surface-308-picks-the-silent-box crew-d \
  "$(surf app_surface_silent_box "$SURF/fleet.json")"
t app-surface-308-no-silent-box-to-ask '' \
  "$(surf app_surface_silent_box "$SURF/fleet-all-answered.json")"
printf 'box: crew-d\nengine: unknown — the box did not answer\n' >"$SURF/status-unknown.txt"
printf 'box: crew-d\nengine: not hired (no engine)\n'            >"$SURF/status-never-hired.txt"
printf 'box: crew-d\n'                                          >"$SURF/status-no-engine-line.txt"
SURF_S="an unanswered probe reads unknown"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-unknown.txt" 0)"
t app-surface-308-truthful-unknown ok "$(surf_says "$r1" "$SURF_S")"
# The wrong repair: the operator is sent to `crew hire` for a box that is
# hired and not talking.
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-never-hired.txt" 0)"
t app-surface-308-staged-never-hired FAIL "$(surf_says "$r1" "$SURF_S")"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-no-engine-line.txt" 2)"
t app-surface-308-no-engine-line-red FAIL "$(surf_says "$r1" "$SURF_S")"

# --- #345: `no build duty` names a cause and a count ---------------------
{ printf 'crew-a 12:00 heavy-duty/crew: no build duty (board empty)\n'
  printf 'crew-b 12:00 heavy-duty/crew: no build duty (slot held by #402; board holds 3 ready)\n'
  printf 'crew-d 12:00 heavy-duty/crew: no build duty (2 ready, 1 round(s) held by seen-ledger)\n'
} >"$SURF/nbd.txt"
printf 'crew-a 12:00 heavy-duty/crew: no build duty\n' >"$SURF/nbd-bare.txt"
: >"$SURF/nbd-empty.txt"
SURF_N="duty.log: every no build duty line names a cause"
r1="$(surf app_surface_no_build_duty "$SURF/nbd.txt")"
t app-surface-345-truthful-causes ok "$(surf_says "$r1" "$SURF_N")"
# The bare line #345 replaced: indistinguishable from the burial bug.
r1="$(surf app_surface_no_build_duty "$SURF/nbd-bare.txt")"
t app-surface-345-staged-bare-line FAIL "$(surf_says "$r1" "$SURF_N")"
r1="$(surf app_surface_no_build_duty "$SURF/nbd-empty.txt")"
t app-surface-345-nothing-logged-skips skip "$(surf_says "$r1" "no build duty names a cause")"

# --- the page halves: the walk's own named lines ------------------------
{ printf '  ok   floor: the canvas header paints the serving host version\n'
  printf '  ok   render: the engine tile carries its integrity verdict\n'
} >"$SURF/walk.out"
printf '  FAIL floor: the canvas header paints the serving host version\n' >"$SURF/walk-failed.out"
: >"$SURF/walk-never-reached.out"
SURF_W="page: the header renders"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk.out")"
t app-surface-walk-line-present ok "$(surf_says "$r1" "$SURF_W")"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-failed.out")"
t app-surface-walk-line-failed FAIL "$(surf_says "$r1" "$SURF_W")"
# A walk that exits 0 having never reached the check proves nothing about it.
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-never-reached.out")"
t app-surface-walk-never-reached FAIL "$(surf_says "$r1" "$SURF_W")"

# --- #312: disarmed is a decision, silent is an alarm --------------------
surf_page() {  # surf_page '<python mutating q>' → the page reader's payload
  python3 - "$1" <<'PY'
import json, sys
# `empty` is what drill/rehearsal-page-read.js reads off #emptyfloor: whether
# the panel is in the DOM at all, whether syncEmptyFloor has it shown, and its
# text. On a fleet with consoles drawn it is present and not shown, which is
# the shape the truthful fixture below carries.
q = {"live": True, "tiles": "4units3hired",
     "disarmed": ["crew-b"], "silent": ["crew-d"],
     "empty": {"present": True, "shown": False, "text": ""}}
exec(sys.argv[1])
print(json.dumps(q))
PY
}
# The empty floor as the page actually paints it (app.js:1681-1686), and the
# tile row that goes with a fleet where nothing is deployed: `hidden` is 4, so
# the hired tile renders, reading 0.
EMPTY_TEXT='NO BOX IS HIRED YET The fleet roster declares 4 boxes, and none of them is running an engine. A console appears here as its box is hired. crew hire <box>'
surf_page 'pass'                                     >"$SURF/page.json"
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b"]' >"$SURF/page-alarms-a-decision.json"
surf_page 'q["silent"] = ["crew-b"]'                 >"$SURF/page-both-groups.json"
surf_page 'q["disarmed"] = ["crew-z"]'               >"$SURF/page-unknown-box.json"
surf_page 'q["disarmed"], q["silent"] = [], []'      >"$SURF/page-no-members.json"
surf_page 'q["live"] = False'                        >"$SURF/page-demo.json"
surf_page 'q["tiles"] = "3units3hired"'              >"$SURF/page-shrunk.json"
surf_page 'q["tiles"] = "4units"'                    >"$SURF/page-no-hired-tile.json"
surf_page 'q["tiles"] = "4units4hired"'              >"$SURF/page-furniture.json"
# The two dropped-member stages: a page that lists nobody wrongly, by listing
# nobody at all. Before both directions were asserted these PASSED.
surf_page 'q["silent"] = []'                         >"$SURF/page-drops-silent.json"
surf_page 'q["disarmed"] = []'                       >"$SURF/page-drops-disarmed.json"
# The page agreeing with a payload that calls crew-b silent, so the only thing
# left to disagree is `crew status`.
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b", "crew-d"]' \
                                                     >"$SURF/page-b-silent.json"
# Two boxes the operator deliberately stopped, correctly grouped: the fleet the
# blind-set arity defect reds falsely when both are also logged out.
surf_page 'q["disarmed"], q["silent"] = ["crew-b", "crew-d"], []' \
                                                     >"$SURF/page-two-disarmed.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': False, 'shown': False, 'text': ''}" \
                                                     >"$SURF/page-empty-no-panel.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': False, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty-hidden.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'NO BOX IS HIRED YET The fleet roster declares 4 boxes.'}" \
                                                     >"$SURF/page-empty-no-verb.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'THE FLEET ROSTER IS EMPTY No box is declared. crew new <box>'}" \
                                                     >"$SURF/page-empty-wrong-verb.json"
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  disarmed\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status.txt"
# The same fleet, logged out. cli/crew:2123 gives a missing credential the note
# column outright, so the disarmed word never reaches it — the normal starting
# state on a drill host, and it must not read as a disagreement.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-logged-out.txt"
# TWO boxes logged out, which is the arity that matters: the blind set was
# accumulated as a display string (`crew-b, crew-d`) and then tested token-wise,
# so every member but the last kept a comma and read as NOT blind — a false
# FAIL on a correct page, invisible with the one-box fixture above (codex-bot,
# claude-bot, #428). Creds-free is the normal starting state on a drill host and
# two quiet boxes is an ordinary fleet, so this is the shape that reds #400's
# round against a page that is right.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   convergence unknown\n'
} >"$SURF/status-both-blind.txt"
# ...and the same, with both blind boxes DISARMED rather than one of each, so
# the members that must not red are the ones the disarmed direction iterates.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   ⚠ log in: box shell crew-d\n'
} >"$SURF/status-two-disarmed-blind.txt"
# ...and the same fleet where the CLI simply does not agree: crew-b is armed
# and ticking as far as `crew status` can tell.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  2026-08-08T11:04Z reviewed #428\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-b-armed.txt"

SURF_F="page: the state filter separates disarmed from silent"
SURF_T="page: the unit tile counts the declared roster"
SURF_E="page: an all-undeployed floor names the repair verb"
SURF_FC="page: the state filter agrees with crew status for every box"
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-truthful-split ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-page-truthful-tiles ok "$(surf_says "$r1" "$SURF_T")"
# Nothing was blind to `crew status`, so the reader's own caveat is not raised.
t app-surface-312-nothing-unclassifiable absent "$(surf_says "$r1" "$SURF_FC")"
# The load-bearing direction, and the whole of #312: a box the operator
# deliberately stopped counted in the alarm group.
r1="$(surf app_surface_page_groups "$SURF/page-alarms-a-decision.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-staged-decision-as-alarm FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-both-groups.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-both-groups-at-once FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-unknown-box.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-grouped-box-cli-never-saw FAIL "$(surf_says "$r1" "$SURF_F")"
# The other direction, which is the correction: a page that drops a genuinely
# silent box — or a genuinely disarmed one — has no member to be wrong about,
# and passed until the groups were compared as sets.
r1="$(surf app_surface_page_groups "$SURF/page-drops-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-silent-box FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-drops-disarmed.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-disarmed-box FAIL "$(surf_says "$r1" "$SURF_F")"
# The two readers disagreeing, each way round. The payload calls crew-b
# disarmed and the CLI shows it ticking...
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-b-armed.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-cli-does-not-confirm-disarmed FAIL "$(surf_says "$r1" "$SURF_F")"
# ...and the CLI calls crew-b deliberately stopped while the payload has it in
# the alarm group, which is #312's original defect read from the other reader.
r1="$(surf app_surface_page_groups "$SURF/page-b-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-b-not-disarmed.json")"
t app-surface-312-cli-says-stopped-payload-does-not FAIL "$(surf_says "$r1" "$SURF_F")"
# A logged-out box: `crew status` cannot answer for it, so it is named in its
# own skip and the page-side verdict still stands. Counting it as a
# disagreement would red a correct page on every creds-free host.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-logged-out.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-credential-note-does-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-credential-note-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# TWO blind boxes, one from each group — the cheaper reproduction, since the
# blind set is filled from the disarmed boxes before the silent ones, so the
# disarmed member is the one that carried the comma.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-both-blind.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-two-blind-boxes-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-boxes-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# ...and both of them DISARMED, which is the case put directly to the loop that
# tests blind membership. A correct page must skip here and not FAIL.
r1="$(surf app_surface_page_groups "$SURF/page-two-disarmed.json" "$SURF/status-two-disarmed-blind.txt" 4 crew-c 3 "$SURF/fleet-two-disarmed.json")"
t app-surface-312-two-blind-disarmed-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-disarmed-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# The set is machine-readable and the message is a copy of it: both boxes are
# named, comma-joined, and neither naming nor membership depends on the other.
t app-surface-312-blind-skip-names-both skip "$(surf_says "$r1" "armed-ness would be in: crew-b, crew-d")"
r1="$(surf app_surface_page_groups "$SURF/page-no-members.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-none-quiet.json")"
t app-surface-312-no-member-to-classify skip "$(surf_says "$r1" "$SURF_F")"
# The demo payload is not this host, so neither group may be read off it.
r1="$(surf app_surface_page_groups "$SURF/page-demo.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-demo-payload-skips skip "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-demo-payload-skips skip "$(surf_says "$r1" "$SURF_T")"
t app-surface-204-demo-payload-skips-empty-floor skip "$(surf_says "$r1" "$SURF_E")"
r1="$(surf app_surface_page_groups "$SURF/page-shrunk.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-204-staged-shrunk-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# Fully deployed: the count half still holds, and the hired tile is furniture.
r1="$(surf app_surface_page_groups "$SURF/page-no-hired-tile.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-fully-deployed ok "$(surf_says "$r1" "$SURF_T")"
r1="$(surf app_surface_page_groups "$SURF/page-furniture.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-permanent-hired-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# A floor with a console drawn is not the empty-floor state, and the drill will
# not un-hire a box to reach it: skipped by name, never quietly passed.
t app-surface-204-empty-floor-skips-when-drawn skip "$(surf_says "$r1" "$SURF_E")"

# --- #204's other half: the floor with nothing on it ---------------------
# Four declared boxes, none deployed. The issue asks for this floor to name
# `crew hire` in as many words, and nothing here read it before.
SURF_ALLND="crew-a crew-b crew-c crew-d"
r1="$(surf app_surface_page_groups "$SURF/page-empty.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-names-crew-hire ok "$(surf_says "$r1" "$SURF_E")"
# The count half still holds on that floor: 4 declared, 0 with a console.
t app-surface-204-empty-floor-tiles ok "$(surf_says "$r1" "$SURF_T")"
# A blank stage with no words on it is the state #204 named as the defect.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-panel.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-panel FAIL "$(surf_says "$r1" "$SURF_E")"
# In the DOM but never shown is the same blank stage to an operator.
r1="$(surf app_surface_page_groups "$SURF/page-empty-hidden.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-hidden FAIL "$(surf_says "$r1" "$SURF_E")"
# It says how many boxes are declared and stops — the count without the next
# step, which is the half the issue calls a requirement on the fix.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-repair-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# `crew new` is the wrong verb for a roster that DOES declare boxes: they exist
# to be hired, and telling the operator to create more is the wrong repair.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-wrong-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# ...and it is the RIGHT verb when the roster declares nothing at all, which is
# the other branch syncEmptyFloor renders.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 0 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-roster-names-crew-new ok "$(surf_says "$r1" "$SURF_E")"

# --- rehearsal phase 0: acquisition failures abort before checks (#27) --
P0SHIM="$TMP/phase0-bin"
P0HOME="$TMP/phase0-home"
P0LOG="$TMP/phase0-box.log"
mkdir -p "$P0SHIM" "$P0HOME"
# shellcheck disable=SC2016  # fixture expands state at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0LOG"\ncase "$1" in\n  list) printf "[]\\n" ;;\n  new|exec) exit 0 ;;\n  *) exit 2 ;;\nesac\n' >"$P0SHIM/box"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0SHIM/gh"
chmod +x "$P0SHIM/box" "$P0SHIM/gh"
: >"$P0LOG"

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

# --tree is a promise that SOURCE_SHA identifies the tree the operator means
# to drill, including the committed ref phase 1 installs (#183). Refuse every
# dirty shape before the first box operation and show the paths and reason.
P0TREE="$TMP/phase0-tree"
mkdir -p "$P0TREE/shared/test" "$P0TREE/cli"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0TREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0TREE/shared/test/run.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0TREE/cli/crew"
printf '0.0.0-test\n' >"$P0TREE/VERSION"
chmod +x "$P0TREE/shared/install.sh" "$P0TREE/shared/test/run.sh" "$P0TREE/cli/crew"
git -C "$P0TREE" init -q
git -C "$P0TREE" add .
git -C "$P0TREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-clean-tree-passes-guard passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-clean-tree-reaches-box reached-box "$r2"

printf '# dirty shared\n' >>"$P0TREE/shared/install.sh"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-shared-rc 1 "$r1"
case "$p0out" in
  *"shared/install.sh"*"SOURCE_SHA must name the tree"*"phase 1 installs"*"crew hire --ref"*) r2=attributed ;;
  *) r2=missing ;;
esac
t rehearsal-dirty-shared-attributed attributed "$r2"
t rehearsal-dirty-shared-before-box 0 "$(wc -l <"$P0LOG")"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal-all.sh" --roles reviewer --tree "$P0TREE" \
    --quick --no-app --no-config-drill --no-install-drill 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-all-passes-dirty-refusal-rc 1 "$r1"
case "$p0out" in *"has uncommitted changes"*"FAIL       reviewer"*) r2=passed ;; *) r2=swallowed ;; esac
t rehearsal-all-passes-dirty-refusal passed "$r2"

git -C "$P0TREE" restore shared/install.sh
printf '# dirty cli\n' >>"$P0TREE/cli/crew"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-cli-rc 1 "$r1"
case "$p0out" in *"cli/crew"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-cli-names-path named "$r2"
t rehearsal-dirty-cli-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore cli/crew
printf '0.0.1-staged\n' >"$P0TREE/VERSION"
git -C "$P0TREE" add VERSION
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-staged-rc 1 "$r1"
case "$p0out" in *"VERSION"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-staged-names-path named "$r2"
t rehearsal-dirty-staged-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore --staged --worktree VERSION
printf 'untracked\n' >"$P0TREE/NEW-FILE"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-untracked-rc 1 "$r1"
case "$p0out" in *"NEW-FILE"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-untracked-names-path named "$r2"
t rehearsal-dirty-untracked-before-box 0 "$(wc -l <"$P0LOG")"
rm -f "$P0TREE/NEW-FILE"

P0NONGIT="$TMP/phase0-not-git"
mkdir -p "$P0NONGIT/shared/test"
printf 'fixture\n' >"$P0NONGIT/shared/install.sh"
printf 'fixture\n' >"$P0NONGIT/shared/test/run.sh"
printf 'fixture\n' >"$P0NONGIT/VERSION"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0NONGIT" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-non-git-tree-rc 1 "$r1"
case "$p0out" in *"must be a git checkout with a clean working tree"*) r2=owned ;; *) r2=raw ;; esac
t rehearsal-non-git-tree-owned-error owned "$r2"
t rehearsal-non-git-tree-before-box 0 "$(wc -l <"$P0LOG")"

# A missing host git gets its own preflight reason, before the source guard or
# any box operation can turn it into a misleading checkout error.
P0NOGITSHIM="$TMP/phase0-no-git-bin"
mkdir -p "$P0NOGITSHIM"
ln -s "$(command -v dirname)" "$P0NOGITSHIM/dirname"
ln -s "$P0SHIM/box" "$P0NOGITSHIM/box"
ln -s "$P0SHIM/gh" "$P0NOGITSHIM/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0NOGITSHIM/jq"
chmod +x "$P0NOGITSHIM/jq"
: >"$P0LOG"
if p0out="$(PATH="$P0NOGITSHIM" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  /usr/bin/bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-missing-git-rc 1 "$r1"
case "$p0out" in *"git not found on the host"*) r2=owned ;; *) r2=misattributed ;; esac
t rehearsal-missing-git-owned-error owned "$r2"
t rehearsal-missing-git-before-box 0 "$(wc -l <"$P0LOG")"

# Remote/ref acquisition already uses git clone, but must not inherit the
# --tree-only clean-status probe.
P0GSHIM="$TMP/phase0-git-bin"
P0GITLOG="$TMP/phase0-git.log"
REAL_GIT="$(command -v git)"
mkdir -p "$P0GSHIM"
# shellcheck disable=SC2016  # expanded by the shim at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0GITLOG"\ncase " $* " in\n  *" status "*)\n    if [ "${P0GIT_FAIL_STATUS:-0}" -eq 1 ]; then echo "fixture status failure" >&2; exit 42; fi\n    if [ "${P0GIT_WARN_STATUS:-0}" -eq 1 ]; then echo "fixture status warning" >&2; fi ;;\nesac\nexec "$REAL_GIT" "$@"\n' >"$P0GSHIM/git"
chmod +x "$P0GSHIM/git"

# A warning from a successful status is not a dirty path and must not make a
# clean checkout refuse. A failed status retains its stderr in crew's error.
: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_WARN_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-status-warning-is-not-dirty passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-status-warning-reaches-box reached-box "$r2"

: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_FAIL_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-status-failure-rc 1 "$r1"
case "$p0out" in *"could not inspect"*"fixture status failure"*) r2=owned ;; *) r2=missing ;; esac
t rehearsal-status-failure-owned-error owned "$r2"
t rehearsal-status-failure-before-box 0 "$(wc -l <"$P0LOG")"

P0REMOTE="$TMP/phase0-remote.git"
P0REF="$(git -C "$P0TREE" branch --show-current)"
git clone -q --bare "$P0TREE" "$P0REMOTE"
: >"$P0GITLOG"
: >"$P0LOG"
PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$P0REMOTE" \
    --ref "$P0REF" --quick >/dev/null 2>&1 || true
if grep -Eq '(^|[[:space:]])status([[:space:]]|$)' "$P0GITLOG"; then r2=probed; else r2=untouched; fi
t rehearsal-remote-skips-clean-tree-probe untouched "$r2"

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

# The suite/reference extraction, archive selection and phase-0 verifier are
# one contract: each can drift independently, and empty inputs never cover it.
P0COVER_SUITE="$TMP/phase0-cover-suite.sh"
P0COVER_REHEARSAL="$TMP/phase0-cover-rehearsal.sh"
cp "$HERE/run.sh" "$P0COVER_SUITE"
cp "$ROOT/drill/rehearsal.sh" "$P0COVER_REHEARSAL"
# shellcheck disable=SC2016  # write a literal synthetic suite dependency
printf '%s%s\n' '$ROOT' '/postmortems' >>"$P0COVER_SUITE"
t phase0-new-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a literal brace-form suite dependency
printf '%s%s\n' '${ROOT}' '/postmortems/report.md' >>"$P0COVER_SUITE"
t phase0-braced-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a dependency beneath the excluded subtree
printf '%s%s\n' '$ROOT' '/fleet-floor/dev/assets.json' >>"$P0COVER_SUITE"
t phase0-excluded-suite-path-refused excluded:fleet-floor/dev \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # replace the block with the literal legacy command
sed -i '/BEGIN phase-0 archive selection/,/END phase-0 archive selection/c\
# BEGIN phase-0 archive selection\
tar czf "$ENGINE_ARCHIVE" -C "$SOURCE_TREE" shared VERSION\
# END phase-0 archive selection' "$P0COVER_REHEARSAL"
t phase0-legacy-archive-selection-refused archive:archive-selection-mismatch \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_SUITE"
t phase0-empty-suite-root-list-refused empty-suite-roots \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_REHEARSAL"
t phase0-empty-verified-root-list-refused empty-verified-roots \
  "$(phase0_coverage_result "$HERE/run.sh" "$P0COVER_REHEARSAL")"

# Exercise the in-box verifier, not just its static root list. The fixture is
# a valid clean git tree with one required root deliberately absent; phase 0
# must attribute that truncation before it can run the staged suite.
P0VERIFYTREE="$TMP/phase0-verify-tree"
P0VERIFYHOME="$TMP/phase0-verify-home"
P0VERIFYSHIM="$TMP/phase0-verify-bin"
mkdir -p "$P0VERIFYTREE"/{.ceremony,.github,cli,drill,fleet-floor,shared/test} \
  "$P0VERIFYHOME" "$P0VERIFYSHIM"
printf 'fixture\n' >"$P0VERIFYTREE/.ceremony/marker"
printf 'fixture\n' >"$P0VERIFYTREE/.github/marker"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0VERIFYTREE/cli/crew"
printf 'fixture\n' >"$P0VERIFYTREE/drill/marker"
printf 'fixture\n' >"$P0VERIFYTREE/fleet-floor/marker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0VERIFYTREE/shared/test/run.sh"
printf '0.0.0-test\n' >"$P0VERIFYTREE/VERSION"
chmod +x "$P0VERIFYTREE/cli/crew" "$P0VERIFYTREE/install.sh" \
  "$P0VERIFYTREE/shared/install.sh" "$P0VERIFYTREE/shared/test/run.sh"
git -C "$P0VERIFYTREE" init -q
git -C "$P0VERIFYTREE" add .
git -C "$P0VERIFYTREE" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm fixture
# shellcheck disable=SC2016  # the shim receives and executes rehearsal's script argument
printf '%s\n' '#!/usr/bin/env bash
case "$1" in
  list) printf "[]\n" ;;
  new) exit 0 ;;
  exec)
    shift 5
    HOME="$P0VERIFYHOME" bash -lc "$1" ;;
  *) exit 2 ;;
esac' >"$P0VERIFYSHIM/box"
chmod +x "$P0VERIFYSHIM/box"
if p0out="$(PATH="$P0VERIFYSHIM:$P0SHIM:$PATH" P0VERIFYHOME="$P0VERIFYHOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0VERIFYTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t phase0-truncated-tree-rc 1 "$r1"
case "$p0out" in *"transferred engine failed verification"*) r1=attributed ;; *) r1=missing ;; esac
t phase0-truncated-tree-attributed attributed "$r1"
case "$p0out" in *"fixture tests green"*) r1=ran-suite ;; *) r1=stopped-before-suite ;; esac
t phase0-truncated-tree-stops-before-suite stopped-before-suite "$r1"

# --- install-drill step 9: engine/cron/tick survival, both paths (#341) --
# The tick leg used to demand an unchanged, NON-EMPTY last duty.log line. A box
# hired seconds earlier has no duty.log at all — it is written at the first
# cron boundary — so on the drill's own standalone path the assertion failed by
# construction. Observed on crew-drill-011, 2026-08-03: the drill read an empty
# tail and redded, and the box's first tick fired 14s later, AFTER the console
# removal.
#
# These fixtures drive the predicate itself, not a host: a fake box home, the
# crontab shim above, and a clock the wait spends instead of the suite's wall
# time. As with the rehearsal-safety block above, the caller's bx() is what
# makes that possible; each block defines its own and nothing after either one
# calls it.
SHOME="$TMP/survival-home"
SDUTY="$SHOME/duty"
SCRON="$TMP/survival-crontab"
SURVIVAL_CLOCK=0
SURVIVAL_TICK_AT=""
SURVIVAL_RESTAMP_AT=""
SURVIVAL_DISARM_AT=""

# survival_reset <engine> <armed|disarmed> [last duty.log line]
# The third argument is the whole difference between the two paths: a borrowed
# box arrives with tick history, a freshly hired one does not.
survival_reset() {
  rm -rf "$SHOME"; mkdir -p "$SDUTY/bin"
  printf '%s\n' "$1" >"$SDUTY/VERSION"
  : >"$SCRON"
  if [ "$2" = armed ]; then
    printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$SDUTY" >"$SCRON"
  fi
  [ -z "${3:-}" ] || printf '%s\n' "$3" >"$SDUTY/duty.log"
  SURVIVAL_CLOCK=0
  SURVIVAL_TICK_AT=""
  SURVIVAL_RESTAMP_AT=""
  SURVIVAL_DISARM_AT=""
}

bx() { HOME="$SHOME" PATH="$ISHIM" CRON_STATE="$SCRON" bash -c "$1"; }
# shellcheck source=drill/install-survival.sh
source "$ROOT/drill/install-survival.sh"
# The two seams, taken over: the clock only moves when the predicate sleeps, so
# the real 300+90s budget is exercised in no wall time at all — and the tick
# lands when the fixture's boundary strikes, the way a surviving engine's does.
# The two *_AT breakages are how a box is made to lose engine or cron INSIDE the
# wait window, which is the only place the second engine/cron read can see them.
install_survival_now() { printf '%s\n' "$SURVIVAL_CLOCK"; }
install_survival_sleep() {
  SURVIVAL_CLOCK=$((SURVIVAL_CLOCK + $1))
  if [ -n "$SURVIVAL_TICK_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_TICK_AT" ]; then
    printf 'tick %s duty run end\n' "$SURVIVAL_TICK_AT" >>"$SDUTY/duty.log"
  fi
  if [ -n "$SURVIVAL_RESTAMP_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_RESTAMP_AT" ]; then
    printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
  fi
  if [ -n "$SURVIVAL_DISARM_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_DISARM_AT" ]; then
    : >"$SCRON"
  fi
}
# Which surfaces the detail blames, as a list — the D2 assertion in one line.
survival_surfaces() {
  printf '%s' "$INSTALL_SURVIVAL_DETAIL" | tr ';' '\n' |
    sed 's/^ *//;s/:.*//' | tr '\n' ',' | sed 's/,$//'
}

# The budget is the box's own schedule, not a constant this file guesses at.
t survival-budget-reads-the-cron-period 150 "$(install_survival_budget '*/1 * * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-unparsable 390 "$(install_survival_budget '17 2 * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-cron-empty 390 "$(install_survival_budget '')"

# --- the fresh-box path: no duty.log before the removal
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-fresh-box-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
t survival-fresh-box-label-describes-arrival "the box arrived with no duty.log" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-passes-on-the-observed-tick survived "$r1"
t survival-fresh-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-fresh-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# The mutation #192's precedent requires: step 9's leg as it read before this
# fix — one read, no wait — against the same fixture that just passed.
SURVIVAL_WAIT="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"; [ -n "$INSTALL_SURVIVAL_TICK" ]
}
install_survival_check && r1=survived || r1=red
t survival-deleting-the-wait-reds-the-fresh-box red "$r1"
t survival-deleting-the-wait-still-names-tick tick "$(survival_surfaces)"
eval "$SURVIVAL_WAIT"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-restoring-the-wait-passes-the-same-fixture survived "$r1"

# A fresh box whose engine never ticks again is the failure this path exists to
# catch, and it must be reported as the tick — not as the removal transcript.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-fresh-box-with-no-tick-reds red "$r1"
t survival-fresh-box-with-no-tick-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"duty.log"*"390s"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-fresh-box-with-no-tick-says-what-it-read says-what-it-read "$r1"
t survival-fresh-box-with-no-tick-waited-the-budget 390 "$SURVIVAL_CLOCK"

# --- a tick that lands DURING the uninstall proves nothing
# The wait measures against the log as the COMPLETED removal left it, not the
# empty read taken before it. A boundary striking while `crew uninstall` runs
# writes a line the console was still installed for; accepting it would pass
# step 9 at zero elapsed time on a box whose engine never ticked again.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-uninstall-tick-still-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-alone-reds red "$r1"
t survival-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
t survival-tick-during-uninstall-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"tick during uninstall"*"already there"*) r1=says-the-stale-line ;; *) r1=OPAQUE ;;
esac
t survival-tick-during-uninstall-says-the-stale-line says-the-stale-line "$r1"

# …and that same box passes the moment the engine ticks after the removal.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-then-a-real-tick-passes survived "$r1"
t survival-tick-during-uninstall-reports-the-later-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"

# The mutation the case exists for: the baseline-blind wait — first non-empty
# line wins — takes the during-uninstall line as its evidence and concludes in
# no time at all, which is the false pass this fixture must catch.
SURVIVAL_WAIT_PRE="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    [ -z "$INSTALL_SURVIVAL_TICK" ] || return 0
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-baseline-blind-wait-false-passes-the-uninstall-tick survived "$r1"
t survival-baseline-blind-wait-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_PRE"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-the-baseline-reds-the-same-fixture red "$r1"

# --- the wait window is not a blind spot
# Up to a whole cron period passes inside the wait, so engine and cron are read
# again on the other side of it: a box that loses either one in there did not
# outlive its console, and the detail names the read that saw it go.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_RESTAMP_AT=305
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-inside-the-wait-reds red "$r1"
t survival-engine-restamped-inside-the-wait-names-engine engine "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"after the 390s tick wait"*) r1=says-which-read ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-inside-the-wait-says-which-read says-which-read "$r1"

survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_DISARM_AT=305
install_survival_check && r1=survived || r1=red
t survival-cron-disarmed-inside-the-wait-reds red "$r1"
t survival-cron-disarmed-inside-the-wait-names-cron cron "$(survival_surfaces)"

# A surface that missed before the wait is reported once, at the read that saw
# it — the second pass must not double it into the detail.
survival_reset '' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-engine-gone-reds red "$r1"
t survival-fresh-box-engine-gone-reported-once engine "$(survival_surfaces)"

# --- the borrowed-box context: history, with the same post-removal wait
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
t survival-borrowed-box-records-history-context history "$INSTALL_SURVIVAL_PATH"
t survival-borrowed-box-label-describes-arrival "the box arrived with tick history" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-newer-post-removal-line-passes survived "$r1"
t survival-borrowed-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-borrowed-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# A borrowed box whose engine dies with its console spends the full budget and
# reds. This explicitly inverts the old borrowed-box pass on an unchanged log.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-unchanged-log-now-reds red "$r1"
t survival-borrowed-box-unchanged-log-names-tick tick "$(survival_surfaces)"
t survival-borrowed-box-unchanged-log-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"box arrived with"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-box-failure-retains-pre-removal-tick names-arrival-tick "$r1"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
rm -f "$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-emptied-log-still-reds red "$r1"

# A tick written during uninstall is the post-removal baseline, not survival
# evidence. The borrowed context must exclude it exactly as the fresh one does.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-alone-reds red "$r1"
t survival-borrowed-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"2026-08-03T15:19:01Z tick during uninstall"*) r1=says-both-lines ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-tick-during-uninstall-says-both-lines says-both-lines "$r1"

# …and that same borrowed box passes once a later boundary proves survival.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-then-real-tick-passes survived "$r1"

# Restore the old byte-identical borrowed-path comparison. It reds the healthy
# fixture above as soon as it sees the uninstall-boundary line and never waits
# for the later proof. This is the reported flake's negative mutation.
SURVIVAL_WAIT_HISTORY="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
  [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" = "$INSTALL_SURVIVAL_TICK_PRE" ]
}
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-byte-identical-compare-reds red "$r1"
eval "$SURVIVAL_WAIT_HISTORY"

# Pointing the wait at TICK_PRE instead of the post-removal read accepts the
# during-uninstall line at zero elapsed time. The correct baseline reds it.
SURVIVAL_WAIT_POST="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    if [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" != "$INSTALL_SURVIVAL_TICK_PRE" ]; then
      return 0
    fi
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-borrowed-pre-removal-baseline-false-passes survived "$r1"
t survival-borrowed-pre-removal-baseline-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_POST"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-post-removal-baseline-reds red "$r1"

# --- the real survival failures, on the surfaces they happened to
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
: >"$SCRON"
install_survival_check && r1=survived || r1=red
t survival-cron-removed-by-hand-reds red "$r1"
t survival-cron-removed-by-hand-names-cron-first cron,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick.sh"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-cron-removed-says-what-it-read says-what-it-read "$r1"
t survival-borrowed-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick: not waited for"*) r1=says-no-wait ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-says-no-wait says-no-wait "$r1"
case "$INSTALL_SURVIVAL_DETAIL" in *"2026-08-03T15:14:01Z duty run end"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-retains-pre-removal-tick names-arrival-tick "$r1"

# The same removal on a fresh box: no boundary can strike, so the wait is not
# entered at all and the report says so rather than blaming the tick alone.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
: >"$SCRON"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-cron-removed-reds red "$r1"
t survival-fresh-box-cron-removed-names-cron-first cron,tick "$(survival_surfaces)"
t survival-fresh-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-reds red "$r1"
t survival-engine-restamped-names-engine-first engine,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"crew@9.9.9-someone-elses"*"crew@0.0.0-drill-b"*) r1=says-both ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-says-read-and-expected says-both "$r1"

survival_reset '' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-engine-gone-reds red "$r1"
t survival-engine-gone-names-engine-first engine,tick "$(survival_surfaces)"

# The driver reads the predicate from here and reports the surfaces, so the
# transcript that misled #341 cannot come back as the evidence.
if grep -qF 'install_survival_before' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'install_survival_check' "$ROOT/drill/install-drill.sh"; then r1=wired; else r1=MISSING; fi
t survival-driver-uses-the-shared-predicate wired "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF '($INSTALL_SURVIVAL_PATH_LABEL)' "$ROOT/drill/install-drill.sh"; then r1=context; else r1=LOST; fi
t survival-driver-pass-line-keeps-arrival-context context "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF 'fail "step 9: positive engine/cron/tick survival observation" "$INSTALL_SURVIVAL_DETAIL"' \
     "$ROOT/drill/install-drill.sh"; then r1=surfaces; else r1=TRANSCRIPT; fi
t survival-driver-fails-with-the-surfaces surfaces "$r1"
if grep -qE 'tick_(pre_remove|after)' "$ROOT/drill/install-drill.sh"; then r1=INLINE; else r1=extracted; fi
t survival-driver-keeps-no-inline-copy extracted "$r1"

# --- drill/install-payload.sh: #365's payload rule, per channel (#421) ----
# Same shape as the survival block above: the predicate is driven against
# fixtures rather than a host — a stub installer, stub guards, and installed
# trees built by hand. No bx() is needed at all here, because the thing under
# assertion is an ordinary directory: install-drill.sh's installs are
# host-side, into its own scratch CREW_HOME.
PHOME="$TMP/payload"

# payload_src <declared roots, space separated> <bound in guard A> <bound in B>
# A stub source tree: the installer's list and the two offline guards that
# spell the size bound, in the shape install-payload.sh reads them.
payload_src() {
  local roots p; read -ra roots <<<"$1"
  rm -rf "$PHOME/src"; mkdir -p "$PHOME/src/shared/test"
  { printf 'PAYLOAD_EXCLUDED_PATHS=(\n'
    for p in "${roots[@]}"; do [ -z "$p" ] || printf '  %s  # a reason\n' "$p"; done
    printf ')\n'
  } >"$PHOME/src/install.sh"
  # shellcheck disable=SC2016  # `$kb` is the guard's literal text
  [ "$2" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$2" >"$PHOME/src/shared/test/install-lifecycle.sh"
  [ "$2" = - ] && : >"$PHOME/src/shared/test/install-lifecycle.sh"
  # shellcheck disable=SC2016  # same
  [ "$3" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$3" >"$PHOME/src/shared/test/artifact.sh"
  [ "$3" = - ] && : >"$PHOME/src/shared/test/artifact.sh"
  return 0
}

# payload_tree <name> <root to plant, or -> <filler KiB> → echoes the path
payload_tree() {
  local dir="$PHOME/trees/$1"
  rm -rf "$dir"; mkdir -p "$dir/cli"
  [ "$2" = - ] || mkdir -p "$dir/$2"
  head -c "$(( $3 * 1024 ))" /dev/zero >"$dir/filler"
  printf '%s\n' "$dir"
}

# The predicate's own report, captured. A subshell supplies the pass()/fail()
# the caller owes it, so neither name escapes into the suite around it.
payload_run() {  # <source tree> <installed tree>
  ( pass() { printf 'PASS %s\n' "$1"; }
    fail() { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
    # shellcheck source=drill/install-payload.sh
    . "$ROOT/drill/install-payload.sh"
    install_payload_assert payload "$1" "$2" )
}
payload_verdict() { case "$1" in *FAIL*) printf 'red\n' ;; *) printf 'green\n' ;; esac; }

CLEAN_ROOTS='.git drill shared/test fleet-floor/dev fleet-floor/test'

# A tree that ships none of them, well under the bound.
#
# The expectation for the reported size is `du -skL`'s own reading of this
# tree, never a hard-coded window: du charges directory inodes per filesystem,
# so the two directories below cost 0 blocks on the tmpfs a box's $TMP usually
# is and 4 KiB each on a runner's ext4 — 64 KiB here and 72 KiB there, for the
# same fixture. A band is green on one and red on the other for a reason that
# is not the predicate's. Equality against du is also the stronger assertion:
# it pins the line to the measurement rather than to a range a constant could
# sit in, and payload-two-trees-report-different-sizes below closes the last
# way a constant could still satisfy it.
payload_src "$CLEAN_ROOTS" 3072 3072
payload_dir="$(payload_tree clean - 64)"
payload_kb="$(du -skL "$payload_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_dir")"
t payload-clean-tree-passes green "$(payload_verdict "$r1")"
case "$r1" in *"is $payload_kb KiB, within the 3072 KiB bound"*) r2=measured ;; *) r2="$r1" ;; esac
t payload-pass-line-carries-the-measured-size measured "$r2"
case "$r1" in *"none of the installer's 5 excluded roots"*) r2=counted ;; *) r2="$r1" ;; esac
t payload-pass-line-counts-the-roots-it-walked counted "$r2"

# MUST FAIL: a tree carrying fleet-floor/dev reds, NAMING that path — and it is
# not a size finding, so the size assertion beside it still passes. A leg that
# only redded on the bound would report "over budget" and leave the operator to
# work out which root came back.
r1="$(payload_run "$PHOME/src" "$(payload_tree fat-dev fleet-floor/dev 64)")"
t payload-dev-root-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-dev-root-names-the-path named "$r2"
case "$r1" in *"PASS payload: installed tree is"*) r2=size-still-green ;; *) r2="$r1" ;; esac
t payload-dev-root-is-not-a-size-finding size-still-green "$r2"

# MUST FAIL: under the bound and still carrying a test root. This is the case a
# size-only check passes.
r1="$(payload_run "$PHOME/src" "$(payload_tree small-test shared/test 64)")"
t payload-test-root-under-budget-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: shared/test"*) r2=named ;; *) r2="$r1" ;; esac
t payload-test-root-under-budget-names-the-path named "$r2"

# …and the mirror: no excluded root anywhere, and fat. The bound is the only
# thing that catches the next big directory nobody thought to exclude.
payload_fat_dir="$(payload_tree fat-clean - 4096)"
payload_fat_kb="$(du -skL "$payload_fat_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_fat_dir")"
t payload-over-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"within the 3072 KiB bound — measured $payload_fat_kb KiB"*) r2=says-both ;; *) r2="$r1" ;; esac
t payload-over-bound-names-bound-and-measurement says-both "$r2"
# Two trees, two different readings: whatever the filesystem charges for the
# directories, a 4096 KiB tree cannot measure the same as a 64 KiB one. This is
# what stops a predicate that printed a constant from satisfying both cases
# above, which is the force the removed band was carrying.
if [ "$payload_fat_kb" -gt "$payload_kb" ]; then r2=differ; else r2="$payload_kb vs $payload_fat_kb"; fi
t payload-two-trees-report-different-sizes differ "$r2"

# MUST FAIL: a fat artifact tree reds where the checkout tree is clean. The
# channels are asserted separately for exactly this reason — one verdict per
# installed tree, never one inferred from another.
r1="$(payload_run "$PHOME/src" "$(payload_tree channel-checkout - 64)")"
r2="$(payload_run "$PHOME/src" "$(payload_tree channel-artifact fleet-floor/dev 4096)")"
t payload-per-channel-verdicts-are-independent "green red" \
  "$(payload_verdict "$r1") $(payload_verdict "$r2")"

# THE MUTATION THAT DELETES ITS OWN CHECK. Reverting #365 takes fleet-floor/dev
# out of PAYLOAD_EXCLUDED_PATHS, so a walk over only what the installer still
# names would go green on the very regression this leg exists for. The sentinel
# is unioned in, so the tree is still walked against it — and the installer
# having dropped it is a separate finding, not a silence.
payload_src '.git drill shared/test fleet-floor/test' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree reverted fleet-floor/dev 4096)")"
t payload-reverted-exclusion-still-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-reverted-exclusion-still-names-the-root named "$r2"
# shellcheck source=drill/install-payload.sh
. "$ROOT/drill/install-payload.sh"
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-reverted-exclusion-reported-against-the-source dropped "$r1"
payload_src "$CLEAN_ROOTS" 3072 3072
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-declared-sentinel-is-reported-named named "$r1"

# The bound is READ, and reading it doubles as a drift check between the two
# guards that both spell it: disagreement is a defect this drill will not pick
# a winner for.
t payload-bound-read-from-the-guards 3072 "$(install_payload_budget_kb "$PHOME/src")"
payload_src "$CLEAN_ROOTS" 3072 4096
r1="$(payload_run "$PHOME/src" "$(payload_tree disagree - 64)")"
t payload-guards-disagreeing-on-the-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"disagree on the size bound"*) r2=says-so ;; *) r2="$r1" ;; esac
t payload-guards-disagreeing-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" - -
r1="$(payload_run "$PHOME/src" "$(payload_tree nobound - 64)")"
t payload-no-bound-in-the-guards-reds red "$(payload_verdict "$r1")"
case "$r1" in *"no installed-tree size bound"*) r2=says-so ;; *) r2="$r1" ;; esac
t payload-no-bound-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" 3072 3072
rm -f "$PHOME/src/shared/test/artifact.sh"
r1="$(payload_run "$PHOME/src" "$(payload_tree noguard - 64)")"
case "$r1" in *"artifact.sh is missing"*) r2=names-the-guard ;; *) r2="$r1" ;; esac
t payload-missing-guard-names-it names-the-guard "$r2"

# An installer whose list stopped parsing is a red, never an empty walk.
payload_src '' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree noparse - 64)")"
t payload-unparsable-exclusion-list-reds red "$(payload_verdict "$r1")"
case "$r1" in *"did not parse"*) r2=says-so ;; *) r2="$r1" ;; esac
t payload-unparsable-exclusion-list-says-so says-so "$r2"
# …and a tree that is not there is its own finding, reached only once the two
# reads above have succeeded — which is why the source is restored first.
payload_src "$CLEAN_ROOTS" 3072 3072
r1="$(payload_run "$PHOME/src" "$PHOME/trees/does-not-exist")"
case "$r1" in *"nothing at"*) r2=says-so ;; *) r2="$r1" ;; esac
t payload-absent-installed-tree-says-so says-so "$r2"

# The rule the shipped tree actually carries, read through the same predicate
# the drill uses — so a guard reworded past the read reds here and not on a
# release night.
PAYLOAD_SHIPPED_BOUND="$(install_payload_budget_kb "$ROOT")"
case "$PAYLOAD_SHIPPED_BOUND" in [1-9]*) r1=numeric ;; *) r1="$PAYLOAD_SHIPPED_BOUND" ;; esac
t payload-shipped-bound-is-readable numeric "$r1"
install_payload_excluded_roots "$ROOT" | grep -qx 'shared/test' && r1=walked || r1=MISSING
t payload-shipped-list-names-the-test-root walked "$r1"
install_payload_installer_names_sentinel "$ROOT" && r1=named || r1=dropped
t payload-shipped-installer-excludes-the-sentinel named "$r1"

# CRITERION: no size constant is spelled in drill/. Asserted against the bound
# as read, so it keeps holding after the number moves.
if grep -rqF "$PAYLOAD_SHIPPED_BOUND" "$ROOT/drill/"; then r1=SPELLED; else r1=read-not-typed; fi
t payload-drill-spells-no-size-constant read-not-typed "$r1"

# The driver reads the predicate from here, at all three installed trees.
# shellcheck disable=SC2016  # the driver's literal lines are the patterns
if grep -qF '. "$ROOT/drill/install-payload.sh"' "$ROOT/drill/install-drill.sh"; then
  r1=sourced; else r1=MISSING; fi
t payload-driver-sources-the-shared-predicate sourced "$r1"
r1="$(grep -c 'install_payload_assert ' "$ROOT/drill/install-drill.sh")"
t payload-driver-asserts-three-installed-trees 3 "$r1"
# shellcheck disable=SC2016  # same
if grep -qF 'versions/$VA' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'CREW_HOME/current' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'ARTIFACT_HOME/share/current' "$ROOT/drill/install-drill.sh"; then
  r1=first-upgrade-artifact; else r1=INCOMPLETE; fi
t payload-driver-covers-first-upgrade-and-artifact first-upgrade-artifact "$r1"

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
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/addressing.jq"; then r1=head-keyed; else r1=CHANGED; fi
t addressing-keys-on-head head-keyed "$r1"

# --- #133: engine (re-)requests the panel, keyed off the session's SIGNAL -----
# request-panel.jq answers "whom, given the engine already holds the licence";
# answered-head.jq is that licence — the head the session last signalled, and
# (since #286) WHEN it signalled — and the engine acts only when that head
# equals the current one, never on commit activity (#133's hardest must-fail).
RPJQ="$SHARED/lib/jq/request-panel.jq"
AHJQ="$SHARED/lib/jq/answered-head.jq"
RP_OLD="dddddddddddddddddddddddddddddddddddddddd"
RP_MARK="📣 round answered at head"
# The fixture CLOCK (#286). Ordering is the whole subject now, so every fixture
# states its times against these three, taken from the #281 transcript: the
# signal that OPENED round 1, the verdict that CLOSED it, and a later signal that
# would answer that verdict. T_SIG_OPEN < T_VERDICT < T_SIG_ANSWER.
RP_T_SIG_OPEN="2026-08-02T10:08:12Z"
RP_T_VERDICT="2026-08-02T10:32:33Z"
RP_T_SIG_ANSWER="2026-08-02T11:12:27Z"
# payload builder carrying comments (the signal lives there), reviewRequests and
# latestOpinionatedReviews. Reuses H from the converged block.
#
# Timestamps are DEFAULTED, not forced: a review node with no submittedAt gets
# RP_T_VERDICT and a comment with no createdAt gets RP_T_SIG_ANSWER, so a
# fixture that says nothing about time describes the ordinary case — the builder
# signalled after reading the verdict. A fixture that cares states its own, and
# one that means "the API returned no time here" says so with an explicit null,
# which `has` preserves. Before #286 the nodes carried no times at all, and that
# is precisely why no test could fail on this bug.
mk_rp() {  # <head> <reqs-json> <revs-json> <comments-json>
  jq -n --arg head "$1" --argjson reqs "$2" --argjson revs "$3" --argjson coms "$4" \
    --arg rev_at "$RP_T_VERDICT" --arg com_at "$RP_T_SIG_ANSWER" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head,
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:($revs|map(
        if has("submittedAt") then . else . + {submittedAt:$rev_at} end))},
      comments:{nodes:($coms|map(
        if has("createdAt") then . else . + {createdAt:$com_at} end))}}}}}'
}
# The signal request-panel.jq is handed. Shaped exactly like answered-head.jq's
# output, because in the engine it IS that output — the two are wired together
# in _request_panel and nowhere else.
sig() { jq -cn --arg sha "$1" --arg at "$2" '{sha:$sha,createdAt:$at}'; }
rp() {  # <signal-json> [panel-json]
  jq -r --argjson panel "${2:-$PANEL}" --argjson signal "$1" -f "$RPJQ" \
    | tr '\n' ' ' | sed 's/ $//'
}
ah() { jq -c --arg me me-bot --arg mark "$RP_MARK" -f "$AHJQ"; }
ah_sha() { ah | jq -r '.sha'; }
# The default signal: at the current head, later than the default verdict time.
# Fixtures with no current-head verdict are indifferent to it by construction.
RP_SIG_LATE="$(sig "$H" "$RP_T_SIG_ANSWER")"
RP_CR_AT_HEAD='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
RP_STALE_BOTH='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$RP_OLD'"}},{"author":{"login":"rev-b"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'

# request-panel.jq — whom to request once licensed.
t rp-first-round-requests-all "rev-a rev-b" \
  "$(mk_rp "$H" '[]' '[]' '[]' | rp "$RP_SIG_LATE")"
# The no-push half #133 exists for: a change-request AT the current head is
# re-requested (the builder answered with argument), the head approver is not.
# RETIMED for #286, not preserved: this case was written with no comments at
# all, so its signal could never be newer than the verdict it claimed to answer,
# and it expected rev-a anyway. It is now the boundary PAIR below — the same
# reviews read twice, once under a signal newer than the verdict and once under
# the signal that opened the round. Leaving it as it stood and still passing
# would mean the predicate is not reading the ordering.
t rp-no-push-cr-at-head-requests-cr-er "rev-a" \
  "$(mk_rp "$H" '[]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
t rp-no-push-stale-signal-requests-none "" \
  "$(mk_rp "$H" '[]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
t rp-converged-requests-none "" \
  "$(mk_rp "$H" '[]' "$REVS_OK" '[]' | rp "$RP_SIG_LATE")"
# Head moved: every prior review is stale → all re-requested, approvers included.
t rp-head-moved-requests-all "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_STALE_BOTH" '[]' | rp "$RP_SIG_LATE")"
t rp-already-requested-none "" \
  "$(mk_rp "$H" '["rev-a","rev-b"]' "$RP_STALE_BOTH" '[]' | rp "$RP_SIG_LATE")"
# Never triage: the request derives only from $panel, so an off-panel identity
# (dan-claude-bot) that left a review or a request cannot be returned.
RP_TRIAGE_REV='[{"author":{"login":"dan-claude-bot"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'
t rp-never-targets-triage "rev-a rev-b" \
  "$(mk_rp "$H" '["dan-claude-bot"]' "$RP_TRIAGE_REV" '[]' | rp "$RP_SIG_LATE")"

# --- #286: ONE SIGNAL OPENS ONE ROUND ----------------------------------------
# The licence is spent by the verdicts that answer it. Every case below was
# inexpressible before the fixtures had a clock.
#
# THE #281 LOOP, in one fixture. Signal opens the round; both panelists answer
# it at the head, one blocking; GitHub has dropped them from requested_reviewers
# the instant they submitted. Before the fix this returned the change-requester
# and did so on every tick, forever, on a tree nobody had changed.
RP_281='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"},
         {"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"},"submittedAt":"2026-08-02T10:29:40Z"}]'
# The same blocking verdict with rev-b's approval removed: rev-b now owes a
# first verdict at this head, so it rides through every hold that binds rev-a
# and each fixture below shows WHICH panelist was held rather than an empty set
# that two different rules could have produced.
RP_CR_A_ONLY='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
t rp-286-closed-round-requests-none "" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
# ...and the no-push resolution still works: the builder answers with argument,
# pushes nothing, re-signals — a signal NEWER than the blocking verdict — and
# exactly the change-requester is re-requested. The pair is the boundary: revert
# the predicate and the fixture above goes red while this one stays green.
t rp-286-newer-signal-requests-cr-er "rev-a" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# An equal-second tie HOLDS — fail-closed. A signal posted in the same second as
# the verdict cannot be shown to have read it, and the cost of guessing wrong is
# the loop above; the cost of holding is one tick, cleared by the next signal.
t rp-286-same-second-tie-holds "" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_VERDICT")")"
# Absent times hold for the same reason — an unstamped verdict is not evidence
# that the signal came after it. (An engine reading a payload from before the
# query carried submittedAt would see exactly this.)
RP_CR_UNSTAMPED='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":null}]'
t rp-286-unstamped-verdict-holds "rev-b" \
  "$(mk_rp "$H" '[]' "$RP_CR_UNSTAMPED" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
t rp-286-unstamped-signal-holds "rev-b" \
  "$(mk_rp "$H" '[]' "$RP_CR_A_ONLY" '[]' | rp "$(sig "$H" "")")"
# THE COHERENCE GATE (ruled 2026-08-02, danmt). A `📣` posted mid-round is inert
# until the round closes: rev-a blocked and the builder re-signalled, but rev-b
# still owes a first verdict, so the round is still the panel's and rev-a is not
# re-requested under a signal that would blur two rounds into one head.
t rp-286-coherence-holds-mid-round "" \
  "$(mk_rp "$H" '["rev-b"]' "$RP_CR_A_ONLY" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# ...and it is the PANEL's round that holds it open, not any request: an
# off-panel reviewer's outstanding request (triage, a human, an advisory
# reviewer) is not the panel's verdict to wait for. Same scoping as
# addressing.jq's $no_panel_reqs, so the two never disagree about whose ball it
# is.
t rp-286-offpanel-request-does-not-hold-the-round "rev-a" \
  "$(mk_rp "$H" '["dan-claude-bot"]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# The gate is narrow BY DESIGN: it binds verdict-holders only. A panelist who
# owes a first verdict at this head is requested even while another request is
# outstanding — otherwise the first round, where the whole panel is requested at
# once and each request lands beside the others, could never complete. Three
# panelists, because that is the smallest set where the two rules can be told
# apart: rev-a is held by the gate, rev-b holds the round open, rev-c rides
# through untouched.
t rp-286-coherence-spares-first-verdicts "rev-c" \
  "$(mk_rp "$H" '["rev-b"]' "$RP_CR_A_ONLY" '[]' \
    | rp "$(sig "$H" "$RP_T_SIG_ANSWER")" '["rev-a","rev-b","rev-c"]')"
# No reviewer is requested twice at one head under one signal: the engine's own
# request puts them back on the list, and the next tick sees that and holds.
t rp-286-requested-not-requested-again "" \
  "$(mk_rp "$H" '["rev-a"]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# The hold is scoped to CHANGES_REQUESTED, the only state that closes a round
# against the builder. A DISMISSED verdict at the head is a WITHDRAWN opinion:
# round_owed does not count it, addressing.jq calls the round closed and
# converged.jq calls it unapproved, so if this predicate held it too the
# panelist would owe a verdict nobody would ever ask for — the stall this issue
# exists to end, arriving through its own fix. An unknown future state takes the
# same door for the same reason.
RP_DISMISSED='[{"author":{"login":"rev-a"},"state":"DISMISSED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
RP_FUTURE_STATE='[{"author":{"login":"rev-a"},"state":"PONDERED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
t rp-286-dismissed-verdict-is-re-requested "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_DISMISSED" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
t rp-286-unknown-state-is-re-requested "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_FUTURE_STATE" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"

# answered-head.jq — the signal. This is the WIP-safety property: a mid-fix push
# moves the head away from the last signalled one, so the engine holds.
RP_SIG_H='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
RP_SIG_OLD='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"}]'
RP_SIG_TWO='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"},{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-signal-at-head "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_H" | ah_sha)"
t ah-no-signal-empty "" "$(mk_rp "$H" '[]' '[]' '[]' | ah_sha)"
t ah-latest-signal-wins "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO" | ah_sha)"
# The must-fail made concrete: a WIP push after the last signal (signal at OLD,
# head now H) yields a signalled head != current head, so the engine's
# `answered_head = gql_head` gate is false — it does NOT request. No commit
# inference.
t ah-wip-push-stales-signal "$RP_OLD" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OLD" | ah_sha)"
# Another user's MARK_ANSWERED is not my signal.
RP_SIG_OTHER='[{"author":{"login":"someone"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-other-user-signal-ignored "" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OTHER" | ah_sha)"
# #286: the licence carries its TIME, and it is the time of the signal it
# returned — the latest one, not the first. Both halves come out of one program
# so no caller can pair a sha with another signal's clock.
RP_SIG_TWO_TIMED='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'","createdAt":"'$RP_T_SIG_OPEN'"},
                   {"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'","createdAt":"'$RP_T_SIG_ANSWER'"}]'
t ah-carries-the-signal-time "$RP_T_SIG_ANSWER" \
  "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO_TIMED" | ah | jq -r '.createdAt')"
t ah-pairs-sha-with-its-own-time "$H $RP_T_SIG_ANSWER" \
  "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO_TIMED" | ah | jq -r '"\(.sha) \(.createdAt)"')"
# No signal is the empty OBJECT, never null: _request_panel reads .sha off it
# unconditionally, and request-panel.jq reads .createdAt, so the shape has to
# survive the absence.
t ah-no-signal-is-an-empty-object '{"sha":"","createdAt":""}' \
  "$(mk_rp "$H" '[]' '[]' '[]' | ah)"

# Structural gates (#133 test plan, must-fails).
# The engine acts on the signal, not commits: _request_panel gates on
# answered-head == current head before requesting.
# shellcheck disable=SC2016  # the grep literal contains $gql_head on purpose
if grep -q 'answered-head.jq' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'answered_head" != "\$gql_head"' "$SHARED/lib/duty-builder.sh"; then r1=signal-gated; else r1=UNGATED; fi
t engine-request-requires-signal signal-gated "$r1"
# #286: a predicate can only read what the query asks for, and the handoff query
# carried neither timestamp — which is why the ordering bug was invisible to
# every fixture in this file. Pin both fields at the query.
if grep -q 'comments(last:100){nodes{author{login} body createdAt}}' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'latestOpinionatedReviews(first:50){nodes{author{login} state submittedAt commit{oid}}}' \
       "$SHARED/lib/duty-builder.sh"; then r1=timestamped; else r1=UNTIMED; fi
t engine-request-fetches-ordering-evidence timestamped "$r1"
# The licence crosses into jq as ONE object: request-panel.jq is HANDED the
# signal and reads its time, rather than parsing MARK_ANSWERED out of the
# comments a second time. Two parsers would be two copies of the predicate, and
# the copies drift — head-checks.jq's header is the standing warning. Pinned on
# the wire string, not on prose: a second parser needs $mark to find a signal at
# all, so its absence here is the property.
# shellcheck disable=SC2016  # the grep literals contain $signal_json / $mark
if grep -q -- '--argjson signal "\$signal_json"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'signal\.createdAt' "$SHARED/lib/jq/request-panel.jq" \
  && ! grep -q 'mark' "$SHARED/lib/jq/request-panel.jq"; then r1=one-object; else r1=RE-DERIVED; fi
t engine-request-passes-the-whole-signal one-object "$r1"
# And exactly one PROGRAM parses the signal, for the same reason. Not one call
# site: #243's resume scan is a second legitimate consumer, and it deliberately
# reuses this parser rather than keeping its own definition of MARK_ANSWERED —
# fleet comments wrap the SHA in backticks or trail punctuation after the
# marker, and resume must classify the exact bodies the request gate does.
# shellcheck disable=SC2016  # the grep literal contains $mark on purpose
t engine-has-one-signal-parser 1 \
  "$(grep -l 'startswith(\$mark)' "$SHARED"/lib/jq/*.jq | wc -l | tr -d ' ')"
# Every consumer reads the licence as the OBJECT it now is. One `.sha` read per
# call site: a consumer left comparing the raw output to a head would classify
# every PR as unsignalled — resume would re-answer finished rounds forever and
# the request gate would never open (#286).
ah_calls="$(grep -c -- '-f "\$[A-Z_]*DIR[A-Za-z_/]*/jq/answered-head\.jq"' "$SHARED/lib/duty-builder.sh")"
ah_sha_reads="$(grep -c "jq -r '\.sha // \"\"'" "$SHARED/lib/duty-builder.sh")"
if [ "$ah_calls" -gt 0 ] && [ "$ah_calls" -eq "$ah_sha_reads" ]; then
  r1=object-read
else
  r1="MISMATCH($ah_calls/$ah_sha_reads)"
fi
t engine-signal-consumers-read-the-object object-read "$r1"
# Green-head precondition, mechanical half only: request on green|none, hold else.
# shellcheck disable=SC2016  # the shell literal contains $check_state
if grep -q 'green|none)' "$SHARED/lib/duty-builder.sh"; then r1=green-gated; else r1=UNGATED; fi
t engine-request-green-gated green-gated "$r1"
# Drafts excluded: the request rides the my_open list, built non-draft.
# shellcheck disable=SC2016
if grep -q 'select(.isDraft | not)' "$SHARED/lib/duty-builder.sh"; then r1=draft-excluded; else r1=EXPOSED; fi
t engine-request-excludes-drafts draft-excluded "$r1"
# #155: GitHub rejects connection pages above 100 instead of truncating them.
# Pin the live API ceiling across shared/, not only the query that exposed it.
oversized_connections="$(grep -REho '(first|last):[0-9]+' "$SHARED" \
  | awk -F: '$2 > 100 { print }')"
t graphql-connection-pages-live-valid "" "$oversized_connections"
# A GraphQL error can be non-empty stdout with a non-zero status and a null PR.
# The handoff sweep must validate the object before either _request_panel or
# converged.jq sees it; non-empty is not evidence of a successful fetch.
GQL_EXCESSIVE='{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"EXCESSIVE_PAGINATION"}]}'
GQL_LONG_OK="$(mk_rp "$H" '[]' "$REVS_OK" '[]' | jq --arg mark "$RP_MARK $H" '
  .data.repository.pullRequest += {
    mergeable:"MERGEABLE", labels:{nodes:[]},
    comments:{nodes:([range(0;99) | {author:{login:"someone"},body:"thread"}]
      + [{author:{login:"me-bot"},body:$mark}])}
  }')"
payload_usable() {
  jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1 \
    && printf usable || printf unusable
}
t graphql-error-body-is-unusable unusable "$(printf '%s' "$GQL_EXCESSIVE" | payload_usable)"
t graphql-long-thread-payload-is-usable usable "$(printf '%s' "$GQL_LONG_OK" | payload_usable)"
t graphql-long-thread-converges true \
  "$(printf '%s' "$GQL_LONG_OK" | jq -r --argjson panel "$PANEL" \
      --arg needs_human state:needs-human -f "$CJQ")"
if grep -q "jq -e '.data.repository.pullRequest != null'" "$SHARED/lib/duty-builder.sh" \
  && grep -q 'PR state payload unusable; skipping request and handoff' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=EXPOSED
fi
t graphql-error-gates-request-and-handoff gated "$r1"
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
#
# The two programs are wired together here exactly as _request_panel wires them
# — answered-head.jq's object is what request-panel.jq is handed — so this case
# also pins that the licence survives the trip between them (#286).
RP_READY_SIGNALLED="$(mk_rp "$H" '[]' '[]' "$RP_SIG_H")"
t strand-fix-ready-with-signal-requests "rev-a rev-b" \
  "$(printf '%s' "$RP_READY_SIGNALLED" \
    | rp "$(printf '%s' "$RP_READY_SIGNALLED" | ah)")"
t strand-fix-ready-with-signal-has-signal "$H" \
  "$(printf '%s' "$RP_READY_SIGNALLED" | ah_sha)"
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
mk_rl() {  # <body> <reviews-json> <comments-json> [commits-json] [head-oid-json]
  jq -n --arg body "$1" --argjson reviews "$2" --argjson comments "$3" \
    --argjson commits "${4:-[]}" --argjson head "${5:-null}" \
    '{data:{repository:{pullRequest:{
      body:$body, headRefOid:$head, commits:{nodes:$commits},
      reviews:{nodes:$reviews}, comments:{nodes:$comments}}}}}'
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

# #249: GitHub can re-point an existing verdict to a base-merge commit made
# after the verdict. Repair only that impossible key to the newest commit that
# existed when the verdict was submitted.
RL_OLD="6bb9f61000000000000000000000000000000000"
RL_HEAD="bfb1f3a4dc313b370981f75e0034d7c0ec720324"
RL_227_COMMITS="$(printf '[{"commit":{"oid":"%s","committedDate":"2026-01-01T13:39:23Z"}},{"commit":{"oid":"%s","committedDate":"2026-01-01T14:56:52Z"}}]' "$RL_OLD" "$RL_HEAD")"
RL_227_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:46:20Z"},{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:48:02Z"},{"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:54:22Z"}]' "$RL_HEAD" "$RL_HEAD" "$RL_OLD")"
RL_227_FINAL="$(mk_rl "Body." "$RL_227_REVS" '[]' "$RL_227_COMMITS" "\"$RL_HEAD\"" | rl)"
case "$RL_227_FINAL" in *"round:$RL_OLD"*) r1=old ;; *) r1=WRONG ;; esac
t roundlog-repointed-verdicts-use-original-head old "$r1"
case "$RL_227_FINAL" in *"round:$RL_HEAD"*) r1=LEAKED ;; *) r1=one-round ;; esac
t roundlog-repointed-verdicts-form-one-round one-round "$r1"
RL_227_LIVE="$(mk_rl "Body." "$RL_227_REVS" '[]' "$RL_227_COMMITS" "\"$RL_HEAD\"" | rl_live)"
t roundlog-repointed-live-payload-stays-empty "" "$RL_227_LIVE"

# A possible reported key stays put even when a newer commit exists: this is
# not a blanket timestamp-based forward re-key.
RL_STALE_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T16:00:00Z"}]' "$RL_OLD")"
RL_STALE="$(mk_rl "Body." "$RL_STALE_REVS" '[]' "$RL_227_COMMITS" null | rl)"
case "$RL_STALE" in *"round:$RL_OLD"*) r1=kept ;; *) r1=MOVED ;; esac
t roundlog-possible-stale-key-is-preserved kept "$r1"

# If the verdict predates every returned commit, retain and render its reported
# key: truncated or rewritten history is not evidence for a guessed repair.
RL_PRE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RL_PRE_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T12:00:00Z"}]' "$RL_PRE")"
RL_PRE_OUT="$(mk_rl "Body." "$RL_PRE_REVS" '[]' "$RL_227_COMMITS" null | rl)"
case "$RL_PRE_OUT" in *"round:$RL_PRE"*) r1=rendered ;; *) r1=DROPPED ;; esac
t roundlog-prehistory-verdict-keeps-reported-key rendered "$r1"

# The current-head guard is independent of sort position: defer a current head
# even when a later round exists, but finalize it at handoff.
RL_HEAD_FIRST_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"},{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T02:00:00Z"}]' "$RL_O1" "$RL_O2")"
RL_HEAD_FIRST_LIVE="$(mk_rl "Body." "$RL_HEAD_FIRST_REVS" '[]' '[]' "\"$RL_O1\"" | rl_live)"
case "$RL_HEAD_FIRST_LIVE" in *"round:$RL_O1"*) r1=LEAKED ;; *) r1=deferred ;; esac
t roundlog-current-head-deferred-out-of-sort-position deferred "$r1"
RL_HEAD_FIRST_FINAL="$(mk_rl "Body." "$RL_HEAD_FIRST_REVS" '[]' '[]' "\"$RL_O1\"" | rl)"
case "$RL_HEAD_FIRST_FINAL" in *"round:$RL_O1"*) r1=finalized ;; *) r1=MISSING ;; esac
t roundlog-current-head-finalized-at-handoff finalized "$r1"

# The live GraphQL query carries the repair inputs and stays at GitHub's
# connection ceiling.
if grep -q 'headRefOid' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'commits(last:100){nodes{commit{oid committedDate}}}' "$SHARED/lib/duty-builder.sh"; then
  r1=present
else
  r1=MISSING
fi
t roundlog-query-carries-head-and-commits present "$r1"

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

# Build ready lines are committed only when the post-session board proves the
# whole enumerated set was declined. IDs compare as whole keys (#264).
READY3='heavy-duty/crew#2 T2
heavy-duty/crew#25 T25
heavy-duty/crew#30 T30'
t ready-commit-whole-decline "$READY3" \
  "$(_ready_lines_to_commit "$READY3" $'heavy-duty/crew#2\nheavy-duty/crew#25\nheavy-duty/crew#30')"
t ready-commit-one-claimed "" \
  "$(_ready_lines_to_commit "$READY3" $'heavy-duty/crew#2\nheavy-duty/crew#30')"
t ready-commit-none-left "" "$(_ready_lines_to_commit "$READY3" '')"
t ready-commit-empty "" "$(_ready_lines_to_commit '' 'heavy-duty/crew#2')"
t ready-commit-whole-id "" \
  "$(_ready_lines_to_commit 'heavy-duty/crew#2 T2' 'heavy-duty/crew#25')"

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

BUILDER_MOD="$SHARED/lib/duty-builder.sh"
builder_commit_block="$(sed -n '/# Record what this session SAW/,/# --- HANDOFF:/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '_ready_lines_to_commit "$ready_items" "$post_ready_ids"' <<<"$builder_commit_block" &&
   ! grep -Fq '"$ready_items" "$cr_items" | ledger_commit' <<<"$builder_commit_block"; then
  r1=narrowed
else
  r1=WHOLE_SET
fi
t builder-ready-commit-routed-through-helper narrowed "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_commit" "$cr_items" | ledger_commit' <<<"$builder_commit_block"; then
  r1=preserved
else
  r1=DROPPED
fi
t builder-round-items-preserved preserved "$r1"
# The build ledger commit must stay inside this call site's success guard. A
# whole-module grep can accidentally match the independent ci-red guard.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
builder_rc_block="$(sed -n '/^    if \[ "${RUN_SESSION_RC:-1}" -eq 0 \]; then$/,/^    fi$/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_commit" "$cr_items" | ledger_commit' <<<"$builder_rc_block"; then
  r1=gated
else
  r1=UNGATED
fi
t builder-ready-commit-gated-by-session-rc gated "$r1"
# A failed re-query must stay visible and fail open toward another session,
# never burying the whole pre-session ready set (#264 D4).
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if [ "$(grep -Fc 'post-session ready re-query failed; committing no ready lines (#264)' \
     <<<"$builder_commit_block")" -eq 1 ] &&
   ! grep -Fq 'ready_commit="$ready_items"' <<<"$builder_commit_block"; then
  r1=safe
else
  r1=WHOLE_SET
fi
t builder-ready-requery-failure-commits-none safe "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '[ -e "$marker" ] && return 0' "$BUILDER_MOD" &&
   grep -Fq '_repair_seen_build_264' "$BUILDER_MOD"; then
  r1=gated
else
  r1=UNGATED
fi
t builder-ledger-repair-marker-gated gated "$r1"
# The repair is box-wide, so it runs once before duty_builder enters its
# per-repository loop rather than once from _builder_repo (#264 D5).
builder_entry_block="$(sed -n '/^duty_builder() {/,/^_builder_repo() {/p' "$BUILDER_MOD")"
if [ "$(grep -Fc '_repair_seen_build_264' <<<"$builder_entry_block")" -eq 1 ]; then
  r1=once-per-box
else
  r1=PER_REPO
fi
t builder-ledger-repair-call-site once-per-box "$r1"

# The repair clears both state classes once, names #264, and leaves files
# created after its marker untouched on later invocations.
REPAIR_DIR="$TMP/repair-264"
mkdir -p "$REPAIR_DIR"
printf old >"$REPAIR_DIR/.seen-build"
printf old >"$REPAIR_DIR/.suppressed-build.one"
repair_log="$(DUTY_DIR="$REPAIR_DIR" _repair_seen_build_264)"
[ -e "$REPAIR_DIR/.seen-build" ] && r1=kept || r1=deleted
t builder-ledger-repair-seen deleted "$r1"
[ -e "$REPAIR_DIR/.suppressed-build.one" ] && r1=kept || r1=deleted
t builder-ledger-repair-suppressed deleted "$r1"
[ -e "$REPAIR_DIR/.seen-build.repair-264" ] && r1=created || r1=missing
t builder-ledger-repair-marker created "$r1"
case "$repair_log" in *'#264'*) r1=named ;; *) r1=missing ;; esac
t builder-ledger-repair-log-names-issue named "$r1"
printf later >"$REPAIR_DIR/.seen-build"
printf later >"$REPAIR_DIR/.suppressed-build.two"
t builder-ledger-repair-second-log "" "$(DUTY_DIR="$REPAIR_DIR" _repair_seen_build_264)"
t builder-ledger-repair-second-seen later "$(cat "$REPAIR_DIR/.seen-build")"
t builder-ledger-repair-second-suppressed later "$(cat "$REPAIR_DIR/.suppressed-build.two")"

# --- `no build duty` names its cause (#345) --------------------------------
# One spelling for three causes cost the operator an hour on 2026-08-03: the
# line was indistinguishable from #264's burial bug and the answer was the
# boring one (the slot was held). These drive the module's own variables in the
# module's own order — enumerate, ledger-filter, gate, name the cause — because
# the gate WIPES ready_items, so a reason read off anything but the pre-gate
# snapshot collapses every scenario below onto `board empty`.
# Two ledgers, chosen per scenario rather than mutated in place: the ONLY
# difference between the slot-held and the seen-ledger cause is whether the
# board survived the filter, so a single ledger would make the scenarios
# order-dependent and the mutation count below would silently drop.
NBD_LG_COLD="$TMP/ledger-nbd-cold"
NBD_LG_HOT="$TMP/ledger-nbd-hot"
NBD_LG="$NBD_LG_COLD"
nbd() {  # nbd READY_LINES CR_LINES MINE_JSON [BOARD_READ]
  local R=heavy-duty/crew
  local ready_items="$1" cr_items="$2" mine_json="$3" board_read="${4:-1}"
  local ready_board ledgered_rounds ready_count cr_count open_pr_count
  local slot_prs="" open_pr_ids=""
  ready_board="$(printf '%s\n' "$ready_items" | awk 'NF{c++} END{print c+0}')"
  ready_count="$(printf '%s\n' "$ready_items" \
    | ledger_filter "$NBD_LG" | awk 'NF{c++} END{print c+0}')"
  ledgered_rounds="$(printf '%s\n' "$cr_items" | awk 'NF{c++} END{print c+0}')"
  cr_count="$(printf '%s\n' "$cr_items" \
    | ledger_filter "$NBD_LG" | awk 'NF{c++} END{print c+0}')"
  # shellcheck disable=SC2034  # read by _gate_ready_for_open_pr through bash's
  # dynamic scoping, exactly as _builder_repo hands them over.
  open_pr_count="$(printf '%s' "$mine_json" | jq 'length')"
  # shellcheck disable=SC2034  # same: the gate reads this, then writes slot_prs.
  open_pr_ids="$(printf '%s' "$mine_json" \
    | jq -r --arg repo "$R" '[.[].number] | sort | map("\($repo)#\(.)") | join(", ")')"
  _gate_ready_for_open_pr >/dev/null || true
  if [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    printf 'BUILD_DUTY'
    return 0
  fi
  _no_build_duty_reason "$ready_board" "$ledgered_rounds" "$slot_prs" "$board_read"
}
NBD_READY="$(printf 'heavy-duty/crew#2 T2\nheavy-duty/crew#25 T25\nheavy-duty/crew#30 T30')"
NBD_CR="$(printf 'heavy-duty/crew#40 T40')"

# (a) BOARD EMPTY — nothing enumerated on either side.
t nbd-board-empty 'board empty' "$(nbd '' '' '[]')"

# (c) SLOT HELD — a non-empty, unledgered board and an open authored PR. The
# board count is the pre-gate one: the gate has emptied ready_items by the time
# the line is written, and 3 is what the operator sees on the queue.
t nbd-slot-held 'slot held by heavy-duty/crew#231; board holds 3 ready' \
  "$(nbd "$NBD_READY" '' '[{"number":231}]')"
# The count is READ, never hardcoded: a different board gives a different N,
# which is the number #264's discriminating read depends on.
t nbd-slot-count-is-live 'slot held by heavy-duty/crew#231; board holds 1 ready' \
  "$(nbd 'heavy-duty/crew#2 T2' '' '[{"number":231}]')"
# Every PR occupying the slot is named, in numeric order, whatever order the
# listing returned — the line has to be stable across ticks.
t nbd-slot-names-all-prs \
  'slot held by heavy-duty/crew#9, heavy-duty/crew#40; board holds 3 ready' \
  "$(nbd "$NBD_READY" '' '[{"number":40},{"number":9}]')"
# (b) SEEN-LEDGER — enumerated, then hidden whole. N is the pre-filter count.
printf '%s\n%s\n' "$NBD_READY" "$NBD_CR" | ledger_commit "$NBD_LG_HOT"
NBD_LG="$NBD_LG_HOT"
t nbd-seen-ledger-ready '3 ready held by seen-ledger' "$(nbd "$NBD_READY" '' '[]')"
# An open PR does NOT claim the tick when the gate never fired: with the board
# ledgered to zero the ledger is what zeroed it, and the slot is not the news.
t nbd-slot-not-claimed-when-gate-idle '3 ready held by seen-ledger' \
  "$(nbd "$NBD_READY" '' '[{"number":231}]')"
# cr_count runs the SAME filter over a different set, so the noun follows the
# count it came from. An empty board with a ledgered round is not `board empty`.
t nbd-seen-ledger-rounds '1 round(s) held by seen-ledger' "$(nbd '' "$NBD_CR" '[{"number":40}]')"
t nbd-seen-ledger-both '3 ready, 1 round(s) held by seen-ledger' \
  "$(nbd "$NBD_READY" "$NBD_CR" '[{"number":40}]')"
# Fresh work on either side is duty, not a cause — the no-duty branch is never
# reached, so no spelling may claim it.
t nbd-fresh-ready-is-duty BUILD_DUTY "$(nbd 'heavy-duty/crew#77 T77' '' '[]')"
t nbd-fresh-round-is-duty BUILD_DUTY "$(nbd '' 'heavy-duty/crew#78 T78' '[{"number":78}]')"

# (d) BOARD UNREAD — the issue listing failed, so neither of the two above may
# be asserted. Narrower than both; it claims only that nobody read the board.
t nbd-board-unread 'board unread' "$(nbd '' '' '[]' 0)"

# MUTATION — the property that makes this issue worth building. Merge any two
# causes back into one spelling and this count drops below 4. Each scenario
# picks its own ledger, because the ledger IS the discriminator between two of
# them.
NBD_LG="$NBD_LG_COLD"; nbd_slot="$(nbd "$NBD_READY" '' '[{"number":231}]')"
NBD_LG="$NBD_LG_HOT"
NBD_ALL="$(printf '%s\n%s\n%s\n%s\n' \
  "$(nbd '' '' '[]')" \
  "$(nbd "$NBD_READY" '' '[]')" \
  "$nbd_slot" \
  "$(nbd '' '' '[]' 0)" | sort -u | awk 'NF{c++} END{print c+0}')"
t nbd-causes-are-distinct 4 "$NBD_ALL"

# CONSUMERS — the prefix is the contract. `crew status` renders the newest duty
# line as its NOTE through `cut -c1-60`, and the floor's RE_BUILD_DUTY matches
# the POSITIVE line only; a parenthetical must reach neither.
NBD_LINE="$(log "heavy-duty/crew: no build duty ($nbd_slot)")"
case "$NBD_LINE" in
  *'heavy-duty/crew: no build duty (slot held by'*) r1=prefixed ;;
  *) r1="$NBD_LINE" ;;
esac
t nbd-grep-prefix-unchanged prefixed "$r1"
case "$(printf '%s' "$NBD_LINE" | cut -c1-60)" in
  *'no build duty'*) r1=survives ;;
  *) r1=TRUNCATED_AWAY ;;
esac
t nbd-note-column-keeps-prefix survives "$r1"
if printf '%s\n' "$NBD_LINE" \
  | grep -qE ' (\S+): build duty \(ready unclaimed=([0-9]+), whole rounds owed=([0-9]+)\)'; then
  r1=MATCHED_POSITIVE
else
  r1=distinct
fi
t nbd-not-mistaken-for-positive-line distinct "$r1"

# WIRING — the fixtures above prove the spellings; these pin them to the module.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_board_assign="$(grep -F 'ready_board="$(' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
case "$nbd_board_assign" in
  *ledger_filter*)  r1=LEDGERED ;;
  *'"$ready_items"'*) r1=pre-filter ;;
  *)                r1=MISSING ;;
esac
t nbd-board-count-is-pre-ledger pre-filter "$r1"
# ...and taken before the gate empties the set it counts.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_board_ln="$(grep -nF 'ready_board="$(' "$BUILDER_MOD" | head -n1 | cut -d: -f1)"
nbd_gate_ln="$(grep -nF '_gate_ready_for_open_pr || true' "$BUILDER_MOD" | head -n1 | cut -d: -f1)"
if [ -n "$nbd_board_ln" ] && [ -n "$nbd_gate_ln" ] && [ "$nbd_board_ln" -lt "$nbd_gate_ln" ]; then
  r1=before
else
  r1=AFTER_GATE
fi
t nbd-board-count-taken-before-gate before "$r1"
# Why that order is load-bearing, stated as behaviour rather than left to the
# line numbers: fed the post-gate set, the same scenario reports an empty board
# it does not have — the stale count #264's read cannot survive.
t nbd-post-gate-count-would-lie 'slot held by heavy-duty/crew#231; board holds 0 ready' \
  "$(_no_build_duty_reason 0 0 'heavy-duty/crew#231' 1)"
# The line names the cause, and names it from the board facts rather than from
# the survivors, every one of which is zero by then.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_call="$(sed -n '/log "\$R: no build duty (\$(_no_build_duty_reason/,+1p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_board" "$ledgered_rounds" "$slot_prs" "$board_read"' <<<"$nbd_call"; then
  r1=named
else
  r1=BARE
fi
t nbd-call-site-passes-board-facts named "$r1"
# The gate is what knows the slot fired; nothing downstream can re-derive it.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_gate_body="$(sed -n '/^_gate_ready_for_open_pr() {/,/^}/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'slot_prs="${open_pr_ids' <<<"$nbd_gate_body"; then r1=recorded; else r1=SILENT; fi
t nbd-gate-records-that-it-fired recorded "$r1"
# And records it UNCONDITIONALLY: the fallback makes the record independent of
# the id render, so an empty open_pr_ids cannot make the line blame the ledger
# for what the slot did. Text here, behaviour in claim.test.sh, which drives the
# production gate with an empty render (gate-record-survives-empty-ids).
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'slot_prs="${open_pr_ids:-' <<<"$nbd_gate_body"; then r1=always; else r1=CONDITIONAL; fi
t nbd-gate-record-is-unconditional always "$r1"
# One listing, several derived facts (the comment at the top of the block). A
# second ready listing would let the board count disagree with the set it
# describes. Two are expected and neither is new: the pre-session enumeration
# and #264's post-session re-query.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_ready_listings="$(grep -Fc 'gh issue list -R "$R" --state open --label "$LABEL_READY"' "$BUILDER_MOD")"
t nbd-no-second-ready-listing 2 "$nbd_ready_listings"
# Spec decision 3: a single-cause line stays exactly as it was, and no new log
# lines are added. Only the build kind has three causes to tell apart.
for nbd_kind in resume ci-red handoff rebase; do
  # shellcheck disable=SC2016  # Match literal shell source, not test variables.
  if grep -Fq "log \"\$R: no $nbd_kind duty\"" "$BUILDER_MOD"; then r1=plain; else r1=CHANGED; fi
  t "nbd-other-kind-untouched-$nbd_kind" plain "$r1"
done
# Must-not-change: the positive line and the board-anomaly NOTE.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'log "$R: build duty (ready unclaimed=$ready_count, whole rounds owed=$cr_count)"' \
     "$BUILDER_MOD"; then r1=intact; else r1=CHANGED; fi
t nbd-positive-line-intact intact "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'ready issue(s) WITH an assignee (board anomaly; hygiene'"'"'s to fix)' \
     "$BUILDER_MOD"; then r1=intact; else r1=CHANGED; fi
t nbd-anomaly-note-intact intact "$r1"

# --- the triage board poll follows the mention session (#253) ---------------
# _triage_repo used to compute all four board signals, THEN run the mention
# session (ceiling TIMEOUT_MENTION=1500), THEN decide on the values it had
# computed up to 25 minutes earlier — so a lead that died during the session
# still spent a full triage session, and a signal born during it waited a
# whole tick. These drive the real module under a stateful `gh` shim whose
# answers change when the mention session runs, in the shape _handoff_finalize
# is tested in above.
TRD="$TMP/tr-duty"; TRS="$TMP/tr-shim"; TRF="$TMP/tr-fix"
mkdir -p "$TRD/lib/jq" "$TRD/work" "$TRD/conf" "$TRS" "$TRF"
cp "$SHARED/lib/jq/blockers.jq" "$TRD/lib/jq/"
cp -r "$SHARED/prompts" "$TRD/prompts"
# The label vocabulary comes from the SHIPPED conf, not from assignments in
# this file (#358). The runner calls load_fleet_conf against this copy, so a
# queue label the engine's config does not define is a label these fixtures
# cannot silently supply on its behalf.
cp "$SHARED/conf/fleet.defaults.conf" "$TRD/conf/"
TR_CALLS="$TMP/tr-calls.log"; TR_PHASE="$TMP/tr-phase"
TR_LOG="$TMP/tr-log.txt"; TR_PROMPT="$TMP/tr-prompt"

# Phase 1 is the board before the mention session, phase 2 the board after it;
# the runner's run_session override flips the phase file. Every invocation is
# recorded, so the call log doubles as the "no extra reads" guard.
cat >"$TRS/gh" <<'TRGH'
#!/usr/bin/env bash
set -eu
# One line per invocation — the GraphQL query argument is multi-line, and the
# call log is counted, not just grepped.
printf '%s\n' "${*//$'\n'/ }" >>"$TR_CALLS"
p=1; [ -f "$TR_PHASE" ] && p="$(cat "$TR_PHASE")"
case "$*" in
  *"api notifications"*)    cat "$TR_FIX/notif.json" ;;
  *"api graphql"*)          cat "$TR_FIX/disc.$p.rows" ;;  # --jq is already applied
  *"--label needs-triage"*) cat "$TR_FIX/nt.$p.json" ;;
  *"--label blocked"*)      cat "$TR_FIX/blocked.$p.json" ;;
  *"--state all"*)          cat "$TR_FIX/numstates.json" ;;
  *"number,body,labels,updatedAt"*) cat "$TR_FIX/board.$p.json" ;;
  *"issue list"*)           cat "$TR_FIX/stray.$p.json" ;;
  *)                        printf '[]\n' ;;
esac
exit 0
TRGH
chmod +x "$TRS/gh"

cat >"$TMP/tr-run.sh" <<'TRRUN'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/duty-triage.sh"
load_fleet_conf
run_session() {
  printf 'SESSION %s\n' "$1" >>"$TR_CALLS"
  printf '%s' "$5" >"$TR_PROMPT.$1"
  # Phase 2 is the server state after either kind of session returns. The
  # production success path must re-read this state rather than committing
  # the phase-1 rows that launched it (#359).
  printf '2' >"$TR_PHASE"
  RUN_SESSION_RC="${TR_SESSION_RC:-0}"
}
ensure_checkout() { return 0; }
_triage_repo o/r
TRRUN

# Stray and discussion arguments are optional and default to an empty board,
# so calls written before their fixtures keep their meaning.
tr_fix() {  # notif nt1 nt2 blocked1 blocked2 numstates [stray1] [stray2] [disc1] [disc2]
  local p nt_file blocked_file stray_file
  printf '%s' "$1" >"$TRF/notif.json"
  printf '%s' "$2" >"$TRF/nt.1.json";      printf '%s' "$3" >"$TRF/nt.2.json"
  printf '%s' "$4" >"$TRF/blocked.1.json"; printf '%s' "$5" >"$TRF/blocked.2.json"
  printf '%s' "$6" >"$TRF/numstates.json"
  printf '%s' "${7:-[]}" >"$TRF/stray.1.json"
  printf '%s' "${8:-${7:-[]}}" >"$TRF/stray.2.json"
  printf '%s' "${9:-}" >"$TRF/disc.1.rows"
  printf '%s' "${10:-${9:-}}" >"$TRF/disc.2.rows"
  for p in 1 2; do
    nt_file="$TRF/nt.$p.json"
    blocked_file="$TRF/blocked.$p.json"
    stray_file="$TRF/stray.$p.json"
    jq -s '
      (.[0] | map(. + {body:(.body // null), labels:[{name:"needs-triage"}]}))
      + (.[1] | map(. + {updatedAt:(.updatedAt // "2026-08-01T00:00:00Z"),
                         labels:[{name:"blocked"}]}))
      + (.[2] | map(. + {body:(.body // null)}))
    ' "$nt_file" "$blocked_file" "$stray_file" >"$TRF/board.$p.json"
  done
}
tr_tick() {  # tr_tick <run_session rc>, preserving ledgers from earlier ticks
  : >"$TR_CALLS"
  rm -f "$TR_PHASE" "$TR_PROMPT".*
  SHARED_DIR="$SHARED" TR_CALLS="$TR_CALLS" TR_PHASE="$TR_PHASE" TR_FIX="$TRF" \
  TR_PROMPT="$TR_PROMPT" TR_SESSION_RC="$1" DUTY_DIR="$TRD" ME=me-bot \
  TIMEOUT_MENTION=1 TIMEOUT_TRIAGE=1 \
  PATH="$TRS:$PATH" bash "$TMP/tr-run.sh" >"$TR_LOG" 2>&1
}
tr_run() {  # tr_run <run_session rc>, starting with cold ledgers
  rm -f "$TRD"/.seen-* "$TRD"/.suppressed-*
  tr_tick "$1"
}
trc() { grep -c -- "$1" "$TR_CALLS"; }
TR_MENTION='[{"id":"t1","reason":"mention","updated_at":"2026-08-01T15:40:00Z",
  "repository":{"full_name":"o/r"},"subject":{"url":"https://api/x"}}]'
TR_LEAD='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-01T15:30:00Z"}]'
TR_LANDED='[{"number":216,"state":"CLOSED"}]'

# The reported case: the sweep clears #244 forty-four seconds after the poll,
# and the session that would have been launched on it starts nineteen minutes
# later. Polled after the mention session, the lead is simply gone.
tr_fix "$TR_MENTION" '[]' '[]' "$TR_LEAD" '[]' "$TR_LANDED"
tr_run 0
t triage253-dead-lead-spends-no-triage-session 0 "$(trc '^SESSION triage$')"
t triage253-dead-lead-still-runs-the-mention 1 "$(trc '^SESSION mention$')"
if grep -q 'no triage signals — mention session was the only wake' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-dead-lead-logs-mention-only said "$r1"
# Asserted on the prompt text, not only the session count: the two differ the
# moment another signal is live.
if [ -f "$TR_PROMPT.triage" ] && grep -q '244' "$TR_PROMPT.triage"; then
  r1=STALE_LEAD; else r1=none; fi
t triage253-dead-lead-not-in-prompt none "$r1"

# The positive control that keeps the assertion above from being vacuous: a
# lead that is STILL live after the mention session reaches the prompt.
tr_fix "$TR_MENTION" '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-live-lead-launches-triage 1 "$(trc '^SESSION triage$')"
if grep -q 'unblockable' "$TR_PROMPT.triage" && grep -q '244' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage253-live-lead-named-in-prompt named "$r1"

# The inverse: a signal BORN during the mention session is seen by the same
# tick instead of waiting for the next one.
tr_fix "$TR_MENTION" '[]' '[{"number":999,"updatedAt":"2026-08-01T15:50:00Z"}]' \
  '[]' '[]' '[]'
tr_run 0
t triage253-newborn-signal-wakes-same-tick 1 "$(trc '^SESSION triage$')"
if grep -q '1x needs-triage' "$TR_LOG"; then r1=named; else r1="$(cat "$TR_LOG")"; fi
t triage253-newborn-signal-in-log named "$r1"
if grep -q 'o/r#999' "$TRD/.seen-triage-board"; then r1=ledgered; else r1=MISSING; fi
t triage253-newborn-signal-ledgered ledgered "$r1"

# Before any triage session launches, each signal is still polled exactly once.
# A successful session deliberately adds the #359 exit-state reads; a quiet
# tick adds none. These counts distinguish that bounded re-read from polling
# twice before the launch decision.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-reads-notifications-once 1 "$(trc 'api notifications')"
t triage253-reads-needs-triage-once   1 "$(trc '--label needs-triage')"
t triage253-reads-strays-once         1 "$(trc 'number,labels,updatedAt')"
t triage253-reads-discussions-once    1 "$(trc 'api graphql')"
t triage253-reads-blocked-once        1 "$(trc '--label blocked')"
t triage253-gh-calls-with-mention     5 "$(grep -vc '^SESSION' "$TR_CALLS")"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-gh-calls-without-mention  5 "$(grep -vc '^SESSION' "$TR_CALLS")"
t triage253-quiet-tick-spends-nothing 0 "$(trc '^SESSION')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-quiet-tick-log-unchanged said "$r1"
# The state-map reads still ride the non-empty blocked list, and nothing else.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-gh-calls-with-blocked-list 11 "$(grep -vc '^SESSION' "$TR_CALLS")"

# The mention path itself is untouched — the regression that matters, since
# this change moves code around that block. One session, kind mention, and the
# ledger committed only on rc 0.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-mention-only-one-session 1 "$(trc '^SESSION')"
t triage253-mention-only-kind        1 "$(trc '^SESSION mention$')"
if grep -q '^t1 ' "$TRD/.seen-mentions"; then r1=committed; else r1=MISSING; fi
t triage253-mention-ledger-on-rc0 committed "$r1"
tr_run 1
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage253-mention-ledger-not-on-rcfail withheld "$r1"

# Static ordering, in the style of the module-wiring checks above: every board
# read must sit BELOW the mention call site, and the launch decision below all
# of them. Cheap, and it fails loudly if a later edit hoists a poll back up.
TRIAGE_MOD="$SHARED/lib/duty-triage.sh"
tr_ln() { grep -Fn -- "$1" "$TRIAGE_MOD" | head -1 | cut -d: -f1; }
tr_mention_ln="$(tr_ln 'run_session mention')"
# shellcheck disable=SC2016  # matching the module's literal source text
tr_decide_ln="$(tr_ln '[ -z "$signals" ]')"
# shellcheck disable=SC2016  # ditto
for probe in '--label "$LABEL_NEEDS_TRIAGE"' 'number,labels,updatedAt' \
             '_triage_discussion_items "$R"' '--label "$LABEL_BLOCKED"'; do
  probe_ln="$(tr_ln "$probe")"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -gt "$tr_mention_ln" ]; then
    r1=after; else r1="BEFORE($probe_ln vs $tr_mention_ln)"; fi
  t "triage253-poll-after-mention:$probe" after "$r1"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -lt "$tr_decide_ln" ]; then
    r1=before; else r1="AFTER($probe_ln vs $tr_decide_ln)"; fi
  t "triage253-poll-before-decision:$probe" before "$r1"
done

# --- #359: successful triage sessions settle ledgers at their exit state ---
TR359_T1='2026-08-05T10:00:00Z'
TR359_T2='2026-08-05T10:05:00Z'
TR359_T3='2026-08-05T10:10:00Z'
tr359_nt() { jq -nc --arg s "$1" '[{number:116,updatedAt:$s}]'; }

# A session comments on an item and leaves it needs-triage. The post-session
# timestamp, not the launching timestamp, is committed; the following tick is
# therefore quiet even though the item remains in the query.
tr_fix '[]' "$(tr359_nt "$TR359_T1")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_run 0
t triage359-self-write-first-tick-launches 1 "$(trc '^SESSION triage$')"
if grep -q "o/r#116 $TR359_T2" "$TRD/.seen-triage-board"; then r1=post; else r1=STALE; fi
t triage359-self-write-commits-post-session post "$r1"
tr_fix '[]' "$(tr359_nt "$TR359_T2")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_tick 0
t triage359-self-write-next-tick-quiet 0 "$(trc '^SESSION triage$')"

# Genuine activity after that session advances the board beyond the committed
# value and buys one new session. This is the side the safe re-read must retain.
tr_fix '[]' "$(tr359_nt "$TR359_T3")" "$(tr359_nt "$TR359_T3")" '[]' '[]' '[]'
tr_tick 0
t triage359-third-party-later-write-rewakes 1 "$(trc '^SESSION triage$')"

# Discussion rows use the same exit-state contract, with their own ledger.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#8 $TR359_T1" "o/r#8 $TR359_T2"
tr_run 0
if grep -q "o/r#8 $TR359_T2" "$TRD/.seen-discussions"; then r1=post; else r1=STALE; fi
t triage359-discussion-commits-post-session post "$r1"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#8 $TR359_T2" "o/r#8 $TR359_T2"
tr_tick 0
t triage359-discussion-next-tick-quiet 0 "$(trc '^SESSION triage$')"

# A failed session commits none of the three ledgers. Crash-only retry remains
# the distinction between "declined" and "never got there".
tr_fix '[]' "$(tr359_nt "$TR359_T1")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_run 1
if [ -f "$TRD/.seen-triage-board" ]; then r1=COMMITTED; else r1=withheld; fi
t triage359-failed-session-commits-no-board withheld "$r1"

# A standing unblockable lead costs one session. Its exit timestamp settles
# the dedicated ledger; subsequent ticks report the stable lead once without
# launching, and report_suppressed then quiets the unchanged warning.
TR359_BLOCK_1='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-05T11:00:00Z"}]'
TR359_BLOCK_2='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-05T11:05:00Z"}]'
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_1" "$TR359_BLOCK_2" "$TR_LANDED"
tr_run 1
if [ -f "$TRD/.seen-unblockable" ]; then r1=COMMITTED; else r1=withheld; fi
t triage359-failed-session-commits-no-unblockable withheld "$r1"
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_1" "$TR359_BLOCK_2" "$TR_LANDED"
tr_run 0
t triage359-unblockable-first-tick-launches 1 "$(trc '^SESSION triage$')"
if grep -q 'o/r#244 2026-08-05T11:05:00Z' "$TRD/.seen-unblockable"; then r1=post; else r1=MISSING; fi
t triage359-unblockable-commits-post-session post "$r1"
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_2" "$TR359_BLOCK_2" "$TR_LANDED"
tr_tick 0
t triage359-unblockable-next-tick-spends-no-session 0 "$(trc '^SESSION triage$')"
if grep -q 'o/r: unblockable: 1 item(s)' "$TR_LOG"; then r1=warned; else r1=SILENT; fi
t triage359-unblockable-suppression-reported warned "$r1"
tr_tick 0
if grep -q 'o/r: unblockable: 1 item(s)' "$TR_LOG"; then r1=REPEATED; else r1=quiet; fi
t triage359-unblockable-stable-warning-once quiet "$r1"

# --- #358: post-merge is a queue label, and the engine's set is LABELS.md's -
# LABELS.md declares a SIX-label board invariant; fleet.defaults.conf defined
# five and signal (b) selected on those five. So the moment triage did its job
# — a Refs-linked PR merges, the issue moves claimed -> post-merge — it turned
# that issue into a permanent violation of the engine's own invariant, one no
# session could ever clear because post-merge is the correct terminal state.
# All four live matches on this board were that false positive.
#
# Both directions are driven through the real module and the same shim: the
# select is proven by what it selects, never by reading it. The label values
# reach the module from the SHIPPED conf (see the TRD/conf copy above), so a
# label the engine's config does not define cannot pass here.
TR358_STAMP='2026-08-05T00:00:00Z'
tr358_board() {  # tr358_board <label|-> ... — one open issue per argument
  printf '%s\n' "$@" | jq -R . | jq -cs --arg s "$TR358_STAMP" \
    'to_entries | map({number: (100 + .key),
                       labels: (if .value == "-" then [] else [{name: .value}] end),
                       updatedAt: $s})'
}

# Direction one — an issue whose only queue label is post-merge is not a stray.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board post-merge)"
tr_run 0
t triage358-post-merge-spends-no-session 0 "$(trc '^SESSION')"
if grep -q 'queue-unlabeled' "$TR_LOG"; then r1="$(cat "$TR_LOG")"; else r1=silent; fi
t triage358-post-merge-raises-no-signal silent "$r1"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=quiet; else r1="$(cat "$TR_LOG")"; fi
t triage358-post-merge-tick-is-quiet quiet "$r1"
# The fixture analogue of this issue's post-merge criterion: the suppression
# report must not name it either. A signal that is merely ledgered still WARNs
# every tick, which is the cost this issue is about.
if cat "$TRD"/.suppressed-triage-board.* 2>/dev/null | grep -q 'o/r#100'; then
  r1=NAMED; else r1=absent; fi
t triage358-post-merge-not-in-suppressed absent "$r1"

# Direction two — an issue carrying none of the six still is one. The detector
# is narrowed to the truth, not silenced; a select widened until it is quiet is
# the failure mode this half exists to prevent.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board -)"
tr_run 0
t triage358-unlabeled-still-a-stray 1 "$(trc '^SESSION triage$')"
if grep -q '1x queue-unlabeled' "$TR_LOG"; then r1=named; else r1="$(cat "$TR_LOG")"; fi
t triage358-unlabeled-signal-named named "$r1"
# ...and a label outside the queue vocabulary does not stand in for one.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board bug)"
tr_run 0
t triage358-non-queue-label-still-a-stray 1 "$(trc '^SESSION triage$')"

# The doctrine's own sentence, parsed rather than restated: from its opening
# clause to the end of that sentence, which is the first backtick-then-period
# — the full stop closing the last backticked label.
tr358_doctrine="$(awk '
  /invariant a board scan relies on/ { on = 1 }
  on { printf "%s ", $0 }
  on && /`\./ { exit }
' "$ROOT/.ceremony/LABELS.md")"
tr358_doctrine="${tr358_doctrine%%\`.*}\`"
# shellcheck disable=SC2016  # a grep pattern: the backticks are LABELS.md's
tr358_doctrine_set="$(printf '%s' "$tr358_doctrine" | grep -o '`[a-z][a-z-]*`' \
  | tr -d '`' | sort -u | tr '\n' ' ')"
# Anti-vacuity guard, and the only place a count is written down: without it a
# parse that silently stops matching compares an empty set to an empty set and
# passes. It asserts cardinality, never membership — the comparison below is
# what asserts which labels, and it is derived on both sides.
t triage358-doctrine-set-nonvacuous 6 "$(printf '%s' "$tr358_doctrine_set" | wc -w | tr -d ' ')"

# The engine's set, taken from signal (b)'s own --arg list and resolved through
# the shipped conf. A label added to LABELS.md and not to the engine fails
# here, and so does one added to the engine and not to LABELS.md.
tr358_select="$(awk '/elif ! stray_items=/,/stray parse failed/' "$SHARED/lib/duty-triage.sh")"
# shellcheck disable=SC2016  # a grep pattern: the $LABEL_ is the module's text
tr358_pairs="$(printf '%s\n' "$tr358_select" \
  | grep -o -- '--arg [a-z_]* "\$LABEL_[A-Z_]*"' \
  | sed 's/--arg \([a-z_]*\) "\$\(LABEL_[A-Z_]*\)"/\1 \2/')"
tr358_engine_set=""
while read -r tr358_arg tr358_var; do
  [ -n "${tr358_arg:-}" ] || continue
  # Declared is not consulted: an --arg the select never tests is a label the
  # engine does not actually accept, so it is reported rather than counted.
  case "$tr358_select" in
    *". == \$$tr358_arg"*) ;;
    *) tr358_engine_set="$tr358_engine_set UNCONSULTED-$tr358_arg"; continue ;;
  esac
  tr358_engine_set="$tr358_engine_set $(sed -n "s/^$tr358_var=\"\(.*\)\"\$/\1/p" \
    "$SHARED/conf/fleet.defaults.conf" | head -1)"
done <<TR358PAIRS
$tr358_pairs
TR358PAIRS
# shellcheck disable=SC2086  # deliberate word-splitting: these are set members
tr358_engine_set="$(printf '%s\n' $tr358_engine_set | sort -u | tr '\n' ' ')"
t triage358-engine-set-is-the-doctrine-set "$tr358_doctrine_set" "$tr358_engine_set"
# Named separately so the conf's own omission — the whole defect — reads as
# itself rather than as a set diff.
if grep -q '^LABEL_POST_MERGE="post-merge"$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=defined; else r1=MISSING; fi
t triage358-conf-defines-post-merge defined "$r1"

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
ATT_MOD="$SHARED/lib/duty-attention.sh"
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

# --- malformed attention audit (#303) --------------------------------------
ATT_AUDIT_ROWS="$(printf 'heavy-duty/crew 285 issue 1\nheavy-duty/crew 310 issue 0\nheavy-duty/crew 293 pr 0\nheavy-duty/crew 294 pr 1\n')"
t attention-audit-classifies-all-shapes "OK heavy-duty/crew 285 issue 1
UNASSIGNED heavy-duty/crew 310 issue 0
PR heavy-duty/crew 293 pr 0
PR heavy-duty/crew 294 pr 1" \
  "$(printf '%s\n' "$ATT_AUDIT_ROWS" | _attention_audit_classify)"
t attention-audit-empty-input-is-empty "" \
  "$(printf '' | _attention_audit_classify)"

ATT_AUDIT="$TMP/attention-audit"
mkdir -p "$ATT_AUDIT"
# shellcheck disable=SC2034,SC2317  # variables/functions consumed by the sourced audit
attention_audit_case() { # attention_audit_case <rows> [failed-repo] [registry]
  local supplied="$1" failed="${2:-}" registry="${3:-heavy-duty/crew}" rc
  : >"$ATT_AUDIT/gh-calls"
  (
    DUTY_DIR="$ATT_AUDIT"
    REPOS_FILE="$ATT_AUDIT/repos.txt"
    LABEL_ATTENTION=attention
    read_repo_list() { printf '%s\n' "$registry"; }
    gh() {
      printf 'GH %s\n' "$*" >>"$ATT_AUDIT/gh-calls"
      case "$*" in *"/repos/$failed/issues?"*) return 1 ;; esac
      printf '%s\n' "$supplied"
    }
    warn() { printf 'WARN %s\n' "$*"; }
    alert() { printf 'ALERT %s\n' "$*"; }
    duty_attention_audit
    rc=$?
    printf 'RC %s\n' "$rc"
  )
}

# A valid board is silent apart from its single bounded read.
rm -f "$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_OK="$(attention_audit_case 'heavy-duty/crew 285 issue 1')"
t attention-audit-valid-board-has-no-warning 0 \
  "$(printf '%s\n' "$ATT_AUDIT_OK" | grep -c '^WARN ' || true)"
t attention-audit-valid-board-has-no-alert 0 \
  "$(printf '%s\n' "$ATT_AUDIT_OK" | grep -c '^ALERT ' || true)"
t attention-audit-one-read-per-registry-repo 1 \
  "$(grep -c '^GH api /repos/heavy-duty/crew/issues?' "$ATT_AUDIT/gh-calls" || true)"

# A fetch failure is evidence, not a failed tick, and leaves report state
# untouched so a partial registry sweep cannot falsely announce a repair.
printf 'heavy-duty/crew#293 PR\n' >"$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_FAIL="$(attention_audit_case '' heavy-duty/crew "$(printf 'heavy-duty/crew\nother/repo\n')")"
t attention-audit-fetch-failure-warns 1 \
  "$(printf '%s\n' "$ATT_AUDIT_FAIL" | grep -c '^WARN ' || true)"
t attention-audit-fetch-failure-returns-zero 'RC 0' \
  "$(printf '%s\n' "$ATT_AUDIT_FAIL" | tail -1)"
t attention-audit-fetch-failure-keeps-state 'heavy-duty/crew#293 PR' \
  "$(cat "$ATT_AUDIT/.attention-malformed")"
t attention-audit-fetch-failure-still-reads-later-repos 2 \
  "$(grep -c '^GH api /repos/' "$ATT_AUDIT/gh-calls" || true)"

# report_suppressed makes a stable malformed set speak once, then re-arms
# when the set changes. The operator alert follows exactly the same cadence.
rm -f "$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_TWO="$(attention_audit_case "$(printf 'heavy-duty/crew 293 pr 0\nheavy-duty/crew 310 issue 0\n')")"
ATT_AUDIT_SAME="$(attention_audit_case "$(printf 'heavy-duty/crew 293 pr 0\nheavy-duty/crew 310 issue 0\n')")"
ATT_AUDIT_ONE="$(attention_audit_case 'heavy-duty/crew 293 pr 0')"
t attention-audit-first-set-reports 1 \
  "$(printf '%s\n' "$ATT_AUDIT_TWO" | grep -c '^WARN ' || true)"
t attention-audit-first-set-alerts 1 \
  "$(printf '%s\n' "$ATT_AUDIT_TWO" | grep -c '^ALERT ' || true)"
t attention-audit-unchanged-set-is-silent 0 \
  "$(printf '%s\n' "$ATT_AUDIT_SAME" | grep -Ec '^(WARN|ALERT) ' || true)"
t attention-audit-shrunk-set-reports 1 \
  "$(printf '%s\n' "$ATT_AUDIT_ONE" | grep -c '^WARN ' || true)"
t attention-audit-shrunk-set-alerts 1 \
  "$(printf '%s\n' "$ATT_AUDIT_ONE" | grep -c '^ALERT ' || true)"

# Pin the wiring and the negative contract: one call, inside both the triage
# role and interval guards, before hygiene; no board write or model launch.
DUTYSH="$SHARED/bin/duty.sh"
AUDIT_BLOCK="$(awk '/if has_role triage; then/{b=$0 ORS; next} b!=""{b=b $0 ORS} /duty_hygiene &&/{print b; exit}' "$DUTYSH")"
if printf '%s\n' "$AUDIT_BLOCK" | grep -q 'HYGIENE_INTERVAL' &&
   printf '%s\n' "$AUDIT_BLOCK" | grep -q 'duty_attention_audit' &&
   printf '%s\n' "$AUDIT_BLOCK" | grep -q 'duty_hygiene'; then r1=gated; else r1=UNGATED; fi
t attention-audit-is-triage-hygiene-gated gated "$r1"
t attention-audit-has-one-call-site 1 \
  "$(grep -c '^[[:space:]]*duty_attention_audit$' "$DUTYSH")"
AUDIT_SOURCE="$(awk '/^duty_attention_audit\(\)/,/^}/' "$ATT_MOD")"
if printf '%s\n' "$AUDIT_SOURCE" | grep -Eq 'gh api -X|--method|gh issue edit|run_session'; then
  r1=WRITES
else
  r1=read-only
fi
t attention-audit-is-read-only read-only "$r1"
# shellcheck disable=SC2016  # matching the literal query, not expanding it
if grep -Fq '/issues?filter=assigned&state=open&labels=$LABEL_ATTENTION&per_page=100' "$ATT_MOD"; then
  r1=unchanged
else
  r1=CHANGED
fi
t attention-wake-query-unchanged unchanged "$r1"
# shellcheck disable=SC2016  # matching the prompt's literal Markdown
if grep -Fq 'put `attention` on the assigned issue that owns the claim — never on a pull request or an unassigned issue' \
     "$SHARED/prompts/triage.txt"; then r1=named; else r1=MISSING; fi
t triage-prompt-names-attention-target named "$r1"

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

# --- builder attention dispatch and timeout evidence (#301) -----------------
# A builder pickup may finish an existing PR in this slot, but must hand a new
# build to the normal duty tick. Pin the ruling in both render layers so a
# route/prompt drift cannot silently restore the half-budget build lifecycle.
if grep -q 'test whether it already has an open PR' "$ATT_MOD" &&
   ! grep -q 'IS build work: do it now' "$ATT_MOD"; then r1=dispatched; else r1=BUILDING; fi
t attention-builder-route-dispatches-new-build dispatched "$r1"
if grep -q 'For a builder claim with no open PR, your output is board state, never code' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'when one exists, keep the issue claimed and assigned' "$ATT_MOD" &&
   grep -q 'A pushed branch keeps the issue claimed and assigned for ORPHANS resume' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'If a directed hold remains, keep the issue claimed and assigned' "$ATT_MOD" &&
   grep -q 'a standing hold keeps it claimed and assigned with its park re-stated' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'Only when no build branch exists and no hold remains' "$ATT_MOD" &&
   grep -q 'Only genuinely unstarted work with no remaining hold is unassigned' \
     "$SHARED/prompts/attention.txt"; then
  r1=dispatched
else
  r1=MISSING
fi
t attention-prompt-dispatches-new-build dispatched "$r1"
# Production run_session, not only the behavior stub below, must expose the
# immutable log path consumed by the timeout evidence branch.
# shellcheck disable=SC2016  # literal source assignment, not test expansion
if grep -q 'RUN_SESSION_LOG="\$slog"' "$SHARED/lib/common.sh"; then
  r1=exposed
else
  r1=MISSING
fi
t attention-run-session-exposes-log exposed "$r1"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
if grep -q 'fragment-round-rules.txt.*MARK_ANSWERED="\$MARK_ANSWERED"' "$ATT_MOD"; then
  r1=whole
else
  r1=BROKEN
fi
t attention-builder-round-rules-still-whole whole "$r1"
if grep -q '^TIMEOUT_ATTENTION=1800$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=1800
else
  r1=CHANGED
fi
t attention-timeout-budget-unchanged 1800 "$r1"
# duty_attention and duty_builder are separate sessions in one normal tick;
# builder follows attention and launches through the full build budget.
attention_ln="$(grep -n '^duty_attention$' "$SHARED/bin/duty.sh" | cut -d: -f1)"
builder_ln="$(grep -n '^  duty_builder$' "$SHARED/bin/duty.sh" | cut -d: -f1)"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
if [ "$attention_ln" -lt "$builder_ln" ] &&
   grep -A2 'run_session build ' "$SHARED/lib/duty-builder.sh" | grep -q '"\$TIMEOUT_BUILD"'; then
  r1=full-budget
else
  r1=BROKEN
fi
t attention-dispatch-reaches-normal-build-session full-budget "$r1"

# Drive the actual wake with a stubbed run_session. The output log records only
# externally visible effects: COMMENT, ALERT and LEDGER. This distinguishes all
# three outcomes and proves the timeout branch does not settle the seen ledger.
ATT_BEHAVIOR="$TMP/attention-behavior"
mkdir -p "$ATT_BEHAVIOR/bin" "$ATT_BEHAVIOR/work"
cat >"$ATT_BEHAVIOR/bin/post-once.sh" <<'ATTPO'
#!/usr/bin/env bash
printf 'COMMENT %s#%s %s\n' "$1" "$2" "$3" >>"$ATT_CALLS"
ATTPO
chmod +x "$ATT_BEHAVIOR/bin/post-once.sh"
attention_case() { # attention_case <run_session rc> <tag>
  local case_rc="$1" tag="${2:-one}" calls
  calls="$ATT_BEHAVIOR/calls-$case_rc-$tag"
  : >"$calls"
  ATT_CASE_RC="$case_rc" ATT_CASE_TAG="$tag" ATT_CALLS="$calls" \
    bash -s -- "$SHARED" "$ATT_BEHAVIOR" <<'ATTCASE'
set -u
SHARED="$1"; ATT_BEHAVIOR="$2"
export ATT_CALLS
LABEL_ATTENTION=attention
REPOS_FILE="$ATT_BEHAVIOR/repos.txt"
DUTY_DIR="$ATT_BEHAVIOR/duty"
WORK_DIR="$ATT_BEHAVIOR/work"
TREES_DIR="$ATT_BEHAVIOR/trees"
BIN_DIR="$ATT_BEHAVIOR/bin"
ME=builder
TIMEOUT_ATTENTION=1800
DOCTRINE_TRIAGE=TRIAGE.md
DOCTRINE_ENTRYPOINT=AGENTS.md
DOCTRINE_BUILDER=BUILDER.md
DOCTRINE_REVIEWER=REVIEWER.md
FLEET_TRIAGE=triage
FLEET_BENCH=bench
MARK_ADDRESSING=addressing
MARK_ANSWERED=answered
MARK_PICKUP=pickup
mkdir -p "$DUTY_DIR"
gh() { printf 'GH %s\n' "$*" >>"$ATT_CALLS"; printf 'o/r 9 T1\n'; }
read_repo_list() { printf 'o/r\n'; }
report_suppressed() { cat >/dev/null; }
ledger_filter() { cat; }
ledger_suppressed() { cat >/dev/null; }
ledger_commit() { cat >/dev/null; printf 'LEDGER\n' >>"$ATT_CALLS"; }
has_role() { [ "$1" = builder ]; }
ensure_main_clone() { mkdir -p "$2"; }
render_prompt() { printf 'prompt'; }
run_session() {
  RUN_SESSION_RC="$ATT_CASE_RC"
  mkdir -p "$ATT_BEHAVIOR/logs"
  RUN_SESSION_LOG="$ATT_BEHAVIOR/logs/$ATT_CASE_TAG.log"
  : >"$RUN_SESSION_LOG"
}
alert() { printf 'ALERT %s\n' "$1" >>"$ATT_CALLS"; }
warn() { printf 'WARN %s\n' "$1" >>"$ATT_CALLS"; }
log() { :; }
# shellcheck disable=SC1090
source "$SHARED/lib/duty-attention.sh"
duty_attention
ATTCASE
  cat "$calls"
}
ATT_124="$(attention_case 124)"
t attention-timeout-comments-once 1 "$(printf '%s\n' "$ATT_124" | grep -c '^COMMENT ' || true)"
t attention-timeout-alerts-once 1 "$(printf '%s\n' "$ATT_124" | grep -c '^ALERT ' || true)"
t attention-timeout-names-session-log named \
  "$(printf '%s\n' "$ATT_124" | grep -q 'attention-o__r_9-latest.log' && echo named || echo MISSING)"
t attention-timeout-does-not-commit 0 "$(printf '%s\n' "$ATT_124" | grep -c '^LEDGER$' || true)"
t attention-timeout-gh-read-only 1 "$(printf '%s\n' "$ATT_124" | grep -c '^GH api /issues?' || true)"
t attention-timeout-gh-makes-no-writes 0 \
  "$(printf '%s\n' "$ATT_124" | grep '^GH ' | grep -Ec 'issue edit| -X (POST|PATCH|DELETE)|--add-|--remove-' || true)"
# A retry has a different immutable run log but hands post-once a byte-identical
# stable link, so its exact-body match suppresses duplicate board comments.
ATT_124_RETRY="$(attention_case 124 retry)"
t attention-timeout-comment-body-stable \
  "$(printf '%s\n' "$ATT_124" | grep '^COMMENT ')" \
  "$(printf '%s\n' "$ATT_124_RETRY" | grep '^COMMENT ')"
ATT_0="$(attention_case 0)"
t attention-success-no-comment 0 "$(printf '%s\n' "$ATT_0" | grep -c '^COMMENT ' || true)"
t attention-success-no-alert 0 "$(printf '%s\n' "$ATT_0" | grep -c '^ALERT ' || true)"
t attention-success-commits-ledger 1 "$(printf '%s\n' "$ATT_0" | grep -c '^LEDGER$' || true)"
ATT_1="$(attention_case 1)"
t attention-crash-no-comment 0 "$(printf '%s\n' "$ATT_1" | grep -c '^COMMENT ' || true)"
t attention-crash-no-alert 0 "$(printf '%s\n' "$ATT_1" | grep -c '^ALERT ' || true)"
t attention-crash-does-not-commit 0 "$(printf '%s\n' "$ATT_1" | grep -c '^LEDGER$' || true)"

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

# Cross the file-contract boundary instead of testing only its writer. The
# floor probe must read the exact marker common.sh writes, including the
# service-specific filename and its single-line reason (#138, edge 3).
printf 'crew@fixture\n' >"$AUTHDIR/VERSION"
note_auth_failure gh "fixture rejection"
AUTH_PROBE="$(DUTY_DIR="$AUTHDIR" bash "$ROOT/fleet-floor/server/probe.sh" </dev/null)"
case "$AUTH_PROBE" in *$'::gh missing\n'*) r1=missing ;; *) r1=UNREAD ;; esac
t authfail-common-to-probe-state missing "$r1"
case "$AUTH_PROBE" in *'::authfail-gh '*'fixture rejection'*) r1=reason ;; *) r1=LOST ;; esac
t authfail-common-to-probe-reason reason "$r1"
clear_auth_failure gh

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
cred_rc() {  # cred_rc <agent> <home> [KIMI_CODE_HOME] -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite. KIMI_CODE_HOME
  # is the one a caller may set back, in $3, because kimi's home resolver gives
  # it precedence over both probed homes and that precedence is under test.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="${3:-}" CODEX_HOME="" GROK_HOME="" \
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

# -- kimi, the second home. The shipped CLI keeps the same credential at
# ~/.kimi, not ~/.kimi-code, so the profile resolves the home instead of
# assuming it (#240): the fleet's kimi box reported a dead vendor credential
# on every tick while being perfectly logged in. cred_rc clears
# KIMI_CODE_HOME by design, so these four are the unset case.
KH2="$CREDH/kimialt"; mkdir -p "$KH2/.kimi/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-present 0 "$(cred_rc kimi "$KH2")"
# A wider search must reach the SAME parser, not a second, dumber one.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-unparseable-is-unknown 2 "$(cred_rc kimi "$KH2")"
# Neither home holds anything: still a CONFIDENT logout. A resolver that fell
# back to a path it never checked would answer 2 here and silence a real one.
KH0="$CREDH/kiminone"; mkdir -p "$KH0/.kimi/credentials" "$KH0/.kimi-code/credentials"
t cred-kimi-neither-home 1 "$(cred_rc kimi "$KH0")"

# KIMI_CODE_HOME is explicit operator intent and outranks both probes. Proven
# by pointing it at a home with NO credential while BOTH known homes hold a
# good one: a resolver that probed first would answer 0. cred_rc's third
# argument is the only vendor override it does not clear, for exactly this.
KHO="$CREDH/kimiover"; mkdir -p "$KHO/.kimi/credentials" "$KHO/.kimi-code/credentials" "$KHO/elsewhere/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/.kimi/credentials/kimi-code.json"
cp "$KHO/.kimi/credentials/kimi-code.json" "$KHO/.kimi-code/credentials/kimi-code.json"
t cred-kimi-override-outranks-probe 1 "$(cred_rc kimi "$KHO" "$KHO/elsewhere")"
# ...and it reaches a credential neither probe would ever find.
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/elsewhere/credentials/kimi-code.json"
t cred-kimi-override-reaches-elsewhere 0 "$(cred_rc kimi "$KH0" "$KHO/elsewhere")"

# -- the SAME resolution drives PATH, and until now nothing asserted that half
# of #240's D2: BOT_PATH_PREPEND is an assignment evaluated when the profile is
# sourced, so reading it back also proves the resolver is defined ABOVE it.
# The resolved home's bin comes first, then every other known home's — a
# non-existent PATH entry costs nothing, which is why the fallbacks are cheaper
# than guessing right. Only PRESENCE of the credential picks the home here, not
# whether its JWT parses, so the fixtures above are reused exactly as they lie.
path_prepend() {  # path_prepend <home> [KIMI_CODE_HOME] -> BOT_PATH_PREPEND
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$1" KIMI_CODE_HOME="${2:-}"
    # shellcheck disable=SC1091
    source "$SHARED/conf/agents/kimi.conf"; printf '%s' "$BOT_PATH_PREPEND" ) 2>/dev/null
}
t path-kimi-alt-home-first "$KH2/.kimi/bin:$KH2/.kimi-code/bin" "$(path_prepend "$KH2")"
t path-kimi-old-home-first "$KH/.kimi-code/bin:$KH/.kimi/bin" "$(path_prepend "$KH")"
# No credential anywhere: the ~/.kimi-code fallback leads, and the other home
# is still on PATH — the CLI may be installed where the credential is not.
t path-kimi-neither-home-falls-back "$KH0/.kimi-code/bin:$KH0/.kimi/bin" "$(path_prepend "$KH0")"
# Explicit operator intent leads here too, even though both probes would hit.
t path-kimi-override-first "$KHO/elsewhere/bin:$KHO/.kimi/bin:$KHO/.kimi-code/bin" \
  "$(path_prepend "$KHO" "$KHO/elsewhere")"

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

# ...and every profile must launch its CLI NON-INTERACTIVELY. run_session runs
# each CLI with </dev/null, deliberately, so a tool-approval prompt has no
# stdin to read and no human to answer it: the session blocks until the role
# budget kills it and writes rc=124 outcome=TIMEOUT — no verdict, no comment,
# 45 minutes spent. kimi shipped with no flag at all and did exactly that on
# every session, which kept every PR in this repo one panel verdict short
# (#240). Nothing here read BOT_CLI_CMD before, so the only detector was a
# 45-minute silence on one box. The flag's SPELLING is the vendor's; that one
# is present is crew's, and this is where crew says so.
for pair in \
  "claude:--dangerously-skip-permissions" \
  "codex:--dangerously-bypass-approvals-and-sandbox" \
  "grok:--permission-mode bypassPermissions" \
  "kimi:--afk"; do
  agent="${pair%%:*}"; want="${pair#*:}"
  # The array is joined and matched with surrounding spaces so a multi-token
  # flag is pinned whole and a longer flag that merely starts the same cannot
  # pass for it.
  # shellcheck disable=SC1090
  got="$( source "$SHARED/conf/agents/$agent.conf"; printf '%s' "${BOT_CLI_CMD[*]}" )"
  case " $got " in *" $want "*) r1=present ;; *) r1=MISSING ;; esac
  t "agent-conf-$agent-non-interactive" present "$r1"
done

# The boot gate must exercise the same Kimi command shape as a real session.
# `kimi doctor` looked plausible but bypassed both --afk and the resolved
# credential home, so the upgraded Kimi box warned on every tick while real
# review sessions succeeded at the same minutes (#240). This fixture accepts
# only the command/environment pair that makes sessions work on that box.
KIMI_PROBE_HOME="$TMP/kimi-probe-home"
mkdir -p "$KIMI_PROBE_HOME/.kimi/bin" "$KIMI_PROBE_HOME/.kimi/credentials"
printf '%s\n' '{"refresh_token":"fixture"}' \
  >"$KIMI_PROBE_HOME/.kimi/credentials/kimi-code.json"
cat >"$KIMI_PROBE_HOME/.kimi/bin/kimi" <<'EOF'
#!/usr/bin/env bash
[ "${KIMI_CODE_HOME:-}" = "$HOME/.kimi" ] || exit 21
[ "${KIMI_PROBE_AUTH:-accept}" != reject ] || exit 23
[ "${KIMI_PROBE_EXPECT_GUARDS:-0}" != 1 ] || {
  [ -z "${DUTY_LOCKED+x}${NOTIFY_LOCKED+x}${DUTY_SNAPSHOT+x}" ] || exit 24
}
[ "${KIMI_PROBE_READ_STDIN:-0}" != 1 ] || cat >/dev/null
[ "${KIMI_PROBE_HANG:-0}" != 1 ] || while :; do sleep 10; done
case " $* " in
  *" --afk -p "*) exit 0 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$KIMI_PROBE_HOME/.kimi/bin/kimi"

KIMI_TIMEOUT_BIN="$TMP/kimi-timeout-bin"
KIMI_TIMEOUT_CAPTURE="$TMP/kimi-timeout-args"
mkdir -p "$KIMI_TIMEOUT_BIN"
cat >"$KIMI_TIMEOUT_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >"$KIMI_TIMEOUT_CAPTURE"
shift 3
exec /usr/bin/timeout -k 1 1 "$@"
EOF
chmod +x "$KIMI_TIMEOUT_BIN/timeout"

kimi_probe_rc() {  # kimi_probe_rc [working|interactive|logged-out|stdin|guards|bound]
  local shape="${1:-working}" auth=accept read_stdin=0 expect_guards=0 hang=0 rc=0
  [ "$shape" != logged-out ] || auth=reject
  [ "$shape" != stdin ] || read_stdin=1
  [ "$shape" != guards ] || expect_guards=1
  [ "$shape" != bound ] || hang=1
  # shellcheck disable=SC2016  # expansion belongs to the fixture shell
  /usr/bin/timeout -k 1 3 \
    env HOME="$KIMI_PROBE_HOME" SHARED="$SHARED" KIMI_PROBE_SHAPE="$shape" \
    KIMI_PROBE_AUTH="$auth" KIMI_PROBE_READ_STDIN="$read_stdin" \
    KIMI_PROBE_EXPECT_GUARDS="$expect_guards" KIMI_PROBE_HANG="$hang" \
    KIMI_TIMEOUT_BIN="$KIMI_TIMEOUT_BIN" \
    KIMI_TIMEOUT_CAPTURE="$KIMI_TIMEOUT_CAPTURE" \
    DUTY_LOCKED=1 NOTIFY_LOCKED=1 DUTY_SNAPSHOT=fixture \
    bash -c '
      unset KIMI_CODE_HOME
      source "$SHARED/conf/agents/kimi.conf"
      export PATH="$BOT_PATH_PREPEND:$KIMI_TIMEOUT_BIN:/usr/bin:/bin"
      [ "$KIMI_PROBE_SHAPE" != interactive ] || \
        BOT_CLI_CMD=(env "KIMI_CODE_HOME=$(_kimi_home)" kimi -p)
      bot_cli_probe
    ' >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
t kimi-boot-probe-matches-working-session 0 "$(kimi_probe_rc working)"
if [ "$(kimi_probe_rc interactive)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-rejects-interactive-session failed "$r1"
if [ "$(kimi_probe_rc logged-out)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-rejects-logged-out-session failed "$r1"
KIMI_STDIN_FIFO="$TMP/kimi-probe-stdin"
mkfifo "$KIMI_STDIN_FIFO"
( sleep 5 >"$KIMI_STDIN_FIFO" ) & kimi_stdin_writer=$!
t kimi-boot-probe-closes-inherited-stdin 0 "$(kimi_probe_rc stdin <"$KIMI_STDIN_FIFO")"
kill "$kimi_stdin_writer" 2>/dev/null || true
wait "$kimi_stdin_writer" 2>/dev/null || true
t kimi-boot-probe-clears-lock-environment 0 "$(kimi_probe_rc guards)"
rm -f "$KIMI_TIMEOUT_CAPTURE"
if [ "$(kimi_probe_rc bound)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-bounds-hung-cli failed "$r1"
t kimi-boot-probe-timeout-arguments "-k 10 60" \
  "$(cat "$KIMI_TIMEOUT_CAPTURE" 2>/dev/null)"

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

# --- terminal session classification and per-kind breaker (#388) ----------
TERM_LOG="$TMP/session-terminal.log"
printf '%s\n' "Server: Error code: 403 - {'error': {'message': \"You've reached your usage limit for this billing cycle.\", 'type': 'access_terminated_error'}}" >"$TERM_LOG"

kimi_session_classification() (
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf "provider error: {'type': 'access_terminated_error'}\n" >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'provider error: access_terminated_error; reached your usage limit\n' >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  if bot_session_terminal "$SHARED/conf/agents/kimi.conf"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'Used Shell (gh api repos/o/r/pulls/1/reviews)\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
  printf '|'
  printf 'Final answer only\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
)
t kimi-session-hooks 'terminal|terminal|transient|transient|yes|no' \
  "$(kimi_session_classification)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
kimi_quoted_terminal_then_transient() (
  local bdir="$TMP/terminal-breaker-kimi-quoted" i state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  BOT_CLI_CMD=(bash -c '
    printf x >>"$BREAKER_CALLS"
    printf "%s\n" "Used Shell (gh issue view 388)"
    printf "%s\n" "Server: Error code: 403 - {'\''error'\'': {'\''message'\'': \"You'\''ve reached your usage limit for this billing cycle.\", '\''type'\'': '\''access_terminated_error'\''}}"
    printf "%s\n" "transient network failure: dial tcp i/o timeout"
    exit 1
  ')
  bot_cli_probe() { printf probe >>"$bdir/probes"; return 0; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  state="$(_session_terminal_state review)"
  printf '%s|%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'outcome=FAILED' "$bdir/output" || true)" \
    "$([ -e "$state" ] && echo tripped || echo clear)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)" \
    "$([ -e "$bdir/probes" ] && wc -c <"$bdir/probes" || echo 0)"
)
t kimi-quoted-terminal-payload-ending-transient-never-trips '16|16|clear|0|0' \
  "$(kimi_quoted_terminal_then_transient)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_case() ( # terminal_breaker_case terminal|transient|hookless
  local shape="$1" bdir="$TMP/terminal-breaker-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"
  LOG_DIR="$bdir/logs"
  DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"
  : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf "%s\n" "$BREAK_TEXT"; exit 1')
  export BREAK_TEXT=transient-network-failure
  if [ "$shape" = terminal ]; then
    BREAK_TEXT=access_terminated_error
    export BREAK_TEXT
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  elif [ "$shape" = transient ]; then
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  else
    unset -f bot_session_terminal
  fi
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  local alert_count=0
  [ ! -f "$bdir/alerts" ] || alert_count="$(wc -l <"$bdir/alerts")"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$alert_count" \
    "$(grep -c 'outcome=TERMINAL' "$bdir/output" || true)" \
    "$(grep -c 'SESSION SKIP.*terminal-breaker' "$bdir/output" || true)"
)
t terminal-breaker-replays-sixteen-as-three-dispatches '3|1|3|13' \
  "$(terminal_breaker_case terminal)"
t transient-failures-never-trip '16|0|0|0' \
  "$(terminal_breaker_case transient)"
t hookless-failures-remain-transient '16|0|0|0' \
  "$(terminal_breaker_case hookless)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_resets_sequence() (
  local bdir="$TMP/terminal-breaker-reset" state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'printf "%s\n" "$BREAK_TEXT"; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  alert() { :; }
  export BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=transient-network-failure
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  if [ -s "$state" ]; then
    IFS=$'\t' read -r count status _ <"$state"
    printf '%s|%s' "$count" "$status"
  else
    printf missing
  fi
)
t terminal-breaker-transient-resets-consecutive-count '2|closed' \
  "$(terminal_breaker_resets_sequence)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_timeout_case() (
  local bdir="$TMP/terminal-breaker-timeout" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'exit 124')
  bot_session_terminal() { return 0; }
  bot_session_acted() { return 1; }
  alert() { printf alert >>"$bdir/alerts"; }
  for i in $(seq 1 16); do run_session review fixture/repo "$bdir/work" 5 prompt; done >"$bdir/output"
  printf '%s|%s' "$(grep -c 'outcome=TIMEOUT' "$bdir/output")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo tripped || echo clear)"
)
t timeout-failures-never-trip '16|clear' "$(terminal_timeout_case)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_kind_isolation() (
  local bdir="$TMP/terminal-breaker-kind" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session build fixture/repo "$bdir/work" 5 prompt >/dev/null
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo review-stopped || echo review-open)"
)
t terminal-breaker-is-keyed-by-kind '4|review-stopped' "$(terminal_kind_isolation)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_recovery() (
  local bdir="$TMP/terminal-breaker-recovery" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  DUTY_TICK_ID=tick-2
  bot_cli_probe() { return 0; }
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" "$([ -e "$state" ] && echo present || echo cleared)"
)
t terminal-breaker-recovers-on-next-tick '4|cleared' "$(terminal_breaker_recovery)"

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

# The never-ticked boundary is the same kind of shared rule and pinned the same
# way (#265). SILENT_AFTER_S was never the only number the two readers had to
# agree on — it was only the only one that EXISTED. `waiting` adds a second
# boundary, and a verdict living in one reader alone is precisely the
# disagreement auth_from_flow was written to remove: `crew status` would say a
# fresh hire is waiting while the floor called it stale, in front of the same
# operator, about the same box. Extracted rather than grepped for, so that
# moving the boundary in one reader fails HERE rather than silently.
# shellcheck disable=SC2016  # a literal fragment of cli/crew, not to expand
CL_NEVER="$(sed -n 's/^ *if \[ "$tickage" -lt \(-*[0-9][0-9]*\) \]; then.*/\1/p' "$CREW_CLI" | head -1)"
FL_NEVER="$(sed -n 's/^ *never_ticked = tick_age < \(-*[0-9][0-9]*\).*/\1/p' "$FLOOR_PY" | head -1)"
t nevertick-rule-floor-boundary 0 "$FL_NEVER"
t nevertick-rule-cli-matches-floor "$FL_NEVER" "$CL_NEVER"
# ...and it must be a verdict BOTH readers can actually produce. The boundary
# matching proves they agree on WHEN; these prove they agree on what to CALL it,
# which is the half a numeric compare cannot see: two readers could share the
# boundary exactly and still print different words at it.
# shellcheck disable=SC2016  # a literal fragment of cli/crew, not to expand
if grep -q 'printf -v "$_v" waiting' "$CREW_CLI"; then r1=emitted; else r1=MISSING; fi
t nevertick-cli-emits-waiting emitted "$r1"
if grep -q 'u\[svc\] = "waiting"' "$FLOOR_PY"; then r1=emitted; else r1=MISSING; fi
t nevertick-floor-emits-waiting emitted "$r1"

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
# Same-head reruns are all present in the rollup. The latest run of each check
# name is the check's answer; older runs are not independent evidence.
CHK_CANCEL_THEN_OK='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"}]'
CHK_OK_THEN_CANCEL='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:08Z"}]'
CHK_SAME_SECOND_CANCEL_LAST='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"}]'
CHK_WORKFLOW_COLLISION_FAILURE_FIRST='[
  {"__typename":"CheckRun","name":"test","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:00:00Z","completedAt":"2026-07-29T10:01:00Z"},
  {"__typename":"CheckRun","name":"test","workflowName":"nightly","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T10:05:00Z","completedAt":"2026-07-29T10:06:00Z"}]'
CHK_WORKFLOW_COLLISION_FAILURE_LAST="$(printf '%s' "$CHK_WORKFLOW_COLLISION_FAILURE_FIRST" | jq 'reverse')"
CHK_SUPERSEDED_CANCEL_AND_FAILURE='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:58:47Z","completedAt":"2026-07-29T10:59:22Z"}]'
CHK_FAILURE_THEN_RUNNING='[
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:58:47Z","completedAt":"2026-07-29T10:59:22Z"},
  {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-07-29T11:02:00Z","completedAt":null}]'
# The StatusContext shape. THIS is the fixture that matters: crew's own CI is a
# single CheckRun, so an implementation that discriminates on __typename and
# reads only .conclusion passes every other test in this file and reports a
# FAILING status context as green — a pass for a reason unrelated to the claim,
# which is #50's shape. Reintroduce that discrimination and these two go red.
SC_BAD='[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
SC_ERR='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
SC_MIX='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
# The status carries `startedAt`, not `createdAt`: `gh` requests GitHub's
# `createdAt` for a StatusContext and serialises it under its own key, so
# `createdAt` never reaches a caller. `latest_checks` reads `.startedAt //
# .createdAt`, so the generation ordering this fixture pins is unchanged either
# way — but the fiction is the one that went on to kill `_resume_newest_check`
# one module over (#391 round 2), and a fixture file cannot hold a shape
# contract while contradicting it here.
SC_COLLISION_STATUS_LAST='[
  {"__typename":"CheckRun","name":"ci/build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"StatusContext","context":"ci/build","state":"FAILURE","startedAt":"2026-07-29T11:05:00Z"}]'
SC_COLLISION_STATUS_FIRST="$(printf '%s' "$SC_COLLISION_STATUS_LAST" | jq 'reverse')"

state_of() { hc '[]' "$(mk_prc "$1")" | cut -f4; }
t head-check-run-success      green   "$(state_of "$CHK_OK")"
t head-check-run-failure      red     "$(state_of "$CHK_BAD")"
t head-status-context-failure red     "$(state_of "$SC_BAD")"
t head-status-context-error   red     "$(state_of "$SC_ERR")"
t head-mixed-shapes-one-red   red     "$(state_of "$SC_MIX")"
t head-colliding-status-last-is-red red "$(state_of "$SC_COLLISION_STATUS_LAST")"
t head-colliding-status-first-is-red red "$(state_of "$SC_COLLISION_STATUS_FIRST")"
t head-check-still-running    pending "$(state_of "$CHK_RUNNING")"
t head-no-checks-is-not-green none    "$(state_of '[]')"
# GREEN IS A WHITELIST; ANYTHING ELSE IS RED (codex, #64). The first version
# enumerated the failing conclusions and let the rest fall through to green,
# arguing a CANCELLED run is one superseded by a newer push. Same-head rollups
# can retain several generations of one check name, but after reducing those
# generations a latest cancellation is a head that is not passing. Reading it
# green defeated #45's gate and blinded #17's wake at the same time. This test
# previously asserted `green` and locked that in, which is why it is called
# out here rather than quietly flipped.
t head-cancelled-is-red       red     "$(state_of "$CHK_CANCEL")"
t head-stale-is-red           red     "$(state_of "$CHK_STALE")"
# ...and the point of a whitelist: a conclusion nobody has written a branch for
# fails CLOSED. Enumerating the bad ones would have gotten this wrong the same
# way, silently, the next time GitHub adds one.
t head-unknown-conclusion-is-red red  "$(state_of "$CHK_UNKNOWN")"
# #146: a concurrency cancellation superseded by a later same-name success is
# not evidence; a cancellation that remains the latest run is still fail-closed.
t head-cancelled-then-succeeded-is-green green "$(state_of "$CHK_CANCEL_THEN_OK")"
t head-cancelled-as-last-word-is-red red "$(state_of "$CHK_OK_THEN_CANCEL")"
t head-same-second-cancel-last-is-green green "$(state_of "$CHK_SAME_SECOND_CANCEL_LAST")"
# Same-named jobs in different workflows are independent evidence. Neither
# rollup order may let one workflow's success discard another one's failure.
t head-workflow-collision-failure-first-is-red red \
  "$(state_of "$CHK_WORKFLOW_COLLISION_FAILURE_FIRST")"
t head-workflow-collision-failure-last-is-red red \
  "$(state_of "$CHK_WORKFLOW_COLLISION_FAILURE_LAST")"
# An unrelated failure survives even while the superseded cancellation from
# another check identity disappears.
t head-unrelated-failure-survives-superseded-cancel red \
  "$(state_of "$CHK_SUPERSEDED_CANCEL_AND_FAILURE")"
t head-unrelated-failure-is-named "test (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_SUPERSEDED_CANCEL_AND_FAILURE")" | cut -f6)"
# A rerun in progress is the latest word and therefore pending, not the stale
# failure from the earlier run.
t head-running-rerun-supersedes-failure pending "$(state_of "$CHK_FAILURE_THEN_RUNNING")"
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

# #286: the same agreement extended to the REQUEST side, on the #281 snapshot as
# it reads once the signal is spent — every verdict in, no request outstanding,
# and the only signal older than the blocking verdicts it supposedly answered.
# The bug was never that one of these predicates was wrong. round_owed and
# addressing.jq were both right and both held false by the engine's own request,
# so the ball landed nowhere: request-panel.jq has to agree with its siblings on
# the same payload or the round has no owner at all. Asserting the four together
# is what makes "the ball provably lands somewhere" a test rather than a claim.
PR281_PANEL='["p1","p2","p3"]'
PR281_REVIEWS='[
  {"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:32:33Z"},
  {"state":"CHANGES_REQUESTED","author":{"login":"p2"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:35:14Z"},
  {"state":"APPROVED","author":{"login":"p3"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:29:40Z"}]'
# The signal that opened round 1 at 10:08:12Z — older than every verdict above,
# and the only one #281 ever carried.
PR281_SIG="$(sig abc1234 2026-08-02T10:08:12Z)"
PR281_GQL="$(jq -cn --argjson reviews "$PR281_REVIEWS" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-281-requests-none "" \
  "$(mk_rp abc1234 '[]' "$PR281_REVIEWS" '[]' | rp "$PR281_SIG" "$PR281_PANEL")"
t round-siblings-281-round-owed owed \
  "$(hc "$PR281_PANEL" "$(mk_prc "$CHK_OK" "$PR281_REVIEWS")" | cut -f5)"
t round-siblings-281-addressing true \
  "$(printf '%s' "$PR281_GQL" | jq -r --argjson panel "$PR281_PANEL" \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-281-converged false \
  "$(printf '%s' "$PR281_GQL" | jq -r --argjson panel "$PR281_PANEL" \
    --arg needs_human state:needs-human -f "$CJQ")"
# The live-round half of the same agreement, and the reason state:bots-reviewing
# is true only while a request awaits a verdict: with p2 still requested, the
# round is the panel's — addressing.jq holds off, and request-panel.jq's
# coherence gate holds p1 rather than opening a second round at one head.
PR281_MID="$(printf '%s' "$PR281_GQL" \
  | jq -c '.data.repository.pullRequest.reviewRequests.nodes
             = [{requestedReviewer:{login:"p2"}}]')"
t round-siblings-281-mid-round-addressing false \
  "$(printf '%s' "$PR281_MID" | jq -r --argjson panel "$PR281_PANEL" \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-281-mid-round-requests-none "" \
  "$(mk_rp abc1234 '["p2"]' "$PR281_REVIEWS" '[]' \
    | rp "$(sig abc1234 2026-08-02T11:12:27Z)" "$PR281_PANEL")"

# --- the ci-red ledger key: why the head is the ID, not the value (#17) -------
# #243: a ready PR missing its current-head signal becomes resume work only on
# the twelfth consecutive tick. The state is keyed by head, so a push resets
# the count even when the PR number is unchanged.
STRANDED_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STRANDED_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
STRANDED_NONE="cccccccccccccccccccccccccccccccccccccccc"
STRANDED_JSON="$(jq -cn --arg head "$STRANDED_HEAD" --arg old "$STRANDED_OLD" --arg none "$STRANDED_NONE" '[
  {number:1,isDraft:true,headRefOid:$head,comments:[]},
  {number:2,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER `" + $head + "`")}]},
  {number:3,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $old)}]},
  {number:4,isDraft:false,headRefOid:$none,comments:[
    {author:{login:"other"},body:("ANSWER " + $none)}]},
  {number:5,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER: " + $head)}]}
]')"
t stranded-keys-exclude-draft-and-current-signal \
  "$(printf 'o/r#3@%s\no/r#4@%s' "$STRANDED_HEAD" "$STRANDED_NONE")" \
  "$(printf '%s' "$STRANDED_JSON" | _stranded_resume_keys o/r me ANSWER)"
# #286: the licence grew a createdAt half, and THIS path stays indifferent to
# it. These listings carry the field natively — `gh pr list --json comments`
# returns it — so the fixture proves the extra field changes nothing here.
# The two cases are deliberately inverted against the clock: #6 signals the
# CURRENT head with the OLDER comment and is not stranded, #7 signals an OLD
# head with the NEWER comment and is. A path that started reading the time
# instead of the sha would get both backwards. Stranded detection asks which
# head a signal names; whether that signal was spent by the verdicts answering
# it is the request side's question (#286), never resume's (#243).
STRANDED_TIMED="$(jq -cn --arg head "$STRANDED_HEAD" --arg old "$STRANDED_OLD" '[
  {number:6,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $head),createdAt:"2026-08-02T10:08:12Z"}]},
  {number:7,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $old),createdAt:"2026-08-02T11:12:27Z"}]}
]')"
t stranded-keys-ignore-the-signal-clock \
  "$(printf 'o/r#7@%s' "$STRANDED_HEAD")" \
  "$(printf '%s' "$STRANDED_TIMED" | _stranded_resume_keys o/r me ANSWER)"
STRANDED_STATE="$TMP/resume-unsignalled"
for _tick in $(seq 1 11); do
  stranded_out="$(printf 'o/r#243@aaa\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
done
t stranded-resume-not-before-12 "" "$stranded_out"
t stranded-resume-on-12 243 \
  "$(printf 'o/r#243@aaa\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
t stranded-resume-state-file-format-byte-compatible \
  $'o/r#243@aaa\t12' "$(cat "$STRANDED_STATE")"
t stranded-resume-push-resets "" \
  "$(printf 'o/r#243@bbb\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
t stranded-resume-new-head-count-is-one 1 \
  "$(awk -F'\t' '$1 == "o/r#243@bbb" {print $2}' "$STRANDED_STATE")"
# A signal removes the PR from the candidate input; a later new head starts a
# fresh episode rather than inheriting the old count.
printf '' | _stranded_resume_due "$STRANDED_STATE" 12 >/dev/null
t stranded-resume-signal-clears-state 0 "$(wc -l <"$STRANDED_STATE" | tr -d ' ')"

# #403: the near-miss bypass and the post-twelve stranded output each pass
# through the same reporting adapter but own independent breaker state. Drive
# ticks 1→5 at one head, then a push and ticks 6→8: a single call cannot prove
# that the fourth and fifth attempts stay suppressed or that head movement is
# the only reset.
lane_tick() {
  local lane="$1" state="$2" keys="$3" log_file="$4"
  _resume_lane_breaker o/r "$lane" "$state" "$keys" >>"$log_file" 2>&1
  LANE_OUT="$RESUME_LANE_DISPATCH_NUMS"
}
for lane in near-miss stranded; do
  lane_state="$TMP/resume-zero-action-$lane"
  lane_log="$TMP/resume-zero-action-$lane.log"
  : >"$lane_log"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-1" 403 "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-2" 403 "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-3" 403 "$LANE_OUT"
  t "$lane-breaker-trip-at-3" 1 \
    "$(grep -c "WARN: o/r#403: $lane resume dispatch 3 of 3 at head aaa — the previous 2 produced no commit" "$lane_log")"
  t "$lane-breaker-trip-claims-no-third-result" 0 \
    "$(grep -c 'previous 3 produced no commit' "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-suppresses-4" "" "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-suppresses-5" "" "$LANE_OUT"
  t "$lane-breaker-suppression-speaks-every-tick" 2 \
    "$(grep -c "o/r#403 $lane lane suppressed at aaa after 3 zero-action dispatches" "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  t "$lane-breaker-push-resets-to-1" 403 "$LANE_OUT"
  t "$lane-breaker-push-state-count" 1 \
    "$(awk -F'\t' '$1 == "o/r#403@bbb" { print $2 }' "$lane_state")"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  t "$lane-breaker-post-push-dispatch-3" 403 "$LANE_OUT"
  t "$lane-breaker-logs-lane-pr-count-head" 1 \
    "$(grep -c "o/r#403: $lane resume dispatch 3 of 3 at bbb" "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#404@ccc' "$lane_log"
  t "$lane-breaker-prunes-left-set" $'o/r#404@ccc\t1' "$(cat "$lane_state")"
done

# The concrete call sites and consumers are both part of the contract: sharing
# either new file resets the other lane, while ignoring either verdict restores
# the unbounded wiring without disturbing the helper-level breaker tests.
# shellcheck disable=SC2016  # matching shell source literally
if [ "$(grep -cF '.resume-zero-action-nearmiss.$slug' "$SHARED/lib/duty-builder.sh")" = 1 ] \
  && grep -Fq 'near_miss_nums="$RESUME_LANE_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED-OR-SHARED
fi
t resume-lane-breaker-nearmiss-wiring bounded "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if [ "$(grep -cF '.resume-zero-action-stranded.$slug' "$SHARED/lib/duty-builder.sh")" = 1 ] \
  && grep -Fq 'stranded_nums="$RESUME_LANE_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED-OR-SHARED
fi
t resume-lane-breaker-stranded-wiring bounded "$r1"
ISO_NEAR="$TMP/resume-isolation-near"; ISO_STRANDED="$TMP/resume-isolation-stranded"
lane_tick near-miss "$ISO_NEAR" 'o/r#403@same' "$TMP/resume-isolation.log"
lane_tick near-miss "$ISO_NEAR" 'o/r#403@same' "$TMP/resume-isolation.log"
lane_tick stranded "$ISO_STRANDED" 'o/r#403@same' "$TMP/resume-isolation.log"
t resume-lane-breaker-state-files-do-not-touch $'2\t1' \
  "$(paste <(cut -f2 "$ISO_NEAR") <(cut -f2 "$ISO_STRANDED"))"

# A suppressed near miss must not hitchhike in the prompt when an unrelated PR
# independently buys the session. Drive A past its breaker and B through the
# real twelve-tick threshold, then build the same final dispatch union and
# description the repository tick uses.
MIXED_NEAR_STATE="$TMP/resume-mixed-near"
MIXED_NEAR_LOG="$TMP/resume-mixed-near.log"
for _tick in $(seq 1 4); do
  lane_tick near-miss "$MIXED_NEAR_STATE" 'o/r#403@aaa' "$MIXED_NEAR_LOG"
done
MIXED_DUE_STATE="$TMP/resume-mixed-due"
for _tick in $(seq 1 12); do
  mixed_due_nums="$(printf 'o/r#404@bbb\n' | _stranded_resume_due "$MIXED_DUE_STATE" 12)"
done
mixed_stranded_nums="$(printf '%s %s' "$mixed_due_nums" "$LANE_OUT" \
  | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
mixed_near_desc="$(_near_miss_dispatch_desc $'403\t9001' "$mixed_stranded_nums")"
t resume-lane-mixed-unrelated-pr-still-wakes 404 "$(printf '%s' "$mixed_stranded_nums" | xargs)"
t resume-lane-mixed-suppressed-near-miss-not-actionable "" "$mixed_near_desc"
# If an independent lane admits the same PR, retain why its signal looked like
# a near miss even though the near-miss lane itself is suppressed.
t resume-lane-mixed-same-pr-keeps-near-miss-context '#403 (comment 9001)' \
  "$(_near_miss_dispatch_desc $'403\t9001' '403')"

# The post-twelve lane has two counters with different questions. Trip its
# dispatch breaker after ticks 12–14, then move the head: the unsignalled
# counter starts at one immediately, while the breaker starts at one when that
# new head first becomes dispatchable on its twelfth tick.
DUAL_DUE="$TMP/resume-dual-unsignalled"
DUAL_BREAKER="$TMP/resume-dual-breaker"
DUAL_LOG="$TMP/resume-dual.log"
for _tick in $(seq 1 14); do
  dual_num="$(printf 'o/r#403@aaa\n' | _stranded_resume_due "$DUAL_DUE" 12)"
  dual_keys=""
  [ -z "$dual_num" ] || dual_keys='o/r#403@aaa'
  lane_tick stranded "$DUAL_BREAKER" "$dual_keys" "$DUAL_LOG"
done
t stranded-lane-trips-after-three-past-threshold-dispatches 3 \
  "$(cut -f2 "$DUAL_BREAKER")"
dual_num="$(printf 'o/r#403@bbb\n' | _stranded_resume_due "$DUAL_DUE" 12)"
lane_tick stranded "$DUAL_BREAKER" "" "$DUAL_LOG"
t stranded-lane-push-restarts-unsignalled-at-one $'o/r#403@bbb\t1' \
  "$(cat "$DUAL_DUE")"
for _tick in $(seq 2 12); do
  dual_num="$(printf 'o/r#403@bbb\n' | _stranded_resume_due "$DUAL_DUE" 12)"
done
dual_keys=""; [ -z "$dual_num" ] || dual_keys='o/r#403@bbb'
lane_tick stranded "$DUAL_BREAKER" "$dual_keys" "$DUAL_LOG"
t stranded-lane-push-restarts-breaker-at-one $'o/r#403@bbb\t1' \
  "$(cat "$DUAL_BREAKER")"

# The no-signal hold speaks once for one repo/PR/head, then speaks again when a
# push changes the key. report_suppressed writes through warn on stderr.
hold1="$(_report_unsignalled_hold o/r 243 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
hold2="$(_report_unsignalled_hold o/r 243 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
hold3="$(_report_unsignalled_hold o/r 243 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"
t unsignalled-hold-first-warns 1 "$(grep -c 'no round-answered signal' <<<"$hold1")"
t unsignalled-hold-same-head-quiet 0 "$(grep -c 'no round-answered signal' <<<"$hold2")"
t unsignalled-hold-new-head-warns 1 "$(grep -c 'no round-answered signal' <<<"$hold3")"
# Pin the wake-path wiring too: helper-only tests stay green if the request
# gate regresses to the old bare log that flooded #227 on every tick.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_report_unsignalled_hold "$repo" "$num" "$gql_head"' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=BARE-OR-MISSING
fi
t unsignalled-hold-wired-into-request-gate wired "$r1"

# --- #319: a round-answered signal that missed the wire ---------------------
# PR #311 posted `{{MARK_ANSWERED}} 3741918e…` — the literal slot name, then the
# correct head. The marker is accepted only as a prefix, so to the engine that
# was not a partial signal, it was no comment at all: no panel requested,
# state:addressing standing over an answered round at a green head, and the
# twelve-tick stranded path an hour away. A near-miss is detectable on sight,
# and these fixtures ARE that comment body.
NM_HEAD=3741918e27139974532956470a2c411e5bc6ad62
NM_OLD=f117b520f117b520f117b520f117b520f117b520
NMJQ="$SHARED/lib/jq/near-miss-signal.jq"
nm_payload() {  # nm_payload <comment json>... -> the GraphQL payload shape
  jq -cn --argjson nodes "$(printf '%s\n' "$@" | jq -sc '.')" \
    '{data:{repository:{pullRequest:{comments:{nodes:$nodes}}}}}'
}
nm_comment() {  # nm_comment LOGIN BODY [ID] [CREATED]
  jq -cn --arg login "$1" --arg body "$2" --arg id "${3:-5165639326}" \
    --arg at "${4:-2026-08-03T11:17:54Z}" \
    '{author:{login:$login},body:$body,createdAt:$at,id:$id}'
}
nm() { jq -c --arg me me -f "$NMJQ"; }

# The incident, byte for byte.
t near-miss-detects-the-incident \
  "{\"sha\":\"$NM_HEAD\",\"createdAt\":\"2026-08-03T11:17:54Z\",\"id\":\"5165639326\"}" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD")" | nm)"
# Any unrendered slot is the same defect: the shape is the evidence, not the
# name. Whichever marker the session meant, a ready PR at a head with no valid
# signal is owed the round-answered one, so resume's next act is the same.
t near-miss-matches-any-marker-slot "$NM_HEAD" \
  "$(nm_payload "$(nm_comment me "{{MARK_RESUME}} $NM_HEAD")" | nm | jq -r .sha)"
# MUST FAIL — a near-miss treated as a signal. The two predicates partition the
# same thread: neither body is ever both, in either direction. The engine
# requesting a panel off unrendered template text is a worse failure than the
# stall #319 fixes.
NM_REAL="$(nm_payload "$(nm_comment me "📣 round answered at head $NM_HEAD")")"
t near-miss-real-signal-is-not-a-near-miss "" \
  "$(printf '%s' "$NM_REAL" | nm | jq -r .sha)"
t near-miss-real-signal-still-reads-as-a-signal "$NM_HEAD" \
  "$(printf '%s' "$NM_REAL" \
     | jq -r --arg me me --arg mark '📣 round answered at head' -f "$AHJQ" | jq -r .sha)"
NM_PLACEHOLDER="$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD")")"
t near-miss-placeholder-is-not-a-signal "" \
  "$(printf '%s' "$NM_PLACEHOLDER" \
     | jq -r --arg me me --arg mark '📣 round answered at head' -f "$AHJQ" | jq -r .sha)"
# Anchored, like the startswith it mirrors: a body that MENTIONS a placeholder —
# a reviewer quoting the incident, this suite's own prose — is discussion, and
# must never make a PR resume-due.
t near-miss-prose-mentioning-a-slot-is-not-one "" \
  "$(nm_payload "$(nm_comment me "the session posted {{MARK_ANSWERED}} $NM_HEAD by mistake")" \
     | nm | jq -r .sha)"
# A slot with no head names nothing to resume at.
t near-miss-without-a-head-is-nothing "" \
  "$(nm_payload "$(nm_comment me '{{MARK_ANSWERED}} (sha to follow)')" | nm | jq -r .sha)"
# Somebody else's botched marker is not my signal, exactly as in answered-head.
t near-miss-is-mine-only "" \
  "$(nm_payload "$(nm_comment other "{{MARK_ANSWERED}} $NM_HEAD")" | nm | jq -r .sha)"
# Latest wins, and the id travels with the sha it belongs to.
t near-miss-latest-wins "$NM_HEAD 5165639326" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_OLD" 111)" \
       "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD" 5165639326)" \
     | nm | jq -r '"\(.sha) \(.id)"')"
# The sha is captured from what FOLLOWS the slot, so a near-miss that quotes
# another commit first cannot name the wrong head.
t near-miss-reads-the-head-after-the-slot "$NM_HEAD" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD (was $NM_OLD)")" | nm | jq -r .sha)"
t near-miss-empty-thread-is-empty "" "$(echo '{}' | nm | jq -r .sha)"

# THE PANEL IS NOT REQUESTED FROM A NEAR-MISS, end to end. With only that
# comment on the thread, answered-head.jq reads no signal, so _request_panel
# returns at its gate; and request-panel.jq, handed the empty licence that gate
# would have handed it, names nobody. `me-bot` and `$H` are the request-side
# fixture's own author and head (above), so this is that block's PR with the
# incident's comment body substituted for its signal — the only difference.
NM_ONLY="$(mk_rp "$H" '[]' '[]' \
  "$(jq -cn --arg b "{{MARK_ANSWERED}} $H" '[{author:{login:"me-bot"},body:$b}]')")"
t near-miss-answered-head-reads-no-signal "" "$(printf '%s' "$NM_ONLY" | ah_sha)"
# ...and _request_panel therefore issues nothing. Driven through the gate itself
# rather than through request-panel.jq, because the sha half of the licence is
# the CALLER's gate and is deliberately not re-checked in the predicate (that
# file's header) — asking the predicate would be asking the wrong layer. `gh` is
# a shell function here, so any API call the gate lets through is recorded
# instead of made.
NM_DUTY="$TMP/near-miss-duty"; mkdir -p "$NM_DUTY/lib"
ln -sfn "$SHARED/lib/jq" "$NM_DUTY/lib/jq"
NM_STUB="$TMP/near-miss-bin"; mkdir -p "$NM_STUB"
cat >"$NM_STUB/gh" <<'NMGH'
#!/usr/bin/env bash
# Every API call the gate lets through is recorded here instead of made.
printf '%s\n' "$*" >>"$NM_GH_LOG"
NMGH
chmod +x "$NM_STUB/gh"
# Driven in a child shell with that stub first on PATH, rather than with a `gh`
# function in this one: a fixture that calls an engine function directly drags
# the engine's own dataflow into this file's static analysis, and the child
# keeps the two apart.
# `nm_pr` / `nm_log`, not `payload` / `gh_log`: a variable named `payload` in
# this file makes shellcheck read the unrelated `r1=payload-author` above as
# arithmetic (SC2100), and the suite is shellcheck-clean in CI.
nm_request() {  # nm_request <payload> <call-log> -> how many API calls it made
  local nm_pr="$1" nm_log="$2"
  : >"$nm_log"
  PATH="$NM_STUB:$PATH" NM_GH_LOG="$nm_log" ME="me-bot" MARK_ANSWERED="$RP_MARK" \
    DUTY_DIR="$NM_DUTY" LABEL_BOTS_REVIEWING="state:bots-reviewing" \
    bash -c 'set -uo pipefail
      # shellcheck disable=SC1090
      source "$1/lib/common.sh"
      # shellcheck disable=SC1090
      source "$1/lib/duty-builder.sh"
      _request_panel o/r 311 "$2" "$3" green "$4"' \
    nm_request "$SHARED" "$nm_pr" "$PANEL" "$H" >/dev/null 2>&1
  awk 'NF' "$nm_log" | wc -l | tr -d ' '
}
t near-miss-request-issues-no-review-request 0 \
  "$(nm_request "$NM_ONLY" "$TMP/near-miss-gh-calls")"
# The control: the same payload with a REAL signal in place of the near-miss
# does request, so the zero above is the near-miss being refused and not the
# harness being inert.
NM_REAL_ONLY="$(mk_rp "$H" '[]' '[]' \
  "$(jq -cn --arg b "$RP_MARK $H" '[{author:{login:"me-bot"},body:$b}]')")"
t near-miss-control-real-signal-does-request 3 \
  "$(nm_request "$NM_REAL_ONLY" "$TMP/near-miss-gh-calls-control")"

# The detection over a listing. Fixtures, never a live box (#319's test plan).
NM_LISTING="$(jq -cn --arg head "$NM_HEAD" --arg old "$NM_OLD" '[
  {number:311,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"5165639326",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:312,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $old),id:"222",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:313,isDraft:false,headRefOid:$head,comments:[]},
  {number:314,isDraft:true,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"444",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:315,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"555",
     createdAt:"2026-08-03T11:17:54Z"},
    {author:{login:"me"},body:("ANSWER " + $head),
     createdAt:"2026-08-03T11:32:08Z"}]},
  {number:316,isDraft:false,headRefOid:$head,comments:null}
]')"
# Called in THIS shell, never inside a command substitution: the answer comes
# back in a global, and a subshell's globals die with it. Its reports go to
# stdout like every other log line, so they are captured through a file.
_near_miss_resume_rows o/r me ANSWER "$NM_LISTING" >"$TMP/near-miss.log" 2>&1
nm_out="$(cat "$TMP/near-miss.log")"
# 311 alone: 312's near-miss names a SUPERSEDED head — its own push invalidated
# what it announced — 313 is genuine silence, 314 is a draft (the draft path
# already owns it), 315 signalled properly beside its near-miss, and 316's
# thread could not be read.
t near-miss-rows-only-the-current-head-case "$(printf '311\t5165639326')" \
  "$(printf '%s' "$NEAR_MISS_ROWS" | awk 'NF')"
# MUST FAIL — the bypass firing on genuine silence. #313 has no signal and no
# near-miss and must still wait the full twelve ticks; collapsing that threshold
# is a different decision with a different cost, and it is not #319's.
t near-miss-silence-is-not-a-near-miss 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^313')"
# MUST FAIL — a near-miss naming a stale head triggering the bypass.
t near-miss-stale-head-does-not-bypass 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^312')"
# ...and all four of those PRs are still stranded the ordinary way, so the
# bypass adds a reason to be due and never removes one.
t near-miss-non-bypassed-still-stranded "$(printf 'o/r#311@%s\no/r#312@%s\no/r#313@%s' \
    "$NM_HEAD" "$NM_HEAD" "$NM_HEAD")" \
  "$(printf '%s' "$NM_LISTING" | _stranded_resume_keys o/r me ANSWER)"
# EXACTLY ONE WARN per detection, naming the PR, the head in full, and the
# comment id — the three things a reader needs to find the malformed comment.
t near-miss-warns-once 1 "$(grep -c 'WARN.*o/r#311' <<<"$nm_out")"
t near-miss-warn-names-the-head 1 "$(grep -c "$NM_HEAD" <<<"$nm_out")"
t near-miss-warn-names-the-comment 1 "$(grep -c '5165639326' <<<"$nm_out")"
t near-miss-warn-is-silent-about-the-rest 1 "$(grep -c 'WARN' <<<"$nm_out")"
# MUST FAIL — the malformed comment edited, hidden or deleted. The board record
# is the only trace this class leaves; a fix that tidies it destroys the
# evidence. The detection makes NO GitHub write of any kind: it reads the
# listing it was handed and warns.
nm_body="$(declare -f _near_miss_resume_rows)"
t near-miss-detection-makes-no-github-call 0 "$(grep -c 'gh ' <<<"$nm_body")"
if grep -Fq 'LEAVE THE MALFORMED COMMENT WHERE IT IS' "$SHARED/prompts/resume.txt" \
  && grep -Fq 'do not edit it, hide it, delete it' "$SHARED/prompts/resume.txt"; then
  r1=left-alone
else
  r1=TIDIED
fi
t near-miss-prompt-leaves-the-comment-alone left-alone "$r1"
# MUST FAIL — a second definition of the marker. A hand-rolled brace match or a
# marker comparison inside duty-builder.sh is exactly what answered-head.jq's
# header warns about; both predicates live in jq, and the shell only calls them.
t near-miss-no-hand-rolled-slot-match-in-the-engine 0 \
  "$(grep -c 'MARK_[A-Z]*}}' "$SHARED/lib/duty-builder.sh")"
t near-miss-has-one-placeholder-parser 1 \
  "$(grep -l 'MARK_\[A-Z0-9_\]' "$SHARED"/lib/jq/*.jq | wc -l | tr -d ' ')"
# The predicate is its own file, never a fallback branch inside answered-head.jq:
# a fallback there is how placeholder text becomes wire protocol.
t near-miss-not-a-branch-of-the-signal-parser 0 \
  "$(grep -c 'MARK_\[A-Z0-9_\]' "$SHARED/lib/jq/answered-head.jq")"
# MUST FAIL — the state file's format changing. `.resume-unsignalled.<slug>` is
# written by a live fleet, and a format change strands every counter on every
# box at upgrade. The bypass rides BESIDE _stranded_resume_due, never through
# it: same threshold, same call, same two-column state file, and its tests above
# run unmodified.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_stranded_resume_due "$DUTY_DIR/.resume-unsignalled.$slug" 12' \
     "$SHARED/lib/duty-builder.sh"; then r1=threshold-intact; else r1=DISTURBED; fi
t near-miss-threshold-call-unchanged threshold-intact "$r1"
NM_STATE="$TMP/resume-unsignalled-319"
printf 'o/r#311@%s\n' "$NM_HEAD" | _stranded_resume_due "$NM_STATE" 12 >/dev/null
t near-miss-state-file-format-unchanged "o/r#311@$NM_HEAD	1" "$(cat "$NM_STATE")"
# The near-miss PR's counter advances exactly as any other stranded PR's does:
# the bypass adds a second, independent reason to be due, and takes nothing
# away from the evidence the threshold path is accumulating.
printf 'o/r#311@%s\n' "$NM_HEAD" | _stranded_resume_due "$NM_STATE" 12 >/dev/null
t near-miss-counter-still-advances "o/r#311@$NM_HEAD	2" "$(cat "$NM_STATE")"

# The listing stopped carrying comments at 70823ac (#314) and `.comments // []`
# read the absence as an empty thread, so every non-draft authored PR has
# classified as unsignalled since. The signal half is read per PR now; these pin
# the route and the reason it is not the listing's own connection.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'gh api --paginate "repos/$repo/issues/$num/comments?per_page=100"' \
     "$SHARED/lib/duty-builder.sh"; then r1=paginated; else r1=CAPPED; fi
t near-miss-comments-read-is-paginated paginated "$r1"
# A thread that could not be read is NOT an empty thread: the PR leaves the
# stranded set for the tick rather than accruing toward a resume the evidence
# does not support.
t near-miss-unread-thread-is-not-stranded "" \
  "$(printf '%s' "$NM_LISTING" | jq -c '[.[] | select(.number == 316)]' \
     | _stranded_resume_keys o/r me ANSWER)"
t near-miss-unread-thread-is-not-a-detection 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^316')"
# The wake path: the rows reach the resume prompt, and the prompt tells the
# session what the comment it is looking at actually is.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'NEAR_MISS="${near_miss_desc:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{NEAR_MISS}}' "$SHARED/prompts/resume.txt"; then r1=wired; else r1=UNWIRED; fi
t near-miss-wired-into-the-resume-prompt wired "$r1"
if grep -Fq 'OPENS WITH AN UNRENDERED TEMPLATE SLOT' "$SHARED/prompts/resume.txt"; then
  r1=explained
else
  r1=MISSING
fi
t near-miss-prompt-explains-the-comment explained "$r1"

# --- #314: the doable-work gate on resume dispatch --------------------------
# Resume was the one wake with no doable-work condition — it fired on "is there
# a draft", and a park is invisible to that. PR #311 spent 58 sessions at one
# head across 4h45m with zero commits, and every comment on it was the
# builder's own. These fixtures ARE that incident: the self comment advances
# every tick, which is what makes an "anything changed" fingerprint re-arm
# itself and suppress nothing.
RG_HEAD=9ff004ac9ff004ac9ff004ac9ff004ac9ff004ac
RG_HEAD2=1782445178244517824451782445178244517824
RG_DUTY="$TMP/resume-gate"; RG_LOG="$TMP/resume-gate.log"
RG_SPEECH="$TMP/resume-speech"
mkdir -p "$RG_DUTY" "$RG_SPEECH"
# THE ACTIVITY THE STUBBED API SERVES, one file per PR number, `login<TAB>stamp`
# per line — the shape _resume_newest_foreign consumes. It is a FILE and not a
# variable on purpose: the call sites below wrap rg_listing in a command
# substitution, and a subshell's variables die with it while its files do not.
rg_say() {  # rg_say NUM comments|reviews [LOGIN TS]...
  local f="$RG_SPEECH/$1.$2"; shift 2
  : >"$f"
  while [ "$#" -ge 2 ]; do
    [ -n "$2" ] && printf '%s\t%s\n' "$1" "$2" >>"$f"
    shift 2
  done
  return 0
}
rg_listing() {  # rg_listing HEAD NEWEST-SELF-TS NEWEST-FOREIGN-TS BODY
  # No `comments`/`reviews` in the listing, because the engine no longer asks
  # for them: those nested connections are `first: 100` and never paginate, so
  # the foreign half is read from the paginated REST endpoints instead.
  rg_say 311 comments me "$2" other "$3"
  rg_say 311 reviews
  rg_say 999 comments
  rg_say 999 reviews
  jq -cn --arg head "$1" --arg body "$4" '[
    { number: 311, isDraft: true, headRefOid: $head, body: $body },
    { number: 999, isDraft: false, headRefOid: $head, body: "Closes #99" }
  ]'
}
RG_ISSUE_TS="2026-08-01T00:00:00Z"
RG_GH_FAIL=""   # "", "issue", "foreign" or "all"
# shellcheck disable=SC2317  # called indirectly by _resume_gate
gh() {
  # Joined FIRST: `${*##pat}` strips element-wise and only then joins, which
  # silently parsed the wrong number out of the comments URL.
  local args="$*" n kind
  case "$args" in
    */comments*|*/reviews*)
      case "$RG_GH_FAIL" in foreign|all) return 1 ;; esac
      case "$args" in */comments*) kind=comments ;; *) kind=reviews ;; esac
      n="${args##*/issues/}"; n="${n##*/pulls/}"; n="${n%%/*}"
      [ -f "$RG_SPEECH/$n.$kind" ] || return 0
      # THE PAGE BOUNDARY IS HONOURED, and that is the point of this stub. A
      # JSON fixture cannot reproduce a GraphQL connection's cap, but a REST
      # page is exactly reproducible: without `--paginate` the caller gets the
      # FIRST page and nothing after it. That makes the deep-thread cases below
      # behavioural must-fails rather than assertions about source text.
      case "$args" in
        *--paginate*) cat "$RG_SPEECH/$n.$kind" ;;
        *) head -100 "$RG_SPEECH/$n.$kind" ;;
      esac
      return 0 ;;
    *)
      case "$RG_GH_FAIL" in issue|all) return 1 ;; esac
      printf '%s\n' "$RG_ISSUE_TS" ;;
  esac
  return 0
}
# shellcheck disable=SC2031  # breaker fixtures above intentionally isolate DUTY_DIR in subshells
RG_SAVED_DUTY="$DUTY_DIR"; RG_SAVED_ME="${ME-}"; RG_ME_WAS_SET="${ME+x}"
DUTY_DIR="$RG_DUTY"; ME=me
rg_reset() { rm -f "$RG_DUTY/.seen-resume" "$RG_DUTY/.resume-zero-action.o__r"; }
rg_tick() {  # rg_tick LISTING [SESSION-RC] — one duty tick, caller side included
  # Cleared, not assumed: against a tree without the gate this keeps `set -u`
  # from taking the whole suite down, so each case below reports its own FAIL
  # rather than the run dying at the first one.
  RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
  _resume_gate o/r o__r "$1" >"$RG_LOG" 2>&1 || true
  if [ "${2:-0}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
    printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$RG_DUTY/.seen-resume"
  fi
}

# The pure half first: one line per DRAFT, the issue read from the body and
# never from a branch name. The foreign half is NOT here — see the block below.
t resume-fp-one-line-per-draft \
  "o/r#311@$RG_HEAD	290" \
  "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z 2026-08-02T19:20:37Z 'Closes #290' \
     | _resume_pr_fingerprints o/r)"
# Body forms: Refs is the post-merge citation, Part of is CROSS-repo and must
# not be mistaken for a local issue, and a body with neither degrades to the PR
# half rather than erroring.
rg_ref() { rg_listing "$RG_HEAD" T '' "$1" | _resume_pr_fingerprints o/r | cut -f2; }
t resume-fp-body-refs 314 "$(rg_ref 'Refs #314')"
t resume-fp-body-closes 290 "$(rg_ref 'Closes #290')"
t resume-fp-body-cross-repo-ignored "" "$(rg_ref 'Part of heavy-duty/crew#280')"
t resume-fp-body-bare-hash-ignored "" "$(rg_ref 'see #280 for the epic')"
t resume-fp-body-none-degrades "" "$(rg_ref 'no reference at all')"
# The word boundary: without it `discloses` ends in `closes` and this body
# declares a wake on an issue nobody named, costing a gh call every tick.
t resume-fp-body-word-boundary "" "$(rg_ref 'the operator discloses #99 in passing')"
t resume-fp-body-boundary-keeps-real-refs 290 "$(rg_ref 'and so, Closes #290')"

# THE FOREIGN HALF, at any thread length. `gh pr list --json comments,reviews`
# generates `comments(first: 100)` and does not paginate it, so reading the
# newest foreign activity from the listing froze it at the newest of the first
# hundred — measured on the incident PR itself, which is past that mark.
rg_say 311 comments me 2026-08-03T00:05:52Z other 2026-08-02T19:20:37Z
rg_say 311 reviews
t resume-nf-excludes-me 2026-08-02T19:20:37Z "$(_resume_newest_foreign o/r 311 me)"
# Nobody else has spoken: empty, which the gate floors to `0` — a stamp that
# sorts below any ISO one and keeps the ledger line at NF>=2.
rg_say 311 comments me 2026-08-03T00:05:52Z
t resume-nf-nobody-spoke "" "$(_resume_newest_foreign o/r 311 me)"
# A foreign REVIEW counts the same as a foreign comment, and comes from the
# other endpoint — the reviews connection is capped identically.
rg_say 311 comments me 2026-08-03T00:00:00Z
rg_say 311 reviews other 2026-08-02T20:00:00Z
t resume-nf-foreign-review 2026-08-02T20:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# The newest wins across both endpoints, not the last one read.
rg_say 311 comments other 2026-08-04T00:00:00Z
rg_say 311 reviews other 2026-08-02T20:00:00Z
t resume-nf-newest-across-endpoints 2026-08-04T00:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# THE 100-CAP REGRESSION, behavioural. 130 of my own comments, then the foreign
# one that must wake it: any lookup that reads only a first page — the capped
# listing connection, or a `per_page=1` REST read, whose `sort`/`direction` this
# endpoint ignores — answers with one of MY stamps and the draft never wakes.
: >"$RG_SPEECH/311.comments"
for _i in $(seq 1 130); do
  printf 'me\t2026-08-03T00:%02d:00Z\n' "$(( _i % 60 ))" >>"$RG_SPEECH/311.comments"
done
printf 'other\t2026-08-04T09:00:00Z\n' >>"$RG_SPEECH/311.comments"
rg_say 311 reviews
t resume-nf-past-the-hundredth 2026-08-04T09:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# A lookup that FAILS is not a lookup that found nothing: nonzero, so the gate
# can say so rather than silently flooring the fingerprint.
RG_GH_FAIL=foreign
t resume-nf-failure-is-nonzero 1 "$(_resume_newest_foreign o/r 311 me >/dev/null 2>&1; echo $?)"
RG_GH_FAIL=""

# 1. THE FLOOD, reproduced and then impossible. Three consecutive ticks whose
# only new comments are the builder's own marker and checkpoint. Pre-fix this
# dispatches three times; post-fix the cold ledger dispatches once and the next
# two are suppressed and SAID (#59: stop paying, do not stop saying).
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-02T19:20:37Z '' 'Closes #290')"
t resume-gate-cold-dispatches-once 311 "$RESUME_DISPATCH_NUMS"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-02T19:25:41Z '' 'Closes #290')"
t resume-gate-self-comment-suppressed "" "$RESUME_DISPATCH_NUMS"
t resume-gate-suppression-is-logged 1 \
  "$(grep -c "no resume duty: o/r#311 unchanged at $RG_HEAD" "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z '' 'Closes #290')"
t resume-gate-self-comment-still-suppressed "" "$RESUME_DISPATCH_NUMS"
t resume-gate-suppression-logged-every-tick 1 \
  "$(grep -c "no resume duty: o/r#311 unchanged at $RG_HEAD" "$RG_LOG")"
# A non-draft PR is not this gate's business at all.
t resume-gate-ignores-non-drafts 0 "$(grep -c 'o/r#999' "$RG_LOG")"

# 2. A FOREIGN comment wakes it, and the ledger advances.
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-foreign-comment-wakes 311 "$RESUME_DISPATCH_NUMS"
t resume-gate-ledger-advanced 1 \
  "$(grep -c "^o/r#311@$RG_HEAD 2026-08-03T01:00:00Z$" "$RG_DUTY/.seen-resume")"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-foreign-comment-once "" "$RESUME_DISPATCH_NUMS"

# 3. A PUSH wakes it even when no one else has spoken. The head is in the ID,
# so this holds however the two SHAs happen to sort — the ci-red lesson (#17).
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-push-wakes 311 "$RESUME_DISPATCH_NUMS"

# 4. AN ISSUE-SIDE WAKE, with the PR untouched — the #311/#290 shape, where the
# wake that lifts the park lands off the PR entirely.
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-issue-quiet-suppressed "" "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-03T10:18:04Z"
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-issue-wake-dispatches 311 "$RESUME_DISPATCH_NUMS"
# A body naming no local issue cannot be woken from the issue side, and must
# still be gated rather than erroring: the clock moves, the draft stays quiet.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T02:00:00Z '' 'no reference at all')"
t resume-gate-no-ref-cold-dispatches 311 "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-04T00:00:00Z"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T03:00:00Z '' 'no reference at all')"
t resume-gate-no-ref-degrades-to-pr-half "" "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-01T00:00:00Z"
# An issue lookup that fails degrades the same way and says so rather than
# silently pinning the fingerprint to the PR half.
RG_GH_FAIL=issue
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')"
t resume-gate-issue-fetch-failure-warns 1 \
  "$(grep -c 'issue #290 lookup failed for the resume fingerprint' "$RG_LOG")"
t resume-gate-issue-fetch-failure-still-dispatches 311 "$RESUME_DISPATCH_NUMS"
# So does a FOREIGN lookup that fails — and it must be its own line, because the
# two halves degrade to each other and a human reading duty.log needs to know
# which one went dark.
RG_GH_FAIL=foreign
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')"
t resume-gate-foreign-fetch-failure-warns 1 \
  "$(grep -c 'the foreign-activity lookup failed for the resume fingerprint' "$RG_LOG")"
t resume-gate-foreign-fetch-failure-still-dispatches 311 "$RESUME_DISPATCH_NUMS"
# A failed foreign lookup floors to `0` for the tick, which HOLDS against a
# stored stamp rather than losing the wake: the real stamp returns next tick and
# still sorts greater than what the ledger holds.
RG_GH_FAIL=""
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
RG_GH_FAIL=foreign
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-gate-foreign-failure-holds "" "$RESUME_DISPATCH_NUMS"
RG_GH_FAIL=""
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-gate-foreign-failure-loses-no-wake 311 "$RESUME_DISPATCH_NUMS"

# 5. rc != 0 DOES NOT COMMIT the ledger: a session that fails re-dispatches on
# the next tick rather than losing the wake it never got to act on.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')" 1
t resume-gate-failed-session-dispatched 311 "$RESUME_DISPATCH_NUMS"
t resume-gate-failed-session-uncommitted 0 \
  "$(awk 'NF' "$RG_DUTY/.seen-resume" 2>/dev/null | wc -l | tr -d ' ')"
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')" 1
t resume-gate-failed-session-redispatches 311 "$RESUME_DISPATCH_NUMS"

# 6. THE BREAKER. Three consecutive dispatches at one head that produce no
# commit trip it: no fourth dispatch at that head, exactly one WARN, and a push
# resets the count to one. Foreign comments advance every tick here, so the
# ledger admits each one — this is precisely the case the ledger does NOT catch.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
t resume-breaker-first-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-at-one 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-breaker-second-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-at-two 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T03:00:00Z 'Closes #290')"
t resume-breaker-third-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-trips-once 1 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
# The WHOLE line, not a prefix: the declared wake is the half a human reads to
# know where the park expects its signal, and a prefix match let a `:+`/`:-`
# pair that printed the issue number twice through in review.
# ANCHORED at the end, deliberately: an unanchored match is a substring match,
# and the `:+`/`:-` pair this replaced printed `o/r#290290` — which a prefix
# assertion accepts.
# It also asserts only what is OBSERVED at trip time: the third dispatch is
# going out as this fires, so two are known commitless and the third has not run.
t resume-breaker-warn-names-pr-head-count 1 \
  "$(grep -c "WARN: o/r#311: resume dispatch 3 of 3 at head ${RG_HEAD:0:12} — the previous 2 produced no commit, and after this one resume is suppressed at this head until it moves (#314); declared wake: o/r#290\$" "$RG_LOG")"
t resume-breaker-warn-claims-no-unrun-session 0 \
  "$(grep -c '3 consecutive resume dispatches' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T04:00:00Z 'Closes #290')"
t resume-breaker-no-fourth-dispatch "" "$RESUME_DISPATCH_NUMS"
t resume-breaker-suppression-is-said 1 \
  "$(grep -c "breaker-suppressed at $RG_HEAD after 3 zero-action dispatches" "$RG_LOG")"
t resume-breaker-warns-only-once 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
# A push clears it: a new head is a new key, and the count starts at one.
rg_tick "$(rg_listing "$RG_HEAD2" T 2026-08-03T05:00:00Z 'Closes #290')"
t resume-breaker-push-clears-suppression 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-push-resets-count-to-one 1 \
  "$(awk -F'\t' -v k="o/r#311@$RG_HEAD2" '$1 == k {print $2}' "$RG_DUTY/.resume-zero-action.o__r")"
# A tick the LEDGER held must not reset the count: the breaker bounds
# consecutive DISPATCHES, and a quiet tick between two of them is not progress.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
t resume-breaker-quiet-tick-held "" "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-tick-preserves-count 1 \
  "$(awk -F'\t' -v k="o/r#311@$RG_HEAD" '$1 == k {print $2}' "$RG_DUTY/.resume-zero-action.o__r")"
# Three ticks at DIFFERENT heads must never trip it — the must-fail case.
rg_reset
rg_tick "$(rg_listing aaa1 T 2026-08-03T01:00:00Z 'Closes #290')"
rg_tick "$(rg_listing aaa2 T 2026-08-03T02:00:00Z 'Closes #290')"
rg_tick "$(rg_listing aaa3 T 2026-08-03T03:00:00Z 'Closes #290')"
t resume-breaker-different-heads-never-trip 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
t resume-breaker-different-heads-still-dispatch 311 "$RESUME_DISPATCH_NUMS"
# The state prunes: a key gone from the input (merged, closed, undrafted) does
# not accumulate forever.
t resume-breaker-state-prunes 1 "$(awk 'NF' "$RG_DUTY/.resume-zero-action.o__r" | wc -l | tr -d ' ')"

# 7. THE SUPPRESSED SET AND THE DISPATCHED SET PARTITION the draft set — no
# draft in both, none missing. The `suppressed-partitions` assertion above is
# the model; here it is asserted end to end, through the gate.
RG_TWO="$(jq -cn --arg h "$RG_HEAD" '[
  {number:1,isDraft:true,headRefOid:$h,body:""},
  {number:2,isDraft:true,headRefOid:$h,body:""}]')"
rg_reset
rg_say 1 comments; rg_say 1 reviews; rg_say 2 comments; rg_say 2 reviews
rg_tick "$RG_TWO"
# Only #2 is spoken to on the second tick, so the two sets must partition.
rg_say 2 comments other 2026-08-03T09:00:00Z
rg_tick "$RG_TWO"
t resume-gate-partition-dispatched 2 "$RESUME_DISPATCH_NUMS"
t resume-gate-partition-suppressed 1 "$(grep -c 'no resume duty: o/r#1 unchanged' "$RG_LOG")"
t resume-gate-partition-disjoint 0 "$(grep -c 'no resume duty: o/r#2 unchanged' "$RG_LOG")"

# 8. THE 100-CAP, END TO END THROUGH THE GATE. The draft is quiet on the ledger,
# and the one comment that must wake it sits past the hundredth — where the
# listing's capped connection cannot see it. This is the #311 shape after the
# flood: a builder that floods its own PR past 100 comments must not be left
# permanently unwakeable by anyone speaking on it.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:00:00Z '' 'Closes #290')"
t resume-gate-deep-thread-cold-dispatches 311 "$RESUME_DISPATCH_NUMS"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:30:00Z '' 'Closes #290')"
t resume-gate-deep-thread-then-quiet "" "$RESUME_DISPATCH_NUMS"
: >"$RG_SPEECH/311.comments"
for _i in $(seq 1 130); do
  printf 'me\t2026-08-03T00:%02d:00Z\n' "$(( _i % 60 ))" >>"$RG_SPEECH/311.comments"
done
printf 'other\t2026-08-04T09:00:00Z\n' >>"$RG_SPEECH/311.comments"
rg_say 311 reviews
RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
_resume_gate o/r o__r "$(jq -cn --arg h "$RG_HEAD" \
  '[{number:311,isDraft:true,headRefOid:$h,body:"Closes #290"}]')" >"$RG_LOG" 2>&1 || true
t resume-gate-wakes-past-the-hundredth 311 "$RESUME_DISPATCH_NUMS"

# 9. A BROKEN GATE FAILS OPEN AND SAYS SO. jq's stderr is no longer swallowed,
# and an unparseable listing returns nonzero so the caller keeps its pre-gate
# draft list. The alternative — empty globals, silently — is `no resume duty`
# forever with nothing warned, which is the #59 failure inside the fix for it.
rg_reset
RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
_resume_gate o/r o__r 'not json at all' >"$RG_LOG" 2>&1
t resume-gate-broken-filter-returns-nonzero 1 "$?"
t resume-gate-broken-filter-warns 1 \
  "$(grep -c 'the resume fingerprint filter failed' "$RG_LOG")"
t resume-gate-broken-filter-commits-nothing "" "${RESUME_COMMIT_LINES//[[:space:]]/}"
DUTY_DIR="$RG_SAVED_DUTY"
if [ -n "$RG_ME_WAS_SET" ]; then ME="$RG_SAVED_ME"; else unset ME; fi
unset -f gh

# 8. THE WIRING. Helper-level tests stay green if the dispatch site stops
# routing through the ledger, which is exactly how the flood would come back.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'ledger_filter "$DUTY_DIR/.seen-resume"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq 'ledger_suppressed "$DUTY_DIR/.seen-resume"' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=UNGATED
fi
t resume-gate-wired-through-the-ledger gated "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_resume_gate "$R" "$slug" "$resume_json"' "$SHARED/lib/duty-builder.sh"; then r1=wired; else r1=BYPASSED; fi
t resume-gate-wired-into-dispatch wired "$r1"
# The commit must stay rc-gated at the call site, not merely inside the helper.
# shellcheck disable=SC2016  # matching shell source literally
if grep -F -A2 'if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then' \
       "$SHARED/lib/duty-builder.sh" \
     | grep -Fq 'ledger_commit "$DUTY_DIR/.seen-resume"'; then
  r1='rc-gated'
else
  r1=UNCONDITIONAL
fi
t resume-gate-commit-is-rc-gated rc-gated "$r1"
# THE LISTING MUST NOT CARRY THE FOREIGN HALF. `gh pr list --json comments` /
# `--json reviews` generate `first: 100` nested connections that never paginate:
# the array is oldest-first and truncated, so `max` over it freezes at the
# newest of the first hundred and the draft becomes permanently unwakeable by
# anyone speaking on it. Measured on the incident PR — the listing returns
# exactly 100 comments for heavy-duty/crew#311 while the paginated REST endpoint
# has 124. A JSON fixture cannot reproduce a GraphQL cap, so this binds at the
# shape level: the capped fields must not be requested at all.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq -- '--json number,isDraft,headRefOid,body' "$SHARED/lib/duty-builder.sh" \
  && ! grep -Fq -- '--json number,isDraft,headRefOid,comments,reviews,body' "$SHARED/lib/duty-builder.sh"; then
  r1=uncapped
else
  r1='CAPPED-LISTING'
fi
t resume-gate-listing-omits-capped-connections uncapped "$r1"
# And the fingerprint filter must not read them either, however they arrive.
if grep -Eq '\.comments|\.reviews' \
     <(sed -n '/^_resume_pr_fingerprints()/,/^}/p' "$SHARED/lib/duty-builder.sh"); then
  r1='READS-LISTING-ARRAYS'
else
  r1=clean
fi
t resume-fp-does-not-read-listing-arrays clean "$r1"
# The replacement must actually paginate. A single page of either endpoint is
# not "the newest": `sort`/`direction` are not parameters of
# `GET /repos/{owner}/{repo}/issues/{n}/comments` — they belong to the
# repo-level `/issues/comments` list — so GitHub ignores them and a `per_page=1`
# read returns the OLDEST comment. Verified live on heavy-duty/crew#311.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq -- '--paginate "repos/$repo/issues/$num/comments?per_page=100"' \
     "$SHARED/lib/duty-builder.sh" \
  && grep -Fq -- '--paginate "repos/$repo/pulls/$num/reviews?per_page=100"' \
     "$SHARED/lib/duty-builder.sh"; then
  r1=paginated
else
  r1='SINGLE-PAGE'
fi
t resume-nf-lookup-is-paginated paginated "$r1"
# A gate that cannot run must not become a silent stall: the caller keeps its
# pre-gate draft list when _resume_gate returns nonzero (#59).
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'if _resume_gate "$R" "$slug" "$resume_json"; then' "$SHARED/lib/duty-builder.sh"; then
  r1='fails-open'
else
  r1='FAILS-CLOSED'
fi
t resume-gate-failure-fails-open fails-open "$r1"

# 9. THE PROMPT AND THE DOCTRINE STATE THE SAME RULE. The prompt must carry no
# instruction to comment that is unconditional on the session acting — a parked
# builder cannot obey both halves of a fork, and #311's builder correctly obeyed
# the prompt.
RG_PROMPT="$SHARED/prompts/resume.txt"
if grep -Fq 'For each draft PR: post one comment' "$RG_PROMPT"; then
  r1=UNCONDITIONAL
else
  r1=conditional
fi
t resume-prompt-marker-not-unconditional conditional "$r1"
if grep -Fq 'ONLY WHEN YOU ARE GOING TO ACT' "$RG_PROMPT" \
  && grep -Fq 'POST NOTHING AT ALL' "$RG_PROMPT"; then r1=gated; else r1=MISSING; fi
t resume-prompt-marker-gated-on-acting gated "$r1"
# The doctrine sentences themselves, quoted rather than paraphrased, so the
# two files can be read side by side.
#
# Compared on whitespace-NORMALISED text, never line by line. `.ceremony/` is
# machine-written by `docs-sync --fix` at whatever pin is vendored, so its
# prose REWRAPS on a bump that changes no word — and a line-based `grep -Fq`
# reads that rewrap as a divergence. That is half of how the 0.6.0 re-vendor
# reddened main (#363): the sentence had moved across a line break as well as
# changed wording, so re-syncing the prompt alone would still have failed here
# and invited the assertion to be gutted instead. Normalising costs nothing and
# leaves the real contract — same words, both files — exactly as strict.
# This clause stops before the Markdown emphasis around the preceding words.
assert_doctrine_quote "$RG_PROMPT" \
  'a resumption finding nothing changed posts nothing' \
  resume-prompt-quotes-the-doctrine
# This clause stops before the Markdown emphasis around `no open PR`.
assert_doctrine_quote "$RG_PROMPT" \
  'Each change owes one comment — the wait resolves or changes hands, the shape changes, the claim unparks.' \
  resume-prompt-quotes-each-change-doctrine
# The prompt citation includes its prose context, while the doctrine side must
# be the exact heading; neither asserted substring contains emphasis syntax.
assert_doctrine_quote "$RG_PROMPT" 'under Claiming:' \
  resume-prompt-cites-claiming-heading '## Claiming'

# Count every direct BUILDER doctrine slot in every prompt. In resume.txt the
# four occurrences are: bare opening reference; quotation attribution for the
# declaration/Claiming passage; bare acceptance reference; quotation
# attribution for the draft-flip passage. build.txt's two occurrences are bare
# governing/acceptance references. fragment-round-rules.txt's two occurrences
# are bare green-head/panel references. attention.txt, ci-red.txt,
# fragment-floor-envelope.txt, fragment-oneshot-rules.txt,
# fragment-unblockable.txt, fragment-wt-rules.txt, hygiene.txt, mention.txt,
# rebase.txt, review.txt, and triage.txt contain no direct occurrence.
declare -A doctrine_builder_occurrences=(
  [attention.txt]=0 [build.txt]=2 [ci-red.txt]=0
  [fragment-floor-envelope.txt]=0 [fragment-oneshot-rules.txt]=0
  [fragment-round-rules.txt]=2 [fragment-unblockable.txt]=0
  [fragment-wt-rules.txt]=0 [hygiene.txt]=0 [mention.txt]=0
  [rebase.txt]=0 [resume.txt]=4 [review.txt]=0 [triage.txt]=0
)
for doctrine_prompt in "$SHARED"/prompts/*.txt; do
  doctrine_prompt_name="$(basename "$doctrine_prompt")"
  doctrine_actual_count="$(grep -oF '{{DOCTRINE_BUILDER}}' "$doctrine_prompt" | wc -l)"
  t "doctrine-builder-occurrences-$doctrine_prompt_name" \
    "${doctrine_builder_occurrences[$doctrine_prompt_name]-UNCLASSIFIED}" \
    "$doctrine_actual_count"
done

# --- #384: three stuck states the resume gate could not leave ----------------
# A session finished a fix round on PR #381, pushed d4b8035, and parked waiting
# for `ci-floor` before signalling. `ci-floor` went green at ~07:52Z; the session
# was still parked at 08:38Z and the operator unstuck it by hand. There was no
# wake to be had: `_resume_newest_foreign` paginates comments and reviews, and a
# check conclusion is neither, so nothing in the fingerprint could move.
#
# These fixtures are that timeline, plus PR #386's — a ready, green, correctly
# signalled PR converted to draft six seconds into the request pass, which the
# handoff listing then skipped and the resume ledger then suppressed.
P384_HEAD=d4b8035d4b8035d4b8035d4b8035d4b8035d4b80
P384_OLD=aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22
P384_START=2026-08-06T07:41:19Z
P384_DONE=2026-08-06T07:52:18Z
p384_run() {  # p384_run CONCLUSION [COMPLETED] — one CheckRun in a rollup
  # The jq arg is `fin`, not `done`: shellcheck reads a bare `done` after --arg
  # as the loop keyword and warns (SC1010), and ci-shell runs it without a
  # severity floor, so a warning is a red job.
  #
  # THE RUNNING SHAPE IS `gh`'s, NOT A TIDIED ONE. A running CheckRun comes back
  # with `conclusion:""` and Go's ZERO TIME in `completedAt` — neither key is
  # ever absent, live on nodejs/node:
  #   {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z",
  #    "conclusion":"","name":"coverage-windows","status":"IN_PROGRESS",...}
  # The first cut of this fixture omitted both, which is the only reason a
  # `completedAt != ""` test for "has concluded" passed here while fabricating a
  # stamp on every real running check (#391 round 2, claude).
  jq -cn --arg c "$1" --arg fin "${2:-}" --arg started "$P384_START" \
    '[{__typename:"CheckRun", name:"ci-floor", workflowName:"ci-floor",
       status:(if $c == "" then "IN_PROGRESS" else "COMPLETED" end),
       conclusion:$c, startedAt:$started,
       completedAt:(if $fin == "" then "0001-01-01T00:00:00Z" else $fin end)}]'
}
P384_ZERO_TIME=0001-01-01T00:00:00Z
P384_GREEN="$(p384_run SUCCESS "$P384_DONE")"
P384_PENDING="$(p384_run "" "")"
P384_RED="$(p384_run FAILURE "$P384_DONE")"
p384_pr() {  # p384_pr NUM DRAFT ROLLUP SIGNAL-SHA REQUESTED-JSON
  jq -cn --argjson num "$1" --argjson draft "$2" --argjson roll "$3" \
    --arg head "$P384_HEAD" --arg sig "$4" --argjson req "${5:-[]}" \
    '{number:$num, isDraft:$draft, headRefOid:$head, body:"Closes #290",
      statusCheckRollup:$roll, reviewRequests:$req,
      comments:(if $sig == "" then []
                else [{author:{login:"me"}, body:("ANSWER " + $sig),
                       createdAt:"2026-08-06T07:39:00Z", id:"9001"}] end)}'
}

# 1. THE CONCLUSION STAMP. A CheckRun contributes only once it has finished, so
# a running check is no stamp at all — reading `startedAt` here would move the
# fingerprint when CI STARTS, which is the tick the session is still working
# through rather than the one it is waiting for.
P384_ONE="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_GREEN" '' )" '[$pr]')"
t p384-check-stamp-is-the-conclusion "$P384_DONE" "$(_resume_newest_check "$P384_ONE" 381)"
P384_RUNNING="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_PENDING" '')" '[$pr]')"
t p384-running-check-has-no-stamp "" "$(_resume_newest_check "$P384_RUNNING" 381)"
t p384-running-check-does-not-leak-startedAt 0 \
  "$(_resume_newest_check "$P384_RUNNING" 381 | grep -c "$P384_START")"
# …and does not leak the ZERO TIME either. `completedAt` is present-but-zero
# while a check runs, so "has concluded" is `.status == "COMPLETED"` and not a
# non-empty string. The three assertions above are one contract read three ways:
# a running check contributes NOTHING, neither a real start nor a fabricated
# end. A fabricated one sorts below every genuine stamp so it would never mask a
# conclusion — but it displaces the documented `0` floor, and the floor is what
# the gate's own comment promises a reader.
t p384-running-check-does-not-leak-the-zero-time 0 \
  "$(_resume_newest_check "$P384_RUNNING" 381 | grep -c "$P384_ZERO_TIME")"
t p384-running-fixture-carries-the-zero-time 1 \
  "$(printf '%s' "$P384_RUNNING" | grep -c "$P384_ZERO_TIME")"
# A RED check has concluded, and its stamp counts: the fingerprint's job is to
# say the head answered, not that it passed. Whether green or red is the
# due-predicates' question, two blocks down.
P384_FAILED="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_RED" '')" '[$pr]')"
t p384-red-check-still-concludes "$P384_DONE" "$(_resume_newest_check "$P384_FAILED" 381)"
# The NEWEST across several checks, not the last one read.
P384_MANY="$(jq -cn --arg h "$P384_HEAD" '[{number:381,isDraft:true,headRefOid:$h,body:"",
  reviewRequests:[],comments:[],statusCheckRollup:[
    {__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS",
     startedAt:"2026-08-06T07:00:00Z",completedAt:"2026-08-06T07:10:00Z"},
    {__typename:"CheckRun",name:"b",status:"COMPLETED",conclusion:"SUCCESS",
     startedAt:"2026-08-06T07:00:00Z",completedAt:"2026-08-06T07:52:18Z"}]}]')"
t p384-check-stamp-is-the-newest "$P384_DONE" "$(_resume_newest_check "$P384_MANY" 381)"
# A StatusContext has no completedAt at all, so its start stands in — but only
# where its state is TERMINAL. A PENDING context's stamp is when the wait began,
# and the rollup mixes the two shapes (head-checks.jq's header).
#
# THE KEY IS `startedAt`, WHICH GITHUB'S SCHEMA DOES NOT HAVE. `gh` requests
# StatusContext.createdAt and serialises it under its own `startedAt`, so
# `createdAt` never reaches a caller of `gh pr list --json statusCheckRollup`.
# Live on python/cpython:
#   {"__typename":"StatusContext","context":"CLA Signing",
#    "startedAt":"2026-08-06T15:09:40Z","state":"SUCCESS","targetUrl":""}
# The first cut of this fixture fabricated `createdAt`, so it passed against a
# shape that does not occur while the branch was dead against every real rollup
# — met for a repo whose checks are CheckRuns, crew's own among them, and unmet
# exactly where a legacy status concludes. That is head-checks.jq's #50 (its
# header, and `head-status-context-failure` above) transposed from grading to
# stamping, which is why this fixture is now `gh`'s output key for key
# (#391 round 2, codex and claude).
P384_CTX="$(jq -cn --arg h "$P384_HEAD" --arg s "$P384_DONE" '[{number:381,isDraft:true,
  headRefOid:$h,body:"",reviewRequests:[],comments:[],
  statusCheckRollup:[{__typename:"StatusContext",context:"legacy",state:"SUCCESS",
                      startedAt:$s,targetUrl:""}]}]')"
t p384-status-context-concludes "$P384_DONE" "$(_resume_newest_check "$P384_CTX" 381)"
# The negative was VACUOUS before the fix — there was no `createdAt` for the
# terminal-state gate to reject, so it could not fail. It is a real assertion
# for the first time here.
P384_CTX_WAIT="$(printf '%s' "$P384_CTX" | jq -c '.[0].statusCheckRollup[0].state = "PENDING" | .')"
t p384-pending-status-context-has-no-stamp "" "$(_resume_newest_check "$P384_CTX_WAIT" 381)"
# The `//` form, not a bare swap to `.startedAt`: `head-checks.jq`'s own idiom
# in `latest_checks`, so a fleet box whose `gh` serialises GitHub's key
# unrenamed still stamps rather than going quietly dead a second time.
P384_CTX_CREATED="$(printf '%s' "$P384_CTX" \
  | jq -c '.[0].statusCheckRollup[0] |= (.createdAt = .startedAt | del(.startedAt))')"
t p384-status-context-createdAt-still-concludes "$P384_DONE" \
  "$(_resume_newest_check "$P384_CTX_CREATED" 381)"
# No checks configured is not a conclusion either; the gate floors it to `0`.
P384_NOCI="$(jq -cn --argjson pr "$(p384_pr 381 true '[]' '')" '[$pr]')"
t p384-no-checks-no-stamp "" "$(_resume_newest_check "$P384_NOCI" 381)"
# A lookup that FAILED is not a lookup that found nothing — the
# _resume_newest_foreign contract, so the gate can warn rather than silently
# flooring a half it could not read.
t p384-check-lookup-failure-is-nonzero 1 \
  "$(_resume_newest_check "$P384_ONE" 999 >/dev/null 2>&1; echo $?)"

# MUST FAIL — a rollup fixture that is not the shape `gh` emits. Both halves of
# the round-2 defect were fixtures, not code: the code was a correct reading of
# a rollup nobody receives, and every test above passed against it. crew's own
# CI is a single CheckRun, so this repo's CI can never catch either one — the
# same reason head-checks.jq keeps `SC_BAD` and says so in its header. That
# makes a shape guard the only thing standing between this class and its next
# recurrence, and it is asserted on the fixtures as DATA rather than by reading
# the source, so a fixture built by transform is covered like a literal one.
p384_shape_lies() {  # p384_shape_lies ROLLUP — count nodes lying about `gh`
  printf '%s' "$1" | jq '[ .[] | select(
      # `gh` renames StatusContext.createdAt to `startedAt` on the way out, so a
      # fixture carrying createdAt is asserting against a shape that never
      # arrives — the dead branch, exactly.
      (.__typename == "StatusContext" and has("createdAt"))
      # A running CheckRun carries a present-but-zero completedAt, so a fixture
      # omitting the key lets a non-empty test for "has concluded" pass here and
      # fabricate a stamp in production — the half claude found, exactly.
      or (.__typename == "CheckRun" and (.status // "") != "COMPLETED"
          and ((has("completedAt") and .completedAt != null) | not))
    )] | length'
}
p384_rollup_of() { printf '%s' "$1" | jq -c '.[0].statusCheckRollup'; }
t p384-fixture-shape-green 0 "$(p384_shape_lies "$P384_GREEN")"
t p384-fixture-shape-pending 0 "$(p384_shape_lies "$P384_PENDING")"
t p384-fixture-shape-red 0 "$(p384_shape_lies "$P384_RED")"
t p384-fixture-shape-many 0 "$(p384_shape_lies "$(p384_rollup_of "$P384_MANY")")"
t p384-fixture-shape-status-context 0 "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX")")"
t p384-fixture-shape-pending-status-context 0 \
  "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX_WAIT")")"
t p384-fixture-shape-collision 0 "$(p384_shape_lies "$SC_COLLISION_STATUS_LAST")"
# The guard catches the shapes this round shipped broken, or it is decoration.
t p384-shape-guard-catches-status-createdAt 1 \
  "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX_CREATED")")"
t p384-shape-guard-catches-running-without-completedAt 1 \
  "$(p384_shape_lies "$(printf '%s' "$P384_PENDING" | jq -c 'map(del(.completedAt))')")"
# `P384_CTX_CREATED` is the ONE fixture that carries createdAt on purpose — it
# asserts the `//` fallback for a `gh` that does not rename the field — so it is
# named here rather than exempted quietly, and the assertion above is that the
# guard does see it. Every other fixture in this file is `gh`'s shape, which a
# literal scan says in one line and independently of the list above.
# The pattern is split across two lines on purpose: written whole it would
# match ITSELF and the guard would red on its own source.
P384_SC_LITERAL='__typename":"StatusContext"'
t p384-no-fixture-fabricates-status-createdAt 0 \
  "$(grep -c "$P384_SC_LITERAL"'.*createdAt":' "$SHARED/test/run.sh")"

# 2. THE CHECK STATE, graded through head-checks.jq and never restated here.
t p384-state-green "$(printf '381\tgreen')" "$(_resume_check_states o/r "$P384_ONE")"
t p384-state-pending "$(printf '381\tpending')" "$(_resume_check_states o/r "$P384_RUNNING")"
t p384-state-red "$(printf '381\tred')" "$(_resume_check_states o/r "$P384_FAILED")"
# Drafts are graded too, which head-checks.jq alone will not do — the flip-owed
# predicate's whole subject is a draft.
t p384-state-grades-drafts 1 "$(_resume_check_states o/r "$P384_ONE" | grep -c green)"
t p384-state-unreadable-is-nonzero 1 \
  "$(_resume_check_states o/r 'not json' >/dev/null 2>&1; echo $?)"
# MUST FAIL — a second copy of the green whitelist in this module. `is_green`
# is fail-closed by construction (#64) and a restatement of it here would be a
# second predicate that drifts the first time GitHub adds a conclusion.
t p384-green-is-not-restated-in-the-engine 0 \
  "$(grep -c 'SUCCESS.*NEUTRAL.*SKIPPED' "$SHARED/lib/duty-builder.sh")"

# 3. THE GREEN-HEAD DUE-PREDICATE. Its evidence is a check conclusion where
# #319's is a near-miss comment, and it reaches the same conclusion from it: the
# checks have finished, the head is passing, and there is nothing left to wait
# for, so the twelve ticks are no longer buying information.
P384_GH_LISTING="$(jq -cn \
  --argjson a "$(p384_pr 381 false "$P384_GREEN" '')" \
  --argjson b "$(p384_pr 382 false "$P384_PENDING" '')" \
  --argjson c "$(p384_pr 383 false "$P384_RED" '')" \
  --argjson d "$(p384_pr 384 false "$P384_GREEN" "$P384_HEAD")" \
  --argjson e "$(p384_pr 385 false "$P384_GREEN" "$P384_OLD")" \
  --argjson f "$(p384_pr 386 true "$P384_GREEN" '')" \
  --argjson g "$(p384_pr 387 false '[]' '')" \
  '[$a,$b,$c,$d,$e,$f,$g] | map(if .number == 388 then . else . end)')"
# #388: a thread that could not be read is not an empty thread.
P384_GH_LISTING="$(printf '%s' "$P384_GH_LISTING" | jq -c \
  --argjson h "$(p384_pr 388 false "$P384_GREEN" '')" '. + [$h | .comments = null]')"
_green_head_resume_rows o/r me ANSWER "$P384_GH_LISTING" >"$TMP/p384-green.log" 2>&1
p384_gh_out="$(cat "$TMP/p384-green.log")"
# 381 and 385 alone. 382 is PENDING and 383 is RED — the measured twelve-tick
# case, untouched; 384 signalled its current head; 386 is a draft (the draft
# path owns it); 387 has no checks configured, which is not green; 388's thread
# could not be read.
p384_gh_nums="$(printf '%s' "$GREEN_HEAD_ROWS" | awk -F'\t' 'NF{print $1}')"
t p384-green-head-rows "$(printf '381\n385')" "$p384_gh_nums"
# MUST FAIL, one per line — these are the regressions, and each is its own
# assertion so a failure names which guarantee broke rather than "the set moved".
t p384-pending-head-still-waits-twelve 0 "$(grep -c '^382$' <<<"$p384_gh_nums")"
t p384-red-head-still-waits-twelve 0 "$(grep -c '^383$' <<<"$p384_gh_nums")"
t p384-correct-signal-is-never-resumed 0 "$(grep -c '^384$' <<<"$p384_gh_nums")"
t p384-draft-is-not-this-predicates-business 0 "$(grep -c '^386$' <<<"$p384_gh_nums")"
t p384-no-checks-is-not-green 0 "$(grep -c '^387$' <<<"$p384_gh_nums")"
t p384-unread-thread-is-not-a-detection 0 "$(grep -c '^388$' <<<"$p384_gh_nums")"
# A signal naming a SUPERSEDED head is no signal at this head: 385 is due.
t p384-stale-signal-is-still-unsignalled 1 "$(grep -c '^385$' <<<"$p384_gh_nums")"
# THE HEAD RIDES WITH THE NUMBER, from this read and not a second one: the
# caller builds the breaker's `<repo>#<num>@<head>` key out of this row, and two
# reads of the listing are two chances to key a count to the wrong head.
t p384-green-row-carries-the-head "$(printf '381\t%s\n385\t%s' "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$GREEN_HEAD_ROWS" | awk 'NF')"
# EXACTLY ONE WARN per detection, naming the head in full and the reason.
t p384-green-warns-once-per-detection 2 "$(grep -c 'WARN' <<<"$p384_gh_out")"
t p384-green-warn-names-the-head 2 "$(grep -c "green and no signal names that head" <<<"$p384_gh_out")"
t p384-green-warn-carries-the-full-sha 2 "$(grep -c "$P384_HEAD" <<<"$p384_gh_out")"
t p384-green-warn-names-the-pr 1 "$(grep -c 'WARN.*o/r#381' <<<"$p384_gh_out")"
# DETECTION DOES NOT PROMISE A DISPATCH. Whether this tick actually resumes is
# the breaker's answer, said at the breaker's site — so the detection WARN must
# not carry the old "so resuming this tick instead of the twelfth" tail, which
# would be a claim this function cannot make once a bypass can be suppressed.
t p384-green-warn-does-not-promise-a-dispatch 0 \
  "$(grep -c 'resuming this tick' <<<"$p384_gh_out")"
# The bypass ADDS a reason to be due and removes none: both PRs it named are
# still stranded the ordinary way, their counters advancing exactly as before,
# and so are the three it declined to name. Five in total — 384 signalled its
# head, 386 is a draft and 388's thread could not be read, and none of those
# three was ever stranded.
t p384-green-bypassed-are-still-stranded "$(printf 'o/r#381@%s\no/r#385@%s' \
    "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER \
     | grep -E '#(381|385)@')"
t p384-green-declined-are-still-stranded "$(printf 'o/r#382@%s\no/r#383@%s\no/r#387@%s' \
    "$P384_HEAD" "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER \
     | grep -E '#(382|383|387)@')"
t p384-green-strands-nothing-new 5 \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER | wc -l | tr -d ' ')"
# FAIL-SOFT: a rollup that cannot be graded warns and leaves every PR out for
# the tick. It must NEVER fabricate a green — the whole predicate is an
# assertion about evidence, and inventing the evidence inverts it.
_green_head_resume_rows o/r me ANSWER 'not json' >"$TMP/p384-green-fail.log" 2>&1
t p384-green-ungradeable-detects-nothing "" "$(printf '%s' "$GREEN_HEAD_ROWS" | awk 'NF')"
t p384-green-ungradeable-warns 1 \
  "$(grep -c 'check rollup could not be graded' "$TMP/p384-green-fail.log")"

# 3b. THE GREEN-HEAD BOUND. Detection above answers "is this PR due"; the
# breaker answers "how many times may being due buy a session before the
# evidence is that the sessions produce nothing". The predicate holds no state
# of its own, so unbounded it would name the same PR every tick for as long as
# the head stood — a resume session every five minutes, indefinitely, which is
# the #314 flood re-entering through the door built to end it. That is this
# PR's own argument for bounding the flip-owed lane, and it is no weaker here:
# "non-draft, green head, no signal at that head" is a shape every PR passes
# through on the ordinary path between CI concluding and its builder signalling.
P384_GB="$TMP/p384-green-breaker"; P384_GB_LOG="$TMP/p384-green-breaker.log"
mkdir -p "$P384_GB"
P384_GB_SAVED_DUTY="$DUTY_DIR"; DUTY_DIR="$P384_GB"
p384_gb_tick() {  # p384_gb_tick ROWS — one tick of the bypass, caller side
  GREEN_HEAD_DISPATCH_NUMS=""
  _green_head_breaker o/r o__r "$1" >"$P384_GB_LOG" 2>&1 || true
}
P384_GB_ROWS="$(printf '381\t%s\n' "$P384_HEAD")"
for _p384_i in 1 2 3; do
  p384_gb_tick "$P384_GB_ROWS"
  t "p384-green-bypass-dispatch-$_p384_i" 381 "$GREEN_HEAD_DISPATCH_NUMS"
done
t p384-green-bypass-dispatch-is-said 1 \
  "$(grep -c "green head owed a signal .* dispatch 3 of 3 at $P384_HEAD" "$P384_GB_LOG")"
# The trip fires as the THIRD dispatch goes out and asserts only what is
# observed — the previous two produced nothing; the third has not run yet.
t p384-green-bypass-trips-once 1 \
  "$(grep -c 'the previous 2 produced no signal' "$P384_GB_LOG")"
# AND NO FOURTH. This is the assertion the round asked for.
p384_gb_tick "$P384_GB_ROWS"
t p384-green-bypass-no-fourth-dispatch "" "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-suppression-is-said 1 \
  "$(grep -c "green-head bypass suppressed at $P384_HEAD after 3 zero-action dispatches" "$P384_GB_LOG")"
# SUPPRESSION ENDS THE BYPASS, NOT THE PR'S CLAIM ON RESUME: the twelve-tick
# counter is a different lane with a different state file, and the suppression
# line says so rather than leaving a reader to infer the PR was abandoned.
t p384-green-bypass-suppression-names-the-other-lane 1 \
  "$(grep -c 'the twelve-tick counter still runs' "$P384_GB_LOG")"
# A PUSH ENDS THE EPISODE, with no separate observation of "produced no commit":
# the head is in the key, so a moved head is a key never seen.
p384_gb_tick "$(printf '381\t%s\n' "$P384_OLD")"
t p384-green-bypass-push-resets 381 "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-count-restarts-at-one 1 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
t p384-green-bypass-prunes-the-old-head 0 \
  "$(grep -c "@$P384_HEAD" "$P384_GB/.resume-zero-action-green.o__r")"
# THE TWO LANES DO NOT SHARE A STATE FILE, and this is why. _resume_breaker
# rebuilds its state from stdin alone and `mv`s it into place, so keys absent
# from a call are pruned (`resume-breaker-state-prunes` pins it deliberately).
# Two call sites on one file would therefore erase each other's counters every
# tick — the gate's drafts are not in the bypass's stdin, and the bypass's PRs
# are not in the gate's. Written through _resume_breaker itself, so this is the
# gate's own state file in the gate's own format.
printf 'o/r#999@%s\tfresh\n' "$P384_HEAD" \
  | _resume_breaker "$P384_GB/.resume-zero-action.o__r" 3 >/dev/null
p384_gb_tick "$(printf '381\t%s\n' "$P384_OLD")"
t p384-green-bypass-leaves-the-gate-counters 1 \
  "$(awk -F'\t' -v k="o/r#999@$P384_HEAD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action.o__r")"
t p384-green-bypass-keeps-its-own-count 2 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
# A QUIET TICK DISPATCHES NOTHING AND RESETS NOTHING. The count is of
# consecutive DISPATCHES, not consecutive ticks — the breaker's own rule — so a
# tick with no rows returns early rather than rebuilding an empty state file.
p384_gb_tick ""
t p384-green-bypass-quiet-tick-is-empty "" "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-quiet-tick-keeps-the-count 2 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
DUTY_DIR="$P384_GB_SAVED_DUTY"
unset -f p384_gb_tick

# 4. THE FLIP-OWED DUE-PREDICATE — the terminal state neither path can leave.
# PR #386 was ready, green and correctly signalled when it was converted to
# draft six seconds into the request pass. The request path stopped seeing it
# (the handoff listing is `select(.isDraft | not)`) and the resume ledger
# suppressed it (unchanged head, nobody foreign spoke). Both correct; together a
# hole, and no panel was ever requested.
P384_PANEL='["p1","p2"]'
P384_SIG_AT=2026-08-06T09:54:56Z
# The verdicts the stubbed GraphQL serves, one file per PR — a FILE for the same
# reason the #314 block's speech files are: the call sites wrap this in a command
# substitution and a subshell's variables die with it.
P384_GQL="$TMP/p384-gql"; mkdir -p "$P384_GQL"
p384_verdicts() {  # p384_verdicts NUM REQUESTED-JSON REVIEWS-JSON
  jq -cn --argjson req "$2" --argjson rev "$3" \
    '{requested:$req, reviews:$rev}' >"$P384_GQL/$1"
}
p384_review() {  # p384_review LOGIN STATE SUBMITTED [OID]
  jq -cn --arg l "$1" --arg s "$2" --arg at "$3" --arg oid "${4:-$P384_HEAD}" \
    '{author:{login:$l}, state:$s, submittedAt:$at, commit:{oid:$oid}}'
}
# shellcheck disable=SC2317  # called indirectly by _flip_owed_resume_rows
gh() {
  local args="$*" n f
  n="${args##*num=}"; n="${n%% *}"
  f="$P384_GQL/$n"
  [ -f "$f" ] || return 1
  jq -cn --arg head "$P384_HEAD" --arg sig "$P384_HEAD" --arg at "$P384_SIG_AT" \
    --argjson v "$(cat "$f")" \
    '{data:{repository:{pullRequest:{
        headRefOid:$head,
        comments:{nodes:[{author:{login:"me"}, body:("ANSWER " + $sig), createdAt:$at}]},
        reviewRequests:{nodes:($v.requested | map({requestedReviewer:{login:.}}))},
        latestOpinionatedReviews:{nodes:$v.reviews}}}}}'
}
p384_verdicts 386 '[]' '[]'
p384_verdicts 387 '["p1"]' '[]'
p384_verdicts 388 '[]' '[]'
p384_verdicts 389 '[]' '[]'
p384_verdicts 390 '[]' '[]'
p384_verdicts 391 '[]' '[]'
p384_verdicts 392 '["advisory-bot"]' '[]'
# 393 is the case that rewrote this predicate: a draft the ENGINE made, because
# a round closed against its author (_redraft_authored_pr), whose thread still
# carries the signal that opened that round. Both panelists answered it with
# CHANGES_REQUESTED at this head AFTER it was posted, and GitHub drops a
# change-requester from requested_reviewers in the same instant — so "nobody is
# on reviewRequests" is true of it, and it owes a ROUND REPLY, not a flip.
p384_verdicts 393 '[]' "$(jq -cn --argjson a "$(p384_review p1 CHANGES_REQUESTED 2026-08-06T10:30:00Z)" \
  --argjson b "$(p384_review p2 CHANGES_REQUESTED 2026-08-06T10:31:00Z)" '[$a,$b]')"
# 394 is its control: the same shape with the verdicts PRECEDING the signal, so
# the signal answers them and the panel is owed a re-read. #286's ordering rule,
# reached through request-panel.jq rather than restated here.
p384_verdicts 394 '[]' "$(jq -cn --argjson a "$(p384_review p1 CHANGES_REQUESTED 2026-08-06T09:00:00Z)" \
  --argjson b "$(p384_review p2 CHANGES_REQUESTED 2026-08-06T09:01:00Z)" '[$a,$b]')"
# 395: the whole panel already APPROVES this head. Nothing is owed of anyone, so
# nothing is requestable and this is a converged draft, not a stranded one.
p384_verdicts 395 '[]' "$(jq -cn --argjson a "$(p384_review p1 APPROVED 2026-08-06T10:30:00Z)" \
  --argjson b "$(p384_review p2 APPROVED 2026-08-06T10:31:00Z)" '[$a,$b]')"
P384_FO_LISTING="$(jq -cn \
  --argjson a "$(p384_pr 386 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson b "$(p384_pr 387 true "$P384_GREEN" "$P384_HEAD" '[{"login":"p1"}]')" \
  --argjson c "$(p384_pr 388 true "$P384_GREEN" '')" \
  --argjson d "$(p384_pr 389 true "$P384_PENDING" "$P384_HEAD")" \
  --argjson e "$(p384_pr 390 false "$P384_GREEN" "$P384_HEAD")" \
  --argjson f "$(p384_pr 391 true "$P384_GREEN" "$P384_OLD")" \
  --argjson g "$(p384_pr 392 true "$P384_GREEN" "$P384_HEAD" '[{"login":"advisory-bot"}]')" \
  --argjson h "$(p384_pr 393 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson i "$(p384_pr 394 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson j "$(p384_pr 395 true "$P384_GREEN" "$P384_HEAD")" \
  '[$a,$b,$c,$d,$e,$f,$g,$h,$i,$j]')"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_FO_LISTING" >"$TMP/p384-flip.log" 2>&1
p384_fo_out="$(cat "$TMP/p384-flip.log")"
# 386, 392 and 394. 387 has a PANELIST requested, so the round is live and the
# move is someone else's. 388 carries no signal at all — ordinary interrupted
# work on its existing path. 389's head is pending. 390 is not a draft, so the
# request path can see it. 391's signal names a superseded head. 392's only
# requested reviewer is OFF-panel, which BUILDER.md rules advisory and never the
# ask. 393's signal was SPENT by the verdicts that answered it. 395 is converged.
t p384-flip-owed-rows "$(printf '386\n392\n394')" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
# 387 is deliberately PARTLY requested — p1 asked, p2 not. request-panel.jq
# still names p2 there, which is why the "nobody was ever asked" gate is its own
# test and not folded into that predicate: a panelist already reading the tree
# is a live round, and the next move is theirs rather than resume's.
t p384-requested-panelist-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^387$')"
t p384-unsignalled-draft-is-untouched 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^388$')"
t p384-pending-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^389$')"
t p384-non-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^390$')"
t p384-stale-signal-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^391$')"
t p384-advisory-reviewer-is-not-the-ask 1 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^392$')"
# MUST FAIL, and it is why this predicate asks request-panel.jq instead of
# reading `reviewRequests` itself. A draft the ENGINE redrafted over a closed
# round has no panelist requested and a current-head signal on its thread, so
# the obvious predicate names it — and the session would then be told to mark an
# UNANSWERED round ready-for-review. The spent-signal rule (#286) is what parts
# it from #386, and 394 next door proves the rule is the ordering and not merely
# "any verdict at the head".
t p384-spent-signal-draft-is-not-owed-a-flip 0 \
  "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^393$')"
t p384-answered-verdicts-are-still-owed-a-panel 1 \
  "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^394$')"
t p384-converged-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^395$')"
# The ledger keys the gate is handed, head included so a push ends the episode.
t p384-flip-owed-force-fresh-keys \
  "$(printf 'o/r#386@%s\no/r#392@%s\no/r#394@%s' "$P384_HEAD" "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$RESUME_FORCE_FRESH" | awk 'NF')"
t p384-flip-warns-once-per-detection 3 "$(grep -c 'WARN' <<<"$p384_fo_out")"
t p384-flip-warn-names-the-reason 3 \
  "$(grep -c 'the handoff was consumed, not completed' <<<"$p384_fo_out")"
t p384-flip-warn-carries-the-full-sha 3 "$(grep -c "$P384_HEAD" <<<"$p384_fo_out")"
# The WARN names the panel that is owed, which is the evidence a reader needs to
# tell this state from a converged one without opening the PR.
t p384-flip-warn-names-the-owed-panel 1 \
  "$(grep -c 'WARN.*o/r#386.*owing a panel (p1 p2)' <<<"$p384_fo_out")"
# DETECTED, NEVER HONOURED. The flip asserts the round was answered whole, which
# BUILDER.md rules the one judgement its author cannot delegate — so the WARN
# says so, and the predicate buys a session rather than performing the act. It
# computes exactly whom the engine WOULD request, and requests nobody.
t p384-flip-warn-leaves-the-flip-to-the-builder 3 \
  "$(grep -c 'The flip stays yours' <<<"$p384_fo_out")"
if tr -s '[:space:]' ' ' <"$ROOT/.ceremony/BUILDER.md" \
     | grep -Fq 'an engine may draft a PR but only the builder undrafts it'; then
  r1=agreed
else
  r1=DIVERGED
fi
t p384-flip-doctrine-still-says-so agreed "$r1"
# This complete clause contains no Markdown syntax, so it is the longest safe
# prompt-side comparison to pair beside the existing doctrine-only assertion.
assert_doctrine_quote "$RG_PROMPT" \
  'an engine may draft a PR but only the builder undrafts it' \
  resume-prompt-quotes-undraft-doctrine
# MUST FAIL — the engine flipping, requesting or labelling. Neither predicate
# writes to the board at all: no undraft, no reviewer, no label. The one GitHub
# call the flip predicate makes is a READ, pinned below.
p384_bodies="$(cat <(declare -f _green_head_resume_rows) <(declare -f _flip_owed_resume_rows))"
t p384-predicates-never-flip 0 \
  "$(grep -cE 'ready-for-review|--undraft|markPullRequestReadyForReview' <<<"$p384_bodies")"
t p384-predicates-never-request 0 \
  "$(grep -cE '_request_panel|--add-reviewer|requested_reviewers' <<<"$p384_bodies")"
t p384-predicates-never-label 0 \
  "$(grep -cE 'LABEL_|--add-label|/labels' <<<"$p384_bodies")"
t p384-predicates-never-mutate 0 "$(grep -c 'mutation' <<<"$p384_bodies")"
t p384-flip-makes-exactly-one-read 1 "$(grep -c 'gh api graphql' <<<"$p384_bodies")"
# A verdict lookup that fails leaves that draft out for the tick rather than
# guessing — the same fail-soft direction as everything else on this path.
rm -f "$P384_GQL/386"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" \
  "$(jq -cn --argjson a "$(p384_pr 386 true "$P384_GREEN" "$P384_HEAD")" '[$a]')" \
  >"$TMP/p384-flip-gql-fail.log" 2>&1
t p384-flip-verdict-failure-detects-nothing "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
t p384-flip-verdict-failure-warns 1 \
  "$(grep -c 'verdict lookup failed' "$TMP/p384-flip-gql-fail.log")"
p384_verdicts 386 '[]' '[]'
# FAIL-SOFT on the rollup, the same contract as the green-head half.
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" 'not json' >"$TMP/p384-flip-fail.log" 2>&1
t p384-flip-ungradeable-detects-nothing "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
t p384-flip-ungradeable-forces-nothing "" "$(printf '%s' "$RESUME_FORCE_FRESH" | awk 'NF')"
t p384-flip-ungradeable-warns 1 \
  "$(grep -c 'check rollup could not be graded' "$TMP/p384-flip-fail.log")"
unset -f gh

# 5. THROUGH THE GATE. Its own DUTY_DIR and its own `gh` stub, in the shape the
# #314 block above establishes: the foreign half is served from files so a
# command substitution cannot lose it, and the issue half from a variable.
P384_DUTY="$TMP/p384-gate"; P384_LOG="$TMP/p384-gate.log"
P384_SPEECH="$TMP/p384-speech"
mkdir -p "$P384_DUTY" "$P384_SPEECH"
: >"$P384_SPEECH/381.comments"; : >"$P384_SPEECH/381.reviews"
: >"$P384_SPEECH/386.comments"; : >"$P384_SPEECH/386.reviews"
P384_ISSUE_TS="2026-08-01T00:00:00Z"
# shellcheck disable=SC2317  # called indirectly by _resume_gate
gh() {
  local args="$*" n kind
  case "$args" in
    *graphql*)
      # The flip-owed predicate's one read. Only #386 is signalled here, and it
      # is signalled with nobody requested and nobody having reviewed — the
      # state that PR was actually in when the draft consumed its handoff.
      n="${args##*num=}"; n="${n%% *}"
      [ "$n" = 386 ] || return 1
      jq -cn --arg head "$P384_HEAD" --arg at "$P384_SIG_AT" \
        '{data:{repository:{pullRequest:{
            headRefOid:$head,
            comments:{nodes:[{author:{login:"me"}, body:("ANSWER " + $head), createdAt:$at}]},
            reviewRequests:{nodes:[]},
            latestOpinionatedReviews:{nodes:[]}}}}}'
      return 0 ;;
    */comments*|*/reviews*)
      case "$args" in */comments*) kind=comments ;; *) kind=reviews ;; esac
      n="${args##*/issues/}"; n="${n##*/pulls/}"; n="${n%%/*}"
      [ -f "$P384_SPEECH/$n.$kind" ] && cat "$P384_SPEECH/$n.$kind"
      return 0 ;;
    *) printf '%s\n' "$P384_ISSUE_TS" ;;
  esac
  return 0
}
P384_SAVED_DUTY="$DUTY_DIR"; P384_SAVED_ME="${ME-}"; P384_ME_WAS_SET="${ME+x}"
DUTY_DIR="$P384_DUTY"; ME=me
p384_reset() {
  rm -f "$P384_DUTY/.seen-resume" "$P384_DUTY/.resume-zero-action.o__r"
  RESUME_FORCE_FRESH=""
}
p384_tick() {  # p384_tick LISTING — one duty tick, caller side included
  RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
  _resume_gate o/r o__r "$1" >"$P384_LOG" 2>&1 || true
  if [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
    printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$P384_DUTY/.seen-resume"
  fi
}
p384_draft() {  # p384_draft ROLLUP -> the one-draft listing #381 is
  jq -cn --argjson roll "$1" --arg head "$P384_HEAD" \
    '[{number:381,isDraft:true,headRefOid:$head,body:"Closes #290",
       statusCheckRollup:$roll,reviewRequests:[],comments:[]}]'
}

# THE #381 REPLAY. The session pushed d4b8035 and parked on `ci-floor`. Tick one
# is the cold ledger and dispatches; tick two is the same head with the check
# still running and nobody foreign speaking, and is correctly suppressed. Then
# `ci-floor` CONCLUDES at 07:52:18Z — and that is the tick the old engine could
# not see, because a check conclusion is neither a comment nor a review. It
# dispatches now, forty-six minutes and eleven ticks before the twelfth.
p384_reset
p384_tick "$(p384_draft "$P384_PENDING")"
t p384-replay-cold-dispatches 381 "$RESUME_DISPATCH_NUMS"
p384_tick "$(p384_draft "$P384_PENDING")"
t p384-replay-parked-on-a-running-check-is-quiet "" "$RESUME_DISPATCH_NUMS"
t p384-replay-quiet-tick-is-said 1 \
  "$(grep -c "no resume duty: o/r#381 unchanged at $P384_HEAD" "$P384_LOG")"
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-replay-the-conclusion-wakes-it 381 "$RESUME_DISPATCH_NUMS"
# ...and the ledger advanced to the conclusion stamp, so the value is what fired
# and not some coincidence of the other halves.
t p384-replay-ledger-carries-the-conclusion 1 \
  "$(grep -c "^o/r#381@$P384_HEAD $P384_DONE\$" "$P384_DUTY/.seen-resume")"
# THE ID IS UNTOUCHED. A check term in the id would mint an id never seen on
# every re-run and fire again on an unchanged tree; the head stays its whole
# content, exactly as the ci-red scheme requires (#17).
t p384-ledger-id-carries-only-the-head 1 \
  "$(awk '{print $1}' "$P384_DUTY/.seen-resume" | grep -cx "o/r#381@$P384_HEAD")"
# The value stays ALL ISO-8601, which is what makes a lexical max a
# chronological one — the invariant the fingerprint block's header states.
t p384-ledger-value-is-iso8601 1 \
  "$(awk '{print $2}' "$P384_DUTY/.seen-resume" \
     | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
# A RE-RUN of the same check does not re-fire. Its conclusion stamp is not newer
# than the one already committed, so the value does not sort greater and the
# ledger holds — which is the difference between a term in the value and a term
# in the id, asserted rather than argued.
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-rerun-of-the-same-check-does-not-refire "" "$RESUME_DISPATCH_NUMS"
# A LATER conclusion does: a rerun that finishes at a new time is new evidence.
P384_RERUN="$(p384_run SUCCESS 2026-08-06T09:30:00Z)"
p384_tick "$(p384_draft "$P384_RERUN")"
t p384-a-later-conclusion-refires 381 "$RESUME_DISPATCH_NUMS"

# FAIL-SOFT AT THE GATE. A check lookup that errors warns and drops that half
# for the tick; the other halves still decide, and no green is fabricated.
p384_reset
P384_REAL_CHECK="$(declare -f _resume_newest_check)"
# shellcheck disable=SC2317  # reinstated immediately below
_resume_newest_check() { return 1; }
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-check-failure-warns 1 \
  "$(grep -c 'check-conclusion lookup failed for the resume fingerprint' "$P384_LOG")"
t p384-check-failure-still-decides-on-the-rest 381 "$RESUME_DISPATCH_NUMS"
t p384-check-failure-fabricates-no-stamp 0 \
  "$(grep -c "$P384_DONE" "$P384_DUTY/.seen-resume")"
eval "$P384_REAL_CHECK"

# THE #386 REPLAY. A draft carrying a valid signal at a green head with no panel
# requested: the head has not moved and nobody foreign has spoken, so the ledger
# is right to hold it and would hold it forever. The force-fresh override is
# what makes it due.
P384_386="$(jq -cn --argjson roll "$P384_GREEN" --arg head "$P384_HEAD" \
  '[{number:386,isDraft:true,headRefOid:$head,body:"Closes #291",
     statusCheckRollup:$roll,reviewRequests:[],
     comments:[{author:{login:"me"},body:("ANSWER " + $head),
                createdAt:"2026-08-06T09:54:56Z",id:"9002"}]}]')"
p384_reset
p384_tick "$P384_386"
t p384-386-cold-dispatches 386 "$RESUME_DISPATCH_NUMS"
# THE CONTROL: without the override the second tick is suppressed, which is the
# state #386 actually sat in. This assertion is what makes the next one mean
# something — it shows the ledger genuinely holds this shape.
p384_tick "$P384_386"
t p384-386-ledger-would-hold-it-forever "" "$RESUME_DISPATCH_NUMS"
t p384-386-hold-is-said 1 \
  "$(grep -c "no resume duty: o/r#386 unchanged at $P384_HEAD" "$P384_LOG")"
# Now the predicate speaks, and the same unchanged tick becomes due.
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
p384_tick "$P384_386"
t p384-386-force-fresh-makes-it-due 386 "$RESUME_DISPATCH_NUMS"
# BOUNDED. The override rides _resume_breaker rather than going around it: three
# consecutive zero-action dispatches at one head and no fourth. An unbounded
# bypass would dispatch every five minutes for as long as the draft stood, which
# is the #314 flood re-entering through the door built to end it.
#
# The COUNTER is reset here and the LEDGER deliberately is not, so all three
# dispatches below are the override's own — with the ledger left holding, a
# dispatch can have no other cause, and the bound is measured on exactly the
# path this PR adds rather than on the cold-start it inherits.
rm -f "$P384_DUTY/.resume-zero-action.o__r"
for _p384_i in 1 2 3; do
  _flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
  p384_tick "$P384_386"
  t "p384-386-override-dispatch-$_p384_i" 386 "$RESUME_DISPATCH_NUMS"
done
t p384-386-breaker-trips-once 1 \
  "$(grep -c 'produced no commit, and after this one' "$P384_LOG")"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
p384_tick "$P384_386"
t p384-386-no-fourth-dispatch "" "$RESUME_DISPATCH_NUMS"
t p384-386-breaker-suppression-is-said 1 \
  "$(grep -c "breaker-suppressed at $P384_HEAD after 3 zero-action dispatches" "$P384_LOG")"
# A PUSH ends the episode: the signal at the old head is no longer at the head,
# so the predicate stops naming it and the ordinary path takes over.
P384_386_MOVED="$(printf '%s' "$P384_386" | jq -c --arg h "$P384_OLD" '.[0].headRefOid = $h | .')"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386_MOVED" >/dev/null 2>&1
t p384-386-push-ends-the-episode "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
DUTY_DIR="$P384_SAVED_DUTY"
if [ -n "$P384_ME_WAS_SET" ]; then ME="$P384_SAVED_ME"; else unset ME; fi
unset -f gh
RESUME_FORCE_FRESH=""

# 6. THE WIRING. Helper-level tests stay green if the dispatch site stops
# consulting either predicate, which is exactly how these stalls come back.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_green_head_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$resume_json"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '_flip_owed_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$panel_json" "$resume_json"' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=UNWIRED
fi
t p384-predicates-wired-into-the-tick wired "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'GREEN_HEAD="${green_head_nums:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{GREEN_HEAD}}' "$RG_PROMPT" \
  && grep -Fq 'FLIP_OWED="${flip_owed_nums:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{FLIP_OWED}}' "$RG_PROMPT"; then
  r1=wired
else
  r1=UNWIRED
fi
t p384-reasons-reach-the-resume-prompt wired "$r1"
# The prompt must hand the flip BACK to the builder rather than instructing the
# session to rubber-stamp it: the judgement is the whole reason a session is
# bought instead of the engine acting.
if grep -Fq 'THE FLIP IS YOURS AND ONLY YOURS' "$RG_PROMPT"; then r1=owned; else r1=DELEGATED; fi
t p384-prompt-keeps-the-flip-with-the-builder owned "$r1"
# The green-head reason rides BESIDE the threshold — #319's assertions on
# _stranded_resume_due's call, threshold and state-file format above run
# unmodified, and this pins the union that adds the second reason — and THROUGH
# the breaker, which is the half a helper-level test cannot see. An earlier cut
# of this PR had the union alone, and this assertion as written then pinned the
# unbounded wiring rather than catching it; both halves are named now.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '"$stranded_nums" "$green_head_nums"' "$SHARED/lib/duty-builder.sh"; then
  r1=beside
else
  r1=THROUGH
fi
t p384-green-rides-beside-the-threshold beside "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_green_head_breaker "$R" "$slug" "$green_head_rows"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq 'green_head_nums="$GREEN_HEAD_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED
fi
t p384-green-also-rides-the-breaker bounded "$r1"
# ...on a state file of its own. A second call site against the gate's file
# would silently prune the gate's counters every tick, so the path is part of
# the wiring and not an implementation detail.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_resume_breaker "$DUTY_DIR/.resume-zero-action-green.$slug"' "$SHARED/lib/duty-builder.sh" \
  && [ "$(grep -cF '_resume_breaker "$DUTY_DIR/.resume-zero-action.$slug"' "$SHARED/lib/duty-builder.sh")" = 1 ]; then
  r1=separate
else
  r1=SHARED
fi
t p384-green-breaker-has-its-own-state-file separate "$r1"

# A ci-red session returning zero does not consume an unsettled same-head item.
# Red is terminal and remains one-shot; a moved head settles the old key and
# will independently enter under its new id if it is red.
CI_PENDING="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"aaa",statusCheckRollup:[{name:"ci",status:"IN_PROGRESS"}]}')"
CI_RED="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"aaa",statusCheckRollup:[{name:"ci",status:"COMPLETED",conclusion:"FAILURE"}]}')"
CI_MOVED="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"bbb",statusCheckRollup:[{name:"ci",status:"IN_PROGRESS"}]}')"
if printf '%s' "$CI_PENDING" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-pending-remains-retryable retry "$r1"
if printf '%s' "$CI_RED" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-red-remains-one-shot settled "$r1"
if printf '%s' "$CI_MOVED" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-moved-head-settles-old-key settled "$r1"

# The settle predicate must gate the ledger commit, not merely exist beside a
# post-session rollup re-read. Removing this condition restores the
# unconditional commit while leaving the fixture-level helper tests green.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '| _ci_red_rollup_settled "${red_key##*@}"; then' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=UNCONDITIONAL
fi
t ci-red-ledger-commit-is-settle-gated gated "$r1"

# `attention` remains a hand-written demand. Reads in duty-attention.sh are the
# wake mechanism and are allowed; engine label writes are not. Fold continued
# shell lines before looking for add/remove-label or labels[]= writes so moving
# an argument onto the next source line cannot evade the guard.
attention_writes="$(awk '
  FNR == 1 { logical = "" }
  {
    line = $0
    if (logical != "") line = logical line
    if (line ~ /\\[[:space:]]*$/) {
      sub(/\\[[:space:]]*$/, " ", line)
      logical = line
      next
    }
    logical = ""
    if (line !~ /^[[:space:]]*#/ &&
        line ~ /(--add-label|--remove-label|labels\[\])/ &&
        line ~ /(LABEL_ATTENTION|attention)/) print FILENAME ":" FNR ":" line
  }
' "$SHARED"/lib/*.sh "$SHARED"/bin/* 2>/dev/null)"
t engine-never-writes-attention-label "" "$attention_writes"

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

# --- #167: the dirty-worktree WARN, once per (worktree, dirt state) ----------
# Leaving a dirty worktree alone is right; saying so every five minutes for a
# week is not — that is how a WARN becomes wallpaper. Driven against a REAL
# linked worktree, because the fingerprint is `git status --porcelain` read
# inside one, and a fixture that only feeds text would not prove that.
WTBASE="$TMP/wt-base"
mkdir -p "$WTBASE"
git -C "$WTBASE" init -q
printf 'engine\n' >"$WTBASE/README.md"
git -C "$WTBASE" add README.md
git -C "$WTBASE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
WTDIR="$TMP/wt-build-9"
git -C "$WTBASE" worktree add "$WTDIR" -b build/9-x >/dev/null 2>&1
printf 'scratch\n' >"$WTDIR/untracked.txt"
WTLG="$TMP/seen-wt-dirty"

# The two assertions are each other's must-fail. A fix that keeps warning every
# tick fails the second; a fix that goes permanently silent after the first
# emission fails wt-dirty-new-dirt-rewarns below — and silence is the worse of
# the two, which is why both directions are pinned here.
W1="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
W2="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
t wt-dirty-first-pass-warns 1 "$(printf '%s\n' "$W1" | grep -c 'WARN')"
t wt-dirty-second-pass-silent "" "$W2"
# The message names the branch and the price, not just the state: the worktree
# holds its branch, and the failure lands later, on somebody else's build.
case "$W1" in *"build/9-x"*)             r1=named ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-branch named "$r1"
case "$W1" in *"already checked out"*)   r1=named ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-consequence named "$r1"
case "$W1" in *"0 modified, 1 untracked"*) r1=counted ;; *) r1=MISSING ;; esac
t wt-dirty-warn-names-the-dirt counted "$r1"

# Dirty in a NEW way is a new condition and is reported again.
printf 'more\n' >"$WTDIR/second.txt"
W3="$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
t wt-dirty-new-dirt-rewarns 1 "$(printf '%s\n' "$W3" | grep -c 'WARN')"
t wt-dirty-new-dirt-then-silent "" "$(_wt_hygiene_report "$WTLG" o/r build/9-x "$WTDIR")"
# One worktree's silence is not another's: branch and repo are both in the key,
# so a second stale worktree is not swallowed by the first one's report.
t wt-dirty-other-branch-still-warns 1 \
  "$(_wt_hygiene_report "$WTLG" o/r build/10-y "$WTDIR" | grep -c 'WARN')"
t wt-dirty-other-repo-still-warns 1 \
  "$(_wt_hygiene_report "$WTLG" o/other build/9-x "$WTDIR" | grep -c 'WARN')"

# The id carries the dirt and the value is a fixed sentinel — the ci-red scheme
# (#17), for the same reason. This is the negative control for the scheme NOT
# used: keyed the ordinary way, a new dirt state whose fingerprint sorts below
# the old one is suppressed, losing the report exactly when the condition
# changed.
WTNAIVE="$TMP/wt-naive"
printf 'o/r:build/9-x 999-77\n' | ledger_commit "$WTNAIVE"
t wt-dirt-naive-value-loses-new-dirt 0 \
  "$(printf 'o/r:build/9-x 111-88\n' | ledger_filter "$WTNAIVE" | n)"
t wt-dirt-id-distinguishes-dirt-shapes 2 \
  "$(printf '%s\n%s\n' "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" \
                       "$(_wt_dirt_id o/r build/9-x '?? b.txt')" | sort -u | n)"
t wt-dirt-id-stable-for-the-same-dirt 1 \
  "$(printf '%s\n%s\n' "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" \
                       "$(_wt_dirt_id o/r build/9-x 'M  a.txt')" | sort -u | n)"

# Wiring: the hygiene block reports through the ledger rather than warning flat,
# now by way of _wt_release, which owns the whole clean/preserve/force order.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '_wt_hygiene_report "$ledger" "$repo" "$branch" "$path"' "$BMOD"; then
  r1=ledgered
else
  r1=UNGUARDED
fi
t wt-dirty-warn-is-ledgered-in-module ledgered "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '_wt_release "$dir" "$R" "$wt_branch" "$wt_path" "$pr_num" "$DUTY_DIR/.seen-wt-dirty"' "$BMOD"; then
  r1=wired
else
  r1=UNWIRED
fi
t wt-hygiene-block-calls-release wired "$r1"
# The PR the record goes on comes from the lookup that decided the branch was
# done — one query, so the record can never name a different PR than the removal
# was decided on, and the rare refusal path costs no second API call.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq -- '--state all --json state,number' "$BMOD"; then r1=joined; else r1=SPLIT; fi
t wt-hygiene-lookup-carries-the-pr-number joined "$r1"
# #167's must-fail, in the amended form #168 gives it: not "no --force" but
# "no --force except as the confirmed consequence of a successful preservation
# push". One occurrence, and the ordering assertions below pin it to that one
# place. Comments are stripped first: the block above SAYS why the force is
# earned rather than reached for, and counting raw occurrences counts that
# sentence — a detector tripping on its own documentation, which this repo has
# now managed four separate times.
t wt-hygiene-force-removes-exactly-once 1 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c -- '--force')"
# ...and the clean path is untouched: removed, branch deleted, no warning.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq 'git -C "$dir" branch -D "$branch"' "$BMOD"; then r1=intact; else r1=MISSING; fi
t wt-clean-removal-path-intact intact "$r1"

# --- #168: preserve before removing ------------------------------------------
# Driven against real repositories — a real bare remote, a real clone, a real
# linked worktree — because every claim here is about what git actually did:
# what the pushed tree contains, whether the ref reached the REMOTE, and
# whether the worktree survived a push that failed. A text fixture proves none
# of that, and the defect this issue exists to prevent (a --force reached
# before the push confirms) is invisible to one.
P168="$TMP/p168"
mkdir -p "$P168"
P_BARE="" P_CLONE="" P_WT=""

_p168_fixture() { # $1=name -> a bare remote, a clone with origin, a worktree
  local name="$1"
  P_BARE="$P168/$name.git"; P_CLONE="$P168/$name"; P_WT="$P168/$name-wt"
  git init -q --bare "$P_BARE"
  git init -q "$P_CLONE"
  printf 'engine\n' >"$P_CLONE/README.md"
  printf 'ignored/\n' >"$P_CLONE/.gitignore"
  git -C "$P_CLONE" add -A
  git -C "$P_CLONE" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm fixture
  git -C "$P_CLONE" remote add origin "$P_BARE"
  git -C "$P_CLONE" worktree add "$P_WT" -b "build/$name" >/dev/null 2>&1
}

_p168_wip_refs() { git -C "$1" for-each-ref --format='%(refname)' refs/heads/wip | n; }

# The record's transport is post-once.sh, so the suite stubs it where the engine
# looks: BIN_DIR, pointed at this block's own bin and restored at the end. The
# stub records the (repo, number) it was called with and the exact body, which
# is what the dedup assertion below reads — post-once.sh's own idempotence is
# tested at post-once.sh; what is this module's to prove is that it hands over a
# body that does not change when nothing changed.
P168_BIN="$P168/bin"; mkdir -p "$P168_BIN"
export P168_PO_CALLS="$P168/po-calls" P168_PO_BODY="$P168/po-body" P168_PO_RC=0
: >"$P168_PO_CALLS"; : >"$P168_PO_BODY"
cat >"$P168_BIN/post-once.sh" <<'P168PO'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >>"$P168_PO_CALLS"
printf '%s' "$3" >"$P168_PO_BODY"
exit "${P168_PO_RC:-0}"
P168PO
chmod +x "$P168_BIN/post-once.sh"
P168_BIN_SAVED="$BIN_DIR"
BIN_DIR="$P168_BIN"

# The remote a preservation goes to. `fork` where the clone has one — the bot
# cannot write to upstream, and a push that is always refused earns no force
# and preserves nothing — else `origin`, the single-remote case, which the
# amended spec still describes ("a remote the pushing identity can actually
# write to"). Triage ruled the preference in on 2026-08-05: `origin` on a fleet
# box is unwritable, so the criterion as first written was unsatisfiable.
_p168_fixture remote-choice
t p168-remote-origin-when-alone origin "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote add fork "$P168/fork.git"
t p168-remote-prefers-fork fork "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote remove fork
git -C "$P_CLONE" remote remove origin
if _wt_preserve_remote "$P_CLONE" >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-remote-none-refuses refused "$r1"

# 1. Real uncommitted work: modified tracked AND untracked, ignored dirt left
# out. Asserted from the BARE repo throughout — the must-fail is a
# preservation that lands only locally, and reading the clone's own objects
# would pass while the remote holds nothing.
_p168_fixture dirty
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
P_STATUS_BEFORE="$(git -C "$P_WT" status --porcelain | sort)"
if P_OUT="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-dirty-preserved pushed "$r1"
t p168-ref-is-on-the-remote 1 "$(_p168_wip_refs "$P_BARE")"
P_REMOTE_TREE="$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty | sort)"
case "$P_REMOTE_TREE" in *untracked.txt*) r1=carried ;; *) r1=DROPPED ;; esac
t p168-ref-carries-untracked carried "$r1"
t p168-ref-carries-modified changed \
  "$(git -C "$P_BARE" show refs/heads/wip/build/dirty:README.md)"
case "$P_REMOTE_TREE" in *ignored/x*) r1=LEAKED ;; *) r1=excluded ;; esac
t p168-ref-excludes-ignored excluded "$r1"
# The capture is built in a scratch index, so the worktree it captured is
# byte-identical afterwards: nothing staged, nothing stashed, nothing checked
# out. A push that fails must leave the tree exactly as it was found, and this
# is the property that makes that true.
t p168-capture-leaves-worktree-untouched "$P_STATUS_BEFORE" \
  "$(git -C "$P_WT" status --porcelain | sort)"
t p168-capture-leaves-content-untouched 'rescue me' "$(cat "$P_WT/untracked.txt")"

# Idempotence: the same dirt preserved twice is one ref at one sha. The second
# pass reads the remote, finds its own tree already there, and treats that as
# the confirmation it is — never a second commit, and never the
# non-fast-forward such a commit would be refused as.
if P_OUT2="$(_wt_preserve "$P_WT" build/dirty)"; then r1=confirmed; else r1=REFUSED; fi
t p168-rerun-still-confirms confirmed "$r1"
t p168-rerun-pushes-nothing-new "$P_OUT" "$P_OUT2"
t p168-rerun-leaves-one-ref 1 "$(_p168_wip_refs "$P_BARE")"

# Dirt that CHANGED between passes is new work, and the ref moves to it — the
# new commit is parented on what the remote already holds, so the push is a
# fast-forward rather than a rejection that would strand the worktree.
printf 'later\n' >"$P_WT/second.txt"
if P_OUT3="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-new-dirt-preserved pushed "$r1"
case "$P_OUT3" in "$P_OUT") r1=STALE ;; *) r1=advanced ;; esac
t p168-new-dirt-advances-the-ref advanced "$r1"
case "$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty)" in
  *second.txt*) r1=carried ;; *) r1=DROPPED ;;
esac
t p168-new-dirt-carries-the-new-file carried "$r1"

# The capture's own refusal, reached directly. `_wt_preserve` refuses when what
# it captured is HEAD's own tree — nothing was at risk — and that path is
# otherwise only reachable when a removal refuses for a reason that leaves the
# tree unchanged (a locked worktree), so it is exercised here rather than left
# to the one shape that happens to reach it. The refusal is what denies the
# caller its force, and a refusal that pushed anyway would earn a force it
# cannot explain: both halves are asserted.
_p168_fixture nothing-at-risk
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-ignored-only-capture-refuses refused "$r1"
t p168-ignored-only-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
rm -rf "$P_WT/ignored"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-clean-capture-refuses refused "$r1"
t p168-clean-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"

# --- the index is uncommitted work too (@codex-bot-andresmgsl, #376) ----------
#
# A capture built from the working tree alone answers the wrong question. For a
# partially staged path the index holds ONE version and the working tree
# ANOTHER, and both are uncommitted: preserving the second and forcing the
# worktree away destroys the first, which is this issue's own failure mode
# reached through its own fix. Driven end to end through `_wt_release` because
# that is the level that decides a `--force`, and read from the BARE remote
# after the worktree is gone, because "still retrievable" is the claim.
#
# THE ASSERTIONS GO PAST THE TIP. A suite that checks only
# `refs/heads/wip/<branch>:<file>` passes on the defective capture — the tip is
# the half that survives it. The staged version's own assertion is what bites.
_p168_fixture partial-stage
printf 'carefully-staged\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'later-working-edit\n' >"$P_WT/README.md"
t p168-partial-stage-is-partially-staged 'MM README.md' \
  "$(git -C "$P_WT" status --porcelain --untracked-files=all)"
# The chain is idempotent as the single commit was: a second pass finds its own
# tip AND its own parent already on the remote and confirms rather than minting
# a duplicate pair.
P_PS1="$(_wt_preserve "$P_WT" build/partial-stage)"
P_PS2="$(_wt_preserve "$P_WT" build/partial-stage)"
t p168-partial-stage-rerun-confirms-the-chain "$P_PS1" "$P_PS2"
t p168-partial-stage-rerun-leaves-one-ref 1 "$(_p168_wip_refs "$P_BARE")"
P_LG="$P168/ledger-partial"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/partial-stage "$P_WT" 50 "$P_LG")"; then
  r1=released
else
  r1=KEPT
fi
t p168-partial-stage-released released "$r1"
t p168-partial-stage-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
# The tip is the working tree, which is what `checkout FETCH_HEAD` should land
# somebody on...
t p168-partial-stage-tip-is-the-working-tree later-working-edit \
  "$(git -C "$P_BARE" show refs/heads/wip/build/partial-stage:README.md)"
# ...and the staged bytes are the commit below it, on the remote, after the only
# copy that was ever local has been forced away.
t p168-partial-stage-parent-is-the-index carefully-staged \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/partial-stage^:README.md')"
P_PS_SEEN="$(for P_PS_C in refs/heads/wip/build/partial-stage \
  'refs/heads/wip/build/partial-stage^'; do
  git -C "$P_BARE" show "$P_PS_C:README.md"
done | sort -u | tr '\n' ' ')"
t p168-partial-stage-both-versions-survive 'carefully-staged later-working-edit ' \
  "$P_PS_SEEN"
# The record is the durable half, so it names the half nobody would think to
# look for — the sha, and the ref-relative way to reach it.
P_REC="$(cat "$P168_PO_BODY")"
P_PS_STAGED="$(git -C "$P_BARE" rev-parse 'refs/heads/wip/build/partial-stage^')"
case "$P_REC" in *"$P_PS_STAGED"*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-staged-snapshot named "$r1"
case "$P_REC" in *'FETCH_HEAD^'*) r1=reachable ;; *) r1=MISSING ;; esac
t p168-record-carries-the-staged-recovery reachable "$r1"
case "$P_OUT" in *'FETCH_HEAD^'*) r1=named ;; *) r1=MISSING ;; esac
t p168-log-names-the-staged-snapshot named "$r1"

# The shape the working-tree capture cannot see AT ALL: content staged and then
# put back in the tree. `git status` calls it dirty (`MM`), so the removal
# refuses — and the capture equalled HEAD's tree, so the preservation refused
# too, and the worktree was stuck on every five-minute tick for the life of the
# box with nothing preserved and nothing said. The refusal now reads "neither
# half holds anything", which is what releases this one.
_p168_fixture staged-only
printf 'staged-then-reverted\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'engine\n' >"$P_WT/README.md"
t p168-staged-only-worktree-matches-head "" \
  "$(git -C "$P_WT" diff HEAD --name-only)"
P_LG="$P168/ledger-staged-only"
if _wt_release "$P_CLONE" o/r build/staged-only "$P_WT" 51 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-staged-only-released released "$r1"
t p168-staged-only-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-staged-only-pushes-a-ref 1 "$(_p168_wip_refs "$P_BARE")"
t p168-staged-only-preserves-the-staged-bytes staged-then-reverted \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/staged-only^:README.md')"

# A ref already on the remote from a pass that knew nothing about indexes — the
# upgrade case, and the must-fail for checking the chain rather than the tip.
# The tip matches what this pass captured (the working tree did not change), so
# a confirmation on the tip alone would return "already preserved" and force the
# worktree away with the staged bytes on no remote at all.
_p168_fixture stage-after-preserve
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_SAP1="$(_wt_preserve "$P_WT" build/stage-after-preserve)"
read -r _ _ _ _ P_SAP_STAGED1 <<<"$P_SAP1"
t p168-plain-dirt-has-no-staged-snapshot - "$P_SAP_STAGED1"
t p168-plain-dirt-is-one-commit 1 \
  "$(git -C "$P_BARE" rev-list --count refs/heads/wip/build/stage-after-preserve \
    ^"$(git -C "$P_WT" rev-parse HEAD)")"
P_SAP_TIP1="$(git -C "$P_BARE" rev-parse refs/heads/wip/build/stage-after-preserve)"
printf 'now-staged\n' >"$P_WT/README.md"
git -C "$P_WT" add README.md
printf 'engine\n' >"$P_WT/README.md"
if _wt_preserve "$P_WT" build/stage-after-preserve >/dev/null; then
  r1=pushed
else
  r1=REFUSED
fi
t p168-stage-after-preserve-pushes pushed "$r1"
# Measured on the REMOTE, never on what the function printed: a tip-only
# confirmation returns a different line (it now has a parent to name) while the
# ref stands still, which is the false pass this assertion exists to refuse.
case "$(git -C "$P_BARE" rev-parse refs/heads/wip/build/stage-after-preserve)" in
  "$P_SAP_TIP1") r1=CONFIRMED_STALE ;; *) r1=advanced ;;
esac
t p168-stage-after-preserve-advances-the-ref advanced "$r1"
t p168-stage-after-preserve-carries-the-index now-staged \
  "$(git -C "$P_BARE" show 'refs/heads/wip/build/stage-after-preserve^:README.md')"

# An index that cannot be read is not an empty one. Corrupted here because that
# is deterministic wherever this runs (a chmod proves nothing under root), and
# the shape is the same either way: what is staged is unknown, and unknown must
# not be summarised as nothing on the way to a `--force`. No capture, no push,
# no removal — every byte still on disk.
_p168_fixture unreadable-index
printf 'rescue me\n' >"$P_WT/untracked.txt"
printf 'not-an-index-at-all' >"$(git -C "$P_WT" rev-parse --git-path index)"
if _wt_index_tree "$P_WT" >/dev/null 2>&1; then r1=CLAIMED; else r1=refused; fi
t p168-index-read-fails-closed refused "$r1"
if _wt_preserve "$P_WT" build/unreadable-index >/dev/null 2>&1; then
  r1=CLAIMED
else
  r1=refused
fi
t p168-unreadable-index-capture-refuses refused "$r1"
t p168-unreadable-index-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
t p168-unreadable-index-keeps-the-work 'rescue me' \
  "$(cat "$P_WT/untracked.txt" 2>/dev/null)"

# 2. Only-ignored dirt: removed, and nothing pushed. Nothing was at risk, so
# there is no ref to explain and no force to earn — the clean removal already
# succeeds, which is why the preservation path is reached only by a refusal.
_p168_fixture ignored-only
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
P_LG="$P168/ledger-ignored"
if _wt_release "$P_CLONE" o/r build/ignored-only "$P_WT" 41 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-ignored-only-released released "$r1"
t p168-ignored-only-worktree-gone gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-ignored-only-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
# ...and nothing was recorded either: there is no ref to point a reader at.
t p168-ignored-only-records-nothing 0 "$(grep -c 'o/r#41' "$P168_PO_CALLS")"
# ...and a second sweep has nothing left to re-remove: the released worktree is
# out of `worktree list`, which is what the hygiene block enumerates.
t p168-released-worktree-off-the-list 0 \
  "$(git -C "$P_CLONE" worktree list --porcelain | grep -c "$P_WT\$")"

# 3. A failed push is a hard stop. No preservation, no removal — today's
# behaviour, including #167's once-per-dirt WARN, and the worktree still
# holding every byte of the work.
_p168_fixture push-fails
printf 'rescue me\n' >"$P_WT/untracked.txt"
git -C "$P_CLONE" remote set-url origin "$P168/nowhere-at-all.git"
git -C "$P_WT" remote set-url origin "$P168/nowhere-at-all.git"
P_LG="$P168/ledger-nopush"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/push-fails "$P_WT" 42 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-failed-push-refuses-release kept "$r1"
t p168-failed-push-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-failed-push-keeps-the-work 'rescue me' "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-failed-push-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-failed-push-then-silent "" "$(_wt_release "$P_CLONE" o/r build/push-fails "$P_WT" 42 "$P_LG")"
# Nothing landed, so nothing is recorded: a comment naming a ref that does not
# exist is worse than no comment, because the reader stops looking.
t p168-failed-push-records-nothing 0 "$(grep -c 'o/r#42' "$P168_PO_CALLS")"

# 4. The whole order, end to end: a worktree holding real work is released
# only because the push landed, and the work is retrievable from the remote
# afterwards. This is the acceptance criterion as data — and the must-fail it
# carries is the reordering that would look harmless, a --force reached before
# the confirmation.
_p168_fixture released
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-released"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/released "$P_WT" 43 "$P_LG")"; then
  r1=released
else
  r1=KEPT
fi
t p168-release-succeeds released "$r1"
t p168-release-removed-the-worktree gone "$([ -d "$P_WT" ] && echo THERE || echo gone)"
t p168-release-left-the-work-on-the-remote 'rescue me' \
  "$(git -C "$P_BARE" show refs/heads/wip/build/released:untracked.txt)"
# The log line is the whole recovery instruction: whoever reads it a week later
# is not holding this box, and the worktree it names no longer exists.
case "$P_OUT" in *"wip/build/released"*) r1=named ;; *) r1=MISSING ;; esac
t p168-log-names-the-ref named "$r1"
case "$P_OUT" in *"git fetch $P168/released.git wip/build/released"*) r1=recoverable ;; *) r1=MISSING ;; esac
t p168-log-carries-the-recovery-command recoverable "$r1"
# A released branch is deleted the same way the clean path deletes it — the two
# removals differ in what they preserved first, not in what they leave behind.
t p168-release-deletes-the-branch 0 \
  "$(git -C "$P_CLONE" branch --list build/released | n)"

# 5. The record, which is the half that survives losing the other one. It goes
# on the PR the worktree belonged to, and it names the remote, the ref, what it
# holds and how to get it back — enough to decide the work is worthless without
# fetching it, and enough to fetch it where it is not.
t p168-record-goes-to-the-pr 'o/r#43' "$(tail -1 "$P168_PO_CALLS")"
P_REC="$(cat "$P168_PO_BODY")"
case "$P_REC" in *'wip/build/released'*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-ref named "$r1"
# shellcheck disable=SC2016  # the markdown the record contains, not an expansion
case "$P_REC" in *'`origin`'*) r1=named ;; *) r1=MISSING ;; esac
t p168-record-names-the-remote named "$r1"
# What it holds, in the counts the criterion asks for: one modified tracked
# file (README.md) and one untracked (untracked.txt).
case "$P_REC" in *'1 modified, 1 untracked'*) r1=counted ;; *) r1=MISSING ;; esac
t p168-record-carries-the-counts counted "$r1"
case "$P_REC" in
  *"git fetch $P168/released.git wip/build/released"*) r1=recoverable ;;
  *) r1=MISSING ;;
esac
t p168-record-carries-the-recovery-command recoverable "$r1"
# The sha ties the record to what was actually pushed — and is what makes the
# body stable, which is the property post-once.sh's exact-body dedup runs on.
P_REC_SHA="$(git -C "$P_BARE" rev-parse refs/heads/wip/build/released)"
case "$P_REC" in *"$P_REC_SHA"*) r1=pinned ;; *) r1=MISSING ;; esac
t p168-record-names-the-sha pinned "$r1"

# Dedup, from this module's side: the same preservation asked for twice hands
# post-once.sh a byte-identical body, so its exact-body match suppresses the
# second. A body carrying a timestamp or a run id would pass every assertion
# above and post a fresh comment every tick — which is the shape #167 exists to
# prevent, moved upstream where it is louder.
_p168_fixture record-stable
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_PRES="$(_wt_preserve "$P_WT" build/record-stable)"
read -r P_RM P_RF P_RS P_RU <<<"$P_PRES"
_wt_record o/r 44 build/record-stable "$P_WT" "$P_RM" "$P_RF" "$P_RS" "$P_RU"
P_REC1="$(cat "$P168_PO_BODY")"
_wt_record o/r 44 build/record-stable "$P_WT" "$P_RM" "$P_RF" "$P_RS" "$P_RU"
t p168-record-body-is-stable "$P_REC1" "$(cat "$P168_PO_BODY")"

# The counts describe the REF, and the shape that made them lie is the common
# one: an untracked DIRECTORY. `git status --porcelain` with its default
# untracked mode collapses `newdir/a` and `newdir/b` into a single `?? newdir/`
# row, so the record said "1 untracked" over a ref holding two files — and a
# whole uncommitted `bin/` or `test/`, which is exactly what #168 exists to
# save, is the case that reads as one stray file to whoever decides not to
# fetch it. Asserted against the ref's own file count rather than a literal, so
# the record is checked against the payload and not against itself. Every
# earlier fixture puts its untracked file at the root, where the defect is
# invisible.
_p168_fixture nested-untracked
printf 'changed\n' >"$P_WT/README.md"
mkdir -p "$P_WT/newdir"
printf 'a\n' >"$P_WT/newdir/a"
printf 'b\n' >"$P_WT/newdir/b"
P_LG="$P168/ledger-nested"
_wt_release "$P_CLONE" o/r build/nested-untracked "$P_WT" 49 "$P_LG" >/dev/null
P_NESTED_N="$(git -C "$P_BARE" ls-tree -r --name-only \
  refs/heads/wip/build/nested-untracked -- newdir | n)"
t p168-nested-ref-carries-both-files 2 "$P_NESTED_N"
P_REC="$(cat "$P168_PO_BODY")"
case "$P_REC" in
  *"1 modified, $P_NESTED_N untracked"*) r1=counted ;;
  *) r1="MISCOUNTED: $P_REC" ;;
esac
t p168-record-counts-nested-untracked counted "$r1"

# The same read, failing. Two shapes, because they arrive differently: the
# worktree's directory gone out from under the sweep, and a git that cannot
# answer where the directory is still there.
#
# The failure has to be LOUD, and the reason is the `if !` it is called inside:
# `set -e` is disarmed over the whole condition, so a swallowed exit status is
# not caught anywhere downstream. A status that returned nothing summarises as
# "0 modified, 0 untracked" — a record that reads like a triviality over content
# nobody has seen, and a `--force` earned on it. The must-fail is a `_wt_record`
# that returns 0 here.
if _wt_record o/r 48 build/vanished "$P168/vanished" origin wip/build/vanished \
  deadbeef "$P_BARE" >/dev/null 2>&1; then r1=CLAIMED; else r1=refused; fi
t p168-record-refuses-unreadable-status refused "$r1"
t p168-record-refuses-before-posting 0 "$(grep -c 'o/r#48' "$P168_PO_CALLS")"

# 6. A record that does not land is a hard stop on the removal, exactly as a
# failed push is. The payload is the deletable half and the comment the durable
# one (#168, amended 2026-08-05), so a worktree forced away with the ref pushed
# and nothing upstream saying where it went ships the gap the amendment closes.
# Self-healing by construction: the worktree stays, and the next pass
# re-preserves to the same sha and retries the record.
_p168_fixture record-fails
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-norecord"
P168_PO_RC=1
if P_OUT="$(_wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-failed-record-refuses-release kept "$r1"
t p168-failed-record-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-failed-record-keeps-the-work 'rescue me' "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-failed-record-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-failed-record-then-silent 0 \
  "$(_wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG" | grep -c 'WARN')"
# The payload is still on the remote — the stop is about the pointer, never
# about the work, and the second pass mints no second ref for it.
t p168-failed-record-keeps-the-ref 1 "$(_p168_wip_refs "$P_BARE")"
# ...and once the record does land, the same worktree releases.
P168_PO_RC=0
if _wt_release "$P_CLONE" o/r build/record-fails "$P_WT" 45 "$P_LG" >/dev/null; then
  r1=released
else
  r1=KEPT
fi
t p168-record-recovered-releases released "$r1"
t p168-record-recovered-removed-the-worktree gone \
  "$([ -d "$P_WT" ] && echo THERE || echo gone)"

# ...and the same refusal reached through `_wt_release`, which is where it has
# to hold: a `git` on PATH that fails only `status` (73, so nothing can mistake
# it for a clean exit) and passes everything else through to the real one. The
# push still lands — `_wt_preserve` never reads a status — so this pins the
# exact division the amendment draws: the payload is safe, the pointer is not,
# and it is the pointer that gates the force.
_p168_fixture status-unreadable
printf 'rescue me\n' >"$P_WT/untracked.txt"
P_LG="$P168/ledger-nostatus"
P168_REAL_GIT="$(command -v git)"
export P168_REAL_GIT
cat >"$P168_BIN/git" <<'P168GIT'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = status ] && exit 73; done
exec "$P168_REAL_GIT" "$@"
P168GIT
chmod +x "$P168_BIN/git"
P_PATH_SAVED="$PATH"
PATH="$P168_BIN:$PATH"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/status-unreadable "$P_WT" 47 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
PATH="$P_PATH_SAVED"
rm -f "$P168_BIN/git"
t p168-unreadable-status-refuses-release kept "$r1"
t p168-unreadable-status-keeps-worktree present \
  "$([ -d "$P_WT" ] && echo present || echo GONE)"
t p168-unreadable-status-keeps-the-work 'rescue me' \
  "$(cat "$P_WT/untracked.txt" 2>/dev/null)"
t p168-unreadable-status-records-nothing 0 "$(grep -c 'o/r#47' "$P168_PO_CALLS")"
t p168-unreadable-status-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
# The payload landed before the record was ever attempted, and it stays: the
# stop is about the pointer, never about the work.
t p168-unreadable-status-keeps-the-ref 1 "$(_p168_wip_refs "$P_BARE")"

# One read, in one place, listing every file. Both properties are structural
# because both are invisible to a suite whose fixtures happen to have flat
# untracked files and a working git — which is what the fixtures above were
# until this round. Comment lines are stripped first: the helper DOCUMENTS the
# bare form it exists to replace, and a detector that counts its own
# explanation is a mistake this repo has now made five separate times.
P_STATUS_READS="$(grep -v '^[[:space:]]*#' "$BMOD" | grep 'status --porcelain')"
t p168-one-status-read 1 "$(printf '%s\n' "$P_STATUS_READS" | n)"
t p168-status-lists-every-file 0 \
  "$(printf '%s\n' "$P_STATUS_READS" | grep -vc -- '--untracked-files=all')"
# ...and it fails closed rather than returning an empty listing that summarises
# as "0 modified, 0 untracked".
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_DIRTFN="$(awk '/^_wt_dirt\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
case "$P_DIRTFN" in *'|| return 1'*) r1=closed ;; *) r1=OPEN ;; esac
t p168-dirt-read-fails-closed closed "$r1"

# 7. A worktree that survives the forced removal is reported ONCE, not on every
# tick: the same discipline #167 bought for the dirty-worktree warning, on the
# path that bypassed it. A lock is the reachable way to make `remove --force`
# refuse; the engine never locks a worktree itself, so this needs a human lock
# or a filesystem refusal in the wild — which is exactly why it repeated
# unnoticed on a five-minute unattended loop.
_p168_fixture force-survives
printf 'rescue me\n' >"$P_WT/untracked.txt"
git -C "$P_CLONE" worktree lock "$P_WT"
P_LG="$P168/ledger-locked"
if P_OUT="$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG")"; then
  r1=RELEASED
else
  r1=kept
fi
t p168-locked-force-refuses-release kept "$r1"
t p168-locked-force-warns-once 1 "$(printf '%s\n' "$P_OUT" | grep -c 'WARN')"
t p168-locked-force-then-silent 0 \
  "$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG" | grep -c 'WARN')"
# Silence is not amnesia: the work is still on the remote, still one ref, still
# one commit, however many ticks pass over it.
t p168-locked-force-keeps-one-ref 1 "$(_p168_wip_refs "$P_BARE")"
t p168-locked-force-keeps-the-work 'rescue me' \
  "$(git -C "$P_BARE" show refs/heads/wip/build/force-survives:untracked.txt)"
# New dirt is new news, and says so once again: the ledger id carries the
# preserved sha, so a changed worktree is never swallowed by the last one's
# silence. Must-fail: key it on the worktree alone and this goes quiet.
printf 'later\n' >"$P_WT/second.txt"
t p168-locked-force-rewarns-on-new-dirt 1 \
  "$(_wt_release "$P_CLONE" o/r build/force-survives "$P_WT" 46 "$P_LG" | grep -c 'WARN')"
git -C "$P_CLONE" worktree unlock "$P_WT"

# The ordering, read as an ordering. Every one of these is a real defect that
# passes a behavioural suite on a good day: a force before the push confirms
# discards work only when the remote is down, and a `git stash` capture drops
# untracked files only when there are some.
P_REL="$(awk '/^_wt_release\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_CLEAN_LN="$(printf '%s\n' "$P_REL" | grep -n 'worktree remove "\$path"' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_PRES_LN="$(printf '%s\n' "$P_REL" | grep -n '_wt_preserve "\$path"' | head -1 | cut -d: -f1)"
P_FORCE_LN="$(printf '%s\n' "$P_REL" | grep -n -- '--force' | head -1 | cut -d: -f1)"
t p168-clean-attempt-precedes-capture yes \
  "$([ -n "$P_CLEAN_LN" ] && [ -n "$P_PRES_LN" ] && [ "$P_CLEAN_LN" -lt "$P_PRES_LN" ] && echo yes || echo NO)"
t p168-capture-precedes-force yes \
  "$([ -n "$P_PRES_LN" ] && [ -n "$P_FORCE_LN" ] && [ "$P_PRES_LN" -lt "$P_FORCE_LN" ] && echo yes || echo NO)"
# The record is between them, and reads the worktree while there still is one:
# the counts it carries come from `git status` on a path the force is about to
# take away, so a record moved below the force names nothing at all.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_RECORD_LN="$(printf '%s\n' "$P_REL" | grep -n '_wt_record "\$repo"' | head -1 | cut -d: -f1)"
t p168-capture-precedes-record yes \
  "$([ -n "$P_PRES_LN" ] && [ -n "$P_RECORD_LN" ] && [ "$P_PRES_LN" -lt "$P_RECORD_LN" ] && echo yes || echo NO)"
t p168-record-precedes-force yes \
  "$([ -n "$P_RECORD_LN" ] && [ -n "$P_FORCE_LN" ] && [ "$P_RECORD_LN" -lt "$P_FORCE_LN" ] && echo yes || echo NO)"
# The force is inside the branch the preservation's success opens, not beside
# it: the guard is `if preserved=...`, so a force outside it cannot exist.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
case "$P_REL" in *'if preserved="$(_wt_preserve'*) r1=guarded ;; *) r1=UNGUARDED ;; esac
t p168-force-is-inside-the-push-guard guarded "$r1"
# The capture never goes through `git stash`: without --include-untracked it
# silently drops exactly the files this issue was filed over, and with it, it
# mutates the worktree it is supposed to leave alone.
t p168-capture-never-stashes 0 "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'git stash\|stash push\|stash create')"
# ...it writes a scratch index instead, which is what leaves the tree untouched.
# All three index-touching commands are under it — read-tree, add, write-tree —
# and the one that got left out would be the one that stages the build's work
# into the real index on its way past.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
t p168-capture-uses-a-scratch-index 3 \
  "$(grep -v '^[[:space:]]*#' "$BMOD" | grep -c 'GIT_INDEX_FILE="\$idx"')"
# The REAL index is read the same way: through a copy, never in place. This is
# not fussiness — `git write-tree` rewrites the cache-tree extension into
# whichever index it is handed, so a read that pointed GIT_INDEX_FILE at the
# worktree's own index would modify the worktree this module promises to leave
# byte-identical. The copy is the only thing standing between those two, and it
# is one line somebody would delete as redundant.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_IDXFN="$(awk '/^_wt_index_tree\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
case "$P_IDXFN" in *'cp "$real" "$copy"'*) r1=copied ;; *) r1=IN_PLACE ;; esac
t p168-index-read-through-a-copy copied "$r1"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
t p168-index-read-never-in-place 0 \
  "$(printf '%s\n' "$P_IDXFN" | grep -v '^[[:space:]]*#' | grep -c 'GIT_INDEX_FILE="\$real"')"
# ...and it fails closed, exactly as the status read does: an index that cannot
# be written to a tree is unknown content, and unknown is not empty.
case "$P_IDXFN" in *'|| return 1'*) r1=closed ;; *) r1=OPEN ;; esac
t p168-index-fn-fails-closed closed "$r1"
# The staged snapshot is the tip's PARENT, never the tip: whoever runs the
# recovery command lands on the working tree, which is what they were told they
# would get. Read as an ordering, since both commits are built the same way and
# the swap would pass every "both versions survive" assertion.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_PRESFN="$(awk '/^_wt_preserve\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_STAGED_LN="$(printf '%s\n' "$P_PRESFN" | grep -n 'staged_commit="\$(_wt_commit' | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the literals the module contains, not expansions
P_TIP_LN="$(printf '%s\n' "$P_PRESFN" | grep -n 'commit="\$(_wt_commit "\$path" "\$tree"' | head -1 | cut -d: -f1)"
t p168-staged-commit-precedes-the-tip yes \
  "$([ -n "$P_STAGED_LN" ] && [ -n "$P_TIP_LN" ] && [ "$P_STAGED_LN" -lt "$P_TIP_LN" ] && echo yes || echo NO)"
# The record goes through post-once.sh rather than a bare POST: its dedup is an
# exact body match against the comments endpoint, so a tick that dies between
# the push and the removal re-records nothing. A local ledger cannot promise
# that — it dies with the box, and this whole issue is about a box dying.
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
P_RECFN="$(awk '/^_wt_record\(\)/{p=1} p{print} p&&/^}$/{exit}' "$BMOD")"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
case "$P_RECFN" in *'"$BIN_DIR/post-once.sh"'*) r1=post_once ;; *) r1=RAW ;; esac
t p168-record-uses-post-once post_once "$r1"
t p168-record-never-posts-raw 0 \
  "$(printf '%s\n' "$P_RECFN" | grep -v '^[[:space:]]*#' | grep -c 'issues/.*comments')"

BIN_DIR="$P168_BIN_SAVED"

# --- wiring (#45/#17) --------------------------------------------------------
if grep -q 'statusCheckRollup' "$BMOD"; then r1=fetched; else r1=MISSING; fi
t ci-red-rollup-fetched fetched "$r1"
# The rollup rides listings that are fetched anyway; it never gets a call of its
# own. THREE fetches, each named: the resume block's authored-PR listing (#384),
# the round/ci-red authored-PR listing, and the one post-ci-red `gh pr view`
# re-read #243 added so a session exiting while checks are pending does not
# consume the head. The resume listing and the round listing are deliberately
# NOT merged into one — the round listing is fetched AFTER the resume sessions
# precisely so a session's own push is visible to it, and a merged snapshot
# would grade ci-red and round-owed against a pre-session tree.
#
# COUNTED AS FETCHES, NOT AS OCCURRENCES OF THE WORD. The old form grepped the
# whole module for the string and had to strip comment lines to keep from
# counting its own explanation — "a detector tripping on its own documentation,
# which this repo has now managed three separate times". It then counted
# `_resume_newest_check`'s jq field READ as a fourth API call, which is the same
# defect one layer down: parsing a field you already have is not fetching it.
# Only a `--json` argument list can name a field to fetch, so that is what is
# counted, and the explanation above can say `statusCheckRollup` freely.
t ci-red-rollup-fetched-on-three-listings 3 \
  "$(grep -c -- '--json [^ ]*statusCheckRollup' "$BMOD")"
# The resume half of that count adds no CALL — the listing was already being
# fetched, and #384 put two more fields on it. A `gh` call inside either new
# predicate would be a per-PR-per-tick cost the issue explicitly priced out.
# _flip_owed_resume_rows is deliberately absent: it makes exactly one GraphQL
# READ per green-headed signalled draft, because the verdicts it must weigh
# cannot come off a listing (#147), and that read is pinned by
# `p384-flip-makes-exactly-one-read` beside the assertions that it never writes.
t resume-check-read-adds-no-gh-call 0 \
  "$(cat <(declare -f _resume_newest_check) <(declare -f _resume_check_states) \
       <(declare -f _green_head_resume_rows) \
     | grep -c 'gh ')"
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
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
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
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
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

# --- #139: a closed fix round returns to draft ------------------------------
# GitHub preserves pending review requests across conversion (crew#110 is the
# live trace), so the existing addressing predicate's no-panel-request gate is
# load-bearing: conversion happens only after the whole round closes. The last
# reviewer's triage-scoped box writes state:addressing; the author-owned builder
# tick performs the draft mutation. Those acts are independent and idempotent.
AR_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
AR_T_VERDICT="2026-08-05T18:57:00Z"
AR_T_SIGNAL="2026-08-05T19:00:00Z"
AR_BLOCKED='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}}]'
AR_APPROVED='[{"author":{"login":"rev-a"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}}]'
mk_addressing_payload() {  # draft labels requests reviews [comments]
  jq -cn --argjson draft "$1" --argjson labels "$2" --argjson requests "$3" \
    --argjson reviews "$4" --argjson comments "${5:-[]}" --arg head "$AR_H" \
    '{data:{repository:{pullRequest:{
      id:"PR_fixture",isDraft:$draft,headRefOid:$head,author:{login:"builder"},
      labels:{nodes:($labels|map({name:.}))},
      comments:{nodes:$comments},
      reviewRequests:{nodes:($requests|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$reviews}}}}}'
}
# shellcheck disable=SC2034,SC2317  # vars/functions consumed by engine helpers
review_addressing_actions() (  # payload [label-rc]
  AR_PAYLOAD="$1"; AR_LABEL_RC="${2:-0}"
  LABEL_ADDRESSING=state:addressing
  DUTY_DIR="$SHARED"
  AR_LOG="$TMP/addressing-actions"; : >"$AR_LOG"
  panel_for_repo() { printf '%s\n' '["rev-a","rev-b"]'; }
  log() { :; }
  warn() { :; }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      printf '%s\n' "$AR_PAYLOAD"
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      printf '%s\n' label >>"$AR_LOG"
      return "$AR_LABEL_RC"
    fi
    return 3
  }
  _mark_addressing owner/repo 7
  ar_rc=$?
  printf 'rc=%s actions=%s' "$ar_rc" "$(paste -sd, "$AR_LOG")"
)
# shellcheck disable=SC2317  # mock functions are called indirectly by helper
author_redraft_actions() (  # payload [draft-rc]
  AR_PAYLOAD="$1"; AR_DRAFT_RC="${2:-0}"
  LABEL_ADDRESSING=state:addressing
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK"
  AR_LOG="$TMP/redraft-actions"; : >"$AR_LOG"
  log() { :; }
  warn() { :; }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *convertPullRequestToDraft* ]]; then
        printf '%s\n' draft >>"$AR_LOG"
        return "$AR_DRAFT_RC"
      fi
      printf '%s\n' "$AR_PAYLOAD"
      return 0
    fi
    return 3
  }
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  ar_rc=$?
  printf 'rc=%s actions=%s' "$ar_rc" "$(paste -sd, "$AR_LOG")"
)
AR_OPEN="$(mk_addressing_payload false '[]' '[]' "$AR_BLOCKED")"
AR_LABELLED="$(mk_addressing_payload false '["state:addressing"]' '[]' "$AR_BLOCKED")"
AR_DRAFT="$(mk_addressing_payload true '["state:addressing"]' '[]' "$AR_BLOCKED")"
AR_DRAFT_UNLABELLED="$(mk_addressing_payload true '[]' '[]' "$AR_BLOCKED")"
AR_OK="$(mk_addressing_payload false '[]' '[]' "$AR_APPROVED")"
AR_LIVE="$(mk_addressing_payload false '[]' '["rev-b"]' "$AR_BLOCKED")"
t redraft-reviewer-writes-addressing-only 'rc=0 actions=label' \
  "$(review_addressing_actions "$AR_OPEN")"
t redraft-author-converts-after-label 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED")"
t redraft-full-approval-writes-nothing 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_OK")"
t redraft-live-panel-request-writes-nothing 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_LIVE")"
t redraft-second-tick-is-noop 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_DRAFT")"
t redraft-draft-guard-does-not-depend-on-label 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_DRAFT_UNLABELLED")"
t redraft-retries-after-label-landed 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED")"
t redraft-label-failure-is-best-effort 'rc=0 actions=label' \
  "$(review_addressing_actions "$AR_OPEN" 1)"
t redraft-conversion-failure-is-best-effort 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED" 1)"

# The author-aware panel is resolved once per repository tick and passed into
# every PR predicate. panel_for_repo owns the safe fleet-bench fallback, so the
# redraft path must not advertise an unreachable lookup-failure branch.
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
t redraft-panel-resolved-once-per-repo 1 \
  "$(grep -c 'panel_for_repo "\$R" "\$dir" "\$ME"' "$SHARED/lib/duty-builder.sh")"
if grep -q 'panel lookup failed' "$SHARED/lib/duty-builder.sh"; then
  r1=MISLEADING
else
  r1=fallback-owned
fi
t redraft-panel-fallback-contract fallback-owned "$r1"

# The engine owns only the ready -> draft edge. Ready-for-review remains the
# builder's judgement, and draft exclusion is shared by request and handoff.
if ! grep -q 'convertPullRequestToDraft' "$SHARED/lib/duty-review.sh" \
  && grep -q 'convertPullRequestToDraft' "$SHARED/lib/duty-builder.sh" \
  && ! grep -Rq 'markPullRequestReadyForReview\|gh pr ready' \
       "$SHARED/lib" "$SHARED/bin" "$ROOT/cli"; then
  r1=one-way
else
  r1=ENGINE-MARKS-READY
fi
t redraft-engine-never-marks-ready one-way "$r1"
if grep -qi "while it is still draft, mark it ready with no commit between, and let the head checks settle" \
     "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'requests the panel only after that ready head is green' \
     "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=builder-owned
else
  r1=MISSING
fi
t redraft-prompt-returns-ready-act-to-builder builder-owned "$r1"
if grep -Fq 'A draft carrying a completed review round is actionable' \
     "$SHARED/prompts/resume.txt" \
  && grep -Fq "append the round's fix steps" "$SHARED/prompts/resume.txt" \
  && grep -Fq 'AND NO COMPLETED ROUND STANDS, POST NOTHING AT ALL' \
       "$SHARED/prompts/resume.txt"; then
  r1=woken
else
  r1=STRANDED
fi
t redraft-resume-names-completed-round woken "$r1"

# The issue's whole lifecycle in one stateful fixture. It drives the real
# reviewer and author helpers against one mutable PR, reads the checked-in CI
# workflow gates for the draft-push/ready edges, then hands the real signal
# object to request-panel.jq. A broken link changes or stops this trace.
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by engine helpers
redraft_round_trip() (
  AR_IS_DRAFT=false AR_LABELS='[]' AR_COMMENTS='[]' AR_ACTIONS=""
  LABEL_ADDRESSING=state:addressing LABEL_BOTS_REVIEWING=state:bots-reviewing
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK"
  panel_for_repo() { printf '%s\n' '["rev-a","rev-b"]'; }
  log() { :; }
  warn() { :; }
  ar_payload() {
    mk_addressing_payload "$AR_IS_DRAFT" "$AR_LABELS" '[]' "$AR_BLOCKED" "$AR_COMMENTS"
  }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *convertPullRequestToDraft* ]]; then
        AR_IS_DRAFT=true
        AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}draft"
        return 0
      fi
      ar_payload
      return 0
    fi
    if [ "$1" = api ] && [[ "$2" == repos/*/requested_reviewers ]]; then
      local ar_arg
      for ar_arg in "$@"; do
        case "$ar_arg" in
          reviewers\[\]=*)
            AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}request:${ar_arg#*=}"
            ;;
        esac
      done
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      if [[ "$*" == *state:bots-reviewing* ]]; then
        return 0
      fi
      AR_LABELS='["state:addressing"]'
      AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}addressing"
      return 0
    fi
    return 3
  }
  _mark_addressing owner/repo 7
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  [ "$AR_IS_DRAFT" = true ] || { printf 'NOT-DRAFT'; return; }
  for ar_ci in "$ROOT/.github/workflows/ci-shell.yml" "$ROOT/.github/workflows/ci-floor.yml"; do
    grep -q 'github.event.pull_request.draft == false' "$ar_ci" || { printf 'DRAFT-CI'; return; }
    grep -q 'ready_for_review' "$ar_ci" || { printf 'NO-READY-WAKE'; return; }
  done
  AR_ACTIONS="$AR_ACTIONS,draft-push:no-ci"
  # SIGNAL THEN READY is the builder-owned edge. This no-push answer retains
  # the standing current-head reviews. The next real author sweep must consume
  # the newer signal as proof that this round was already converted and leave
  # the PR ready; pending CI still holds the real request helper, then green
  # re-requests only the current-head change-requester.
  AR_COMMENTS='[{"author":{"login":"builder"},"body":"'"$RP_MARK"' '"$AR_H"'","createdAt":"'"$AR_T_SIGNAL"'"}]'
  AR_IS_DRAFT=false
  AR_ACTIONS="$AR_ACTIONS,signal,ready"
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  [ "$AR_IS_DRAFT" = false ] || { printf 'REDRAFT-LOOP'; return; }
  _request_panel owner/repo 7 "$(ar_payload)" '["rev-a","rev-b"]' pending "$AR_H"
  AR_ACTIONS="$AR_ACTIONS,ci:green"
  _request_panel owner/repo 7 "$(ar_payload)" '["rev-a","rev-b"]' green "$AR_H"
  printf '%s' "$AR_ACTIONS"
)
t redraft-full-round-trip \
  'addressing,draft,draft-push:no-ci,signal,ready,ci:green,request:rev-a' \
  "$(redraft_round_trip)"

# MUST FAIL before the ceremony prerequisite: the caller pin must be at least
# the release that shipped round-over-draft precedence, and the vendored state
# table must still state that a standing non-approval makes a draft addressing.
AR_LABELS_REF="$(sed -n 's|.*heavy-duty/ceremony/.github/workflows/labels.yml@||p' \
  "$ROOT/.github/workflows/labels.yml")"
AR_OLDEST="$(printf '%s\n%s\n' 0.5.0 "$AR_LABELS_REF" | sort -V | head -n1)"
# shellcheck disable=SC2016  # literal doctrine text contains backticks
if [ "$AR_OLDEST" = 0.5.0 ] \
  && tr -s '[:space:]' ' ' <"$ROOT/.ceremony/LABELS.md" \
     | grep -Fq 'Draft is evidence for it, not the definition of it: a draft carrying a standing non-approving verdict is a fix round and reads `state:addressing`'; then
  r1=present
else
  r1=MISSING
fi
t redraft-ceremony-round-precedence-prerequisite present "$r1"

# Conversion precedes draft discovery in the author tick, so the foreign
# closing verdict reaches resume immediately rather than waiting another tick.
# shellcheck disable=SC2016  # grep patterns intentionally contain shell syntax
AR_REDAFT_LINE="$(grep -n '_redraft_authored_rounds "$R"' "$SHARED/lib/duty-builder.sh" | cut -d: -f1)"
# shellcheck disable=SC2016
AR_RESUME_LINE="$(grep -n 'resume_json="$(gh pr list' "$SHARED/lib/duty-builder.sh" | cut -d: -f1)"
if [ -n "$AR_REDAFT_LINE" ] && [ -n "$AR_RESUME_LINE" ] \
  && [ "$AR_REDAFT_LINE" -lt "$AR_RESUME_LINE" ]; then
  r1=ordered
else
  r1=WRONG-ORDER
fi
t redraft-author-converts-before-resume-discovery ordered "$r1"

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
t rereq-auto-off-never-approves          queue        "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 0)"
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

# Pending-is-not-green is the ENGINE's gate (head-checks.jq is_pending), while
# the builder declares as soon as the round is complete. Pin both actors so a
# future prose edit cannot move the engine's wait back into the session.
if grep -q 'def is_pending' "$SHARED/lib/jq/head-checks.jq" \
  && grep -qi 'engine holds the request until it settles' "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'you do not wait to signal' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=ruled
else
  r1=SILENT
fi
t round-rules-rule-pending ruled "$r1"
# Each prompt carried its own form of the builder-side wait. These file-local
# negatives keep a fixed shared fragment from hiding a stale local restatement.
if ! grep -qiE 'check at your head green|ANSWER IS COMPLETE AND THE HEAD IS GREEN|WAIT for it to settle before you signal|signal once it is green' \
     "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-fragment clear "$r1"
if ! grep -qiE 'round-answered SIGNAL at your green head|check at your head is green|final green head' \
     "$SHARED/prompts/build.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-build clear "$r1"
if ! grep -qiE 'final green head|wait for a green current head|current head is green, and if it is' \
     "$SHARED/prompts/resume.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-resume clear "$r1"
if ! grep -qiE "waiting for the new head.s check to settle before signalling" \
     "$SHARED/prompts/ci-red.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-ci-red clear "$r1"
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

# Every engine render site must fill every prompt slot. render_prompt leaves
# unknown slots literal deliberately, so this belongs in CI rather than the
# runtime tick. The fixture mutations prove both missing-argument failure
# shapes and the built-in doctrine exemption.
render_sources=("$SHARED"/lib/*.sh "$SHARED"/bin/*.sh)
t render-sites-supply-every-prompt-slot "" \
  "$(render_site_missing_slots "$SHARED/prompts" "${render_sources[@]}")"

RS_PROMPTS="$TMP/render-site-prompts"
RS_SOURCE="$TMP/render-site.sh"
mkdir -p "$RS_PROMPTS"
printf 'required {{GIVEN}} {{MISSING}} {{DOCTRINE_BUILDER}}' >"$RS_PROMPTS/fixture.txt"
# shellcheck disable=SC2016  # fixture source must contain the literal expansion
printf 'x="$(render_prompt fixture.txt GIVEN="$value")"\n' >"$RS_SOURCE"
render_missing="$(render_site_missing_slots "$RS_PROMPTS" "$RS_SOURCE")"
case "$render_missing" in
  *"$RS_SOURCE:1: fixture.txt missing MISSING"*) r1=named ;;
  *) r1="$render_missing" ;;
esac
t render-sites-name-missing-slot named "$r1"
if grep -q 'DOCTRINE_BUILDER' <<<"$render_missing"; then r1=FLAGGED; else r1=exempt; fi
t render-sites-exempt-built-in-doctrine exempt "$r1"

printf 'required {{GIVEN}} {{ANYTHING}}' >"$RS_PROMPTS/fixture.txt"
render_missing="$(render_site_missing_slots "$RS_PROMPTS" "$RS_SOURCE")"
case "$render_missing" in *'missing ANYTHING'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-new-slot-without-argument-fails failed "$r1"

cp "$BMOD" "$TMP/duty-builder-missing-round.sh"
# shellcheck disable=SC2016  # removing the module's literal argument
sed -i 's/ ROUND_RULES="$round_rules"//' "$TMP/duty-builder-missing-round.sh"
render_missing="$(render_site_missing_slots "$SHARED/prompts" "$TMP/duty-builder-missing-round.sh")"
case "$render_missing" in *'ci-red.txt missing ROUND_RULES'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-ci-red-missing-round-rules-fails failed "$r1"

cp "$SHARED/lib/duty-attention.sh" "$TMP/duty-attention-missing-answered.sh"
# shellcheck disable=SC2016  # removing the module's literal argument
sed -i 's/ MARK_ANSWERED="$MARK_ANSWERED"//' "$TMP/duty-attention-missing-answered.sh"
render_missing="$(render_site_missing_slots "$SHARED/prompts" "$TMP/duty-attention-missing-answered.sh")"
case "$render_missing" in *'fragment-round-rules.txt missing MARK_ANSWERED'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-attention-missing-answered-fails failed "$r1"

# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q '{{ROUND_RULES}}' "$SHARED/prompts/ci-red.txt" \
  && grep -q 'ROUND_RULES="$round_rules"' "$BMOD"; then r1=rendered; else r1=MISSING; fi
t ci-red-renders-round-rules rendered "$r1"
if grep -q 'signal is' "$SHARED/prompts/ci-red.txt" \
  && ! grep -q "let the new head's check speak for itself" "$SHARED/prompts/ci-red.txt"; then
  r1=signals
else
  r1=STALE
fi
t ci-red-fix-ends-in-signal signals "$r1"
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
case "${EVENT_PAYLOAD:-readable}:$*" in
  unreadable:*fixture/overlap*) printf '{"message":"API rate limit exceeded"}\n' ;;
  unreadable:*) printf '[{"type":"IssuesEvent","actor":{"login":"other-builder"},"payload":{"action":"assigned","assignee":{"login":"other-builder"}}}]\n' ;;
  empty:*) printf '[]\n' ;;
  readable:*) printf '[{"type":"IssuesEvent","actor":{"login":"local-triage"},"payload":{"action":"opened"}}]\n' ;;
  foreign:*) printf '[{"type":"IssuesEvent","actor":{"login":"%s"},"payload":{"action":"assigned","assignee":{"login":"%s"}}}]\n' \
        "$FOREIGN_ACTOR" "$FOREIGN_ACTOR" ;;
esac
EOF
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat >"$OFSHIM/jq" <<'EOF'
#!/usr/bin/env bash
[ -z "${JQ_SUCCESS_STDERR:-}" ] || printf '%s\n' "$JQ_SUCCESS_STDERR" >&2
exec "$REAL_JQ" "$@"
EOF
chmod +x "$OFSHIM/box" "$OFSHIM/gh" "$OFSHIM/jq"
before_registry="$(cat "$OFROOT/repos.txt")"
GH_CALLS="$TMP/overlap-gh-calls"
overlap_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$overlap_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-names-repo-and-foreign-actor named "$r1"
case "$overlap_out" in *"registries LEFT UNCHANGED"*"operators must decide"*) r1=operator ;; *) r1=actioned ;; esac
t fleet-overlap-resolution-is-operator operator "$r1"
t fleet-overlap-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

stderr_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder \
  JQ_SUCCESS_STDERR='synthetic jq warning' GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$stderr_out" in *"synthetic jq warning"*) r1=CONTAMINATED ;; *) r1=isolated ;; esac
t fleet-overlap-successful-jq-stderr-is-not-data isolated "$r1"
case "$stderr_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=preserved ;;
  *) r1=LOST ;;
esac
t fleet-overlap-successful-jq-stderr-preserves-data preserved "$r1"

disjoint_out="$(env CREW_CONFIG_DIR="$OFROOT" GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$disjoint_out" in *"WARN one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-disjoint-is-silent silent "$r1"
t fleet-disjoint-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

printf 'fixture/overlap\nfixture/zlater\n' >"$OFROOT/repos.txt"
if unreadable_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=unreadable GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"; then
  r1=survived
else
  r1=FAILED
fi
t fleet-overlap-unreadable-payload-survives survived "$r1"
case "$unreadable_out" in
  *"NOTE one-repo-one-fleet: unreadable recent board activity for fixture/overlap"*"overlap detection skipped"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-unreadable-payload-names-repo named "$r1"
case "$unreadable_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/zlater"*) r1=continued ;;
  *) r1=STOPPED ;;
esac
t fleet-overlap-unreadable-payload-continues continued "$r1"

empty_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=empty GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$empty_out" in *"one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-overlap-empty-array-is-silent silent "$r1"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
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

# --- convergence: rig's role marker, parsed (crew#220) ----------------------
# `crew hire` is crew's irreversible verb — it installs the engine and arms
# cron — and since #220 the thing that authorizes it is this parse. A box whose
# tenant role never converged was indistinguishable from a healthy one in every
# column crew had, so the marker became the discriminator; what the marker MEANS
# is decided here, in eight lines that no fixture fleet can exercise fully.
#
# Extracted and eval'd out of cli/crew, the same way valid_version above is:
# these are the shapes a real /etc/rig/role takes (heavy-duty/rig,
# commands/bootstrap-tenant.sh writes the tenant line, commands/bootstrap.sh
# the machine one) plus the hand-edited near-misses, and a stub box can only
# ever answer with one of them at a time.
# vv_extract above assumes a multi-line body, which is fine for the one
# function it takes. report_field is a ONE-LINER, and on that shape a
# stop-at-`^}` rule never fires on its own line — it runs on to the next
# function's closing brace and evals that too. It happened to be harmless here,
# which is exactly the kind of silence that stops being harmless the day
# somebody inserts a function between the two. So this one closes on its own
# line when the definition is self-contained.
cv_extract() { awk -v f="$2" '
  $0 ~ "^"f"\\(\\) \\{" { print; if ($0 ~ /\}[[:space:]]*$/) exit; p=1; next }
  p { print; if ($0 ~ /^\}$/) exit }
' "$1"; }
eval "$(cv_extract "$ROOT/cli/crew" report_field)"
eval "$(cv_extract "$ROOT/cli/crew" marker_fault)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_of)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_detail)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_recovery)"
# An extraction that came back empty leaves every assertion below testing a
# function that does not exist — and `t` between two empty strings passes. The
# suite would report the gate as covered while executing none of it, which is
# the same shape of silence the manifest parse sat in. Say so once, here.
cv_lifted=""
for cv_f in report_field marker_fault convergence_of convergence_detail convergence_recovery; do
  declare -F "$cv_f" >/dev/null || cv_lifted="$cv_lifted $cv_f"
done
t convergence-functions-lifted "" "$cv_lifted"

# A box that answered NOTHING is `unknown`, and unknown is not converged. This
# is rule 5 of #220's spec and the whole safety property: the defect closed is a
# broken box passing for a healthy one, so the case crew cannot see into must
# refuse rather than proceed. An empty capture is what an unreachable box, a
# stopped box and a `box exec` that died all produce.
t convergence-empty-capture-is-unknown unknown "$(convergence_of "")"
t convergence-no-probe-line-is-unknown unknown "$(convergence_of "marker=role=claude-box tenant=yes host=no")"

# Answered, and rig never wrote a marker: the reported case. The bootstrap
# failed, so the vendor CLI was never installed.
t convergence-answered-without-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n')")"
t convergence-empty-marker-value-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=\n')")"

# The tenant line rig actually writes.
t convergence-tenant-marker-is-converged converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box tenant=yes host=no\n')")"
# …for every agent in the bench, since the role name is data and not a fixed set.
for cv_agent in claude codex grok kimi; do
  t "convergence-tenant-marker[$cv_agent]" converged \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=%s-box tenant=yes host=no\n' "$cv_agent")")"
done
# Hand-edited with tabs or doubled spaces reads the same way, rather than
# silently failing to match — whitespace is normalised before the field test,
# exactly as rig's own root_door_of does it.
t convergence-tenant-marker-tabs-are-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box\ttenant=yes\thost=no\n')")"
t convergence-tenant-marker-double-space-is-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box  tenant=yes  host=no\n')")"

# A MACHINE marker is not an agent tenant. rig writes this shape for the
# `-server` roles and for a guest joined as a workload; a crew member is a box
# guest converged by the tenant bootstrap, and nothing else installed its
# vendor CLI.
t convergence-machine-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no join=yes join-by=rig\n')")"
t convergence-host-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=staging-server root-door=closed host=yes join=yes join-by=rig\n')")"

# HALF A MARKER is not a converged box. #220 pins the verdict on both fields —
# "parses to a non-empty `role=`, and carries `tenant=yes`" — and rig writes the
# two in one line, so a marker with one and not the other is a box interrupted
# partway through converging. Reading it as converged would hire on the strength
# of the half that happened to land.
t convergence-refuses-marker-without-a-role incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")"
t convergence-refuses-empty-role-field incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role= tenant=yes host=no\n')")"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")" in
  *"no role="*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-half-written-marker named "$r1"

# The verdict and the reason are ONE reader, so they cannot drift apart. A row
# reading INCOMPLETE beside a detail saying nothing is missing is a refusal an
# operator cannot act on, and that is what two copies of this parse decay into.
cv_disagree=""
for cv_m in 'role=claude-box tenant=yes host=no' 'role=workload-server root-door=open host=no' \
            'role= tenant=yes host=no' 'tenant=yes' 'role=claude-box tenant=yesish'; do
  cv_v="$(convergence_of "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  cv_d="$(convergence_detail "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  case "$cv_v:$cv_d" in
    converged:*|incomplete:?*) : ;;
    *) cv_disagree="$cv_disagree [$cv_m -> $cv_v / ${cv_d:-<silence>}]" ;;
  esac
done
t convergence-verdict-and-detail-agree "" "$cv_disagree"

# MUST FAIL — the field-anchoring. rig#77 is the scar: an unanchored pattern let
# `root-door=closedish` resolve as `closed` and pass the one gate authorizing an
# irreversible act. Hiring is crew's irreversible act, so a value that merely
# EXTENDS `yes`, or a key that merely ENDS in `tenant`, must not authorize it.
for cv_bad in "tenant=yesish" "tenant=yes-not" "xtenant=yes" "no-tenant=yes" "tenant=no" "tenant=YES"; do
  t "convergence-refuses-near-miss[$cv_bad]" incomplete \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box %s host=no\n' "$cv_bad")")"
done

# The three causes take three different actions, so the detail must name which
# one it is. Collapsing them into "not converged" throws away the only part of
# the refusal an operator can act on.
case "$(convergence_detail "")" in
  *"did not answer"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-unreadable-case named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\n')")" in
  *"/etc/rig/role"*"never converged"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-missing-marker named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no\n')")" in
  *"machine role"*"role=workload-server"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-quotes-the-machine-marker named "$r1"

# The recovery is the three commands `box` itself prints when the bootstrap
# hook fails, and it names the box's OWN tenant — a generic one is a command
# that fails when pasted.
t convergence-recovery-names-the-tenant \
  "box shell kimi-reviewer → sudo rig bootstrap kimi-box → box snapshot kimi-reviewer bootstrapped" \
  "$(convergence_recovery kimi-reviewer kimi)"
# An off-roster box names no agent. A placeholder an operator can fill in beats
# a malformed `rig bootstrap -box`.
case "$(convergence_recovery adhoc-box "")" in
  *"rig bootstrap <agent>-box"*) r1=placeholder ;; *) r1=MALFORMED ;;
esac
t convergence-recovery-without-an-agent-is-a-placeholder placeholder "$r1"
# It must never advise the verb that caused the incident. `crew hire` on a box
# the table told the operator to hire is the whole of #220.
case "$(convergence_recovery kimi-reviewer kimi)" in
  *"crew hire"*) r1=ADVISES_HIRE ;; *) r1=bootstrap ;;
esac
t convergence-recovery-does-not-advise-crew-hire bootstrap "$r1"

# --- convergence: rig's marker and manifest, as the real files (crew#220) ---
# THE REAL TEXT, not a fixture format. Read on 2026-08-01 from inside a
# rig-converged tenant box — the box this branch was built in, which is itself
# a rig box — with the files written by rig 0.3.2-dev on the same day:
#
#     $ ls -l /etc/rig/
#     -rw-r--r-- 1 root root 129 Aug  1 12:31 manifest
#     -rw-r--r-- 1 root root  35 Aug  1 12:31 role
#     $ cat /etc/rig/role
#     role=claude-box tenant=yes host=no
#     $ cat /etc/rig/manifest
#     schema=1
#     bootstrapped_by=0.3.2-dev
#     bootstrapped_at=2026-08-01T12:31:11Z
#     converged_by=0.3.2-dev
#     converged_at=2026-08-01T12:31:11Z
#
# The parse is asserted against THAT, byte for byte, rather than against a
# shape read out of rig's source: reading the writer tells you what rig means
# to emit, and only the artifact tells you what it emitted. Both files are
# 0644, which is the other fact this read establishes — crew's exec must not
# grow a `sudo`, because a `sudo` in a non-interactive `box exec` is itself a
# way to turn a converged box into a false INCOMPLETE.
cv_real_role='role=claude-box tenant=yes host=no'
cv_real_manifest="$(printf '%s\n' \
  'schema=1' \
  'bootstrapped_by=0.3.2-dev' \
  'bootstrapped_at=2026-08-01T12:31:11Z' \
  'converged_by=0.3.2-dev' \
  'converged_at=2026-08-01T12:31:11Z')"
# …assembled into the capture rig_report produces from them: `probe=ok`, the
# marker's first line, and the manifest prefixed a line at a time. The box side
# does no interpreting precisely so that this — the part that decides meaning —
# is reachable from here.
cv_real_report="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" \
  "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")"

t convergence-real-marker-is-converged converged "$(convergence_of "$cv_real_report")"
t convergence-real-manifest-converged-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_real_report")"
t convergence-real-manifest-converged-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_real_report")"
# The namespace, and the `^` that makes it real. `schema=1` unprefixed would
# answer a `report_field schema` somebody adds later; prefixed, and read with an
# anchor, it cannot. Drop the `^` from report_field and this is the assertion
# that reds — the namespace becomes decoration.
t convergence-real-manifest-keys-are-namespaced "" "$(report_field schema "$cv_real_report")"
t convergence-real-marker-survives-the-manifest "$cv_real_role" \
  "$(report_field marker "$cv_real_report")"

# MUST FAIL — the manifest's own `closedish`, and it is a NAMING discipline
# rather than an anchoring one. rig puts `bootstrapped_by=`/`bootstrapped_at=`
# TWO LINES ABOVE the `converged_*` pair, so any read that goes after the
# FAMILY — `.*_at=`, "grab the timestamp" — answers with the bootstrap's, which
# is the date the box was first built rather than the one that authorized the
# hire. The guard is that every read names the whole key. On the real text
# above the two pairs are equal, which is exactly why that text cannot catch it
# alone: this is the same box re-converged later by a newer rig, where they
# differ and the wrong answer is visible.
cv_reconverged="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" "$(printf '%s\n' \
  'rig:schema=1' \
  'rig:bootstrapped_by=0.3.1' \
  'rig:bootstrapped_at=2026-07-04T08:00:00Z' \
  'rig:converged_by=0.3.2-dev' \
  'rig:converged_at=2026-08-01T12:31:11Z')")"
t convergence-converged-by-is-not-bootstrapped-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_reconverged")"
t convergence-converged-at-is-not-bootstrapped-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_reconverged")"
# …and from the other direction: a PARTIAL key name gets nothing. `verged_at`
# is a tail of `converged_at`, and a read loose enough to accept it is a read
# loose enough to accept `bootstrapped_at` too — same defect, cheaper to see.
t convergence-read-refuses-a-suffix-key "" \
  "$(report_field rig:verged_at "$cv_reconverged")"

# CORROBORATING, NEVER LOAD-BEARING. A box whose rig predates the manifest
# (rig#61) has a valid role line and no provenance at all — old, not broken.
# Gating the verdict on `converged_at` would turn every box on that rig into a
# refusal, which #220's test plan names as the outcome worse than the bug.
cv_no_manifest="$(printf 'probe=ok\nmarker=%s\n' "$cv_real_role")"
t convergence-without-a-manifest-is-still-converged converged "$(convergence_of "$cv_no_manifest")"
t convergence-without-a-manifest-reports-no-provenance "" \
  "$(report_field rig:converged_by "$cv_no_manifest")"
# …and the inverse must not rescue anything: a full manifest beside a role file
# that never got written is still INCOMPLETE. The manifest cannot vouch for a
# convergence the marker does not claim.
t convergence-manifest-without-a-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n%s\n' "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")")"

# The marker path is rig's, and it is not crew's to invent. Asserted against the
# source so a refactor that "tidies" it to a crew-shaped path is caught here
# rather than on a real host — crew reads what rig writes, and rig writes these
# two (rig#61 for the manifest).
if grep -q '/etc/rig/role' "$ROOT/cli/crew" && grep -q '/etc/rig/manifest' "$ROOT/cli/crew"; then
  r1=rigs
else
  r1=INVENTED
fi
t convergence-reads-rigs-own-paths rigs "$r1"

# Both files are 0644 on a real box, so the read takes no privilege — and must
# never acquire one. A `sudo` in a NON-INTERACTIVE `box exec` prompts, or fails,
# and either way turns a converged box into a false INCOMPLETE: the refusal
# would then be crew's own doing, on a box that was fine.
if cv_extract "$ROOT/cli/crew" rig_report | grep -q 'sudo'; then
  r1=ESCALATES
else
  r1=unprivileged
fi
t convergence-reads-the-marker-without-sudo unprivileged "$r1"
# …and it goes through bxn, never a fresh literal `box exec`. This helper runs
# inside `while read … done < <(read_roster)` in status, hire-all and up, and a
# raw exec there drains the roster FIFO and converges ONE box out of N with
# rc=0 (#48). bxn is the only shape that pins stdin to /dev/null.
if cv_extract "$ROOT/cli/crew" rig_report | grep -qE '^[[:space:]]*bxn ' &&
   ! cv_extract "$ROOT/cli/crew" rig_report | grep -q 'box exec'; then
  r1=bxn
else
  r1=RAW_EXEC
fi
t convergence-reads-the-marker-through-bxn bxn "$r1"

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

# `up --dry-run` must describe the hire that follows a create (#218). Drive a
# mixed roster through the real CLI in both modes: the box shim records the
# convergence probe at the top of every real hire_box call, giving the
# equality property without copying cmd_up's roster arithmetic into the test.
UPCONF="$TMP/up-dry-run-config"
UPSHIM="$TMP/up-dry-run-bin"
UPSTATE="$TMP/up-dry-run-state"
UPCALLS="$TMP/up-dry-run-calls"
UP_VERSION="$(head -1 "$ROOT/VERSION" | tr -d '\r\n')"
mkdir -p "$UPCONF" "$UPSHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$UPCONF/"
cat >"$UPCONF/fleet.roster" <<'EOF'
fresh claude builder
running codex reviewer
stopped kimi reviewer
EOF
cat >"$UPSHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat >"$UPSHIM/box" <<'EOF'
#!/usr/bin/env bash
json_state() {
  awk 'BEGIN { printf "[" } { printf "%s{\"name\":\"%s\",\"status\":\"%s\"}", sep, $1, $2; sep="," } END { print "]" }' "$UPSTATE"
}
case "$1" in
  list) json_state ;;
  info)
    state="$(awk -v name="$2" '$1 == name { print $2; exit }' "$UPSTATE")"
    printf '[{"name":"%s","status":"%s"}]\n' "$2" "$state"
    ;;
  new)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s running\n' "$name" >>"$UPSTATE"
    printf 'mutate:new:%s\n' "$name" >>"$UPCALLS"
    ;;
  start)
    printf 'mutate:start:%s\n' "$2" >>"$UPCALLS"
    ;;
  exec)
    name="$2"
    script="${*: -1}"
    case "$script" in
      *'/etc/rig/role'*)
        printf 'hire:%s\n' "$name" >>"$UPCALLS"
        printf 'probe=ok\nmarker=role=fixture tenant=yes host=no\n'
        ;;
      *'engine-manifest.sh'*)
        printf 'engine:%s\n' "$name" >>"$UPCALLS"
        printf 'state=current\nstamp=crew@%s fixture\nrecorded=crew@%s fixture\n' "$UP_VERSION" "$UP_VERSION"
        ;;
      *'repos.txt'*) printf 'fixture/operator-repo\n' ;;
      *) printf 'exec:%s\n' "$name" >>"$UPCALLS" ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$UPSHIM/gh" "$UPSHIM/box"
up_reset() {
  printf 'running running\nstopped stopped\n' >"$UPSTATE"
  : >"$UPCALLS"
}
up_run() {
  env CREW_CONFIG_DIR="$UPCONF" UPSTATE="$UPSTATE" UPCALLS="$UPCALLS" UP_VERSION="$UP_VERSION" \
    PATH="$UPSHIM:$PATH" bash "$CLIBIN" up "$@"
}

: >"$UPSTATE"
: >"$UPCALLS"
if up_new_out="$(up_run --dry-run 2>&1)"; then up_new_rc=0; else up_new_rc=$?; fi
t cli-up-dry-run-all-new-exits-zero 0 "$up_new_rc"
t cli-up-dry-run-all-new-reports-every-create 3 \
  "$(grep -c ': WOULD create ' <<<"$up_new_out" || true)"
t cli-up-dry-run-all-new-reports-every-hire 3 \
  "$(grep -c ": WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_new_out" || true)"
case "$up_new_out" in
  *'up --dry-run: 3 would be created, 0 started, 3 hired'*) r1=complete ;;
  *) r1="$up_new_out" ;;
esac
t cli-up-dry-run-all-new-summary complete "$r1"
t cli-up-dry-run-all-new-touches-nothing "" "$(cat "$UPCALLS")"

up_reset
if up_dry_out="$(up_run --dry-run 2>&1)"; then up_dry_rc=0; else up_dry_rc=$?; fi
t cli-up-dry-run-mixed-exits-zero 0 "$up_dry_rc"
t cli-up-dry-run-new-box-hires 1 \
  "$(grep -c "^fresh: WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_dry_out" || true)"
t cli-up-dry-run-existing-wording 2 \
  "$(grep -c ": WOULD hire (currently: crew@$UP_VERSION fixture)$" <<<"$up_dry_out" || true)"
case "$up_dry_out" in
  *'up --dry-run: 1 would be created, 1 started, 3 hired'*) r1=complete ;;
  *) r1="$up_dry_out" ;;
esac
t cli-up-dry-run-summary complete "$r1"
t cli-up-dry-run-does-not-mutate "" "$(grep '^mutate:' "$UPCALLS" || true)"
t cli-up-dry-run-does-not-probe-new-box "" "$(grep ':fresh$' "$UPCALLS" || true)"
dry_hires="$(grep -c ': WOULD hire ' <<<"$up_dry_out" || true)"

up_reset
if up_run >/dev/null 2>&1; then up_real_rc=0; else up_real_rc=$?; fi
t cli-up-real-run-mixed-exits-zero 0 "$up_real_rc"
t cli-up-dry-run-hire-count-matches-real "$dry_hires" \
  "$(grep -c '^hire:' "$UPCALLS" || true)"
t cli-up-real-run-still-creates-and-starts 'mutate:new:fresh
mutate:start:stopped' "$(grep '^mutate:' "$UPCALLS" || true)"

# create-all is a fleet convergence verb: one failed box must not prevent the
# remaining roster rows from being attempted, and the final report is the
# operator's record of the partial run (#219).
CACONF="$TMP/create-all-config"
CASHIM="$TMP/create-all-bin"
CA_CALLS="$TMP/create-all-calls"
mkdir -p "$CACONF" "$CASHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$CACONF/"
cat >"$CACONF/fleet.roster" <<'EOF'
one claude triage
two codex builder
three grok reviewer
four kimi reviewer
five claude reviewer
six codex reviewer
seven grok reviewer
EOF
cat >"$CASHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '%s\n' "${BOX_LIST:-[]}" ;;
  new)
    name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$name" >>"$CA_CALLS"
    [ "$name" != "${FAIL_NAME:-}" ]
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CASHIM/box"
ca_run() {
  env CREW_CONFIG_DIR="$CACONF" CA_CALLS="$CA_CALLS" \
    BOX_LIST="${BOX_LIST:-[]}" FAIL_NAME="${FAIL_NAME:-}" \
    PATH="$CASHIM:$PATH" bash "$CLIBIN" create-all
}
BOX_LIST='[{"name":"three"}]' FAIL_NAME=four
: >"$CA_CALLS"
if ca_out="$(ca_run 2>&1)"; then ca_rc=0; else ca_rc=$?; fi
t cli-create-all-partial-is-nonzero 1 "$ca_rc"
t cli-create-all-continues-after-failure "one
two
four
five
six
seven" "$(cat "$CA_CALLS")"
case "$ca_out" in
  *"create-all: 5 created, 1 existing, 1 failed (four)."*) r1=complete ;;
  *) r1="$ca_out" ;;
esac
t cli-create-all-partial-summary complete "$r1"

# The all-pass path retains the established closing text byte-for-byte.
BOX_LIST='[]' FAIL_NAME=''
: >"$CA_CALLS"
if ca_all_out="$(ca_run 2>&1)"; then ca_all_rc=0; else ca_all_rc=$?; fi
t cli-create-all-all-pass-is-zero 0 "$ca_all_rc"
case "$ca_all_out" in
  *"7 created. Next: log each new box in by hand"*) r1=unchanged ;;
  *) r1="$ca_all_out" ;;
esac
t cli-create-all-all-pass-summary-unchanged unchanged "$r1"

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

# --- the examples fallback creates and arms NOTHING (#216) ------------------
# A host with no operator config at all resolves to $CREW_ROOT/examples and,
# before this, presented as a fully configured seven-box fleet: `crew up`
# there created seven boxes and armed cron against the three live
# repositories the shipped registry then named. The fallback itself stays —
# it is deliberate and the config rehearsal covers it. What it loses is the
# ability to create or arm.
#
# The fixture must reproduce the REPORTED environment exactly, because every
# other test in this file arrives here through a configured path: HOME with no
# .config/crew, XDG unset, CREW_CONFIG_DIR unset, and a $PWD carrying no
# fleet.roster. Get any one of those wrong and resolution lands on an operator
# directory, CONFIG_IS_OPERATOR is 1, and the whole block asserts nothing.
FBHOME="$TMP/fallback-home"
FBPWD="$TMP/fallback-pwd"
mkdir -p "$FBHOME" "$FBPWD"
fbcrew() {  # stdout+stderr, from the unconfigured host
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
fbrc() {
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1)
  echo $?
}

# The fixture proves itself first: if this says operator, every assertion
# below is vacuous.
case "$(fbcrew status)" in
  *"NO operator fleet definition"*) r1=fallback ;;
  *) r1=OPERATOR ;;
esac
t cli-fallback-fixture-is-really-the-fallback fallback "$r1"

# Every mutating verb refuses, and every one of them names `crew init` — the
# refusal is only useful if it says what to do instead. Asserted per verb
# rather than on a sample: the defect was per-call-site and so is the fix.
#
# `floor` refuses too (#244) and is deliberately NOT in this list: fbrc runs
# each spec in the FOREGROUND with no timeout, so a regressed floor refusal
# would serve until the CI job's own limit rather than fail here. Its cases
# live in fleet-floor/test/cli.sh, which owns the verb, caps every process it
# starts and watches the port. Add it here and this suite hangs on the day the
# assertion matters.
refused="" unnamed=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  [ "$(fbrc $spec)" != 0 ] || refused="$refused [$spec]"
  # shellcheck disable=SC2086
  case "$(fbcrew $spec)" in *"crew init"*) : ;; *) unnamed="$unnamed [$spec]" ;; esac
done <<'SPECS'
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-fallback-mutating-verbs-refuse "" "$refused"
t cli-fallback-refusal-names-crew-init "" "$unnamed"

# ...and the read-only verbs still WORK, because inspecting a host in this
# state is exactly what they are for. A fix that made `crew status` refuse
# would take away the one instrument that explains the refusals.
t cli-fallback-status-still-works   0 "$(fbrc status)"
t cli-fallback-profiles-still-works 0 "$(fbrc profiles)"
t cli-fallback-dry-run-still-works  0 "$(fbrc up --dry-run)"

# Each of them says what it is reading. The reported symptom was a table
# nobody could tell apart from a configured fleet's, so the banner is the
# fix's user-visible half and is asserted by content, not by presence.
bannerless=""
for verb in status profiles; do
  case "$(fbcrew "$verb")" in
    *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
    *) bannerless="$bannerless [$verb]" ;;
  esac
done
case "$(fbcrew up --dry-run)" in
  *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
  *) bannerless="$bannerless [up --dry-run]" ;;
esac
t cli-fallback-read-only-verbs-banner "" "$bannerless"

# The banner is on stderr, so the tables stay machine-readable: a row-parsing
# caller must not have to filter it back out. This is the assertion that keeps
# a later "make it more visible" edit from breaking every such caller silently.
fb_stdout="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>/dev/null) )"
case "$fb_stdout" in
  *"NO operator fleet definition"*) r1=ON_STDOUT ;;
  *MEMBER*) r1=rows-only ;;
  *) r1="$fb_stdout" ;;
esac
t cli-fallback-banner-is-on-stderr rows-only "$r1"

# THE REGRESSION THAT MATTERS MORE THAN THE BUG: a real fleet must behave
# exactly as before. A fix that makes configured hosts refuse is a fleet
# outage; the bug it replaces is one confusing table.
OPCONF="$TMP/op-config"
mkdir -p "$OPCONF"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPCONF/"
printf '# an operator registry\nfixture/operator-repo\n' >"$OPCONF/repos.txt"
printf '# an operator notify registry\nfixture/operator-repo\n' >"$OPCONF/notify-repos.txt"
opcrew() {
  (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER CREW_CONFIG_DIR="$OPCONF" \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
overreach=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  case "$(opcrew $spec)" in
    *"refuses under the shipped example"*|*"NO operator fleet definition"*)
      overreach="$overreach [$spec]" ;;
  esac
done <<'SPECS'
status
profiles
up --dry-run
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-operator-config-never-refused-or-bannered "" "$overreach"

# $PWD discovery is an operator definition too — the third resolution hop, and
# the one a developer running crew from a config directory relies on. Banner
# it and this fix breaks that workflow.
pwdcrew_out="$(cd "$OPCONF" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>&1)"
case "$pwdcrew_out" in
  *"NO operator fleet definition"*) r1=BANNERED ;;
  *) r1=clean ;;
esac
t cli-pwd-discovery-is-operator clean "$r1"

# The shipped registry ships EMPTY. Asserted by parsing rather than by diffing
# a literal, so a future edit that re-adds a live repository reds this instead
# of shipping a scaffold aimed at somebody else's board.
t cli-examples-registry-is-empty 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$ROOT/examples/repos.txt" || true)"

# ...and the same must be true one hop later, of what an operator actually
# gets: `crew init` seeds from examples/, so a fresh fleet definition starts
# aimed at nothing and stays that way until the operator names a repo.
INIT_TARGET="$TMP/init-seeded"
init_rc="$(fbrc init "$INIT_TARGET")"
t cli-init-still-works-under-fallback 0 "$init_rc"
t cli-init-seeds-an-empty-registry 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$INIT_TARGET/repos.txt" 2>/dev/null || true)"

# Validation parity: the completeness check ran only for operator definitions,
# so the LEAST trusted directory got the LEAST verification. Both directions
# are asserted, because the property is that the check does not care who wrote
# the directory.
FBROOT="$TMP/fallback-root"
mkdir -p "$FBROOT/cli"
cp "$CLIBIN" "$FBROOT/cli/crew"
cp "$ROOT/VERSION" "$FBROOT/VERSION"
ln -s "$SHARED" "$FBROOT/shared"
cp -R "$ROOT/examples" "$FBROOT/examples"
rm -f "$FBROOT/examples/repos.txt"
fb_incomplete="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT/cli/crew" status 2>&1) )"
case "$fb_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$fb_incomplete" ;;
esac
t cli-fallback-incompleteness-is-fatal refused "$r1"

# fleet.conf is named by the same criterion, so it is asserted by the same
# route rather than assumed to follow from repos.txt.
FBROOT2="$TMP/fallback-root-noconf"
mkdir -p "$FBROOT2/cli"
cp "$CLIBIN" "$FBROOT2/cli/crew"
cp "$ROOT/VERSION" "$FBROOT2/VERSION"
ln -s "$SHARED" "$FBROOT2/shared"
cp -R "$ROOT/examples" "$FBROOT2/examples"
rm -f "$FBROOT2/examples/fleet.conf"
fb_noconf="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT2/cli/crew" status 2>&1) )"
case "$fb_noconf" in
  *"is incomplete; missing: fleet.conf"*) r1=refused ;;
  *) r1="$fb_noconf" ;;
esac
t cli-fallback-missing-fleet-conf-is-fatal refused "$r1"

OPINCOMPLETE="$TMP/op-incomplete"
mkdir -p "$OPINCOMPLETE"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPINCOMPLETE/"
op_incomplete="$( (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER \
  CREW_CONFIG_DIR="$OPINCOMPLETE" HOME="$FBHOME" PATH="$CLISHIM:$PATH" \
  bash "$CLIBIN" status 2>&1) )"
case "$op_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$op_incomplete" ;;
esac
t cli-operator-incompleteness-is-fatal refused "$r1"

# --- CI split: route the browser walk without dropping coverage (#138) -----
# Repo furniture, in the same family as valid_version-parity above: assertions
# about a file the engine never executes, kept here because the property is
# anti-drift and every way of losing it is silent.
CI_SHELL="$ROOT/.github/workflows/ci-shell.yml"
CI_FLOOR="$ROOT/.github/workflows/ci-floor.yml"

ci_paths() {
  trigger="$1"
  workflow="$2"
  awk -v trigger="$trigger" '
    $0 == "  " trigger ":" { in_trigger = 1; next }
    in_trigger && /^  [[:alnum:]_-]+:/ { exit }
    in_trigger && /^    paths: \[/ {
      sub(/^    paths: \[/, "")
      sub(/\]$/, "")
      print
    }
  ' "$workflow" \
    | tr ',' '\n' | tr -d " '\"" | sed '/^$/d' | sort -u
}

# The old filter's product paths survive across the union. Its deleted
# self-path is replaced by both new workflows' paths. ci-floor.yml also routes
# to ci-shell so edits to that workflow run the assertions below; it is the one
# intentional overlap. Explicitly naming .ceremony/** prevents two
# mutually-agreeing filters from dropping the path that caught #363.
CI_EXPECTED="$(printf '%s\n' \
  '.ceremony/**' '.github/workflows/ci-floor.yml' '.github/workflows/ci-shell.yml' \
  'cli/**' 'dist/**' 'drill/**' 'examples/**' 'fleet-floor/**' 'install.sh' 'shared/**' | sort)"
CI_SHELL_PR_PATHS="$(ci_paths pull_request "$CI_SHELL")"
CI_FLOOR_PR_PATHS="$(ci_paths pull_request "$CI_FLOOR")"
CI_UNION="$(printf '%s\n%s\n' "$CI_SHELL_PR_PATHS" "$CI_FLOOR_PR_PATHS")"
t ci-path-union-preserves-coverage "$CI_EXPECTED" "$(printf '%s\n' "$CI_UNION" | sort -u)"
CI_OVERLAP="$(comm -12 <(printf '%s\n' "$CI_SHELL_PR_PATHS") <(printf '%s\n' "$CI_FLOOR_PR_PATHS"))"
t ci-path-overlap-is-only-floor-self-edit '.github/workflows/ci-floor.yml' "$CI_OVERLAP"
case "$CI_SHELL_PR_PATHS" in *'.ceremony/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shell-keeps-ceremony-fixtures present "$r1"
case "$CI_SHELL_PR_PATHS" in *'.github/workflows/ci-floor.yml'*) r1=present ;; *) r1=MISSING ;; esac
t ci-floor-self-edit-routes-to-shell present "$r1"

# The three routing cases, plus the load-bearing CLI coverage on the cheap
# side. Native paths do the routing; a billed filter job is forbidden.
ci_shell_paths="$CI_SHELL_PR_PATHS"
case "$ci_shell_paths" in *'shared/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shared-routes-to-shell present "$r1"
case "$ci_shell_paths" in *'cli/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-cli-routes-to-shell present "$r1"
case "$CI_FLOOR_PR_PATHS" in *'fleet-floor/**'*) r1=floor ;; *) r1=MISSING ;; esac
t ci-fleet-floor-routes-to-floor floor "$r1"
if grep -q 'fleet-floor/test/run.sh --no-browser' "$CI_SHELL"; then r1=covered; else r1=DROPPED; fi
t ci-shell-runs-floor-cli-fixtures covered "$r1"
if grep -Eq 'paths-filter|filter-changes|changes:' "$CI_SHELL" "$CI_FLOOR"; then r1=BILLED; else r1=native; fi
t ci-routing-uses-native-paths native "$r1"

# Both workflows inherit the draft wake/gate, per-ref cancellation and the
# push-to-main post-merge run. A missing half is a checkless current head.
for ci_yml in "$CI_SHELL" "$CI_FLOOR"; do
  ci_name="$(sed -n 's/^name: //p' "$ci_yml")"
  ci_types=",$(sed -n 's/^ *types: *\[\(.*\)\].*$/\1/p' "$ci_yml" | tr -d ' '),"
  for ev in opened synchronize reopened ready_for_review; do
    case "$ci_types" in *",$ev,"*) r1=present ;; *) r1=MISSING ;; esac
    t "$ci_name-trigger-fires-on[$ev]" present "$r1"
  done
  ci_if="$(awk '/^  check:/{p=1} p && /^    if:/{print; exit}' "$ci_yml")"
  case "$ci_if" in *github.event.pull_request.draft*) r1=payload ;; *) r1=MISSING ;; esac
  t "$ci_name-gates-on-draft-payload" payload "$r1"
  case "$ci_if" in *state:*|*label*) r1=LABEL ;; *) r1=payload-only ;; esac
  t "$ci_name-gate-is-not-label" payload-only "$r1"
  case "$ci_if" in *github.event_name*) r1=explicit ;; *) r1=COERCION ;; esac
  t "$ci_name-push-exemption-is-explicit" explicit "$r1"
  t "$ci_name-pushes-run-on-main" 1 "$(grep -c '^    branches: \[main\]$' "$ci_yml")"
  t "$ci_name-push-preserves-union-filter" "$CI_EXPECTED" "$(ci_paths push "$ci_yml")"
  ci_group="$(sed -n 's/^  group: *//p' "$ci_yml")"
  # shellcheck disable=SC2016  # Match the literal GitHub expression in YAML.
  case "$ci_group" in *'${{ github.ref }}'*) r1=per-ref ;; *) r1=TOO-COARSE ;; esac
  t "$ci_name-concurrency-is-per-ref" per-ref "$r1"
  t "$ci_name-cancels-superseded-runs" 1 "$(grep -c '^  cancel-in-progress: true$' "$ci_yml")"
done

# Every old step is routed. The expensive browser invocation exists only on
# the floor side; the cheap side still executes the headless floor/CLI suite.
t ci-check-names-are-distinct 2 \
  "$(sed -n 's/^    name: \(ci-.*\)$/\1/p' "$CI_SHELL" "$CI_FLOOR" | sort -u | wc -l | tr -d ' ')"
for command in 'shared/test/run.sh' 'shared/test/install-lifecycle.sh' \
  'shared/test/artifact.sh' 'shared/test/install-drill.sh'; do
  t "ci-shell-keeps[$command]" 1 "$(grep -Fc "run: $command" "$CI_SHELL")"
done
t ci-floor-keeps-python-syntax 1 "$(grep -Fc 'python3 -m py_compile fleet-floor/server/floor.py' "$CI_FLOOR")"
t ci-floor-keeps-browser-gate 1 "$(grep -Fc 'FLOOR_TEST_REQUIRE_BROWSER=1 fleet-floor/test/run.sh' "$CI_FLOOR")"
t ci-floor-keeps-built-page-check 1 "$(grep -Fc 'git diff --exit-code -- fleet-floor/index.html' "$CI_FLOOR")"
# shellcheck disable=SC2016  # Match the literal loop variable in workflow YAML.
t ci-floor-keeps-bash-syntax 1 "$(grep -Fc 'bash -n "$f"' "$CI_FLOOR")"
t ci-floor-keeps-shellcheck 1 "$(grep -c '^      - name: shellcheck (floor)$' "$CI_FLOOR")"

# The cheap cross-layer contracts that make a browser skip safe (#138 edges 1
# and 6). cmd_floor must keep the server/build/env bridge, and every operator
# command the console names must remain in the CLI's dispatch table.
CI_CREW="$ROOT/cli/crew"
CI_FLOOR_FN="$(sed -n '/^cmd_floor()/,/^}/p' "$CI_CREW")"
case "$CI_FLOOR_FN" in *'fleet-floor/index.html'*'CREW_FLOOR_PORT='*'CREW_FLOOR_BIND='*'CREW_FLOOR_USER='*'CREW_FLOOR_PASS='*'CREW_FLOOR_INTERVAL='*'CREW_FLOOR_ROSTER='*'fleet-floor/server/floor.py'*) r1=bridged ;; *) r1=BROKEN ;; esac
t cli-floor-server-contract bridged "$r1"
CI_CONSOLE_VERBS='down floor hire init new profiles status up upgrade'
CI_CONSOLE_PROSE_VERBS='and cut hangs makes on reads stopped would'
CI_CONSOLE_CANDIDATES="$(grep -ohE 'crew [a-z][a-z-]*' \
  "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" \
  | sed 's/^crew //' | sort -u \
  | grep -Ev "^($(printf '%s' "$CI_CONSOLE_PROSE_VERBS" | tr ' ' '|'))$")"
t floor-named-crew-verb-roster-is-complete "$CI_CONSOLE_VERBS" \
  "$(printf '%s\n' "$CI_CONSOLE_CANDIDATES" | paste -sd ' ' -)"
CI_COMMAND_ROWS="$(sed -n '/^CMDS=(/,/^)/p' "$CI_CREW")"
for verb in $CI_CONSOLE_VERBS; do
  if grep -q "crew $verb" "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" &&
     printf '%s\n' "$CI_COMMAND_ROWS" | grep -q "^  \"$verb\\^"; then
    r1=dispatchable
  else
    r1=MISSING
  fi
  t "floor-named-crew-verb-dispatches[$verb]" dispatchable "$r1"
done

# --- #159: the stamp is a claim, the manifest is the evidence ---------------
# ~/duty/VERSION said what was SHIPPED and nothing ever looked at what was
# THERE, so a hand-edited engine reported as in-sync and the next upgrade
# deleted the edit in silence. Three surfaces, asserted in order: the
# instrument, the installer that records and refuses, and the status the
# operator reads.

# --- the instrument, against a scratch tree -------------------------------
EM="$SHARED/bin/engine-manifest.sh"
EMDUTY="$TMP/manifest-duty"
mkdir -p "$EMDUTY/bin" "$EMDUTY/lib/jq" "$EMDUTY/prompts" "$EMDUTY/conf/roles" "$EMDUTY/conf/agents"
printf 'echo duty\n'    >"$EMDUTY/bin/duty.sh"
printf 'common\n'       >"$EMDUTY/lib/common.sh"
printf '.a\n'           >"$EMDUTY/lib/jq/x.jq"
printf 'prompt\n'       >"$EMDUTY/prompts/p.txt"
printf 'role\n'         >"$EMDUTY/conf/roles/reviewer.conf"
printf 'agent\n'        >"$EMDUTY/conf/agents/claude.conf"
printf 'defaults\n'     >"$EMDUTY/conf/fleet.defaults.conf"
printf 'crew@9.9.9 (deadbee)\ninstalled 2026-07-29T00:00:00Z\n' >"$EMDUTY/VERSION"
em() { env DUTY_DIR="$EMDUTY" bash "$EM" "$@"; }
em_field() { em --report | sed -n "s/^$1=//p" | head -1; }

# A box with an engine and no record is UNVERIFIED, never modified: on the day
# this ships every box in the fleet is in exactly this state, and a fleet-wide
# false alarm is how an instrument gets ignored forever.
t manifest-no-record-is-unverified unverified "$(em_field state)"
t manifest-no-record-has-no-recorded-version "" "$(em_field recorded)"
em --record
t manifest-after-record-is-current current "$(em_field state)"
t manifest-records-the-stamp "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# MUST FAIL: a hash over names and mtimes. touch moves every mtime and no
# content, and a same-size edit moves content and no size.
touch "$EMDUTY/bin/duty.sh" "$EMDUTY/lib/common.sh"
t manifest-touch-is-not-modification current "$(em_field state)"
printf 'echo DUTY\n' >"$EMDUTY/bin/duty.sh"   # same byte count, different bytes
t manifest-same-size-edit-is-modified modified "$(em_field state)"
t manifest-edit-names-the-path "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"
t manifest-modified-still-names-its-version "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# Re-shipping identical bytes converges: the same content hashes the same, so a
# converging re-run stays converging and still says so.
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-identical-bytes-converge current "$(em_field state)"

# An added file and a deleted one are somebody's hand on the box too, and the
# hashes alone cannot tell them apart from each other — the names must be in
# the manifest, which is why it is a listing and not one digest.
printf 'hotfix\n' >"$EMDUTY/bin/hotfix.sh"
t manifest-added-file-is-detected modified "$(em_field state)"
t manifest-added-file-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh" "$EMDUTY/lib/jq/x.jq"
t manifest-deleted-file-is-named "path=removed lib/jq/x.jq" "$(em --report --paths | grep '^path=')"
printf '.a\n' >"$EMDUTY/lib/jq/x.jq"

# MUST FAIL: enumerating `-type f`. find does not follow symlinks, so a symlink
# is neither `f` nor `d` and a -type f walk goes straight past it — one
# `ln -s /anything ~/duty/bin/hotfix.sh` was an executable path the record
# never named and every upgrade certified clean.
ln -s /bin/sh "$EMDUTY/bin/hotfix.sh"
t manifest-added-symlink-is-detected modified "$(em_field state)"
t manifest-added-symlink-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh"
t manifest-after-symlink-removed-is-current current "$(em_field state)"

# A symlink is hashed by what it IS, never by what it points at. sha256sum on a
# link silently hashes the referent, so a shipped file replaced by a link to a
# byte-identical copy elsewhere would read `current` while the engine executes
# a file the record never measured.
cp "$EMDUTY/bin/duty.sh" "$TMP/manifest-duty-elsewhere.sh"
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/manifest-duty-elsewhere.sh" "$EMDUTY/bin/duty.sh"
t manifest-file-swapped-for-link-is-modified modified "$(em_field state)"
t manifest-file-swapped-for-link-is-named "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"

# ...and the same link DANGLING must still be a verdict, not a crash: sha256sum
# on a broken link fails, and under `pipefail` that would take state() down with
# it — the instrument going silent on the one box that needs it.
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/no-such-file-anywhere" "$EMDUTY/bin/duty.sh"
if em --state >/dev/null 2>&1; then r1=0; else r1=$?; fi
t manifest-dangling-link-does-not-crash 0 "$r1"
t manifest-dangling-link-is-modified modified "$(em_field state)"
rm -f "$EMDUTY/bin/duty.sh"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"

# Nor is a symlink the only entry a -type f walk misses; the rule that survives
# review is the simple one — under an engine root, anything that is not a
# directory is engine surface.
mkfifo "$EMDUTY/lib/pipe"
t manifest-added-fifo-is-detected modified "$(em_field state)"
t manifest-added-fifo-is-named "path=added lib/pipe" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/lib/pipe"

# An engine ROOT replaced by a symlink is the same hole one level up: the link
# must be named AND the tree behind it still measured, or an operator redirects
# bin/ and every file the engine runs goes unread.
mkdir -p "$TMP/manifest-elsewhere-bin"
mv "$EMDUTY/bin/duty.sh" "$TMP/manifest-elsewhere-bin/duty.sh"
rmdir "$EMDUTY/bin"
ln -s "$TMP/manifest-elsewhere-bin" "$EMDUTY/bin"
t manifest-redirected-root-is-named "path=added bin" "$(em --report --paths | grep '^path=')"
printf 'echo TAMPERED\n' >"$TMP/manifest-elsewhere-bin/duty.sh"
t manifest-redirected-root-still-measures-content \
  "path=added bin
path=modified bin/duty.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin"
mkdir -p "$EMDUTY/bin"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-after-root-restored-is-current current "$(em_field state)"

# Every root install.sh writes into is covered — a gap here is a file an
# operator can edit invisibly, and the list is easy to under-fill by hand.
for f in bin/duty.sh lib/common.sh lib/jq/x.jq prompts/p.txt \
         conf/roles/reviewer.conf conf/agents/claude.conf conf/fleet.defaults.conf; do
  printf 'tampered\n' >>"$EMDUTY/$f"
  t "manifest-covers[$f]" modified "$(em_field state)"
  case "$f" in
    bin/duty.sh)              printf 'echo duty\n' >"$EMDUTY/$f" ;;
    lib/common.sh)            printf 'common\n'    >"$EMDUTY/$f" ;;
    lib/jq/x.jq)              printf '.a\n'        >"$EMDUTY/$f" ;;
    prompts/p.txt)            printf 'prompt\n'    >"$EMDUTY/$f" ;;
    conf/roles/reviewer.conf) printf 'role\n'      >"$EMDUTY/$f" ;;
    conf/agents/claude.conf)  printf 'agent\n'     >"$EMDUTY/$f" ;;
    *)                        printf 'defaults\n'  >"$EMDUTY/$f" ;;
  esac
done
t manifest-restored-tree-is-current current "$(em_field state)"

# Per-box state and configuration are OUT of the manifest, each for its own
# reason: duty.log and the work trees change on every tick; instance.conf is
# machine-derived and the drill itself appends to it (rehearsal.sh's
# AUTO_APPROVE_REREQUEST fixture); fleet.conf is transported on every install;
# the registries carry their own divergence provenance in apply_registry.
# Any of these inside the manifest reports a healthy fleet as modified.
mkdir -p "$EMDUTY/work" "$EMDUTY/trees" "$EMDUTY/logs"
printf 'tick\n'                     >"$EMDUTY/duty.log"
printf 'AUTO_APPROVE_REREQUEST=0\n' >"$EMDUTY/conf/instance.conf"
printf 'FLEET_BENCH="x"\n'          >"$EMDUTY/conf/fleet.conf"
printf 'owner/repo\n'               >"$EMDUTY/repos.txt"
printf 'scratch\n'                  >"$EMDUTY/work/session.json"
t manifest-ignores-per-box-state current "$(em_field state)"

# A record this shape cannot read is unverified, not modified: the algorithm
# ships WITH the engine, so a record from another format version must never
# read as somebody's edit.
cp "$EMDUTY/.engine-manifest" "$TMP/manifest-v1-backup"
sed -i '1s/.*/# crew-engine-manifest v99 crew@9.9.9/' "$EMDUTY/.engine-manifest"
t manifest-foreign-format-is-unverified unverified "$(em_field state)"
cp "$TMP/manifest-v1-backup" "$EMDUTY/.engine-manifest"

# No engine at all is `absent`, which is not a fault to report — it is `crew
# hire`, and the status table already says so.
mv "$EMDUTY/VERSION" "$TMP/manifest-version-backup"
t manifest-no-engine-is-absent absent "$(em_field state)"
mv "$TMP/manifest-version-backup" "$EMDUTY/VERSION"

# --- the installer: records, then refuses ---------------------------------
# Real installs into a scratch DUTY_DIR, through the same curated PATH the
# other installer fixtures use.
MHOME="$TMP/manifest-install-home"
MDUTY="$MHOME/duty"
mkdir -p "$MHOME"
minstall() {
  env HOME="$MHOME" DUTY_DIR="$MDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}
mstate() { env DUTY_DIR="$MDUTY" bash "$EM" --state; }
minstall >/dev/null 2>&1
t install-records-a-manifest current "$(mstate)"
t install-manifest-names-the-version "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" \
  "$(env DUTY_DIR="$MDUTY" bash "$EM" --report | sed -n 's/^recorded=//p')"

# The converging re-run: identical bytes, so the box is still current and the
# installer does not refuse itself.
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-reship-identical-rc 0 "$r1"
t install-reship-identical-stays-current current "$(mstate)"

# The half of this issue that loses work: a modified tree is REFUSED, and
# nothing is written.
printf '# hotfix by hand\n' >>"$MDUTY/bin/duty.sh"
hotfix_before="$(cat "$MDUTY/bin/duty.sh")"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-modified-rc 1 "$r1"
case "$refuse_out" in *"REFUSING to overwrite a MODIFIED engine"*) r1=refused ;; *) r1=SILENT ;; esac
t install-refusal-is-loud refused "$r1"
case "$refuse_out" in *"modified bin/duty.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-path named "$r1"
case "$refuse_out" in *"crew@$(head -1 "$ROOT/VERSION")"*) r1=versioned ;; *) r1=BARE ;; esac
t install-refusal-names-the-version versioned "$r1"
t install-refusal-changes-nothing "$hotfix_before" "$(cat "$MDUTY/bin/duty.sh")"

# --force is the whole escape hatch, and it must actually proceed.
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-proceeds-rc 0 "$r1"
case "$(cat "$MDUTY/bin/duty.sh")" in *"hotfix by hand"*) r1=SURVIVED ;; *) r1=overwritten ;; esac
t install-force-overwrites overwritten "$r1"
t install-force-re-records-current current "$(mstate)"

# The other half of --force, and the reason it is an escape hatch rather than a
# laundering step: a file the incoming tree does not ship must not RIDE THROUGH
# it. Copying over matching names converges every file the tree has and says
# nothing about one it does not, so before this an added ~/duty/bin/hotfix.sh
# was refused, then survived --force, then got hashed into the new record — the
# box read `current` with unshipped executable code in it, certified by the
# instrument built to catch exactly that.
printf '#!/bin/sh\necho hotfix\n' >"$MDUTY/bin/hotfix.sh"
chmod +x "$MDUTY/bin/hotfix.sh"
added_before="$(cat "$MDUTY/bin/hotfix.sh")"
t install-added-file-reads-modified modified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-refuses-added-file 1 "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-file-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-file gone "$r1"
# Moved, not deleted: the hotfix nobody told the fleet about is evidence.
t install-force-parks-it-in-legacy "$added_before" "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in
  *"moved unshipped engine file to legacy/: bin/hotfix.sh"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-what-it-moved named "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-file absent "$r1"
t install-force-over-added-file-is-current current "$(mstate)"
# ...and the engine that was installed around it is intact.
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-sweep-leaves-the-engine installed "$r1"

# The sweep enumerates the same surface the manifest does, or the hole above
# reopens in the installer: `find -type f` walks past a symlink, so an added
# LINK was refused, survived --force, and was then recorded as shipped. This
# also lands on the plain legacy/ name the added FILE above already took, so it
# is the collision case too: the first park must survive, because parking
# instead of deleting is an evidence argument and evidence the next run
# silently replaces is not evidence.
ln -s /bin/sh "$MDUTY/bin/hotfix.sh"
t install-added-symlink-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-added-symlink 1 "$r1"
case "$refuse_out" in *"added bin/hotfix.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-symlink named "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-symlink-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ] || [ -L "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-symlink gone "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-symlink absent "$r1"
t install-force-over-added-symlink-is-current current "$(mstate)"
# Parked as the link it was — not as a copy of whatever it pointed at.
parked_link=""
for p in "$MDUTY"/legacy/bin/hotfix.sh.*; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  parked_link="${p##*/}"; break
done
if [ -L "$MDUTY/legacy/bin/$parked_link" ]; then r1='link'; else r1=NOT-A-LINK; fi
t install-force-parks-the-symlink-as-a-link link "$r1"
t install-force-parks-the-symlink-target /bin/sh \
  "$(readlink "$MDUTY/legacy/bin/$parked_link" 2>/dev/null)"
t install-second-park-keeps-the-first "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in *"kept as bin/$parked_link"*) r1=named ;; *) r1=SILENT ;; esac
t install-collided-park-names-where-it-went named "$r1"

# The same hole one component UP, and the reason the sweep alone cannot close
# it: the sweep descends a symlinked root but never sweeps the root entry, so an
# operator's `ln -s elsewhere ~/duty/bin` was detected, refused — and then
# survived --force, was written into the record, and the box read `current` with
# its engine executing out of a directory this version never shipped. Detection
# already names the redirect, so blessing it is worse than never having looked.
REDIR="$TMP/manifest-redirect-target"
mkdir -p "$REDIR"
mv "$MDUTY/bin" "$REDIR/bin"
ln -s "$REDIR/bin" "$MDUTY/bin"
t install-redirected-root-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-root 1 "$r1"
case "$refuse_out" in *"added bin"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-root named "$r1"
# ...and the refusal changed nothing: the redirect is still exactly as it was.
if [ -L "$MDUTY/bin" ]; then r1=intact; else r1=DISTURBED; fi
t install-refusal-leaves-the-redirect-alone intact "$r1"

if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-redirected-root-rc 0 "$r1"
# The convergence: a real directory where the link was, not a link crew ships.
if [ -d "$MDUTY/bin" ] && [ ! -L "$MDUTY/bin" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirect-with-a-real-dir real "$r1"
# Moved, not deleted — and parked as a LINK, so the target it pointed at is the
# evidence, sitting outside the engine surface.
redir_park=""
for p in "$MDUTY"/legacy/bin "$MDUTY"/legacy/bin.*; do
  if [ -L "$p" ]; then redir_park="$p"; break; fi
done
if [ -n "$redir_park" ]; then r1='link'; else r1=NOT-PARKED-AS-LINK; fi
t install-force-parks-the-redirect-as-a-link link "$r1"
t install-force-parks-the-redirect-target "$REDIR/bin" \
  "$(readlink "$redir_park" 2>/dev/null)"
case "$force_out" in
  *"replaced redirected engine directory with a real one: bin"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-the-redirect-it-replaced named "$r1"
# The record must not carry the redirect: `bin` as an entry is the blessing.
case "$(sed -n 's/.*  \(bin\)$/\1/p' "$MDUTY/.engine-manifest")" in
  bin) r1=BLESSED ;; *) r1=absent ;;
esac
t install-force-does-not-record-the-redirect absent "$r1"
t install-force-over-redirected-root-is-current current "$(mstate)"
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-through-redirect-leaves-the-engine installed "$r1"
# The park above collided by construction: the added-file fixtures further up
# already left legacy/bin as a DIRECTORY holding hotfix.sh, so parking a link
# called `bin` had to take the timestamped name instead of replacing it. Evidence
# the next run overwrites is not evidence, and a redirect park is no exception.
t install-redirect-park-keeps-the-earlier-evidence "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$redir_park" in
  *"/legacy/bin."*) r1=timestamped ;; *) r1=CLOBBERED-THE-DIRECTORY ;;
esac
t install-redirect-park-takes-a-free-name timestamped "$r1"

# One level FURTHER up, where it was not even detected: conf/ carries
# conf/roles, conf/agents and conf/fleet.defaults.conf without being a manifest
# root itself, so a redirect there resolved, hashed clean, and never refused —
# the whole role and agent set read from wherever an operator pointed it while
# the instrument said `current`.
#
# This is also why the contents are copied back through the link rather than the
# root simply emptied: OPERATOR_CONF falls back to the shipped example only when
# the box has no conf/fleet.conf of its own, so a normalization that dropped the
# redirect's contents would destroy a transported one.
printf 'FLEET_KEEPME=1\n' >>"$MDUTY/conf/fleet.conf"
minstall --force >/dev/null 2>&1   # re-record with the marker in place
mv "$MDUTY/conf" "$REDIR/conf"
ln -s "$REDIR/conf" "$MDUTY/conf"
t install-redirected-ancestor-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-ancestor 1 "$r1"
case "$refuse_out" in *"added conf"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-ancestor named "$r1"
minstall --force >/dev/null 2>&1
if [ -d "$MDUTY/conf" ] && [ ! -L "$MDUTY/conf" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirected-ancestor real "$r1"
# The per-box configuration behind the redirect came back with it.
case "$(cat "$MDUTY/conf/fleet.conf" 2>/dev/null)" in
  *FLEET_KEEPME*) r1=kept ;; *) r1=LOST ;;
esac
t install-redirect-normalization-keeps-the-operator-fleet-conf kept "$r1"
if [ -f "$MDUTY/conf/instance.conf" ]; then r1=present; else r1=MISSING; fi
t install-redirect-normalization-keeps-instance-conf present "$r1"
t install-force-over-redirected-ancestor-is-current current "$(mstate)"

# A DANGLING root redirect must not take the install down with it: there is no
# content to restore, so the right answer is an empty real directory the install
# then fills, not a crash under `set -e`.
rm -rf "$MDUTY/prompts"
ln -s "$TMP/manifest-redirect-nowhere" "$MDUTY/prompts"
t install-dangling-root-redirect-reads-modified modified "$(mstate)"
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-over-dangling-root-redirect-rc 0 "$r1"
if [ -d "$MDUTY/prompts" ] && [ ! -L "$MDUTY/prompts" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-dangling-redirect real "$r1"
if [ -n "$(ls -A "$MDUTY/prompts" 2>/dev/null)" ]; then r1=filled; else r1=EMPTY; fi
t install-force-refills-the-dangling-redirect filled "$r1"
t install-force-over-dangling-redirect-is-current current "$(mstate)"

# A converging re-install sweeps NOTHING. Every install parking files in
# legacy/ would make the mechanism noise, and noise is how the one real one
# gets missed.
legacy_before="$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
reship_out="$(minstall 2>&1)"
t install-clean-reship-sweeps-nothing "$legacy_before" \
  "$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
case "$reship_out" in *"moved unshipped engine file"*) r1=NOISY ;; *) r1=quiet ;; esac
t install-clean-reship-is-quiet quiet "$r1"

# The migration: a box hired before content stamping has no record. It must
# read unverified, must NOT be refused, and one install must cure it.
rm -f "$MDUTY/.engine-manifest"
t install-pre-existing-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-pre-existing-box-is-not-refused 0 "$r1"
t install-pre-existing-box-is-cured current "$(mstate)"

# The obsolete half, on the box where it actually happens: an `unverified` box
# is deliberately NOT refused, so nothing else would ever notice the module it
# has been carrying since two versions ago. The install that cures it sweeps it
# — at depth, and without --force — instead of recording it as shipped.
rm -f "$MDUTY/.engine-manifest"
printf 'dead\n' >"$MDUTY/lib/jq/obsolete.jq"
t install-obsolete-file-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-unforced-sweep-rc 0 "$r1"
if [ -e "$MDUTY/lib/jq/obsolete.jq" ]; then r1=SURVIVED; else r1=gone; fi
t install-unforced-sweeps-the-obsolete-file gone "$r1"
t install-unforced-sweep-parks-it dead "$(cat "$MDUTY/legacy/lib/jq/obsolete.jq" 2>/dev/null)"
case "$(cat "$MDUTY/.engine-manifest")" in *obsolete*) r1=BLESSED ;; *) r1=absent ;; esac
t install-unforced-sweep-does-not-record-it absent "$r1"
t install-unforced-sweep-is-current current "$(mstate)"

# --- crew status: what the operator reads ---------------------------------
# A box is a directory here: the stub runs `box exec` bodies with HOME pointed
# into it, so the REAL engine-manifest.sh runs against a REAL installed tree
# and the column is asserted end to end rather than against a mocked verdict.
MSROOT="$TMP/status-boxes"
MSSHIM="$TMP/status-bin"
MSCONF="$TMP/status-fleet"
MSCALLS="$TMP/status-box-calls"
MSINSTALL_SCRIPTS="$TMP/status-install-scripts"
mkdir -p "$MSSHIM" "$MSCONF" "$MSROOT"
printf 'fixture-box claude reviewer\n' >"$MSCONF/fleet.roster"
printf 'FLEET_BENCH="b"\nFLEET_TRIAGE="t"\nFLEET_HUMAN="h"\n' >"$MSCONF/fleet.conf"
printf 'owner/repo\n' >"$MSCONF/repos.txt"
cat >"$MSSHIM/box" <<'EOF'
#!/usr/bin/env bash
# box list/info/exec against $MSROOT/<name>, one directory per box.
case "$1" in
  list) printf '[{"name":"fixture-box"}]\n' ;;
  info) printf '[{"status":"running"}]\n' ;;
  exec)
    name="$2"
    printf '%s\n' "$name" >>"$MSCALLS"
    shift 3                      # past: exec <name> --
    # what is left is `bash -lc <script>`. Run the script with -c rather than
    # -lc: a login shell would source this workstation's profile, and the box
    # under test is meant to be the directory and nothing else. DUTY_DIR is
    # unset because a real box has none — it resolves from HOME, which is the
    # resolution under test.
    case "$3" in *shared/install.sh*) printf '%s\n' "$3" >>"$MSINSTALL_SCRIPTS" ;; esac
    env -u DUTY_DIR HOME="$MSROOT/$name" CRON_STATE="$MSROOT/$name/crontab" bash -c "$3"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MSSHIM/box"
ln -sf "$(command -v jq)" "$MSSHIM/jq"
# Since #189 `crew status` asks the box whether cron is armed. The shim runs
# these scripts on the HOST, so a real `crontab -l` would read whoever's
# crontab is running the suite — and on a box host that genuinely carries a
# tick.sh line the row would flip depending on the machine. Pin it. The fixture
# box is ARMED, which is the ordinary case and the one the round-trip budget
# below is about; the disarmed path is asserted separately, further down.
cat >"$MSSHIM/crontab" <<'CRONEOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l)
    [ -n "${MSCRON_EMPTY:-}" ] && exit 0
    # The paused shape as the console's PAUSE_SH actually writes it: the live
    # line commented out with the marker in front. Both counts are then
    # non-trivial — armed 0, paused 1 — which is the only shape that catches a
    # record whose fields have been shifted onto a second line.
    if [ -n "${MSCRON_PAUSED:-}" ]; then
      printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n'
    elif [ -f "$CRON_STATE" ]; then
      cat "$CRON_STATE"
    else
      printf '*/5 * * * * $HOME/duty/bin/tick.sh\n'
    fi
    ;;
  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
esac
CRONEOF
chmod +x "$MSSHIM/crontab"
crewstatus() {
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    PATH="$MSSHIM:$PATH" bash "$ROOT/cli/crew" status "$@" 2>&1
}
# The fixture box IS the installed tree from the installer fixtures above.
mkdir -p "$MSROOT/fixture-box"
cp -R "$MDUTY" "$MSROOT/fixture-box/duty"
# ...and it has ticked once. Not decoration: it pins the round-trip count
# asserted below at the steady state #159 is about — a box that has never
# ticked is a different state, and it has its own coverage in
# fleet-floor/test/cli.sh (the table's NOTE, #224; the detail view's line,
# #221).
#
# It used to say the never-ticked case was UNREACHABLE here: with no duty.log
# at all the row's `tail -n 1` exited 1, and under `set -o pipefail` that
# killed cmd_status's loop after the header. #224 fixed that — the fallback
# renders, the loop survives — so the reason this fixture ticks is now the
# count above and nothing else.
printf '2026-07-29T00:00:00Z duty run start\n' >"$MSROOT/fixture-box/duty/duty.log"

# #283 — exercise the real upgrade branch and installer, not a reconstruction
# of its grep. The script capture proves which flags reached install.sh; the
# state-backed crontab shim proves what the installer left behind.
upgradefixture() {
  : >"$MSINSTALL_SCRIPTS"
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    MSINSTALL_SCRIPTS="$MSINSTALL_SCRIPTS" PATH="$MSSHIM:$PATH" \
    bash "$ROOT/cli/crew" upgrade fixture-box >/dev/null 2>&1
}
resolved_tick="$MSROOT/fixture-box/duty/bin/tick.sh"

paused_cron="#CREW-FLOOR-PAUSED */5 * * * * $resolved_tick"
printf '%s\n' "$paused_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-paused-box-passes-no-arm-flag absent "$r1"
t upgrade-paused-box-keeps-crontab "$paused_cron" "$(cat "$MSROOT/fixture-box/crontab")"

armed_cron="*/5 * * * * $resolved_tick"
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=present; else r1=MISSING; fi
t upgrade-armed-box-keeps-arm-flag present "$r1"
t upgrade-armed-box-has-one-canonical-tick 1 \
  "$(grep -cF "$resolved_tick" "$MSROOT/fixture-box/crontab")"

: >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-never-armed-box-passes-no-arm-flag absent "$r1"
t upgrade-never-armed-box-keeps-crontab '' "$(cat "$MSROOT/fixture-box/crontab")"

# Restore the ordinary armed fixture consumed by the status cases below.
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"

status_out="$(crewstatus)"
case "$status_out" in *INTEGRITY*) r1=present ;; *) r1=MISSING ;; esac
t status-has-an-integrity-column present "$r1"
case "$status_out" in *"fixture-box"*current*) r1=current ;; *) r1=OTHER ;; esac
t status-clean-box-reads-current current "$r1"

# The round-trip budget (#159 acceptance): reading integrity must ride the exec
# `crew status` already made. Three per box — the engine report, the auth/tick
# read, and the last log line — which is exactly what it cost before this
# existed, when the first of the three was a bare `head -1 ~/duty/VERSION`.
: >"$MSCALLS"
crewstatus >/dev/null
t status-round-trips-per-box 3 "$(grep -c . "$MSCALLS")"

# #189 — an UNARMED box. `crew status` says so and names the fix, instead of
# printing the newest duty.log line, which on a box whose cron is gone is a
# fact about the past that reads exactly like a working box. The floor answers
# from the same counts; drill/rehearsal-app.sh compares the two on real
# hardware, and that comparison is the thing that had never once run.
status_out="$(MSCRON_EMPTY=1 crewstatus)"
case "$status_out" in *"fixture-box"*disarmed*"crew hire"*) r1=named ;; *) r1="$status_out" ;; esac
t status-unarmed-box-says-disarmed named "$r1"
# ...and it costs one round trip LESS, not more: the log-line read is skipped
# precisely because its answer would mislead. The budget above is the ceiling.
: >"$MSCALLS"
MSCRON_EMPTY=1 crewstatus >/dev/null
t status-round-trips-unarmed 2 "$(grep -c . "$MSCALLS")"

# #189, round 1 (codex/grok/kimi, all three) — a PAUSED box must be told to
# resume, never to re-hire. `grep -c` PRINTS the count and exits 1 when it is
# zero, so a `|| echo 0` guard appended a SECOND zero and pushed the paused
# count onto line two; `read` saw only line one and the note came out
# "disarmed — crew hire". Armed and empty-crontab both parse that away, which
# is why the first cut of these tests went green: this case is the one shape
# where both counts are non-trivial, and it is the shape a real operator makes
# by clicking Pause.
status_out="$(MSCRON_PAUSED=1 crewstatus)"
case "$status_out" in
  *"fixture-box"*"paused by operator"*) r1=paused ;;
  *"fixture-box"*disarmed*)             r1=WRONG-FIX-NAMED ;;
  *)                                    r1="$status_out" ;;
esac
t status-paused-box-says-paused paused "$r1"

# A modified box, end to end.
printf '# hotfix by hand\n' >>"$MSROOT/fixture-box/duty/bin/duty.sh"
status_out="$(crewstatus)"
case "$status_out" in *MODIFIED*) r1=shouts ;; *) r1=SILENT ;; esac
t status-modified-box-shouts shouts "$r1"
case "$status_out" in *"MODIFIED since crew@$(head -1 "$ROOT/VERSION")"*) r1=named ;; *) r1=UNNAMED ;; esac
t status-modified-names-the-version named "$r1"

# MUST FAIL: modified and skew collapsing into one state. They ask for
# different actions — skew says "ship the engine", modified says "find out
# what someone did here" — so the HOST/ENGINE pair and the INTEGRITY column
# have to disagree independently. Here the box is at the host's own version
# and still modified: nothing about skew can be producing this word.
host_v="$(head -1 "$ROOT/VERSION")"
ms_row="$(printf '%s\n' "$status_out" | grep '^fixture-box' || true)"
case "$ms_row" in
  *"$host_v"*"crew@$host_v"*MODIFIED*) r1=same-version-and-modified ;;
  *) r1=COLLAPSED ;;
esac
t status-modified-is-not-skew same-version-and-modified "$r1"

# The per-box view lists the files, on the same single exec.
detail_out="$(crewstatus fixture-box)"
case "$detail_out" in *"integrity: MODIFIED"*"modified bin/duty.sh"*) r1=listed ;; *) r1=MISSING ;; esac
t status-detail-lists-the-files listed "$r1"
case "$detail_out" in *"--force"*) r1=told ;; *) r1=SILENT ;; esac
t status-detail-names-the-override told "$r1"

# A box hired before content stamping: no record AND no tool to compute one.
# It reads unverified in the table, never modified.
rm -f "$MSROOT/fixture-box/duty/.engine-manifest" "$MSROOT/fixture-box/duty/bin/engine-manifest.sh"
status_out="$(crewstatus)"
case "$status_out" in *unverified*) r1=unverified ;; *MODIFIED*) r1=MODIFIED ;; *) r1=OTHER ;; esac
t status-pre-existing-box-reads-unverified unverified "$r1"

# --- git identity: the second carrier of the box's login (#294) -------------
# The split rotated the gh credential and left git naming the pre-split
# account, so a builder's commits were bylined by the reviewer. These assert
# the derivation: gh says who the box is, git is made to agree, and a box that
# cannot be made to agree runs nothing.
#
# GIT_CONFIG_GLOBAL, not $HOME: the suite inherits the real HOME (see the
# export at the top), and a test that writes `git config --global` without
# this rewrites the identity of whoever ran it — which on a live box is the
# very byline #294 exists to protect.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-294"
: >"$GIT_CONFIG_GLOBAL"
GHLOG="$TMP/gh-calls-294"; : >"$GHLOG"

# The address table. Every row is a shape that reaches this parser in the
# fleet as it stands today, not a hypothetical.
t gitid-parses-id-prefixed-form cndgrr \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com')"
t gitid-parses-bare-form cndgrr \
  "$(git_identity_login 'cndgrr@users.noreply.github.com')"
t gitid-folds-case cndgrr \
  "$(git_identity_login 'CNDGRR@Users.NoReply.GitHub.COM')"
t gitid-parses-a-hyphenated-login claude-bot-andresmgsl \
  "$(git_identity_login 'claude-bot-andresmgsl@users.noreply.github.com')"
# Not a noreply address names nobody — deliberately, per the comment on the
# function: the fleet provisions noreply addresses only, so anything else is
# an address no code here wrote.
t gitid-rejects-a-real-email "" "$(git_identity_login 'dan@example.com')"
t gitid-rejects-empty "" "$(git_identity_login '')"
t gitid-rejects-missing-local-part "" "$(git_identity_login '@users.noreply.github.com')"
t gitid-rejects-empty-id "" "$(git_identity_login '+cndgrr@users.noreply.github.com')"
# A non-numeric prefix is not an id GitHub issued. Half-parsing it would read
# `andresmgsl+cndgrr@…` as cndgrr, which is a login this box does not hold.
t gitid-rejects-non-numeric-id "" \
  "$(git_identity_login 'andresmgsl+cndgrr@users.noreply.github.com')"
# The domain must END the address; a lookalike suffix must not match.
t gitid-rejects-lookalike-domain "" \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com.example.net')"
# Whitespace INSIDE the address names nobody. Deleting it would manufacture an
# identity out of an address GitHub attributes to no account — the parser's own
# version of the bug this file is about.
t gitid-rejects-an-interior-space "" \
  "$(git_identity_login 'cnd grr@users.noreply.github.com')"
t gitid-rejects-a-space-around-the-id "" \
  "$(git_identity_login '59120057 + cndgrr@users.noreply.github.com')"
t gitid-rejects-a-space-in-the-domain "" \
  "$(git_identity_login 'cndgrr@users.noreply.git hub.com')"
# The EDGES are still trimmed: that is a value a hand-edited config presents,
# and the address inside it is unambiguous.
t gitid-trims-surrounding-whitespace cndgrr \
  "$(git_identity_login '  59120057+cndgrr@users.noreply.github.com
')"
t gitid-rejects-whitespace-only "" "$(git_identity_login '   ')"

# --- the must-fail proof (#294's test plan) ---------------------------------
# A duty environment whose user.email does not match $ME. Reverting the assert
# greens a box that commits as somebody else, which is today's behaviour and
# the point.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-mismatched-email-is-refused refused "$r1"

# The SAME foreign address in the id-prefixed form — the row #294 singles out
# as the one that matters, because a parser that greened anything containing a
# '+' would green every foreign address on the fleet and still pass the bare
# row above.
git config --global user.email '1234567+claude-bot-andresmgsl@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-foreign-id-prefixed-form-is-refused refused "$r1"

# An address that is only this box's login once its interior whitespace is
# deleted is NOT this box's login. git config stores the value verbatim, so
# this is a state a real ~/.gitconfig can hold, and greening it would byline
# every commit to nobody while the guard reported a converged box.
git config --global user.email 'cnd grr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-interior-space-email-is-refused refused "$r1"

# Both forms of this box's own address pass. One is what provisioning writes,
# the other is what the 2026-08-02 hand sweep wrote; an assert that took only
# the first would red every box that sweep already repaired.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-id-prefixed-form-passes ok "$r1"
git config --global user.email 'cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-hand-swept-bare-form-passes ok "$r1"
if git_identity_ok CNDGRR; then r1=ok; else r1=REFUSED; fi
t gitid-login-comparison-is-case-insensitive ok "$r1"

# No configured identity is a mismatch, not a pass: git then authors commits
# as whatever the box template left behind, which is how this started.
git config --global --unset user.email
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-unset-email-is-refused refused "$r1"
# And an empty login can never be satisfied — a caller with no $ME must not
# accidentally green every box.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok ""; then r1=GREEN; else r1=refused; fi
t gitid-empty-login-is-refused refused "$r1"

# --- convergence ------------------------------------------------------------
# shellcheck disable=SC2317  # invoked indirectly, by converge_git_identity
gh() { echo "$*" >>"$GHLOG"; printf '%s\t%s\n' "$GH_STUB_LOGIN" "$GH_STUB_ID"; }
GH_STUB_LOGIN=cndgrr GH_STUB_ID=59120057

# The steady state costs NOTHING: already converged, so no network call. This
# runs on every tick of every box, so a stray `gh api user` here is a fleet's
# worth of requests for a fact already on local disk.
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-converged-returns-ok 0 "$?"
t gitid-steady-state-makes-no-gh-call "" "$(cat "$GHLOG")"

# The hand-swept bare form is already converged too — it must NOT be rewritten
# on every upgrade for the rest of time.
git config --global user.email 'cndgrr@users.noreply.github.com'
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-bare-form-is-not-rewritten 'cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# The repair: a box carrying the pre-split account converges to its own.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
: >"$GHLOG"
converge_git_identity cndgrr >/dev/null
t gitid-repair-returns-ok 0 "$?"
t gitid-repair-writes-id-prefixed-address '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"
t gitid-repair-writes-the-name cndgrr "$(git config --global user.name)"
t gitid-repair-spends-one-gh-call 1 "$(wc -l <"$GHLOG")"

# No argument is install.sh's call — it has no $ME, so gh alone decides.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
converge_git_identity >/dev/null
t gitid-no-argument-converges-from-gh '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# A dead credential must NOT be repaired-by-guess. There is no source of truth
# to copy, so the copy is left alone and the caller is told — which is what
# makes duty.sh refuse rather than run a session under a name it cannot verify.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { return 1; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-dead-credential-refuses 1 "$?"
t gitid-dead-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"

# A credential that ROTATED between duty.sh resolving $ME and this call must
# refuse, not converge. Converging would write the NEW account and return 0
# while the tick carries on as the OLD $ME — a session acting as one identity
# whose commits byline another, which is #294 one call later rather than
# fixed. Refusing costs one tick; the next one reads both halves consistently.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' andriujoseba 12345678; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-rotated-credential-refuses 1 "$?"
t gitid-rotated-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
# The rotation guard is the CALLER's to invoke: install.sh passes no login
# because it has no $ME, and its whole job is to write whatever gh now says.
converge_git_identity >/dev/null 2>&1
t gitid-no-argument-follows-the-rotation '12345678+andriujoseba@users.noreply.github.com' \
  "$(git config --global user.email)"

# A malformed id is the same class: an address built from it would attribute
# to nobody, and writing it would look like a repair while fixing nothing.
# The starting address is set here rather than inherited from the block above,
# so this case reds for its own reason and not for a neighbour's.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' cndgrr 'not-a-number'; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-non-numeric-id-refuses 1 "$?"
t gitid-non-numeric-id-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
unset -f gh
unset GIT_CONFIG_GLOBAL

# --- the engine actually asks, and refuses before it dispatches -------------
# Static, because duty.sh is a script and not a sourceable module. These are
# the assertions that make REVERTING the fix red: without them a reviewer's
# green tells them the helper works, not that anything calls it.
DUTYSH="$SHARED/bin/duty.sh"
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -Fq 'converge_git_identity "$ME"' "$DUTYSH"; then r1=called; else r1=MISSING; fi
t gitid-duty-converges-against-me called "$r1"

# Ordering is the whole claim: "before any session runs". A converge placed
# after the first dispatch would pass every helper test above and still let a
# session commit under another droid's name.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
conv_line="$(grep -n 'converge_git_identity "\$ME"' "$DUTYSH" | head -1 | cut -d: -f1)"
disp_line="$(grep -n '^duty_attention$' "$DUTYSH" | head -1 | cut -d: -f1)"
if [ -n "$conv_line" ] && [ -n "$disp_line" ] && [ "$conv_line" -lt "$disp_line" ]; then
  r1=before
else
  r1="AFTER(converge=$conv_line dispatch=$disp_line)"
fi
t gitid-converge-precedes-the-first-duty before "$r1"

# And the refusal ends the tick rather than logging and carrying on.
if awk '/converge_git_identity "\$ME"/,/^fi$/' "$DUTYSH" | grep -Fq 'exit 0'; then
  r1=exits
else
  r1=CONTINUES
fi
t gitid-refusal-ends-the-tick exits "$r1"

# install.sh writes it through the ENGINE, not a private copy of the rule. A
# second implementation of "which login is this box" is how the panel copy
# (#285) and the git copy (#294) both happened.
if grep -Fq 'converge_git_identity' "$SHARED/install.sh"; then r1=derived; else r1=MISSING; fi
t gitid-install-uses-the-shared-helper derived "$r1"

if "$SHARED/test/claim.test.sh"; then r1=0; else r1=$?; fi
t claim-regression-suite 0 "$r1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
