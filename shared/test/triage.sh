#!/usr/bin/env bash
# shared/test/triage.sh — standalone triage subject suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
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
# Every program, not just blockers.jq: the round-count census (#503) reads the
# cap out of round-cap.jq and both it and round-count.jq include the rounds.jq
# module, so a hand-picked list here is a list that goes stale silently — the
# census would simply warn and render nothing, and every assertion about the
# evidence would pass vacuously by being about an absent slot.
cp "$SHARED"/lib/jq/*.jq "$TRD/lib/jq/"
cp -r "$SHARED/prompts" "$TRD/prompts"
# The label vocabulary comes from the SHIPPED conf, not from assignments in
# this file (#358). The runner calls load_fleet_conf against this copy, so a
# queue label the engine's config does not define is a label these fixtures
# cannot silently supply on its behalf.
cp "$SHARED/conf/fleet.defaults.conf" "$TRD/conf/"
printf 'o/r\n' >"$TRD/repos.txt"
TR_CALLS="$TMP/tr-calls.log"; TR_PHASE="$TMP/tr-phase"
TR_LOG="$TMP/tr-log.txt"; TR_PROMPT="$TMP/tr-prompt"; TR_CHECKOUT="$TMP/tr-checkout"

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
  # The round-count census (#503) is a GraphQL read too, so it must be matched
  # BEFORE the discussions arm or it would be served discussion rows. Keyed on
  # `pullRequests(`, which only its query carries. `prs.fail` is how a scenario
  # makes the fetch itself fail.
  *"pullRequests(first"*)
    [ -f "$TR_FIX/prs.fail" ] && exit 1
    # WHICH page, keyed on the cursor the census actually sent — so the handoff
    # is checked and not merely counted. The first page carries `after=null`;
    # the second must carry back the exact endCursor page one handed out. A
    # request with any OTHER cursor is served a terminal empty page rather than
    # page one again, so a dropped or mangled cursor surfaces as a missing row
    # in the rendered evidence instead of as a test that loops forever.
    # Matched with the flag before and the space after, so the comparison is on
    # the WHOLE cursor: a bare `*after=CURSOR*` is a substring test, and a
    # census that prefixed or suffixed the value would still be served page two
    # by it — which would make the case pass on a cursor it had corrupted.
    case "$*" in
      *"-F after=null "*)              cat "$TR_FIX/prs.$p.json" ;;
      *"-f after=TR-CURSOR-PAGE-2 "*)  cat "$TR_FIX/prs2.$p.json" ;;
      *)                               cat "$TR_FIX/prs.none.json" ;;
    esac ;;
  *"api graphql"*)          cat "$TR_FIX/disc.$p.rows" ;;  # --jq is already applied
  *"--label needs-triage"*) cat "$TR_FIX/nt.$p.json" ;;
  *"number,body,updatedAt,labels"*) cat "$TR_FIX/board.$p.json" ;;
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
# duty-builder.sh, as bin/duty.sh sources it — before any role dispatch and
# whatever the box's roles are. The triage duty reads `_RESUME_ISSUE_RE` from it
# (#503), so a runner that sourced only duty-triage.sh would be testing a shape
# production never runs, and would have reported the evidence as simply absent.
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/duty-builder.sh"
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
ensure_checkout() { printf '%s\n' "$*" >>"$TR_CHECKOUT"; return 0; }
duty_triage
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
  # The round-count board (#503) defaults to empty and to succeeding, so every
  # scenario written before it keeps its meaning: an empty board yields no
  # evidence and no prompt slot. A scenario that wants either overwrites these
  # two files after calling tr_fix.
  rm -f "$TRF/prs.fail"
  printf '%s' "$TR_PRS_NONE" >"$TRF/prs.1.json"
  printf '%s' "$TR_PRS_NONE" >"$TRF/prs.2.json"
  # And the SECOND page defaults to a terminal empty one, so a scenario that
  # does not paginate is unaffected and a scenario that does must say so.
  printf '%s' "$TR_PRS_NONE" >"$TRF/prs2.1.json"
  printf '%s' "$TR_PRS_NONE" >"$TRF/prs2.2.json"
  printf '%s' "$TR_PRS_NONE" >"$TRF/prs.none.json"
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
  : >"$TR_CHECKOUT"
  rm -f "$TR_PHASE" "$TR_PROMPT".*
  SHARED_DIR="$SHARED" TR_CALLS="$TR_CALLS" TR_PHASE="$TR_PHASE" TR_FIX="$TRF" \
  TR_PROMPT="$TR_PROMPT" TR_CHECKOUT="$TR_CHECKOUT" TR_SESSION_RC="$1" \
  DUTY_DIR="$TRD" ME=me-bot \
  TIMEOUT_MENTION=1 TIMEOUT_TRIAGE=1 MENTION_THREAD_CEILING="${TR_CEILING:-50}" \
  PATH="$TRS:$PATH" bash "$TMP/tr-run.sh" >"$TR_LOG" 2>&1
}
tr_run() {  # tr_run <run_session rc>, starting with cold ledgers
  rm -f "$TRD"/.seen-* "$TRD"/.suppressed-*
  tr_tick "$1"
}
trc() { grep -c -- "$1" "$TR_CALLS"; }
# One page, no PRs — the round-count census's empty board.
TR_PRS_NONE='{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
# tr_pr NUM BODY ROUNDS — one pullRequest node with ROUNDS closed rounds, in the
# shape the census's own query returns.
tr_pr() {
  local num="$1" body="$2" n="$3" i oid ts commits="" reviews=""
  for ((i = 1; i <= n; i++)); do
    oid="$(printf 'p%s-c%d' "$num" "$i")"
    ts="$(printf '2026-08-%02dT10:00:00Z' "$i")"
    commits="$commits{\"commit\":{\"oid\":\"$oid\",\"committedDate\":\"$ts\"}},"
    ts="$(printf '2026-08-%02dT12:00:00Z' "$i")"
    reviews="$reviews{\"author\":{\"login\":\"rev-a\"},\"state\":\"CHANGES_REQUESTED\",\"commit\":{\"oid\":\"$oid\"},\"submittedAt\":\"$ts\"},"
  done
  printf '{"number":%s,"body":%s,"commits":{"totalCount":%d,"nodes":[%s]},"reviews":{"totalCount":%d,"nodes":[%s]}}' \
    "$num" "$(printf '%s' "$body" | jq -Rs .)" "$n" "${commits%,}" "$n" "${reviews%,}"
}
tr_prs() {  # tr_prs NODE... -> one page carrying them, and no page after it
  printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}' \
    "$(printf '%s,' "$@" | sed 's/,$//')"
}
# tr_prs_more CURSOR NODE... -> a page that has a next one, handing CURSOR out.
# The shim serves page two only against this exact value.
tr_prs_more() {
  local cur="$1"; shift
  printf '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":true,"endCursor":"%s"},"nodes":[%s]}}}}' \
    "$cur" "$(printf '%s,' "$@" | sed 's/,$//')"
}
# tr_pr_bulk NUM ISSUE ROUNDS — a node whose body is padded to a realistic
# size. Crew's own PR bodies run to tens of kilobytes; a page of fifty of them
# is ~1.10 MB, and the point of padding here is that a page must be able to
# cross a real byte limit for a case to be able to see one.
TR503_PAD=""
tr_pr_bulk() {
  [ -n "$TR503_PAD" ] || TR503_PAD="$(printf '%*s' 20000 '' | tr ' ' x)"
  tr_pr "$1" "Closes #$2 — $TR503_PAD" "$3"
}
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

# Before any triage session launches, the shared open-board snapshot and each
# remaining independent signal are still polled exactly once.
# A successful session deliberately adds the #359 exit-state reads; a quiet
# tick adds none. These counts distinguish that bounded re-read from polling
# twice before the launch decision.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-reads-notifications-once 1 "$(trc 'api notifications')"
t triage253-reads-open-board-once     1 "$(trc 'number,body,updatedAt,labels')"
t triage253-reads-discussions-once    1 "$(trc 'api graphql')"
t triage253-gh-calls-with-mention     3 "$(grep -vc '^SESSION' "$TR_CALLS")"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-gh-calls-without-mention  3 "$(grep -vc '^SESSION' "$TR_CALLS")"
t triage253-quiet-tick-spends-nothing 0 "$(trc '^SESSION')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-quiet-tick-log-unchanged said "$r1"
# The state-map reads still ride the non-empty declaration graph, and nothing else.
# Ten rather than nine since #503: this scenario is the first above that LAUNCHES
# a triage session, and a launching tick also reads the board's round counts once
# for the prompt. The three counts above are unchanged because none of them
# launches one — which is the same fact the quiet-tick case below asserts head-on.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-gh-calls-with-blocked-list 10 "$(grep -vc '^SESSION' "$TR_CALLS")"
t triage253-blocked-list-reads-rounds-once 1 "$(trc 'pullRequests(first')"

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

# --- #466: one tick-wide mention batch across every configured repository --
tr466_mentions="$(jq -nc '[
  {id:"t1",reason:"mention",updated_at:"2026-08-24T10:01:00Z",
   repository:{full_name:"a/one"},subject:{url:"https://api/x/1",title:"SECRET-TITLE-ONE"}},
  {id:"t2",reason:"team_mention",updated_at:"2026-08-24T10:02:00Z",
   repository:{full_name:"b/two"},subject:{url:"https://api/x/2",title:"SECRET-TITLE-TWO"}},
  {id:"t3",reason:"mention",updated_at:"2026-08-24T10:03:00Z",
   repository:{full_name:"c/three"},subject:{url:"https://api/x/3",title:"SECRET-TITLE-THREE"}},
  {id:"t4",reason:"mention",updated_at:"2026-08-24T10:04:00Z",
   repository:{full_name:"d/four"},subject:{url:"https://api/x/4",title:"SECRET-TITLE-FOUR"}}
]')"
printf '%s\n' a/one b/two c/three d/four >"$TRD/repos.txt"
tr_fix "$tr466_mentions" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-four-repos-one-mention-session 1 "$(trc '^SESSION mention$')"
t triage466-four-repos-one-notifications-fetch 1 "$(trc 'api notifications')"
for repo in a/one b/two c/three d/four; do
  if grep -q "\"repo\":\"$repo\"" "$TR_PROMPT.mention"; then r1=qualified; else r1=MISSING; fi
  t "triage466-prompt-qualifies:$repo" qualified "$r1"
done
t triage466-success-commits-whole-batch 4 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
if grep -q 'SECRET-TITLE' "$TR_PROMPT.mention"; then r1=LEAKED; else r1=absent; fi
t triage466-permissionless-prompt-omits-titles absent "$r1"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-mention-batch-creates-no-checkout none "$r1"

# The neutral session gets no checkout doctrine. Each thread must first resolve
# its own repository's entrypoint over the API and follow that router, rather
# than treating a bare role filename as relative to DUTY_DIR.
# shellcheck disable=SC2016  # the rendered prompt deliberately carries $repo
if grep -Fq 'gh api "repos/$repo/contents/AGENTS.md"' "$TR_PROMPT.mention" &&
   grep -Fq 'same repository-qualified contents API' "$TR_PROMPT.mention"; then
  r1=qualified; else r1=MISSING; fi
t triage466-doctrine-entrypoint-is-repository-qualified qualified "$r1"
doctrine_line="$(grep -n 'default-branch entrypoint' "$TR_PROMPT.mention" | head -1 | cut -d: -f1)"
thread_line="$(grep -n 'subject URL to fetch' "$TR_PROMPT.mention" | head -1 | cut -d: -f1)"
if [ -n "$doctrine_line" ] && [ -n "$thread_line" ] && [ "$doctrine_line" -lt "$thread_line" ]; then
  r1=before; else r1=WRONG_ORDER; fi
t triage466-doctrine-is-read-before-thread before "$r1"
if grep -Fq 'answer per TRIAGE.md' "$TR_PROMPT.mention" ||
   ! grep -Fq 'Do not resolve doctrine from the working directory' "$TR_PROMPT.mention"; then
  r1=RELATIVE; else r1=neutral-safe; fi
t triage466-doctrine-has-no-working-directory-relative-path neutral-safe "$r1"

# Crash and timeout are distinct exits but share the transaction boundary:
# neither may commit even one thread from the selected batch.
tr_run 1
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage466-crash-commits-none withheld "$r1"
tr_run 124
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage466-timeout-commits-none withheld "$r1"

# The ceiling is delivery control, not truncation: only the selected prefix is
# committed, and the remainder is the sole wake on the following tick.
TR_CEILING=2
tr_run 0
t triage466-ceiling-first-tick-commits-two 2 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
t triage466-ceiling-first-tick-one-session 1 "$(trc '^SESSION mention$')"
t triage466-ceiling-deferred-repos-not-quiet 2 \
  "$(grep -c 'mentions deferred by fleet ceiling' "$TR_LOG")"
if grep -E '^(c/three|d/four): quiet — no mentions' "$TR_LOG" >/dev/null; then
  r1=QUIET; else r1=deferred; fi
t triage466-ceiling-deferred-repos-state-named deferred "$r1"
tr_tick 0
t triage466-ceiling-second-tick-commits-remainder 4 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
t triage466-ceiling-second-tick-one-session 1 "$(trc '^SESSION mention$')"
if grep -q '"thread":"t1"\|"thread":"t2"' "$TR_PROMPT.mention"; then r1=REPEATED; else r1=remainder-only; fi
t triage466-ceiling-second-prompt-is-remainder remainder-only "$r1"
unset TR_CEILING
# shellcheck disable=SC2016  # matching the module's literal variable reference
if grep -q '^MENTION_THREAD_CEILING=[0-9][0-9]*$' "$SHARED/conf/roles/triage.conf" &&
   grep -q 'ceiling="$MENTION_THREAD_CEILING"' "$SHARED/lib/duty-triage.sh"; then
  r1=wired; else r1=MISSING; fi
t triage466-configurable-thread-ceiling-wired wired "$r1"

# A quiet snapshot is still one bounded fetch, with no model or checkout.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-quiet-four-repo-fetch-once 1 "$(trc 'api notifications')"
t triage466-quiet-four-repo-no-session 0 "$(trc '^SESSION')"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-quiet-four-repo-no-checkout none "$r1"

# A successful notifications request may produce no pagination documents at
# all. That is an empty snapshot, not a probe failure.
tr_fix '' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-empty-response-fetch-once 1 "$(trc 'api notifications')"
t triage466-empty-response-no-session 0 "$(trc '^SESSION')"
if grep -q 'notifications probe failed' "$TR_LOG"; then r1=WARNED; else r1=empty; fi
t triage466-empty-response-is-not-probe-failure empty "$r1"

# With no configured repositories there is nothing to partition, so the tick
# does not spend an otherwise-useless notifications pagination or create work.
: >"$TRD/repos.txt"
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-empty-repo-list-fetches-nothing 0 "$(trc 'api notifications')"
t triage466-empty-repo-list-launches-nothing 0 "$(trc '^SESSION')"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-empty-repo-list-creates-no-checkout none "$r1"

# Restore the single-repo fixture used by the pre-existing signal cases.
printf 'o/r\n' >"$TRD/repos.txt"

# Static ordering, in the style of the module-wiring checks above: every board
# read must sit BELOW the mention call site, and the launch decision below all
# of them. Cheap, and it fails loudly if a later edit hoists a poll back up.
TRIAGE_MOD="$SHARED/lib/duty-triage.sh"
tr_ln() { grep -Fn -- "$1" "$TRIAGE_MOD" | head -1 | cut -d: -f1; }
tr_mention_ln="$(tr_ln 'run_session mention')"
# shellcheck disable=SC2016  # matching the module's literal source text
tr_decide_ln="$(tr_ln '[ -z "$signals" ]')"
# shellcheck disable=SC2016  # ditto
for probe in '_triage_discussion_items "$R"' 'number,body,updatedAt,labels'; do
  probe_ln="$(tr_ln "$probe")"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -gt "$tr_mention_ln" ]; then
    r1=after; else r1="BEFORE($probe_ln vs $tr_mention_ln)"; fi
  t "triage253-poll-after-mention:$probe" after "$r1"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -lt "$tr_decide_ln" ]; then
    r1=before; else r1="AFTER($probe_ln vs $tr_decide_ln)"; fi
  t "triage253-poll-before-decision:$probe" before "$r1"
done

# --- #468: fast-tick triage receives the enumerated wake set ---------------
TR468_STAMP='2026-08-26T08:00:00Z'
tr468_only_family() {  # expected line, forbidden family headings
  local expected="$1" forbidden="$2"
  if grep -Fq -- "$expected" "$TR_PROMPT.triage"; then r1=named; else r1=MISSING; fi
  t "triage468-names:${expected%%:*}" named "$r1"
  if grep -Eq -- "$forbidden" "$TR_PROMPT.triage"; then r1=EMPTY_HEADING; else r1=omitted; fi
  t "triage468-omits-empty:${expected%%:*}" omitted "$r1"
}

# One family at a time proves that the identifiers already used for ledger
# gating reach the prompt, while absent families render no empty headings.
tr_fix '[]' '[{"number":101,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":101,"updatedAt":"2026-08-26T08:00:00Z"}]' '[]' '[]' '[]'
tr_run 0
tr468_only_family 'Needs-triage issues: #101' \
  'Queue-unlabeled issues:|Unresolved discussions without your voice:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' '[]' '[]' '[]' \
  '[{"number":102,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]'
tr_run 0
tr468_only_family 'Queue-unlabeled issues: #102' \
  'Needs-triage issues:|Unresolved discussions without your voice:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#103 $TR468_STAMP"
tr_run 0
tr468_only_family 'Unresolved discussions without your voice: #103' \
  'Needs-triage issues:|Queue-unlabeled issues:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
tr468_only_family 'Possibly unblockable issues: #244' \
  'Needs-triage issues:|Queue-unlabeled issues:|Unresolved discussions without your voice:'
if grep -Fq 'Treat these as leads, not verdicts' "$TR_PROMPT.triage"; then
  r1=preserved; else r1=MISSING; fi
t triage468-unblockable-caveat-preserved preserved "$r1"
if grep -Fq 'every issue or PR named in their "Blocked by" clause must now read CLOSED or MERGED' \
    "$TR_PROMPT.triage"; then r1=preserved; else r1=MISSING; fi
t triage468-unblockable-condition-preserved preserved "$r1"
if grep -q '{{' "$TR_PROMPT.triage"; then r1=RAW_SLOT; else r1=rendered; fi
t triage468-renders-all-template-slots rendered "$r1"

# A mixed wake is one block with all four families, not four independently
# rendered fragments. Each family retains its own item identifiers.
tr_fix '[]' '[{"number":111,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":111,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  "$TR_LEAD" "$TR_LEAD" "$TR_LANDED" \
  '[{"number":112,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":112,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]' \
  "o/r#113 $TR468_STAMP" "o/r#113 $TR468_STAMP"
tr_run 0
for named in 'Needs-triage issues: #111' 'Queue-unlabeled issues: #112' \
             'Unresolved discussions without your voice: #113' \
             'Possibly unblockable issues: #244'; do
  if grep -Fq -- "$named" "$TR_PROMPT.triage"; then r1=named; else r1=MISSING; fi
  t "triage468-mixed:${named%%:*}" named "$r1"
done
t triage468-mixed-one-signal-block 1 \
  "$(grep -c 'This fast-tick session was launched for the following named work:' "$TR_PROMPT.triage")"
if grep -q '^Converge the named items first[.] The whole-board sweep runs hourly under ' \
    "$TR_PROMPT.triage"; then r1=separate; else r1=JOINED; fi
t triage468-instructions-follow-signal-block-on-new-line separate "$r1"

# Scope changes, not quality changes: the old issue contract, outcome list and
# label-event rule remain exact substrings, behind the newly named work.
# shellcheck disable=SC2016  # the backticks are literal prompt prose
for required in \
  'The whole-board sweep runs hourly under `hygiene.txt`; this fast-tick session does not enumerate the board for more work.' \
  'You may act outside the named set when resolving one of its items requires it, but do not enumerate outside the set.' \
  'For stray issues — anything not minted by you — either normalize them to the issue contract or close them politely, pointing the filer at Discussions: their idea is welcome, the door is over there.' \
  'For discussions, converge each unresolved one to exactly one outcome — answer, ask, escalate, decline, or accept — and every issue you mint meets the contract.' \
  "Before asserting label-borne state in prose, re-read the issue's label events (the timeline API), not just its comments — label events govern over stale prose."; do
  if grep -Fq -- "$required" "$TR_PROMPT.triage"; then r1=present; else r1=MISSING; fi
  t "triage468-required-prose:${required%% *}" present "$r1"
done

# The empty-signal path remains the existing early return: no prompt is
# rendered and no repo session launches.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage468-empty-set-launches-nothing 0 "$(trc '^SESSION triage$')"
if [ -f "$TR_PROMPT.triage" ]; then r1=RENDERED; else r1=absent; fi
t triage468-empty-set-renders-no-prompt absent "$r1"

# --- #471: declared predecessor state changes wake a scoped re-read --------
tr471_issue() {  # tr471_issue NUMBER BODY
  jq -nc --argjson n "$1" --arg body "$2" \
    '[{number:$n,body:$body,labels:[{name:"ready"}],updatedAt:"2026-08-26T09:00:00Z"}]'
}
tr471_states() {  # tr471_states NUMBER STATE [NUMBER STATE ...]
  local rows='[]' number state
  while [ "$#" -gt 0 ]; do
    number="$1"; state="$2"; shift 2
    rows="$(jq -c --argjson n "$number" --arg s "$state" \
      '. + [{number:$n,state:$s}]' <<<"$rows")"
  done
  printf '%s\n' "$rows"
}

TR471_ONE="$(tr471_issue 471 'Blocked by #900. This discharged declaration remains as prose.')"

# Signals (e) and (f) must recognize exactly the same declaration grammar.
# The graph parser points back to the canonical corpus-tested jq file; this
# comparison prevents either byte-identical definition drifting silently.
tr471_graph_blockers="$(awk '
  /^    def blockers:/ { on=1 }
  on { sub(/^    /, ""); print }
  on && /;$/ { exit }
' "$SHARED/lib/duty-triage.sh")"
tr471_unblockable_blockers="$(awk '
  /^def blockers:/ { on=1 }
  on { print }
  on && /;$/ { exit }
' "$SHARED/lib/jq/blockers.jq")"
t triage471-signals-e-and-f-share-blocker-parser \
  "$tr471_unblockable_blockers" "$tr471_graph_blockers"

# A cold edge is work once, including the historical-prose shape where the
# predecessor landed before this ledger existed. The successful session
# records the exact edge state, so an unchanged second tick is silent.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 CLOSED)" \
  "$TR471_ONE" "$TR471_ONE"
tr_run 0
t triage471-closed-prose-wakes-once 1 "$(trc '^SESSION triage$')"
if grep -Fq '#471 depends on #900: UNSEEN -> CLOSED' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-closed-prose-names-transition named "$r1"
if grep -q '^o/r#471#900 CLOSED$' "$TRD/.seen-graph"; then r1=edge-keyed; else r1=MISSING; fi
t triage471-ledger-keys-on-edge edge-keyed "$r1"
tr_tick 0
t triage471-closed-prose-second-tick-quiet 0 "$(trc '^SESSION triage$')"
# On this exact ready/prose fixture, origin/main's steady tick spends five
# calls: notifications, needs-triage, strays, discussions, and blocked issues.
# The widened graph replaces the three issue-list calls with one shared board
# read, spending the saved two on the issue/PR state map and preserving five.
TR471_PRE_CHANGE_PROSE_CALL_FLOOR=5
t triage471-retained-prose-keeps-pre-change-call-floor \
  "$TR471_PRE_CHANGE_PROSE_CALL_FLOOR" "$(grep -vc '^SESSION' "$TR_CALLS")"

# The #159 shape: a predecessor moves from OPEN to MERGED while the dependant
# remains open. The prompt names both ends, the transition, and the bounded
# body re-read; the engine itself performs no board write.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 OPEN)" \
  "$TR471_ONE" "$TR471_ONE"
tr_run 0
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 MERGED)" \
  "$TR471_ONE" "$TR471_ONE"
tr_tick 0
t triage471-merged-predecessor-wakes 1 "$(trc '^SESSION triage$')"
if grep -Fq '#471 depends on #900: OPEN -> MERGED' "$TR_PROMPT.triage" && \
   grep -Fq "Re-read each dependant's body" "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-merged-prompt-names-edge-and-action named "$r1"
if grep -Eq 'issue (edit|comment)|api .*(POST|PATCH)|--add-label|--remove-label' "$TR_CALLS"; then
  r1=MUTATED; else r1=read-only; fi
t triage471-path-writes-no-label-or-comment read-only "$r1"
t triage471-reads-open-issues-once 1 "$(trc 'number,body,updatedAt,labels')"
if grep -Fq 'These are leads, not verdicts' "$TR_PROMPT.triage"; then
  r1=present; else r1=MISSING; fi
t triage471-lead-not-verdict-caveat present "$r1"

# Reopening is a state change too: comparison is exact, not an assumed
# one-way ordering of GitHub's state words.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 OPEN)" \
  "$TR471_ONE" "$TR471_ONE"
tr_tick 0
if grep -Fq '#471 depends on #900: MERGED -> OPEN' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-reopened-predecessor-wakes named "$r1"

# Three edges on one dependant are independent ledger keys. Advancing one per
# tick must produce one named transition per tick rather than collapsing the
# whole dependant after the first wake.
TR471_THREE="$(tr471_issue 472 'Blocked by #901, #902, #903.')"
tr_fix '[]' '[]' '[]' '[]' '[]' \
  "$(tr471_states 901 OPEN 902 OPEN 903 OPEN)" "$TR471_THREE" "$TR471_THREE"
tr_run 0
t triage471-three-edges-recorded 3 "$(grep -c '^o/r#472#90[123] OPEN$' "$TRD/.seen-graph")"
for landed in 901 902 903; do
  s901=OPEN; s902=OPEN; s903=OPEN
  [ "$landed" -ge 901 ] && s901=MERGED
  [ "$landed" -ge 902 ] && s902=MERGED
  [ "$landed" -ge 903 ] && s903=MERGED
  tr_fix '[]' '[]' '[]' '[]' '[]' \
    "$(tr471_states 901 "$s901" 902 "$s902" 903 "$s903")" \
    "$TR471_THREE" "$TR471_THREE"
  tr_tick 0
  t "triage471-three-edges-tick-$landed-wakes-once" 1 \
    "$(grep -c 'depends on' "$TR_PROMPT.triage")"
done

# Multiple edges advancing in one tick render as multiple prompt lines. This
# catches both a collapsed edge list and a literal trailing backslash-n.
TR471_TWO="$(tr471_issue 473 'Blocked by #904, #905.')"
tr_fix '[]' '[]' '[]' '[]' '[]' \
  "$(tr471_states 904 MERGED 905 CLOSED)" "$TR471_TWO" "$TR471_TWO"
tr_run 0
t triage471-two-same-tick-edges-render-two-lines 2 \
  "$(grep -c '^  - #473 depends on #90[45]:' "$TR_PROMPT.triage")"
if grep -Fq '\n' "$TR_PROMPT.triage"; then r1=LITERAL_ESCAPE; else r1=rendered; fi
t triage471-two-same-tick-edges-have-no-literal-escape rendered "$r1"

# Signal (e) still consumes the blocked subset from the widened read and
# renders its established lead alongside (f); no existing verdict moved.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
if grep -Fq 'Possibly unblockable issues: #244' "$TR_PROMPT.triage"; then
  r1=unchanged; else r1=MISSING; fi
t triage471-signal-e-unblockable-verdict-unchanged unchanged "$r1"

# --- #632: a cross-repo gate holds signal (e) and fabricates no (f) edge ---
# heavy-duty/landing-site#40's declaration verbatim, driven through the
# module's own functions. The state map carries the locals CLOSED and ALSO a
# CLOSED local #421 — the wrong-repo collision — so a parser that keyed
# incubator#421 by its bare number would both nominate #40 and teach (f) an
# edge onto an unrelated local issue.
tr632_fn() {  # tr632_fn FUNCTION ARGS... — in a subshell with the module loaded
  # DUTY_DIR is the harness copy that carries lib/jq: signal (e) reads
  # blockers.jq from there, and against a directory without it the function
  # fails closed and the hold case would pass vacuously (its control catches
  # that, which is why the control exists).
  ( DUTY_DIR="$TRD"
    # shellcheck disable=SC1091
    . "$SHARED/lib/duty-triage.sh"; "$@" )
}
TR632_LS40='[{"number":40,"body":"Blocked by #38, #39, heavy-duty/incubator#421.","updatedAt":"2026-09-01T07:00:00Z"}]'
TR632_LOCAL='[{"number":40,"body":"Blocked by #38, #39.","updatedAt":"2026-09-01T07:00:00Z"}]'
TR632_S='{"38":"CLOSED","39":"CLOSED","421":"CLOSED"}'
t triage632-signal-e-holds-on-crossrepo-gate "" \
  "$(tr632_fn _triage_unblockable_items o/r "$TR632_LS40" "$TR632_S")"
t triage632-signal-e-control-releases-on-locals "o/r#40 2026-09-01T07:00:00Z" \
  "$(tr632_fn _triage_unblockable_items o/r "$TR632_LOCAL" "$TR632_S")"
# D3: the (f) edge set for the body carrying the cross-repo reference is the
# edge set for the same body without it — the qualified member is UNKNOWN to
# the state map and absorbed, never `o/r#40#421 CLOSED`.
tr632_edges() { tr632_fn _triage_graph_items "$(tr632_fn _triage_graph_edges o/r "$1")" "$TR632_S"; }
t triage632-signal-f-edge-set-unchanged-by-crossrepo-ref \
  "$(tr632_edges "$TR632_LOCAL")" "$(tr632_edges "$TR632_LS40")"
t triage632-signal-f-edge-set-is-the-two-locals \
  $'o/r#40#38 CLOSED\no/r#40#39 CLOSED' "$(tr632_edges "$TR632_LS40")"
# The engine end to end on the same board: (f)'s two cold edges wake one
# session, and the prompt it renders carries no unblockable lead for #40.
tr_fix '[]' '[]' '[]' "$TR632_LS40" "$TR632_LS40" \
  "$(tr471_states 38 CLOSED 39 CLOSED 421 CLOSED)"
tr_run 0
t triage632-crossrepo-board-wakes-on-graph-only 1 "$(trc '^SESSION triage$')"
if grep -Fq 'Possibly unblockable issues' "$TR_PROMPT.triage"; then
  r1=NOMINATED; else r1=held; fi
t triage632-crossrepo-board-prompt-has-no-unblockable-lead held "$r1"
t triage632-crossrepo-board-ledgers-no-fabricated-edge 0 "$(grep -c '#421' "$TRD/.seen-graph")"

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

# Direction one — an issue whose only queue label is blocked is not a stray
# (it was post-merge until ceremony 0.7.11 retired that row).
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board blocked)"
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
suppressed_triage_board="$(cat "$TRD"/.suppressed-triage-board.* 2>/dev/null)"
if grep -q 'o/r#100' <<<"$suppressed_triage_board"; then
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
t triage358-doctrine-set-nonvacuous 5 "$(printf '%s' "$tr358_doctrine_set" | wc -w | tr -d ' ')"

# The engine's set, taken from signal (b)'s own --arg list and resolved through
# the shipped conf. A label added to LABELS.md and not to the engine fails
# here, and so does one added to the engine and not to LABELS.md.
tr358_select="$(awk '/if ! stray_items=/,/stray parse failed/' "$SHARED/lib/duty-triage.sh")"
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
# Named separately so the conf's own state — the row ceremony 0.7.11 retired —
# reads as itself rather than as a set diff.
if grep -q '^LABEL_POST_MERGE=' "$SHARED/conf/fleet.defaults.conf"; then
  r1=STILL-DEFINED; else r1=retired; fi
t triage358-conf-retired-post-merge retired "$r1"

# --- #461: operator ownership composes with ready, but is not build duty ----
# Signal (b) stays a six-queue-label question. The builder consumes the same
# board differently: `ready` says the work is unblocked, while `operator` says
# it belongs to a human rather than this engine. Drive the production filter
# directly, then derive the exact board count / ledger count / no-duty branch
# its call site uses. This keeps an empty ledger from accidentally becoming the
# implementation and makes the populated-ledger control the same observation.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-builder.sh"

OP461_T='2026-08-27T00:00:00Z'
OP461_OPERATOR="$(jq -cn --arg t "$OP461_T" '[{
  number: 461, assignees: [], updatedAt: $t,
  labels: [{name:"ready"},{name:"operator"}]
}]')"
OP461_PLAIN="$(jq -cn --arg t "$OP461_T" '[{
  number: 461, assignees: [], updatedAt: $t,
  labels: [{name:"ready"}]
}]')"
OP461_SEEN_COLD="$TMP/op461-seen-cold"
OP461_SEEN_HOT="$TMP/op461-seen-hot"
printf 'o/r#461 %s\n' "$OP461_T" | ledger_commit "$OP461_SEEN_HOT"

op461_signal() {  # JSON OPERATOR_LABEL LEDGER — session-count<TAB>reason
  local json="$1" operator_label="$2" ledger="$3"
  local items board count sessions=0 reason=""
  items="$(printf '%s' "$json" | _ready_issue_lines o/r "$operator_label")"
  board="$(printf '%s\n' "$items" | awk 'NF{c++} END{print c+0}')"
  count="$(printf '%s\n' "$items" | ledger_filter "$ledger" | awk 'NF{c++} END{print c+0}')"
  if [ "$count" -gt 0 ]; then
    sessions=1
    reason=build-duty
  else
    reason="$(_no_build_duty_reason "$board" 0 '' 1)"
  fi
  printf '%s\t%s' "$sessions" "$reason"
}

OP461_COLD="$(op461_signal "$OP461_OPERATOR" operator "$OP461_SEEN_COLD")"
OP461_HOT="$(op461_signal "$OP461_OPERATOR" operator "$OP461_SEEN_HOT")"
t operator-ready-cold-starts-no-session 0 "${OP461_COLD%%$'\t'*}"
t operator-ready-cold-is-board-empty 'board empty' "${OP461_COLD#*$'\t'}"
case "$OP461_COLD" in *seen-ledger*) r1=WRONG_NOUN ;; *) r1=absent ;; esac
t operator-ready-is-not-ledger-held absent "$r1"
t operator-ready-ledger-independent "$OP461_COLD" "$OP461_HOT"

OP461_PLAIN_SIGNAL="$(op461_signal "$OP461_PLAIN" operator "$OP461_SEEN_COLD")"
t operator-plain-ready-starts-one-session 1 "${OP461_PLAIN_SIGNAL%%$'\t'*}"
t operator-plain-ready-is-build-duty build-duty "${OP461_PLAIN_SIGNAL#*$'\t'}"

# Compatibility is fail-open by design: an older/unset config sees exactly the
# pre-#461 ready set and raises no jq error.
OP461_UNSET="$(op461_signal "$OP461_OPERATOR" '' "$OP461_SEEN_COLD")"
t operator-unset-keeps-ready-pickable 1 "${OP461_UNSET%%$'\t'*}"
t operator-unset-keeps-old-build-signal build-duty "${OP461_UNSET#*$'\t'}"

# Wiring: the one existing ready listing carries labels, the production
# ready_items assignment calls the filter, and the filtered set is counted
# afterwards. A prompt-only implementation or an after-ready_board exclusion
# fails one of these independently of the behavioural helper cases above.
OP461_BUILD="$SHARED/lib/duty-builder.sh"
if grep -Fq -- '--json number,assignees,labels,updatedAt' "$OP461_BUILD"; then
  r1=fetched
else
  r1=MISSING
fi
t operator-ready-listing-fetches-labels fetched "$r1"
# shellcheck disable=SC2016  # source literals, not test-shell expansions
op461_filter_ln="$(grep -nF '| _ready_issue_lines "$R" "${LABEL_OPERATOR:-}"' "$OP461_BUILD" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # source literal, not command substitution here
op461_board_ln="$(grep -nF 'ready_board="$(' "$OP461_BUILD" | head -1 | cut -d: -f1)"
if [ -n "$op461_filter_ln" ] && [ -n "$op461_board_ln" ] &&
   [ "$op461_filter_ln" -lt "$op461_board_ln" ]; then
  r1=before
else
  r1=AFTER
fi
t operator-filter-precedes-ready-board before "$r1"

# The composing flag is configured beside the other cross-cutting names and
# never enters either copy of the five-member queue set. The existing #358 set
# equality above is the behavioural half; these assertions pin the tempting
# but wrong "seventh queue label" tidy-up.
if grep -q '^LABEL_OPERATOR="operator"$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=defined
else
  r1=MISSING
fi
t operator-conf-defines-composing-label defined "$r1"
op461_queue_count="$(sed -n '/^LABEL_READY=/,/^LABEL_NEEDS_TRIAGE=/p' \
  "$SHARED/conf/fleet.defaults.conf" | grep -c '^LABEL_[A-Z_]*=')"
t operator-queue-set-stays-five 5 "$op461_queue_count"
op461_queue_block="$(sed -n '/^LABEL_READY=/,/^LABEL_NEEDS_TRIAGE=/p' \
  "$SHARED/conf/fleet.defaults.conf")"
if grep -q 'LABEL_OPERATOR' <<<"$op461_queue_block"; then
  r1=IN_QUEUE
else
  r1=outside
fi
t operator-label-stays-outside-queue-block outside "$r1"
if grep -q 'LABEL_OPERATOR' "$SHARED/lib/duty-triage.sh"; then
  r1=TOUCHED
else
  r1=untouched
fi
t operator-triage-detector-needs-no-new-label untouched "$r1"

# `ready` already satisfies triage signal (b), so composing `operator` must not
# turn the issue into a stray. Conversely operator alone is not a queue state.
OP461_STRAY_READY='[{"number":461,"labels":[{"name":"ready"},{"name":"operator"}],"updatedAt":"2026-08-27T00:00:00Z"}]'
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$OP461_STRAY_READY"
tr_run 0
t operator-ready-is-not-a-triage-session 0 "$(trc '^SESSION triage$')"
if grep -q 'queue-unlabeled' "$TR_LOG"; then r1=NAMED; else r1=silent; fi
t operator-ready-is-not-queue-unlabeled silent "$r1"
OP461_STRAY_ONLY='[{"number":461,"labels":[{"name":"operator"}],"updatedAt":"2026-08-27T00:00:00Z"}]'
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$OP461_STRAY_ONLY"
tr_run 0
t operator-alone-is-still-a-stray 1 "$(trc '^SESSION triage$')"

# The prompt clause uses the configured name and disappears completely when
# unset. Its empty rendering preserves the old sentence byte-for-byte around
# the insertion point; the configured rendering tells a session the same rule
# the engine enforced.
t operator-empty-prompt-clause-is-byte-empty '' "$(_operator_build_prompt_clause '')"
OP461_CLAUSE="$(_operator_build_prompt_clause operator)"
# shellcheck disable=SC2016  # prompt backticks are literal prose
case "$OP461_CLAUSE" in
  *'`operator`'*'operator-owned work, not work for a builder'*) r1=named ;;
  *) r1=MISSING ;;
esac
t operator-configured-prompt-clause-names-ownership named "$r1"
OP461_PROMPT_EMPTY="$(PROMPTS_DIR="$SHARED/prompts" render_prompt build.txt OPERATOR_CLAUSE='')"
if grep -Fq 'otherwise pick ONE ready unclaimed issue, claim it' <<<"$OP461_PROMPT_EMPTY" &&
   ! grep -q '{{OPERATOR_CLAUSE}}' <<<"$OP461_PROMPT_EMPTY"; then
  r1=identical
else
  r1=CHANGED
fi
t operator-unset-prompt-keeps-old-sentence identical "$r1"
OP461_PROMPT_SET="$(PROMPTS_DIR="$SHARED/prompts" render_prompt build.txt OPERATOR_CLAUSE="$OP461_CLAUSE")"
# shellcheck disable=SC2016  # prompt backticks are literal prose
if grep -Fq 'a ready issue carrying `operator` is operator-owned work, not work for a builder; otherwise pick ONE ready unclaimed issue, claim it' <<<"$OP461_PROMPT_SET"; then
  r1=rendered
else
  r1=MISSING
fi
t operator-configured-prompt-renders-clause rendered "$r1"

# A doctrine-gap duty exists only when the configured upstream is inside the
# operator's repos.txt containment boundary. Empty preserves today's prompt
# byte-for-byte; an unlisted value renders only the local refusal and warns.
DOCTRINE463_BASE="$(DOCTRINE_REPO='' PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals')"
DOCTRINE463_TODAY="$(sed 's/{{ME}}/me-bot/g; s|{{REPO}}|o/r|g; s/{{SIGNAL_BLOCK}}/signals/g; s/{{DOCTRINE_OUTCOME}}//g; s/{{DOCTRINE_ENTRYPOINT}}/AGENTS.md/g; s/{{DOCTRINE_TRIAGE}}/TRIAGE.md/g' \
  "$SHARED/prompts/triage.txt")"
t doctrine-upstream-empty-is-byte-identical "$DOCTRINE463_TODAY" "$DOCTRINE463_BASE"
if grep -Eq 'DOCTRINE_REPO|owner/repo|upstream duty|consumer guide' <<<"$DOCTRINE463_BASE"; then
  r1=LEAKED
else
  r1=inert
fi
t doctrine-upstream-empty-is-inert inert "$r1"

printf 'o/r\n' >"$TRD/repos.txt"
DOCTRINE463_WARN="$TMP/doctrine463-warn"
DOCTRINE463_UNLISTED="$(DOCTRINE_REPO='heavy-duty/ceremony' REPOS_FILE="$TRD/repos.txt" \
  PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals' 2>"$DOCTRINE463_WARN")"
if grep -Fq 'do not write to heavy-duty/ceremony' <<<"$DOCTRINE463_UNLISTED" &&
   grep -Fq 'outside the operator' <<<"$DOCTRINE463_UNLISTED" &&
   grep -Fq 'log a WARN naming heavy-duty/ceremony and the concrete doctrine finding' <<<"$DOCTRINE463_UNLISTED" &&
   ! grep -Fq 'open a discussion in heavy-duty/ceremony' <<<"$DOCTRINE463_UNLISTED" &&
   [ "$DOCTRINE463_UNLISTED" != "$DOCTRINE463_BASE" ]; then
  r1=refused
else
  r1=UNBOUNDED
fi
t doctrine-upstream-unlisted-renders-refusal-not-duty refused "$r1"
if grep -Fq 'heavy-duty/ceremony' "$DOCTRINE463_WARN" &&
   grep -Fq "$TRD/repos.txt" "$DOCTRINE463_WARN"; then
  r1=bounded
else
  r1=MISSING
fi
t doctrine-upstream-unlisted-warns-with-repo-and-registry bounded "$r1"

printf '%s\n' o/r heavy-duty/ceremony >"$TRD/repos.txt"
DOCTRINE463_LISTED="$(DOCTRINE_REPO='heavy-duty/ceremony' REPOS_FILE="$TRD/repos.txt" \
  PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals')"
if grep -Fq 'discussion in heavy-duty/ceremony' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq "Quote the rule at this repository's pin" <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'link the local issue' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'state the workaround and its retirement condition' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'any issue its triage later mints, from the consumer workaround' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'keep the upstream request linked back to that consumer' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'Never mint an upstream issue yourself.' <<<"$DOCTRINE463_LISTED"; then
  r1=complete
else
  r1=MISSING
fi
t doctrine-upstream-listed-renders-bounded-duty complete "$r1"
case "$DOCTRINE463_LISTED" in
  *"demand."$'\n\n'"When the vendored doctrine"*) r1=standalone ;;
  *) r1=GLUED ;;
esac
t doctrine-upstream-listed-duty-is-standalone standalone "$r1"
DOCTRINE463_ENV_ONLY="$(DOCTRINE_REPO='heavy-duty/ceremony' \
  PROMPTS_DIR="$SHARED/prompts" render_prompt fragment-doctrine-upstream.txt)"
if grep -Fq 'heavy-duty/ceremony' <<<"$DOCTRINE463_ENV_ONLY"; then
  r1=LEAKED
else
  r1=contained
fi
t doctrine-upstream-address-requires-caller-pair contained "$r1"
DOCTRINE463_BOARD='[{"number":463,"body":"The vendored doctrine cannot express this case; keep the local workaround until the upstream discussion lands.","labels":[{"name":"ready"}],"updatedAt":"2026-08-27T00:00:00Z"}]'
printf 'o/r\n' >"$TRD/repos.txt"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$DOCTRINE463_BOARD"
tr_run 0
t doctrine-upstream-prose-adds-no-triage-signal 0 "$(trc '^SESSION triage$')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=untouched
else
  r1=TOUCHED
fi
t doctrine-upstream-prose-keeps-quiet-board untouched "$r1"

# --- #503: round count as sizing evidence, in front of triage ---------------
#
# Doctrine reads round growth as sizing evidence for the NEXT mint, and the
# judgement belongs to triage before a builder claims. These drive the real
# module: the evidence must reach a launching session's prompt, must cost a
# quiet tick nothing, and must never act.
TR503_LEAD='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-01T15:30:00Z"}]'
tr503_wake() {  # tr503_wake <page-json>, a tick whose unblockable lead launches a session
  tr_fix '[]' '[]' '[]' "$TR503_LEAD" "$TR503_LEAD" "$TR_LANDED"
  printf '%s' "$1" >"$TRF/prs.1.json"
  printf '%s' "$1" >"$TRF/prs.2.json"
  tr_run 0
}

# The board D3's example is about: one issue at fourteen rounds while the median
# is three. Both figures must be legible, because the outlier means nothing
# without the distribution beside it.
tr503_wake "$(tr_prs "$(tr_pr 1 'Closes #10' 1)" "$(tr_pr 2 'Closes #11' 3)" \
  "$(tr_pr 3 'Closes #12' 14)")"
t triage503-launches-a-session 1 "$(trc '^SESSION triage$')"
if grep -q 'median 3' "$TR_PROMPT.triage" && grep -q 'max 14' "$TR_PROMPT.triage"; then
  r1=distributed; else r1="$(cat "$TR_PROMPT.triage")"; fi
t triage503-prompt-carries-the-distribution distributed "$r1"
if grep -q '#12: 14 round(s)' "$TR_PROMPT.triage"; then r1=rowed; else r1=MISSING; fi
t triage503-prompt-carries-the-per-issue-rows rowed "$r1"
# EVERY issue's count, not only the interesting ones — the criterion is "each
# issue's PR round count is readable by the triage duty", and the distribution
# alone cannot answer "how many rounds did #10 take". The one-round issue is the
# case any bound would drop first, so it is the one asserted.
if grep -q '#10: 1 round(s)' "$TR_PROMPT.triage" \
  && grep -q '#11: 3 round(s)' "$TR_PROMPT.triage"; then r1=all; else r1=TRUNCATED; fi
t triage503-prompt-carries-every-issues-row all "$r1"
if grep -q 'all 3 of them, most rounds first' "$TR_PROMPT.triage"; then
  r1=counted; else r1=MISCOUNTED; fi
t triage503-prompt-row-count-matches-the-rows counted "$r1"
# Most rounds first, so the outlier reads before the tail.
TR503_ROW_ORDER="$(grep -o '#1[0-2]: [0-9]* round' "$TR_PROMPT.triage" \
  | sed 's/:.*//' | paste -sd, -)"
t triage503-rows-are-sorted-by-count '#12,#11,#10' "$TR503_ROW_ORDER"
# Read against the ruled five, not a number crew picked — and the cap in the
# prompt comes from round-cap.jq, so it can never drift from the one the engine
# holds a request on.
if grep -q 'the cap it is read against is 5' "$TR_PROMPT.triage" \
  && grep -q 'at or over the cap of 5' "$TR_PROMPT.triage"; then
  r1=five; else r1=MISSING; fi
t triage503-prompt-reads-against-the-ruled-cap five "$r1"

# The capped chain, end to end through the duty rather than through jq alone.
tr503_wake "$(tr_prs "$(tr_pr 566 'Refs #503' 5)" "$(tr_pr 586 'Closes #503' 3)")"
if grep -q '#503: 8 round(s) over 2 PR(s)' "$TR_PROMPT.triage"; then
  r1=one-issue; else r1="$(grep -c '#503' "$TR_PROMPT.triage")"; fi
t triage503-cut-chain-is-one-row one-issue "$r1"
# MUST FAIL: a capped chain double-counting. Two observations of 5 and 3 would
# make the median 4 and the max 5; one observation of 8 makes both 8.
if grep -q '1 issue(s) with at least one round' "$TR_PROMPT.triage" \
  && grep -q 'median 8' "$TR_PROMPT.triage"; then r1=counted-once; else r1=DOUBLE; fi
t triage503-cut-chain-counts-once counted-once "$r1"

# A board whose only PR is still unreviewed has an empty distribution and a row
# worth rendering. Gating the evidence on the distribution would withhold it from
# exactly the young board that has the least of it, and would make "each issue's
# count is readable" false for the issue most likely to be sized right now.
tr503_wake "$(tr_prs "$(tr_pr 9 'Closes #77' 0)")"
if grep -q '#77: 0 round(s) over 1 PR(s)' "$TR_PROMPT.triage"; then
  r1=rowed; else r1=MISSING; fi
t triage503-unreviewed-issue-still-gets-its-row rowed "$r1"
if grep -q '0 issue(s) with at least one round' "$TR_PROMPT.triage" \
  && grep -q '1 issue(s) with a PR but no round yet' "$TR_PROMPT.triage"; then
  r1=held-out; else r1=COUNTED; fi
t triage503-unreviewed-issue-is-out-of-the-median held-out "$r1"

# MUST FAIL: a distribution computed from open PRs only. History is what makes
# the first reading mean anything (D5), and the states are in the query — so
# this is asserted where the decision actually lives.
if grep -q 'states:\[OPEN,CLOSED,MERGED\]' "$SHARED/lib/duty-triage.sh"; then
  r1=history-included; else r1=OPEN-ONLY; fi
t triage503-distribution-includes-closed-prs history-included "$r1"

# IT IS CONTEXT, NOT A WAKE. A board with round history and no signal launches
# nothing: a distribution moves whenever any PR gains a round, so as a signal it
# would re-fire on an unchanged board forever, with nothing for a session to do
# about it (#59's defect). And a quiet tick must not even pay for the read.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
printf '%s' "$(tr_prs "$(tr_pr 3 'Closes #12' 14)")" >"$TRF/prs.1.json"
printf '%s' "$(tr_prs "$(tr_pr 3 'Closes #12' 14)")" >"$TRF/prs.2.json"
tr_run 0
t triage503-round-history-is-no-wake 0 "$(trc '^SESSION triage$')"
t triage503-quiet-tick-reads-no-rounds 0 "$(trc 'pullRequests(first')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=quiet; else r1="$(cat "$TR_LOG")"; fi
t triage503-quiet-tick-log-unchanged quiet "$r1"

# MUST FAIL: any automatic relabel (D4). The evidence surfaces and stops — no
# label, split or block follows from it. Asserted over the whole call log of a
# tick that DID render evidence, so a future write would have to show up here.
tr503_wake "$(tr_prs "$(tr_pr 3 'Closes #12' 14)")"
TR503_ACTIONS="$(grep -Ec 'issue edit|pr edit|--add-label|--remove-label|-X PATCH|-X POST|-X PUT|-X DELETE|mutation' \
  "$TR_CALLS" || true)"
t triage503-takes-no-automatic-action 0 "$TR503_ACTIONS"
# ...and the prompt says so too, because the session is the other actor that
# could act on it and doctrine gives the judgement to a human-grade read.
if grep -q 'Nothing is labelled, split, blocked or relabelled on account of it' \
    "$TR_PROMPT.triage"; then r1=said; else r1=SILENT; fi
t triage503-prompt-forbids-acting-on-it said "$r1"

# A fetch failure costs the evidence and nothing else: the session still runs on
# the signals that woke it, and no partial distribution is presented as measured.
tr_fix '[]' '[]' '[]' "$TR503_LEAD" "$TR503_LEAD" "$TR_LANDED"
: >"$TRF/prs.fail"
tr_run 0
t triage503-fetch-failure-still-launches 1 "$(trc '^SESSION triage$')"
if grep -q 'round-count fetch failed' "$TR_LOG"; then r1=warned; else r1="$(cat "$TR_LOG")"; fi
t triage503-fetch-failure-warns warned "$r1"
if grep -q 'Sizing evidence' "$TR_PROMPT.triage"; then r1=PARTIAL; else r1=omitted; fi
t triage503-fetch-failure-renders-no-evidence omitted "$r1"
# The unrendered slot leaves no marker behind either — a literal {{ROUND_EVIDENCE}}
# in a prompt is the shape render_prompt produces for a slot nobody supplied.
if grep -q 'ROUND_EVIDENCE' "$TR_PROMPT.triage"; then r1=LEAKED; else r1=clean; fi
t triage503-unrendered-slot-leaves-no-marker clean "$r1"

# The issue pattern is duty-builder.sh's constant, reached across duty modules.
# bin/duty.sh sources all four before any role dispatch, so it is defined on a
# triage-only box — pinned here so a later reordering cannot silently empty it
# and quietly attribute every PR to no issue.
if grep -q '_RESUME_ISSUE_RE' "$SHARED/lib/duty-triage.sh" \
  && grep -q '^_RESUME_ISSUE_RE=' "$SHARED/lib/duty-builder.sh"; then
  r1=shared; else r1=COPIED; fi
t triage503-issue-pattern-is-the-builders-constant shared "$r1"
# shellcheck disable=SC2016  # match the literal $DUTY_DIR source lines in duty.sh
TR503_ORDER="$(grep -n 'source "$DUTY_DIR/lib/duty-\(builder\|triage\)\.sh"' "$SHARED/bin/duty.sh" \
  | head -2 | sed 's/:.*duty-/ /;s/\.sh"//' | awk '{print $2}' | paste -sd, -)"
t triage503-builder-module-is-sourced-first builder,triage "$TR503_ORDER"
# The dispatch call is indented inside `if has_role triage`, so this compares
# line numbers rather than matching an anchored line.
# shellcheck disable=SC2016  # match the literal $DUTY_DIR source line in duty.sh
TR503_SRC_LINE="$(grep -n 'source "$DUTY_DIR/lib/duty-builder.sh"' "$SHARED/bin/duty.sh" \
  | head -1 | cut -d: -f1)"
TR503_CALL_LINE="$(grep -n '^[[:space:]]*duty_triage$' "$SHARED/bin/duty.sh" \
  | head -1 | cut -d: -f1)"
if [ -n "$TR503_SRC_LINE" ] && [ -n "$TR503_CALL_LINE" ] \
  && [ "$TR503_SRC_LINE" -lt "$TR503_CALL_LINE" ]; then r1=before; else r1=AFTER; fi
t triage503-builder-module-sourced-before-dispatch before "$r1"

# --- a real board's worth of pages, at a real board's size (round 1) ---------
#
# WHY THIS FIXTURE IS BIG, AND WHY THAT IS THE TEST. Every case above is one
# page of a few small nodes, and that is exactly how the accumulator shipped a
# defect past a green suite: it folded the page into the running history with
# `--argjson`, which makes each JSON value ONE argv element, and a single
# element is capped at MAX_ARG_STRLEN — 131,072 bytes — whatever ARG_MAX says.
# Crew's own first page is ~1.10 MB, so `execve` failed with E2BIG on the first
# page of every real board while every fixture here sailed under the limit. A
# case that cannot reach the limit cannot see the bug, so this one carries a
# page that crosses it.
#
# AND IT PAGINATES, because the cursor handoff was never exercised either: the
# fixtures all set hasNextPage:false. The shim serves page two only against the
# exact endCursor page one handed out.
#
# The assertions are on the RENDERED EVIDENCE, not on the call count. A call
# count would have passed against the broken code too — the fetch is not what
# failed. Every figure below is chosen so the wrong answer is a DIFFERENT
# number rather than an absent one: page one alone is 10 issues at min 2,
# median 2, max 2, and both pages together are 21 at min 2, median 9, max 9.
TR503_P1=(); TR503_P2=()
for tr503_i in 1 2 3 4 5 6 7 8 9 10; do
  TR503_P1+=("$(tr_pr_bulk "$((600 + tr503_i))" "$((600 + tr503_i))" 2)")
done
# Page two is unpadded: its job is the cursor and the arithmetic, and page one
# already carries the bytes.
for tr503_i in 1 2 3 4 5 6 7 8 9 10 11; do
  TR503_P2+=("$(tr_pr "$((700 + tr503_i))" "Closes #$((700 + tr503_i))" 9)")
done
tr_fix '[]' '[]' '[]' "$TR503_LEAD" "$TR503_LEAD" "$TR_LANDED"
TR503_PAGE1="$(tr_prs_more TR-CURSOR-PAGE-2 "${TR503_P1[@]}")"
TR503_PAGE2="$(tr_prs "${TR503_P2[@]}")"
printf '%s' "$TR503_PAGE1" >"$TRF/prs.1.json"; printf '%s' "$TR503_PAGE1" >"$TRF/prs.2.json"
printf '%s' "$TR503_PAGE2" >"$TRF/prs2.1.json"; printf '%s' "$TR503_PAGE2" >"$TRF/prs2.2.json"

# The fixture's own size, asserted. Without this a later edit that trims the
# padding for speed would silently stop testing the bound, and every case below
# would keep passing while covering nothing — which is the failure this whole
# block exists to undo.
TR503_NODE_BYTES="$(printf '%s' "$TR503_PAGE1" \
  | jq -c '.data.repository.pullRequests.nodes' | wc -c)"
if [ "$TR503_NODE_BYTES" -gt 131072 ]; then r1=over; else r1="under:$TR503_NODE_BYTES"; fi
t triage503-page-fixture-crosses-the-argv-bound over "$r1"

tr_run 0
t triage503-paginated-board-launches-a-session 1 "$(trc '^SESSION triage$')"
t triage503-paginated-board-reads-both-pages 2 "$(trc 'pullRequests(first')"
# THE BOUND ITSELF. An accumulator that puts the page on argv never gets here:
# it warns and returns, and the fragment is absent entirely.
if grep -q 'round-count accumulate failed' "$TR_LOG"; then r1=E2BIG; else r1=folded; fi
t triage503-oversized-page-folds folded "$r1"
if grep -q 'Sizing evidence' "$TR_PROMPT.triage"; then r1=rendered; else r1=ABSENT; fi
t triage503-oversized-page-reaches-the-prompt rendered "$r1"
# PAGE ONE reached the rendered rows — the page that crosses the bound.
if grep -q '#601: 2 round(s)' "$TR_PROMPT.triage" \
  && grep -q '#610: 2 round(s)' "$TR_PROMPT.triage"; then r1=rowed; else r1=MISSING; fi
t triage503-oversized-page-rows-are-rendered rowed "$r1"
# PAGE TWO reached them too, which is the cursor handoff answered on the output
# rather than on the call log: #701 and #711 exist on no other page.
if grep -q '#701: 9 round(s)' "$TR_PROMPT.triage" \
  && grep -q '#711: 9 round(s)' "$TR_PROMPT.triage"; then r1=rowed; else r1=MISSING; fi
t triage503-second-page-rows-are-rendered rowed "$r1"
# And the DISTRIBUTION is the two-page one. Page one alone would say 10 issues,
# median 2, max 2 — three different numbers, so a lost page cannot pass this.
if grep -q '21 issue(s) with at least one round' "$TR_PROMPT.triage" \
  && grep -q 'min 2, median 9, max 9' "$TR_PROMPT.triage"; then
  r1=both-pages; else r1="$(grep -o '[0-9]* issue(s) with at least one round.*' "$TR_PROMPT.triage")"; fi
t triage503-distribution-spans-every-page both-pages "$r1"
t triage503-paginated-board-still-takes-no-action 0 \
  "$(grep -Ec 'issue edit|pr edit|--add-label|--remove-label|-X PATCH|-X POST|-X PUT|-X DELETE|mutation' \
    "$TR_CALLS" || true)"

# The cursor is CHECKED, not just sent: the shim answers page two only against
# the exact endCursor, so a census that dropped or mangled it would be served a
# terminal empty page and lose #701-#711. Pinned here so the two assertions
# above cannot be satisfied by a shim that hands out page two unconditionally.
if grep -q -e '-f after=TR-CURSOR-PAGE-2 ' "$TR_CALLS"; then r1=carried; else r1=DROPPED; fi
t triage503-second-page-carries-the-cursor carried "$r1"

# ── #757 D8 — the discussion return clock, and a human's reply wakes triage ──
# Signal (c)'s selector used to drop every thread $ME had commented on, so
# converging a discussion removed it from the wake set for good: an ask or an
# escalate with `returns on <date>` was never read again. The selector is now
# lib/jq/discussions.jq, driven here over a fixture board on three dates.
TR_D8_FIX="$TRF/d8-discussions.json"
cat >"$TR_D8_FIX" <<'JSON'
{"data":{"repository":{"discussions":{"nodes":[
 {"number":1,"updatedAt":"2026-10-01T00:00:00Z","comments":{"nodes":[]}},
 {"number":2,"updatedAt":"2026-10-02T00:00:00Z","comments":{"nodes":[{"author":{"login":"me"},"body":"I will look","createdAt":"2026-10-01T01:00:00Z","replies":{"nodes":[{"author":{"login":"dan"},"body":"thanks, any news?","createdAt":"2026-10-02T00:00:00Z"}]}}]}},
 {"number":3,"updatedAt":"2026-10-03T00:00:00Z","comments":{"nodes":[{"author":{"login":"me"},"body":"converged: declined.","createdAt":"2026-10-03T00:00:00Z","replies":{"nodes":[]}}]}},
 {"number":4,"updatedAt":"2026-10-04T00:00:00Z","comments":{"nodes":[{"author":{"login":"me"},"body":"Asked the operator; returns on 2026-10-20.","createdAt":"2026-10-04T00:00:00Z","replies":{"nodes":[]}}]}},
 {"number":5,"updatedAt":"2026-10-05T00:00:00Z","comments":{"nodes":[{"author":{"login":"me"},"body":"escalated; returns on 2026-12-01.","createdAt":"2026-10-05T00:00:00Z","replies":{"nodes":[]}}]}},
 {"number":6,"updatedAt":"2026-10-06T00:00:00Z","comments":{"nodes":[{"author":{"login":"dan"},"body":"first","createdAt":"2026-10-01T00:00:00Z","replies":{"nodes":[]}},{"author":{"login":"me"},"body":"returns on 2026-10-09; then returns on 2026-10-22.","createdAt":"2026-10-06T00:00:00Z","replies":{"nodes":[]}}]}}
]}}}}
JSON
d8_sel() { TR_ME=me TR_R=o/r TR_TODAY="$1" jq -r -f "$SHARED/lib/jq/discussions.jq" "$TR_D8_FIX" | paste -sd' ' -; }
t d8-selector-on-2026-10-23 \
  "o/r#1 2026-10-01T00:00:00Z o/r#2 2026-10-02T00:00:00Z o/r#4 2026-10-20T00:00:00Z o/r#6 2026-10-22T00:00:00Z" \
  "$(d8_sel 2026-10-23)"
t d8-a-thread-nobody-answered-wakes 1 "$(d8_sel 2026-10-23 | grep -o 'o/r#1 ' | wc -l | tr -d ' ')"
t d8-a-humans-reply-wakes-even-after-mine 1 "$(d8_sel 2026-10-23 | grep -o 'o/r#2 ' | wc -l | tr -d ' ')"
t d8-my-converged-thread-stays-silent 0 "$(d8_sel 2026-10-23 | grep -o 'o/r#3 ' | wc -l | tr -d ' ')"
t d8-a-future-return-waits 0 "$(d8_sel 2026-10-23 | grep -o 'o/r#5 ' | wc -l | tr -d ' ')"
t d8-the-return-arrives-the-day-it-says 1 "$(d8_sel 2026-10-20 | grep -o 'o/r#4 2026-10-20T00:00:00Z' | wc -l | tr -d ' ')"
t d8-the-return-is-not-due-the-day-before 0 "$(d8_sel 2026-10-19 | grep -o 'o/r#4 ' | wc -l | tr -d ' ')"
t d8-the-last-date-in-the-body-is-the-promise 0 "$(d8_sel 2026-10-21 | grep -o 'o/r#6 ' | wc -l | tr -d ' ')"
t d8-the-last-date-in-the-body-arrives 1 "$(d8_sel 2026-10-22 | grep -o 'o/r#6 ' | wc -l | tr -d ' ')"
# The ledger key moves with the clock: a due return carries the return date,
# which is later than the thread's own updatedAt, so a thread the ledger saw at
# its updatedAt is new again the day the promise falls due.
t d8-a-due-return-advances-the-ledger-key 1 "$(d8_sel 2026-10-23 | grep -o 'o/r#4 2026-10-20T00:00:00Z' | wc -l | tr -d ' ')"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t d8-the-engine-reads-the-selector-from-its-file 1 "$(grep -c -- '--jq "$(cat "$DUTY_DIR/lib/jq/discussions.jq")"' "$SHARED/lib/duty-triage.sh")"
t d8-the-query-fetches-bodies-and-times 2 "$(grep -c 'author{ login } body createdAt' "$SHARED/lib/duty-triage.sh")"
# The worse half: a human answering a thread triage opened arrives as a
# notification with reason `author` (or `comment`), not `mention`, and was
# dropped. On a Discussion those reasons wake the mention session; on an Issue
# they still do not.
TR_D8_DISC_AUTHOR='[{"id":"t8","reason":"author","updated_at":"2026-08-01T15:40:00Z","repository":{"full_name":"o/r"},"subject":{"url":"https://api/d","type":"Discussion"}}]'
TR_D8_DISC_COMMENT='[{"id":"t9","reason":"comment","updated_at":"2026-08-01T15:41:00Z","repository":{"full_name":"o/r"},"subject":{"url":"https://api/d","type":"Discussion"}}]'
TR_D8_ISSUE_AUTHOR='[{"id":"t10","reason":"author","updated_at":"2026-08-01T15:42:00Z","repository":{"full_name":"o/r"},"subject":{"url":"https://api/i","type":"Issue"}}]'
tr_fix "$TR_D8_DISC_AUTHOR" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t d8-discussion-author-notification-wakes-the-mention-session 1 "$(trc '^SESSION mention$')"
tr_fix "$TR_D8_DISC_COMMENT" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t d8-discussion-comment-notification-wakes-the-mention-session 1 "$(trc '^SESSION mention$')"
tr_fix "$TR_D8_ISSUE_AUTHOR" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t d8-issue-author-notification-stays-silent 0 "$(trc '^SESSION mention$')"
unset -f d8_sel

# The discussions query reads the NEWEST comments and replies (#763 review):
# `first:` was the oldest fifty, so a human's reply on a long thread never
# woke triage.
t discussions-query-reads-the-newest-comments 1 "$(grep -c 'comments(last:50)' "$SHARED/lib/duty-triage.sh")"
t discussions-query-reads-the-newest-replies 1 "$(grep -c 'replies(last:20)' "$SHARED/lib/duty-triage.sh")"
t discussions-query-reads-no-oldest-first 0 "$(grep -cE 'comments\(first:|replies\(first:' "$SHARED/lib/duty-triage.sh" || true)"

suite_finish
