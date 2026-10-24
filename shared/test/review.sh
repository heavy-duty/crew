#!/usr/bin/env bash
# shared/test/review.sh — standalone reviewer subject suite.
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
# shellcheck source=shared/lib/duty-review.sh
source "$SHARED/lib/duty-review.sh"

H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PANEL='["rev-a","rev-b"]'
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
RR_H="$H"
RR_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RR_T1="2026-07-28T10:00:00Z"
RR_T2="2026-07-28T11:00:00Z"

# --- #114: the auto-approve must read the verdict's STATE, not just its head -
# The re-request rule (ceremony#94) existed to stop a STALE verdict blocking a
# tree that has not changed. It never consulted the verdict's state, so a
# re-request over a standing CHANGES_REQUESTED at an unchanged head was answered
# with a boilerplate approval — 3 of its 4 recorded fires rubber-stamped a live
# block. rereq_decision is that policy as a pure function; pin every transition.
# A live block (CHANGES_REQUESTED / DISMISSED) queues a real review; only a
# standing APPROVED still auto-approves.

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
# The no-push half survives, now engine-side: request-panel.jq re-requests a
# change-requester still AT the current head once the round is signalled answered
# (proved by rp-no-push-cr-at-head-requests-cr-er above), and the prompt names
# that case so the builder knows an argument-only answer still reaches the panel.
REREQUEST_RULES="$(PROMPTS_DIR="$SHARED/prompts" render_prompt fragment-round-rules.txt \
  MARK_ADDRESSING=addressing MARK_ANSWERED=answered DOCTRINE_BUILDER=BUILDER.md \
  BENCH='rev-a rev-b' TRIAGE=triage-bot ROUND_CAP=-)"
if grep -qi 'pushed nothing' <<<"$REREQUEST_RULES"; then r1=carved; else r1=MISSING; fi
t rerequest-no-push-half-engine-side carved "$r1"
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
addr() { jq -r --argjson panel "${1:-$PANEL}" --argjson roster "${2:-${1:-$PANEL}}" --arg addressing state:addressing -f "$AJQ"; }

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
# The panel sized for the head is rev-b alone; a request still open to rev-a
# — the roster's, outside the subset — is a round still open (#763 review).
REVS_ONE_B='[{"author":{"login":"rev-b"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}}]'
t addressing-a-sized-panel-closes-on-its-own-verdicts true "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ONE_B" | addr '["rev-b"]' '["rev-a","rev-b"]')"
t addressing-a-request-open-outside-the-sized-panel-is-still-open false "$(mk_pr "$H" MERGEABLE '[]' '["rev-a"]' "$REVS_ONE_B" | addr '["rev-b"]' '["rev-a","rev-b"]')"
# An empty panel never closes a round vacuously (mirror of converged-empty-panel).
t addressing-empty-panel-false false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --argjson roster '[]' --arg addressing state:addressing -f "$AJQ")"
# Mergeability is irrelevant to addressing: a conflicting PR can still owe a fix.
t addressing-conflicting-still-addresses true "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_ADDR" | addr)"
# The predicate keys approvals/reviews on the head, same as converged.jq — a
# stale approval at an old head keeps the round open.
t addressing-keys-on-head false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR_STALE" | addr)"

# Drive the real entrypoint through a completed review session. The addressing
# payload represents the verdict that session just submitted; the label write
# deliberately fails so this one drive proves ordering, exact arguments,
# best-effort failure, and the absence of any state:building write.
D601="$TMP/entrypoint"
mkdir -p "$D601/lib/jq" "$D601/work" "$D601/trees" "$D601/prompts"
cp "$SHARED/lib/jq/addressing.jq" "$D601/lib/jq/"
printf 'fx/repo\n' >"$D601/repos.txt"
D601_CALLS="$D601/calls"
D601_WARN="$D601/warn"
D601_PROMPT="$D601/prompt"
D601_HEAD="dddddddddddddddddddddddddddddddddddddddd"

d601_drive() (
  # shellcheck disable=SC2030  # fixture globals are intentionally isolated
  local DUTY_DIR="$D601" WORK_DIR="$D601/work" TREES_DIR="$D601/trees"
  local LOG_DIR="$D601/logs" CONF_DIR="$D601/conf" PROMPTS_DIR="$SHARED/prompts"
  local BIN_DIR="$D601/bin" REPOS_FILE="$D601/repos.txt"
  local ME=fixture-reviewer MARK_REVIEWING='reviewing head'
  local TIMEOUT_REVIEW=30 AUTO_APPROVE_REREQUEST=1 LABEL_ADDRESSING=state:addressing
  : >"$D601_CALLS"
  : >"$D601_WARN"
  : >"$D601_PROMPT"
  gh() {
    printf '%s\n' "$*" >>"$D601_CALLS"
    if [ "$1" = api ] && [[ "$2" == repos/fx/repo/pulls\?* ]]; then
      jq -cn --arg me "$ME" \
        '[{draft:false, requested_reviewers:[{login:$me}],
           created_at:"2026-08-30T06:00:00Z", updated_at:"2026-08-30T07:00:00Z",
           number:7, user:{login:"author"}}]'
      return 0
    fi
    if [ "$1" = search ]; then return 0; fi
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *'timelineItems(itemTypes:'* ]]; then
        printf '%s - - - 2026-08-30T06:30:00Z\n' "$D601_HEAD"
      elif [[ "$*" == *'reviews(author:'* ]]; then
        jq -cn --arg head "$D601_HEAD" '{data:{repository:{pullRequest:{reviews:{nodes:[
          {commit:{oid:$head},submittedAt:"2026-08-30T07:01:00Z",state:"APPROVED"}
        ]}}}}}'
      else
        jq -cn --arg head "$D601_HEAD" '{data:{repository:{pullRequest:{
          headRefOid:$head, author:{login:"author"}, labels:{nodes:[]},
          reviewRequests:{nodes:[]}, latestOpinionatedReviews:{nodes:[
            {author:{login:"rev-a"},state:"CHANGES_REQUESTED",commit:{oid:$head}},
            {author:{login:"rev-b"},state:"APPROVED",commit:{oid:$head}}
          ]}}}}}'
      fi
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then return 1; fi
    return 3
  }
  ensure_checkout() { mkdir -p "$2/.git"; }
  _review_check_evidence_list() { printf -- '- %s#%s: fixture evidence.\n' "$1" "$2"; }
  panel_for_repo() { printf '["rev-a","rev-b"]\n'; }
  run_session() {
    printf 'SESSION %s %s\n' "$1" "$2" >>"$D601_CALLS"
    printf '%s' "$5" >"$D601_PROMPT"
    mkdir -p "$TREES_DIR/fx__repo/mutation-7"
    touch "$TREES_DIR/fx__repo/mutation-7/broken-copy"
    RUN_SESSION_RC=0
    RUN_SESSION_LOG=""
  }
  log() { :; }
  warn() { printf '%s\n' "$*" >>"$D601_WARN"; }
  duty_review
)

if d601_drive; then D601_RC=0; else D601_RC=$?; fi
D601_SESSION_LINE="$(grep -n '^SESSION review fx/repo$' "$D601_CALLS" | cut -d: -f1)"
D601_EDIT_LINE="$(grep -n '^issue edit 7 -R fx/repo --add-label state:addressing$' "$D601_CALLS" | cut -d: -f1)"
if [ -n "$D601_SESSION_LINE" ] && [ -n "$D601_EDIT_LINE" ] \
    && [ "$D601_SESSION_LINE" -lt "$D601_EDIT_LINE" ]; then
  r1=after-verdict
else
  r1=MISSING-OR-MISORDERED
fi
t addressing-wired-after-verdict after-verdict "$r1"
if [ "$D601_RC" -eq 0 ] \
    && grep -q 'could not set state:addressing (reconciler will)' "$D601_WARN"; then
  r1='best-effort'
else
  r1=GATING
fi
t addressing-write-is-best-effort best-effort "$r1"
if grep -q -- '--add-label state:building' "$D601_CALLS"; then r1=WRITES-IT; else r1=absent; fi
t addressing-never-writes-state-building absent "$r1"
t review-session-removes-its-mutation-copy gone \
  "$([ ! -e "$D601/trees/fx__repo/mutation-7" ] && printf gone || printf PRESENT)"
t completed-session-exact-head-verdict-settles \
  'fx/repo#7 2026-08-30T07:00:00Z' "$(cat "$D601/.seen-review")"

# #671: a successful model process is not a durable terminal action. The
# postcondition is an exact-head opinionated review by this identity or a
# recognized park; everything else remains owed, with local spending bounded
# to three attempts per PR/head.
D671_HEAD_A="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
D671_HEAD_B="ffffffffffffffffffffffffffffffffffffffff"

d671_verdict_result() ( # payload-kind expected-head
  local kind="$1" expected="$2" ME=fixture-reviewer
  gh() {
    case "$kind" in
      approve) jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"APPROVED"}]}}}}}' ;;
      changes) jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"CHANGES_REQUESTED"}]}}}}}' ;;
      dismissed) jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"DISMISSED"}]}}}}}' ;;
      latest-dismissed)
        # Model GitHub's server-side states filter before last:1: excluding
        # DISMISSED exposes the older approval; including it returns the newer
        # dismissal, which the positive postcondition must reject.
        if [[ "$*" == *'states:[APPROVED,CHANGES_REQUESTED,DISMISSED]'* ]]; then
          jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"DISMISSED"}]}}}}}'
        else
          jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"APPROVED"}]}}}}}'
        fi
        ;;
      none) jq -cn '{data:{repository:{pullRequest:{reviews:{nodes:[]}}}}}' ;;
      malformed) printf 'not-json\n' ;;
      error) return 1 ;;
    esac
  }
  if _review_verdict_at_head fx/repo 7 "$expected"; then
    printf 'yes:%s\n' "$REVIEW_VERDICT_POSTCONDITION"
  else
    printf 'no:%s\n' "$REVIEW_VERDICT_POSTCONDITION"
  fi
)

t review-postcondition-accepts-approval "yes:APPROVED" \
  "$(d671_verdict_result approve "$D671_HEAD_A")"
t review-postcondition-accepts-changes "yes:CHANGES_REQUESTED" \
  "$(d671_verdict_result changes "$D671_HEAD_A")"
t review-postcondition-rejects-dismissed "no:none" \
  "$(d671_verdict_result dismissed "$D671_HEAD_A")"
t review-postcondition-rejects-newer-dismissal-over-older-approval "no:none" \
  "$(d671_verdict_result latest-dismissed "$D671_HEAD_A")"
t review-postcondition-rejects-other-head "no:none" \
  "$(d671_verdict_result approve "$D671_HEAD_B")"
t review-postcondition-empty-reviews-is-no-verdict "no:none" \
  "$(d671_verdict_result none "$D671_HEAD_A")"
t review-postcondition-malformed-is-lookup-error "no:lookup-error" \
  "$(d671_verdict_result malformed "$D671_HEAD_A")"
t review-postcondition-api-error-is-lookup-error "no:lookup-error" \
  "$(d671_verdict_result error "$D671_HEAD_A")"

D671_COUNT="$TMP/review-owed-counter"
mkdir -p "$D671_COUNT"
(
  DUTY_DIR="$D671_COUNT"
  _review_owed_attempt fx/repo 7 "$D671_HEAD_A"
  _review_owed_attempt fx/repo 7 "$D671_HEAD_A"
  _review_owed_attempt fx/repo 7 "$D671_HEAD_B"
) >"$D671_COUNT/results"
t review-owed-same-head-increments $'1\n2\n1' "$(cat "$D671_COUNT/results")"
t review-owed-moved-head-discards-old-counter "fx/repo#7@$D671_HEAD_B 1" \
  "$(cat "$D671_COUNT/.review-owed")"
DUTY_DIR="$D671_COUNT" _review_owed_clear fx/repo 7
t review-owed-settle-clears-all-heads empty \
  "$([ ! -s "$D671_COUNT/.review-owed" ] && printf empty || printf PRESENT)"

printf 'fx/repo#7@%s 2\nfx/repo#8@%s 1\n' "$D671_HEAD_A" "$D671_HEAD_B" \
  >"$D671_COUNT/.review-owed"
DUTY_DIR="$D671_COUNT" _review_owed_prune_inactive 'fx/repo#8'
t review-owed-complete-sweep-prunes-ended-request "fx/repo#8@$D671_HEAD_B 1" \
  "$(cat "$D671_COUNT/.review-owed")"

# The retry ledger is replaced only after every producer and the rename
# succeeds. A partial producer must leave the original multi-PR state intact,
# and a failed rename must remove only its unpublished temporary file.
D671_TXN="$TMP/review-owed-transactional-writes"
mkdir -p "$D671_TXN"
D671_TXN_ORIGINAL="fx/repo#7@$D671_HEAD_A 2
fx/repo#8@$D671_HEAD_B 1"

printf '%s\n' "$D671_TXN_ORIGINAL" >"$D671_TXN/.review-owed"
(
  DUTY_DIR="$D671_TXN"
  awk() { printf 'partial-row\n'; return 1; }
  if _review_owed_clear fx/repo 7; then printf success; else printf failed; fi
) >"$D671_TXN/clear-result"
t review-owed-clear-writer-failure-returns-nonzero failed \
  "$(cat "$D671_TXN/clear-result")"
t review-owed-clear-writer-failure-preserves-ledger "$D671_TXN_ORIGINAL" \
  "$(cat "$D671_TXN/.review-owed")"
t review-owed-clear-writer-failure-removes-temp empty \
  "$([ -z "$(find "$D671_TXN" -maxdepth 1 -name '.review-owed.*' -print -quit)" ] && printf empty || printf PRESENT)"

printf '%s\n' "$D671_TXN_ORIGINAL" >"$D671_TXN/.review-owed"
(
  DUTY_DIR="$D671_TXN"
  awk() { printf 'partial-row\n'; return 1; }
  if _review_owed_prune_inactive 'fx/repo#8'; then printf success; else printf failed; fi
) >"$D671_TXN/prune-result"
t review-owed-prune-writer-failure-returns-nonzero failed \
  "$(cat "$D671_TXN/prune-result")"
t review-owed-prune-writer-failure-preserves-ledger "$D671_TXN_ORIGINAL" \
  "$(cat "$D671_TXN/.review-owed")"
t review-owed-prune-writer-failure-removes-temp empty \
  "$([ -z "$(find "$D671_TXN" -maxdepth 1 -name '.review-owed.*' -print -quit)" ] && printf empty || printf PRESENT)"

printf '%s\n' "$D671_TXN_ORIGINAL" >"$D671_TXN/.review-owed"
(
  DUTY_DIR="$D671_TXN"
  awk() {
    if [[ "$*" == *'-v p='* ]]; then printf 'partial-row\n'; return 1; fi
    command awk "$@"
  }
  if _review_owed_attempt fx/repo 7 "$D671_HEAD_A"; then printf success; else printf failed; fi
) >"$D671_TXN/attempt-write-result"
t review-owed-attempt-writer-failure-returns-nonzero failed \
  "$(cat "$D671_TXN/attempt-write-result")"
t review-owed-attempt-writer-failure-preserves-ledger "$D671_TXN_ORIGINAL" \
  "$(cat "$D671_TXN/.review-owed")"
t review-owed-attempt-writer-failure-removes-temp empty \
  "$([ -z "$(find "$D671_TXN" -maxdepth 1 -name '.review-owed.*' -print -quit)" ] && printf empty || printf PRESENT)"

printf '%s\n' "$D671_TXN_ORIGINAL" >"$D671_TXN/.review-owed"
(
  DUTY_DIR="$D671_TXN"
  awk() {
    if [[ "$*" == *'-v k='* ]]; then return 1; fi
    command awk "$@"
  }
  if _review_owed_attempt fx/repo 7 "$D671_HEAD_A"; then printf success; else printf failed; fi
) >"$D671_TXN/attempt-read-result"
t review-owed-attempt-count-failure-returns-nonzero failed \
  "$(cat "$D671_TXN/attempt-read-result")"
t review-owed-attempt-count-failure-preserves-ledger "$D671_TXN_ORIGINAL" \
  "$(cat "$D671_TXN/.review-owed")"

printf '%s\n' "$D671_TXN_ORIGINAL" >"$D671_TXN/.review-owed"
(
  DUTY_DIR="$D671_TXN"
  mv() { return 1; }
  if _review_owed_clear fx/repo 7; then printf success; else printf failed; fi
) >"$D671_TXN/mv-result"
t review-owed-rename-failure-returns-nonzero failed \
  "$(cat "$D671_TXN/mv-result")"
t review-owed-rename-failure-preserves-ledger "$D671_TXN_ORIGINAL" \
  "$(cat "$D671_TXN/.review-owed")"
t review-owed-rename-failure-removes-temp empty \
  "$([ -z "$(find "$D671_TXN" -maxdepth 1 -name '.review-owed.*' -print -quit)" ] && printf empty || printf PRESENT)"

d671_drive() ( # root post-mode ticks [capture] [invalid] [multi] [mutation] [ready] [lifecycle] [rerequest] [clear-failure] [writer-failure]
  local root="$1" post_mode="$2" ticks="$3" capture="${4:-}" invalid="${5:-0}" multi="${6:-0}"
  local mutation="${7:-none}" ready="${8:-0}" lifecycle="${9:-0}"
  local rerequest="${10:-0}"
  local clear_failure="${11:-0}"
  local writer_failure="${12:-0}"
  # shellcheck disable=SC2030  # fixture globals are intentionally isolated
  local DUTY_DIR="$root" WORK_DIR="$root/work" TREES_DIR="$root/trees"
  local LOG_DIR="$root/logs" CONF_DIR="$root/conf" PROMPTS_DIR="$SHARED/prompts"
  local BIN_DIR="$root/bin" REPOS_FILE="$root/repos.txt"
  local ME=fixture-reviewer MARK_REVIEWING='reviewing head'
  local TIMEOUT_REVIEW=30 AUTO_APPROVE_REREQUEST=1 LABEL_ADDRESSING=state:addressing
  local tick
  mkdir -p "$WORK_DIR" "$TREES_DIR" "$LOG_DIR"
  printf 'fx/repo\n' >"$REPOS_FILE"
  : >"$root/calls"; : >"$root/warn"; : >"$root/session-log"
  if [ "$ready" -eq 1 ]; then : >"$root/park-ready"; fi
  if [ "$post_mode" = skip ]; then
    printf 'fx/repo#7@%s 2\n' "$D671_HEAD_A" >"$root/.review-owed"
  fi
  gh() {
    printf '%s\n' "$*" >>"$root/calls"
    if [ "$1" = api ] && [[ "$2" == repos/fx/repo/pulls\?* ]]; then
      if [ "$lifecycle" -eq 1 ] && [ "$tick" -eq 2 ]; then
        printf '[]\n'
      elif [ "$multi" -eq 1 ]; then
        jq -cn --arg me "$ME" '[7,8] | map({draft:false,requested_reviewers:[{login:$me}],
          created_at:"2026-09-04T10:00:00Z",updated_at:"2026-09-04T11:00:00Z",
          number:.,user:{login:"author"}})'
      else
        jq -cn --arg me "$ME" '[{draft:false,requested_reviewers:[{login:$me}],
          created_at:"2026-09-04T10:00:00Z",updated_at:"2026-09-04T11:00:00Z",
          number:7,user:{login:"author"}}]'
      fi
      return 0
    fi
    if [ "$1" = search ]; then return 0; fi
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *'timelineItems(itemTypes:'* ]]; then
        if [ "$post_mode" = skip ]; then
          printf '%s %s 2026-09-04T10:31:00Z APPROVED 2026-09-04T10:30:00Z\n' \
            "$D671_HEAD_A" "$D671_HEAD_A"
        elif [ "$lifecycle" -eq 1 ] && [ "$tick" -ge 3 ]; then
          printf '%s %s 2026-09-04T10:31:00Z DISMISSED 2026-09-04T10:32:00Z\n' \
            "$D671_HEAD_A" "$D671_HEAD_A"
        elif [ "$rerequest" -eq 1 ]; then
          printf '%s %s 2026-09-04T10:31:00Z CHANGES_REQUESTED 2026-09-04T10:32:00Z\n' \
            "$D671_HEAD_A" "$D671_HEAD_A"
        else
          printf '%s - - - 2026-09-04T10:30:00Z\n' "$D671_HEAD_A"
        fi
      elif [[ "$*" == *'reviews(author:'* ]]; then
        [[ "$*" == *'-f me=fixture-reviewer'* ]] && printf 'POST-SCOPED-TO-ME\n' >>"$root/calls"
        case "$post_mode" in
          lifecycle)
            if [ "$tick" -eq 1 ]; then return 1; else jq -cn '{data:{repository:{pullRequest:{reviews:{nodes:[]}}}}}'; fi
            ;;
          verdict) jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"APPROVED"}]}}}}}' ;;
          mixed)
            if [[ "$*" == *'num=7'* ]]; then
              jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"APPROVED"}]}}}}}'
            else
              jq -cn '{data:{repository:{pullRequest:{reviews:{nodes:[]}}}}}'
            fi
            ;;
          dismissed) jq -cn --arg h "$D671_HEAD_A" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"DISMISSED"}]}}}}}' ;;
          wrong-head) jq -cn --arg h "$D671_HEAD_B" '{data:{repository:{pullRequest:{reviews:{nodes:[{commit:{oid:$h},state:"APPROVED"}]}}}}}' ;;
          none) jq -cn '{data:{repository:{pullRequest:{reviews:{nodes:[]}}}}}' ;;
          error) return 1 ;;
        esac
      else
        return 1
      fi
      return 0
    fi
    return 3
  }
  ensure_checkout() { mkdir -p "$2/.git"; }
  _review_check_evidence_list() { :; }
  _review_detached_run_blocks_dispatch() { return 1; }
  review_park_prune_inactive() { :; }
  review_park_inspect() {
    if [ -e "$root/park-ready" ]; then
      REVIEW_PARK_STATE=ready
      REVIEW_PARK_RESULTS='detached review completed'
      REVIEW_PARK_REASON='consuming completed detached review'
      REVIEW_PARK_DIGESTS=fixture-digest
    else
      REVIEW_PARK_STATE=none REVIEW_PARK_RESULTS="" REVIEW_PARK_REASON="" REVIEW_PARK_DIGESTS=""
    fi
  }
  review_park_capture() {
    REVIEW_PARK_CAPTURE_INVALID="$invalid"
    REVIEW_PARK_CAPTURED="$capture"
  }
  review_park_clear() { rm -f "$root/park-ready"; }
  _review_park_cleanup_runs() { :; }
  review_cleanup_mutation_copies() { :; }
  _mark_addressing() { :; }
  run_session() {
    printf 'SESSION %s %s\n%s\n%s\n' "$1" "$2" "$5" \
      'acted=yes; submit-verdict exited 1; final answer: verdict submitted successfully' \
      >>"$root/session-log"
    RUN_SESSION_RC=0
    RUN_SESSION_LOG='acted=yes; submit-verdict exited 1; final answer: verdict submitted successfully'
  }
  log() { :; }
  warn() { printf '%s\n' "$*" >>"$root/warn"; }
  case "$mutation" in
    accept-nonverdict) _review_verdict_at_head() { REVIEW_VERDICT_POSTCONDITION=mutated; return 0; } ;;
    unbounded) _review_owed_exhausted() { return 1; } ;;
    no-prune) _review_owed_prune_inactive() { :; } ;;
  esac
  if [ "$clear_failure" -eq 1 ]; then
    _review_owed_clear() { return 1; }
  fi
  if [ "$writer_failure" -eq 1 ]; then
    awk() {
      if [[ "$*" == *'-v p=fx/repo#7@'* ]]; then
        printf 'partial-row\n'
        return 1
      fi
      command awk "$@"
    }
  fi
  for ((tick=1; tick<=ticks; tick++)); do
    duty_review
    if [ -s "$root/.review-owed" ]; then
      cp "$root/.review-owed" "$root/owed-after-$tick"
    else
      : >"$root/owed-after-$tick"
    fi
  done
)

D671_NONE="$TMP/review-post-none"
d671_drive "$D671_NONE" none 4
t review-no-verdict-bounds-dispatch-at-three 3 \
  "$(grep -c '^SESSION ' "$D671_NONE/session-log")"
t review-no-verdict-third-attempt-settles 'fx/repo#7 2026-09-04T11:00:00Z' \
  "$(cat "$D671_NONE/.seen-review")"
t review-no-verdict-warns-once 1 \
  "$(grep -c "fx/repo#7 at $D671_HEAD_A still has no exact-head verdict after 3 attempts" "$D671_NONE/warn")"
t review-no-verdict-leaves-live-request-untouched 0 \
  "$(grep -Ec 'requested-reviewer|issue comment' "$D671_NONE/calls" || true)"
if grep -Fq 'acted=yes; submit-verdict exited 1; final answer: verdict submitted successfully' \
    "$D671_NONE/session-log"; then r1=covered; else r1=MISSING; fi
t review-false-submission-prose-does-not-settle-early covered "$r1"

D671_ERROR="$TMP/review-post-error"
d671_drive "$D671_ERROR" error 1
t review-post-lookup-error-leaves-seen-empty empty \
  "$([ ! -s "$D671_ERROR/.seen-review" ] && printf empty || printf PRESENT)"
t review-post-lookup-error-remains-owed "fx/repo#7@$D671_HEAD_A 1" \
  "$(cat "$D671_ERROR/.review-owed")"
t review-post-lookup-error-warns 1 \
  "$(grep -c 'post-session verdict lookup failed; request remains owed' "$D671_ERROR/warn")"

D671_SKIP="$TMP/review-covered-request-skip"
d671_drive "$D671_SKIP" skip 1
t review-pre-dispatch-covered-request-clears-spent-attempt empty \
  "$([ ! -s "$D671_SKIP/owed-after-1" ] && printf empty || printf PRESENT)"
t review-pre-dispatch-covered-request-dispatches-no-session 0 \
  "$(grep -c '^SESSION ' "$D671_SKIP/session-log" || true)"

# A verdict can really land while its post-session lookup fails. Once GitHub
# self-clears that request, a complete sweep removes its spent attempt. A later
# unchanged-head re-request over the now-dismissed verdict gets a fresh three.
D671_LIFECYCLE="$TMP/review-settle-gap-rerequest"
d671_drive "$D671_LIFECYCLE" lifecycle 6 '' 0 0 none 0 1
t review-landed-verdict-lookup-failure-spends-first-request-attempt \
  "fx/repo#7@$D671_HEAD_A 1" "$(cat "$D671_LIFECYCLE/owed-after-1")"
t review-disappeared-request-clears-spent-attempt empty \
  "$([ ! -s "$D671_LIFECYCLE/owed-after-2" ] && printf empty || printf PRESENT)"
t review-unchanged-head-rerequest-starts-fresh-attempt-budget \
  "fx/repo#7@$D671_HEAD_A 1" "$(cat "$D671_LIFECYCLE/owed-after-3")"
t review-unchanged-head-rerequest-receives-three-attempts 4 \
  "$(grep -c '^SESSION ' "$D671_LIFECYCLE/session-log")"
t review-unchanged-head-rerequest-warns-on-its-third-attempt 1 \
  "$(grep -c "fx/repo#7 at $D671_HEAD_A still has no exact-head verdict after 3 attempts" "$D671_LIFECYCLE/warn")"

D671_LIFECYCLE_MUT="$TMP/review-settle-gap-rerequest-no-prune"
d671_drive "$D671_LIFECYCLE_MUT" lifecycle 2 '' 0 0 no-prune 0 1
t review-disappeared-request-prune-mutation-reds red \
  "$([ -s "$D671_LIFECYCLE_MUT/owed-after-2" ] && printf red || printf FALSE-PASS)"

# A newer unchanged-head request over a standing CHANGES_REQUESTED is live and
# owed. Its existing attempts must survive each pre-dispatch queue decision;
# otherwise a persistent post-session lookup failure spends forever at one.
D671_LIVE_REREQUEST="$TMP/review-live-unchanged-head-rerequest"
d671_drive "$D671_LIVE_REREQUEST" error 4 '' 0 0 none 0 0 1
t review-live-unchanged-head-rerequest-bounds-dispatch-at-three 3 \
  "$(grep -c '^SESSION ' "$D671_LIVE_REREQUEST/session-log")"
t review-live-unchanged-head-rerequest-third-attempt-settles \
  'fx/repo#7 2026-09-04T11:00:00Z' "$(cat "$D671_LIVE_REREQUEST/.seen-review")"
t review-live-unchanged-head-rerequest-warns-once 1 \
  "$(grep -c "fx/repo#7 at $D671_HEAD_A still has no exact-head verdict after 3 attempts" "$D671_LIVE_REREQUEST/warn")"
t review-live-unchanged-head-rerequest-leaves-request-untouched 0 \
  "$(grep -Ec 'requested-reviewer|issue comment' "$D671_LIVE_REREQUEST/calls" || true)"

D671_READY_ONCE="$TMP/review-post-ready-once"
d671_drive "$D671_READY_ONCE" none 1 '' 0 0 none 1
t review-consumed-ready-park-without-verdict-leaves-seen-empty empty \
  "$([ ! -s "$D671_READY_ONCE/.seen-review" ] && printf empty || printf PRESENT)"
t review-consumed-ready-park-without-verdict-spends-one-attempt \
  "fx/repo#7@$D671_HEAD_A 1" "$(cat "$D671_READY_ONCE/.review-owed")"

D671_READY="$TMP/review-post-ready"
d671_drive "$D671_READY" none 4 '' 0 0 none 1
t review-consumed-ready-park-bounds-dispatch-at-three 3 \
  "$(grep -c '^SESSION ' "$D671_READY/session-log")"
t review-consumed-ready-park-third-attempt-settles 'fx/repo#7 2026-09-04T11:00:00Z' \
  "$(cat "$D671_READY/.seen-review")"
t review-consumed-ready-park-warns-once 1 \
  "$(grep -c "fx/repo#7 at $D671_HEAD_A still has no exact-head verdict after 3 attempts" "$D671_READY/warn")"

D671_VERDICT="$TMP/review-post-verdict"
d671_drive "$D671_VERDICT" verdict 2
t review-exact-head-verdict-settles-once 1 \
  "$(grep -c '^SESSION ' "$D671_VERDICT/session-log")"
t review-exact-head-verdict-clears-counter empty \
  "$([ ! -s "$D671_VERDICT/.review-owed" ] && printf empty || printf PRESENT)"

D671_PARK="$TMP/review-post-park"
d671_drive "$D671_PARK" none 1 7 0
t review-valid-park-withholds-seen-ledger empty \
  "$([ ! -s "$D671_PARK/.seen-review" ] && printf empty || printf PRESENT)"
t review-valid-park-clears-counter empty \
  "$([ ! -s "$D671_PARK/.review-owed" ] && printf empty || printf PRESENT)"

D671_INVALID="$TMP/review-post-invalid-park"
d671_drive "$D671_INVALID" verdict 1 '' 1
t review-invalid-park-withholds-seen empty \
  "$([ ! -s "$D671_INVALID/.seen-review" ] && printf empty || printf PRESENT)"
t review-invalid-park-does-not-spend-budget empty \
  "$([ ! -s "$D671_INVALID/.review-owed" ] && printf empty || printf PRESENT)"

D671_MIXED="$TMP/review-post-mixed"
d671_drive "$D671_MIXED" mixed 2 '' 0 1
t review-mixed-session-settles-only-verdict-pr 'fx/repo#7 2026-09-04T11:00:00Z' \
  "$(cat "$D671_MIXED/.seen-review")"
t review-mixed-session-keeps-failed-pr-owed "fx/repo#8@$D671_HEAD_A 2" \
  "$(cat "$D671_MIXED/.review-owed")"
t review-mixed-session-first-dispatch-covers-both 1 \
  "$(grep -c 'oldest first: 7 8\.' "$D671_MIXED/session-log")"
t review-mixed-session-retry-excludes-settled-sibling 1 \
  "$(grep -c 'oldest first: 8\.' "$D671_MIXED/session-log")"
t review-postcondition-query-is-scoped-to-me 3 \
  "$(grep -c '^POST-SCOPED-TO-ME$' "$D671_MIXED/calls")"

# The production caller runs duty_review under set -e. Retry-ledger cleanup is
# best-effort after a durable outcome: its failure must warn without aborting
# the tick, losing completed siblings, or skipping retry accounting for others.
D671_CLEAR_FAILURE="$TMP/review-owed-clear-failure"
( set -e; d671_drive "$D671_CLEAR_FAILURE" mixed 1 '' 0 1 none 0 0 0 1 )
D671_CLEAR_FAILURE_RC=$?
t review-owed-clear-failure-is-best-effort 0 "$D671_CLEAR_FAILURE_RC"
t review-owed-clear-failure-keeps-verdict-sibling-settled \
  'fx/repo#7 2026-09-04T11:00:00Z' "$(cat "$D671_CLEAR_FAILURE/.seen-review")"
t review-owed-clear-failure-keeps-missing-sibling-owed \
  "fx/repo#8@$D671_HEAD_A 1" "$(cat "$D671_CLEAR_FAILURE/.review-owed")"
t review-owed-clear-failure-warns 1 \
  "$(grep -c 'fx/repo#7 could not clear settled missing-verdict attempts' \
      "$D671_CLEAR_FAILURE/warn")"

# Exercise the same warning path through the real helper: its underlying
# writer fails after producing partial output, while the sibling attempt still
# updates from the intact ledger under the production set-e calling context.
D671_WRITER_FAILURE="$TMP/review-owed-writer-failure"
mkdir -p "$D671_WRITER_FAILURE"
printf 'fx/repo#7@%s 2\nfx/repo#8@%s 1\n' "$D671_HEAD_A" "$D671_HEAD_A" \
  >"$D671_WRITER_FAILURE/.review-owed"
( set -e; d671_drive "$D671_WRITER_FAILURE" mixed 1 '' 0 1 none 0 0 0 0 1 )
D671_WRITER_FAILURE_RC=$?
t review-owed-real-writer-failure-is-best-effort 0 "$D671_WRITER_FAILURE_RC"
t review-owed-real-writer-failure-preserves-settled-pr-attempt \
  "fx/repo#7@$D671_HEAD_A 2" \
  "$(grep '^fx/repo#7@' "$D671_WRITER_FAILURE/.review-owed")"
t review-owed-real-writer-failure-updates-missing-sibling \
  "fx/repo#8@$D671_HEAD_A 2" \
  "$(grep '^fx/repo#8@' "$D671_WRITER_FAILURE/.review-owed")"
t review-owed-real-writer-failure-warns 1 \
  "$(grep -c 'fx/repo#7 could not clear settled missing-verdict attempts' \
      "$D671_WRITER_FAILURE/warn")"

# Required mutations: each deliberately weakens one failure direction. The
# fixture reports `red` only when that weakening violates its safety property.
for D671_MUT_KIND in none dismissed wrong-head error; do
  D671_MUT="$TMP/review-mutant-$D671_MUT_KIND"
  d671_drive "$D671_MUT" "$D671_MUT_KIND" 1 '' 0 0 accept-nonverdict
  t "review-$D671_MUT_KIND-settlement-mutation-reds" red \
    "$([ -s "$D671_MUT/.seen-review" ] && printf red || printf FALSE-PASS)"
done
D671_MUT="$TMP/review-mutant-unbounded"
d671_drive "$D671_MUT" none 4 '' 0 0 unbounded
t review-unbounded-retry-mutation-reds red \
  "$([ "$(grep -c '^SESSION ' "$D671_MUT/session-log")" -eq 4 ] \
      && [ ! -s "$D671_MUT/.seen-review" ] && printf red || printf FALSE-PASS)"

# #605: repo commands run in the detached checkout, never its worktree parent.
# Drive the real prompt render above so the engine-to-prompt contract is pinned,
# then exercise box's repo-wide `bin/* **/*.sh` shape with a mutation sibling.
D605_PARENT="$D601/trees/fx__repo"
D605_CHECKOUT="$D605_PARENT/review-7"
# shellcheck disable=SC2016  # prompt shell variables are matched literally
if grep -Fq "review_checkout=\"$D605_PARENT/review-<N>\"" "$D601_PROMPT" \
    && grep -Fq 'Run the whole review from the checkout (`cd "$review_checkout"`)' "$D601_PROMPT" \
    && grep -Fq "\`$D605_PARENT\` is only the parent" "$D601_PROMPT" \
    && grep -Fq 'it is not a checkout, and no repository command runs there' "$D601_PROMPT"; then
  r1=checkout
else
  r1=CONTAINER
fi
t review-prompt-runs-repo-commands-in-checkout checkout "$r1"

D605="$TMP/repo-command-checkout"
mkdir -p "$D605/repo/bin" "$D605/repo/scripts" "$D605_PARENT"
git -C "$D605/repo" init -q -b main
git -C "$D605/repo" config user.email fixture@example.com
git -C "$D605/repo" config user.name fixture
printf '#!/usr/bin/env bash\n' >"$D605/repo/bin/box"
printf '#!/usr/bin/env bash\n' >"$D605/repo/scripts/check.sh"
git -C "$D605/repo" add bin/box scripts/check.sh
git -C "$D605/repo" commit -qm seed
git -C "$D605/repo" worktree add --detach "$D605_CHECKOUT" HEAD >/dev/null 2>&1
mkdir -p "$D605_PARENT/mutation-6/bin" "$D605_PARENT/mutation-6/scripts"
printf '#!/usr/bin/env bash\nexit 99\n' >"$D605_PARENT/mutation-6/bin/box"
printf '#!/usr/bin/env bash\nexit 99\n' >"$D605_PARENT/mutation-6/scripts/broken.sh"
D605_GLOB="$({
  cd "$D605_CHECKOUT" || exit
  shopt -s globstar dotglob
  files=(bin/* **/*.sh)
  printf '%s\n' "${files[@]}" | sort -u
})"
D605_CI_SET="$({
  cd "$D605_CHECKOUT" || exit
  printf '%s\n' bin/*
  git ls-files '*.sh'
} | sort -u)"
t review-checkout-glob-matches-ci "$D605_CI_SET" "$D605_GLOB"
if git -C "$D605_CHECKOUT" ls-files >/dev/null 2>&1; then r1=worktree; else r1=NOT-A-REPO; fi
t review-checkout-git-ls-files-succeeds worktree "$r1"
if grep -Fq mutation- <<<"$D605_GLOB"; then r1=LEAKED; else r1=excluded; fi
t review-checkout-glob-excludes-mutation-sibling excluded "$r1"

# #606: mutation copies are throwaway probe scaffolding. They are removed by
# the engine once no detached command for that review remains live; review
# worktrees and verdict files beside them are records with separate lifecycles.
mkdir -p "$D605_PARENT/mutation-7/nested" "$D605_PARENT/review-8"
touch "$D605_PARENT/mutation-7/nested/broken" \
  "$D605_PARENT/review-8/keep" "$D605_PARENT/verdict-8-deadbeef.md"
review_cleanup_mutation_copies "$D605_PARENT" fixture/repo >/dev/null
t review-mutation-copy-removed-at-session-end gone \
  "$([ ! -e "$D605_PARENT/mutation-6" ] && [ ! -e "$D605_PARENT/mutation-7" ] && printf gone || printf PRESENT)"
t review-mutation-cleanup-preserves-review-worktree present \
  "$([ -e "$D605_PARENT/review-8/keep" ] && printf present || printf MISSING)"
t review-mutation-cleanup-preserves-verdict-file present \
  "$([ -e "$D605_PARENT/verdict-8-deadbeef.md" ] && printf present || printf MISSING)"

# A parked mutation probe still owns its copy after the launching session
# returns. The same helper removes it on the first tick after the run completes.
D606_LIVE_HEAD="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
mkdir -p "$D605_PARENT/mutation-9"
touch "$D605_PARENT/mutation-9/broken-copy"
(
  cd "$D605_PARENT/mutation-9" || exit
  run_detached fixture/repo 9 "$D606_LIVE_HEAD" -- \
    bash -c 'sleep 1; test -f broken-copy'
) >"$D605_PARENT/mutation-9.digest"
D606_LIVE_DIGEST="$(cat "$D605_PARENT/mutation-9.digest")"
D606_LIVE_OUT="$(review_cleanup_mutation_copies "$D605_PARENT" fixture/repo)"
t review-mutation-live-run-preserves-copy present \
  "$([ -e "$D605_PARENT/mutation-9/broken-copy" ] && printf present || printf MISSING)"
t review-mutation-live-run-logs-protector 1 \
  "$(grep -cF "protected by active detached run fixture/repo#9@$D606_LIVE_HEAD" <<<"$D606_LIVE_OUT")"
for _ in 1 2 3 4 5; do
  detached_run_read fixture/repo 9 "$D606_LIVE_HEAD" "$D606_LIVE_DIGEST" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 1
done
t review-mutation-live-run-completes complete "$DETACHED_RUN_STATE"
review_cleanup_mutation_copies "$D605_PARENT" fixture/repo >/dev/null
t review-mutation-completed-run-removes-copy gone \
  "$([ ! -e "$D605_PARENT/mutation-9" ] && printf gone || printf PRESENT)"

# #597: a killed review never reaches its prompt-owned cleanup, so the next
# tick reclaims detached worktrees before dispatch. A deliberately misleading
# base-* name proves detached HEAD — not naming convention — is the boundary;
# the branch-holding sibling is builder state and must survive.
RW="$TMP/reclaim-worktrees"
mkdir -p "$RW/work/repo" "$RW/trees/repo"
git -C "$RW/work/repo" init -q -b main
git -C "$RW/work/repo" config user.email fixture@example.com
git -C "$RW/work/repo" config user.name fixture
git -C "$RW/work/repo" remote add origin https://github.com/fixture/repo.git
touch "$RW/work/repo/seed"
git -C "$RW/work/repo" add seed
git -C "$RW/work/repo" commit -qm seed
RW_HEAD="$(git -C "$RW/work/repo" rev-parse HEAD)"
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/base-1" HEAD >/dev/null 2>&1
touch "$RW/trees/repo/base-1/uncommitted"
# Reproduce the incident's retry collision before the reclaim resolves it.
if git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/base-1" HEAD \
    >"$RW/collision.out" 2>&1; then
  RW_COLLISION_RC=0
else
  RW_COLLISION_RC=$?
fi
t review-reclaim-fixture-reproduces-collision nonzero \
  "$([ "$RW_COLLISION_RC" -ne 0 ] && printf nonzero || printf ZERO)"
case "$(cat "$RW/collision.out")" in
  *"already exists"*) RW_COLLISION_MSG=named ;;
  *) RW_COLLISION_MSG=MISSING ;;
esac
t review-reclaim-fixture-names-existing-path named "$RW_COLLISION_MSG"
git -C "$RW/work/repo" worktree add -b build/1 "$RW/trees/repo/build-1" HEAD >/dev/null 2>&1
# shellcheck disable=SC2031  # the entrypoint fixture's subshell cannot change this caller
RW_OLD_TREES="$TREES_DIR"
TREES_DIR="$RW/trees"
RW_OUT="$(reclaim_detached_review_worktrees)"
TREES_DIR="$RW_OLD_TREES"
# D3 amended (#606): dirty is preserved by MOVING it off the path, never by
# being left on it. The work survives; the path it was occupying does not.
RW_KEPT_BASE="$RW/trees/repo/kept-base-1-${RW_HEAD:0:7}"
t review-reclaim-dirty-auxiliary-survives present \
  "$([ -e "$RW_KEPT_BASE/uncommitted" ] && printf present || printf MISSING)"
t review-reclaim-dirty-auxiliary-warning-names-both-paths 1 \
  "$(grep -cF "dirty detached worktree $RW/trees/repo/base-1 preserved as $RW_KEPT_BASE" <<<"$RW_OUT")"
t review-reclaim-dirty-auxiliary-frees-its-path gone \
  "$([ ! -e "$RW/trees/repo/base-1" ] && printf gone || printf PRESENT)"
t review-reclaim-preserves-branch present "$([ -d "$RW/trees/repo/build-1" ] && printf present || printf MISSING)"
# A kept-* tree is an ordinary candidate on the next tick: once its dirt is
# gone the ordinary rule reclaims it, which is what bounds this instead of
# making it a second accumulation.
rm -f "$RW_KEPT_BASE/uncommitted"
TREES_DIR="$RW/trees"
RW_CLEAN_OUT="$(reclaim_detached_review_worktrees)"
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-clean-kept-tree-is-removed gone \
  "$([ ! -e "$RW_KEPT_BASE" ] && printf gone || printf PRESENT)"
t review-reclaim-logs-path-and-head 1 \
  "$(grep -cF "review: reclaimed detached worktree $RW_KEPT_BASE at $RW_HEAD (0 modified, 0 untracked)" <<<"$RW_CLEAN_OUT")"
TREES_DIR="$RW/trees"
RW_QUIET="$(reclaim_detached_review_worktrees)"
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-empty-is-quiet "" "$RW_QUIET"
t review-reclaim-noop-preserves-branch present \
  "$([ -d "$RW/trees/repo/build-1" ] && printf present || printf MISSING)"

# D1 amended by triage 2026-09-02 (#606): the PR's state is NO PART of the
# predicate, so a numbered review worktree is reclaimed on #597's rule alone.
# The `gh` shim below still answers exactly as the retired gate's queries did —
# review-41's PR is OPEN, review-42's history is all CLOSED — precisely so that
# a reinstated gate would preserve review-41 and this fixture would red. Under
# the amended rule both go, and the shim is never reached at all: an open PR on
# the review side does not mean "still in use", it means "this PR will be
# reviewed again", which is exactly when the fixed review-<N> path must be free.
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-41" "$RW_HEAD" >/dev/null 2>&1
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-42" "$RW_HEAD" >/dev/null 2>&1
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-43" "$RW_HEAD" >/dev/null 2>&1
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-44" "$RW_HEAD" >/dev/null 2>&1
# review-43 carries both kinds of dirt, and its exact bytes are recorded so the
# move can be proven lossless rather than merely survivable.
printf 'unsaved analysis\n' >"$RW/trees/repo/review-43/uncommitted"
printf 'modified seed\n' >"$RW/trees/repo/review-43/seed"
RW_D43_PORCELAIN="$(git -C "$RW/trees/repo/review-43" status --porcelain --untracked-files=all)"
RW_D43_BYTES="$(cat "$RW/trees/repo/review-43/uncommitted" "$RW/trees/repo/review-43/seed")"
# review-44 is dirty AND locked, which is how the move is made to fail for real
# rather than by stubbing: `git worktree move` refuses a locked working tree.
printf 'unsaved too\n' >"$RW/trees/repo/review-44/uncommitted"
git -C "$RW/work/repo" worktree lock "$RW/trees/repo/review-44" >/dev/null 2>&1
# D4: a verdict file sits beside the trees and is a record, not scratch.
printf 'verdict\n' >"$RW/trees/repo/verdict-41-deadbeef.md"
RW_GH_CALLS="$RW/gh-calls"
: >"$RW_GH_CALLS"
# The shim is reached only through the library under test, which shellcheck
# cannot see; under 0.10.0 that reads as dead code and SC2317 is info-level,
# which ci-shell's unfiltered `shellcheck -x` treats as a failure.
# shellcheck disable=SC2317
gh() {
  printf '%s\n' "$*" >>"$RW_GH_CALLS"
  if [ "$1" = api ] && [[ "$2" == repos/fixture/repo/pulls/* ]]; then
    case "${2##*/}" in
      41|42|43|44) printf 'fork-a\tbuild/shared\n' ;;
    esac
    return 0
  fi
  if [ "$1 $2 $3" = "api --method GET" ]; then
    case "$*" in
      *'-f head=fork-a:build/shared'*) printf 'closed\nopen\n' ;;
    esac
    return 0
  fi
  return 1
}
TREES_DIR="$RW/trees"
RW_PR_OUT="$(reclaim_detached_review_worktrees 2>&1)"
TREES_DIR="$RW_OLD_TREES"
unset -f gh
# The retired criterion's replacement: the reclaim reads no PR history at all.
t review-reclaim-makes-no-gh-call 0 "$(wc -l <"$RW_GH_CALLS" | tr -d ' ')"
t review-clean-worktree-on-open-pr-is-removed gone \
  "$([ ! -e "$RW/trees/repo/review-41" ] && printf gone || printf PRESENT)"
t review-clean-worktree-on-closed-pr-is-removed gone \
  "$([ ! -e "$RW/trees/repo/review-42" ] && printf gone || printf PRESENT)"
# D3 amended: the dirt survives byte-identical at the sibling path, and the
# fixed path it was occupying is free.
RW_KEPT_43="$RW/trees/repo/kept-review-43-${RW_HEAD:0:7}"
t review-dirty-worktree-preserved-at-sibling present \
  "$([ -e "$RW_KEPT_43/uncommitted" ] && printf present || printf MISSING)"
t review-dirty-worktree-dirt-is-byte-identical "$RW_D43_BYTES" \
  "$(cat "$RW_KEPT_43/uncommitted" "$RW_KEPT_43/seed" 2>/dev/null)"
t review-dirty-worktree-porcelain-is-unchanged "$RW_D43_PORCELAIN" \
  "$(git -C "$RW_KEPT_43" status --porcelain --untracked-files=all 2>/dev/null)"
t review-dirty-worktree-warning-names-both-paths 1 \
  "$(grep -cF "dirty detached worktree $RW/trees/repo/review-43 preserved as $RW_KEPT_43" <<<"$RW_PR_OUT")"
t review-dirty-worktree-warns-exactly-once 1 \
  "$(grep -cF "$RW/trees/repo/review-43" <<<"$RW_PR_OUT")"
# The added criterion (D1 + D3): #597's collision does not reproduce. This is
# the real `git worktree add --detach` the prompt tells a retrying review to
# run, not a reasoned claim about the path being free.
if git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-43" "$RW_HEAD" \
    >"$RW/retry.out" 2>&1; then
  RW_RETRY=succeeded
else
  RW_RETRY="FAILED: $(cat "$RW/retry.out")"
fi
t review-killed-dirty-review-retry-succeeds succeeded "$RW_RETRY"
git -C "$RW/work/repo" worktree remove --force "$RW/trees/repo/review-43" >/dev/null 2>&1
# The failed-move path: nothing dirty is deleted there either, the tree stays
# exactly where it was, and the warning says so.
t review-dirty-worktree-failed-move-stays-put present \
  "$([ -e "$RW/trees/repo/review-44/uncommitted" ] && printf present || printf MISSING)"
t review-dirty-worktree-failed-move-creates-no-sibling absent \
  "$([ ! -e "$RW/trees/repo/kept-review-44-${RW_HEAD:0:7}" ] && printf absent || printf PRESENT)"
t review-dirty-worktree-failed-move-warning-says-so 1 \
  "$(grep -cF "dirty detached worktree $RW/trees/repo/review-44 could not be preserved as $RW/trees/repo/kept-review-44-${RW_HEAD:0:7}; left exactly where it is" <<<"$RW_PR_OUT")"
# D4 on the reclaim path specifically: verdict records are not swept.
t review-reclaim-preserves-verdict-file present \
  "$([ -e "$RW/trees/repo/verdict-41-deadbeef.md" ] && printf present || printf MISSING)"
# A kept-* tree is never moved twice: while dirty it is preserved where it
# stands, which is what stops the sibling names accreting one per tick.
TREES_DIR="$RW/trees"
RW_KEPT_OUT="$(reclaim_detached_review_worktrees 2>&1)"
TREES_DIR="$RW_OLD_TREES"
t review-kept-tree-is-not-moved-twice present \
  "$([ -e "$RW_KEPT_43/uncommitted" ] && printf present || printf MISSING)"
t review-kept-tree-no-second-generation absent \
  "$([ -z "$(find "$RW/trees/repo" -maxdepth 1 -name 'kept-kept-*' -print -quit)" ] && printf absent || printf PRESENT)"
t review-kept-tree-preserved-where-it-stands 1 \
  "$(grep -cF "dirty detached worktree $RW_KEPT_43 is preserved where it stands" <<<"$RW_KEPT_OUT")"

# Round 1 (codex-bot-andresmgsl, kimi-bot-andresmgsl): a DANGLING SYMLINK at the
# unsuffixed destination is the input that defeats a `-e`-only suffix loop. `-e`
# resolves the link and so reads the name as free; the move then fails on a name
# that is in fact taken, and the fail-safe branch leaves the dirty tree on the
# fixed review-<N> path — #597 reproduced through the one case the suffix rule
# exists to survive. Occupied is a property of the entry, not of what it
# resolves to, so the loop must take the suffix here.
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-45" "$RW_HEAD" >/dev/null 2>&1
printf 'unsaved through a symlink\n' >"$RW/trees/repo/review-45/uncommitted"
RW_D45_BYTES="$(cat "$RW/trees/repo/review-45/uncommitted")"
RW_KEPT_45="$RW/trees/repo/kept-review-45-${RW_HEAD:0:7}"
ln -s "$RW/no-such-target" "$RW_KEPT_45"
t review-dangling-symlink-fixture-is-dangling dangling \
  "$([ -L "$RW_KEPT_45" ] && [ ! -e "$RW_KEPT_45" ] && printf dangling || printf NOT-DANGLING)"
TREES_DIR="$RW/trees"
RW_LINK_OUT="$(reclaim_detached_review_worktrees 2>&1)"
TREES_DIR="$RW_OLD_TREES"
t review-dangling-symlink-target-takes-suffix present \
  "$([ -e "$RW_KEPT_45-2/uncommitted" ] && printf present || printf MISSING)"
t review-dangling-symlink-dirt-is-byte-identical "$RW_D45_BYTES" \
  "$(cat "$RW_KEPT_45-2/uncommitted" 2>/dev/null)"
t review-dangling-symlink-warning-names-both-paths 1 \
  "$(grep -cF "dirty detached worktree $RW/trees/repo/review-45 preserved as $RW_KEPT_45-2" <<<"$RW_LINK_OUT")"
# The symlink is somebody else's entry: the walk neither follows it nor removes it.
t review-dangling-symlink-is-left-untouched dangling \
  "$([ -L "$RW_KEPT_45" ] && [ ! -e "$RW_KEPT_45" ] && printf dangling || printf DISTURBED)"
t review-dangling-symlink-no-third-generation absent \
  "$([ ! -e "$RW_KEPT_45-3" ] && printf absent || printf PRESENT)"
# The point of all of it: the fixed retry path is free, proved by running the
# `git worktree add --detach` the prompt tells a retrying review to run.
if git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-45" "$RW_HEAD" \
    >"$RW/retry-link.out" 2>&1; then
  RW_LINK_RETRY=succeeded
else
  RW_LINK_RETRY="FAILED: $(cat "$RW/retry-link.out")"
fi
t review-dangling-symlink-retry-succeeds succeeded "$RW_LINK_RETRY"
# Leave the tree as this block found it: the preserved sibling is a real
# worktree and would otherwise be one more protected candidate in the counts
# the later live-run fixtures assert.
git -C "$RW/work/repo" worktree remove --force "$RW/trees/repo/review-45" >/dev/null 2>&1
git -C "$RW/work/repo" worktree remove --force "$RW_KEPT_45-2" >/dev/null 2>&1
rm -f "$RW_KEPT_45"

# Ignored build products are reproducible; tracked files, ordinary untracked
# evidence, and verdict records are not. The porcelain snapshot must therefore
# be byte-identical before and after cleanup.
RBO="$TMP/review-build-output"
RBO_WORK="$RBO/work"
RBO_CLONE="$RBO_WORK/fixture__repo-review"
mkdir -p "$RBO_CLONE"
git -C "$RBO_CLONE" init -q -b main
git -C "$RBO_CLONE" config user.email fixture@example.com
git -C "$RBO_CLONE" config user.name fixture
git -C "$RBO_CLONE" remote add origin https://github.com/fixture/output.git
mkdir -p "$RBO_CLONE/dist"
printf 'tracked\n' >"$RBO_CLONE/source.txt"
printf 'tracked manifest\n' >"$RBO_CLONE/dist/manifest.txt"
git -C "$RBO_CLONE" add source.txt dist/manifest.txt
git -C "$RBO_CLONE" commit -qm seed
printf 'node_modules/\n.next/\ntest-results/\ndist/generated/\n' >"$RBO_CLONE/.gitignore"
git -C "$RBO_CLONE" add .gitignore
git -C "$RBO_CLONE" commit -qm ignores
mkdir -p "$RBO_CLONE/node_modules/pkg" "$RBO_CLONE/.next/cache" \
  "$RBO_CLONE/test-results/run" "$RBO_CLONE/dist/generated"
touch "$RBO_CLONE/node_modules/pkg/index.js" "$RBO_CLONE/.next/cache/data" \
  "$RBO_CLONE/test-results/run/result" "$RBO_CLONE/dist/generated/app.js" \
  "$RBO_CLONE/review-188-verdict.md"
printf 'modified\n' >"$RBO_CLONE/source.txt"
RBO_BEFORE="$(git -C "$RBO_CLONE" status --porcelain)"
# shellcheck disable=SC2031  # the entrypoint fixture's subshell cannot change this caller
RBO_OLD_WORK="$WORK_DIR"
WORK_DIR="$RBO_WORK"
RBO_HEAD="$(git -C "$RBO_CLONE" rev-parse HEAD)"
RBO_DIGEST="$(run_detached fixture/output 8 "$RBO_HEAD" -- sleep 1)"
RBO_LIVE_OUT="$(review_cleanup_stale_build_outputs)"
t review-build-output-live-run-preserves-ignored-products present \
  "$([ -e "$RBO_CLONE/node_modules/pkg/index.js" ] \
      && [ -e "$RBO_CLONE/test-results/run/result" ] \
      && printf present || printf MISSING)"
t review-build-output-live-run-logs-protector 1 \
  "$(grep -cF "protected by active detached run fixture/output#8@$RBO_HEAD" <<<"$RBO_LIVE_OUT")"
for _ in 1 2 3 4 5; do
  detached_run_read fixture/output 8 "$RBO_HEAD" "$RBO_DIGEST" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 1
done
t review-build-output-live-run-completes complete "$DETACHED_RUN_STATE"
review_cleanup_stale_build_outputs >/dev/null
WORK_DIR="$RBO_OLD_WORK"
RBO_AFTER="$(git -C "$RBO_CLONE" status --porcelain)"
t review-build-output-cleanup-preserves-porcelain "$RBO_BEFORE" "$RBO_AFTER"
t review-build-output-cleanup-removes-ignored-products gone \
  "$([ ! -e "$RBO_CLONE/node_modules" ] && [ ! -e "$RBO_CLONE/.next" ] \
      && [ ! -e "$RBO_CLONE/test-results" ] && [ ! -e "$RBO_CLONE/dist/generated" ] \
      && printf gone || printf PRESENT)"
t review-build-output-cleanup-preserves-tracked-file present \
  "$([ -e "$RBO_CLONE/dist/manifest.txt" ] && printf present || printf MISSING)"
t review-build-output-cleanup-preserves-verdict-file present \
  "$([ -e "$RBO_CLONE/review-188-verdict.md" ] && printf present || printf MISSING)"

# A parked review command deliberately outlives its launching tick. Reclaim
# protects that command's worktree but still removes unrelated stale review
# trees, so another PR can dispatch without colliding on its path.
git -C "$RW/work/repo" commit --allow-empty -qm live-head
RW_LIVE_HEAD="$(git -C "$RW/work/repo" rev-parse HEAD)"
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-live" "$RW_LIVE_HEAD" >/dev/null 2>&1
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-stale" "$RW_LIVE_HEAD" >/dev/null 2>&1
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/base-aux" "$RW_HEAD" >/dev/null 2>&1
(
  cd "$RW/work/repo" || exit
  RW_LIVE_DIGEST="$(run_detached fixture/repo 7 "$RW_LIVE_HEAD" -- \
    bash -c "sleep 1; [ -d \"\$1\" ] && [ -d \"\$2\" ] && : > \"\$1/review-finished\"" \
      _ "$RW/trees/repo/review-live" "$RW/trees/repo/base-aux")"
  printf '%s' "$RW_LIVE_DIGEST" >"$RW/live.digest"
)
TREES_DIR="$RW/trees"
RW_LIVE_OUT="$(reclaim_detached_review_worktrees)"
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-active-run-logs-protector 5 \
  "$(grep -cF "protected by active detached run fixture/repo#7@$RW_LIVE_HEAD" <<<"$RW_LIVE_OUT")"
t review-reclaim-active-run-preserves-worktree present \
  "$([ -d "$RW/trees/repo/review-live" ] && printf present || printf MISSING)"
t review-reclaim-same-head-stale-conservatively-preserved present \
  "$([ -d "$RW/trees/repo/review-stale" ] && printf present || printf MISSING)"
t review-reclaim-active-run-preserves-auxiliary-base-head present \
  "$([ -d "$RW/trees/repo/base-aux" ] && printf present || printf MISSING)"
if _review_detached_run_blocks_dispatch fixture/repo; then
  RW_SAME_HEAD_DECISION=suppressed
else
  RW_SAME_HEAD_DECISION=DISPATCHED
fi
t review-reclaim-same-head-next-dispatch-suppressed suppressed "$RW_SAME_HEAD_DECISION"
t review-reclaim-same-head-suppression-names-protector "fixture/repo#7@$RW_LIVE_HEAD" \
  "$REVIEW_DETACHED_RUN_SUBJECT"
if _review_detached_run_blocks_dispatch fixture/repo; then
  RW_DIFFERENT_HEAD_DECISION=suppressed
else
  RW_DIFFERENT_HEAD_DECISION=DISPATCHED
fi
t review-reclaim-different-head-next-dispatch-suppressed suppressed \
  "$RW_DIFFERENT_HEAD_DECISION"
RW_LIVE_DIGEST="$(cat "$RW/live.digest")"
for _ in 1 2 3 4 5; do
  detached_run_read fixture/repo 7 "$RW_LIVE_HEAD" "$RW_LIVE_DIGEST" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 1
done
t review-reclaim-fixture-run-completes complete "$DETACHED_RUN_STATE"
TREES_DIR="$RW/trees"
reclaim_detached_review_worktrees >/dev/null
TREES_DIR="$RW_OLD_TREES"
# The killed review's own tree is dirty, so it is preserved at the sibling and
# its fixed path is freed — the whole point of D3's amendment.
RW_KEPT_LIVE="$RW/trees/repo/kept-review-live-${RW_LIVE_HEAD:0:7}"
t review-reclaim-ended-run-dirty-tree-preserved present \
  "$([ -e "$RW_KEPT_LIVE/review-finished" ] && printf present || printf MISSING)"
t review-reclaim-ended-run-dirty-tree-frees-its-path gone \
  "$([ ! -e "$RW/trees/repo/review-live" ] && printf gone || printf PRESENT)"
t review-reclaim-ended-run-stale-tree-removed gone \
  "$([ ! -e "$RW/trees/repo/review-stale" ] && printf gone || printf PRESENT)"
t review-reclaim-ended-run-auxiliary-tree-removed gone \
  "$([ ! -e "$RW/trees/repo/base-aux" ] && printf gone || printf PRESENT)"
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/base-aux" "$RW_HEAD" >/dev/null 2>&1
t review-reclaim-ended-run-clears-auxiliary-path recreated \
  "$([ -d "$RW/trees/repo/base-aux" ] && printf recreated || printf COLLISION)"
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/review-stale" "$RW_LIVE_HEAD" >/dev/null 2>&1
t review-reclaim-ended-run-clears-next-dispatch-path recreated \
  "$([ -d "$RW/trees/repo/review-stale" ] && printf recreated || printf COLLISION)"

# Logical TREES_DIR paths are normalized before comparing them with Git's
# physical toplevel. A symlinked trees root must not silently disable reclaim.
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/symlinked" "$RW_HEAD" >/dev/null 2>&1
ln -s "$RW/trees" "$RW/trees-link"
TREES_DIR="$RW/trees-link"
RW_SYMLINK_OUT="$(reclaim_detached_review_worktrees)"
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-symlinked-trees-removes-detached gone \
  "$([ ! -e "$RW/trees/repo/symlinked" ] && printf gone || printf PRESENT)"
t review-reclaim-symlinked-trees-logs-physical-path 1 \
  "$(grep -cF "review: reclaimed detached worktree $RW/trees/repo/symlinked at $RW_HEAD" <<<"$RW_SYMLINK_OUT")"

# Git deliberately detaches a builder worktree during a conflicted rebase.
# Reclaim must leave both the operation and uncommitted material intact.
printf 'main\n' >"$RW/work/repo/conflict"
git -C "$RW/work/repo" add conflict
git -C "$RW/work/repo" commit -qm main-side
git -C "$RW/work/repo" worktree add -b build/9 "$RW/trees/repo/build-9" HEAD~1 >/dev/null 2>&1
printf 'branch\n' >"$RW/trees/repo/build-9/conflict"
git -C "$RW/trees/repo/build-9" add conflict
git -C "$RW/trees/repo/build-9" commit -qm branch-side
touch "$RW/trees/repo/build-9/notes.txt"
git -C "$RW/trees/repo/build-9" rebase main >/dev/null 2>&1 || true
t review-reclaim-rebase-fixture-is-detached detached \
  "$(git -C "$RW/trees/repo/build-9" symbolic-ref -q HEAD >/dev/null 2>&1 && printf BRANCH || printf detached)"
TREES_DIR="$RW/trees"
reclaim_detached_review_worktrees >/dev/null
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-preserves-rebase-worktree present \
  "$([ -d "$RW/trees/repo/build-9" ] && printf present || printf MISSING)"
t review-reclaim-preserves-rebase-dirt present \
  "$([ -f "$RW/trees/repo/build-9/notes.txt" ] && printf present || printf MISSING)"
git -C "$RW/trees/repo/build-9" rebase --abort >/dev/null 2>&1

# Bisect is another detached builder operation. The operation marker itself is
# the boundary; a synthetic marker keeps this fixture independent of how many
# commits a particular Git version needs before it resolves a bisect.
git -C "$RW/work/repo" worktree add --detach "$RW/trees/repo/build-bisect" HEAD >/dev/null 2>&1
RW_BISECT_GIT_DIR="$(git -C "$RW/trees/repo/build-bisect" rev-parse --absolute-git-dir)"
touch "$RW_BISECT_GIT_DIR/BISECT_LOG"
TREES_DIR="$RW/trees"
reclaim_detached_review_worktrees >/dev/null
TREES_DIR="$RW_OLD_TREES"
t review-reclaim-preserves-bisect-worktree present \
  "$([ -d "$RW/trees/repo/build-bisect" ] && printf present || printf MISSING)"
rm -f "$RW_BISECT_GIT_DIR/BISECT_LOG"

# A main clone reports `.git` as its common dir. Resolution is rooted at the
# candidate, never at the duty process cwd.
mkdir -p "$RW/nested/repo"
git -C "$RW/nested/repo" init -q
t review-reclaim-common-dir-is-absolute "$RW/nested/repo/.git" \
  "$(_review_common_dir "$RW/nested/repo")"

# MUST FAIL: replace detached-HEAD discrimination with a review-* name check.
# The auxiliary base-* fixture then leaks, which is the incident's exact
# counterexample to a naming convention repair.
RW_MUT="$TMP/reclaim-name-mutant.sh"
# shellcheck disable=SC2016  # deliberate literal mutation expression
sed 's@if git -C "$candidate" symbolic-ref -q HEAD >/dev/null 2>&1; then@if [[ "${candidate##*/}" != review-* ]]; then@' \
  "$SHARED/lib/duty-review.sh" >"$RW_MUT"
mkdir -p "$RW/mut-work" "$RW/mut-trees/repo"
git -C "$RW/mut-work" init -q
git -C "$RW/mut-work" config user.email fixture@example.com
git -C "$RW/mut-work" config user.name fixture
touch "$RW/mut-work/seed"
git -C "$RW/mut-work" add seed
git -C "$RW/mut-work" commit -qm seed
git -C "$RW/mut-work" worktree add --detach "$RW/mut-trees/repo/base-2" HEAD >/dev/null 2>&1
(
  # shellcheck disable=SC1090  # deliberate mutation fixture
  source "$RW_MUT"
  TREES_DIR="$RW/mut-trees"
  reclaim_detached_review_worktrees >/dev/null
)
t review-reclaim-name-mutation-reds red \
  "$([ -d "$RW/mut-trees/repo/base-2" ] && printf red || printf FALSE-PASS)"

# Drive duty.sh with controlled lane stubs. Recording the executed reclaim and
# first dispatch makes a dead, missing, or moved call fail even when the same
# source text remains elsewhere in the script.
RW_TICK_DUTY="$RW/tick-duty"
RW_TICK_CALLS="$RW/tick-calls"
mkdir -p "$RW_TICK_DUTY/lib" "$RW_TICK_DUTY/work" \
  "$RW_TICK_DUTY/trees" "$RW_TICK_DUTY/logs"
cat >"$RW_TICK_DUTY/lib/common.sh" <<'RWCOMMON'
WORK_DIR="$DUTY_DIR/work"
TREES_DIR="$DUTY_DIR/trees"
LOG_DIR="$DUTY_DIR/logs"
load_conf() { :; }
log() { :; }
warn() { :; }
alert() { :; }
report_profile_classifier_gaps() { :; }
session_reconcile_orphans() { printf 'ORPHAN\n' >>"$RW_TICK_CALLS"; }
bot_cli_probe() { return 0; }
gh_identity() { printf 'fixture-bot\n'; }
check_vendor_credential() { :; }
converge_git_identity() { return 0; }
has_role() { [ "$1" = reviewer ]; }
idle_ticks_account() { :; }
RWCOMMON
cat >"$RW_TICK_DUTY/lib/duty-review.sh" <<'RWREVIEW'
reclaim_detached_review_worktrees() { printf 'RECLAIM\n' >>"$RW_TICK_CALLS"; }
duty_review() { printf 'REVIEW\n' >>"$RW_TICK_CALLS"; }
RWREVIEW
cat >"$RW_TICK_DUTY/lib/duty-attention.sh" <<'RWATTENTION'
duty_attention() { printf 'ATTENTION\n' >>"$RW_TICK_CALLS"; }
RWATTENTION
cat >"$RW_TICK_DUTY/lib/duty-builder.sh" <<'RWBUILDER'
duty_builder() { printf 'BUILDER\n' >>"$RW_TICK_CALLS"; }
RWBUILDER
cat >"$RW_TICK_DUTY/lib/duty-triage.sh" <<'RWTRIAGE'
duty_triage() { printf 'TRIAGE\n' >>"$RW_TICK_CALLS"; }
RWTRIAGE
cat >"$RW_TICK_DUTY/lib/duty-reaper.sh" <<'RWREAPER'
reaper_interval() { REAPER_INTERVAL_SECONDS=9999999999; }
duty_reaper() { printf 'REAPER\n' >>"$RW_TICK_CALLS"; }
RWREAPER
cat /proc/sys/kernel/random/boot_id >"$RW_TICK_DUTY/.boot-id"

rw_tick_reclaim_order() { # <duty-script>
  : >"$RW_TICK_CALLS"
  DUTY_LOCKED=1 DUTY_SNAPSHOT="$RW/tick-snapshot-marker" \
    DUTY_DIR="$RW_TICK_DUTY" RW_TICK_CALLS="$RW_TICK_CALLS" \
    bash "$1" >/dev/null 2>&1 || return 1
  awk '/^RECLAIM$/ { if (!rec) rec = NR }
       /^(ATTENTION|TRIAGE|REVIEW|BUILDER)$/ { if (!disp) disp = NR }
       END { print (rec && disp && rec < disp) ? "before" : "AFTER" }' \
    "$RW_TICK_CALLS"
}

t review-reclaim-runs-before-any-dispatch before \
  "$(rw_tick_reclaim_order "$SHARED/bin/duty.sh")"
RW_ORDER_MUT="$TMP/duty-reclaim-below-dispatch.sh"
sed '/^reclaim_detached_review_worktrees$/d; /^  duty_review$/a reclaim_detached_review_worktrees' \
  "$SHARED/bin/duty.sh" >"$RW_ORDER_MUT"
t review-reclaim-below-dispatch-mutation-reds AFTER \
  "$(rw_tick_reclaim_order "$RW_ORDER_MUT")"
RW_DEAD_MUT="$TMP/duty-reclaim-dead-helper.sh"
env awk '/^reclaim_detached_review_worktrees$/ {
       print "_dead_reclaim" "() {"; print "  reclaim_detached_review_worktrees"; print "}"; next
     } { print }' "$SHARED/bin/duty.sh" >"$RW_DEAD_MUT"
t review-reclaim-dead-call-mutation-reds AFTER \
  "$(rw_tick_reclaim_order "$RW_DEAD_MUT")"


suite_finish
