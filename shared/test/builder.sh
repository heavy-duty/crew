#!/usr/bin/env bash
# shared/test/builder.sh — standalone builder subject suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$SHARED"/.panel-sized-*' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
# shellcheck source=shared/lib/duty-builder.sh
source "$SHARED/lib/duty-builder.sh"
# shellcheck source=shared/lib/duty-attention.sh
source "$SHARED/lib/duty-attention.sh"
# shellcheck source=shared/lib/duty-review.sh
source "$SHARED/lib/duty-review.sh"
ATT_MOD="$SHARED/lib/duty-attention.sh"
mkdir -p "$TMP/prompts"

# --- #530: the rendered reviewer prompt owns bounded long-command waits -----
D530_RENDERED="$(PROMPTS_DIR="$SHARED/prompts" render_prompt review.txt \
  ME=fixture-reviewer REPO=fx/repo PRS=7 BIN=/duty/bin REVIEW_WT_PARENT=/duty/trees/fx__repo \
  DUTY=/duty PARK_RESULTS=- \
  MARK_REVIEWING='reviewing' HEAD_CHECKS='- fx/repo#7: none at this head abc123.' \
  ONESHOT_RULES='one-shot')"
if grep -Fq 'never poll on a pattern the polling shell itself carries' <<<"$D530_RENDERED" &&
   grep -Fq 'the waiter can match its own command line forever' <<<"$D530_RENDERED"; then
  r1=named
else
  r1=MISSING
fi
t d530-rendered-review-names-self-matching-hazard named "$r1"
# shellcheck disable=SC2016  # rendered shell syntax is matched literally
if grep -Fq 'Prefer these mechanisms in order: `wait "$pid"` for a child of the current shell → `while kill -0 "$pid" 2>/dev/null; do sleep 5; done` for a known PID → a sentinel the command itself writes.' <<<"$D530_RENDERED"; then
  r1=ordered
else
  r1=CHANGED
fi
t d530-rendered-review-orders-wait-mechanisms ordered "$r1"
# shellcheck disable=SC2016  # prompt backticks are matched literally
if grep -Fq 'Bound every wait with `timeout`' <<<"$D530_RENDERED" &&
   grep -Fq 'never run an unbounded `until` or `while`' <<<"$D530_RENDERED"; then
  r1=bounded
else
  r1=UNBOUNDED
fi
t d530-rendered-review-bounds-every-wait bounded "$r1"
# shellcheck disable=SC2016  # wrapper variables are prompt text, not test vars
if grep -Fq '{ <command>; echo "EXIT=$?"; } >"$log" 2>&1 &' <<<"$D530_RENDERED" &&
   grep -Fq 'poll `$log` for `EXIT=`' <<<"$D530_RENDERED"; then
  r1=sentinel
else
  r1=MISSING
fi
t d530-rendered-review-gives-sentinel-wrapper sentinel "$r1"
# shellcheck disable=SC2016  # prompt backticks are matched literally
if [ "$(grep -Fo 'pgrep -f' <<<"$D530_RENDERED" | wc -l)" -eq 1 ] &&
   grep -Fq 'never use `pgrep -f` as a wait mechanism' <<<"$D530_RENDERED"; then
  r1=forbidden
else
  r1=ACCEPTABLE
fi
t d530-rendered-review-forbids-pgrep-f-wait forbidden "$r1"

# --- #532: reviewer prompts carry same-head CI as evidence, not permission --
if grep -Fq 'fx/repo#7: none at this head abc123' <<<"$D530_RENDERED"; then r1=rendered; else r1=MISSING; fi
t d532-rendered-review-carries-check-evidence rendered "$r1"
if grep -Fq "A green check covers the tree, not the change's intent" <<<"$D530_RENDERED" \
  && grep -Fq 'changes that suite or harness' <<<"$D530_RENDERED" \
  && grep -Fq 'paths filter skipped the relevant workflow' <<<"$D530_RENDERED"; then
  r1=bounded
else
  r1=MISSING
fi
t d532-rendered-review-bounds-green-evidence bounded "$r1"

# --- #598: memory-killed ShellCheck is unavailable and never retried -------
# shellcheck disable=SC2016  # prompt backticks are matched literally
if grep -Fq 'an uncapped command exits 137 or reports `Killed` by the kernel' <<<"$D530_RENDERED" \
  && grep -Fq 'the check is unavailable — not failing' <<<"$D530_RENDERED" \
  && grep -Fq 'Never retry a memory-killed command in this session' <<<"$D530_RENDERED"; then
  r1=classified
else
  r1=MISSING
fi
t d598-rendered-review-classifies-kernel-kill classified "$r1"
# shellcheck disable=SC2016  # rendered command syntax is matched literally
if grep -Fq '`(ulimit -v 2097152; shellcheck -x <files...>)`' <<<"$D530_RENDERED" \
  && grep -Fq '`shellcheck: out of memory`' <<<"$D530_RENDERED"; then
  r1=bounded
else
  r1=UNBOUNDED
fi
t d598-rendered-review-bounds-shellcheck-memory bounded "$r1"
if grep -Fq 'Record the check as unverified, naming ShellCheck and the memory limit or kernel kill' <<<"$D530_RENDERED"; then
  r1=recorded
else
  r1=MISSING
fi
t d598-rendered-review-records-unavailable-check recorded "$r1"
# shellcheck disable=SC2016  # prompt backticks are matched literally
if grep -Fq 'For repo-wide ShellCheck, rely on a green `ci-shell` check at this same head and name that reliance in the verdict' <<<"$D530_RENDERED" \
  && grep -Fq 'if `ci-shell` is absent or not green, record repo-wide ShellCheck as unverified rather than attempting it locally' <<<"$D530_RENDERED"; then
  r1=routed
else
  r1=MISSING
fi
t d598-rendered-review-routes-repo-lint-to-head-check routed "$r1"
if grep -Fq 'Treat this as evidence, not permission to trust CI or skip verification.' <<<"$D530_RENDERED"; then
  r1=unchanged
else
  r1=CHANGED
fi
t d598-rendered-review-preserves-evidence-framing unchanged "$r1"

# --- #533: reviewer sessions may park on engine-owned detached work --------
if grep -Fq 'run_detached fx/repo <N> <full-head-sha>' <<<"$D530_RENDERED" \
  && grep -Fq 'PARKED fx/repo#<N>@<full-head-sha> runs=<digest[,digest]> reason=<base64-reason>' <<<"$D530_RENDERED"; then
  r1=declared
else
  r1=MISSING
fi
t d533-rendered-review-declares-detached-park declared "$r1"
if grep -Fq "post-once.sh fx/repo <N> \"\$park_body\" \"\$park_marker\"" <<<"$D530_RENDERED" \
  && grep -Fq '<!-- duty:review-park:fx/repo#<N>@<full-head-sha> -->' <<<"$D530_RENDERED"; then
  r1=idempotent
else
  r1=UNKEYED
fi
t d533-park-announce-uses-post-once-marker idempotent "$r1"
# shellcheck disable=SC2016  # backticks and state name are literal prompt prose
if grep -Fq 'Do not change any PR label or review request' <<<"$D530_RENDERED" \
  && grep -Fq '`state:bots-reviewing` remains true' <<<"$D530_RENDERED"; then
  r1=unchanged
else
  r1=MUTABLE
fi
t d533-prompt-keeps-review-state-unchanged unchanged "$r1"
if grep -Fq 'DETACHED RESULTS FROM AN EARLIER SESSION: -' <<<"$D530_RENDERED"; then
  r1=rendered
else
  r1=MISSING
fi
t d533-park-results-slot-is-rendered rendered "$r1"
if grep -Fq 'report the conflict in the verdict' <<<"$D530_RENDERED" \
  && grep -Fq 'the environment where the local result ran' <<<"$D530_RENDERED" \
  && grep -Fq 'which evidence you rely on' <<<"$D530_RENDERED"; then
  r1=reported
else
  r1=MISSING
fi
t d532-rendered-review-reports-local-ci-conflict reported "$r1"
D532_CI_PERMISSION_RE='(green (check|CI)|(check|CI) is green).*(may|can|should).*(skip|omit|avoid).*(local|verification)'
if grep -Eqi "$D532_CI_PERMISSION_RE" <<<"$D530_RENDERED"; then
  r1=PERMITTED
else
  r1=forbidden
fi
t d532-green-never-permits-skipping-verification forbidden "$r1"
if grep -Eqi "$D532_CI_PERMISSION_RE" \
    <<<'If CI is green, you may skip local verification.'; then
  r1=detected
else
  r1=MISSED
fi
t d532-ci-permission-natural-wording-mutation detected "$r1"

D532_AT_HEAD='{"number":7,"isDraft":false,"reviewRequests":[],"updatedAt":"T1","headRefOid":"abc123","statusCheckRollup":[{"__typename":"CheckRun","workflowName":"ci-shell","name":"ci-shell","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-08-29T23:45:26Z","completedAt":"2026-08-29T23:45:26Z"},{"__typename":"CheckRun","workflowName":"ci-shell","name":"ci-shell","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-29T23:52:00Z","completedAt":"2026-08-30T00:03:35Z"},{"__typename":"CheckRun","workflowName":"ci-floor","name":"ci-floor","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-08-29T23:52:00Z","completedAt":"2026-08-29T23:52:00Z"}]}'
D532_EVIDENCE="$(_review_check_evidence_from_payload fx/repo 7 "$D532_AT_HEAD" abc123)"
if grep -Fq 'checks at abc123 (this head; aggregate green)' <<<"$D532_EVIDENCE" \
  && grep -Fq 'ci-shell=SUCCESS' <<<"$D532_EVIDENCE" \
  && grep -Fq 'ci-floor=SKIPPED' <<<"$D532_EVIDENCE" \
  && ! grep -Fq 'ci-shell=SKIPPED' <<<"$D532_EVIDENCE"; then
  r1=complete
else
  r1="$D532_EVIDENCE"
fi
t d532-at-head-checks-name-conclusions complete "$r1"
D532_STALE="$(_review_check_evidence_from_payload fx/repo 7 "$D532_AT_HEAD" def456)"
case "$D532_STALE" in *'checks at abc123 (older SHA; current head def456;'*) r1=stale ;; *) r1="$D532_STALE" ;; esac
t d532-older-head-checks-marked-stale stale "$r1"
D532_UNKNOWN="$(_review_check_evidence_from_payload fx/repo 7 "$D532_AT_HEAD" unknown)"
case "$D532_UNKNOWN" in *'checks at abc123 (current head unavailable;'*) r1=unknown ;; *) r1="$D532_UNKNOWN" ;; esac
t d532-unreadable-current-head-is-not-called-stale unknown "$r1"
D532_NONE='{"number":7,"isDraft":false,"reviewRequests":[],"updatedAt":"T1","headRefOid":"abc123","statusCheckRollup":[]}'
t d532-no-checks-says-none-at-head '- fx/repo#7: none at this head abc123.' \
  "$(_review_check_evidence_from_payload fx/repo 7 "$D532_NONE" abc123)"

D532_MULTI="$({
  _review_check_evidence() { printf -- '- %s#%s: evidence.\n' "$1" "$2"; }
  _review_check_evidence_list fx/repo '7 8'
})"
t d532-multi-pr-evidence-keeps-line-separator $'- fx/repo#7: evidence.\n- fx/repo#8: evidence.' "$D532_MULTI"
# shellcheck disable=SC2016  # production shell syntax is matched literally
if grep -Fq 'check_evidence="$(_review_check_evidence_list "$SR" "$prs")"' \
    "$SHARED/lib/duty-review.sh"; then
  r1=connected
else
  r1=DISCONNECTED
fi
t d532-multi-pr-evidence-list-is-used-by-review-render connected "$r1"

# shellcheck disable=SC2016,SC2100  # grep literals intentionally contain shell syntax
if grep -Fq '_mark_addressing "$SRa" "$Na"' "$SHARED/lib/duty-review.sh" && \
    ! grep -Fq 'repos/$SRa/pulls/$Na' "$SHARED/lib/duty-review.sh"; then r1=payload-author; else r1=EXTRA-FETCH; fi
t panel-reviewer-reuses-payload-author payload-author "$r1"

H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PANEL='["rev-a","rev-b"]'
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
CJQ="$SHARED/lib/jq/converged.jq"
CJ_HUMAN="danmt"
CJ_NO_SIG='{"sha":"","createdAt":""}'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
CJ_ME="builder-me"
CJ_MARK="🤝 handed off at head"   # MARK_HANDOFF, the wire string (fleet.defaults.conf)
cj() {  # cj [signal-json] [panel-json] [human] [roster-json]
  jq -r --argjson panel "${2:-$PANEL}" --argjson roster "${4:-${2:-$PANEL}}" --arg me "$CJ_ME" --arg mark_handoff "$CJ_MARK" \
    --arg human "${3-$CJ_HUMAN}" --argjson signal "${1:-$CJ_NO_SIG}" -f "$CJQ"
}

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
if grep -q 'comments(last:.*OPERATING_LIMIT_GITHUB_CONNECTION_NODES.*){.*nodes{author{login} body createdAt}}' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'latestOpinionatedReviews(first:.*OPERATING_LIMIT_GITHUB_PANEL_NODES.*){.*nodes{author{login} state submittedAt commit{oid}}}' \
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
# Every consumer reads the licence as the OBJECT it now is: a consumer left
# comparing the raw output to a head would classify every PR as unsignalled —
# resume would re-answer finished rounds forever and the request gate would
# never open (#286).
#
# #452 adds the first consumer that reads it WHOLE: converged.jq is handed the
# same {sha, createdAt} object request-panel.jq gets, and spends the human's
# block with its createdAt. So "one `.sha` read per call site" stops being the
# shape of the property — it was always a proxy — while the property itself is
# unchanged. Every call site is accounted for by exactly one consumption, a
# `.sha` read or a whole-object pass, and the two must still add up: a new call
# site that does neither is a raw output nobody read as an object.
ah_calls="$(grep -c -- '-f "\$[A-Z_]*DIR[A-Za-z_/]*/jq/answered-head\.jq"' "$SHARED/lib/duty-builder.sh")"
ah_sha_reads="$(grep -c "jq -r '\.sha // \"\"'" "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the grep literal contains $handoff_signal
ah_whole_reads="$(grep -c -- '--argjson signal "\$handoff_signal"' "$SHARED/lib/duty-builder.sh")"
if [ "$ah_calls" -gt 0 ] && [ "$ah_calls" -eq "$((ah_sha_reads + ah_whole_reads))" ]; then
  r1=object-read
else
  r1="MISMATCH($ah_calls/$ah_sha_reads+$ah_whole_reads)"
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
  "$(printf '%s' "$GQL_LONG_OK" | cj)"
if grep -q "jq -e '.data.repository.pullRequest != null'" "$SHARED/lib/duty-builder.sh" \
  && grep -q 'PR state payload unusable; skipping request and handoff' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=EXPOSED
fi
t graphql-error-gates-request-and-handoff gated "$r1"
# bots-reviewing is best-effort (|| warn), never gating.
# shellcheck disable=SC2016
if grep -q 'could not set \$LABEL_BOTS_REVIEWING' "$SHARED/lib/duty-builder.sh"; then r1='best-effort'; else r1=GATING; fi
t engine-bots-reviewing-best-effort best-effort "$r1"
# MARK_ANSWERED is defined and wire-protected against operator override.
if grep -q '^MARK_ANSWERED=' "$SHARED/conf/fleet.defaults.conf" \
  && grep -q 'wire_answered' "$SHARED/lib/common/conf.sh"; then r1=wire; else r1=UNPROTECTED; fi
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

# --- #728: the authored-PR awareness pass is bounded by the registry --------
# Since #714 the operator's own account is a supported box identity, so the
# `gh search prs --author=$ME` awareness pass enumerated that account's entire
# open pull-request list and named it in duty.log — five personal and
# organization repositories per tick, every five minutes, in the 0.1.3-rc2
# round. Drive a whole tick under exactly that identity, with a shim that would
# ANSWER a cross-account search if one were made: nothing outside the registry
# may be read, named or acted on.
#
# The out-of-scope needle is one variable, shared by this control and by the
# mutation below, so the two cannot drift into asserting different things.
P728_DIR="$TMP/p728"
mkdir -p "$P728_DIR/duty"
P728_CALLS="$P728_DIR/calls"
P728_OUT_OF_SCOPE='lafamilia-landing|my-angular-bank|wtf-is-a-wallet|tarea-4-lenguajes|easy-eddie'
# The rc2 round's own rows, verbatim from the WARN line #728 quotes.
p728_operator_prs() {
  printf '%s\n' heavy-duty/lafamilia-landing#2 danmt/my-angular-bank#3 \
    danmt/wtf-is-a-wallet#3 danmt/tarea-4-lenguajes#3 danmt/easy-eddie#6
}
# The tick's environment is `local` inside a function called in a subshell, not
# bare assignment in one: DUTY_DIR and ME are live for the rest of this suite,
# and a subshell assignment to either is a modification shellcheck reports and
# a later reader could be misled by.
p728_tick() {
  local DUTY_DIR="$P728_DIR/duty"
  local REPOS_FILE="$P728_DIR/repos.txt"
  local ME=danmt
  local REVIEW_MY_PR_REPOS=""
  local OPERATING_LIMIT_GITHUB_REST_PAGE=100
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  read_repo_list() { printf 'heavy-duty/crew\n'; }
  # shellcheck disable=SC2317  # invoked indirectly by _discover_my_pr_repos
  has_role() { [ "$1" = builder ]; }
  # Trace to a file, never to stdout: the registry pulls page is consumed as
  # JSON, so a trace line on the same stream would break the read under test.
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  gh() {
    printf 'GH %s\n' "$*" >>"$P728_CALLS"
    case "$*" in
      'search prs'*) p728_operator_prs ;;
      'api repos/heavy-duty/crew/pulls'*) printf '[{"user":{"login":"danmt"}}]\n' ;;
    esac
  }
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  _repair_seen_build_264() { :; }
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  _builder_suppression_prune() { :; }
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  _builder_repo() { printf 'REPO %s\n' "$1"; }
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  log() { printf 'LOG %s\n' "$*"; }
  # shellcheck disable=SC2317  # invoked indirectly by duty_builder
  warn() { printf 'WARN %s\n' "$*"; }
  duty_builder
}
: >"$P728_CALLS"
P728_TICK="$(p728_tick)"
t p728-tick-issues-no-cross-account-search 0 \
  "$(grep -c '^GH search' "$P728_CALLS" || true)"
# Read AND said: the calls file is what the tick fetched, the tick output is
# what it wrote to duty.log. Neither may carry an out-of-registry repository.
t p728-out-of-registry-repos-never-fetched 0 \
  "$(grep -Ec "$P728_OUT_OF_SCOPE" "$P728_CALLS" || true)"
t p728-out-of-registry-repos-never-named 0 \
  "$(printf '%s\n' "$P728_TICK" | grep -Ec "$P728_OUT_OF_SCOPE" || true)"
# The registry half stays live rather than being switched off: the tick really
# did read the carried repo's pulls page, and acted on that repo and no other.
t p728-registry-pulls-page-still-read 1 \
  "$(grep -c '^GH api repos/heavy-duty/crew/pulls' "$P728_CALLS" || true)"
t p728-acts-only-on-registry-repos 'REPO heavy-duty/crew' \
  "$(printf '%s\n' "$P728_TICK" | grep '^REPO ' || true)"
# Source invariant, because a future re-introduction would pass every row above
# by being spelled differently: the module makes no search-index call at all.
t p728-module-has-no-search-call 0 "$(grep -c 'gh search' "$BUILDER_MOD" || true)"

# MUST FAIL: the pre-#728 spelling, restored here and nowhere else, driven by
# the same shims and matched by the same needle. Without this row the ones
# above are all satisfiable by a fixture that never had anything to find.
p728_mutation() {
  local REPOS_FILE=unused
  local ME=danmt
  # shellcheck disable=SC2317  # invoked indirectly by _p728_pre728_pass
  read_repo_list() { printf 'heavy-duty/crew\n'; }
  # shellcheck disable=SC2317  # invoked indirectly by _p728_pre728_pass
  gh() { p728_operator_prs; }
  # shellcheck disable=SC2317  # invoked indirectly by _p728_pre728_pass
  warn() { printf 'WARN %s\n' "$*"; }
  _p728_pre728_pass() {
    local mine cand repo_list unscoped=""
    mine="$(gh search prs --author="$ME" --state open --limit 50 \
      --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      repo_list="$(read_repo_list "$REPOS_FILE")"
      if ! grep -qxF "${cand%%#*}" <<<"$repo_list"; then
        unscoped="$unscoped $cand"
      fi
    done <<<"$mine"
    if [ -n "$unscoped" ]; then
      warn "builder: authored PR(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
    fi
  }
  _p728_pre728_pass
}
P728_MUTATION="$(p728_mutation)"
t p728-mutation-old-pass-names-all-five 5 \
  "$(printf '%s\n' "$P728_MUTATION" | grep -Eo "$P728_OUT_OF_SCOPE" | n)"

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
# shellcheck disable=SC2016  # source patterns intentionally contain shell syntax
commit_block="$(sed -n \
  '/if \[ "${RUN_SESSION_RC:-1}" -eq 0 \]; then/,/# These PRs may now carry/p' \
  "$REVIEW_MOD")"
# shellcheck disable=SC2016  # source pattern intentionally contains a variable name
if grep -Fq "\${repo_items[\$SR]}" <<<"$commit_block" &&
   grep -Fq 'captured_prs=" $REVIEW_PARK_CAPTURED "' <<<"$commit_block" &&
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
if grep -q 'RUN_SESSION_LOG="\$slog"' "$SHARED/lib/common/session.sh"; then
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
builder_session_block="$(grep -A2 'run_session build ' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
if [ "$attention_ln" -lt "$builder_ln" ] &&
   grep -q '"\$TIMEOUT_BUILD"' <<<"$builder_session_block"; then
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
  "$(grep -q 'attention-o__r_9-latest.log' <<<"$ATT_124" && echo named || echo MISSING)"
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
#
# The verification is a CENSUS plus a post-tick assertion since #714, not a
# refusal, so the needles are the two halves rather than the old predicate:
# `rehearsal_attention_census` records what is parked outside the sandbox and
# `rehearsal_attention_census_assert` reads this module's own suppressed report
# back. A grep for the old name would be green on a drill that had quietly
# stopped reading anything.
if grep -q 'rehearsal_attention_census()' "$ROOT/drill/rehearsal-safety.sh" &&
   grep -q 'rehearsal_attention_census_take' "$ROOT/drill/rehearsal.sh" &&
   grep -q 'rehearsal_attention_census_assert' "$ROOT/drill/rehearsal.sh"; then r1=checked; else r1=ASSUMED; fi
t "drill-checks-attention-outside-sandbox" checked "$r1"

# --- head-checks.jq: the check at the head, and the round it gates (#45/#17) --
# The engine never read statusCheckRollup at all, which is both bugs at once: a
# fix round opened on a red head (#45) and a red head that woke nothing (#17).
HC="$SHARED/lib/jq/head-checks.jq"
hc() {  # hc <panel-json> <pr-array-json> [human] -> rows
  printf '%s' "$2" | jq -r --argjson panel "$1" --arg repo "o/r" \
    --arg human "${3-$CJ_HUMAN}" -f "$HC"
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
# THE STATUS AND THE CONCLUSION DISAGREE (#634). Every literal above is
# terminal-or-null: a non-terminal status always sits beside a null conclusion,
# which is why a status-only `is_pending` shipped. GitHub can leave a finished
# run at `status: IN_PROGRESS` with its `conclusion` set (ceremony#593's
# `labels / scope`, verbatim shape); the run never revises itself, so the head
# graded pending for as long as it existed. The sibling literals keep the
# genuinely running shapes — `null`, and `gh`'s real `""` + zero-time
# `completedAt` — so the guard is proved narrow, not merely present.
CHK_FINISHED_LEFT_IN_PROGRESS='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]'
CHK_RUNNING_BESIDE_GREEN='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":null},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]'
CHK_RUNNING_BESIDE_FAILURE='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":null},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]'
CHK_GH_RUNNING_SHAPE='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":"","completedAt":"0001-01-01T00:00:00Z"}]'
CHK_RUNNING_AND_FINISHED_LEFT_IN_PROGRESS='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":null},
  {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":"SUCCESS"}]'
CHK_FAILED_LEFT_IN_PROGRESS='[
  {"__typename":"CheckRun","name":"labels / scope","status":"IN_PROGRESS","conclusion":"FAILURE"},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]'
SC_PENDING='[{"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"}]'
SC_OK='[{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]'
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
# A finished run GitHub left at IN_PROGRESS is the shape ceremony#593 sat on
# for 10h17m (#634): the shipped grader read it pending and green at once, and
# `check_state` tests pending first, so the head graded pending forever and the
# panel was never requested. The guard lives on `is_pending` and is NARROW —
# the three running shapes beside it still hold the request, and a FAILURE
# anywhere is still red: pending never masks red.
t head-finished-left-in-progress-is-green green "$(state_of "$CHK_FINISHED_LEFT_IN_PROGRESS")"
t head-running-beside-green-is-pending pending "$(state_of "$CHK_RUNNING_BESIDE_GREEN")"
t head-gh-running-shape-is-pending pending "$(state_of "$CHK_GH_RUNNING_SHAPE")"
t head-running-and-finished-left-in-progress-is-pending pending \
  "$(state_of "$CHK_RUNNING_AND_FINISHED_LEFT_IN_PROGRESS")"
t head-running-beside-failure-is-red red "$(state_of "$CHK_RUNNING_BESIDE_FAILURE")"
# ...and a FAILED run left at IN_PROGRESS is red, not pending: the conclusion
# is the verdict whatever the status says, and a guard that read only
# `is_green` would hold the request (and blind #17's wake) on a failed head.
t head-failed-left-in-progress-is-red red "$(state_of "$CHK_FAILED_LEFT_IN_PROGRESS")"
t head-failed-left-in-progress-is-named "labels / scope (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_FAILED_LEFT_IN_PROGRESS")" | cut -f6)"
# The StatusContext axis is untouched by the guard: a status has no conclusion.
t head-status-context-pending-is-pending pending "$(state_of "$SC_PENDING")"
t head-status-context-success-is-green green "$(state_of "$SC_OK")"
# THE PREDICATES, ASSERTED DIRECTLY RATHER THAN INFERRED FROM `check_state`.
# `is_blocking` is `(is_green or is_pending) | not` and must not move under the
# guard on any payload above (#634 D3); `check_state` would hide a move behind
# its own ordering. `HC_DEFS` is the file's definitions — everything before its
# `.[]` main expression — so this reads the shipped predicates, not a restated
# copy of them.
HC_DEFS="$(sed '/^\.\[\]$/,$d' "$HC")"
t head-predicates-sliced-from-the-module 1 "$(grep -c '^def is_blocking' <<<"$HC_DEFS")"
pred_of() {  # pred_of <predicate> <rollup> -> the predicate per row, rollup order
  printf '%s' "$2" | jq -r "$HC_DEFS map($1) | map(tostring) | join(\" \")"
}
t head-finished-left-in-progress-rows-not-pending "false false" \
  "$(pred_of is_pending "$CHK_FINISHED_LEFT_IN_PROGRESS")"
t head-finished-left-in-progress-rows-green "true true" \
  "$(pred_of is_green "$CHK_FINISHED_LEFT_IN_PROGRESS")"
t head-finished-left-in-progress-rows-not-blocking "false false" \
  "$(pred_of is_blocking "$CHK_FINISHED_LEFT_IN_PROGRESS")"
t head-running-beside-green-rows-pending "true false" \
  "$(pred_of is_pending "$CHK_RUNNING_BESIDE_GREEN")"
t head-running-beside-green-rows-not-blocking "false false" \
  "$(pred_of is_blocking "$CHK_RUNNING_BESIDE_GREEN")"
t head-running-beside-failure-rows-pending "true false" \
  "$(pred_of is_pending "$CHK_RUNNING_BESIDE_FAILURE")"
t head-running-beside-failure-rows-blocking "false true" \
  "$(pred_of is_blocking "$CHK_RUNNING_BESIDE_FAILURE")"
t head-gh-running-shape-row-pending true "$(pred_of is_pending "$CHK_GH_RUNNING_SHAPE")"
t head-gh-running-shape-row-not-blocking false "$(pred_of is_blocking "$CHK_GH_RUNNING_SHAPE")"
t head-running-and-finished-rows-pending "true false" \
  "$(pred_of is_pending "$CHK_RUNNING_AND_FINISHED_LEFT_IN_PROGRESS")"
t head-running-and-finished-rows-not-blocking "false false" \
  "$(pred_of is_blocking "$CHK_RUNNING_AND_FINISHED_LEFT_IN_PROGRESS")"
t head-failed-left-in-progress-rows-not-pending "false false" \
  "$(pred_of is_pending "$CHK_FAILED_LEFT_IN_PROGRESS")"
t head-failed-left-in-progress-rows-blocking "true false" \
  "$(pred_of is_blocking "$CHK_FAILED_LEFT_IN_PROGRESS")"
t head-status-context-pending-row-pending true "$(pred_of is_pending "$SC_PENDING")"
t head-status-context-pending-row-not-blocking false "$(pred_of is_blocking "$SC_PENDING")"
t head-status-context-success-row-green true "$(pred_of is_green "$SC_OK")"
t head-status-context-success-row-not-blocking false "$(pred_of is_blocking "$SC_OK")"
# MUST FAIL — `check_state` testing green before pending (#634 D2). That is the
# plausible wrong fix: it also grades a head green while a second check is
# genuinely still running, which is #45's gate defeated. Pinned by source text
# (red, then pending, then green, and no green test among the branches) and by
# behaviour (`head-running-beside-green-is-pending` above).
hc_order="$(sed -n '/^def check_state/,/end;/p' "$HC" | grep -o 'map(is_[a-z]*)' | tr '\n' ' ')"
t head-check-state-tests-red-then-pending "map(is_blocking) map(is_pending) " "$hc_order"
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
# --- #452: THE BOUNCE IS GONE — the two predicates on ONE human-block payload -
# The siblings' agreement extended to the round the human owns. This is the
# whole defect in one snapshot: the panel approves the head, the maintainer
# blocks it, nothing is requested. Before the fix round_owed said `-` and
# converged said true, so the tick handed off — re-requesting the human and
# re-setting state:needs-human over the very block that had just come in, while
# the builder was never woken. The ball has to land on exactly one of these two,
# and asserting both against one payload is what makes that a test rather than a
# claim. Read again with the human RE-REQUESTED, both flip: the wake is spent
# and the PR is legitimately the human's.
HB_PANEL='["p1"]'
HB_REVIEWS='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-11T09:30:00Z"},
  {"state":"CHANGES_REQUESTED","author":{"login":"'$CJ_HUMAN'"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-11T10:00:00Z"}]'
HB_GQL="$(jq -cn --argjson reviews "$HB_REVIEWS" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-human-block-owed owed \
  "$(hc "$HB_PANEL" "$(mk_prc "$CHK_OK" "$HB_REVIEWS")" | cut -f5)"
t round-siblings-human-block-not-converged false \
  "$(printf '%s' "$HB_GQL" | cj '' "$HB_PANEL")"
# Requested: state:needs-human stands, the builder is not re-woken, and the
# handoff does not refire either — nothing re-requests a human already on the
# list, and the label is already set.
HB_REQUESTED="$(printf '%s' "$HB_GQL" \
  | jq -c --arg h "$CJ_HUMAN" '.data.repository.pullRequest.reviewRequests.nodes
             = [{requestedReviewer:{login:$h}}]')"
t round-siblings-human-block-requested-not-owed - \
  "$(hc "$HB_PANEL" "$(mk_prc "$CHK_OK" "$HB_REVIEWS" '[{"login":"'$CJ_HUMAN'"}]')" | cut -f5)"
t round-siblings-human-block-requested-still-not-converged false \
  "$(printf '%s' "$HB_REQUESTED" | cj '' "$HB_PANEL")"
# And the answered round, at the same unchanged head: converged again, so the
# argument reaches the human — while round_owed has NOT re-fired, the human
# still being off the request list until the handoff puts them back on it. The
# builder answering is what moves this, never the engine deciding on its own.
t round-siblings-human-block-answered-converges true \
  "$(printf '%s' "$HB_GQL" | cj "$(sig abc1234 2026-08-11T11:00:00Z)" "$HB_PANEL")"

# The wiring, not just the predicates: both facts must actually reach both
# programs at the handoff call site, off the SAME payload and through the same
# licence program the request path uses. A predicate nobody passes $human to is
# a fix that ships inert.
# shellcheck disable=SC2016
if grep -q 'arg human "\${FLEET_HUMAN:-}"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'argjson signal "\$handoff_signal"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'jq/answered-head.jq' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=INERT
fi
t engine-handoff-reads-the-human wired "$r1"
# ...and it is read GUARDED. duty.sh runs `set -euo pipefail`, FLEET_HUMAN has
# no entry in fleet.defaults.conf, and the round-detection call site above runs
# on every tick for every repo — a bare deref there turns "the operator never
# set FLEET_HUMAN" from a handoff that fails into a builder that does not run at
# all. Both new sites take `${FLEET_HUMAN:-}`; empty is the predicates'
# documented "matches nobody", which is exactly today's behaviour.
# shellcheck disable=SC2016
t engine-human-arg-is-set-u-safe 0 \
  "$(grep -c -- '--arg human "\$FLEET_HUMAN"' "$SHARED/lib/duty-builder.sh" || true)"
# Every head-checks.jq and converged.jq invocation passes $human — jq aborts on
# an undefined argument, so a missed call site is a silently empty row or an
# `err` branch, not a loud failure.
# `case` over the captured context, not a `| grep -q`: this file runs under
# pipefail and an early-exiting grep at the end of a pipe is the SIGPIPE red
# the guard above exists to keep out (#443, #449).
# The line numbers arrive by process substitution rather than by a pipe into
# the loop, and the loop reads them one line at a time (SC2013): `missing_human`
# accumulates in the loop BODY, so a `grep | while read` would spend every hit
# in a subshell and leave this guard passing vacuously. `cut` drains its input,
# so nothing at the end of that feeding pipe exits early either.
missing_human=""
while read -r _ph_ln; do
  _ph_ctx="$(sed -n "$((_ph_ln > 6 ? _ph_ln - 6 : 1)),${_ph_ln}p" \
    "$SHARED/lib/duty-builder.sh")"
  case "$_ph_ctx" in
    *"--arg human"*) : ;;
    *) missing_human="${missing_human}${_ph_ln} " ;;
  esac
done < <(grep -n 'jq/head-checks\.jq\|jq/converged\.jq' \
  "$SHARED/lib/duty-builder.sh" | cut -d: -f1)
t engine-every-predicate-call-passes-human "" "${missing_human% }"

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
# Four since #761: the sizing read of the head's files is one more gh call.
t near-miss-control-real-signal-does-request 4 \
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
# shellcheck disable=SC2016,SC2100  # matching shell source literally
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
if grep -Fq 'gh api --paginate "repos/$repo/issues/$num/comments?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE"' \
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
RG_MARKER="$RG_DUTY/.builder-suppressed.o__r.draft.o__r_311_$RG_HEAD"
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
rg_reset() {
  rm -f "$RG_DUTY/.seen-resume" "$RG_DUTY/.resume-zero-action.o__r" \
    "$RG_DUTY"/.builder-suppressed.o__r.draft*
}
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
t resume-breaker-third-dispatch-does-not-record-suppression 1 \
  "$([ -e "$RG_MARKER" ] && echo 0 || echo 1)"
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
t resume-breaker-suppress-verdict-records-box-state \
  $'draft\to/r#311@'"$RG_HEAD" \
  "$(cut -f2- "$RG_MARKER")"
RG_SUPPRESSED_AT="$(cut -f1 "$RG_MARKER")"
case "$RG_SUPPRESSED_AT" in ''|*[!0-9]*) r1=INVALID ;; *) r1=epoch ;; esac
t resume-breaker-state-records-suppression-time epoch "$r1"
t resume-breaker-first-marker-write-is-quiet 0 \
  "$(grep -c 'builder-suppressed.*No such file or directory' "$RG_LOG")"
t resume-breaker-suppression-is-said 1 \
  "$(grep -c "breaker-suppressed at $RG_HEAD after 3 zero-action dispatches" "$RG_LOG")"
t resume-breaker-state-keeps-original-trip-time "$RG_SUPPRESSED_AT" \
  "$(cut -f1 "$RG_MARKER")"
t resume-breaker-warns-only-once 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
# A push clears it: a new head is a new key, and the count starts at one.
rg_tick "$(rg_listing "$RG_HEAD2" T 2026-08-03T05:00:00Z 'Closes #290')"
t resume-breaker-push-clears-suppression 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-push-resets-count-to-one 1 \
  "$(awk -F'\t' -v k="o/r#311@$RG_HEAD2" '$1 == k {print $2}' "$RG_DUTY/.resume-zero-action.o__r")"
t resume-breaker-push-clears-box-state 1 \
  "$([ -e "$RG_MARKER" ] && echo 0 || echo 1)"
# Closing the last draft also clears the published episode. This path returns
# before the ledger, so it needs its own lifecycle assertion rather than
# borrowing the head-movement case above.
printf '1\tdraft\to/r#311@%s\n' "$RG_HEAD" \
  >"$RG_MARKER"
rg_tick ""
t resume-breaker-empty-list-clears-box-state 1 \
  "$([ -e "$RG_MARKER" ] && echo 0 || echo 1)"

# More than one PR can trip the same lane. Each episode keeps its own original
# timestamp, and clearing either selected episode must leave the other intact.
MULTI_DUTY="$TMP/suppression-same-lane"
mkdir -p "$MULTI_DUTY"
old_duty="$DUTY_DIR"; DUTY_DIR="$MULTI_DUTY"
MULTI_STATE="$MULTI_DUTY/.resume-zero-action-stranded.o__r"
MULTI_PREFIX="$MULTI_DUTY/.builder-suppressed.o__r.stranded"
MULTI_ONE="$MULTI_PREFIX.o__r_1_aaa"
MULTI_TWO="$MULTI_PREFIX.o__r_2_bbb"
printf 'o/r#1@aaa\t3\no/r#2@bbb\t3\n' >"$MULTI_STATE"
printf '100\tstranded\to/r#1@aaa\n' >"$MULTI_ONE"
_resume_lane_breaker o/r stranded "$MULTI_STATE" $'o/r#2@bbb\no/r#1@aaa' >/dev/null
MULTI_TWO_AT="$(cut -f1 "$MULTI_TWO")"
t suppression-same-lane-keeps-first-trip 100 "$(cut -f1 "$MULTI_ONE")"
case "$MULTI_TWO_AT" in ''|*[!0-9]*) r1=INVALID ;; *) r1=epoch ;; esac
t suppression-same-lane-records-second-trip epoch "$r1"
_resume_lane_breaker o/r stranded "$MULTI_STATE" 'o/r#2@bbb' >/dev/null
t suppression-same-lane-clears-oldest-only 1 \
  "$([ ! -e "$MULTI_ONE" ] && [ -e "$MULTI_TWO" ] && echo 1 || echo 0)"
t suppression-same-lane-survivor-keeps-trip "$MULTI_TWO_AT" "$(cut -f1 "$MULTI_TWO")"
printf 'o/r#1@aaa\t3\no/r#2@bbb\t3\n' >"$MULTI_STATE"
printf '100\tstranded\to/r#1@aaa\n' >"$MULTI_ONE"
_resume_lane_breaker o/r stranded "$MULTI_STATE" $'o/r#2@bbb\no/r#1@aaa' >/dev/null
_resume_lane_breaker o/r stranded "$MULTI_STATE" 'o/r#1@aaa' >/dev/null
t suppression-same-lane-clears-younger-only 1 \
  "$([ -e "$MULTI_ONE" ] && [ ! -e "$MULTI_TWO" ] && echo 1 || echo 0)"
t suppression-same-lane-older-survivor-keeps-trip 100 "$(cut -f1 "$MULTI_ONE")"
DUTY_DIR="$old_duty"

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

# Published markers are bounded by the configured repository/lane set too.
# A removed repo has no caller left to clear its lane, and a renamed lane has
# the same shape, so the tick-wide prune owns both endings.
PRUNE_DUTY="$TMP/suppression-prune"
mkdir -p "$PRUNE_DUTY"
printf '1\tdraft\to/r#1@aaa\n' >"$PRUNE_DUTY/.builder-suppressed.o__r.draft"
printf '2\tdraft\told/r#2@bbb\n' >"$PRUNE_DUTY/.builder-suppressed.old__r.draft.old__r_2_bbb"
printf '3\tretired\to/r#3@ccc\n' >"$PRUNE_DUTY/.builder-suppressed.o__r.retired.o__r_3_ccc"
old_duty="$DUTY_DIR"; DUTY_DIR="$PRUNE_DUTY"
_builder_suppression_prune 'o/r'
DUTY_DIR="$old_duty"
t suppression-prune-keeps-configured-lane 1 \
  "$([ -e "$PRUNE_DUTY/.builder-suppressed.o__r.draft" ] && echo 1 || echo 0)"
t suppression-prune-removes-dropped-repo 1 \
  "$([ ! -e "$PRUNE_DUTY/.builder-suppressed.old__r.draft.old__r_2_bbb" ] && echo 1 || echo 0)"
t suppression-prune-removes-retired-lane 1 \
  "$([ ! -e "$PRUNE_DUTY/.builder-suppressed.o__r.retired.o__r_3_ccc" ] && echo 1 || echo 0)"
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
resume_commit_block="$(grep -F -A2 'if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then' \
       "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'ledger_commit "$DUTY_DIR/.seen-resume"' <<<"$resume_commit_block"; then
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
if grep -Fq -- '--paginate "repos/$repo/issues/$num/comments?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE"' \
     "$SHARED/lib/duty-builder.sh" \
  && grep -Fq -- '--paginate "repos/$repo/pulls/$num/reviews?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE"' \
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
# governing/acceptance references. fragment-round-rules.txt's three occurrences
# are the two bare green-head/panel references and the round cap's section
# citation (#502). attention.txt, ci-red.txt,
# fragment-floor-envelope.txt, fragment-oneshot-rules.txt,
# fragment-doctrine-unlisted.txt, fragment-doctrine-upstream.txt,
# fragment-graph-changed.txt, fragment-round-count.txt, fragment-signals.txt,
# fragment-unblockable.txt,
# fragment-wt-rules.txt,
# hygiene.txt, mention.txt,
# rebase.txt, release.txt, review.txt, and triage.txt contain no direct
# occurrence.
# fragment-round-count.txt is sizing evidence read by TRIAGE, so it cites no
# builder doctrine slot even though its subject is the builder's round cap.
declare -A doctrine_builder_occurrences=(
  [attention.txt]=0 [build.txt]=2 [ci-red.txt]=0
  [fragment-floor-envelope.txt]=0 [fragment-oneshot-rules.txt]=0
  [fragment-doctrine-unlisted.txt]=0 [fragment-doctrine-upstream.txt]=0
  [fragment-graph-changed.txt]=0 [fragment-round-count.txt]=0
  [fragment-round-rules.txt]=3 [fragment-signals.txt]=0
  [fragment-unblockable.txt]=0
  [fragment-wt-rules.txt]=0 [fragment-handoff.txt]=0 [fragment-wait-rules.txt]=0
  [fragment-wait-rules-review.txt]=0
  [hygiene.txt]=0 [mention.txt]=0
  [rebase.txt]=0 [release.txt]=0 [resume.txt]=4 [review.txt]=0 [triage.txt]=0
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
p384_run() {  # p384_run CONCLUSION [COMPLETED] [STATUS] — one CheckRun in a rollup
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
  #
  # STATUS, when given, overrides the derivation from CONCLUSION (#634). The
  # derivation assumes the two fields agree, and on a finished run GitHub can
  # leave `status: IN_PROGRESS` beside a set conclusion — a shape that was
  # unrepresentable here, not merely untested. An empty or absent STATUS is
  # today's derivation exactly, so every existing caller is byte-identical.
  jq -cn --arg c "$1" --arg fin "${2:-}" --arg st "${3:-}" --arg started "$P384_START" \
    '[{__typename:"CheckRun", name:"ci-floor", workflowName:"ci-floor",
       status:(if $st != "" then $st elif $c == "" then "IN_PROGRESS" else "COMPLETED" end),
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
# A finished run left at IN_PROGRESS beside its SUCCESS (#634) grades green
# through the same path the engine takes, and the override is what makes the
# shape representable in this family at all.
P384_LEFT_IN_PROGRESS="$(p384_run SUCCESS "$P384_DONE" IN_PROGRESS)"
t p384-status-override-lands 1 "$(grep -c '"status":"IN_PROGRESS","conclusion":"SUCCESS"' <<<"$P384_LEFT_IN_PROGRESS")"
P384_FINISHED_LEFT_IN_PROGRESS="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_LEFT_IN_PROGRESS" '')" '[$pr]')"
t p384-state-finished-left-in-progress-is-green "$(printf '381\tgreen')" \
  "$(_resume_check_states o/r "$P384_FINISHED_LEFT_IN_PROGRESS")"
# MUST FAIL — today's argument list producing anything but today's output. The
# default is pinned to the literal, not to a re-derivation, and an explicit
# empty STATUS is the two-argument call.
t p384-run-default-green-is-byte-identical \
  '[{"__typename":"CheckRun","name":"ci-floor","workflowName":"ci-floor","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-06T07:41:19Z","completedAt":"2026-08-06T07:52:18Z"}]' \
  "$P384_GREEN"
t p384-run-default-pending-is-byte-identical \
  '[{"__typename":"CheckRun","name":"ci-floor","workflowName":"ci-floor","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-08-06T07:41:19Z","completedAt":"0001-01-01T00:00:00Z"}]' \
  "$P384_PENDING"
t p384-run-default-red-is-byte-identical \
  '[{"__typename":"CheckRun","name":"ci-floor","workflowName":"ci-floor","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-06T07:41:19Z","completedAt":"2026-08-06T07:52:18Z"}]' \
  "$P384_RED"
t p384-run-empty-status-is-the-default "$P384_GREEN" "$(p384_run SUCCESS "$P384_DONE" "")"
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
builder_doctrine_flat="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/BUILDER.md")"
if grep -Fq 'an engine may draft a PR but only the builder undrafts it' <<<"$builder_doctrine_flat"; then
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

# --- #725: THE RESUME LANES AS THE DRILL DRIVES THEM ------------------------
#
# Every assertion above drives ONE lane. `drill/rehearsal-resume.sh` drives all
# of them at once, in a fixed order, against one PR — and the `0.1.3-rc2` round
# read two of its rows FAIL: a pending head was reported resumed, and the
# unchanged head was reported not to stop at the installed threshold. A
# per-lane suite cannot answer that report either way, because the report is
# about the COMPOSITION: which lane may name this PR on each of the leg's six
# ticks. This block is that composition, replayed tick for tick.
#
# IT IS THE LEG'S SEQUENCE AND NOT AN ILLUSTRATION OF IT. Tick 1 is the pending
# head; tick 2 flips the same head green; the drill's unrendered-marker comment
# lands before tick 3; ticks 3–5 are the threshold's worth of near-miss
# dispatches; tick 6 is the one the leg asserts stops. Change the leg's shape
# and this block must change with it, which is the point — the two were tested
# against different subjects until now, and only one of them ran.
#
# THE COMPOSITION IS COPIED FROM THE ENGINE, and that is its one weakness: a
# copy can drift from `_builder_repo`. The wiring greps above (#319's two lane
# call sites, #384's four) are what hold the copy to the original, so they are
# the assertions to read first if this block ever disagrees with a real host.
P725="$TMP/p725"; P725_LOG="$P725/tick.log"
mkdir -p "$P725"
P725_SAVED_DUTY="$DUTY_DIR"; P725_SAVED_ME="${ME-}"; P725_ME_WAS_SET="${ME+x}"
DUTY_DIR="$P725"; ME=me
P725_MARK="📣 round answered at head"
P725_OLD="$(printf 'a%.0s' $(seq 1 40))"   # the head the round was answered at
P725_HEAD="$(printf 'b%.0s' $(seq 1 40))"  # the head the drill advances to
P725_STATE=PENDING     # the drill's own status context, flipped by the leg
P725_NEAR=0            # 1 once the leg posts its unrendered-marker comment
p725_listing() {
  jq -cn --arg h "$P725_HEAD" --arg s "$P725_STATE" '[{
    number: 42, isDraft: false, headRefOid: $h, body: "Closes #41",
    reviewRequests: [{login: "host-reviewer"}],
    statusCheckRollup: [{__typename: "StatusContext",
      context: "drill/resume-head-settle", state: $s,
      startedAt: "2026-09-12T10:00:00Z", targetUrl: ""}]}]'
}
# The thread the leg leaves behind: the fix round's real signal, at the head the
# drill then pushes past, and — from tick 3 — the unrendered marker naming the
# CURRENT head, which is #319's evidence and not a signal.
p725_comments() {
  local thread
  thread="$(jq -cn --arg me "$ME" --arg m "$P725_MARK" --arg h "$P725_OLD" \
    '[{author:{login:$me}, body:"🔨 addressing round", createdAt:"2026-09-12T09:00:00Z", id:"1"},
      {author:{login:$me}, body:"\($m) \($h)", createdAt:"2026-09-12T09:30:00Z", id:"2"}]')"
  [ "$P725_NEAR" -eq 1 ] && thread="$(printf '%s' "$thread" \
    | jq -c --arg me "$ME" --arg h "$P725_HEAD" \
        '. + [{author:{login:$me}, body:"{{MARK_ANSWERED}} \($h)",
               createdAt:"2026-09-12T10:10:00Z", id:"77"}]')"
  printf '%s' "$thread"
}
# shellcheck disable=SC2317  # called indirectly by the resume block below
gh() {
  local args="$*"
  case "$args" in
    */issues/42/comments*) p725_comments | jq -c '.[]' ;;
    */comments*|*/reviews*) : ;;
    *) printf '2026-09-12T09:00:00Z\n' ;;   # the issue half of the fingerprint
  esac
  return 0
}
# One duty tick's resume block, in `_builder_repo`'s order and with its names.
# The globals are cleared rather than assumed so a tree missing a lane fails its
# own assertion instead of taking the suite down under `set -u`.
p725_tick() {
  local resume_json draft_nums stranded_keys stranded_due_nums stranded_due_keys=""
  local near_miss_rows near_miss_keys="" green_head_rows key num
  P725_DRAFTS=""; P725_STRANDED=""; P725_NEAR_MISS=""; P725_GREEN=""; P725_FLIP=""
  NEAR_MISS_ROWS=""; GREEN_HEAD_ROWS=""; FLIP_OWED_ROWS=""; RESUME_FORCE_FRESH=""
  RESUME_LANE_DISPATCH_NUMS=""; GREEN_HEAD_DISPATCH_NUMS=""; RESUME_DISPATCH_NUMS=""
  {
    resume_json="$(p725_listing)"
    draft_nums="$(printf '%s' "$resume_json" | jq -r '.[] | select(.isDraft) | .number' | tr '\n' ' ')"
    _resume_attach_comments o/r "$resume_json"
    resume_json="${RESUME_LISTING:-$resume_json}"
    stranded_keys="$(printf '%s' "$resume_json" | _stranded_resume_keys o/r "$ME" "$P725_MARK")"
    _near_miss_resume_rows o/r "$ME" "$P725_MARK" "$resume_json"
    near_miss_rows="$NEAR_MISS_ROWS"
    _green_head_resume_rows o/r "$ME" "$P725_MARK" "$resume_json"
    green_head_rows="$GREEN_HEAD_ROWS"
    _flip_owed_resume_rows o/r "$ME" "$P725_MARK" '[]' "$resume_json"
    P725_FLIP="$(printf '%s' "$FLIP_OWED_ROWS" | tr '\n' ' ')"
    stranded_due_nums="$(printf '%s\n' "$stranded_keys" \
      | _stranded_resume_due "$DUTY_DIR/.resume-unsignalled.o__r" 12 | tr '\n' ' ')"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      num="${key#*#}"; num="${num%@*}"
      case " $stranded_due_nums " in
        *" $num "*) stranded_due_keys="$stranded_due_keys$key"$'\n' ;;
      esac
    done <<<"$stranded_keys"
    _resume_lane_breaker o/r stranded "$DUTY_DIR/.resume-zero-action-stranded.o__r" "$stranded_due_keys"
    P725_STRANDED="$RESUME_LANE_DISPATCH_NUMS"
    while IFS=$'\t' read -r num _; do
      [ -n "$num" ] || continue
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        [ "${key%@*}" = "o/r#$num" ] || continue
        near_miss_keys="$near_miss_keys$key"$'\n'
      done <<<"$stranded_keys"
    done <<<"$near_miss_rows"
    _resume_lane_breaker o/r near-miss "$DUTY_DIR/.resume-zero-action-nearmiss.o__r" "$near_miss_keys"
    P725_NEAR_MISS="$RESUME_LANE_DISPATCH_NUMS"
    _green_head_breaker o/r o__r "$green_head_rows"
    P725_GREEN="$GREEN_HEAD_DISPATCH_NUMS"
    if _resume_gate o/r o__r "$resume_json"; then P725_DRAFTS="$RESUME_DISPATCH_NUMS"; fi
  } >"$P725_LOG" 2>&1
  # The engine's own union: every lane that may buy this tick's session.
  P725_UNION="$(printf '%s %s %s %s\n' "$P725_DRAFTS" "$P725_STRANDED" \
    "$P725_NEAR_MISS" "$P725_GREEN" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  P725_UNION="${P725_UNION% }"
}

# TICK 1 — THE PENDING HEAD. The leg's first assertion, and the row the round
# read FAIL. No lane may name this PR: green-head declines a head that has not
# concluded, the near-miss lane has no marker to read yet, and twelve ticks of
# silence have not been bought. A session on this tick is a session spent on
# evidence that does not exist.
P725_STATE=PENDING; P725_NEAR=0
p725_tick
t p725-pending-head-buys-no-lane "" "$P725_UNION"
t p725-pending-head-is-graded-pending "$(printf '42\tpending')" \
  "$(_resume_check_states o/r "$(p725_listing)")"
# MUST FAIL, each on its own line, so a regression names the lane that broke it
# rather than "the union moved".
t p725-pending-head-no-green-bypass "" "$P725_GREEN"
t p725-pending-head-no-near-miss "" "$P725_NEAR_MISS"
t p725-pending-head-no-stranded-dispatch "" "$P725_STRANDED"
t p725-pending-head-no-draft-dispatch "" "$P725_DRAFTS"
t p725-pending-head-no-flip "" "${P725_FLIP// /}"
# And it is SILENT about resuming, not merely undispatched: the leg reads the
# log, so a detection WARN naming this head would be indistinguishable from a
# resume to the only instrument that watches it.
t p725-pending-head-detects-nothing 0 \
  "$(grep -c 'green and no signal names that head' "$P725_LOG")"
t p725-pending-head-dispatches-nothing 0 "$(grep -c 'resume dispatch' "$P725_LOG")"
# The twelve-tick counter still advanced — the pending head is not excused from
# the ordinary path, it is only excused from the bypass.
t p725-pending-head-still-counts-toward-twelve 1 \
  "$(awk -F'\t' -v k="o/r#42@$P725_HEAD" '$1 == k {print $2}' "$P725/.resume-unsignalled.o__r")"

# TICK 2 — THE CONCLUSION WAKE. The same head, now green. This is the row the
# round read `ok`, and it is asserted here so the fix for the two failing rows
# cannot be "stop resuming", which would pass both of them and break this one.
P725_STATE=SUCCESS
p725_tick
t p725-green-head-wakes-the-lane 42 "$P725_GREEN"
t p725-green-head-wake-is-said 1 \
  "$(grep -c "o/r#42: green head owed a signal .* dispatch 1 of 3 at $P725_HEAD" "$P725_LOG")"

# TICKS 3–5 — THE NEAR-MISS LANE, one dispatch per tick for the threshold's
# worth, beside the green-head lane which is spending its own last two.
P725_NEAR=1
for _p725_i in 1 2 3; do
  p725_tick
  t "p725-near-miss-dispatch-$_p725_i" 42 "$P725_NEAR_MISS"
done
t p725-near-miss-trips-at-three 1 \
  "$(grep -c "o/r#42: near-miss resume dispatch 3 of 3 at head" "$P725_LOG")"

# TICK 6 — THE STOP. The leg's second failing row. Both bypass lanes have spent
# their three at this head, nothing pushed, and the twelve-tick counter is at
# six — so the union is empty and the suppression is SAID, which is the half the
# leg greps for. Silence here would be #59's failure, not a fix.
p725_tick
t p725-unchanged-head-stops "" "$P725_UNION"
t p725-unchanged-head-stop-is-said 1 \
  "$(grep -c "no resume duty: o/r#42 near-miss lane suppressed at $P725_HEAD after 3 zero-action dispatches" "$P725_LOG")"
t p725-unchanged-head-green-bypass-also-stopped 1 \
  "$(grep -c "no resume duty: o/r#42 green-head bypass suppressed at $P725_HEAD after 3 zero-action dispatches" "$P725_LOG")"
# The leg's threshold is READ FROM THE INSTALLED ENGINE (`breaker=<n>` in
# `_resume_lane_breaker`), so the number the drill counts to and the number the
# engine stops at are one fact. A rename or a move here leaves the leg unable to
# resolve a threshold at all, which is a leg that cannot run rather than a leg
# that lies — but it is still a break, and this is where it reds first.
t p725-installed-threshold-is-readable 3 \
  "$(sed -n '/^_resume_lane_breaker()/,/^}/p' "$SHARED/lib/duty-builder.sh" \
     | sed -n 's/.*breaker=\([0-9][0-9]*\).*/\1/p' | head -1)"
# A PUSH ends both episodes at once, which is what the leg's next round depends
# on: the head is in the key, so a moved head is a key neither lane has seen.
P725_HEAD="$(printf 'c%.0s' $(seq 1 40))"
p725_tick
t p725-push-reopens-the-lanes 42 "$P725_UNION"
DUTY_DIR="$P725_SAVED_DUTY"
if [ -n "$P725_ME_WAS_SET" ]; then ME="$P725_SAVED_ME"; else unset ME; fi
unset -f gh p725_tick p725_listing p725_comments
RESUME_FORCE_FRESH=""

# THE THRESHOLD COMPARISON AT ITS BOUNDARY, one below and one at, and at a
# threshold that is not the shipped 3 — the whole point of a boundary case is
# that it fails for an off-by-one, and `-ge 3` and `-gt 3` are told apart by the
# fourth attempt while `-ge 1` and `-gt 1` are told apart by the SECOND, which
# is where an off-by-one actually hides. Driven through `_resume_breaker`
# itself, the one comparison all four lanes share.
p725_breaker() {  # p725_breaker STATE THRESHOLD — one attempt, verdict only
  printf 'o/r#42@head\tfresh\n' | _resume_breaker "$1" "$2" | cut -f2
}
P725_B1="$TMP/p725-breaker-1"
t p725-threshold-1-dispatches-the-first dispatch "$(p725_breaker "$P725_B1" 1)"
t p725-threshold-1-suppresses-the-second suppress "$(p725_breaker "$P725_B1" 1)"
P725_B5="$TMP/p725-breaker-5"
for _p725_i in 1 2 3 4; do P725_B5_OUT="$(p725_breaker "$P725_B5" 5)"; done
t p725-threshold-5-dispatches-below dispatch "$P725_B5_OUT"
t p725-threshold-5-dispatches-at-the-last dispatch "$(p725_breaker "$P725_B5" 5)"
t p725-threshold-5-suppresses-past-it suppress "$(p725_breaker "$P725_B5" 5)"
# A HELD tick is not an attempt: the count is of consecutive DISPATCHES, so the
# comparison must not advance on a tick the ledger withheld. An off-by-one that
# counted ticks would suppress this one attempt early.
P725_B2="$TMP/p725-breaker-2"
printf 'o/r#42@head\tfresh\n' | _resume_breaker "$P725_B2" 2 >/dev/null
printf 'o/r#42@head\theld\n' | _resume_breaker "$P725_B2" 2 >/dev/null
t p725-held-tick-is-not-an-attempt dispatch "$(p725_breaker "$P725_B2" 2)"
t p725-held-tick-then-suppresses suppress "$(p725_breaker "$P725_B2" 2)"
unset -f p725_breaker

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
# an argument onto the next source line cannot evade the guard. The library
# half of the population is walked, not globbed: shared/lib/common/ is engine
# source and a non-descending glob would exempt it (#507).
mapfile -t attention_sources < <(engine_lib_sources)
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
' "${attention_sources[@]}" "$SHARED"/bin/* 2>/dev/null)"
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

BMOD="$SHARED/lib/duty-builder.sh"

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
# ...plus the parked-wait read since #760: _builder_waits_due names the rollup
# in its own --json list, one per parked wait, which is the fourth listing.
t ci-red-rollup-fetched-on-three-listings 4 \
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
  DUTY_DIR="$SHARED" PANEL_SIZED_CACHE=off
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
    # The head's files, when the case sizes the panel (low: one small file).
    if [ "$1" = pr ] && [ "$2" = view ] && [[ "$*" == *"--json files"* ]] && [ -n "${AR_FILES:-}" ]; then
      printf '%s\n' "$AR_FILES"
      return 0
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
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK" PANEL_SIZED_CACHE=off
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

# THE SIZED PANEL CLOSES THE ROUND (#763 review). PR #7 at low risk is asked of
# rev-b alone (7 mod 2 = 1); rev-b's change-request at the head is then the
# whole round — closed, not approved — and the label is written. Read against
# the whole roster the same verdict is "rev-a has not reviewed", the round is
# still open, and state:addressing is never written (it is written nowhere
# else). A request still open to rev-a — outside the sized subset — keeps the
# round open under either reading: the whole roster's requests count.
AR_ONE_CR='[{"author":{"login":"rev-b"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$AR_H'"}}]'
AR_SIZED="$(mk_addressing_payload false '[]' '[]' "$AR_ONE_CR")"
AR_SIZED_REQ="$(mk_addressing_payload false '[]' '["rev-a"]' "$AR_ONE_CR")"
t addressing-a-low-risk-head-is-marked-on-its-sized-reviewers-verdict 'rc=0 actions=label' \
  "$(AR_FILES='README.md 3' review_addressing_actions "$AR_SIZED")"
t addressing-the-same-verdict-against-the-whole-roster-is-an-open-round 'rc=0 actions=' \
  "$(review_addressing_actions "$AR_SIZED")"
t addressing-a-request-open-outside-the-sized-subset-holds-the-round 'rc=0 actions=' \
  "$(AR_FILES='README.md 3' review_addressing_actions "$AR_SIZED_REQ")"

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
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK" PANEL_SIZED_CACHE=off
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
labels_doctrine_flat="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/LABELS.md")"
# shellcheck disable=SC2016  # literal doctrine text contains backticks
if [ "$AR_OLDEST" = 0.5.0 ] \
  && grep -Fq 'Draft is evidence for it, not the definition of it: a draft carrying a standing non-approving verdict is a fix round and reads `state:addressing`' <<<"$labels_doctrine_flat"; then
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
t d533-rereq-running-park-suppresses     parked       "$(rereq_decision - "$RR_H" - - "$RR_T1" 1 parked)"
t d533-rereq-ready-park-queues           queue        "$(rereq_decision - "$RR_H" - - "$RR_T1" 1 ready)"
t d533-rereq-expired-park-queues-fresh   queue        "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T2" "$RR_T1" 1 expired)"

# Drive duty_review, not only rereq_decision: a live park must issue no model
# dispatch and no label mutation; a completed park dispatches once with its
# result evidence, clears only after rc=0, and then settles in the seen ledger.
D533="$TMP/d533"; mkdir -p "$D533/bin" "$D533/work" "$D533/trees" "$D533/prompts"
printf 'fx/repo\n' >"$D533/repos.txt"
D533_HEAD=dddddddddddddddddddddddddddddddddddddddd
D533_NUM=7
D533_UPDATED=2026-08-30T07:00:00Z
D533_DISPATCHES="$D533/dispatches"
D533_GH="$D533/gh"
D533_PROMPT="$D533/prompt"

d533_tick() (
  # shellcheck disable=SC2030  # fixture globals are intentionally isolated
  local DUTY_DIR="$D533" WORK_DIR="$D533/work" TREES_DIR="$D533/trees"
  # shellcheck disable=SC2030  # fixture globals are intentionally isolated
  local LOG_DIR="$D533/logs" CONF_DIR="$D533/conf" PROMPTS_DIR="$SHARED/prompts"
  local BIN_DIR="$D533/bin" REPOS_FILE="$D533/repos.txt"
  local ME=fixture-reviewer MARK_REVIEWING='reviewing head'
  local TIMEOUT_REVIEW=30 AUTO_APPROVE_REREQUEST=1 LABEL_ADDRESSING=state:addressing
  : >"$D533_GH"
  gh() {
    printf '%s\n' "$*" >>"$D533_GH"
    if [ "$1" = api ] && [[ "$2" == repos/fx/repo/pulls\?* ]]; then
      jq -cn --arg me "$ME" --arg n "$D533_NUM" --arg updated "$D533_UPDATED" \
        '[{draft:false, requested_reviewers:[{login:$me}],
           created_at:"2026-08-30T06:00:00Z", updated_at:$updated,
           number:($n|tonumber), user:{login:"author"}}]'
      return 0
    fi
    if [ "$1" = search ]; then return 0; fi
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [ -e "$D533/verdict-landed-$D533_NUM" ]; then
        printf '%s %s 2026-08-30T07:01:00Z APPROVED 2026-08-30T06:30:00Z\n' \
          "$D533_HEAD" "$D533_HEAD"
      else
        printf '%s - - - 2026-08-30T06:30:00Z\n' "$D533_HEAD"
      fi
      return 0
    fi
    return 3
  }
  ensure_checkout() { mkdir -p "$2/.git"; }
  _review_check_evidence_list() { printf -- '- %s#%s: fixture evidence.\n' "$1" "$2"; }
  _mark_addressing() { :; }
  run_session() {
    printf '%s\n' "$2" >>"$D533_DISPATCHES"
    printf '%s' "$5" >"$D533_PROMPT"
    mkdir -p "$D533/logs"
    RUN_SESSION_LOG="$D533/logs/review.log"
    : >"$RUN_SESSION_LOG"
    if [ "${D533_START_CAPTURE:-0}" = 1 ]; then
      D533_SESSION_DIGEST="$(run_detached "$2" "$D533_NUM" "$D533_HEAD" -- \
        bash -c 'sleep 0.3; printf captured')"
      printf 'PARKED %s#%s@%s runs=%s reason=%s\n' \
        "$2" "$D533_NUM" "$D533_HEAD" "$D533_SESSION_DIGEST" "$D533_REASON" \
        >"$RUN_SESSION_LOG"
    elif [ -n "${D533_PARK_LINE:-}" ]; then
      printf '%s\n' "$D533_PARK_LINE" >"$RUN_SESSION_LOG"
    fi
    : >"$D533/verdict-landed-$D533_NUM"
    RUN_SESSION_RC=0
  }
  duty_review
)

# shellcheck disable=SC2031  # the subshell above cannot change this caller
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
D533_RUNNING="$(run_detached fx/repo "$D533_NUM" "$D533_HEAD" -- bash -c 'sleep 30')"
D533_REASON="$(printf 'suite still running' | base64 | tr -d '\n')"
review_park_write fx/repo "$D533_NUM" "$D533_HEAD" "$D533_RUNNING" "$D533_REASON"
DUTY_DIR="$old_duty"
rm -f "$D533_DISPATCHES"
d533_tick
if [ -f "$D533_DISPATCHES" ]; then r1="$(wc -l <"$D533_DISPATCHES")"; else r1=0; fi
t d533-running-park-dispatches-no-session 0 "$r1"
if grep -Eq 'issue edit|add-label|remove-label|requested_reviewers' "$D533_GH"; then r1=MUTATED; else r1=unchanged; fi
t d533-running-park-mutates-no-label-or-request unchanged "$r1"

# Replace the live park with one whose detached run has completed.
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
detached_run_abandon fx/repo "$D533_NUM" "$D533_HEAD" "$D533_RUNNING"
D533_DONE="$(run_detached fx/repo "$D533_NUM" "$D533_HEAD" -- bash -c 'printf finished')"
for _wait in $(seq 1 100); do
  detached_run_read fx/repo "$D533_NUM" "$D533_HEAD" "$D533_DONE" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 0.02
done
review_park_write fx/repo "$D533_NUM" "$D533_HEAD" "$D533_DONE" "$D533_REASON"
DUTY_DIR="$old_duty"
d533_tick
t d533-complete-park-dispatches-once 1 "$(wc -l <"$D533_DISPATCHES")"
if grep -Fq 'exit=0' "$D533_PROMPT" && grep -Fq "$D533_DONE.log" "$D533_PROMPT"; then r1=handed; else r1=MISSING; fi
t d533-complete-park-hands-results handed "$r1"
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
if [ -f "$(_review_park_path fx/repo "$D533_NUM" "$D533_HEAD")" ]; then r1=kept; else r1=cleared; fi
DUTY_DIR="$old_duty"
t d533-complete-session-clears-park cleared "$r1"
d533_tick
# The landed verdict makes the next tick's pre-dispatch dedup guard skip the
# request; post-session settlement is covered directly in review.sh.
t d533-settled-result-does-not-redispatch 1 "$(wc -l <"$D533_DISPATCHES")"
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
if [ -f "$(_detached_run_stamp fx/repo 7 "$D533_HEAD" "$D533_DONE")" ] \
  || [ -f "$(_detached_run_dir fx/repo 7 "$D533_HEAD")/$D533_DONE.log" ]; then
  r1=kept
else
  r1=collected
fi
DUTY_DIR="$old_duty"
t d533-completed-artifacts-are-collected collected "$r1"

# Drive PARKED capture through the real session-log boundary. The first
# completed session must withhold this unchanged item from .seen-review; once
# the run completes, the same updated_at must dispatch exactly one resume.
D533_NUM=8; D533_HEAD=8888888888888888888888888888888888888888
D533_UPDATED=2026-08-30T07:30:00Z
D533_START_CAPTURE=1
D533_BEFORE="$(wc -l <"$D533_DISPATCHES")"
d533_tick
D533_START_CAPTURE=0
D533_CAPTURED="$(basename "$(find "$D533/.detached-runs/fx_repo/$D533_NUM/$D533_HEAD" \
  -type f -name '*.stamp' -print -quit)")"
D533_CAPTURED="${D533_CAPTURED%.stamp}"
if grep -Fq "fx/repo#$D533_NUM $D533_UPDATED" "$D533/.seen-review"; then r1=committed; else r1=withheld; fi
t d533-captured-park-withholds-ledger-item withheld "$r1"
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
for _wait in $(seq 1 100); do
  detached_run_read fx/repo "$D533_NUM" "$D533_HEAD" "$D533_CAPTURED" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 0.02
done
DUTY_DIR="$old_duty"
d533_tick
t d533-captured-completion-dispatches-once "$((D533_BEFORE + 2))" \
  "$(wc -l <"$D533_DISPATCHES")"

# At tick 13 the running command is abandoned and the ordinary review path is
# dispatched in this same tick rather than leaving an unowned gap.
D533_NUM=9; D533_HEAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
D533_EXPIRE="$(run_detached fx/repo "$D533_NUM" "$D533_HEAD" -- bash -c 'sleep 30')"
review_park_write fx/repo "$D533_NUM" "$D533_HEAD" "$D533_EXPIRE" "$D533_REASON"
_review_park_rewrite_ticks "$(_review_park_path fx/repo "$D533_NUM" "$D533_HEAD")" "$REVIEW_PARK_TICK_LIMIT"
DUTY_DIR="$old_duty"
D533_UPDATED=2026-08-30T08:00:00Z
D533_EXPIRE_BEFORE="$(wc -l <"$D533_DISPATCHES")"
d533_tick
t d533-expired-park-redispatches "$((D533_EXPIRE_BEFORE + 1))" \
  "$(wc -l <"$D533_DISPATCHES")"
old_duty="$DUTY_DIR"; DUTY_DIR="$D533"
if [ -f "$(_review_park_path fx/repo "$D533_NUM" "$D533_HEAD")" ]; then r1=kept; else r1=removed; fi
DUTY_DIR="$old_duty"
t d533-expired-park-is-abandoned removed "$r1"

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
if awk_range_grep_q '/--- HANDOFF/,/--- REBASE/' "$BMOD" 'NOT GATED ON A GREEN HEAD'; then
  r1=called-out
else
  r1=SILENT
fi
t handoff-green-gating-called-out called-out "$r1"

# --- configurable doctrine keeps the shipped prompts byte-identical (#76) ---
# shellcheck disable=SC2031  # d533_tick isolates its PROMPTS_DIR in a subshell
saved_prompts_dir="$PROMPTS_DIR"
PROMPTS_DIR="$SHARED/prompts"
# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=AGENTS.md DOCTRINE_TRIAGE=TRIAGE.md \
  DOCTRINE_BUILDER=BUILDER.md DOCTRINE_REVIEWER=REVIEWER.md
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  expected="$(sed \
    -e 's/{{DOCTRINE_REPO}}//g' \
    -e 's/{{DOCTRINE_OUTCOME}}//g' \
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
  if grep -Eq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md' <<<"$rendered"; then
    doctrine_leaks="$doctrine_leaks $prompt_name"
  fi
  if grep -q '{{DOCTRINE_' <<<"$rendered"; then
    doctrine_unresolved="$doctrine_unresolved $prompt_name"
  fi
done
t doctrine-custom-no-shipped-name-leaks "" "$doctrine_leaks"
t doctrine-custom-no-unresolved-slots "" "$doctrine_unresolved"

# Every engine render site must fill every prompt slot. render_prompt leaves
# unknown slots literal deliberately, so this belongs in CI rather than the
# runtime tick. The fixture mutations prove both missing-argument failure
# shapes and the built-in doctrine exemption.
# Walked, not globbed, for the same reason as the attention guard above: the
# seven shared/lib/common/ modules are render sites too (#507).
mapfile -t render_sources < <(engine_lib_sources)
render_sources+=("$SHARED"/bin/*.sh)
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

# --- #462: a declined ready issue becomes a fact on the BOARD ---------------
#
# The defect is a lost discovery, so almost every assertion here is made
# against the board — the fixture's comment store — and never against
# $DUTY_DIR. A ledger entry proving a decline happened is exactly what already
# existed and exactly what was not a record: per box, two fields, no reason,
# dead when the box is.
#
# The fixture GitHub keeps a comment store AND a log of every call it was
# handed. The log is what D4 is asserted from: "moves no label and assigns
# nobody" read off a final label set would pass on a path that set a label and
# put it back, so the question asked is whether a mutation was ever ISSUED.
D462="$TMP/d462"; mkdir -p "$D462/bin"
export D462_STORE="$D462/comments.json" D462_CALLS="$D462/gh-calls" \
       D462_SEQ="$D462/seq" D462_ME="fixture-builder"
cat >"$D462/bin/gh" <<'D462GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$D462_CALLS"
[ -s "$D462_STORE" ] || printf '[]' >"$D462_STORE"
[ "${1:-}" = api ] || exit 1
if [ "${2:-}" = user ]; then printf '%s\n' "$D462_ME"; exit 0; fi
path="$2"; method=GET; body=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -f) case "$2" in body=*) body="${2#body=}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
case "$method:$path" in
  GET:*/comments) cat "$D462_STORE"; exit 0 ;;
  POST:*/comments)
    # A strictly increasing stamp: two comments in the same wall-clock second
    # would tie, and "newest wins" is a real rule being tested.
    seq_n=$(( $(cat "$D462_SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$seq_n" >"$D462_SEQ"
    jq --arg me "$D462_ME" --arg b "$body" \
       --arg at "$(printf '2026-08-25T00:00:%02dZ' "$seq_n")" \
       '. + [{user:{login:$me}, body:$b, created_at:$at}]' "$D462_STORE" >"$D462_STORE.tmp" \
      && mv "$D462_STORE.tmp" "$D462_STORE"
    exit 0 ;;
esac
exit 1
D462GH
chmod +x "$D462/bin/gh"

d462_reset() { printf '[]' >"$D462_STORE"; : >"$D462_CALLS"; : >"$D462_SEQ"; }
d462_count() { jq 'length' "$D462_STORE"; }
# A comment attributed to someone else, or to me with a body of my choosing —
# how the "never mistaken for the engine's" cases are staged.
d462_seed() {  # d462_seed <login> <body>
  jq --arg u "$1" --arg b "$2" --arg at "2026-08-24T00:00:00Z" \
    '. + [{user:{login:$u}, body:$b, created_at:$at}]' "$D462_STORE" >"$D462_STORE.tmp"
  mv "$D462_STORE.tmp" "$D462_STORE"
}
D462_MARK_A="$_DECLINE_MARK — fx/repo#7 — unbuildable"
D462_MARK_B="$_DECLINE_MARK — fx/repo#7 — needs-ruling"
# Two bodies that differ only in the sentence a MODEL wrote. This is the whole
# reason an exact-body key could not be reused: two boxes reaching the same
# conclusion never phrase the deciding fact the same way.
D462_BODY_A="@triage this is not buildable as written.

$D462_MARK_A

The criterion asks for \`df\` output from a host no builder can reach."
D462_BODY_A2="@triage I cannot build this one.

$D462_MARK_A

Acceptance needs disk figures from the operator's own machine."
D462_BODY_B="@triage this needs a ruling first.

$D462_MARK_B

Which of the two payload paths ships is not decided anywhere on the board."

D462_PATH="$PATH"
PATH="$D462/bin:$PATH"
PO="$SHARED/bin/post-once.sh"
# ME is the engine's own login, set by duty.sh. It is supplied per call in a
# subshell rather than assigned here: this suite's earlier blocks already set ME
# inside subshells, and a top-level assignment would make every one of those a
# lost-modification finding — info-level, which crew's shellcheck job fails on.
d462_reason() { ( PATH="$D462/bin:$D462_PATH"; ME="$D462_ME"; DUTY_DIR="$D462"; _decline_reason "$@" ); }
d462_record() { ( PATH="$D462/bin:$D462_PATH"; ME="$D462_ME"; DUTY_DIR="$D462"; _record_declines "$@" ); }

# INVOCATIONS of a module function, not occurrences of its name: every line
# carrying it, less its own definition and less the comment lines that document
# it. The cardinality guards below are what let a bounded-region assertion mean
# "the call site" rather than "a call site", so what they count has to be the
# thing that can move the region — and a name in a comment cannot.
d462_uses() {  # d462_uses <function-name> — how many times $BMOD calls it
  grep -Fn -- "$1" "$BMOD" \
    | grep -v '^[0-9]*:[[:space:]]*#' \
    | grep -vc "^[0-9]*:$1() {"
}

# 1. THE DECLINE LANDS ON THE BOARD. Asserted from the store, which is the
# issue — the criterion says so in as many words.
d462_reset
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" "$D462_MARK_A" >/dev/null 2>&1
t d462-decline-lands-on-the-board 1 "$(d462_count)"

# The parked-review prompt uses this same four-argument marker contract. Drive
# the real helper so a stale three-argument usage assumption cannot rewrite D7.
d462_reset
D533_POST_MARK='<!-- duty:review-park:fx/repo#7@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->'
D533_POST_BODY="⏸ review parked at head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa — suite running
$D533_POST_MARK"
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D533_POST_BODY" "$D533_POST_MARK" >/dev/null 2>&1
t d533-park-marker-four-argument-contract 1 "$(d462_count)"
d462_reset
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" "$D462_MARK_A" >/dev/null 2>&1

# 2. A SECOND BOX ADDS NOTHING — same conclusion, a body a different model
# wrote. The marker is the key, so this is one comment.
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A2" "$D462_MARK_A" >/dev/null 2>&1
t d462-second-box-adds-nothing 1 "$(d462_count)"

# 3. A CHANGED CONCLUSION IS NOT SUPPRESSED. A different one of the four is a
# different key and posts.
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_B" "$D462_MARK_B" >/dev/null 2>&1
t d462-changed-conclusion-posts 2 "$(d462_count)"

# 4. MUST FAIL: THE MARKER DROPPED. The same two bodies through the 3-argument
# exact-body form is the spam case — two boxes, two comments — and it is why
# post-once.sh was extended rather than called as it stood.
d462_reset
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" >/dev/null 2>&1
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A2" >/dev/null 2>&1
t d462-unmarked-differing-bodies-double-post 2 "$(d462_count)"

# 5. The 3-argument form is otherwise UNCHANGED: an identical body still
# dedups. Every existing caller keys on this.
d462_reset
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" >/dev/null 2>&1
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" >/dev/null 2>&1
t d462-exact-body-form-still-dedups 1 "$(d462_count)"

# 6. An UNMARKED comment of mine — the same prose, no marker line — does not
# suppress. The marker is what suppresses it, which is what keeps a human's
# comment from being mistaken for the engine's.
d462_reset
d462_seed "$D462_ME" "@triage this is not buildable as written. I cannot get that evidence."
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" "$D462_MARK_A" >/dev/null 2>&1
t d462-unmarked-comment-does-not-suppress 2 "$(d462_count)"

# 7. The marker match is a WHOLE LINE, never a substring: ceremony#32's finding
# survives. A comment quoting the marker inside a sentence is not a decline.
d462_reset
d462_seed "$D462_ME" "I read \`$D462_MARK_A\` on a sibling board and disagree."
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_A" "$D462_MARK_A" >/dev/null 2>&1
t d462-marker-is-a-line-not-a-substring 2 "$(d462_count)"

# 8. FAIL CLOSED on a marker that is not a line of the body: a key absent from
# what gets posted matches nothing it wrote, which is a double-post on every
# call — the exact failure the script exists to prevent.
d462_reset
if DUTY_DIR="$D462" "$PO" fx/repo 7 "no marker in here" "$D462_MARK_A" >/dev/null 2>&1
then r1=POSTED; else r1=refused; fi
t d462-marker-absent-from-body-refused refused "$r1"
t d462-marker-absent-posts-nothing 0 "$(d462_count)"

# --- the engine reading the reason back ------------------------------------
# 9. My marker, one of the four: the reason travels off the board.
d462_reset
d462_seed "$D462_ME" "$D462_BODY_A"
t d462-reason-read-back unbuildable "$(d462_reason fx/repo 7)"

# 10. Someone else's marker is not my decline. A reviewer or a human writing
# the line must never become a fact the engine reports.
d462_reset
d462_seed other-bot "$D462_BODY_A"
t d462-foreign-marker-is-not-mine "" "$(d462_reason fx/repo 7)"

# 11. The reason set is CLOSED. A token outside the four is not a reason, so
# the operator's line can never be written by a session's free text.
d462_reset
d462_seed "$D462_ME" "x

$_DECLINE_MARK — fx/repo#7 — i-would-rather-do-another-one

y"
t d462-unknown-reason-token-rejected "" "$(d462_reason fx/repo 7)"

# 12. The marker is keyed on the ISSUE too: another issue's decline is not
# this one's.
d462_reset
d462_seed "$D462_ME" "$_DECLINE_MARK — fx/repo#9 — unbuildable"
t d462-other-issues-marker-not-read "" "$(d462_reason fx/repo 7)"

# 13. NEWEST WINS. A changed conclusion posts (case 3), so it must also
# govern, or the engine reports the superseded reason forever.
d462_reset
d462_seed "$D462_ME" "$D462_BODY_A"
DUTY_DIR="$D462" "$PO" fx/repo 7 "$D462_BODY_B" "$D462_MARK_B" >/dev/null 2>&1
t d462-newest-conclusion-governs needs-ruling "$(d462_reason fx/repo 7)"

# 14. No marker at all: no reason, and nothing invented.
d462_reset
d462_seed "$D462_ME" "just a normal comment"
t d462-no-marker-no-reason "" "$(d462_reason fx/repo 7)"

# --- _record_declines, beside the ledger commit ----------------------------
D462_SLUG="fx__repo"
D462_LEDGER_LINES="fx/repo#7 2026-08-25T00:00:00Z"
d462_reset
d462_seed "$D462_ME" "$D462_BODY_A"
: >"$D462_CALLS"
d462_record fx/repo "$D462_SLUG" "$D462_LEDGER_LINES"
t d462-record-writes-id-and-reason "fx/repo#7 unbuildable" \
  "$(cat "$D462/.declined-build.$D462_SLUG" 2>/dev/null)"

# 15. MUST FAIL: THE LEDGER WITHOUT THE COMMENT. An id being ledgered with no
# decline on the board records nothing — the whole finding is that a per-box
# file is not a record, so the ledger entry alone must satisfy nothing.
d462_reset
d462_record fx/repo "$D462_SLUG" "$D462_LEDGER_LINES"
if [ -e "$D462/.declined-build.$D462_SLUG" ]; then r1=WROTE; else r1=nothing; fi
t d462-ledger-without-comment-records-nothing nothing "$r1"

# 16. MUST FAIL: A DECLINE THAT MOVES THE LABEL. Asserted from the calls the
# path ISSUED, not from a final label set: a path that set a label and put it
# back would pass that reading, and this is the tempting implementation.
#
# The pattern must cover the idiom THIS module demotes with, not just the raw
# REST shapes: duty-builder.sh moves a label as `gh issue edit --add-label`
# (:512, :612), which matches no `-X VERB` and no `/labels` path, so a predicate
# spelled only in REST reads a demotion as silence. It is the same widening
# attention-timeout-gh-makes-no-writes already carries, plus PUT and the two
# REST paths, so nothing this predicate used to catch is dropped.
d462_reset
d462_seed "$D462_ME" "$D462_BODY_A"
: >"$D462_CALLS"
d462_record fx/repo "$D462_SLUG" "$D462_LEDGER_LINES" >/dev/null
t d462-decline-issues-no-mutation "" \
  "$(grep -E -- 'issue edit| -X (POST|PATCH|PUT|DELETE)|--add-|--remove-|/labels|/assignees' \
    "$D462_CALLS" | tr '\n' ' ')"
t d462-decline-reads-only 1 "$(grep -c 'issues/7/comments' "$D462_CALLS")"

# 17. The record is per repo, for the reason every other builder state file is:
# _builder_repo runs once per repo and one shared file makes each clobber the
# last (#345).
# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q '\.declined-build\.\$slug' "$BMOD"; then r1='per-repo'; else r1=SHARED; fi
t d462-record-file-is-per-repo per-repo "$r1"

# 18. It is keyed to the LEDGER COMMIT, not to the enumerated board: the caller
# hands over exactly what ledger_commit is given, so the two records can never
# disagree about which ids the session left behind (#264).
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if awk_range_grep_Fq '/_record_declines "\$R" "\$slug" "\$ready_commit"/,/ledger_commit "\$DUTY_DIR\/.seen-build"/' \
  "$BMOD" 'ledger_commit'; then r1='beside-the-commit'; else r1=DETACHED; fi
t d462-record-keyed-to-ledger-commit beside-the-commit "$r1"

# 19. A recorded id that has left the board is not a live decline. Without the
# intersection the last session's record would outlive the issue itself.
printf 'fx/repo#7 unbuildable\nfx/repo#8 needs-ruling\n' >"$D462/.declined-build.$D462_SLUG"
t d462-declines-intersect-the-board "unbuildable" \
  "$(DUTY_DIR="$D462"; _declined_for_board "$D462_SLUG" "fx/repo#7 2026-08-25T00:00:00Z" | tr '\n' ' ' | sed 's/ $//')"
t d462-declines-empty-board-none "" \
  "$(DUTY_DIR="$D462" _declined_for_board "$D462_SLUG" "")"
rm -f "$D462/.declined-build.$D462_SLUG"

PATH="$D462_PATH"

# --- the no-duty line names the CAUSE, not the mechanism (D3) --------------
# 20. One declined and one genuinely ledger-held: the line distinguishes them,
# because a decline is triage's to repair and a ledger hold is not.
t d462-nbd-declined-and-held \
  '1 ready held by seen-ledger, 1 ready declined: unbuildable (1)' \
  "$(_no_build_duty_reason 2 0 "" 1 'unbuildable')"
# 21. Everything declined: no ledger half to report.
t d462-nbd-all-declined \
  '4 ready declined: unbuildable (3), needs-ruling (1)' \
  "$(_no_build_duty_reason 4 0 "" 1 'unbuildable
needs-ruling
unbuildable
unbuildable')"
# 22. Canonical reason order, not input order and not count order, so two log
# lines differ only when something actually changed.
t d462-nbd-summary-canonical-order \
  '2 ready declined: out-of-scope (1), operator-owned (1)' \
  "$(_no_build_duty_reason 2 0 "" 1 'operator-owned
out-of-scope')"
# 23. The rounds half is not lost when a decline is reported.
t d462-nbd-declined-keeps-rounds \
  '1 ready declined: unbuildable (1), 2 round(s) held by seen-ledger' \
  "$(_no_build_duty_reason 1 2 "" 1 'unbuildable')"
# 24. The slot still outranks it: the slot is the answer to "why did the claim
# not happen" whenever it fired (#345), and D3 leaves that branch alone.
t d462-nbd-slot-still-outranks \
  'slot held by fx/repo#12; board holds 3 ready' \
  "$(_no_build_duty_reason 3 0 "fx/repo#12" 1 'unbuildable')"

# 25. WITH NONE DECLINED THE WORDING IS BYTE-IDENTICAL TO TODAY'S. Every
# existing branch, spelled out — the criterion is byte-identity, so the
# assertion is the bytes and not a shape.
t d462-nbd-unchanged-ready-and-rounds '2 ready, 1 round(s) held by seen-ledger' \
  "$(_no_build_duty_reason 2 1 "" 1)"
t d462-nbd-unchanged-ready '3 ready held by seen-ledger' \
  "$(_no_build_duty_reason 3 0 "" 1)"
t d462-nbd-unchanged-rounds '1 round(s) held by seen-ledger' \
  "$(_no_build_duty_reason 0 1 "" 1)"
t d462-nbd-unchanged-board-empty 'board empty' "$(_no_build_duty_reason 0 0 "" 1)"
t d462-nbd-unchanged-board-unread 'board unread' "$(_no_build_duty_reason 0 0 "" 0)"
t d462-nbd-unchanged-slot 'slot held by fx/repo#12; board holds 3 ready' \
  "$(_no_build_duty_reason 3 0 "fx/repo#12" 1)"
# 26. An EMPTY declined argument is the same as none: the read side hands over
# whatever the intersection produced, which is routinely nothing.
t d462-nbd-empty-declined-is-none '3 ready held by seen-ledger' \
  "$(_no_build_duty_reason 3 0 "" 1 '')"

# 27. AND THE READER IS WIRED TO IT. Every assertion above calls the renderer
# with a hand-built argument; none of them observes the engine supplying one.
# Replacing the 5th argument at the call site with "" left the whole suite
# green while D3 vanished from the running engine — the operator back to
# reading `2 ready held by seen-ledger`, the wrong noun this issue exists to
# remove, and 2605 assertions saying nothing was wrong. The write side has had
# this guard since test 18; the read side is the operator-facing half.
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if awk_range_grep_Fq '/no build duty \(\$\(_no_build_duty_reason/,/\)\)"$/' "$BMOD" \
  '_declined_for_board "$slug" "$ready_items"'; then r1=wired; else r1=DETACHED; fi
t d462-nbd-call-site-passes-the-declines wired "$r1"
# The guard above says "the call site" — a fact it does not itself hold. A
# SECOND, unwired invocation added later leaves it green and puts the wrong
# noun back in front of the operator on whichever branch reaches it; pinning
# the cardinality is what makes the assertion mean what it reads as.
#
# Counted as invocations, not as command substitutions. Spelled `$(_no_build…`
# — the form this guard shipped with — it held "appears as a substitution
# once", which is narrower than the sentence above it: a forwarding wrapper
# (`_w() { _no_build_duty_reason "$@"; }`) walked past it at 715/0
# (claude-bot, round 3). Same overstatement the rounds keep finding, so it is
# closed here rather than left standing beside its blocking twin at 33c.
t d462-nbd-has-one-call-site 1 "$(d462_uses _no_build_duty_reason)"

# --- the prompt: the decline has a WRITTEN ROUTE (D1/D5) -------------------
# 28. The four reasons reach the session. Before this change they existed only
# in a source comment addressed to whoever reads duty-builder.sh, in a file the
# session never opens — which is the defect, so this is the first must-fail.
D462_PROMPT="$SHARED/prompts/build.txt"
# Read as RENDERED, not as the template: the session is handed the filled text,
# and a slot that is never supplied is a prompt that names nothing. (The render
# site's own slot coverage is the guard above; this reads what comes out of it.)
D462_RENDERED="$(PROMPTS_DIR="$SHARED/prompts" render_prompt build.txt \
  ME=fixture-builder REPO=fx/repo TRIAGE=fixture-triage CLAIM=/duty/bin/claim-issue.sh \
  POST_ONCE=/duty/bin/post-once.sh \
  DECLINE_MARK="$_DECLINE_MARK" DECLINE_REASONS="$_DECLINE_REASONS" \
  HEAD_CHECKS=- WT_RULES=- ROUND_RULES=- ONESHOT_RULES=-)"
r1=all
for reason in out-of-scope unbuildable needs-ruling operator-owned; do
  grep -Fq -- "$reason" <<<"$D462_RENDERED" || r1="MISSING:$reason"
done
t d462-prompt-names-all-four-reasons all "$r1"
# The set the prompt is handed is the set the reader validates against: one
# constant, rendered into the prompt, so the writer and the reader cannot drift.
t d462-prompt-reasons-are-the-engines-set "out-of-scope unbuildable needs-ruling operator-owned" \
  "$_DECLINE_REASONS"
if grep -Fq '{{DECLINE_REASONS}}' "$D462_PROMPT" \
  && grep -Fq '{{DECLINE_MARK}}' "$D462_PROMPT"; then r1=slotted; else r1=HARDCODED; fi
t d462-prompt-mark-and-reasons-are-slots slotted "$r1"

# 29. The route is post-once.sh with a MARKER — the 4-argument form. A decline
# told to post with a bare `gh` would be the spam case of test 4 on every box.
if grep -Fq '{{POST_ONCE}} {{REPO}} <issue-number> "<body>" "<marker>"' "$D462_PROMPT"
then r1='marker-form'; else r1=UNKEYED; fi
t d462-prompt-routes-through-post-once-with-marker marker-form "$r1"

# 30. The marker the prompt tells the session to write is the prefix the engine
# reads back. Two literals that must agree is how a writer and a reader drift,
# so the reader's own renderer is asserted against the prompt's template.
t d462-marker-key-matches-prompt-template "$_DECLINE_MARK — fx/repo#7 — " \
  "$(_decline_marker_key fx/repo 7)"
if grep -Fq '{{DECLINE_MARK}} — {{REPO}}#<issue-number> — <reason>' "$D462_PROMPT"
then r1=agreed; else r1=DRIFTED; fi
t d462-prompt-marker-template-matches-reader agreed "$r1"
# And the same thing end to end: the line the RENDERED prompt tells the session
# to write, with the issue number filled in, is byte-identical to the prefix
# _decline_reason keys on. This is the assertion that actually catches a drift.
if grep -Fq "$(_decline_marker_key fx/repo '<issue-number>')<reason>" <<<"$D462_RENDERED"
then r1=agreed; else r1=DRIFTED; fi
t d462-rendered-marker-is-the-readers-key agreed "$r1"

# 31. D4 reaches the session too: a decline is not a claim and moves no label.
r1=stated
grep -Fq 'DECLINE IS NOT A CLAIM AND MOVES NO LABEL' "$D462_PROMPT" || r1=SILENT
grep -Fq 'assigns nobody' "$D462_PROMPT" || r1=SILENT
t d462-prompt-says-decline-moves-no-label stated "$r1"
# The comment is the deliverable, so the mention that makes it triage's input
# is not optional either.
if grep -Fq '@-mention {{TRIAGE}}' "$D462_PROMPT"; then r1=mentions; else r1=SILENT; fi
t d462-prompt-decline-mentions-triage mentions "$r1"

# 32. D5: the clause must not make declining attractive. The claim imperative
# survives, and shopping the board is refused by name.
if grep -Fq 'pick ONE ready unclaimed issue, claim it' "$D462_PROMPT"
then r1=intact; else r1=WEAKENED; fi
t d462-prompt-claim-imperative-intact intact "$r1"
if grep -Fq 'I would rather do a different one' "$D462_PROMPT"
then r1=refused; else r1=OPEN; fi
t d462-prompt-shopping-refused-by-name refused "$r1"

# 33. D6/D4: the claim path does not change. The decline never runs it — this
# half is the claim path only; the label half is 33b, below.
if awk_range_grep_Fq '/^_record_declines\(\)/,/^}/' "$BMOD" 'claim-issue.sh'; then
  r1=CLAIMS
elif awk_range_grep_Fq '/^_decline_reason\(\)/,/^}/' "$BMOD" 'claim-issue.sh'; then
  r1=CLAIMS
else
  r1='no-claim-path'
fi
t d462-decline-machinery-never-claims no-claim-path "$r1"

# 33b. D4's other half, read as SOURCE rather than as issued calls. Test 16 asks
# whether a mutation was handed to gh on the path the fixture drives, which is
# the right question and the only one that catches a write the source spells
# indirectly — but it can only see a branch `d462_record` actually walks. A
# demotion behind a condition the fixture never reaches stays invisible to it.
# So 16 and 33b are a pair, and neither means what it says alone.
#
# What 33b holds is bounded by its POPULATION: the two function bodies below,
# and nothing else. The engine's own decline block is a third site and 33c is
# what covers it — say "the decline machinery" of these two guards together,
# never of either one (codex-bot, round 3).
r1='no-label-write'
for d462_range in '/^_record_declines\(\)/,/^}/' '/^_decline_reason\(\)/,/^}/'; do
  for d462_needle in '--add-label' '--remove-label' '--add-assignee' '/labels' '/assignees'; do
    if awk_range_grep_Fq "$d462_range" "$BMOD" "$d462_needle"; then
      r1="WRITES:$d462_needle"
    fi
  done
done
t d462-decline-machinery-writes-no-label no-label-write "$r1"

# 33c. D4's THIRD site — the engine's own decline block, which 16 and 33b both
# structurally miss. Test 16 drives `_record_declines` directly (`d462_record`),
# so the fixture's gh never sees a call `_builder_repo` issues; 33b reads source
# over a hand-listed pair of function bodies, and the block that CALLS them is
# in neither. A `gh issue edit --remove-label ready --add-label needs-spec`
# dropped immediately after `_record_declines` is a decline-path demotion in
# the very idiom round 2 widened test 16 to catch, and the suite stayed at
# 715 passed / 0 failed (codex-bot, round 3).
#
# The region is the one the reviewer named: the post-session ready re-query and
# the decline recording, through the ledger commit they are keyed to. Its start
# anchor is the block's `local` line rather than its `if`, because
# `[ "${RUN_SESSION_RC:-1}" -eq 0 ]` occurs three times in the module and an
# awk range opening on the earliest would swallow the rounds branch — coverage
# bought by asserting over code this criterion says nothing about.
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
D462_CALL_SITE='/local ready_commit="" ready_reread=1/,/ledger_commit "\$DUTY_DIR\/\.seen-build"/'
r1='no-label-write'
for d462_needle in '--add-label' '--remove-label' '--add-assignee' '/labels' '/assignees'; do
  if awk_range_grep_Fq "$D462_CALL_SITE" "$BMOD" "$d462_needle"; then
    r1="WRITES:$d462_needle"
  fi
done
t d462-decline-call-site-writes-no-label no-label-write "$r1"

# 33d. AND THE REGION HAS TO BE A REGION. An awk range whose start anchor drifts
# matches nothing, a grep over nothing finds nothing, and 33c reports
# no-label-write over an empty string — this round's defect wearing a different
# hat, and the reason a silent guard is worse than an absent one. So assert the
# region actually contains the call it claims to bound.
# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if awk_range_grep_Fq "$D462_CALL_SITE" "$BMOD" '_record_declines "$R" "$slug"'; then
  r1=bounded
else
  r1=EMPTY
fi
t d462-decline-call-site-region-holds-the-call bounded "$r1"

# 33e. And 33c reads as "the decline call site" — a fact it does not itself
# hold. A SECOND `_record_declines` invocation elsewhere in the module sits
# outside that bounded region, so 33c would stay green over a region that no
# longer covers the machinery, and 33d would still find its call. Pinning the
# cardinality is what makes the other two mean what they read as — the same
# logic as test 27's, applied to the write side.
t d462-record-declines-has-one-call-site 1 "$(d462_uses _record_declines)"

# 34. THE LEDGER STILL RECORDS THE DECLINE. The board comment is the record
# that survives the box; the ledger is what stops the engine PAYING for the
# same discovery every five minutes, and #462 replaces neither with the other.
# A declined id — still pickable after the session — is still committed.
d462_reset
d462_seed "$D462_ME" "$D462_BODY_A"
t d462-declined-id-still-ledgered "fx/repo#7 2026-08-25T00:00:00Z" \
  "$(_ready_lines_to_commit "$D462_LEDGER_LINES" "fx/repo#7")"
d462_record fx/repo "$D462_SLUG" "$D462_LEDGER_LINES"
t d462-ledger-and-reason-agree "fx/repo#7 unbuildable" \
  "$(cat "$D462/.declined-build.$D462_SLUG" 2>/dev/null)"

# 35. A CLAIM STILL WORKS UNCHANGED, and leaves no decline anywhere. A claimed
# id is no longer pickable, so #264's rule commits nothing — and the reason
# record follows the commit, so a stale decline from a previous tick is cleared
# rather than left to be reported against an issue now being built.
d462_reset
# Seeded with a PREVIOUS box's decline on this very issue, so the comment count
# below can tell a path that posts from one that does not: against a store
# d462_reset has just emptied, `0` is also what an assertion that never ran
# reads, which is coverage it is not (claude-bot, round 1). Seeded, the claim
# path reads 1 and a path that posted would read 2.
d462_seed "$D462_ME" "$D462_BODY_A"
t d462-claimed-id-commits-nothing "" \
  "$(_ready_lines_to_commit "$D462_LEDGER_LINES" "")"
d462_record fx/repo "$D462_SLUG" ""
if [ -e "$D462/.declined-build.$D462_SLUG" ]; then r1=STALE; else r1=cleared; fi
t d462-claim-clears-the-decline-record cleared "$r1"
t d462-claim-leaves-no-decline-comment 1 "$(d462_count)"

# 36. COULD NOT LOOK IS NOT NOTHING TO RECORD — the contrast with the clearing
# directly above. Same empty set, but #264's re-query-failed path reaches it
# without having read the board, and unlinking there costs the reasons for the
# ids EARLIER ticks already ledgered: those stay held, the marker dedup will
# not re-post an unchanged conclusion, and the operator silently drops back to
# `N ready held by seen-ledger` — this issue's own defect, fired by an API blip
# rather than a missing wire. The record survives; the intersection with the
# live board, not this write, is what stops it going stale (claude-bot, r1).
printf 'fx/repo#7 unbuildable\n' >"$D462/.declined-build.$D462_SLUG"
d462_record fx/repo "$D462_SLUG" "" 0
t d462-unread-board-keeps-the-record "fx/repo#7 unbuildable" \
  "$(cat "$D462/.declined-build.$D462_SLUG" 2>/dev/null)"
# And a board that WAS read still clears on the empty set: the whole-set write
# is the reason a stale reason cannot linger, and 36 must not buy 35's job.
d462_record fx/repo "$D462_SLUG" "" 1
if [ -e "$D462/.declined-build.$D462_SLUG" ]; then r1=STALE; else r1=cleared; fi
t d462-read-board-with-nothing-still-clears cleared "$r1"
# The flag is only worth having if the call site sets it from the re-query it
# actually performed, and says 0 on exactly the branch that could not look.
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if awk_range_grep_Fq '/_record_declines "\$R" "\$slug" "\$ready_commit"/,/ledger_commit "\$DUTY_DIR\/.seen-build"/' \
  "$BMOD" '"$ready_reread"'; then r1=told; else r1=UNTOLD; fi
t d462-record-told-whether-the-board-was-read told "$r1"
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if awk_range_grep_Fq '/if post_ready_json=/,/post-session ready re-query failed/' \
  "$BMOD" 'ready_reread=0'; then r1=marked; else r1=SILENT; fi
t d462-failed-reread-marks-itself marked "$r1"

# --- #479: the resume comment splice does not travel on argv --------------
#
# _resume_attach_comments handed a PR's whole thread to jq as ONE argv element,
# bounded by MAX_ARG_STRLEN (131,072) and not by ARG_MAX. Past that the execve
# failed, the swallow left the listing unchanged, and the PR reached the
# predicates with `.comments` ABSENT — a skip that never cleared, because a
# thread never shrinks. Fixtures, never a live box: no gh, no network.
D479="$TMP/d479"; mkdir -p "$D479/bin"
export D479_CALLS="$D479/gh-calls"
D479_BIG="$D479/big-thread.json"
export D479_BIG
# 120 comments of 2 KiB. The size is the point, so it is asserted rather than
# assumed: a fixture that drifted under the limit would still pass every
# assertion below while testing nothing.
jq -cn '[range(0;120) as $i
         | {author:{login:"me"}, body:("x"*2000),
            createdAt:"2026-08-01T00:00:00Z", id:($i|tostring)}]' >"$D479_BIG"
D479_SIZE="$(wc -c <"$D479_BIG" | tr -d ' ')"
if [ "$D479_SIZE" -gt 131072 ]; then r1=over; else r1=UNDER; fi
t d479-fixture-exceeds-the-argv-limit over "$r1"

# Every gh call recorded rather than made, so a label write on this path would
# be visible even though the guard above already forbids one.
cat >"$D479/bin/gh" <<'D479GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$D479_CALLS"
D479GH
chmod +x "$D479/bin/gh"
export D479_ALERTS="$D479/alerts"
# The receipt half of the escalation (AC5). BIN_DIR is $DUTY_DIR/bin, and
# d479_run sets DUTY_DIR here, so the real post-once.sh is replaced by a
# recorder without the module being told anything: a stub that RECORDS is what
# keeps d479-structural-writes-no-label's zero-gh-calls reading meaning what it
# says — the real script would call gh twice for its own dedup and that count
# would stop being about label writes at all.
export D479_RECEIPTS="$D479/receipts"
cat >"$D479/bin/post-once.sh" <<'D479PO'
#!/usr/bin/env bash
printf 'post-once %s %s %s\n' "$1" "$2" "$3" >>"$D479_RECEIPTS"
exit "${D479_PO_RC:-0}"
D479PO
chmod +x "$D479/bin/post-once.sh"

d479_listing() {  # d479_listing <head> <body>
  jq -cn --arg head "$1" --arg body "$2" \
    '[{number:311, isDraft:false, headRefOid:$head, body:$body}]'
}
D479_HEAD="cafebabecafebabecafebabecafebabecafebabe"
D479_HEAD2="feedfacefeedfacefeedfacefeedfacefeedface"
D479_BODY="Closes #479

The splice is the subject."
D479_PATH="$PATH"

# Driven in a child shell with the stub first on PATH, the near-miss block's
# reason: a fixture calling an engine function directly drags the engine's own
# dataflow into this file's static analysis. `_resume_pr_comments` is overridden
# there rather than stubbed through gh, because the classification under test is
# exactly "the read succeeded and the fold did not", which no gh exit code can
# express — `ok` reads the fixture, `transient` fails the read, `structural`
# returns cleanly with a payload jq cannot fold.
d479_run() {  # d479_run <mode> <listing> <log> -> the spliced listing on stdout
  local d479_mode="$1" d479_pr="$2" d479_log="$3"
  : >"$d479_log"
  PATH="$D479/bin:$D479_PATH" D479_MODE="$d479_mode" DUTY_DIR="$D479" \
    LABEL_ATTENTION=attention \
    bash -c 'set -uo pipefail
      # shellcheck disable=SC1090
      source "$1/lib/common.sh"
      # shellcheck disable=SC1090
      source "$1/lib/duty-builder.sh"
      _resume_pr_comments() {
        case "$D479_MODE" in
          ok) cat "$D479_BIG" ;;
          transient) return 1 ;;
          structural) printf "not json" ;;
        esac
      }
      # The breaker module suite shape: alert is a function here, so the
      # operator channel is observable without a token, a chat id, or curl.
      alert() { printf "%s\n" "$1" >>"$D479_ALERTS"; }
      _resume_attach_comments fx/repo "$2" >"$3" 2>&1
      printf "%s" "$RESUME_LISTING"' \
    d479_run "$SHARED" "$d479_pr" "$d479_log"
}
d479_reset() { : >"$D479_CALLS"; : >"$D479_ALERTS"; : >"$D479_RECEIPTS"
  rm -f "$D479"/.seen-resume-structural "$D479"/.suppressed-resume-structural.*; }
d479_calls() { awk 'NF' "$D479_CALLS" | wc -l | tr -d ' '; }
d479_alerts() { awk 'NF' "$D479_ALERTS" | wc -l | tr -d ' '; }
d479_receipts() { awk 'NF' "$D479_RECEIPTS" | wc -l | tr -d ' '; }

# AC1 — the 200 KiB thread is spliced whole and reaches the predicates present.
d479_reset
D479_OK="$(d479_run ok "$(d479_listing "$D479_HEAD" "$D479_BODY")" "$D479/ok.log")"
t d479-large-thread-splices-whole 120 \
  "$(printf '%s' "$D479_OK" | jq -r '.[0].comments | length')"
if [ "$(printf '%s' "$D479_OK" | jq -r '.[0].comments | type')" = array ]; then
  r1=present
else
  r1=DROPPED
fi
t d479-large-thread-reaches-predicates-present present "$r1"
t d479-large-thread-warns-about-nothing 0 "$(grep -c 'WARN' "$D479/ok.log")"
t d479-large-thread-escalates-nothing 0 "$(d479_alerts)"

# The premise, measured rather than asserted: the OLD argv route refuses this
# same fixture. This is what gives the case above teeth — reinstate --argjson
# and the splice goes empty, which is the test plan's first must-fail.
if printf '%s' "$(d479_listing "$D479_HEAD" "$D479_BODY")" \
   | jq -c --argjson num 311 --argjson comments "$(cat "$D479_BIG")" \
       'map(if .number == $num then . + {comments:$comments} else . end)' \
       >/dev/null 2>&1; then
  r1=SPLICED
else
  r1=refused
fi
t d479-argv-route-refuses-the-same-fixture refused "$r1"
# ...and the module does not use that route. A behavioural case cannot see a
# payload that happens to fit, so the shape is asserted too. CODE, not prose: the
# header above the function names the old form in order to explain it, and a
# guard that read comments would be satisfied by deleting the explanation.
d479_code() { grep -v '^[[:space:]]*#' "$BMOD"; }
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if grep -Fq -- '--argjson comments' <<<"$(d479_code)"; then r1=ON-ARGV; else r1=off-argv; fi
t d479-splice-payload-is-not-on-argv off-argv "$r1"
# shellcheck disable=SC2016  # matching the module's literals, not expanding them
if grep -Fq -- '--slurpfile comments' <<<"$(d479_code)"; then r1=slurped; else r1=MISSING; fi
t d479-splice-payload-is-slurped slurped "$r1"

# AC2 — a transient read failure still skips the PR for the tick, unchanged...
d479_reset
D479_TR="$(d479_run transient "$(d479_listing "$D479_HEAD" "$D479_BODY")" "$D479/tr.log")"
t d479-transient-skips-the-pr null \
  "$(printf '%s' "$D479_TR" | jq -r '.[0].comments')"
# ...and says so...
if grep -Fq 'comment read failed' "$D479/tr.log"; then r1=warned; else r1=SILENT; fi
t d479-transient-warns warned "$r1"
# ...and is NEVER escalated. The test plan's third must-fail: a transient failure
# reaching the operator is the over-correction this classification exists to
# refuse, and zero alerts is the only reading of it.
t d479-transient-escalates-nothing 0 "$(d479_alerts)"
# ...and posts NOTHING, which is the half of AC5 that keeps the receipt
# affordable: a comment on every transient `gh` hiccup would be its own defect,
# and the discriminator is the only thing standing between the two.
t d479-transient-posts-no-receipt 0 "$(d479_receipts)"

# AC4 (as ruled by triage, 2026-08-26) — a structural failure warns and escalates
# to the operator on the alert channel, naming the PR, the head and the
# AUTHORIZING ISSUE as where a human would set `attention`. The engine does not
# write that label anywhere on this path: the demand flag is hand-set doctrine
# (LABELS.md, shared/prompts/attention.txt) held by
# engine-never-writes-attention-label above.
d479_reset
D479_ST="$(d479_run structural "$(d479_listing "$D479_HEAD" "$D479_BODY")" "$D479/st.log")"
t d479-structural-skips-the-pr null \
  "$(printf '%s' "$D479_ST" | jq -r '.[0].comments')"
if grep -Fq 'comment splice failed' "$D479/st.log"; then r1=warned; else r1=SILENT; fi
t d479-structural-warns warned "$r1"
t d479-structural-escalates-once 1 "$(d479_alerts)"
t d479-structural-writes-no-label 0 "$(d479_calls)"
# The alert names the issue a human would flag, and the PR it is about.
if grep -Fq 'set attention on fx/repo#479' <<<"$(cat "$D479_ALERTS")" &&
   grep -Fq 'fx/repo#311' <<<"$(cat "$D479_ALERTS")"; then r1=named; else r1=VAGUE; fi
t d479-structural-alert-names-the-issue named "$r1"

# AC5 (@danmt, 2026-08-26) — THE ALERT IS THE WAKE, THE RECEIPT IS THE RECORD.
# alert() is a silent no-op returning success with no token file and a
# ten-second best-effort with one, so nothing downstream can tell a delivered
# escalation from a dropped one. Survivable for every other alert in the tree,
# because those name conditions that re-fire; not here, where the ledger's
# once-per-head makes one lost message a permanently lost escalation.
t d479-structural-posts-a-receipt 1 "$(d479_receipts)"
# It carries the SAME facts as the alert, on the PR: the number acted on, the
# head it is about — full, because that is what post-once.sh's exact-body dedup
# keys on — and where a human would set the demand.
D479_RC="$(cat "$D479_RECEIPTS")"
if grep -Fq 'post-once fx/repo 311 ' <<<"$D479_RC" &&
   grep -Fq "$D479_HEAD" <<<"$D479_RC" &&
   grep -Fq 'set attention on fx/repo#479' <<<"$D479_RC"; then r1=named; else r1=VAGUE; fi
t d479-receipt-names-the-pr-the-head-and-the-issue named "$r1"

# ONCE PER HEAD — #167's rule: an escalation that repeats every five minutes is
# wallpaper, and it is the operator's channel being spent.
d479_run structural "$(d479_listing "$D479_HEAD" "$D479_BODY")" "$D479/st2.log" >/dev/null
t d479-structural-does-not-re-escalate-the-same-head 1 "$(d479_alerts)"
# The receipt is gated by the same ledger and not by post-once.sh's dedup: the
# call is never made a second time at this head, so the durable half costs one
# comment per head even where the exact-body check is not what stops it.
t d479-receipt-is-not-reposted-at-the-same-head 1 "$(d479_receipts)"
# The quiet is not a silence: the standing condition is still reported.
if grep -Fq 'still standing at head' "$D479/st2.log"; then r1=reported; else r1=SILENT; fi
t d479-structural-suppression-is-reported reported "$r1"
# A new head is a tree that changed, so the condition is re-asserted against it.
d479_run structural "$(d479_listing "$D479_HEAD2" "$D479_BODY")" "$D479/st3.log" >/dev/null
t d479-structural-re-escalates-on-a-new-head 2 "$(d479_alerts)"
t d479-receipt-follows-the-new-head 2 "$(d479_receipts)"

# A body naming no authorizing issue still escalates — the PR number is enough to
# act on — and says that the reference is missing rather than going quiet or
# guessing an issue.
d479_reset
d479_run structural "$(d479_listing "$D479_HEAD" "no reference here")" "$D479/st4.log" >/dev/null
t d479-structural-without-an-issue-still-escalates 1 "$(d479_alerts)"
if grep -Fq 'names no authorizing issue' "$D479/st4.log"; then r1=said; else r1=SILENT; fi
t d479-structural-without-an-issue-says-so said "$r1"
# The receipt reaches that branch too, and says the same thing the alert does —
# the operator named this branch explicitly, and it is covered by construction:
# both messages interpolate the one `where` clause, so there is no second code
# path here to drift.
t d479-receipt-without-an-issue-is-still-posted 1 "$(d479_receipts)"
if grep -Fq 'names no authorizing issue' <<<"$(cat "$D479_RECEIPTS")"; then
  r1=said
else
  r1=SILENT
fi
t d479-receipt-without-an-issue-says-so said "$r1"

# D2 GOVERNS THE NEW BRANCH TOO, and this one is driven rather than counted.
# d479-every-failure-branch-warns is scoped to _resume_attach_comments's region,
# so it cannot see a warn dropped from the escalation — and it did not: deleting
# this warn survived the whole suite before this case existed. A receipt that
# does not post is the case where the alert is the ONLY copy, which is precisely
# when the log line is worth having.
d479_reset
export D479_PO_RC=1
d479_run structural "$(d479_listing "$D479_HEAD" "$D479_BODY")" "$D479/st5.log" >/dev/null
unset D479_PO_RC
if grep -Fq 'receipt did not post' "$D479/st5.log"; then r1=warned; else r1=SILENT; fi
t d479-receipt-failure-warns warned "$r1"
# ...and the wake still fires. The record failing must not take the alert with
# it: they are two objects for exactly this reason.
t d479-receipt-failure-still-alerts 1 "$(d479_alerts)"

# D2 — EVERY failure branch on this path warns, including the fallback that
# cannot even mark the thread unread. That third branch is not reachable from a
# fixture without breaking jq itself, so the region is counted: three failure
# warns, and a warn removed from any of them fails this.
t d479-every-failure-branch-warns 3 \
  "$(awk '/^_resume_attach_comments\(\) \{$/,/^\}$/' "$BMOD" | grep -c 'warn "')"
# ...and the swallows are counted beside them, because the warn count alone does
# NOT close the property the pair is here for. Counting warns catches a warn
# taken away; it cannot catch one that was never written, since an appended
# `|| spliced=""` with no warn leaves the count at three and passes. Pinning
# both numbers closes THIS SWALLOW SPELLING — the `||`-fallback-to-empty the
# defect was written in: adding one moves this count, and warning about it moves
# the other. The pair is textual and is not claimed to be more: a block-form
# swallow (`if ! spliced="$(…)"; then spliced=""; fi`) moves neither counter.
# That is a known and accepted limit, not an oversight — a region count cannot
# be made airtight, and every branch this function actually has warns, which is
# what AC3 asks.
t d479-no-swallow-goes-unwarned 2 \
  "$(awk '/^_resume_attach_comments\(\) \{$/,/^\}$/' "$BMOD" | grep -c '||.*=""')"

# THE ISSUE-REF PATTERN HAS ONE DEFINITION. The escalation and the fingerprints
# must agree about which issue a PR answers, and a second copy would drift
# silently — both parse, only one is right.
t d479-issue-ref-pattern-defined-once 1 \
  "$(grep -Fc -- 'closes|refs|fixes|resolves' "$BMOD")"
# ...and the hoist did not change what it answers. The tab form and the
# `discloses #99` word boundary are the two cases the original comment names.
D479_FP="$(jq -cn '[{number:1,isDraft:true,headRefOid:"aaa",body:"Closes #479"},
                    {number:2,isDraft:true,headRefOid:"bbb",body:"Refs\t#480"},
                    {number:3,isDraft:true,headRefOid:"ccc",body:"the operator discloses #99 in passing"},
                    {number:4,isDraft:true,headRefOid:"ddd",body:"Part of owner/repo#77"}]' \
  | _resume_pr_fingerprints fx/repo | awk -F'\t' '{printf "%s ", ($2 == "" ? "-" : $2)}')"
t d479-issue-ref-hoist-preserves-answers "479 480 - - " "$D479_FP"

PATH="$D479_PATH"
unset D479_MODE

# --- #502: the round cap the engine counts and never cuts -------------------
#
# Doctrine gives the engine one half of the rule and forbids it the other:
# "nothing counts rounds for you, nothing enforces the cut … Where an engine
# does count and says the boundary is here, that is instruction and never
# performance." So these cases pin two things that a later change could quietly
# swap — that the count is right, and that counting is ALL the engine does.
RC_JQ="$SHARED/lib/jq/round-cap.jq"
RC_PANEL='["rev-a","rev-b"]'
# A DUTY_DIR of its own: the census writes a seen-ledger, and the fixtures that
# borrow "$SHARED" as DUTY_DIR only ever read jq out of it. The symlink gives
# the real programs without giving the real tree somewhere to be written to.
RC_DUTY="$TMP/round-cap-duty"
mkdir -p "$RC_DUTY/lib"
ln -sfn "$SHARED/lib/jq" "$RC_DUTY/lib/jq"

# rc_build FULL [OPEN] [PUSHED] [LAST_VERDICT] — a pullRequest payload carrying
# FULL rounds that both panelists voted in; OPEN=1 adds one more round with a
# single verdict in it (a round that has opened and not closed); PUSHED=1 adds a
# commit after the last verdict, which is the head the builder's round fixes
# land on. The locals are `rc_`-prefixed because shellcheck reads this whole
# file in one namespace: a local named `full` turns an unrelated `r1=full-budget`
# five hundred lines up into an arithmetic expression and SC2100. Commit i is committed at 10:00 and reviewed at 12:00 the same day,
# so no verdict is re-pointed and the partition is the plain one.
#
# LAST_VERDICT is rev-a's state in the FULL-th round, defaulting to
# CHANGES_REQUESTED — rev-b always approves, so the default builds a round that
# closed WITHOUT full approval. Passing APPROVED builds the terminal shape the
# round-1 panel found uncovered: a fifth round that closed UNANIMOUSLY, where the
# cut must not fire. It is a parameter rather than a second builder because every
# existing case must keep driving the byte-identical payload it drove before.
rc_build() {
  local rc_full="$1" rc_open="${2:-0}" rc_pushed="${3:-0}" rc_last="${4:-CHANGES_REQUESTED}"
  local i oid ts st
  local commits="" reviews="" head=""
  for ((i = 1; i <= rc_full + rc_open + rc_pushed; i++)); do
    oid="$(printf 'c%039d' "$i")"
    ts="$(printf '2026-08-%02dT10:00:00Z' "$i")"
    commits="$commits{\"commit\":{\"oid\":\"$oid\",\"committedDate\":\"$ts\"}},"
    head="$oid"
  done
  for ((i = 1; i <= rc_full; i++)); do
    oid="$(printf 'c%039d' "$i")"
    ts="$(printf '2026-08-%02dT12:00:00Z' "$i")"
    if [ "$i" -eq "$rc_full" ]; then st="$rc_last"; else st=CHANGES_REQUESTED; fi
    reviews="$reviews{\"author\":{\"login\":\"rev-a\"},\"state\":\"$st\",\"commit\":{\"oid\":\"$oid\"},\"submittedAt\":\"$ts\"},"
    reviews="$reviews{\"author\":{\"login\":\"rev-b\"},\"state\":\"APPROVED\",\"commit\":{\"oid\":\"$oid\"},\"submittedAt\":\"$ts\"},"
  done
  if [ "$rc_open" -eq 1 ]; then
    i=$((rc_full + 1))
    oid="$(printf 'c%039d' "$i")"
    ts="$(printf '2026-08-%02dT12:00:00Z' "$i")"
    reviews="$reviews{\"author\":{\"login\":\"rev-a\"},\"state\":\"CHANGES_REQUESTED\",\"commit\":{\"oid\":\"$oid\"},\"submittedAt\":\"$ts\"},"
  fi
  printf '{"data":{"repository":{"pullRequest":{"headRefOid":"%s","body":"","comments":{"nodes":[]},"commits":{"nodes":[%s]},"reviews":{"nodes":[%s]}}}}}' \
    "$head" "${commits%,}" "${reviews%,}"
}
rc_count() {  # payload [panel] -> "<rounds> <at_cap>"
  printf '%s' "$1" \
    | jq -c -L "$SHARED/lib/jq" --argjson panel "${2:-$RC_PANEL}" -f "$RC_JQ" \
    | jq -r '"\(.rounds) \(.at_cap)"'
}

t roundcap-no-rounds-is-not-at-cap        '0 false' "$(rc_count "$(rc_build 0)")"
t roundcap-one-round-is-not-at-cap        '1 false' "$(rc_count "$(rc_build 1)")"
t roundcap-four-rounds-is-not-at-cap      '4 false' "$(rc_count "$(rc_build 4)")"
t roundcap-fifth-round-closed-is-at-cap   '5 true'  "$(rc_count "$(rc_build 5)")"
# MUST FAIL: a mid-round cut. Round 5 has OPENED — one panelist has voted — and
# doctrine "permits no mid-round cut", so the boundary is not here yet. A bare
# `rounds >= 5` reads this as at-cap and instructs a cut over two reviewers who
# are still reading.
t roundcap-fifth-round-still-open-is-not-at-cap '5 false' "$(rc_count "$(rc_build 4 1)")"
# The cut survives the round's own fixes. Step 1 answers round 5 whole and
# pushes, which moves the head off every verdict-bearing commit; the cap is a
# fact about the PR's history and must not evaporate with that push.
t roundcap-survives-the-round-fix-push    '5 true'  "$(rc_count "$(rc_build 5 0 1)")"
# A sixth round that opened in spite of the rule does not un-close the fifth.
t roundcap-sixth-round-still-at-cap       '6 true'  "$(rc_count "$(rc_build 6)")"
# MUST FAIL: a successor whose first round is numbered 6. Rounds are counted per
# PR, so the successor — a different PR with its own review history — arrives
# here at one round and on the ordinary path.
t roundcap-successor-first-round-is-round-one '1 false' "$(rc_count "$(rc_build 1)")"
# MUST FAIL: a cut fired on a fifth round that closed with the panel's UNANIMOUS
# approval. That is the ordinary way a long PR finally passes: converged.jq is
# true on the same tick, the engine hands the PR to the human, and the PR then
# sits in the authored listing until a human merges it — so an at-cap answer here
# names a handed-off PR for the cut in every builder-side prompt for the whole of
# that window, beside a step 4 reading "Close the predecessor". Doctrine's cut is
# written for a round that closed with work still owed: step 1 answers round 5 and
# pushes fixes there are none of, and step 2's "a verdict bought on the
# predecessor is a verdict on a PR that will never merge" has its premise
# inverted. Found by @codex-bot-andresmgsl and @claude-bot-andresmgsl, and named
# as an unverified path by @kimi-bot-andresmgsl, on PR #566's round 1.
t roundcap-converged-fifth-round-is-not-at-cap '5 false' \
  "$(rc_count "$(rc_build 5 0 0 APPROVED)")"
# ...and the carve-out is exactly as wide as that, no wider. Same unanimous fifth
# round, but the builder has since pushed: the approvals are spent, converged.jq
# is false, the panel is re-requested, and the verdicts that land would form ROUND
# SIX on the same PR. A plain "did the fifth round approve?" test reads this as
# not-at-cap and opens the hole the cap exists to close.
t roundcap-stale-full-approval-is-still-at-cap '5 true' \
  "$(rc_count "$(rc_build 5 0 1 APPROVED)")"
# A fourth round that closed unanimously is not at the cap for the ordinary
# reason — four is not five — and reaching the carve-out for it would be reading
# the wrong round.
t roundcap-converged-fourth-round-is-not-at-cap '4 false' \
  "$(rc_count "$(rc_build 4 0 0 APPROVED)")"
# A sixth round that opened in spite of the rule does not un-close the fifth, and
# the carve-out reads the FIFTH round's verdicts rather than the newest ones: here
# round 5 requested changes and round 6 approved unanimously.
t roundcap-later-approval-does-not-lift-the-cap '6 true' \
  "$(rc_count "$(rc_build 6 0 0 APPROVED)")"
# One panelist who requested changes and then APPROVED the same head has released
# that head, and the latest verdict per reviewer is the one that counts — the same
# reading latestOpinionatedReviews gives addressing.jq. Counting the stale
# CHANGES_REQUESTED would hold a PR at the cap the panel had in fact passed.
RC_REVOTED="$(printf '%s' "$(rc_build 5)" | jq -c \
  --arg oid "$(printf 'c%039d' 5)" \
  '.data.repository.pullRequest.reviews.nodes += [{author:{login:"rev-a"},state:"APPROVED",commit:{oid:$oid},submittedAt:"2026-08-05T18:00:00Z"}]')"
t roundcap-revote-at-the-cap-head-is-the-latest '5 false' "$(rc_count "$RC_REVOTED")"
# An empty panel never closes a round vacuously, the guard addressing.jq and
# converged.jq both carry against a bare `panel=` line.
t roundcap-empty-panel-never-closes-a-round '5 false' "$(rc_count "$(rc_build 5)" '[]')"
# A bare COMMENTED review is not a verdict and opens no round.
RC_COMMENTED="$(printf '%s' "$(rc_build 5)" | jq -c \
  --arg oid "$(printf 'c%039d' 6)" \
  '.data.repository.pullRequest.reviews.nodes += [{author:{login:"rev-a"},state:"COMMENTED",commit:{oid:$oid},submittedAt:"2026-08-06T12:00:00Z"}]')"
t roundcap-commented-review-opens-no-round '5 true' "$(rc_count "$RC_COMMENTED")"

# THE PARTITION IS round-log.jq's, AND THIS IS WHAT HOLDS THEM TOGETHER. Two
# programs splitting one thread into rounds by different rules would disagree
# about which round a builder is in, and the rendered `## Round log` is where a
# human reads that answer off. $final=true finalizes the live round too, so the
# marker count is the whole partition.
rc_logged_rounds() {
  printf '%s' "$1" \
    | jq -r --arg me builder --argjson final true \
        --arg mark_answered '📣 round answered at head' \
        --arg mark_addressing '🔧 addressing round on head' \
        --arg mark_resume '⟲ resuming from' \
        --arg mark_handoff '🤝 handed off at head' \
        -f "$SHARED/lib/jq/round-log.jq" \
    | grep -c '<!-- round:'
}
for rc_n in 1 3 5 6; do
  t "roundcap-agrees-with-round-log-at-$rc_n" \
    "$rc_n" "$(rc_logged_rounds "$(rc_build "$rc_n")")"
  t "roundcap-count-agrees-with-round-log-at-$rc_n" \
    "$rc_n" "$(rc_count "$(rc_build "$rc_n")" | cut -d' ' -f1)"
done

# --- the census: it counts, and that is the whole of what it does -----------
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by the engine helper
rc_census() (  # payload listing
  DUTY_DIR="$RC_DUTY" ME=builder
  RC_PAYLOAD="$1"
  RC_LOG="$TMP/round-cap-census"; : >"$RC_LOG"
  log() { printf 'log %s\n' "$*" >>"$RC_LOG"; }
  warn() { printf 'warn %s\n' "$*" >>"$RC_LOG"; }
  PANEL_SIZED_CACHE=off
  gh() {
    printf 'gh %s\n' "$*" >>"$RC_LOG"
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      printf '%s\n' "$RC_PAYLOAD"
      return 0
    fi
    # The head's files, when the case sizes the panel: one small file, no
    # risky path, which is the low tier (#761). Unanswered, the read fails and
    # the panel is whole.
    if [ "$1" = pr ] && [ "$2" = view ] && [[ "$*" == *"--json files"* ]] && [ -n "${RC_FILES:-}" ]; then
      printf '%s\n' "$RC_FILES"
      return 0
    fi
    return 3
  }
  _round_cap_census owner/repo '["rev-a","rev-b"]' "$2"
  printf 'prs=[%s] named=[%s]' "$ROUND_CAP_PRS" "$ROUND_CAP_NAMED"
)
RC_LISTING='[{"number":7}]'
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-names-the-capped-pr \
  'prs=[owner/repo#7] named=[owner/repo#7 (5 rounds)]' \
  "$(rc_census "$(rc_build 5)" "$RC_LISTING")"
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-leaves-a-below-cap-pr-unnamed \
  'prs=[] named=[-]' \
  "$(rc_census "$(rc_build 4)" "$RC_LISTING")"
# MUST FAIL: an engine that performs any act of the cut. The census is allowed
# exactly one kind of call — a GraphQL read — and nothing that opens a PR,
# closes one, or writes a body.
rm -f "$RC_DUTY/.seen-round-cap"
rc_census "$(rc_build 5)" "$RC_LISTING" >/dev/null
RC_CALLS="$(grep -c '^gh api graphql' "$TMP/round-cap-census")"
RC_FILE_READS="$(grep -c '^gh pr view 7 -R owner/repo --json files' "$TMP/round-cap-census")"
RC_MUTATIONS="$(grep -Ec '^gh .*(mutation|pr create|pr close|pr edit|-X PATCH|-X POST|convertPullRequest|requested_reviewers|issue edit)' \
  "$TMP/round-cap-census" || true)"
t roundcap-census-reads-once-per-pr 1 "$RC_CALLS"
t roundcap-census-reads-the-heads-files-once 1 "$RC_FILE_READS"
t roundcap-census-performs-no-act-of-the-cut 0 "$RC_MUTATIONS"
# THE SIZED PANEL (#763 review): the census counts against the panel the head
# was asked of. PR #7 at low risk is sized to rev-b (7 mod 2 = 1), who approved
# every round — so the fifth round closed APPROVED and the cap is not reached,
# where the whole roster (rev-a's five change-requests) would name it. PR #8 is
# sized to rev-a (8 mod 2 = 0): five change-requests from the one reviewer the
# head was asked of IS the cap. Without the sizing the low-risk PR cycled past
# five forever, the one reviewer never being "every panelist".
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-a-low-risk-pr-is-counted-against-its-sized-reviewer-approving \
  'prs=[] named=[-]' \
  "$(RC_FILES='README.md 3' rc_census "$(rc_build 5)" "$RC_LISTING")"
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-a-low-risk-pr-reaches-the-cap-on-its-one-reviewer \
  'prs=[owner/repo#8] named=[owner/repo#8 (5 rounds)]' \
  "$(RC_FILES='README.md 3' rc_census "$(rc_build 5)" '[{"number":8}]')"
rm -f "$RC_DUTY/.seen-round-cap"
# ...and no module of the engine opens or closes a pull request at all, which is
# the same claim made where a later change would actually make it. Comment lines
# are stripped first: duty-builder.sh's resume header names `gh pr create` while
# describing the SESSION's act, and a guard that cannot tell prose from code
# would have to be deleted the first time it fired.
# The match runs off a here-string and never off a pipe: a `| grep -q` takes the
# pipeline's status from grep under pipefail, and #449's guard reds on writing
# the shape at all.
# duty-release.sh is carved out by name (#762): the one `gh pr close` it
# carries withdraws the engine's OWN release cut when main moves past it,
# which is not the round-cap cut and is pinned on its own below — a carve-out
# this guard cannot see is the only way to keep it a guard.
RC_ENGINE_CODE="$(engine_lib_sources | grep -v '/duty-release\.sh$' | xargs grep -hEv '^[[:space:]]*#')"
if grep -Eq 'gh pr (create|close|reopen)|closePullRequest' <<<"$RC_ENGINE_CODE"; then
  r1=ENGINE-CUTS
else
  r1=session-cuts
fi
t roundcap-engine-opens-and-closes-no-pr session-cuts "$r1"
t release-module-closes-only-its-own-cut 1 "$(grep -Ev '^[[:space:]]*#' "$SHARED/lib/duty-release.sh" | grep -cE 'gh pr (create|close|reopen)|closePullRequest')"
t release-module-withdrawal-is-in-the-settle-step 1 "$(awk '/^_release_settle_cut\(\) \{/{f=1} f && /gh pr close "\$num" -R "\$repo" --delete-branch/{c++} /^}/{f=0} END{print c+0}' "$SHARED/lib/duty-release.sh")"
# Said once per (PR, round count), not once per tick: a PR sits at the cap until
# the builder cuts it, and #167's rule is that a line repeating forever is
# wallpaper. The second census over the same state must add no log line.
#
# Counted on the BOUNDARY line specifically, not on every log line the census
# writes. The same census also records each PR's round count against its issue
# on its own ledger (#503), so a bare '^log ' count stopped being a count of
# this line the moment that one existed — and would have gone green again by
# accident on any later change that silenced one of the two.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
rc_census "$(rc_build 5)" "$RC_LISTING" >/dev/null
RC_FIRST="$(grep -c '^log .*round cap reached' "$TMP/round-cap-census")"
rc_census "$(rc_build 5)" "$RC_LISTING" >/dev/null
RC_SECOND="$(grep -c '^log .*round cap reached' "$TMP/round-cap-census")"
rc_census "$(rc_build 6)" "$RC_LISTING" >/dev/null
RC_SIXTH="$(grep -c '^log .*round cap reached' "$TMP/round-cap-census")"
t roundcap-census-says-the-boundary-once "1 0 1" "$RC_FIRST $RC_SECOND $RC_SIXTH"
# A listing this tick could not read names no boundary, and warns rather than
# manufacturing one.
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-failed-listing-names-nothing 'prs=[] named=[-]' \
  "$(rc_census "$(rc_build 5)" err)"
t roundcap-census-failed-listing-warns 1 \
  "$(grep -c '^warn .*round-cap census skipped' "$TMP/round-cap-census")"

# --- D2a: the predecessor is never requested, and everything else is today's -
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by the engine helper
rc_request() (  # payload [at_cap]
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK" PANEL_SIZED_CACHE=off
  LABEL_BOTS_REVIEWING=state:bots-reviewing
  RC_LOG="$TMP/round-cap-request"; : >"$RC_LOG"
  log() { :; }
  warn() { :; }
  gh() {
    local rc_arg
    if [ "$1" = api ] && [[ "$2" == repos/*/requested_reviewers ]]; then
      for rc_arg in "$@"; do
        case "$rc_arg" in
          reviewers\[\]=*) printf 'request:%s\n' "${rc_arg#*=}" >>"$RC_LOG" ;;
        esac
      done
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      printf 'label\n' >>"$RC_LOG"
      return 0
    fi
    return 3
  }
  if [ "$#" -ge 2 ]; then
    _request_panel owner/repo 7 "$1" '["rev-a","rev-b"]' green "$AR_H" "$2"
  else
    _request_panel owner/repo 7 "$1" '["rev-a","rev-b"]' green "$AR_H"
  fi
  paste -sd, "$RC_LOG"
)
RC_SIGNAL_COMMENTS='[{"author":{"login":"builder"},"body":"'"$RP_MARK"' '"$AR_H"'","createdAt":"'"$AR_T_SIGNAL"'"}]'
RC_SIGNALLED="$(mk_addressing_payload false '[]' '[]' "$AR_BLOCKED" "$RC_SIGNAL_COMMENTS")"
# MUST FAIL: a panel request on the predecessor at the cut. Everything the
# ordinary path needs is present — the round is signalled answered at the
# current head and the check is green — so only the cap holds it.
t roundcap-no-panel-request-on-the-predecessor '' "$(rc_request "$RC_SIGNALLED" true)"
# MUST FAIL: a PR below the cap behaving any differently from today. Same
# payload, same green head, cap not reached.
t roundcap-below-cap-requests-as-today 'request:rev-a,label' \
  "$(rc_request "$RC_SIGNALLED" false)"
# ...and a caller that passes no census answer at all gets today's behaviour,
# which is what makes the argument's default the safe one.
t roundcap-omitted-census-answer-is-todays-behaviour 'request:rev-a,label' \
  "$(rc_request "$RC_SIGNALLED")"

# --- the whole control-flow outcome, not the predicate alone ----------------
# Asked for by @codex-bot-andresmgsl on PR #566 round 1, and it is the right
# ask: the three cases above probe `_request_panel` in isolation, so none of
# them sees that execution CONTINUES past the cap's early return into the
# unchanged convergence check. A cut suppressed at the request site while
# `converged.jq` queues `_handoff_finalize` on the same tick is a defect no
# predicate probe can reach. This drives census -> _at_round_cap ->
# _request_panel -> converged.jq over one PR and asserts what the tick actually
# DOES.
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by the engine helpers
rc_flow() (  # cap-payload pr-payload
  DUTY_DIR="$RC_DUTY" ME=builder MARK_ANSWERED="$RP_MARK"
  LABEL_BOTS_REVIEWING=state:bots-reviewing
  LABEL_NEEDS_HUMAN=state:needs-human
  RC_PAYLOAD="$1"; RC_PR="$2"
  local rc_cap rc_signal rc_conv
  RC_LOG="$TMP/round-cap-flow"; : >"$RC_LOG"
  log() { :; }
  warn() { :; }
  gh() {
    local rc_arg
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      printf '%s\n' "$RC_PAYLOAD"
      return 0
    fi
    if [ "$1" = api ] && [[ "$2" == repos/*/requested_reviewers ]]; then
      for rc_arg in "$@"; do
        case "$rc_arg" in
          reviewers\[\]=*) printf 'request:%s\n' "${rc_arg#*=}" >>"$RC_LOG" ;;
        esac
      done
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      printf 'label\n' >>"$RC_LOG"
      return 0
    fi
    return 3
  }
  rm -f "$RC_DUTY/.seen-round-cap"
  _round_cap_census owner/repo '["rev-a","rev-b"]' '[{"number":7}]'
  # The call site's own two lines, copied rather than described, so this drives
  # the wiring instead of a paraphrase of it.
  if _at_round_cap owner/repo 7; then rc_cap=true; else rc_cap=false; fi
  _request_panel owner/repo 7 "$RC_PR" '["rev-a","rev-b"]' green "$AR_H" "$rc_cap"
  rc_signal="$(printf '%s' "$RC_PR" | jq -c --arg me "$ME" --arg mark "$MARK_ANSWERED" \
    -f "$RC_DUTY/lib/jq/answered-head.jq")"
  rc_conv="$(printf '%s' "$RC_PR" | jq -r --argjson panel '["rev-a","rev-b"]' --argjson roster '["rev-a","rev-b"]' \
    --arg me "$ME" --arg mark_handoff "${MARK_HANDOFF:-🤝 handed off at head}" --arg human "" --argjson signal "$rc_signal" \
    -f "$RC_DUTY/lib/jq/converged.jq")"
  printf 'named=[%s] at_cap=%s requested=[%s] converged=%s' \
    "$ROUND_CAP_NAMED" "$rc_cap" "$(paste -sd, "$RC_LOG")" "$rc_conv"
)
RC_MERGEABLE='.data.repository.pullRequest.mergeable="MERGEABLE"'
# Approvals from the whole panel AT the head, and a signal at that head: the
# terminal shape. `[]` requests and no `state:needs-human` yet, because this is
# the tick on which the handoff would fire.
RC_CONVERGED_PR="$(mk_addressing_payload false '[]' '[]' "$AR_APPROVED" "$RC_SIGNAL_COMMENTS" \
  | jq -c "$RC_MERGEABLE")"
# THE SHAPE ALL 28 ROUND-1 CASES MISSED. Under the fix the census refuses it, so
# nothing is named for the cut, the request site is on today's path and finds
# nobody left to request, and the handoff runs — the PR goes to the human and
# merges. Restore the at-cap answer here and every cell but the last flips.
t roundcap-converged-fifth-round-hands-off-and-is-not-cut \
  'named=[-] at_cap=false requested=[] converged=true' \
  "$(rc_flow "$(rc_build 5 0 0 APPROVED)" "$RC_CONVERGED_PR")"
# The shape the cut IS for, driven the same way: round 5 closed with a change
# request, so the census names it, the request is held on the predecessor, and
# nothing hands off. This is the row that would go missing if the carve-out were
# written too wide.
RC_OWED_PR="$(mk_addressing_payload false '[]' '[]' "$AR_BLOCKED" "$RC_SIGNAL_COMMENTS" \
  | jq -c "$RC_MERGEABLE")"
t roundcap-owed-fifth-round-is-cut-and-never-handed-off \
  'named=[owner/repo#7 (5 rounds)] at_cap=true requested=[] converged=false' \
  "$(rc_flow "$(rc_build 5)" "$RC_OWED_PR")"
# ...and the stale-approval shape, where the suppression is doing visible work:
# the fifth round approved unanimously but the head has moved, so no approval
# stands, converged.jq is false, and the ordinary path would request BOTH
# panelists — whose verdicts would be round six on this PR. The cap holds them.
RC_STALE_REVIEWS="$(printf '%s' "$AR_APPROVED" \
  | jq -c --arg oid "$(printf 'b%039d' 1)" 'map(.commit.oid = $oid)')"
RC_STALE_PR="$(mk_addressing_payload false '[]' '[]' "$RC_STALE_REVIEWS" "$RC_SIGNAL_COMMENTS" \
  | jq -c "$RC_MERGEABLE")"
t roundcap-stale-approval-holds-the-request-and-never-hands-off \
  'named=[owner/repo#7 (5 rounds)] at_cap=true requested=[] converged=false' \
  "$(rc_flow "$(rc_build 5 0 1 APPROVED)" "$RC_STALE_PR")"

# --- no configurable cap, and no per-role override --------------------------
# MUST FAIL: any configurable cap. The number is a literal in the predicate and
# is written once; a conf key or a role override is what D1 forbids by name.
# shellcheck disable=SC2016  # the jq program's own `$cap` is matched literally
t roundcap-five-is-declared-once 1 \
  "$(grep -cE '^\| 5 +as \$cap$' "$RC_JQ")"
if grep -Eqi 'round[_-]?cap|max[_-]?rounds|cap[_-]?rounds' "$SHARED/conf/fleet.defaults.conf"; then
  r1=CONFIGURABLE
else
  r1=untouched
fi
t roundcap-fleet-defaults-untouched untouched "$r1"
if grep -REqi 'ROUND_CAP=[0-9]|MAX_ROUNDS|CREW_ROUND_CAP|ROUND_CAP_DEFAULT|per-role cap' \
  "$SHARED/lib" "$SHARED/bin" "$SHARED/conf" "$ROOT/cli"; then
  r1=OVERRIDABLE
else
  r1=fixed
fi
t roundcap-no-override-anywhere fixed "$r1"
# The census reads no threshold from anywhere: its only source for the number is
# the predicate it calls.
t roundcap-census-reads-no-threshold 0 \
  "$(awk '/^_round_cap_census\(\) \{$/,/^\}$/' "$BMOD" \
     | grep -Ec 'conf_get|[A-Z_]*CAP[A-Z_]*=[0-9]')"

# --- the instruction: what it must name (D3, D3a, the nine steps) -----------
RC_RENDERED="$(PROMPTS_DIR="$SHARED/prompts" render_prompt fragment-round-rules.txt \
  TRIAGE=fx-triage BENCH='a b' MARK_ADDRESSING='addressing' MARK_ANSWERED='answered' \
  ROUND_CAP='owner/repo#7 (5 rounds)')"
rc_names() {  # name phrase...
  local rc_name="$1" rc_phrase
  shift
  r1=named
  for rc_phrase in "$@"; do
    grep -Fq -- "$rc_phrase" <<<"$RC_RENDERED" || r1="MISSING: $rc_phrase"
  done
  t "$rc_name" named "$r1"
}
rc_names roundcap-instruction-states-the-cap \
  'A PR CARRIES AT MOST FIVE ROUNDS' 'round six never opens on the same PR'
rc_names roundcap-instruction-numbers-rounds-per-pr \
  "successor's first round is round 1, never round 6"
# MUST FAIL: an instruction that lets the engine perform the cut.
rc_names roundcap-instruction-keeps-the-cut-with-the-builder \
  'THE ENGINE COUNTS AND SAYS WHERE THE BOUNDARY IS; IT PERFORMS NO ACT OF THE CUT' \
  'it opens no PR, closes no PR and edits no body' \
  'YOU PERFORM THE CUT'
# MUST FAIL: an instruction that omits the Closes -> Refs edit or the
# `### Current state` carry-forward.
rc_names roundcap-instruction-names-the-closes-to-refs-edit \
  "Edit the predecessor's body, 'Closes #N' to 'Refs #N'" \
  'it happens BEFORE the close'
rc_names roundcap-instruction-names-the-round-log-split \
  "'### Current state' is CARRIED FORWARD from the predecessor" \
  "'### Rounds' STARTS EMPTY"
rc_names roundcap-instruction-names-the-carried-set \
  'the branch, the claim, the assignee, the closing link and the queue labels'
rc_names roundcap-instruction-forbids-the-predecessor-request \
  'DO NOT SIGNAL AND DO NOT REQUEST THE PANEL on the predecessor' \
  'The panel is requested once, on the successor'
rc_names roundcap-instruction-forbids-a-mid-round-cut \
  'permits NO MID-ROUND CUT' 'excuses no unanswered round'
rc_names roundcap-instruction-carries-the-census \
  'owner/repo#7 (5 rounds)'
# The nine steps, each numbered, in order. Read from the cut's own sentence
# onward: the fragment's three hard rules are numbered (1)-(3) above it, and a
# count over the whole file would pass on six steps plus those three.
t roundcap-instruction-has-nine-numbered-steps '(1) (2) (3) (4) (5) (6) (7) (8) (9)' \
  "$(grep -oE '\([1-9]\)' <<<"${RC_RENDERED##*THE CUT IS NINE STEPS, IN THIS ORDER.}" \
     | paste -sd' ')"

# --- wiring ------------------------------------------------------------------
# The census must precede every builder-side prompt render, or the boundary
# reaches no session on the tick it is first true.
# shellcheck disable=SC2016  # grep patterns intentionally contain shell syntax
RC_CENSUS_LINE="$(grep -n '_round_cap_census "\$R"' "$BMOD" | cut -d: -f1)"
# shellcheck disable=SC2016
RC_RENDER_LINE="$(grep -n 'render_prompt fragment-round-rules.txt' "$BMOD" | cut -d: -f1)"
# shellcheck disable=SC2016
RC_RESUME_DISPATCH="$(grep -n 'run_session resume' "$BMOD" | cut -d: -f1)"
if [ -n "$RC_CENSUS_LINE" ] && [ -n "$RC_RENDER_LINE" ] \
  && [ "$RC_CENSUS_LINE" -lt "$RC_RENDER_LINE" ] \
  && [ "$RC_RENDER_LINE" -lt "$RC_RESUME_DISPATCH" ]; then
  r1=ordered
else
  r1=WRONG-ORDER
fi
t roundcap-census-precedes-every-render ordered "$r1"
# The request site is handed this tick's answer for that PR, rather than reading
# the global inside the helper where no fixture could drive it.
# shellcheck disable=SC2016  # grep patterns intentionally contain shell syntax
if grep -q '_at_round_cap "\$R" "\$N"' "$BMOD" \
  && grep -q '"\${head_by_num\[\$N\]:-}" "\$_pr_at_cap"' "$BMOD"; then
  r1=passed
else
  r1=HIDDEN
fi
t roundcap-request-site-passes-the-census-answer passed "$r1"
# Drafts are counted. The census enumerates the resume listing, which carries
# every open authored PR, and never filters isDraft — the cut is performed on a
# draft, so a draft-blind census names the boundary only on the tick before it
# is needed. Driven rather than grepped: this asserted the ABSENCE of the string
# `isDraft` in the function body until @claude-bot-andresmgsl pointed out on PR
# #566 that the listing was right there and the claim could be pinned against
# the code instead of against its spelling.
rm -f "$RC_DUTY/.seen-round-cap"
t roundcap-census-counts-drafts \
  'prs=[owner/repo#7] named=[owner/repo#7 (5 rounds)]' \
  "$(rc_census "$(rc_build 5)" '[{"number":7,"isDraft":true}]')"
# The attention wake renders the slot too, with its OWN token: `?` for "did not
# count at all" against the census's `-` for "counted, none at the cap". One
# token for both states was readable only by a session that already knew which
# wake it was on (@claude-bot-andresmgsl, #566). Neither may reach a prompt
# unexplained.
if grep -q 'ROUND_CAP="?"' "$ATT_MOD" \
  && ! grep -q 'ROUND_CAP="-"' "$ATT_MOD" \
  && grep -Fq "a '-' means it counted and none is at the cap" <<<"$RC_RENDERED" \
  && grep -Fq "a '?' means this wake did not count at all" <<<"$RC_RENDERED"; then
  r1=explained
else
  r1=UNEXPLAINED
fi
t roundcap-attention-slot-explained explained "$r1"
# The instruction carries the carve-out too, because doctrine's own procedure is
# executable by a builder counting rounds by hand and a session that counts five
# rounds itself must not cut a PR the panel has just passed.
rc_names roundcap-instruction-names-the-converged-carve-out \
  'THE CUT IS FOR A ROUND THAT CLOSED WITH WORK STILL OWED' \
  'it converges and goes to the human to merge' \
  'If the approvals are STALE because you have since pushed, the cut is owed again'
# The carve-out was crew's reading of a collision between two unconditional
# doctrine rules until ceremony 0.7.11 ruled it the same way ("A fifth round
# that passes does not cut at its close"; a push after the human's return
# fires the cut). The instruction now cites the ruling and keeps the link to
# the discussion that carried it there, in both places the reading is stated
# — here and round-cap.jq's header (#566 round 2, #762).
rc_names roundcap-instruction-cites-the-doctrine-ruling \
  "THIS IS DOCTRINE'S OWN RULING SINCE CEREMONY 0.7.11" \
  'a push after the human returns it fires the cut' \
  'heavy-duty/ceremony#517'

# --- #503: the same count, read against the issue and as a distribution -----
#
# The cap asks a PR whether it has finished. This asks the board what a round
# count normally is here, which is a question about issues and about history.
RK_JQ="$SHARED/lib/jq/round-count.jq"
# The pattern is duty-builder.sh's own constant, read from the module rather
# than restated: a copy here would pass while the engine's copy drifted, which
# is the whole failure `_RESUME_ISSUE_RE` was made a constant to prevent (#479).
RK_RE="$_RESUME_ISSUE_RE"
# The cap is read from round-cap.jq, the one place the literal lives (#502 D1) —
# so a suite that hardcoded 5 could not notice the day the two disagreed.
RK_CAP="$(printf '{}' | jq -L "$SHARED/lib/jq" --argjson panel '[]' \
  -f "$SHARED/lib/jq/round-cap.jq" | jq -r '.cap')"
t roundcount-cap-is-round-caps-own-literal 5 "$RK_CAP"

# rk_pr NUM BODY ROUNDS — one pullRequest node carrying ROUNDS closed rounds.
# Commit i is committed at 10:00 and reviewed at 12:00 the same day, so no
# verdict is re-pointed and the partition is the plain one, exactly as rc_build
# builds it above.
rk_pr() {
  local rk_num="$1" rk_body="$2" rk_n="$3" i oid ts commits="" reviews=""
  for ((i = 1; i <= rk_n; i++)); do
    oid="$(printf 'p%s-c%039d' "$rk_num" "$i")"
    ts="$(printf '2026-08-%02dT10:00:00Z' "$i")"
    commits="$commits{\"commit\":{\"oid\":\"$oid\",\"committedDate\":\"$ts\"}},"
    ts="$(printf '2026-08-%02dT12:00:00Z' "$i")"
    reviews="$reviews{\"author\":{\"login\":\"rev-a\"},\"state\":\"CHANGES_REQUESTED\",\"commit\":{\"oid\":\"$oid\"},\"submittedAt\":\"$ts\"},"
  done
  printf '{"number":%s,"body":%s,"commits":{"nodes":[%s]},"reviews":{"nodes":[%s]}}' \
    "$rk_num" "$(printf '%s' "$rk_body" | jq -Rs .)" "${commits%,}" "${reviews%,}"
}
rk_board() { printf '[%s]' "$(printf '%s,' "$@" | sed 's/,$//')"; }
rk_count() {  # board-json [filter] -> the evaluated program, or one field of it
  printf '%s' "$1" \
    | jq -c -L "$SHARED/lib/jq" --arg re "$RK_RE" --argjson cap "$RK_CAP" -f "$RK_JQ" \
    | jq -r "${2:-.}"
}

# Attribution: both forms BUILDER.md writes reach the issue. `Refs #N` matters
# most — it is what step 3 of the cut leaves on the predecessor.
t roundcount-closes-attributes-to-the-issue 503 \
  "$(rk_count "$(rk_board "$(rk_pr 1 'Closes #503' 2)")" '.issues[0].issue')"
t roundcount-refs-attributes-to-the-issue 503 \
  "$(rk_count "$(rk_board "$(rk_pr 1 'Refs #503' 2)")" '.issues[0].issue')"

# THE CAPPED CHAIN, which is this issue's hardest criterion. The cut closes a
# five-round predecessor at `Refs #N` and opens a successor at `Closes #N`; both
# name the issue, so the issue has taken eight rounds.
RK_CHAIN="$(rk_board "$(rk_pr 566 'Refs #503' 5)" "$(rk_pr 586 'Closes #503' 3)")"
t roundcount-cut-chain-is-one-issue 1 "$(rk_count "$RK_CHAIN" '.issues | length')"
t roundcount-cut-chain-sums-the-rounds 8 "$(rk_count "$RK_CHAIN" '.issues[0].rounds')"
t roundcount-cut-chain-names-both-prs '566,586' \
  "$(rk_count "$RK_CHAIN" '.issues[0].prs | join(",")')"
# MUST FAIL: a capped chain double-counting its rounds. Counted per PR the
# distribution would carry TWO observations, 5 and 3 — reporting the cap as
# ordinary and halving the one issue the evidence exists to show. One issue is
# one observation, and its value is the chain's total.
t roundcount-cut-chain-enters-the-distribution-once 1 \
  "$(rk_count "$RK_CHAIN" '.distribution.issues')"
t roundcount-cut-chain-max-is-the-chain-total 8 \
  "$(rk_count "$RK_CHAIN" '.distribution.max')"
# The positive control that keeps the case above from being vacuous: two PRs on
# two DIFFERENT issues are two observations, so the grouping is doing the work
# rather than a length that happens to be one.
t roundcount-two-issues-are-two-observations 2 \
  "$(rk_count "$(rk_board "$(rk_pr 1 'Closes #10' 5)" "$(rk_pr 2 'Closes #11' 3)")" \
    '.distribution.issues')"

# The distribution's arithmetic, at both parities.
RK_ODD="$(rk_board "$(rk_pr 1 'Closes #10' 1)" "$(rk_pr 2 'Closes #11' 3)" \
  "$(rk_pr 3 'Closes #12' 14)")"
t roundcount-median-odd '1 3 14' "$(rk_count "$RK_ODD" \
  '"\(.distribution.min) \(.distribution.median) \(.distribution.max)"')"
RK_EVEN="$(rk_board "$(rk_pr 1 'Closes #10' 2)" "$(rk_pr 2 'Closes #11' 5)")"
t roundcount-median-even 3.5 "$(rk_count "$RK_EVEN" '.distribution.median')"
# D3's own worked example: an outlier is legible only beside the median, which
# is why the figure reported is a distribution and never a bare number.
t roundcount-outlier-reads-against-the-median '14 3' \
  "$(rk_count "$RK_ODD" '"\(.distribution.max) \(.distribution.median)"')"
t roundcount-at-or-over-cap-counts-against-the-ruled-five 1 \
  "$(rk_count "$RK_ODD" '.distribution.at_or_over_cap')"

# A PR that has taken no rounds YET is not a zero-round issue. Folding it into
# the median answers "how far along is the board" instead of "what does an issue
# cost here"; it is reported rather than dropped, because a filter nobody can
# see is a filter nobody can check.
RK_PENDING="$(rk_board "$(rk_pr 1 'Closes #10' 4)" "$(rk_pr 2 'Closes #11' 0)")"
t roundcount-unreviewed-pr-is-pending-not-zero '1 4 1' \
  "$(rk_count "$RK_PENDING" \
    '"\(.distribution.issues) \(.distribution.median) \(.distribution.pending)"')"
t roundcount-pending-issue-is-still-listed 2 \
  "$(rk_count "$RK_PENDING" '.issues | length')"
# A PR whose body names no issue is in no issue's total, and the count says how
# many rather than letting the coverage gap pass as a complete board.
t roundcount-unattributed-pr-is-counted '1 1' \
  "$(rk_count "$(rk_board "$(rk_pr 1 'Closes #10' 2)" "$(rk_pr 2 'no issue here' 9)")" \
    '"\(.distribution.issues) \(.distribution.unattributed)"')"
# ...and it is genuinely excluded from the figures, not merely tallied: 9 is the
# largest count in that board and must not be the max.
t roundcount-unattributed-pr-is-not-in-the-distribution 2 \
  "$(rk_count "$(rk_board "$(rk_pr 1 'Closes #10' 2)" "$(rk_pr 2 'no issue here' 9)")" \
    '.distribution.max')"
# An empty board reports zeros rather than dividing by none.
t roundcount-empty-board-is-zeros '0 0 0' \
  "$(rk_count '[]' '"\(.distribution.issues) \(.distribution.median) \(.distribution.max)"')"

# THE PARTITION IS ONE DEFINITION NOW, AND THIS IS WHAT HOLDS IT TOGETHER.
# round-cap.jq and round-count.jq both include rounds.jq, so a per-PR count from
# one must equal the other's for the same history. round-log.jq keeps its own
# copy and its own pin above; this is the pair that share the module.
for rk_n in 1 3 5 6; do
  t "roundcount-agrees-with-round-cap-at-$rk_n" "$rk_n" \
    "$(rk_count "$(rk_board "$(rk_pr 1 'Closes #10' "$rk_n")")" '.issues[0].rounds')"
done
# ...and the module is genuinely shared rather than two files that happen to
# agree: neither program may carry the partition's own expressions any more.
if grep -q 'include "rounds";' "$RC_JQ" && grep -q 'include "rounds";' "$RK_JQ" \
  && ! grep -q 'group_by(.oid)' "$RC_JQ" && ! grep -q 'group_by(.oid)' "$RK_JQ" \
  && grep -q 'def round_verdicts:' "$SHARED/lib/jq/rounds.jq" \
  && grep -q 'def round_heads:' "$SHARED/lib/jq/rounds.jq"; then
  r1=one-definition
else
  r1=COPIED
fi
t roundcount-partition-is-one-definition one-definition "$r1"

# --- the census records every PR against its issue, not only the capped ones -
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by the engine helper
rk_census() (  # payload listing
  DUTY_DIR="$RC_DUTY" ME=builder
  RC_PAYLOAD="$1"
  RC_LOG="$TMP/round-count-census"; : >"$RC_LOG"
  log() { printf 'log %s\n' "$*" >>"$RC_LOG"; }
  warn() { printf 'warn %s\n' "$*" >>"$RC_LOG"; }
  gh() {
    printf 'gh %s\n' "$*" >>"$RC_LOG"
    if [ "$1" = api ] && [ "$2" = graphql ]; then printf '%s\n' "$RC_PAYLOAD"; return 0; fi
    return 3
  }
  _round_cap_census owner/repo '["rev-a","rev-b"]' "$2"
  # THE SUBJECT IS THE LOG LINE, NOT A VARIABLE. An earlier revision returned a
  # `ROUND_CAP_COUNTS` global here, and round 1 of #503 pointed out that nothing
  # in production ever read it — so the cases below were the only consumer of a
  # channel that carried nothing, and would have stayed green if the record had
  # never reached the log or the ledger at all. The ledger line and this log line
  # are the record an engine whose record is its log actually keeps, so they are
  # what the four cases below read.
  sed -n 's/^log .*rounds recorded against the issue — //p' "$RC_LOG"
)
# rk_body NUM BODY ROUNDS — rc_build's payload with a body written into it, so
# the census has an issue to resolve.
rk_payload() { printf '%s' "$(rc_build "$2")" | jq -c --arg b "$1" '.data.repository.pullRequest.body = $b'; }

# THE RECORD IS NOT THE STALL SIGNAL. A four-round PR is nowhere near the cap
# and is still recorded — D1's whole complaint is a counter "that surfaces when
# a PR stalls", so a census that recorded only capped PRs would have rebuilt it.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
t roundcount-census-records-a-below-cap-pr 'owner/repo#7 (4 round(s)) -> #503' \
  "$(rk_census "$(rk_payload 'Closes #503' 4)" "$RC_LISTING")"
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
t roundcount-census-records-a-capped-pr-too 'owner/repo#7 (5 round(s)) -> #503' \
  "$(rk_census "$(rk_payload 'Closes #503' 5)" "$RC_LISTING")"
# The cut predecessor still names its issue after step 3 rewrites the keyword.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
t roundcount-census-records-a-refs-predecessor 'owner/repo#7 (5 round(s)) -> #503' \
  "$(rk_census "$(rk_payload 'Refs #503' 5)" "$RC_LISTING")"
# A body naming no issue records `-` rather than vanishing from the record.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
t roundcount-census-records-an-unattributed-pr 'owner/repo#7 (4 round(s)) -> no issue named' \
  "$(rk_census "$(rk_payload 'no issue named here' 4)" "$RC_LISTING")"
# It costs no extra call: the body rides the payload the cap census already
# fetched, so the per-PR read stays at one.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
rk_census "$(rk_payload 'Closes #503' 4)" "$RC_LISTING" >/dev/null
t roundcount-census-adds-no-fetch 1 "$(grep -c '^gh ' "$TMP/round-count-census")"
# It names the issue in the log, which is what "recorded against the issue"
# means for an engine whose record is its log — and says it once per
# (PR, count, issue), on a ledger of its own.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
rk_census "$(rk_payload 'Closes #503' 4)" "$RC_LISTING" >/dev/null
if grep -q '^log .*rounds recorded against the issue.*owner/repo#7 (4 round(s)) -> #503' \
    "$TMP/round-count-census"; then r1=named; else r1="$(cat "$TMP/round-count-census")"; fi
t roundcount-census-log-names-the-issue named "$r1"
RK_FIRST="$(grep -c '^log .*rounds recorded' "$TMP/round-count-census")"
rk_census "$(rk_payload 'Closes #503' 4)" "$RC_LISTING" >/dev/null
RK_SECOND="$(grep -c '^log .*rounds recorded' "$TMP/round-count-census")"
rk_census "$(rk_payload 'Closes #503' 5)" "$RC_LISTING" >/dev/null
RK_THIRD="$(grep -c '^log .*rounds recorded' "$TMP/round-count-census")"
t roundcount-census-records-once-per-count '1 0 1' "$RK_FIRST $RK_SECOND $RK_THIRD"
# The two ledgers are separate, so a PR reaching the cap cannot swallow its own
# round record — they clear on different events and say different things.
if grep -q 'seen-round-count' "$BMOD" && grep -q 'seen-round-cap' "$BMOD" \
  && [ -f "$RC_DUTY/.seen-round-count" ]; then r1=separate; else r1=SHARED; fi
t roundcount-census-ledger-is-its-own separate "$r1"

# MUST FAIL: any automatic action on the signal (D4). The census is allowed one
# kind of call — a GraphQL read — and this evidence adds nothing that labels,
# splits or blocks. Asserted on the whole call log of a census that recorded a
# count, so a future write would have to appear here to pass.
rm -f "$RC_DUTY/.seen-round-cap" "$RC_DUTY/.seen-round-count"
rk_census "$(rk_payload 'Closes #503' 4)" "$RC_LISTING" >/dev/null
RK_ACTIONS="$(grep -Ec '^gh .*(mutation|issue edit|pr edit|pr create|pr close|--add-label|--remove-label|-X PATCH|-X POST|-X PUT|-X DELETE)' \
  "$TMP/round-count-census" || true)"
t roundcount-census-takes-no-automatic-action 0 "$RK_ACTIONS"

# ── #535 — the handoff refire guard is the engine's own mark, never a label ──
# converged.jq used to read state:needs-human as "already handed off"; the
# reconciler owns that label and takes it off for reasons of its own, and each
# removal re-armed the wake at an unchanged head (135 label events in 6h19m on
# crew#516). The guard now reads the builder's own `MARK_HANDOFF <head>` line
# in a comment by $me, whole first line, and nothing else.
d7_pr() {  # d7_pr <head> <mergeable> <comments-json> [labels-json]
  jq -n --arg head "$1" --arg m "$2" --argjson comments "$3" --argjson labels "${4:-[]}" \
    --argjson revs "${REVS_OK//$H/$1}" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:[]},
      comments:{nodes:$comments},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
D7_H1="1111111111111111111111111111111111111111"
D7_H2="2222222222222222222222222222222222222222"
d7_mark() { jq -n --arg a "$1" --arg b "$2" '[{author:{login:$a},body:$b}]'; }   # d7_mark <login> <body>
t d7-converged-without-mark-hands-off true "$(d7_pr "$D7_H1" MERGEABLE '[]' | cj)"
t d7-my-mark-at-head-is-handed-off handed-off \
  "$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1"$'\n\nEvery panel verdict approves')" | cj)"
# THE DEFECT: the label is not the guard in either direction.
t d7-mark-survives-label-removal handed-off \
  "$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1")" '[]' | cj)"
t d7-label-alone-is-not-the-guard true \
  "$(d7_pr "$D7_H1" MERGEABLE '[]' '["state:needs-human"]' | cj)"
# A new head re-arms; nobody else's mark, and no prose mention, is the mark.
t d7-mark-at-an-old-head-rearms true \
  "$(d7_pr "$D7_H2" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1")" | cj)"
t d7-another-login-mark-is-not-mine true \
  "$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark rev-a "$CJ_MARK $D7_H1")" | cj)"
t d7-mark-in-prose-is-not-the-mark true \
  "$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "as noted, $CJ_MARK $D7_H1 earlier")" | cj)"
t d7-mark-with-a-tail-is-not-the-mark true \
  "$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1 (again)")" | cj)"
# The guard answers only where "true" would have: unknown mergeability still
# defers, and a human block still wins.
t d7-mark-under-unknown-still-defers defer-unknown \
  "$(d7_pr "$D7_H1" UNKNOWN "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1")" | cj)"
d7_blocked="$(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1")" \
  | jq --arg h "$CJ_HUMAN" --arg head "$D7_H1" '.data.repository.pullRequest.latestOpinionatedReviews.nodes += [{author:{login:$h},state:"CHANGES_REQUESTED",submittedAt:"2026-08-11T10:00:00Z",commit:{oid:$head}}]')"
t d7-mark-under-a-human-block-is-still-false false "$(printf '%s' "$d7_blocked" | cj)"
# The flood: the same converged head over ten ticks is suppressed on every one.
d7_flood=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  d7_flood="$d7_flood $(d7_pr "$D7_H1" MERGEABLE "$(d7_mark "$CJ_ME" "$CJ_MARK $D7_H1")" | cj)"
done
t d7-ten-ticks-at-one-head-are-all-suppressed 10 "$(grep -o 'handed-off' <<<"$d7_flood" | wc -l | tr -d ' ')"
# The engine's side: the mark is passed, the label is not, the suppression is
# logged, and _handoff_finalize posts the mark LAST so a crash retries whole.
# shellcheck disable=SC2016  # the engine's own text, $ included
t d7-engine-passes-the-mark-to-converged 1 \
  "$(grep -A2 -- '--argjson panel "\$_PANEL_EFFECTIVE_JSON"' "$SHARED/lib/duty-builder.sh" | grep -c -- '--arg mark_handoff "\$MARK_HANDOFF"')"
t d7-engine-no-longer-passes-the-label 0 "$(grep -c -- '--arg needs_human' "$SHARED/lib/duty-builder.sh" "$CJQ" | awk -F: '{s+=$2} END{print s}')"
t d7-engine-logs-the-suppressed-refire 1 "$(grep -c 'refire suppressed (#535)' "$SHARED/lib/duty-builder.sh")"
d7_fin="$(sed -n '/^_handoff_finalize() {/,/^}/p' "$SHARED/lib/duty-builder.sh")"
t d7-finalize-posts-the-mark-after-the-label 1 \
  "$(awk '/add-label "\$LABEL_NEEDS_HUMAN"/{l=NR} /post-once.sh/{p=NR} END{print (l && p && p>l) ? 1 : 0}' <<<"$d7_fin")"
unset -f d7_pr d7_mark

# ── #760 — the handoff note, the parked waits, the wait idiom ─────────────
H760="$TMP/h760"; mkdir -p "$H760"
h760_body='Closes #12.

## Worklog
- [x] wrote the thing
- [ ] run the suite

## Round log
### Current state
round 1 answered at abc1234

## Something else
not part of the note'
t handoff-sections-keep-worklog-and-round-log "## Worklog|- [x] wrote the thing|- [ ] run the suite||## Round log|### Current state|round 1 answered at abc1234|" \
  "$(_handoff_sections "$h760_body" | paste -sd'|' -)"
t handoff-sections-of-a-body-without-them-are-empty "" "$(_handoff_sections 'just prose')"
h760_run() {  # h760_run <gh-mode> <fn> <args...> — the fn's stdout, under a gh that answers one way
  (
    DUTY_DIR="$H760"
    # shellcheck disable=SC2317  # the gh stub is invoked indirectly by the fn under test
    case "$1" in
      ok)   gh() { printf '%s\n' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "$h760_body"; } ;;
      fail) gh() { return 1; } ;;
      pending) gh() { printf '{"headRefOid":"h1","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}\n'; } ;;
      green)   gh() { printf '{"headRefOid":"h1","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}\n'; } ;;
      moved)   gh() { printf '{"headRefOid":"h2","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}\n'; } ;;
    esac
    # shellcheck disable=SC2317  # invoked indirectly by the fn under test
    log() { :; }
    shift; "$@"
  )
}
h760_note="$(h760_run ok _handoff_fetch o/r 12)"
t handoff-fetch-prints-the-note 1 "$(grep -c '^- \[ \] run the suite$' <<<"$h760_note")"
t handoff-fetch-saves-a-copy-with-its-header 1 "$(grep -c '^# o/r#12 head=deadbeef' "$H760/.handoff-o_r-12")"
t handoff-a-failed-fetch-falls-back-to-the-copy 1 "$(h760_run fail _handoff_fetch o/r 12 | grep -c '^- \[x\] wrote the thing$')"
rm -f "$H760/.handoff-o_r-12"
t handoff-a-failed-fetch-with-no-copy-is-1 1 "$(h760_run fail _handoff_fetch o/r 12 >/dev/null; echo $?)"
t handoff-block-names-each-pr 1 "$(h760_run ok _handoff_block o/r "12 none" | grep -c '^### o/r#12$')"
t handoff-block-of-nothing-is-none none "$(h760_run ok _handoff_block o/r "none")"
printf 'o/r 7 h1 2026-10-23T10:00:00Z\n' >"$H760/.wait-o_r-7"
t waits-a-pending-wait-is-not-due "" "$(h760_run pending _builder_waits_due o/r)"
t waits-a-pending-wait-keeps-its-file yes "$([ -e "$H760/.wait-o_r-7" ] && echo yes || echo no)"
t waits-a-concluded-wait-is-due 7 "$(h760_run green _builder_waits_due o/r)"
# The reader consumes nothing: a due wait is cleared only once the tick has
# acted on it, so a clone or session failure after the read keeps the wake.
t waits-a-due-wait-is-not-consumed-by-the-read yes "$([ -e "$H760/.wait-o_r-7" ] && echo yes || echo no)"
h760_run green _builder_waits_clear o/r 7
t waits-clear-consumes-the-named-wait no "$([ -e "$H760/.wait-o_r-7" ] && echo yes || echo no)"
printf 'o/r 7 h1 2026-10-23T10:00:00Z\n' >"$H760/.wait-o_r-7"
t waits-a-moved-head-makes-the-wait-moot-and-due 7 "$(h760_run moved _builder_waits_due o/r)"
h760_run green _builder_waits_clear o/r 7
printf 'x/y 9 h1 2026-10-23T10:00:00Z\n' >"$H760/.wait-x_y-9"
t waits-another-repos-park-is-not-this-repos "" "$(h760_run green _builder_waits_due o/r)"
t waits-clear-leaves-another-repos-park yes "$(h760_run green _builder_waits_clear o/r 9; [ -e "$H760/.wait-x_y-9" ] && echo yes || echo no)"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t engine-clears-waits-only-after-the-resume-ran 1 "$(grep -c '^    \[ "${RUN_SESSION_RC:-1}" -ne 0 \] || _builder_waits_clear "$R" "$wait_nums"$' "$SHARED/lib/duty-builder.sh")"
# The helpers a session calls.
h760_gh="$TMP/h760-bin"; mkdir -p "$h760_gh"
# shellcheck disable=SC2016  # the stub's own source, read by the shell that runs it
printf '#!/usr/bin/env bash\ncase "$*" in *statusCheckRollup*) printf "%%s\\n" "$H760_ROLLUP" ;; *headRefOid*) printf "h1\\n" ;; esac\n' >"$h760_gh/gh"; chmod +x "$h760_gh/gh"
t wait-for-usage-is-2 2 "$(PATH="$h760_gh:$PATH" bash "$SHARED/bin/wait-for.sh" nothing >/dev/null 2>&1; echo $?)"
# The stub answers the poller's jq: `<pending> <total>`.
t wait-for-settled-checks-return-0 0 "$(H760_ROLLUP='0 2' PATH="$h760_gh:$PATH" bash "$SHARED/bin/wait-for.sh" checks o/r 7 --timeout 1 >/dev/null 2>&1; echo $?)"
# An EMPTY rollup is not "settled" on sight (the first poll after a push can
# land before any run is reported): it is confirmed on a second poll, and
# said for what it is. A pending run (REQUESTED counts) runs out the budget.
t wait-for-an-empty-rollup-is-confirmed-then-said "no checks reported on o/r#7" \
  "$(H760_ROLLUP='0 0' WAIT_FOR_POLL_S=0 PATH="$h760_gh:$PATH" bash "$SHARED/bin/wait-for.sh" checks o/r 7 --timeout 5 2>/dev/null | sed 's/ (.*//')"
t wait-for-a-pending-run-runs-out-the-budget 1 "$(H760_ROLLUP='1 1' WAIT_FOR_POLL_S=0 PATH="$h760_gh:$PATH" bash "$SHARED/bin/wait-for.sh" checks o/r 7 --timeout 2 >/dev/null 2>&1; echo $?)"
t wait-for-every-poller-counts-requested-and-expected-as-pending 3 "$(grep -l '"REQUESTED" or (.status // "") == "EXPECTED"' "$SHARED/bin/wait-for.sh" "$SHARED/lib/host/wake.sh" "$SHARED/lib/duty-builder.sh" | wc -l | tr -d ' ')"
t wait-for-pending-checks-run-out-the-budget 1 "$(H760_ROLLUP=2 PATH="$h760_gh:$PATH" bash "$SHARED/bin/wait-for.sh" checks o/r 7 --timeout 0 >/dev/null 2>&1; echo $?)"
t wait-for-a-gone-pid-returns-0 0 "$(bash "$SHARED/bin/wait-for.sh" pid 999999999 --timeout 5 >/dev/null 2>&1; echo $?)"
t park-until-writes-the-park "o/r 7 h1" "$(DUTY_DIR="$H760" PATH="$h760_gh:$PATH" bash "$SHARED/bin/park-until.sh" checks o/r 7 >/dev/null; cut -d' ' -f1-3 "$H760/.wait-o_r-7")"
t park-until-tells-the-session-to-end 1 "$(DUTY_DIR="$H760" PATH="$h760_gh:$PATH" bash "$SHARED/bin/park-until.sh" checks o/r 7 | grep -c 'End your session now')"
t park-until-usage-is-2 2 "$(bash "$SHARED/bin/park-until.sh" checks >/dev/null 2>&1; echo $?)"
# The prompts carry the contract, and every dispatch renders it.
t prompts-resume-reads-the-handoff-first 1 "$(grep -c '{{HANDOFF_BLOCK}}' "$SHARED/prompts/resume.txt")"
t prompts-ci-red-reads-the-handoff-first 1 "$(grep -c '{{HANDOFF_BLOCK}}' "$SHARED/prompts/ci-red.txt")"
t prompts-every-lane-carries-the-wait-rules "build ci-red resume review" \
  "$(grep -l '{{WAIT_RULES}}' "$SHARED"/prompts/{build,ci-red,resume,review}.txt | xargs -n1 basename | sed 's/\.txt$//' | paste -sd' ' -)"
t prompts-the-wait-fragment-names-the-helpers 2 "$(grep -o -E '(wait-for|park-until)\.sh' "$SHARED/prompts/fragment-wait-rules.txt" | sort -u | wc -l | tr -d ' ')"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t engine-renders-the-wait-rules-on-every-builder-lane 3 "$(grep -c 'WAIT_RULES="$wait_rules"' "$SHARED/lib/duty-builder.sh")"
t engine-renders-the-park-free-wait-rules-for-the-reviewer 1 "$(grep -c 'fragment-wait-rules-review.txt' "$SHARED/lib/duty-review.sh")"
t the-reviewer-wait-rules-carry-no-park 0 "$(grep -c 'park-until.sh checks' "$SHARED/prompts/fragment-wait-rules-review.txt")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t engine-passes-the-wait-reason-into-the-resume-session 1 "$(grep -c 'WAKE_REASON="${WAKE_REASON:-cron}${wait_why:+,$wait_why}"' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t engine-checkpoints-the-note-after-a-complete-session 1 "$(grep -c -- '-ne 0 \] || _handoff_block "$R"' "$SHARED/lib/duty-builder.sh")"
rm -rf "$H760" "$h760_gh"; unset -f h760_run

# ── #761 — the panel follows the head's risk ──────────────────────────────
p761_risk() {  # p761_risk <files-json-lines|FAIL> — tier|why
  (
    PANEL_RISK_PATHS='^(shared/lib|shared/bin|cli|\.github/workflows)/'
    PANEL_RISK_MAX_FILES=3 PANEL_RISK_MAX_LINES=80
    fx="$1"
    if [ "$fx" = FAIL ]; then gh() { return 1; }; else gh() { printf '%s\n' "$fx"; }; fi
    _panel_risk o/r 7; printf '%s|%s' "$_PANEL_RISK_TIER" "$_PANEL_RISK_WHY"
  )
}
t panel-risk-a-small-safe-change-is-low "low|2 file(s), 30 lines, no risky path" "$(p761_risk $'docs/a.md 20\nshared/test/x.sh 10')"
t panel-risk-a-risky-path-is-high "high|1 risky path(s): shared/lib/duty-builder.sh" "$(p761_risk $'shared/lib/duty-builder.sh 2')"
t panel-risk-too-many-files-is-high "high|4 files (bound 3)" "$(p761_risk $'a 1\nb 1\nc 1\nd 1')"
t panel-risk-too-many-lines-is-high "high|81 lines (bound 80)" "$(p761_risk $'docs/a.md 81')"
t panel-risk-an-unreadable-head-is-high "high|files unreadable" "$(p761_risk FAIL)"
p761_panel=$'rev-a\nrev-b\nrev-c'
t panel-sized-high-is-the-whole-panel "rev-a rev-b rev-c" "$(_panel_sized high 7 "$p761_panel" | paste -sd' ' -)"
t panel-sized-low-is-one-reviewer-rotated-by-number "rev-b" "$(PANEL_LOW_RISK_SIZE=1 _panel_sized low 7 "$p761_panel")"
t panel-sized-low-rotates "rev-c" "$(PANEL_LOW_RISK_SIZE=1 _panel_sized low 8 "$p761_panel")"
t panel-sized-low-can-take-two "rev-b rev-c" "$(PANEL_LOW_RISK_SIZE=2 _panel_sized low 7 "$p761_panel" | paste -sd' ' -)"
t panel-sized-a-panel-no-larger-than-the-size-is-whole "rev-a" "$(PANEL_LOW_RISK_SIZE=1 _panel_sized low 7 "rev-a")"
t panel-sized-a-bad-size-is-one "rev-b" "$(PANEL_LOW_RISK_SIZE=x _panel_sized low 7 "$p761_panel")"
t panel-knobs-ship "PANEL_LOW_RISK_SIZE=1 PANEL_RISK_MAX_FILES=3 PANEL_RISK_MAX_LINES=80" \
  "$(grep -hE '^PANEL_(LOW_RISK_SIZE|RISK_MAX_FILES|RISK_MAX_LINES)=' "$SHARED/conf/fleet.defaults.conf" | sort | paste -sd' ' -)"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t panel-request-posts-the-sizing-mark 1 "$(grep -c '"${MARK_PANEL_SIZED:-🧭 panel sized} $risk_tier at $gql_head:' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
# Two request sites — the engine's request and the flip-owed detection — and
# both ask from the sized panel.
t panel-request-requests-from-the-sized-panel 2 "$(grep -c -- '--argjson panel "$_PANEL_EFFECTIVE_JSON" --argjson signal "$signal_json"' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t panel-redraft-reads-the-round-against-the-sized-panel 1 "$(grep -c '^  eff_panel="$_PANEL_EFFECTIVE_JSON"$' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t panel-handoff-counts-against-the-sized-panel 1 "$(grep -c -- '--argjson panel "$_PANEL_EFFECTIVE_JSON" --argjson roster "$panel_json" --arg me "$ME" --arg mark_handoff' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the pin quotes the engine's source line verbatim
t panel-sizing-mark-is-keyed-once-per-head 1 "$(grep -c 'sized_marker="<!-- duty:panel-sized:$repo#$num@$gql_head -->"' "$SHARED/lib/duty-builder.sh")"
# The effective panel: a low-risk head is ONE reviewer, the same one every
# tick of that head; a high-risk head is the roster; a new head re-reads.
p761_eff() { # p761_eff <files-json-lines|FAIL> <head> [num]
  (
    PANEL_RISK_PATHS='^(shared/lib|shared/bin|cli|\.github/workflows)/'
    PANEL_RISK_MAX_FILES=3 PANEL_RISK_MAX_LINES=80 PANEL_LOW_RISK_SIZE=1
    fx="$1"
    if [ "$fx" = FAIL ]; then gh() { return 1; }; else gh() { printf '%s\n' "$fx"; }; fi
    _panel_effective o/r "${3:-7}" "$2" '["rev-a","rev-b","rev-c"]'
    printf '%s|%s' "$_PANEL_RISK_TIER" "$_PANEL_EFFECTIVE_JSON"
  )
}
rm -f "$TMP"/.panel-sized-*
t effective-panel-low-is-one-reviewer 'low|["rev-b"]' "$(p761_eff $'docs/a.md 2' h1)"
t effective-panel-same-head-is-cached-not-re-read 'low|["rev-b"]' "$(p761_eff FAIL h1)"
t effective-panel-new-head-re-reads 'high|["rev-a","rev-b","rev-c"]' "$(p761_eff FAIL h2)"
t effective-panel-cache-names-the-head-and-tier 1 "$(grep -c '^h2 high ' "$TMP/.panel-sized-o_r-7")"
rm -f "$TMP"/.panel-sized-*
unset -f p761_risk

suite_finish
