# duty-builder.sh — builder wakes, in doctrine priority order (FLEET.md):
# resume → ci-red → build (ready issues / completed rounds) → handoff →
# rebase, plus worktree hygiene. ci-red precedes build because your own red
# head outranks a new claim (ceremony BUILDER.md); the block order in this
# file IS the tick order, and this header is what FLEET.md is reconciled
# against. All review predicates use latestOpinionatedReviews, NEVER
# latestReviews or reviewDecision: COMMENTED can mask a standing opinion in
# latestReviews, while reviewDecision exists only
# under branch protection and stays "" here — keying on it silently stalled
# rounds for a day (ceremony#26, #39).
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

BUILDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ready_issue_lines REPO OPERATOR_LABEL — enumerate the ready issues this
# builder can actually claim. `operator` composes with `ready`, so it is
# excluded here, before the board count or seen-ledger derives a second fact
# from the set. An empty name is deliberately inert for fleets whose config
# predates the central label (#461).
_ready_issue_lines() {
  local repo="$1" operator_label="${2:-}"
  jq -r --arg repo "$repo" --arg operator "$operator_label" '
    .[]
    | select((.assignees | length) == 0)
    | select($operator == "" or ((.labels // []) | map(.name) | index($operator) | not))
    | "\($repo)#\(.number) \(.updatedAt)"
  '
}

# The clause is a rendered value rather than unconditional prompt prose: an
# older fleet with no configured label receives the exact prompt it did before
# #461, while a configured fleet tells the session what the engine enforced.
_operator_build_prompt_clause() {
  local operator_label="${1:-}"
  [ -n "$operator_label" ] || return 0
  printf 'a ready issue carrying `%s` is operator-owned work, not work for a builder; ' \
    "$operator_label"
}

# Mutates the caller's dynamically scoped ready_count/ready_items/slot_prs.
# Withheld items must disappear from both the prompt and the eventual
# seen-ledger. slot_prs is the gate's OWN record that it fired: downstream, the
# no-duty line has to name which of three causes zeroed the tick, and once this
# has run, a zeroed ready_count is indistinguishable from an empty board and a
# ledgered one (#345).
_gate_ready_for_open_pr() {
  if [ "$open_pr_count" -gt 0 ] && [ "$ready_count" -gt 0 ]; then
    log "$R: $open_pr_count open authored PR(s) occupy the build slot — not claiming a ready issue"
    # Unconditional: the gate's record of having fired must not depend on the
    # id render succeeding. If open_pr_ids is empty (jq failing on mine_json
    # after `jq length` returned non-zero) the count still names the slot, and
    # the no-duty line cannot fall through to blaming the ledger or an empty
    # board for what the slot did (#345, review condition).
    slot_prs="${open_pr_ids:-$open_pr_count open PR(s)}"
    ready_count=0
    ready_items=""
    return 0
  fi
  return 1
}

# --- The decline: a ready issue the session judged unbuildable ---------------
#
# The BUILD block below has told whoever reads this source, since #59, that a
# ready issue clears its signal only on a claim "which is an action the session
# may correctly decline (out of scope, unbuildable, needs a ruling)". Nothing
# carried that to the session — it is handed build.txt, which said claim it and
# build it — and nothing carried the decision back: _ready_lines_to_commit
# reduces the whole discovery to an id and a timestamp in a per-box dotfile that
# dies with the box. So the board, the only memory that outlives a box, learned
# nothing; every sibling box re-derived the same refusal from scratch, and
# triage, which OWES the repair (TRIAGE.md's claim-time clause, ceremony#487),
# never got the input. What stopped the claim in practice was a hand-written
# paragraph in the consumer repo's issue body, absent by default, and where it
# was absent it did not hold — box#180 was claimed against `df`-on-a-host
# criteria and caught only afterwards (#462).
#
# FOUR reasons, not the three that comment names. #461 removes `operator-owned`
# as a cause by keeping such an issue off `ready` at all; until it ships the
# session still meets one, and the other three are spec defects no label
# prevents. The set is CLOSED and revalidated on read-back: an unrecognised
# token is not a reason and is never reported as one, because the line an
# operator reads must not be writable by a session's free text.
_DECLINE_MARK='🚫 build declined'
_DECLINE_REASONS='out-of-scope unbuildable needs-ruling operator-owned'

# _decline_marker_key REPO NUM — the marker line's fixed prefix, up to and
# including the separator before the reason. One renderer for the reader here
# and, through {{DECLINE_MARK}}, for the prompt that writes it: two literals
# that must agree is how the writer and the reader drift apart.
_decline_marker_key() { printf '%s — %s#%s — ' "$_DECLINE_MARK" "$1" "$2"; }

# _decline_reason REPO NUM — the reason MY OWN decline marker names on that
# issue, or empty. Two rules, both load-bearing:
#
#   my comments only, and an exact marker LINE. Never a substring of a body:
#   this issue, a reviewer quoting the marker, or a human pasting it would
#   otherwise become a fact the engine reports. post-once.sh ruled the same way
#   after ceremony#32, where a contains() match let a short SHA false-match a
#   different announce; a whole-line compare is the form that keeps the
#   precedent while still keying on something narrower than a whole body.
#
#   newest wins. A session declining for a different one of the four is a
#   CHANGED conclusion, which D2 says posts — so it must also govern, or the
#   engine would keep reporting the superseded reason forever.
#
# Empty on any failure: no reason is reported, the ledger branch says what it
# always said, and nothing is invented from a listing that did not load.
_decline_reason() {
  local repo="$1" num="$2"
  gh api "repos/$repo/issues/$num/comments" --paginate 2>/dev/null \
    | jq -rs --arg me "$ME" --arg key "$(_decline_marker_key "$repo" "$num")" \
        --arg reasons "$_DECLINE_REASONS" '
      ($reasons | split(" ")) as $ok
      | [ add[]
          | . as $c
          | select($c.user.login == $me)
          | ($c.body | split("\n") | map(sub("\r$"; "")))[]
          | select(startswith($key))
          | ltrimstr($key)
          | select(IN($ok[]))
          | {reason: ., at: $c.created_at} ]
      | sort_by(.at) | last | .reason // ""
    ' 2>/dev/null || true
}

# _record_declines REPO SLUG LINES [BOARD_REREAD] — write the reasons behind
# the ready lines this tick is about to ledger, one `<repo>#<n> <reason>` per
# declined id.
#
# Keyed to the ledger commit, not to the enumerated board: the caller passes
# exactly what ledger_commit is given, so the two records can never disagree
# about which ids the session left behind. Whole-set, replacing the file — a
# ready line that left the board has no decline to report and must not linger.
# Per repo for the reason every other builder state file is (#345): _builder_repo
# runs once per repo and one shared file makes each clobber the last.
#
# BOARD_REREAD=0 MEANS COULD NOT LOOK, WHICH IS NOT NOTHING TO RECORD, and it
# is why the whole-set write needs a fourth argument rather than reading the
# empty set at face value. On #264's re-query-failed path the caller has no
# lines to commit but also no knowledge, and unlinking there would cost the
# reasons for the ids EARLIER ticks already ledgered — permanently, because the
# marker dedup is working as designed and will not re-post an unchanged
# conclusion, so nothing puts them back. The operator silently drops to
# `N ready held by seen-ledger`, the wrong noun this issue removes: the same
# fact-never-reaches-the-reader defect, triggered by an API blip instead of a
# missing wire. Returning early keeps the last known-good record, and what
# stops that record going stale is _declined_for_board's intersection with the
# live board — never this write. Default 1 so a caller that genuinely read the
# board says nothing extra, and the empty set keeps clearing the file (#462).
_record_declines() {
  local repo="$1" slug="$2" lines="$3" board_reread="${4:-1}" line id reason out=""
  [ "$board_reread" -eq 1 ] || return 0
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    id="${line%% *}"
    reason="$(_decline_reason "$repo" "${id#*#}")"
    [ -n "$reason" ] || continue
    out="$out$id $reason"$'\n'
  done <<<"$lines"
  if [ -n "${out//[[:space:]]/}" ]; then
    printf '%s' "$out" >"$DUTY_DIR/.declined-build.$slug"
  else
    rm -f "$DUTY_DIR/.declined-build.$slug"
  fi
}

# _declined_for_board SLUG READY_LINES — the recorded reasons, one per line,
# for the ids still enumerated on the board right now. The intersection is what
# keeps a closed or claimed issue from being counted as a live decline on a tick
# where no session ran to refresh the record.
_declined_for_board() {
  local slug="$1" ready_lines="$2"
  local file="$DUTY_DIR/.declined-build.$slug"
  [ -s "$file" ] || return 0
  [ -n "${ready_lines//[[:space:]]/}" ] || return 0
  awk 'NR==FNR { if (NF>=1) board[$1]=1; next } NF>=2 { if ($1 in board) print $2 }' \
    <(printf '%s\n' "$ready_lines") "$file"
}

# _declined_summary REASONS — `unbuildable (3), needs-ruling (1)`. Rendered in
# the canonical reason order rather than by count, so the same board reads the
# same way on every tick and a diff of two log lines means something changed.
_declined_summary() {
  local reasons="$1" r n out=""
  for r in $_DECLINE_REASONS; do
    n="$(awk -v r="$r" '$1 == r { c++ } END { print c+0 }' <<<"$reasons")"
    [ "$n" -gt 0 ] || continue
    out="$out${out:+, }$r ($n)"
  done
  printf '%s' "$out"
}

# _no_build_duty_reason BOARD_READY LEDGERED_ROUNDS SLOT_PRS BOARD_READ DECLINED
# — the parenthetical on `no build duty`.
#
# One spelling for three causes is a diagnosis tax on every reader. On
# 2026-08-03 the operator read `build duty (ready unclaimed=8)` → claim → `no
# build duty` ten minutes later, which is indistinguishable from the burial bug
# #264 exists to prevent; an hour of ledger reads later the answer was that the
# slot was held. The prefix stays `$R: no build duty` so `crew status` and every
# grep consumer are untouched — only the parenthetical is new (#345).
#
# The order is causal, not cosmetic — first match wins, and the first match is
# the most useful answer, not the only true one:
#   slot        the gate zeroed a ready count that was still non-zero AFTER the
#               ledger ran, so the ready side is the slot's doing. The rounds
#               side can be ledger-held on the same tick — an open PR whose
#               owed round is already seen at that head — and this branch then
#               prints the slot clause alone: incomplete, never false, and the
#               slot is the answer an operator is actually looking for.
#   seen-ledger nothing is left for the slot to explain, and the ledger hid all
#               of what was enumerated. In this branch the counts are
#               whole-set: a partial suppression leaves ready_count/cr_count
#               non-zero and never reaches here.
#   board empty what is left when nothing was enumerated at all.
# `board unread` is the fourth state and not a fourth cause: the issue listing
# failed, so which of the two above holds is unknown and neither may be
# asserted. The warn at that call site names the failure; this says only that
# the board behind the line was never read.
#
# `declined` is not a fifth cause either — it is the ledger branch finally able
# to name what it is holding. `N ready held by seen-ledger` was honest and it
# was the wrong noun: it named the MECHANISM and never the cause, so an operator
# could not tell a spec defect from a box that ran out of context, and could not
# tell that the refusal would be identical on every box forever. Where the
# record has a reason for some of the held ready lines, the two halves are
# reported separately: a decline is triage's to repair, a plain ledger hold is
# not, and one number covering both is a number nobody can act on (#462). It
# ranks under the slot for the reason the slot outranks the ledger — the slot is
# the answer to "why did the claim not happen" whenever it fired.
_no_build_duty_reason() {
  local board_ready="$1" ledgered_rounds="$2" slot_prs="$3" board_read="$4"
  local declined="${5:-}"
  local d_count=0 d_summary="" held_ready="$board_ready"
  if [ -n "${declined//[[:space:]]/}" ]; then
    d_count="$(awk 'NF{c++} END{print c+0}' <<<"$declined")"
    d_summary="$(_declined_summary "$declined")"
    held_ready=$((board_ready - d_count))
    [ "$held_ready" -lt 0 ] && held_ready=0
  fi
  if [ -n "$slot_prs" ]; then
    # The board count is the pre-ledger, pre-gate one on purpose: it is the
    # board's own fact, the number an operator sees on the queue, and it is what
    # makes #264's discriminating read work from a single tick's log.
    printf 'slot held by %s; board holds %s ready' "$slot_prs" "$board_ready"
  elif [ "$d_count" -gt 0 ]; then
    if [ "$held_ready" -gt 0 ]; then
      printf '%s ready held by seen-ledger, ' "$held_ready"
    fi
    printf '%s ready declined: %s' "$d_count" "$d_summary"
    if [ "$ledgered_rounds" -gt 0 ]; then
      printf ', %s round(s) held by seen-ledger' "$ledgered_rounds"
    fi
  elif [ "$board_ready" -gt 0 ] && [ "$ledgered_rounds" -gt 0 ]; then
    printf '%s ready, %s round(s) held by seen-ledger' "$board_ready" "$ledgered_rounds"
  elif [ "$board_ready" -gt 0 ]; then
    printf '%s ready held by seen-ledger' "$board_ready"
  elif [ "$ledgered_rounds" -gt 0 ]; then
    printf '%s round(s) held by seen-ledger' "$ledgered_rounds"
  elif [ "$board_read" = 0 ]; then
    printf 'board unread'
  else
    printf 'board empty'
  fi
}

# _ready_lines_to_commit PRE_LINES POST_IDS — preserve the whole enumerated
# ready set only when the completed session declined every issue. If even one
# pre-session id is no longer pickable, the session acted on the set and none
# of the remaining (withheld) ready lines belongs in the ledger (#264).
_ready_lines_to_commit() {
  local pre_lines="$1" post_ids="$2" line id
  [ -n "${pre_lines//[[:space:]]/}" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%% *}"
    grep -qxF "$id" <<<"$post_ids" || return 0
  done <<<"$pre_lines"
  printf '%s\n' "$pre_lines"
}

# Existing boxes may already have pickable work buried by the old whole-set
# commit. Re-open every build signal once after upgrade; ready and round ids
# share a key shape, so the old file cannot be narrowed safely (#264 D5).
_repair_seen_build_264() {
  local marker="$DUTY_DIR/.seen-build.repair-264"
  [ -e "$marker" ] && return 0
  rm -f "$DUTY_DIR/.seen-build"
  find "$DUTY_DIR" -maxdepth 1 -type f -name '.suppressed-build.*' -delete 2>/dev/null || true
  : >"$marker"
  log "builder: repaired build ledgers for #264; cleared .seen-build and suppression state once"
}

# _orphan_claim_nums REPO-NAME CLAIMED MERGED-HEADS OPEN-HEADS — return the
# claimed issue numbers whose build branch is neither merged nor attached to an
# open PR. The head listings are complete before matching starts: under the
# caller's pipefail setting, an early-exiting grep must never race their writer.
_orphan_claim_nums() {
  local name="$1" claimed_nums="$2" merged_heads="$3" open_heads="$4"
  local N branch orphan_nums=""
  for N in $claimed_nums; do
    branch="$(gh api "repos/$ME/$name/git/matching-refs/heads/build/$N-" \
      --jq '.[0].ref // "" | sub("^refs/heads/"; "")' 2>/dev/null || echo "")"
    [ -z "$branch" ] && continue
    if grep -qx "$branch" <<<"$merged_heads"; then continue; fi
    if ! grep -qx "$branch" <<<"$open_heads"; then
      orphan_nums="$orphan_nums $N"
    fi
  done
  printf '%s' "$orphan_nums"
}

# Author-side duty repos are repos.txt-scoped, like every other module
# (danmt 2026-07-25). This previously swept the org, on the rationale that
# cast#143's converged round sat unowed 40 minutes while every tick looked
# only at ceremony — but an org-wide author sweep also lets a builder box
# act on repos nobody put in its registry, which is the same unbounded write
# surface the reviewer sweep had.
#
# THE READ IS THE REGISTRY TOO, NOT ONLY THE WRITE (#728, danmt 2026-09-12).
# Closing that write surface left an awareness pass behind it,
# `_warn_unscoped_authored`, which searched `--author=$ME` across the whole of
# GitHub and logged every open PR that fell outside repos.txt. It was sized for
# an identity whose entire life is the fleet. Since #714 the operator's own
# account is a supported box identity, and then the set it enumerates is the
# operator's whole open-pull-request list, personal repos included, re-fetched
# every five minutes on every builder box that account is on. The `0.1.3-rc2`
# round read five such rows per tick and named them in duty.log.
#
# The pass is REMOVED rather than narrowed, because narrowed it is empty. This
# function is the registry-derived authored-PR read — one pulls page per carried
# repo, object endpoints, no search index — and what it finds is already spoken
# by _gate_ready_for_open_pr's `slot held by <repo>#<n>` line. A second pass
# over the same set would report the same PRs twice and nothing else.
#
# WHERE CAST#143'S SIGNAL WENT. Its shape is a converged round nobody hears
# about, and the fleet's answer to that shape is notify.sh, which sweeps
# repos.txt UNION notify-repos.txt — a list that exists for precisely this,
# "cross-repo handoff targets" the fleet can flag "without working them", and
# which no repos.txt narrowing touches. The condition that produces the signal
# is an open non-draft PR carrying `$LABEL_NEEDS_HUMAN` in a listed repo; its
# phase-3 desync invariant then alerts when such a PR is seen and not tracked,
# which is the silence cast#143 and rig#112 actually were. The standing channel
# for handing this box work outside its beat stays duty-attention.sh, which
# reports and alerts on out-of-registry demands and acts on none (crew#66).
_discover_my_pr_repos() {
  if [ -n "$REVIEW_MY_PR_REPOS" ] || has_role reviewer; then
    # shellcheck disable=SC2086  # splitting the space-joined list is the point
    printf '%s\n' $REVIEW_MY_PR_REPOS
    return 0
  fi
  local SR
  while IFS= read -r SR; do
    [ -n "$SR" ] || continue
    if gh api "repos/$SR/pulls?state=open&per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE" --paginate 2>/dev/null \
      | jq -se --arg me "$ME" '[add[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      printf '%s\n' "$SR"
    fi
  done < <(read_repo_list "$REPOS_FILE")
}

# _redraft_authored_pr REPO NUM PANEL_JSON — convert my ready PR back to draft after a
# round closes without full approval. The last reviewer can write the triage-
# permitted state:addressing label, but cannot draft another author's PR; this
# author-side tick owns that mutation. Ignore an already-standing addressing
# label only in this evaluation: the reconciler may have written it before this
# tick, and conversion must not depend on which actor won that independent
# best-effort write. A current-head answer signal newer than the verdict spends
# this round's conversion licence: once the builder marks that unchanged head
# ready, leave it ready so the ordinary green gate can re-request the panel.
# A failed conversion remains ready and retries next tick.
_redraft_authored_pr() {
  local repo="$1" num="$2" eff_panel="$3" owner name payload redraft pr_id is_draft
  local head signal_json answered_head to_request
  owner="${repo%%/*}"; name="${repo##*/}"
  if ! payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      id
      isDraft
      headRefOid
      author{login}
      labels(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{name}}
      comments(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){nodes{author{login} body createdAt}}
      reviewRequests(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{requestedReviewer{... on User{login}}}}
      latestOpinionatedReviews(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{author{login} state submittedAt commit{oid}}}
    } }
  }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)"; then
    warn "$repo#$num: draft conversion lookup failed; retrying on the author's next tick"
    return 0
  fi
  is_draft="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.isDraft // false' 2>/dev/null)"
  [ "$is_draft" = false ] || return 0
  # The round is read against the panel sized for THIS head (#761): the
  # reviewers the engine asked are the ones whose verdicts close it.
  _panel_effective "$repo" "$num" "$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)" "$eff_panel"
  # The whole roster rides beside the sized subset: a request still open to a
  # reviewer outside the subset (a head requested whole under the old rule, a
  # PR whose risk dropped) is a round still open, never a closed one.
  local roster_panel="$eff_panel"
  eff_panel="$_PANEL_EFFECTIVE_JSON"
  redraft="$(printf '%s' "$payload" \
    | jq -c --arg addressing "$LABEL_ADDRESSING" \
        '.data.repository.pullRequest.labels.nodes |= map(select(.name != $addressing))' 2>/dev/null \
    | jq -r --argjson panel "$eff_panel" --argjson roster "$roster_panel" --arg addressing "$LABEL_ADDRESSING" \
        -f "$DUTY_DIR/lib/jq/addressing.jq" 2>/dev/null || echo err)"
  case "$redraft" in
    true)
      head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
      signal_json="$(printf '%s' "$payload" \
        | jq -c --arg me "$ME" --arg mark "$MARK_ANSWERED" \
            -f "$DUTY_DIR/lib/jq/answered-head.jq" 2>/dev/null)"
      [ -n "$signal_json" ] || signal_json='{"sha":"","createdAt":""}'
      answered_head="$(printf '%s' "$signal_json" | jq -r '.sha // ""' 2>/dev/null)"
      if [ -n "$head" ] && [ "$answered_head" = "$head" ]; then
        to_request="$(printf '%s' "$payload" \
          | jq -r --argjson panel "$eff_panel" --argjson signal "$signal_json" \
              -f "$DUTY_DIR/lib/jq/request-panel.jq" 2>/dev/null)"
        if [ -n "${to_request//[[:space:]]/}" ]; then
          log "$repo#$num: current-head round already answered — leaving ready for the green-gated panel request"
          return 0
        fi
      fi
      pr_id="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.id // ""' 2>/dev/null)"
      if [ -z "$pr_id" ]; then
        warn "$repo#$num: draft conversion missing pull request id; retrying on the author's next tick"
      else
        log "$repo#$num: round closed without full approval — author converting to draft"
        gh api graphql -f query='mutation($id:ID!){
          convertPullRequestToDraft(input:{pullRequestId:$id}){pullRequest{isDraft}}
        }' -f id="$pr_id" >/dev/null 2>&1 \
          || warn "$repo#$num: could not convert to draft; retrying on the author's next tick"
      fi
      ;;
    false) : ;;
    *) warn "$repo#$num: draft conversion eval failed; skipping (best-effort)" ;;
  esac
  return 0
}

_redraft_authored_rounds() {
  local repo="$1" eff_panel="$2" nums num
  nums="$(gh pr list -R "$repo" --state open --author "$ME" \
    --json number,isDraft --jq '.[] | select(.isDraft | not) | .number' 2>/dev/null || echo err)"
  if [ "$nums" = err ]; then
    warn "$repo: authored PR listing failed; skipping draft conversion this tick"
    return 0
  fi
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    _redraft_authored_pr "$repo" "$num" "$eff_panel"
  done <<<"$nums"
}

# _mirror_rounds REPO NUM — render review facts into the PR body's rolling
# `## Round log` (#504, ceremony#418). The builder owns Current state and each
# row's requested/done prose; the engine fills the round number, head, verdicts
# and permalink to the existing reply comment. round-log.jq keys each row by
# `<!-- round:<head-sha> -->` and returns the whole new body only when something
# is un-recorded — so an already-rendered (or legacy verbatim-mirrored) round
# makes a retry a no-op. Body writes go through REST: `gh pr edit --body-file` dies
# on crew's projects-classic GraphQL and writes nothing. This is best-effort
# and the handoff NEVER blocks on it (the same rule as the label write).
_mirror_rounds() {
  # FINAL (default false) is true only at the handoff straggler: it finalizes
  # the live last round too. Per-tick mirroring leaves the live round deferred
  # so a still-arriving round is never rendered before its facts settle.
  local repo="$1" num="$2" final="${3:-false}" owner name payload newbody measured
  owner="${repo%%/*}"; name="${repo##*/}"
  # The assignment's status is tested outside the substitution: GraphQL errors
  # may write a non-empty JSON body to stdout, but their non-zero status still
  # reaches this guard (#155).
  payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      body
      headRefOid
      commits(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){totalCount nodes{commit{oid committedDate}}}
      reviews(first:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){totalCount nodes{author{login} state commit{oid} submittedAt}}
      comments(first:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){totalCount nodes{author{login} body url createdAt}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)" \
    || { warn "$repo#$num: round-log fetch failed; body left as-is (handoff continues)"; return 0; }
  measured="$(printf '%s' "$payload" | jq -r '
    [.data.repository.pullRequest.commits.totalCount,
     .data.repository.pullRequest.reviews.totalCount,
     .data.repository.pullRequest.comments.totalCount]
    | map(. // 0) | max' 2>/dev/null)" || measured=invalid
  operating_limit_assess github_connection_nodes "$measured" "$repo" "$num" \
    'round-log history exceeds its unpaginated GraphQL window' || return 0
  newbody="$(printf '%s' "$payload" \
    | jq -r --arg me "$ME" --argjson final "$final" \
        --arg mark_answered "$MARK_ANSWERED" \
        --arg mark_addressing "$MARK_ADDRESSING" \
        --arg mark_resume "$MARK_RESUME" \
        --arg mark_handoff "$MARK_HANDOFF" \
        -f "$DUTY_DIR/lib/jq/round-log.jq" 2>/dev/null)" \
    || { warn "$repo#$num: round-log render failed; body left as-is"; return 0; }
  [ -n "$newbody" ] || return 0   # every round already recorded — write nothing
  printf '%s' "$newbody" | jq -Rs '{body:.}' \
    | gh api -X PATCH "repos/$repo/pulls/$num" --input - >/dev/null 2>&1 \
    || warn "$repo#$num: round-log body write failed (handoff continues)"
}

# _handoff_comment REPO NUM — echo the engine-rendered handoff comment: the
# terminal facts and nothing composed. First line is MARK_HANDOFF + the head
# SHA so post-once.sh's exact-body dedup is stable across a retried tick.
# Echoes empty on a fetch failure (the caller then skips only the comment).
_handoff_comment() {
  local repo="$1" num="$2" owner name
  owner="${repo%%/*}"; name="${repo##*/}"
  gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      headRefOid
      latestOpinionatedReviews(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{author{login} state commit{oid}}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null \
  | jq -r --arg mark "$MARK_HANDOFF" '
      .data.repository.pullRequest as $pr
      | ( $pr.latestOpinionatedReviews.nodes
          | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
                | .author.login) | unique ) as $approvers
      | $mark + " " + $pr.headRefOid + "\n\n"
        + "Every panel verdict approves the current head `" + $pr.headRefOid + "`"
        + (if ($approvers | length) > 0
           then " — " + ($approvers | map("@" + .) | join(", ")) else "" end)
        + ".\n\nThe round-by-round record is in the PR body **Round log**, above."
        + "\n\n_Rendered by the engine from the review state — no prose composed at handoff._"
    ' 2>/dev/null
}

# _handoff_finalize REPO NUM — the whole handoff, engine-side, no session and
# no clone (#91). Every step is idempotent and NONE gates the next: the label
# is what notify.sh polls, and making it contingent on a comment or a request
# that can fail is the invisible-escalation class the notifier exists to
# prevent. Order is chosen for crash-safety, not priority — the MARK_HANDOFF
# comment is written LAST because it is the convergence refire guard
# (converged.jq's $handed_at_head, #535): a box that dies before it refires
# next tick, and every write above is a no-op on the retry (an already-
# requested reviewer, an already-present label, an already-present round
# marker; the comment itself is post-once's exact-body dedup). A comment that
# does not post leaves the guard unarmed on purpose — the next tick retries the
# whole handoff, loudly, until the fact is on the record. Requesting the human
# does not suppress the refire on its own — converged.jq's $no_panel_reqs
# counts only PANEL requests, and the human is off-panel — and neither does
# the label: it is the reconciler's to clear, and reading it as the guard is
# the flood #535 measured.
#
# What the human's request DOES spend is round_owed's second clause (#452): the
# builder wake for a human CHANGES_REQUESTED is "blocking at the head and not
# currently requested", so this line is where a wake that was answered stops
# firing — the mirror of the panel clause's outstanding-request guard.
# converged.jq's own human disqualifier is what keeps a blocked head from
# handing off while the ball is the builder's.
_handoff_finalize() {
  local repo="$1" num="$2" comment
  _mirror_rounds "$repo" "$num" true   # finalize the live round: the PR is converging
  gh api "repos/$repo/pulls/$num/requested_reviewers" \
    -f "reviewers[]=$FLEET_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: review request for @$FLEET_HUMAN failed (already requested?)"
  gh issue edit "$num" -R "$repo" --add-label "$LABEL_NEEDS_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: could not set $LABEL_NEEDS_HUMAN"
  # LAST: the refire guard. Posted after the label so a crash between the two
  # retries the handoff rather than stranding a handed-off head without its
  # label.
  comment="$(_handoff_comment "$repo" "$num")"
  if [ -n "$comment" ]; then
    "$BIN_DIR/post-once.sh" "$repo" "$num" "$comment" \
      || warn "$repo#$num: handoff comment did not post (label set; the handoff retries next tick until it does)"
  else
    warn "$repo#$num: could not render the handoff comment this tick (label set; the handoff retries next tick)"
  fi
}

_report_unsignalled_hold() {
  local repo="$1" num="$2" head="$3" item fresh state
  item="$repo#$num@$head head"
  fresh="$(printf '%s\n' "$item" | ledger_filter "$DUTY_DIR/.seen-round-signal")"
  if [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" | ledger_commit "$DUTY_DIR/.seen-round-signal"
  fi
  state="$DUTY_DIR/.suppressed-round-signal.${repo//\//__}.$num"
  printf '%s\n' "$item" \
    | ledger_suppressed "$DUTY_DIR/.seen-round-signal" \
    | report_suppressed "$state" \
        "$repo#$num: no round-answered signal at head ${head:0:12} — not requesting (#133)"
}

# --- The round cap: the engine counts, and says the boundary is here (#502) ---
#
# Doctrine gives the engine exactly one half of this rule. "You perform the cut,
# at the round close … nothing counts rounds for you, nothing enforces the cut,
# and nothing stops a sixth round on one PR. Where an engine does count and says
# the boundary is here, that is instruction and never performance." So what lives
# below is a census and a held request. The engine opens no successor, closes no
# predecessor and edits no body; the nine-step procedure is the session's, and
# its text is in fragment-round-rules.txt where every builder wake reads it.
#
# ROUND_CAP_PRS is the census answer the rest of the tick reads: the `repo#num`
# of every open authored PR that has reached the cap, space-separated.
# ROUND_CAP_NAMED is the same set rendered for the prompt slot, or `-`.
# Globals rather than a return value for the reason _resume_attach_comments
# states: every report here is a log line, log writes to stdout, and a function
# returning its data down the same channel would fold its warnings into it.
ROUND_CAP_PRS=""
ROUND_CAP_NAMED="-"
# THERE IS NO THIRD GLOBAL FOR THE ROUND COUNTS (#503, round 1). The census's
# other answer — every open authored PR's count and the issue it was recorded
# against, not only the ones at the boundary — is recorded on the
# `.seen-round-count` ledger and said in the log, and those two ARE the record.
# A `ROUND_CAP_COUNTS` variable carried the same figures for one revision of
# this change and no production code ever read it; only a test did, which made
# the test's subject a channel that carried nothing. The ledger and the log line
# are what a reader can find later, so they are what the cases assert on.

# _round_cap_census REPO PANEL_JSON LISTING — count every open authored PR's
# rounds and record the ones at the cap.
#
# DRAFTS ARE COUNTED, and that is the whole reason this is a census of its own
# rather than a field folded into _redraft_authored_pr's fetch. The cut is
# performed on a PR the engine has just returned to draft: the round closed
# without full approval, the author tick drafted it, and the session that answers
# round 5 and performs the cut is the RESUME session on that draft. A census that
# skipped drafts would name the boundary on the one tick before it mattered and
# be silent on every tick after it.
#
# It costs one GraphQL call per open authored PR per tick, and there is no
# cheaper shape: `reviews` is what distinguishes five rounds from one, and it is
# neither on the `gh pr list` listing nor derivable from
# `latestOpinionatedReviews`, which carries one verdict per author. The listing
# is the one this tick already fetched, so the enumeration itself adds no call.
#
# A fetch or eval failure counts that PR as not-at-cap for the tick and warns.
# That is the safe direction: an unnamed boundary costs a tick and the next
# census re-states it, where a manufactured one would tell a session to close a
# PR that has rounds left.
_round_cap_census() {
  local repo="$1" panel_json="$2" listing="$3"
  local owner name num payload capjson rounds at_cap named="" items="" fresh measured cap_head
  local issue record="" record_fresh
  ROUND_CAP_PRS=""
  ROUND_CAP_NAMED="-"
  owner="${repo%%/*}"; name="${repo##*/}"
  if [ -z "$listing" ] || [ "$listing" = err ]; then
    warn "$repo: round-cap census skipped (the authored-PR listing failed); no boundary named this tick"
    return 0
  fi
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    if ! payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
      repository(owner:$owner,name:$name){ pullRequest(number:$num){
        headRefOid body
        commits(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){totalCount nodes{commit{oid committedDate}}}
        reviews(first:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){totalCount nodes{author{login} state commit{oid} submittedAt}}
      } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)"; then
      warn "$repo#$num: round-cap fetch failed; not counted this tick"
      continue
    fi
    measured="$(printf '%s' "$payload" | jq -r '
      [.data.repository.pullRequest.commits.totalCount,
       .data.repository.pullRequest.reviews.totalCount]
      | map(. // 0) | max' 2>/dev/null)" || measured=invalid
    if ! operating_limit_assess github_connection_nodes "$measured" "$repo" "$num" \
        'round-cap history exceeds its unpaginated GraphQL window'; then
      continue
    fi
    # THE SIZED PANEL, here as at the request, the redraft and the handoff
    # (#761): a round closes when the reviewers THIS head was asked of have all
    # spoken, so a low-risk PR reviewed by one sized reviewer reaches the cap on
    # that reviewer's five rounds — counted against the whole roster it never
    # would, and the PR would cycle past five without the cut.
    cap_head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
    _panel_effective "$repo" "$num" "$cap_head" "$panel_json"
    capjson="$(printf '%s' "$payload" \
      | jq -c -L "$DUTY_DIR/lib/jq" --argjson panel "$_PANEL_EFFECTIVE_JSON" \
          -f "$DUTY_DIR/lib/jq/round-cap.jq" 2>/dev/null)" || capjson="" # Decision-path empty fallback: the next branch warns and excludes this PR from the destructive cap decision.
    if [ -z "$capjson" ]; then
      warn "$repo#$num: round-cap eval failed; not counted this tick"
      continue
    fi
    rounds="$(printf '%s' "$capjson" | jq -r '.rounds // 0' 2>/dev/null || echo 0)"
    at_cap="$(printf '%s' "$capjson" | jq -r '.at_cap // false' 2>/dev/null || echo false)"
    # THE COUNT IS RECORDED AGAINST THE ISSUE, AND FOR EVERY PR (#503 D1, D2).
    # This is above the at-cap `continue` on purpose: a record only capped PRs
    # reach is the builder-side counter "that surfaces when a PR stalls", which
    # is the shape D1 names as insufficient. Every open authored PR's count is
    # recorded, whether or not it is anywhere near five.
    #
    # The issue is read from the PR body with the same pattern the resume
    # fingerprints use, so `Refs #N` resolves as well as `Closes #N` — which is
    # what makes a cut predecessor still name the issue it stopped closing.
    # An unattributed PR records `-`: dropping it would hide a PR whose body
    # names no issue, which is a board fact worth seeing rather than a gap.
    issue="$(printf '%s' "$payload" | jq -r --arg re "$_RESUME_ISSUE_RE" \
      '(.data.repository.pullRequest.body // "")
       | (first(capture($re; "i") | .n) // "-")' 2>/dev/null)" || issue="-"
    [ -n "$issue" ] || issue="-"
    record="$record$(printf '%s#%s %02d@%s' "$repo" "$num" "$rounds" "$issue")"$'\n'
    [ "$at_cap" = true ] || continue
    ROUND_CAP_PRS="${ROUND_CAP_PRS:+$ROUND_CAP_PRS }$repo#$num"
    named="${named:+$named; }$repo#$num ($rounds rounds)"
    items="$items$(printf '%s#%s %02d' "$repo" "$num" "$rounds")"$'\n'
  done < <(printf '%s' "$listing" | jq -r '.[].number' 2>/dev/null)
  # Said once per (PR, count, issue), on its own ledger. Separate from
  # .seen-round-cap because the two say different things and clear on different
  # events: the cap line is an instruction that stands until the builder cuts,
  # while this is a measurement that changes every time a round closes. Sharing
  # one ledger would let a PR reaching the cap swallow its own round record.
  record_fresh="$(printf '%s' "$record" | ledger_filter "$DUTY_DIR/.seen-round-count")"
  if [ -n "${record_fresh//[[:space:]]/}" ]; then
    log "$repo: rounds recorded against the issue — $(printf '%s' "$record_fresh" \
      | awk 'NF { split($2, f, "@"); n = f[1] + 0
                  printf "%s%s (%d round(s)) -> %s", sep, $1,
                         n, (f[2] == "-" ? "no issue named" : "#" f[2]); sep = "; " }')"
    printf '%s' "$record_fresh" | ledger_commit "$DUTY_DIR/.seen-round-count"
  fi
  [ -n "$named" ] && ROUND_CAP_NAMED="$named"
  # Said once per (PR, round count), not once per tick. A PR sits at the cap for
  # every tick until the builder cuts it, and #167's rule applies: a line that
  # repeats forever is wallpaper. The count is the ledger's value, zero-padded so
  # a lexical compare stays a numeric one, so a sixth round opening in spite of
  # the rule re-states the line instead of being swallowed by the first.
  #
  # Committed immediately and not on a session's rc, unlike .seen-build and
  # .seen-ci-red: this ledger gates a LOG LINE and never a dispatch, so there is
  # no wake to lose by committing early. The instruction itself is in the prompt
  # on every tick regardless — silence here buys quiet, never a withheld boundary.
  fresh="$(printf '%s' "$items" | ledger_filter "$DUTY_DIR/.seen-round-cap")"
  if [ -n "${fresh//[[:space:]]/}" ]; then
    log "$repo: round cap reached — $ROUND_CAP_NAMED; the session performs the cut, the engine holds the panel request on the predecessor (#502)"
    printf '%s' "$fresh" | ledger_commit "$DUTY_DIR/.seen-round-cap"
  fi
  return 0
}

# _at_round_cap REPO NUM — 0 when this tick's census put that PR at the cap.
_at_round_cap() {
  case " ${ROUND_CAP_PRS:-} " in
    *" $1#$2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _request_panel REPO NUM PAYLOAD PANEL_JSON CHECK_STATE HC_HEAD [AT_CAP] — engine-side
# panel (re-)request, and state:bots-reviewing beside it (#133). This moves the
# request off the builder SESSION, where a session that died between its last
# push and its re-request left a PR that looked finished and was waiting for
# nobody — the blocker:unrequested shape.
#
# THE ENGINE ACTS ONLY ON THE SESSION'S SIGNAL, never on commit activity — the
# issue's hardest must-fail. The signal is a MARK_ANSWERED comment the session
# posts once it has answered the round whole (reply + any fix pushed) and after
# it first marks a PR ready-for-review. This function requests only when a
# MARK_ANSWERED for the CURRENT head is present: a mid-fix WIP push (green head,
# no answer yet) carries no such marker, so the panel is never re-requested
# under an unfinished round. A session that dies before posting the marker does
# not strand the PR — resume.txt re-posts it, so a missing marker only delays to
# the next tick, it never stalls forever (the old permanent-stall bug).
#
# PAYLOAD is the same GraphQL pullRequest object the handoff loop already
# fetched (now carrying comments), so this costs no extra call. Every write is
# best-effort and gates nothing — the same rule as _handoff_finalize.
# --- Risk-sized panels (#761) -------------------------------------------------
#
# _panel_risk REPO NUM — sets _PANEL_RISK_TIER (`low` or `high`) and
# _PANEL_RISK_WHY; prints nothing, so a caller reads both without a subshell.
# Read off the head's files: any path matching PANEL_RISK_PATHS, more than
# PANEL_RISK_MAX_FILES files, or more than PANEL_RISK_MAX_LINES lines changed
# is high. A read that fails is high — a panel that cannot see the change
# reviews it whole, never smaller.
_PANEL_RISK_WHY=""
_PANEL_RISK_TIER=high
_panel_risk() {
  local repo="$1" num="$2" files paths n lines risky
  _PANEL_RISK_WHY=""; _PANEL_RISK_TIER=high
  if ! files="$(gh pr view "$num" -R "$repo" --json files \
      --jq '.files[] | "\(.path) \(.additions + .deletions)"' 2>/dev/null)"; then
    _PANEL_RISK_WHY="files unreadable"; return 0
  fi
  n="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')"
  lines="$(printf '%s\n' "$files" | awk 'NF {s += $2} END {print s + 0}')"
  paths="$(printf '%s\n' "$files" | awk 'NF {print $1}')"
  risky="$(printf '%s\n' "$paths" | grep -E -c "${PANEL_RISK_PATHS:-^$}" || true)"
  if [ "$risky" -gt 0 ]; then
    _PANEL_RISK_WHY="$risky risky path(s): $(printf '%s\n' "$paths" | grep -E "${PANEL_RISK_PATHS:-^$}" | head -3 | paste -sd, -)"
    return 0
  fi
  if [ "$n" -gt "${PANEL_RISK_MAX_FILES:-3}" ]; then
    _PANEL_RISK_WHY="$n files (bound ${PANEL_RISK_MAX_FILES:-3})"; return 0
  fi
  if [ "$lines" -gt "${PANEL_RISK_MAX_LINES:-80}" ]; then
    _PANEL_RISK_WHY="$lines lines (bound ${PANEL_RISK_MAX_LINES:-80})"; return 0
  fi
  _PANEL_RISK_WHY="$n file(s), $lines lines, no risky path"
  _PANEL_RISK_TIER=low
}

# _panel_sized TIER NUM TO_REQUEST — the reviewers to request: all of them
# at high, PANEL_LOW_RISK_SIZE of them at low, starting at NUM modulo the
# count so consecutive low-risk heads rotate through the panel.
_panel_sized() {
  local tier="$1" num="$2" to_request="$3" size count start
  [ "$tier" = low ] || { printf '%s\n' "$to_request"; return 0; }
  size="${PANEL_LOW_RISK_SIZE:-1}"
  case "$size" in ''|*[!0-9]*|0) size=1 ;; esac
  count="$(printf '%s\n' "$to_request" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" -gt "$size" ] || { printf '%s\n' "$to_request"; return 0; }
  start=$(( num % count ))
  printf '%s\n' "$to_request" | sed '/^$/d' | awk -v s="$start" -v k="$size" -v c="$count" '
    { line[NR - 1] = $0 }
    END { for (i = 0; i < k; i++) print line[(s + i) % c] }'
}

# _panel_effective REPO NUM HEAD PANEL_JSON — THE panel for this head: the
# risk-sized subset of the resolved roster, as a JSON array in
# _PANEL_EFFECTIVE_JSON, with the tier and its reason in _PANEL_RISK_TIER and
# _PANEL_RISK_WHY. It is what request-panel.jq requests FROM and what
# converged.jq counts approvals AGAINST, so a low-risk head is reviewed by one
# reviewer and hands off on that one approval — sizing the panel, not the
# order it is asked in. The reading is cached per head in
# `.panel-sized-<repo>-<num>` (`<head> <tier> <why>`), so every tick of the
# same head sizes the same way and the files read is one per head, not one per
# tick; a new head reads again.
_PANEL_EFFECTIVE_JSON="[]"
_panel_effective() {
  local repo="$1" num="$2" head="$3" panel_json="$4" cache c_head tier why sized
  cache="$DUTY_DIR/.panel-sized-${repo//\//_}-$num"
  if [ -n "$head" ] && [ -r "$cache" ] && read -r c_head tier why <"$cache" \
      && [ "$c_head" = "$head" ] && [ -n "$tier" ]; then
    _PANEL_RISK_TIER="$tier"; _PANEL_RISK_WHY="$why"
  else
    _panel_risk "$repo" "$num"
    # PANEL_SIZED_CACHE=off is for a harness that runs the engine out of its
    # own tree: it reads the same way and leaves no file behind.
    [ -z "$head" ] || [ "${PANEL_SIZED_CACHE:-on}" = off ] \
      || { printf '%s %s %s\n' "$head" "$_PANEL_RISK_TIER" "$_PANEL_RISK_WHY" >"$cache.tmp" && mv -f "$cache.tmp" "$cache"; }
  fi
  sized="$(_panel_sized "$_PANEL_RISK_TIER" "$num" "$(printf '%s' "$panel_json" | jq -r '.[]' 2>/dev/null)")"
  _PANEL_EFFECTIVE_JSON="$(printf '%s\n' "$sized" | awk 'NF' | jq -R . | jq -cs .)"
  [ -n "$_PANEL_EFFECTIVE_JSON" ] || _PANEL_EFFECTIVE_JSON="$panel_json"
}

_request_panel() {
  local repo="$1" num="$2" payload="$3" panel_json="$4" check_state="$5" hc_head="$6"
  local at_cap="${7:-false}"
  local gql_head signal_json answered_head to_request rvr requested_any=0
  # THE CUT SPENDS EVERY APPROVAL, SO NOTHING ON THE PREDECESSOR ASKS FOR ONE
  # (#502 D2a). Doctrine, step 2 of the cut: "Do not re-request the panel. The
  # ordinary rule re-requests by head after a push; here the cut spends every
  # approval, so a verdict bought on the predecessor is a verdict on a PR that
  # will never merge … The panel is requested once, on the successor." Left
  # alone, this function is exactly what makes that request: the session answers
  # round 5 whole, signals at a green head, and the ordinary path opens round six
  # on the PR doctrine says can never carry one.
  #
  # Held before the signal gate rather than after it, because the refusal is not
  # a wait. There is no head at which the predecessor becomes requestable, so
  # _report_unsignalled_hold's "not requesting yet" reading would be wrong.
  #
  # Silent, and the census owns the saying: _round_cap_census logs the boundary
  # once per (PR, round count), so a line here would repeat that fact on every
  # tick for as long as the PR stands — the wallpaper #167 rules against, on the
  # loop whose "nothing to request" case is already silent for the same reason.
  #
  # The default is `false`, so a caller that does not pass the census answer gets
  # exactly today's behaviour, which is also what every PR below the cap gets.
  # And the successor is a different PR with an empty review history, so its
  # round 1 arrives here on the ordinary green-gated path with nothing to hold.
  [ "$at_cap" != true ] || return 0
  gql_head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
  [ -n "$gql_head" ] || { warn "$repo#$num: no head in payload; not requesting"; return 0; }
  # THE SIGNAL GATE. The latest MARK_ANSWERED comment of mine names the head the
  # round was answered at; the engine acts only when that head is the current
  # one. No marker, or a marker for a superseded head (a fix was pushed after
  # the answer and not yet re-signalled), means the round is not answered here —
  # hold, do not infer done-ness from the push.
  # The licence is ONE object, {sha, createdAt} (#286). This gate reads its sha;
  # request-panel.jq reads its createdAt to decide whether the signal answers a
  # verdict or merely predates it. Neither half is re-derived on the other side —
  # a second program means a second copy of the predicate.
  signal_json="$(printf '%s' "$payload" \
    | jq -c --arg me "$ME" --arg mark "$MARK_ANSWERED" \
        -f "$DUTY_DIR/lib/jq/answered-head.jq" 2>/dev/null)"
  [ -n "$signal_json" ] || signal_json='{"sha":"","createdAt":""}'
  answered_head="$(printf '%s' "$signal_json" | jq -r '.sha // ""' 2>/dev/null)"
  if [ "$answered_head" != "$gql_head" ]; then
    _report_unsignalled_hold "$repo" "$num" "$gql_head"
    return 0
  fi
  # The MECHANICAL half of the green-head precondition — the only half the
  # engine makes. Request only on a head whose check is green or absent; red and
  # pending both hold (wait, do not abandon — the next tick re-evaluates once the
  # check settles). The argued-exception (a red genuinely outside the PR) stays a
  # session judgement in fragment-round-rules.txt, never made here.
  case "$check_state" in
    green|none) : ;;
    *) log "$repo#$num: round answered but check at head is ${check_state:-unknown} — holding request (#45/#133)"; return 0 ;;
  esac
  # The green verdict must be ABOUT the head we would request on. head-checks.jq
  # read one gh-pr-list snapshot and this loop read a later GraphQL one; if a
  # push landed between them, defer a tick rather than request on a head whose
  # check nobody has seen settle.
  [ "$hc_head" = "$gql_head" ] || { log "$repo#$num: head moved mid-tick — deferring panel request"; return 0; }
  # The panel for THIS head (#761): risk-sized once per head, and the same
  # subset converged.jq counts against, so the request and the handoff agree.
  _panel_effective "$repo" "$num" "$gql_head" "$panel_json"
  to_request="$(printf '%s' "$payload" \
    | jq -r --argjson panel "$_PANEL_EFFECTIVE_JSON" --argjson signal "$signal_json" \
        -f "$DUTY_DIR/lib/jq/request-panel.jq" 2>/dev/null)"
  # Nothing to request is now the ROUND-CLOSED case as well as the
  # nothing-owed one (#286): a panel that answered with CHANGES_REQUESTED spends
  # the signal, and the ball returns to the builder through round_owed and
  # state:addressing, which log it there. Silent here on purpose — a handed-off
  # PR stays in this loop for every tick until the human merges it, and a line
  # per tick per PR would bury the writes that matter.
  [ -n "${to_request//[[:space:]]/}" ] || return 0
  # The tier and what decided it, on the pull request ONCE PER HEAD: the
  # marker line is the key post-once matches, so a later tick that requests a
  # further member of the same sized panel posts nothing new.
  local risk_tier="$_PANEL_RISK_TIER" risk_why="$_PANEL_RISK_WHY" sized_marker
  sized_marker="<!-- duty:panel-sized:$repo#$num@$gql_head -->"
  log "$repo#$num: panel sized $risk_tier ($risk_why): $(printf '%s' "$_PANEL_EFFECTIVE_JSON" | jq -r 'join(" ")' 2>/dev/null)"
  "$BIN_DIR/post-once.sh" "$repo" "$num" \
    "${MARK_PANEL_SIZED:-🧭 panel sized} $risk_tier at $gql_head: $(printf '%s' "$_PANEL_EFFECTIVE_JSON" | jq -r 'join(" ")' 2>/dev/null) — $risk_why
$sized_marker" "$sized_marker" >/dev/null 2>&1 \
    || warn "$repo#$num: the panel-sized comment did not post (best-effort)"
  # One reviewer per call, not a batched reviewers[] array: a single 422 (an
  # already-pending request that raced the predicate) must not drop the others.
  for rvr in $to_request; do
    [ -n "$rvr" ] || continue
    if gh api "repos/$repo/pulls/$num/requested_reviewers" -f "reviewers[]=$rvr" >/dev/null 2>&1; then
      requested_any=1
    else
      warn "$repo#$num: panel request for @$rvr did not land (already requested?)"
    fi
  done
  # state:bots-reviewing rides along in the SAME act. It buys no latency —
  # review_requested carries it in seconds — it is here so the write is atomic
  # with the request that causes it, exactly as _handoff_finalize sets
  # state:needs-human beside its human request. Best-effort; gates nothing.
  if [ "$requested_any" -eq 1 ]; then
    log "$repo#$num: engine requested panel ($(printf '%s' "$to_request" | tr '\n' ' ')) at ${gql_head:0:12}"
    gh issue edit "$num" -R "$repo" --add-label "$LABEL_BOTS_REVIEWING" >/dev/null 2>&1 \
      || warn "$repo#$num: could not set $LABEL_BOTS_REVIEWING (reconciler will)"
  fi
  return 0
}

# --- The dirty-worktree report: once per (worktree, dirt), never per tick ---
#
# Leaving a dirty worktree alone is right — a `--force` here deletes
# uncommitted work irrecoverably, and no log line is worth that. What was
# wrong is that the engine said so on EVERY pass, forever, about a condition
# nothing in the loop can change: the same two lines every five minutes for
# days on build/77-fleet-action-status (PR #103, merged). A warning that
# repeats forever is not a warning, it is wallpaper, and this fleet already
# has a family of defects that survived because a signal was present and
# unread (#114, #147, #155, #158). So the ledger buys silence for a condition
# already stated once — not for an unstated one (#59).
#
# THE DIRT GOES IN THE ID, AND THE VALUE IS A FIXED SENTINEL — the ci-red
# scheme (#17) for the same reason: ledger_filter re-fires when the VALUE
# sorts greater, and a dirt fingerprint has no order. Keyed the ordinary way,
# a worktree that became dirty in a NEW way whose fingerprint happened to sort
# below the old one would be suppressed — losing the report exactly when the
# condition changed, which is the one thing this ledger must not do.
#
# `cksum`, not `sha256sum`: this is an identity for a local state file, not
# provenance, and cksum is POSIX, so the engine gains no new dependency. A
# collision costs one un-repeated warning about a worktree already reported.
_wt_dirt_id() { # $1=repo $2=branch $3=porcelain text -> ledger id
  printf '%s:%s@%s' "$1" "$2" \
    "$(printf '%s' "$3" | cksum | awk '{print $1 "-" $2}')"
}

_wt_dirt_summary() { # $1=porcelain text -> what made it dirty, in two counts
  printf '%s\n' "$1" | awk '
    /^\?\?/ { u++; next }
    NF      { m++ }
    END     { printf "%d modified, %d untracked", m+0, u+0 }'
}

# _wt_dirt PATH — the porcelain listing, one row per FILE, or nonzero if git
# could not say. Every count in this module comes through here, for two reasons
# a bare `git status --porcelain` gets wrong.
#
# `--untracked-files=all`: the default collapses a whole untracked directory to
# a single `?? newdir/` row, so two files under one new directory are summarised
# as "1 untracked" — and the record built from that count describes a ref
# holding something else. That is the wrong half to get wrong: the record is
# what somebody reads to decide the work is worthless WITHOUT fetching it, so an
# undercount is read as "one stray file" over content nobody looks at again.
# Untracked-in-a-new-directory is also the common shape of the thing #168 exists
# to save — a whole `bin/` or `test/` nobody committed yet.
#
# ...and it fails closed. `dirt="$(git ... 2>/dev/null)"` swallows the exit
# status, and the callers run inside `if !` conditions where `set -e` is
# disarmed, so a git that cannot answer used to yield an empty listing that
# summarises as "0 modified, 0 untracked" — a record that reads like a triviality
# over unknown content, and a `--force` earned on it. A read that failed says so
# instead, and the caller keeps the worktree.
_wt_dirt() { # $1=path -> porcelain text (sorted), nonzero if git failed
  local out
  out="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)" \
    || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sort
}

# _wt_hygiene_report LEDGER REPO BRANCH PATH — say it once, and say what it
# costs. "leaving it for inspection" never told the reader the price: the
# worktree holds its branch, so the next `git worktree add` for that branch
# fails with "already checked out", on somebody else's build, later, with no
# obvious connection to the warning nobody was reading. Always returns 0 —
# whether it spoke or not is not the caller's business.
_wt_hygiene_report() {
  local ledger="$1" repo="$2" branch="$3" path="$4" dirt item
  # A status that cannot be read is its own news, and it is not "0 modified, 0
  # untracked": the worktree is still there, still holding its branch, and the
  # reader needs to know the counts are missing rather than zero. Said once,
  # keyed on the path, since the condition does not vary with dirt it cannot see.
  if ! dirt="$(_wt_dirt "$path")"; then
    _wt_say_once "$ledger" "dirt-unreadable:$repo:$branch:$path" \
      "$repo: worktree $path is not clean and 'git status' there failed, so what it holds is unknown; leaving it for inspection — it holds $branch, so a later 'git worktree add' for that branch fails with 'already checked out'"
    return 0
  fi
  item="$(printf '%s\tdirty' "$(_wt_dirt_id "$repo" "$branch" "$dirt")")"
  [ -n "$(printf '%s\n' "$item" | ledger_filter "$ledger")" ] || return 0
  warn "$repo: worktree $path not clean ($(_wt_dirt_summary "$dirt")); leaving it for inspection — it holds $branch, so a later 'git worktree add' for that branch fails with 'already checked out'"
  # Committed here, not after a session: no session runs on this signal, and
  # what is suppressed is a repeated REPORT of an unchanged condition, not
  # work a crashed session still owes.
  printf '%s\n' "$item" | ledger_commit "$ledger"
  return 0
}

# --- #168: preserve before removing ------------------------------------------
#
# Ignored dirt no longer blocks a removal, so every refusal that remains is
# real uncommitted work: modified tracked files, or untracked files nobody
# chose to ignore. A merged PR proves the COMMITTED content reached main and
# says nothing about that. `bin/claim-issue.sh` and its 20-assertion suite once
# existed only as untracked files on claude-builder; a sweep that forced on
# "the PR merged" would have taken them silently, every five minutes, on five
# boxes, unattended.
#
# So the work is pushed to a remote first and the force is the CONSEQUENCE of
# that push landing — never a flag anyone can reach for. A remote, not a local
# stash or a copy under ~/duty: both die at the next `crew upgrade` (#159), and
# a preservation that does not survive the thing it is preserving against is
# not preservation.

# _wt_preserve_remote PATH — where a preservation push goes. `fork` when the
# clone has one, else `origin`.
#
# #168 first said "push it to origin", and on a one-remote clone that is what
# this returns. On a fleet clone it is not: ensure_main_clone adds `fork` at
# the bot's own fork precisely because the bot cannot write to the upstream —
# builds push there, and a preservation that pushed to origin would be refused
# on every box, leaving the force unearned and every dirty worktree stuck
# forever. Triage amended the criterion to the writable remote on 2026-08-05,
# for that reason: `origin` was unsatisfiable in production rather than merely
# inconvenient, and the requirement's own reason — it must outlive the box and
# the next `crew upgrade` — turns on *remote*, not on *origin*. Naming the
# remote in the log keeps the recovery line honest either way.
_wt_preserve_remote() {
  local path="$1"
  if git -C "$path" remote get-url fork >/dev/null 2>&1; then
    printf 'fork\n'
  elif git -C "$path" remote get-url origin >/dev/null 2>&1; then
    printf 'origin\n'
  else
    return 1
  fi
}

# _wt_index_tree PATH — the tree PATH's REAL index holds, or nonzero where it
# cannot be read. The staged snapshot is a SECOND piece of uncommitted work, not
# a preview of the first: for a partially staged path (`MM file`) the index
# holds one version and the working tree another, and a capture built from the
# working tree alone destroys the staged one on its way to earning a --force
# (@codex-bot-andresmgsl, #376). There is also a shape the working-tree capture
# cannot see at all — content staged and then reverted in the tree — where the
# capture equals HEAD's tree and refuses, leaving the worktree stuck on every
# tick forever with `git status` still calling it dirty.
#
# Read through a COPY of the index, never the index itself. `git write-tree`
# rewrites the cache-tree extension into the index it is given, and "the
# worktree is byte-identical afterwards" is the property this whole design rests
# on — a preservation that mutated the thing it was preserving would be worse
# than the one it replaced. The copy is what keeps the promise; the real index
# is only ever read with `cp`.
#
# ...and it fails closed. An unmerged index makes `write-tree` refuse, and so
# does an index nobody can read; either way what is staged is unknown, and
# unknown is not empty. The caller returns nonzero, so nothing is pushed and no
# force is earned — the worktree keeps every byte on disk and is reported once
# per dirt, which is the same bargain `_wt_dirt` strikes for a status git cannot
# answer.
_wt_index_tree() { # $1=path -> tree sha, nonzero if the index cannot be read
  local path="$1" real copy tree
  real="$(git -C "$path" rev-parse --git-path index 2>/dev/null)" || return 1
  [ -n "$real" ] || return 1
  # Absolute in a linked worktree, relative to the worktree root in a plain
  # clone — and this runs from neither.
  case "$real" in /*) ;; *) real="$path/$real" ;; esac
  [ -f "$real" ] || return 1
  copy="$(mktemp "${TMPDIR:-/tmp}/wt-index.XXXXXX")" || return 1
  if cp "$real" "$copy" 2>/dev/null; then
    tree="$(GIT_INDEX_FILE="$copy" git -C "$path" write-tree 2>/dev/null)" || tree="" # Decision-path empty fallback: the guard below fails closed and preserves the worktree unchanged.
  fi
  rm -f "$copy"
  [ -n "${tree:-}" ] || return 1
  printf '%s\n' "$tree"
}

# _wt_commit TREE PARENT MESSAGE, in PATH — the engine's own commit. The box's
# git identity may be anything or nothing, and commit-tree refuses without one.
_wt_commit() { # $1=path $2=tree $3=parent $4=message -> commit sha
  git -C "$1" \
    -c "user.name=${ME:-crew}" -c "user.email=${ME:-crew}@users.noreply.github.com" \
    commit-tree "$2" -p "$3" -m "$4" 2>/dev/null
}

# _wt_preserve PATH BRANCH — capture PATH's uncommitted content and push it as
# `wip/BRANCH`. Prints "<remote> <ref> <sha> <url> <staged-sha-or-dash>" and
# returns 0 ONLY once the remote has it; every other path returns nonzero, which
# is what denies the caller its force.
#
# THE WORKTREE IS NEVER TOUCHED. The commit is built in a scratch index —
# read-tree HEAD, then `add -A` against that index — so nothing is staged,
# stashed or checked out in the tree itself, and a push that fails leaves it
# byte-identical to how it was found. `add -A` is also what gets untracked
# files in and ignored files out, which `git stash` without `--include-untracked`
# famously does not: untracked is where the real example lived.
#
# TWO SNAPSHOTS, ONE REF. Where the index holds something neither HEAD nor the
# working tree does, it is pushed as the working-tree commit's PARENT. The tip
# stays the working tree — that is what `checkout FETCH_HEAD` should land on,
# and what somebody expects to find — and the staged snapshot is one commit
# behind it, reachable as `FETCH_HEAD^` and named in the record so nobody has to
# guess it is there.
_wt_preserve() {
  local path="$1" branch="$2"
  local remote ref idx tree head head_tree idx_tree staged staged_commit
  local parent commit remote_sha remote_staged url
  ref="wip/$branch"
  remote="$(_wt_preserve_remote "$path")" || return 1
  url="$(git -C "$path" remote get-url "$remote" 2>/dev/null)" || return 1
  head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || return 1
  head_tree="$(git -C "$path" rev-parse 'HEAD^{tree}' 2>/dev/null)" || return 1
  idx="$(mktemp "${TMPDIR:-/tmp}/wt-preserve.XXXXXX")" || return 1
  if GIT_INDEX_FILE="$idx" git -C "$path" read-tree HEAD 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$path" add -A 2>/dev/null; then
    tree="$(GIT_INDEX_FILE="$idx" git -C "$path" write-tree 2>/dev/null)" || tree="" # Decision-path empty fallback: the guard below fails closed and grants no push or force.
  fi
  rm -f "$idx"
  [ -n "${tree:-}" ] || return 1
  idx_tree="$(_wt_index_tree "$path")" || return 1
  # The staged snapshot earns its own commit only where it holds something the
  # other two do not: equal to HEAD's tree it is nothing, equal to the capture
  # it is already the tip, and a duplicate commit for either would be noise in
  # the one history somebody reads under pressure.
  staged=""
  if [ "$idx_tree" != "$head_tree" ] && [ "$idx_tree" != "$tree" ]; then
    staged="$idx_tree"
  fi
  # Nothing but ignored dirt captures to HEAD's own tree with nothing staged
  # beside it. Nothing was at risk, so nothing is pushed — and no force is
  # earned by a refusal this cannot explain. Read as "neither half holds
  # anything", never as "the working tree holds nothing": the staged-then-
  # reverted worktree fails the first test and passes this one, which is the
  # whole of why it is now releasable.
  [ "$tree" != "$head_tree" ] || [ -n "$staged" ] || return 1
  # Idempotence, and the reason the ref is read before it is written: a pass
  # that pushed and then failed to remove leaves the ref already holding this
  # exact tree. Re-pushing would mint a second commit for one preservation and
  # be refused as a non-fast-forward — so an identical tree on the remote IS
  # the confirmation, and a different one becomes the new commit's parent so
  # the push still fast-forwards. The parent is checked too where there is a
  # staged snapshot: a tip matching on its own is what a ref pushed before this
  # module read indexes looks like, and confirming on it would skip the staged
  # half for exactly the worktrees that have one.
  remote_sha="$(git -C "$path" ls-remote "$remote" "refs/heads/$ref" 2>/dev/null \
    | awk 'NR==1{print $1}')"
  if [ -n "$remote_sha" ] \
    && git -C "$path" fetch -q "$remote" "refs/heads/$ref" 2>/dev/null; then
    remote_staged=""
    [ -z "$staged" ] \
      || remote_staged="$(git -C "$path" rev-parse "$remote_sha^" 2>/dev/null)"
    if [ "$(git -C "$path" rev-parse "$remote_sha^{tree}" 2>/dev/null)" = "$tree" ] \
      && { [ -z "$staged" ] \
        || [ "$(git -C "$path" rev-parse "$remote_staged^{tree}" 2>/dev/null)" = "$staged" ]; }
    then
      printf '%s %s %s %s %s\n' "$remote" "$ref" "$remote_sha" "$url" "${remote_staged:--}"
      return 0
    fi
    parent="$remote_sha"
  else
    parent="$head"
  fi
  staged_commit=""
  if [ -n "$staged" ]; then
    staged_commit="$(_wt_commit "$path" "$staged" "$parent" \
      "wip($branch): staged (index) snapshot preserved before worktree removal")" \
      || return 1
    parent="$staged_commit"
  fi
  commit="$(_wt_commit "$path" "$tree" "$parent" \
    "wip($branch): uncommitted work preserved before worktree removal")" || return 1
  # One push, and it carries the chain: the tip's parent is the staged commit,
  # so a push that lands lands both, and one that fails leaves neither behind
  # half-preserved.
  git -C "$path" push -q "$remote" "$commit:refs/heads/$ref" 2>/dev/null || return 1
  printf '%s %s %s %s %s\n' "$remote" "$ref" "$commit" "$url" "${staged_commit:--}"
  return 0
}

# _wt_say_once LEDGER ID MESSAGE — one WARN per ID, ever. #167's discipline
# without its message: the report below says "not clean, leaving it for
# inspection", which is not what happened on the paths that use this — the work
# is already on the remote there, and a reader told the wrong thing acts on the
# wrong thing. The ID carries the preserved SHA rather than a dirt fingerprint:
# the sha identifies that dirt exactly, it is in hand at both call sites, and it
# costs no second `git status` on a path that is already going wrong. Keyed
# distinctly from _wt_hygiene_report's own items, whose shape is untouched, so
# nothing here re-warns for a worktree whose dirt still reads the same.
#
# One live box WILL re-warn once, and it is the right line to lose the silence
# over (@claude-bot-andresmgsl, #376): _wt_dirt_id hashes the porcelain text,
# and `--untracked-files=all` changes that text for exactly the
# untracked-directory worktrees whose old warning undercounted them. So each of
# those says itself once more, with the truer counts, and then goes quiet again.
# Always returns 0.
_wt_say_once() {
  local ledger="$1" id="$2" msg="$3" item
  item="$(printf '%s\tsaid' "$id")"
  [ -n "$(printf '%s\n' "$item" | ledger_filter "$ledger")" ] || return 0
  warn "$msg"
  printf '%s\n' "$item" | ledger_commit "$ledger"
  return 0
}

# _wt_record REPO PR BRANCH PATH REMOTE REF SHA URL [STAGED] — the durable half
# of a preservation: a comment on the PR the worktree belonged to, naming the
# remote, the ref, what it holds and the staged snapshot where there is one.
# Returns 0 only once that comment is present.
#
# The payload and the record fail differently, which is the whole reason they
# are separate (triage, #168, 2026-08-05). A `wip/` ref lives on the bot's fork
# because that is the only remote it can write to, and a fork is not durable in
# this org: the public-repo flip detached the bots' forks once already, and an
# org-level action nobody associates with worktrees can take the payload with
# it. A comment upstream survives fork deletion, box destruction and identity
# rotation, and for the 99% of preservations that are worthless it is enough to
# decide so without fetching anything.
#
# post-once.sh, not a bare POST and not a local ledger: its dedup is an exact
# body match against the comments endpoint, so a tick that dies between the push
# and the removal re-records nothing, and a ledger that dies with the box cannot
# make the same promise. The body is deterministic in the sha and the counts —
# same dirt, same body, no second comment; changed dirt, new sha, a new record,
# which is right, because it holds something else.
#
# THE COUNTS COME FROM THE WORKTREE, not from the ref they describe
# (@claude-bot-andresmgsl, #376, argued and not taken). Deriving them with
# `diff-tree HEAD..<tip>` would tie them to the payload by construction, which
# was the right instinct while the ref was one commit — but the ref is a chain
# now, and its tip legitimately equals HEAD's tree for a worktree whose work is
# all staged and reverted. That record would read "0 modified, 0 untracked" over
# real preserved content: the "reads like a triviality" failure this record was
# hardened against, reintroduced by the fix for it. Walking the chain instead
# means teaching the record to reconstruct dirt the worktree states in one read.
# So the read stays, and the cross-check does the work the derivation would:
# p168-record-counts-nested-untracked asserts the counts against the ref's own
# file list, so a systematic drift between them fails the suite.
_wt_record() {
  local repo="$1" pr="$2" branch="$3" path="$4" remote="$5" ref="$6" sha="$7" url="$8"
  local staged="${9:--}"
  local dirt body staged_line=""
  [ -n "$pr" ] || return 1
  # Nonzero rather than a fabricated count: the counts are the part of this
  # record that is checked against nothing, so a read that failed must deny the
  # record, which denies the force, which keeps the worktree.
  dirt="$(_wt_dirt "$path")" || return 1
  # A pointer at the tip alone is a pointer at half the work where the index
  # held its own version, and the half it omits is the one nobody would think to
  # look for. Absent a staged snapshot the body is byte-identical to the one
  # this module has always posted — the dedup upstream is an exact body match,
  # and a cosmetic blank line would re-post every already-recorded preservation
  # once on the upgrade.
  case "$staged" in
    ''|-) ;;
    *) staged_line="$(printf '\n\n%s\n' \
      "Part of that work was **staged and differed from the working tree**, so the index has its own snapshot one commit below the tip (\`$staged\`) — reach it with \`git checkout FETCH_HEAD^\` after the fetch above.")" ;;
  esac
  body="$(printf '%s\n' \
    "🗃️ Uncommitted work preserved before this branch's worktree was removed" \
    "" \
    "\`$branch\`'s worktree was dirty when the hygiene sweep removed it. The work is on the \`$remote\` remote as \`$ref\` (\`$sha\`), holding $(_wt_dirt_summary "$dirt") file(s)." \
    "" \
    "    git fetch $url $ref && git checkout FETCH_HEAD${staged_line}" \
    "" \
    "The ref can be lost with the remote that holds it; this comment is the record that outlives it (#168).")"
  "$BIN_DIR/post-once.sh" "$repo" "$pr" "$body" >/dev/null 2>&1 || return 1
  return 0
}

# _wt_release DIR REPO BRANCH PATH PR LEDGER — release a done branch's worktree,
# in the one order that is safe: try the clean removal, and only where it
# refuses, preserve, and only where the preservation lands AND is recorded
# upstream, force. Returns 0 when the worktree is gone.
#
# The ordering is the entire safety property, so it is read as an ordering in
# the suite too: the clean attempt before the capture, the capture before the
# push, the push before the record, the record before the force.
#
# A failed record stops the removal exactly as a failed push does. #168 spells
# out the hard stop for the push only, so this is the builder's call and is said
# out loud rather than buried: the amendment's own argument is that the ref is
# the deletable half and the comment the durable one, so forcing the worktree
# away with the payload pushed and nothing upstream saying where it went ships
# the gap the amendment exists to close. It is self-healing — the worktree
# stays, and the next tick re-preserves to the same sha (no new commit, no new
# ref) and retries the record.
_wt_release() {
  local dir="$1" repo="$2" branch="$3" path="$4" pr="$5" ledger="$6"
  local preserved remote ref sha url staged staged_note=""
  if git -C "$dir" worktree remove "$path" 2>/dev/null; then
    git -C "$dir" branch -D "$branch" 2>/dev/null || true
    return 0
  fi
  if preserved="$(_wt_preserve "$path" "$branch")"; then
    read -r remote ref sha url staged <<<"$preserved"
    # The line has to be enough on its own: whoever reads it a week later is
    # not holding this box, and the worktree it names is gone.
    case "$staged" in
      ''|-) ;;
      *) staged_note=" (staged content differed and is the commit below the tip, ${staged:0:12} — git checkout FETCH_HEAD^)" ;;
    esac
    log "$repo: preserved $path's uncommitted work as $ref ($remote, ${sha:0:12}) — recover with: git fetch $url $ref && git checkout FETCH_HEAD$staged_note"
    # The record is retried every tick while the worktree stays stuck, and the
    # WARN beside it is not: a deliberate asymmetry, not an oversight
    # (@claude-bot-andresmgsl, #376). The retry IS the self-heal — a rate limit
    # or a five-minute auth blip resolves itself on the next pass, and a ledger
    # remembering "the record failed" would turn that into a worktree stuck until
    # somebody clears a file on a box nobody logs into. The two cost differently:
    # the WARN is noise in a log a human reads, the retry is one cheap GET that
    # is also the recovery attempt.
    if ! _wt_record "$repo" "$pr" "$branch" "$path" "$remote" "$ref" "$sha" "$url" "$staged"; then
      _wt_say_once "$ledger" "record-failed:$repo:$branch@$sha" \
        "$repo: $ref is on $remote but the record on ${pr:+#}${pr:-the PR} did not post; keeping $path until it does — the work is safe, the pointer to it is not"
      return 1
    fi
    if git -C "$dir" worktree remove --force "$path" 2>/dev/null; then
      git -C "$dir" branch -D "$branch" 2>/dev/null || true
      return 0
    fi
    _wt_say_once "$ledger" "force-survived:$repo:$branch@$sha" \
      "$repo: $path survived a forced removal after $ref was pushed; leaving it — the work is on $remote either way"
    return 1
  fi
  # No push, no force: today's behaviour, said once per (worktree, dirt).
  _wt_hygiene_report "$ledger" "$repo" "$branch" "$path"
  return 1
}

# _stranded_resume_due STATE THRESHOLD — count consecutive duty ticks for
# open, ready authored PR heads that have no current-head MARK_ANSWERED signal.
# stdin is one repo#num@head key per PR. The head belongs in the key so every
# push starts again at one; keys absent this tick (draft, signalled, or closed)
# disappear. stdout is the PR number for each key reaching THRESHOLD.
_stranded_resume_due() {
  local state="$1" threshold="$2" key num next tmp
  local -A previous=() current=()
  tmp="$state.tmp.$$"
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r key next; do
      [ -n "$key" ] || continue
      previous["$key"]="${next:-0}"
    done <"$state"
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -n "${current[$key]+x}" ] && continue
    next=$(( ${previous[$key]:-0} + 1 ))
    current["$key"]="$next"
    if [ "$next" -ge "$threshold" ]; then
      num="${key#*#}"; num="${num%@*}"
      printf '%s\n' "$num"
    fi
  done
  : >"$tmp"
  for key in "${!current[@]}"; do
    printf '%s\t%s\n' "$key" "${current[$key]}" >>"$tmp"
  done
  mv "$tmp" "$state"
}

# _resume_pr_comments REPO NUM — every comment on PR NUM, oldest first, shaped
# as the comments.nodes[] the two signal predicates read: {author:{login}, body,
# createdAt, id}. Nonzero means the read failed and the thread is unknown.
#
# Paginated REST, for the same reason _resume_newest_foreign is (below), and the
# reason is sharper here. `gh pr list --json comments` generates `comments(first:
# 100)` and never paginates that nested connection, so it returns the OLDEST
# hundred — while a signal, by construction, is the NEWEST comment on the thread.
# On #311's 124 comments the listing's window stops at `2026-08-03T00:05:52Z`,
# eleven hours before the incident it was meant to classify. The request gate
# reads `comments(last:100)` in its own GraphQL query and is unaffected; this is
# the resume side getting the same depth by the route that is available to it.
_resume_pr_comments() {
  local repo="$1" num="$2" raw
  raw="$(gh api --paginate "repos/$repo/issues/$num/comments?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE" \
    --jq '.[] | {author:{login:(.user.login // "")}, body:(.body // ""),
                 createdAt:(.created_at // ""), id:((.id // "") | tostring)}' \
    2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -sc '.'
}

# _resume_attach_comments REPO LISTING — the answer is the same listing with
# `.comments` filled for every non-draft PR, and it comes back in a GLOBAL,
# RESUME_LISTING, for the reason _resume_gate states
# below: every report here is a log line, log writes to stdout, and a function
# that returned its data through the same channel would fold its own warnings
# into the JSON the caller parses.
#
# THE LISTING STOPPED CARRYING COMMENTS AND NOTHING SAID SO. `_stranded_resume_keys`
# classifies a PR by reading `.comments` off this listing, and the field left it
# at 70823ac (#314) — correctly for the foreign-activity half that commit was
# about, and silently for the signal half, because `.comments // []` reads an
# absent field as an empty thread. Every non-draft authored PR has therefore
# classified as unsignalled since, and a near-miss predicate would have had
# nothing to run against. The comments come back here rather than in the listing
# so the foreign half keeps the paginated read #314 gave it.
#
# A PR whose thread could not be read gets `.comments = null`, NOT an empty
# array: the predicates below skip a null and the PR leaves the stranded set for
# this tick, forfeiting its counter. That is the safe direction. Read as an empty
# thread it would look unsignalled — accruing toward a resume the evidence does
# not support — and a transient failure costing one restarted count is cheaper
# than a resume session spent on a PR that signalled correctly.
#
# DRAFTS ARE READ TOO, since #384. The two predicates that filter drafts out do
# so themselves, so nothing above changes; what needs the draft's thread is
# _flip_owed_resume_rows, whose whole question is whether a DRAFT carries a
# valid signal at its head. The cost is one paginated REST read per draft per
# tick, beside the two _resume_newest_foreign already makes for the same draft.
# THE THREAD DOES NOT TRAVEL ON ARGV (#479). `--argjson comments "$comments"`
# made the whole thread ONE argv element, and a single element is bounded by
# MAX_ARG_STRLEN — 32 pages, 131,072 bytes — not by the ARG_MAX everyone quotes.
# Past that, `execve` fails with E2BIG, `|| spliced=""` swallowed it, the listing
# went through unchanged, and the PR reached the predicates with `.comments`
# ABSENT, which they read as null and skip. A thread never shrinks, so the
# condition never cleared: the guarantee this file states above — "a missing
# marker only delays to the next tick, it never stalls forever" — was void above
# the limit, and every downstream safety net (_green_head_breaker, the #384
# green-head bypass, _stranded_resume_due's counter) sits BELOW the splice, so
# nothing reasoning about the stranded set could reach the PR at all. It read as
# `no resume duty` — a clean board — for 86 minutes.
#
# `--slurpfile` from a process substitution is the fix: argv carries `/dev/fd/N`
# and the payload travels down a pipe, so the bound that applies is the one that
# scales. A temp file would do the same, and is not used, because allocating one
# introduces a failure mode of its own — a full `TMPDIR` — on the exact path
# whose job is to classify failures; the substitution has nothing to allocate.
#
# TRANSIENT AND STRUCTURAL ARE NOT THE SAME SKIP, and the discriminator is which
# half failed. The READ is a network call, so `gh` returning nonzero is the
# transient class the original swallow was written for: it skips the PR for the
# tick, forfeits its counter, and is retried unchanged next tick. The SPLICE is a
# local deterministic fold of two values already in hand — no network, no API, no
# rate limit — so a splice that fails will fail identically next tick on inputs
# that only ever grow. That will not clear on its own, and a permanent condition
# is not a per-tick skip: it escalates to the operator through `alert`, naming
# the PR, the head and the issue a human should flag, rather than waiting for
# someone to notice a board that looks clean — and posts that same fact on the PR
# through post-once.sh, because an alert nothing acknowledges can be dropped
# without trace and this escalation fires only once per head. Why that channel
# and not a label write, and why the record is a separate object from the wake,
# is _resume_structural_escalate's own header, below.
#
# EVERY BRANCH WARNS, including the one that cannot even mark the thread unread.
# A swallow with no warn is what turned a stall into a clean board, so the
# absence of a log line is the defect being fixed here and not an omission.
_resume_attach_comments() {
  local repo="$1" listing="$2" spliced num comments
  RESUME_LISTING=""
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    spliced=""
    if comments="$(_resume_pr_comments "$repo" "$num")"; then
      spliced="$(printf '%s' "$listing" | jq -c --argjson num "$num" \
        --slurpfile comments <(printf '%s' "$comments") \
        'map(if .number == $num then . + {comments:$comments[0]} else . end)')" || spliced="" # Decision-path empty fallback: the next branch warns, escalates, and marks the thread unread.
      if [ -z "$spliced" ]; then
        warn "$repo#$num: comment splice failed on a thread that read cleanly; leaving it out of stranded-resume detection this tick (structural)"
        _resume_structural_escalate "$repo" "$num" "$listing"
      fi
    else
      warn "$repo#$num: comment read failed; leaving it out of stranded-resume detection this tick"
    fi
    if [ -z "$spliced" ]; then
      # The explicit null, for both failures. The predicates skip a null and the
      # PR leaves the stranded set for this tick, forfeiting its counter — the
      # safe direction, because an absent field read as an empty thread would
      # look UNSIGNALLED and accrue toward a resume the evidence does not support.
      spliced="$(printf '%s' "$listing" | jq -c --argjson num "$num" \
        'map(if .number == $num then . + {comments:null} else . end)')" \
        || { spliced=""
             warn "$repo#$num: could not mark the thread unread in the listing either; it reaches the predicates with .comments absent" ; }
    fi
    if [ -n "$spliced" ]; then listing="$spliced"; fi
  done < <(printf '%s' "$listing" | jq -r '.[] | .number' 2>/dev/null)
  RESUME_LISTING="$listing"
}

# _resume_structural_escalate REPO NUM LISTING — put a structural splice failure
# in front of the operator, once per head.
#
# THE CHANNEL IS `alert`, NOT THE `attention` LABEL, and #479's D3 says so since
# triage ruled it on 2026-08-26. The label is hand-set doctrine — LABELS.md:99
# and 185-187 ("the machine never sets `attention`"), shared/prompts/attention.txt
# from the other end ("never set it yourself"), and the enforcement in
# engine-never-writes-attention-label (shared/test/builder.sh, since 9fb7e3d):
# "`attention` remains a hand-written demand. Reads in duty-attention.sh are the
# wake mechanism and are allowed; engine label writes are not". `alert` is the
# channel the engine already owns for exactly this class: duty_attention_audit
# uses it to report a board invariant it observes and does not fix, and crew#66's
# implemented close is the precedent for the shape — a module that observes a
# condition it may not act on pings the operator rather than only logging, which
# is what made its bound affordable. (#66 ruled repos.txt scope, NOT who writes
# the label; the doctrine above is what forecloses the label write. Triage's
# correction, 2026-08-26, recorded here because this header was quoted for it.)
# The escalation therefore NAMES the issue a human should flag rather than
# flagging it, and D3's purpose — a permanent condition is never a per-tick skip,
# and never waits to be noticed — is met without the engine taking the write.
#
# THE ALERT CARRIES A RECEIPT, and the receipt is not decoration (@danmt, via
# #479, 2026-08-26). `alert` is fire-and-forget: with no token file it is a
# silent no-op RETURNING SUCCESS, with one it is a ten-second best-effort with no
# retry whose failure is explicitly non-fatal (common.sh). Every other alert in
# the tree survives that because the condition it names re-fires next tick. THIS
# ONE DOES NOT — the once-per-head ledger below is exactly what makes a single
# dropped message a permanently lost escalation, which is this issue's own
# board-looks-clean failure moved one layer out. So the alert is the wake and the
# post-once.sh comment is the record, the pairing duty-attention.sh:246-248
# already ships in this subsystem. The body carries the full head, so post-once's
# exact-body dedup is once-per-head for free and no second suppression scheme is
# owed; it carries the same `where` clause as the alert, so the branch where the
# body names no authorizing issue gets its receipt by construction and not by a
# second code path. A receipt that does not post warns, like every other failure
# on this path: the alert is then the only copy and that is worth saying.
#
# The authorizing issue comes from the body through _RESUME_ISSUE_RE, the one
# pattern _resume_pr_fingerprints reads, so the two can never disagree about
# which issue a PR answers. A body naming none still escalates — the PR number is
# enough to act on, and a missing reference is itself worth saying.
#
# ONCE PER HEAD, on the ci-red scheme (#17): the head goes in the ledger's ID and
# never in its value, because ledger_filter re-fires when the value sorts greater
# and a SHA has no order. A new head is an id never seen, so a corrective push
# re-escalates — right, the condition being re-asserted against a tree that
# changed — while an unchanged head does not alert the operator every five
# minutes. #167's rule: a warning that repeats forever is wallpaper. The
# suppressed report is what keeps that quiet from becoming a silence, and it runs
# only on the ticks that did NOT alert — reporting a suppression on the very tick
# the alert fired would say "still standing" about its own first occurrence.
_resume_structural_escalate() {
  local repo="$1" num="$2" listing="$3" head issue where item fresh state receipt
  head="$(printf '%s' "$listing" | jq -r --argjson num "$num" \
    'first(.[] | select(.number == $num) | (.headRefOid // "")) // ""' 2>/dev/null)"
  issue="$(printf '%s' "$listing" | jq -r --argjson num "$num" --arg re "$_RESUME_ISSUE_RE" \
    'first(.[] | select(.number == $num)
       | first((.body // "") | capture($re; "i") | .n)) // ""' 2>/dev/null)"
  if [ -n "$issue" ]; then
    where="set $LABEL_ATTENTION on $repo#$issue to hand it to a session"
  else
    where="the body names no authorizing issue, so there is nowhere to set $LABEL_ATTENTION"
  fi
  item="$repo#$num@$head structural"
  state="$DUTY_DIR/.suppressed-resume-structural.${repo//\//__}.$num"
  fresh="$(printf '%s\n' "$item" | ledger_filter "$DUTY_DIR/.seen-resume-structural")"
  if [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" | ledger_commit "$DUTY_DIR/.seen-resume-structural"
    warn "$repo#$num: structural comment-splice failure at head ${head:0:12} — out of stranded-resume detection until it clears; $where"
    alert "🚨 $(hostname): $repo#$num is out of stranded-resume detection at head ${head:0:12} — its comment thread reads but will not splice, and that will not clear on its own; $where"
    # The durable half. Full head in the body, which is what makes the exact-body
    # dedup once-per-head; no marker, so the comment's identity IS its text.
    receipt="🚨 This PR is out of stranded-resume detection at head \`$head\` — its comment thread reads but will not splice, and that will not clear on its own; $where. Posted beside an operator alert, which is fire-and-forget, so this comment is the record that survives one being dropped (#479)."
    "$BIN_DIR/post-once.sh" "$repo" "$num" "$receipt" >/dev/null 2>&1 \
      || warn "$repo#$num: structural escalation receipt did not post at head ${head:0:12}; the alert is the only copy"
    rm -f "$state"
    return 0
  fi
  printf '%s\n' "$item" \
    | ledger_suppressed "$DUTY_DIR/.seen-resume-structural" \
    | report_suppressed "$state" \
        "$repo#$num: structural comment-splice failure still standing at head ${head:0:12}" \
        "already escalated at this head"
}

# --- The check half of the resume evidence (#384) ---------------------------
#
# A session that parks waiting for CI is unwakeable by the event it is waiting
# for: _resume_newest_foreign paginates comments and reviews, and a check-suite
# conclusion is neither. PR #381 pushed d4b8035, held its signal for `ci-floor`,
# and was still parked forty-six minutes after that check went green — there was
# no wake to be had. The two helpers below are the missing read, and they answer
# two different questions off the ONE listing the resume block already fetches:
# WHEN the head last concluded (the fingerprint's new term) and WHAT it
# concluded (the two due-predicates' evidence).

# _resume_check_states REPO LISTING — one `<num>\t<green|red|pending|none>` row
# per PR in LISTING, DRAFTS INCLUDED. Nonzero means the rollup could not be
# graded and every caller must drop that half for the tick.
#
# It grades through head-checks.jq rather than restating the rule, which is what
# _ci_red_rollup_settled already does for the same reason: `is_green` is a
# whitelist whose fail-closed direction was bought with #64, and a second copy
# of it in this file would be a second predicate. The shaping is the price —
# head-checks.jq filters drafts out and joins the round-owed fact, so `isDraft`
# is forced false and an empty `$panel` makes `round_owed`'s panel clause
# uniformly false — with an empty `$human` doing the same to its human clause
# (#452). Only field 4 is read here; the round-owed column stays the request
# path's, and neutering both clauses is how this caller says so.
_resume_check_states() {
  local repo="$1" listing="$2" shaped rows
  shaped="$(printf '%s' "$listing" | jq -c 'map(. + {isDraft:false})' 2>/dev/null)" || return 1
  [ -n "$shaped" ] || return 1
  rows="$(printf '%s' "$shaped" | jq -r --argjson panel '[]' --arg repo "$repo" \
    --arg human '' \
    -f "$BUILDER_LIB_DIR/jq/head-checks.jq" 2>/dev/null)" || return 1
  printf '%s\n' "$rows" \
    | awk -F'\t' -v OFS='\t' 'NF { n = $1; sub(/^.*#/, "", n); print n, $4 }'
}

# _resume_newest_check LISTING NUM — the newest CONCLUSION stamp among the
# checks at PR NUM's head, ISO-8601, or empty where nothing has concluded there.
# Nonzero means the rollup could not be read and the answer is unknown.
#
# _resume_newest_foreign's shape, and its fail-soft contract: a lookup that
# FAILS is not a lookup that found nothing, so the caller can warn and drop this
# half of the fingerprint for the tick rather than fabricating a stamp. A
# fabricated one would be worse than none — it advances the value, and an
# advanced value is a wake spent on evidence that does not exist.
#
# A CONCLUSION, NEVER A START. Reading a start time here would move the
# fingerprint when CI STARTS, which is the tick the session is still working
# through, not the one it is waiting for. The rollup mixes two shapes, so that
# one rule needs two readings — and BOTH are read from what `gh` EMITS, which
# is not what GitHub's schema names (#391 round 2, codex and claude).
#
# A CheckRun has concluded when `.status` says `COMPLETED`, and only then is
# `.completedAt` a conclusion. It is NOT absent while the check runs: `gh`
# marshals Go's zero time and emits `"completedAt":"0001-01-01T00:00:00Z"`
# beside `"conclusion":""`, so a non-empty test admits a running check and
# stamps it with a fabricated date. The status is the discriminator; a sentinel
# blacklist for the zero time would be a second thing to keep true.
#
# A StatusContext carries no completedAt at all, so its start stands in — but
# only where its state is terminal, a PENDING context's stamp being when the
# wait began. `gh` requests GitHub's `createdAt` for it and then serialises it
# under its OWN key, `startedAt`; the schema has no `startedAt` on that type and
# `createdAt` never reaches us. Reading `createdAt` alone made this branch dead
# against every real rollup — met for a repo whose checks are CheckRuns, crew's
# own among them, and unmet exactly where a legacy status concludes, which is
# head-checks.jq's #50 transposed from grading to stamping. The `//` form is
# that file's own idiom (`latest_checks`), and it survives a fleet box whose
# `gh` serialises the field either way.
_resume_newest_check() {
  local listing="$1" num="$2" out
  out="$(printf '%s' "$listing" | jq -r --argjson num "$num" '
      ([.[] | select(.number == $num)] | if length == 0 then error("no such pr") else .[0] end)
      | [ (.statusCheckRollup // [])[]
          # BOUND BEFORE THE LOOKUP, exactly as head-checks.jq warns: inside
          # `["A"] | index(.state)` the `.` is the array literal, so `.state` is
          # null and the test silently answers false rather than erroring.
          | (.state // "") as $s
          | (.status // "") as $st
          | if ($st == "COMPLETED") then (.completedAt // "")
            elif ((["SUCCESS","FAILURE","ERROR"] | index($s)) != null)
              then (.startedAt // .createdAt // "")
            else "" end ]
      | map(select(. != "")) | max // ""
    ' 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# _near_miss_resume_rows REPO ME MARK LISTING — LISTING is the same listing
# _stranded_resume_keys reads. The answer comes back in the global
# NEAR_MISS_ROWS, one `<num>\t<comment id>` line per non-draft PR of mine whose
# latest NEAR-MISS names the current head while no valid signal does, and one
# WARN per detection (#319). A global for the same reason _resume_gate uses two:
# the WARN and the rows would otherwise share stdout.
#
# THE BYPASS IS ABOUT EVIDENCE, NOT IMPATIENCE. `_stranded_resume_due`'s twelve
# ticks are the price of not knowing whether a session died before it signalled
# or is still working; a near-miss at the current head answers that question on
# sight — the session announced a head it had finished, and only the wire format
# was wrong. There is nothing left to wait for, so the PR is due now. Genuine
# silence still buys the full twelve, which is the case that threshold was
# measured against.
#
# DETECTED, NEVER HONOURED. Nothing here requests a panel, sets a label, or
# writes to the board at all — the near-miss buys exactly one thing, a resume
# session that posts the real signal. Honouring it would make unrendered
# template text into wire protocol, and #133's rule that the engine acts only on
# the session's own signal is worth more than the fourteen minutes it saves.
#
# THE MALFORMED COMMENT IS EVIDENCE AND IS LEFT ALONE. It is not edited, hidden
# or deleted here or in the prompt: it is the only trace this class of failure
# leaves, and the WARN names its id so a reader can find it rather than so
# anything can tidy it. The head is printed whole, not shortened to the usual
# twelve, because this line's whole purpose is to be compared against a signal
# that is also written out in full.
_near_miss_resume_rows() {
  local repo="$1" me="$2" mark="$3" listing="$4"
  local pr num head payload answered near_sha near_id
  NEAR_MISS_ROWS=""
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    num="$(printf '%s' "$pr" | jq -r '.number')"
    head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    payload="$(printf '%s' "$pr" \
      | jq -c '{data:{repository:{pullRequest:{comments:{nodes:.comments}}}}}')"
    # The same parser the request gate is licensed by: a PR that signalled
    # properly is not stranded and no near-miss beside that signal changes it.
    answered="$(printf '%s' "$payload" \
      | jq -r --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" \
      | jq -r '.sha // ""')"
    [ "$answered" = "$head" ] && continue
    # Both halves of the near-miss in one read: the id is only ever printed
    # beside the sha it belongs to, so splitting them into two jq calls would
    # be two chances for them to describe different comments.
    near_sha=""; near_id=""
    IFS=$'\t' read -r near_sha near_id < <(printf '%s' "$payload" \
      | jq -r --arg me "$me" -f "$BUILDER_LIB_DIR/jq/near-miss-signal.jq" \
      | jq -r '[.sha, .id] | @tsv') || true
    # A near-miss naming a SUPERSEDED head is no evidence at all: the session's
    # own push invalidated what it announced, so whatever it finished is not
    # what is on the branch now. That PR waits out the ordinary twelve ticks.
    if [ -z "$near_sha" ] || [ "$near_sha" != "$head" ]; then continue; fi
    warn "$repo#$num: comment $near_id opens with an unrendered marker slot and names head $head — not a signal (#133), but the round was answered there; resuming this tick instead of the twelfth (#319)"
    NEAR_MISS_ROWS="${NEAR_MISS_ROWS}${num}"$'\t'"${near_id}"$'\n'
  done < <(printf '%s' "$listing" \
    | jq -c '.[] | select((.isDraft | not) and .comments != null)')
}

# _green_head_resume_rows REPO ME MARK LISTING — _near_miss_resume_rows's
# sibling on CHECK evidence instead of near-miss evidence. The answer comes back
# in the global GREEN_HEAD_ROWS, one `<num>\t<head>` line per non-draft PR of
# mine whose head is GREEN and carries no valid signal, with one WARN per
# detection. A global for the same reason the near-miss rows are one.
#
# THE HEAD RIDES BESIDE THE NUMBER because the caller needs it to build the
# `<repo>#<num>@<head>` key `_resume_breaker` counts by (_green_head_breaker).
# Deriving it there from a second read of the listing would be a second chance
# for the two to describe different heads, which is _near_miss_resume_rows's
# reason for carrying its comment id in the row rather than re-reading it.
#
# DETECTION IS NOT DISPATCH, and this function only detects. The WARN below
# therefore names the evidence and stops: whether this tick actually resumes is
# the breaker's answer, said at the breaker's own site. An earlier cut of this
# function ended its WARN with "so resuming this tick instead of the twelfth" —
# a promise it does not get to make once a bypass can be suppressed.
#
# THE BYPASS IS ABOUT EVIDENCE, NOT IMPATIENCE — the same argument #319 made,
# reaching the same conclusion from the other datum. `_stranded_resume_due`'s
# twelve ticks are the price of not knowing whether a session died before it
# signalled or is still working. A green head with no signal answers that
# question on sight: the checks have finished, the head is passing, and nothing
# a session could still be waiting for is outstanding. There is nothing left to
# wait for, so the PR is due now.
#
# PENDING AND RED STILL BUY THE FULL TWELVE, and that is the case the threshold
# was measured against. A pending head has not answered the question the panel
# will ask; a red one is the author's own next task and wakes ci-red instead.
# `none` is deliberately not green here either, though the request gate admits
# it: `none` is also what a head reads a few seconds after a push, before its
# workflows register, so a bypass on `none` would fire one tick after every push
# in a repo with CI. Waiting the twelve there is the status quo, not a
# regression, and it is the fail-safe direction.
#
# DETECTED, NEVER HONOURED. Nothing here requests a panel, sets a label, or
# writes to the board — it buys exactly one thing, a resume session that posts
# the real signal. #133's rule that the engine acts only on the session's own
# signal is not weakened by knowing the session should have posted one.
_green_head_resume_rows() {
  local repo="$1" me="$2" mark="$3" listing="$4"
  local pr num head answered states state
  GREEN_HEAD_ROWS=""
  if ! states="$(_resume_check_states "$repo" "$listing")"; then
    warn "$repo: the check rollup could not be graded; leaving every PR out of green-head resume detection this tick (#384)"
    return 0
  fi
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    num="$(printf '%s' "$pr" | jq -r '.number')"
    head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    state="$(printf '%s\n' "$states" | awk -F'\t' -v n="$num" '$1 == n {print $2; exit}')"
    [ "$state" = green ] || continue
    # The same parser the request gate is licensed by, for the same reason
    # _stranded_resume_keys uses it: resume must classify the exact bodies the
    # request gate does, or the two disagree about what a signal is.
    answered="$(printf '%s' "$pr" \
      | jq -c '{data:{repository:{pullRequest:{comments:{nodes:.comments}}}}}' \
      | jq -r --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" \
      | jq -r '.sha // ""')"
    [ "$answered" = "$head" ] && continue
    warn "$repo#$num: the check at head $head is green and no signal names that head — nothing left to wait for (#384)"
    GREEN_HEAD_ROWS="${GREEN_HEAD_ROWS}${num}"$'\t'"${head}"$'\n'
  done < <(printf '%s' "$listing" \
    | jq -c '.[] | select((.isDraft | not) and .comments != null)')
}

# _flip_owed_resume_rows REPO ME MARK PANEL LISTING — the third stuck state, and
# the one neither engine path can leave. The answer comes back in the global
# FLIP_OWED_ROWS, one `<num>` line per DRAFT of mine that carries a valid signal
# at its CURRENT head, whose head is GREEN, and for which no panelist is
# requested — with one WARN per detection. RESUME_FORCE_FRESH carries the same
# PRs as `<repo>#<num>@<head>` ledger keys, which is how _resume_gate hears
# about them.
#
# THE HOLE IS BETWEEN TWO CORRECT PATHS. PR #386 was ready, green, and carried a
# valid current-head signal; the request pass was six seconds from running when
# the PR was converted to draft. The handoff listing filters drafts out
# (`select(.isDraft | not)`), so the request path stopped seeing it; the resume
# ledger suppressed it, the head being unchanged and no foreign actor having
# spoken. Both are individually right and together nothing in the engine could
# leave that state — no panel was ever requested.
#
# A DUE-PREDICATE, NOT A FLIP. BUILDER.md rules that "an engine may draft a PR
# but only the builder undrafts it": the flip asserts the round was answered
# whole, which is the one judgement its author cannot delegate. So this buys
# exactly what the other two predicates buy, one resume session, and the session
# decides. Nothing here flips, requests, or labels.
#
# WHY THE OPERATOR'S DRAFT IS NOT THE DEFECT. Converting to draft is the fleet's
# general unstick lever, and it is right for one failure mode and wrong for the
# other: it re-armed #381's fingerprint and woke that builder in five minutes,
# and it consumed #386's completed handoff. Nobody can tell those apart from
# outside. With this predicate the lever is safe in both, which is the reason to
# have it rather than a footnote to it.
#
# A DRAFT WITH NO VALID SIGNAL IS UNTOUCHED — that is ordinary interrupted work,
# and it keeps the ledger-and-breaker path it already has.
#
# "NO PANEL REQUESTED" IS REQUEST-PANEL.JQ'S ANSWER, NEVER A SECOND COPY OF IT,
# and the difference is not academic. The obvious reading — nobody is on
# `reviewRequests` — is true of a completely different PR: one the engine itself
# redrafted because a round closed against its author (_redraft_authored_pr),
# where the panel HAS answered, its requests are consumed, and a stale
# current-head signal can still be sitting on the thread. That draft owes a
# round reply, not a flip, and a predicate that named it would tell the session
# to mark an unanswered round ready-for-review. request-panel.jq already draws
# exactly the line that separates them, in the engine's only copy of it: a
# signal SPENT by verdicts that answered it (#286) requests nobody, so the
# redrafted PR returns empty and #386's untouched signal returns the panel. Ask
# it, and the two cases part on the rule the request gate is already bound by.
#
# It costs one GraphQL read per GREEN-HEADED SIGNALLED draft per tick, which the
# listing cannot serve: the verdicts must be `latestOpinionatedReviews` scoped to
# the head, and `gh pr list --json latestReviews` is ruled out for this question
# (COMMENTED masks a standing blocker and its commit.oid is empty, #147). The
# listing-side gates above it — green, and a valid signal at the head — are what
# keep that call off the ordinary interrupted draft, which is the common case.
_flip_owed_resume_rows() {
  local repo="$1" me="$2" mark="$3" panel="$4" listing="$5"
  local owner name pr num head answered states state
  local payload gql_head signal_json to_request
  owner="${repo%%/*}"; name="${repo##*/}"
  FLIP_OWED_ROWS=""
  RESUME_FORCE_FRESH=""
  if ! states="$(_resume_check_states "$repo" "$listing")"; then
    warn "$repo: the check rollup could not be graded; leaving every draft out of flip-owed resume detection this tick (#384)"
    return 0
  fi
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    num="$(printf '%s' "$pr" | jq -r '.number')"
    head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    state="$(printf '%s\n' "$states" | awk -F'\t' -v n="$num" '$1 == n {print $2; exit}')"
    [ "$state" = green ] || continue
    answered="$(printf '%s' "$pr" \
      | jq -c '{data:{repository:{pullRequest:{comments:{nodes:.comments}}}}}' \
      | jq -r --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" \
      | jq -r '.sha // ""')"
    [ "$answered" = "$head" ] || continue
    # NO PANEL REQUESTED, literally: not one panelist is on the request list.
    # This is the state's own definition and it is not what request-panel.jq
    # answers — that predicate says whether a panel is OWED, and it says yes of a
    # partly-requested round too, where a panelist is already reading and the
    # next move is theirs. Both gates are needed and each does one job: this one
    # says nobody was ever asked, the one below says an ask is still owed. An
    # off-panel reviewer is advisory (BUILDER.md) and is never the ask.
    # Owed to the panel sized for this head, not the whole roster (#761).
    _panel_effective "$repo" "$num" "$head" "$panel"
    if [ "$(printf '%s' "$pr" | jq -r --argjson panel "$_PANEL_EFFECTIVE_JSON" \
        '[.reviewRequests[]? | .login // empty
          | select(. as $l | ($panel | index($l)) != null)] | length')" != 0 ]; then
      continue
    fi
    if ! payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
      repository(owner:$owner,name:$name){ pullRequest(number:$num){
        headRefOid
        comments(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){nodes{author{login} body createdAt}}
        reviewRequests(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{requestedReviewer{... on User{login}}}}
        latestOpinionatedReviews(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{author{login} state submittedAt commit{oid}}}
      } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)"; then
      warn "$repo#$num: the verdict lookup failed; leaving this draft out of flip-owed resume detection this tick (#384)"
      continue
    fi
    # The listing and this payload are two snapshots, and a push between them
    # would grade one head and ask about another. Defer rather than guess — the
    # same rule _request_panel applies to its own two snapshots.
    gql_head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
    [ "$gql_head" = "$head" ] || continue
    signal_json="$(printf '%s' "$payload" \
      | jq -c --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" 2>/dev/null)"
    [ -n "$signal_json" ] || signal_json='{"sha":"","createdAt":""}'
    [ "$(printf '%s' "$signal_json" | jq -r '.sha // ""')" = "$head" ] || continue
    to_request="$(printf '%s' "$payload" \
      | jq -r --argjson panel "$_PANEL_EFFECTIVE_JSON" --argjson signal "$signal_json" \
          -f "$BUILDER_LIB_DIR/jq/request-panel.jq" 2>/dev/null)"
    [ -n "${to_request//[[:space:]]/}" ] || continue
    warn "$repo#$num: a draft carrying a valid signal at green head $head, owing a panel ($(printf '%s' "$to_request" | tr '\n' ' ')) that has never been asked — the handoff was consumed, not completed; resuming this tick (#384). The flip stays yours."
    FLIP_OWED_ROWS="${FLIP_OWED_ROWS}${num}"$'\n'
    RESUME_FORCE_FRESH="${RESUME_FORCE_FRESH}${repo}#${num}@${head}"$'\n'
  done < <(printf '%s' "$listing" \
    | jq -c '.[] | select(.isDraft and .comments != null)')
}

# _stranded_resume_keys REPO ME MARK — stdin is the authored open-PR listing
# used by resume detection. Emit only ready PR heads whose latest signal from
# this builder does not name the current head. Drafts already use the original
# resume path and must never be double-counted here, and neither does a PR whose
# thread could not be read (_resume_attach_comments).
_stranded_resume_keys() {
  local repo="$1" me="$2" mark="$3" pr num head answered
  # Use the signal gate's parser rather than maintaining a second definition
  # of MARK_ANSWERED. In particular, fleet comments may wrap the SHA in
  # backticks or put punctuation after the marker; answered-head.jq accepts
  # both, and resume must classify the exact same bodies the request gate does.
  # That parser returns the whole licence, {sha, createdAt}, since #286. Resume
  # asks only "does the latest signal name this head", so it reads the sha half
  # — the same half _request_panel gates on. The time half is the request
  # side's: whether a signal was spent by the verdicts answering it says nothing
  # about whether a session died before posting it.
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    num="$(printf '%s' "$pr" | jq -r '.number')"
    head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    answered="$(printf '%s' "$pr" \
      | jq -c '{data:{repository:{pullRequest:{comments:{nodes:(.comments // [])}}}}}' \
      | jq -r --arg me "$me" --arg mark "$mark" \
          -f "$BUILDER_LIB_DIR/jq/answered-head.jq" \
      | jq -r '.sha // ""')"
    [ "$answered" = "$head" ] || printf '%s#%s@%s\n' "$repo" "$num" "$head"
  done < <(jq -c '.[] | select((.isDraft | not) and .comments != null)')
}

# --- The resume gate (#314) -------------------------------------------------
#
# Resume was the one wake in this engine with no doable-work condition: it
# fired whenever `draft_nums` was non-empty, and `draft_nums` is every open
# draft I author, so a correctly PARKED draft woke a full model session every
# tick, forever, with no self-heal and no cap. PR #311 spent 58 sessions at one
# head across 4h45m, each posting a resume marker and a worklog checkpoint and
# committing nothing; the operator disarming the box is what stopped it.
#
# THE BUILDER'S OWN OUTPUT IS NOT A SIGNAL, and that is the whole decision.
# Nothing outside the builder ever spoke on #311, so a naive "anything changed"
# fingerprint would have re-armed itself on each of those 58 markers and
# suppressed nothing — the self-resetting trap LABELS.md already records for the
# staleness sweep ("label churn is not activity … or the sweep would reset
# itself"). Comments and reviews authored by ME are excluded by construction.
#
# THE HEAD GOES IN THE ID, THE TIMESTAMPS GO IN THE VALUE — the ci-red scheme
# (#17), for the reason recorded at that block: ledger_filter re-fires when the
# VALUE sorts greater, and a SHA has no order, so a head carried in the value
# would suppress exactly the corrective push it must wake on. Carried in the id,
# a new head is an id never seen and always fires, which is the issue's "the
# builder's own commits count: a push is progress" without asking a SHA to
# compare. What remains in the value is then all ISO-8601 — foreign comment,
# foreign review, referenced issue, and since #384 the head's newest check
# conclusion — so a lexical max is a chronological one.
#
# THE CHECK TERM BELONGS IN THE VALUE FOR EXACTLY THAT REASON. A conclusion
# stamp is ISO-8601, so it joins the max without disturbing the invariant; and
# it must NOT go in the id, where every re-run of the same check would mint an
# id never seen and fire again on an unchanged tree.

# _resume_pr_fingerprints REPO — stdin is the authored open-PR listing resume
# detection already fetches. One tab-separated line per DRAFT:
#   <repo>#<num>@<head>  <referenced issue or empty>
#
# THE FOREIGN HALF IS NOT READ FROM THE LISTING, and that is not a style choice.
# `gh pr list --json comments,reviews` generates `comments(first: 100)` /
# `reviews(first: 100)` and does not paginate those nested connections, so the
# array is oldest-first and truncated: `max` over it is the newest of the FIRST
# hundred, and it stops moving for good once the thread passes that mark.
# Measured on the incident PR itself — `gh pr list --json number,comments`
# returns exactly 100 for #311, newest returned `2026-08-03T00:05:52Z`, while
# `/issues/311/comments --paginate` has 124. A builder that floods its own PR
# past 100 comments would be left permanently unwakeable by anyone speaking on
# it, which fails this gate's central criterion on precisely the shape it exists
# for. The newest-foreign lookup therefore goes through _resume_newest_foreign
# below, and the listing no longer fetches those fields at all.
#
# The issue reference is read from the BODY, never from the branch name: crew
# branches are `<type>/<issue>-<slug>` and only some are `build/` (#315 is
# `docs/302-rehearsal-remote`). `Closes #N` and `Refs #N` are the two forms
# BUILDER.md writes; the GitHub closing synonyms ride along. `Part of
# owner/repo#N` is deliberately NOT matched — that form is cross-repo, so the
# number does not address an issue in this repo at all — and neither is a bare
# `#N`, because crew bodies cite epics and siblings in prose and the first such
# mention is not the authorizing one. The leading `(^|[^a-z])` is a word
# boundary: without it `the operator discloses #99 in passing` yields issue 99,
# costing a gh call per tick and a WARN naming a wake nobody declared.
#
# THE PATTERN IS A CONSTANT BECAUSE IT HAS TWO CONSUMERS (#479). The structural
# escalation below names the PR's authorizing issue in its operator alert — the
# issue a human should flag `attention` on, which the engine does not write
# itself — and needs the same answer this function derives; a second copy of a
# regex whose every clause was bought by a named failure is a second thing to
# keep true, and the drift would be silent — both copies parse, and only one of
# them is right. It is passed with `--arg` rather than inlined, so each jq
# program stays single-quoted and the pattern is one string in one place.
# shellcheck disable=SC2016  # a regex, not a shell expansion
_RESUME_ISSUE_RE='(^|[^a-z])(closes|refs|fixes|resolves)[ \t]+#(?<n>[0-9]+)'

_resume_pr_fingerprints() {
  local repo="$1"
  jq -r --arg repo "$repo" --arg re "$_RESUME_ISSUE_RE" '
    .[] | select(.isDraft)
    | ( first( (.body // "") | capture($re; "i") | .n ) // "" ) as $issue
    | "\($repo)#\(.number)@\(.headRefOid)\t\($issue)"
  '
}

# _resume_newest_foreign REPO NUM ME — the newest activity on PR NUM not
# authored by ME, as an ISO-8601 stamp, or empty when nobody else has spoken.
# Nonzero means the lookup itself failed and the answer is unknown.
#
# Paginated REST, not the listing's capped GraphQL connections (above), and not
# a single page of either: `sort`/`direction` are NOT parameters of
# `GET /repos/{owner}/{repo}/issues/{n}/comments` — they belong to the
# repo-level `/issues/comments` list — so GitHub ignores them and a `per_page=1`
# read returns the OLDEST comment, pinning the fingerprint to the first thing
# ever posted. Verified on #311: `-f per_page=3 -f sort=created -f
# direction=desc` returns the same three stamps as the unsorted call, oldest
# first. Full pagination is what actually answers "the newest, at any thread
# length"; it costs ceil(n/100) calls per draft per tick, which is one for a
# normal draft and two for #311's 124, against ~1 draft per builder.
#
# ME is filtered in awk rather than in jq because `gh api --jq` takes no --arg,
# and a login interpolated into a jq program is a login that can break it.
_resume_newest_foreign() {
  local repo="$1" num="$2" me="$3" raw
  raw="$( {
      gh api --paginate "repos/$repo/issues/$num/comments?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE" \
        --jq '.[] | "\(.user.login // "")\t\(.created_at // "")"' \
      && gh api --paginate "repos/$repo/pulls/$num/reviews?per_page=$OPERATING_LIMIT_GITHUB_REST_PAGE" \
        --jq '.[] | "\(.user.login // "")\t\(.submitted_at // "")"'
    } 2>/dev/null )" || return 1
  printf '%s\n' "$raw" \
    | awk -F'\t' -v me="$me" '$1 != me && $2 != "" { print $2 }' \
    | sort | tail -1
}

# _builder_suppression_sync PREFIX KIND KEYS — publish every breaker episode as
# box state. PREFIX is lane-scoped because each resume lane owns an independent
# breaker: one lane becoming actionable must not erase another lane's stop.
#
# The first field is the trip time, not this tick's observation time. Keeping
# an unchanged marker byte-for-byte makes the age meaningful while a head
# remains suppressed. Each active KEY gets its own marker so one lane can retain
# several independent trip times. KEY carries the repo, PR and head that the
# breaker counts by; KIND names the lane. An empty KEYS list means the lane is
# no longer suppressed (heads moved, PRs stopped qualifying, or the episodes
# otherwise cleared).
_builder_suppression_sync() {
  local prefix="$1" kind="$2" keys="${3:-}" key suffix marker old_kind old_key tmp
  local active marker_key
  active="$(printf '%s\n' "$keys" | awk 'NF && !seen[$0]++')"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    suffix="${key//\//__}"; suffix="${suffix//#/_}"; suffix="${suffix//@/_}"
    marker="$prefix.$suffix"
    if [ -f "$marker" ] \
       && IFS=$'\t' read -r _ old_kind old_key <"$marker" \
       && [ "$old_kind" = "$kind" ] && [ "$old_key" = "$key" ]; then
      continue
    fi
    # Preserve a pre-multi-marker episode when upgrading an already suppressed
    # lane. The legacy marker can represent at most one key, so only an exact
    # content match is eligible to carry its original trip time forward.
    if [ -f "$prefix" ] \
       && IFS=$'\t' read -r _ old_kind old_key <"$prefix" \
       && [ "$old_kind" = "$kind" ] && [ "$old_key" = "$key" ]; then
      mv "$prefix" "$marker"
      continue
    fi
    tmp="$marker.tmp.$$"
    printf '%s\t%s\t%s\n' "$(date +%s)" "$kind" "$key" >"$tmp"
    mv "$tmp" "$marker"
  done <<<"$active"

  rm -f "$prefix"
  for marker in "$prefix".*; do
    [ -f "$marker" ] || continue
    marker_key="$(cut -f3- "$marker" 2>/dev/null || true)"
    grep -qxF "$marker_key" <<<"$active" || rm -f "$marker"
  done
}

# Remove records whose repository or lane is no longer part of this engine's
# configured builder sweep. Without this pass, removing a repo from repos.txt
# leaves its last breaker verdict visible forever because no lane caller remains
# to clear it.
_builder_suppression_prune() {
  local repos="$1" marker repo lane keep
  for marker in "$DUTY_DIR"/.builder-suppressed.*; do
    [ -f "$marker" ] || continue
    keep=0
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      for lane in draft stranded near-miss green-head; do
        if [[ "$marker" = "$DUTY_DIR/.builder-suppressed.${repo//\//__}.$lane" \
           || "$marker" = "$DUTY_DIR/.builder-suppressed.${repo//\//__}.$lane."* ]]; then
          keep=1
          break 2
        fi
      done
    done <<<"$repos"
    [ "$keep" -eq 1 ] || rm -f "$marker"
  done
}

# _resume_breaker STATE THRESHOLD — the zero-action circuit breaker. stdin is
# one `<key>\t<fresh|held>` line per draft this tick, `fresh` meaning the ledger
# would dispatch it; stdout is `<key>\t<dispatch|suppress|hold>\t<count>`.
#
# _stranded_resume_due's shape, with one deliberate difference: a key the gate
# HELD this tick keeps its count instead of being dropped. The breaker bounds
# what the ledger does not catch — a chatty external actor waking one head over
# and over — and those wakes are consecutive DISPATCHES, not consecutive ticks,
# so a quiet tick in between must not silently reset the count. Keys absent from
# stdin entirely (merged, closed, or no longer a draft) still disappear, so the
# state cannot grow without bound.
#
# The head is in the key, so any commit resets the count to one: "produced no
# commit" needs no separate observation. Counting on dispatch rather than on
# rc 0 is also deliberate — a session that crashes before committing anything is
# one of the zero-action dispatches this is here to bound.
_resume_breaker() {
  local state="$1" threshold="$2" key want count tmp
  local -A previous=() current=()
  tmp="$state.tmp.$$"
  if [ -f "$state" ]; then
    while IFS=$'\t' read -r key count; do
      [ -n "$key" ] || continue
      previous["$key"]="${count:-0}"
    done <"$state"
  fi
  while IFS=$'\t' read -r key want; do
    [ -n "$key" ] || continue
    [ -n "${current[$key]+x}" ] && continue
    count="${previous[$key]:-0}"
    if [ "$want" != fresh ]; then
      current["$key"]="$count"
      printf '%s\thold\t%s\n' "$key" "$count"
    elif [ "$count" -ge "$threshold" ]; then
      current["$key"]="$count"
      printf '%s\tsuppress\t%s\n' "$key" "$count"
    else
      count=$(( count + 1 ))
      current["$key"]="$count"
      printf '%s\tdispatch\t%s\n' "$key" "$count"
    fi
  done
  : >"$tmp"
  for key in "${!current[@]}"; do
    printf '%s\t%s\n' "$key" "${current[$key]}" >>"$tmp"
  done
  mv "$tmp" "$state"
}

# _resume_lane_breaker REPO LANE STATE KEYS — bound one non-draft resume lane
# (#403)
# without changing what qualifies for that lane. KEYS is one repo#num@head per
# dispatch the lane would otherwise buy this tick. The answer comes back in
# RESUME_LANE_DISPATCH_NUMS because every report is deliberately written to the
# tick log on stdout.
#
# Each caller owns STATE exclusively. `_resume_breaker` prunes absent keys from
# the state it sees, so sharing a file between lanes would make their calls erase
# one another's counters. An empty tick returns early because these counters are
# consecutive dispatches, not consecutive ticks; the next non-empty tick prunes
# stale keys.
_resume_lane_breaker() {
  local repo="$1" lane="$2" state="$3" keys="$4"
  local key verdict count num head nums="" breaker=3 suppressed_keys=""
  local marker="$DUTY_DIR/.builder-suppressed.${repo//\//__}.$lane"
  RESUME_LANE_DISPATCH_NUMS=""
  if [ -z "${keys//[[:space:]]/}" ]; then
    _builder_suppression_sync "$marker" "$lane" ""
    return 0
  fi
  while IFS=$'\t' read -r key verdict count; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"; head="${key##*@}"
    case "$verdict" in
      dispatch)
        nums="$nums $num"
        log "$repo#$num: $lane resume dispatch $count of $breaker at $head"
        if [ "$count" -eq "$breaker" ]; then
          warn "$repo#$num: $lane resume dispatch $count of $count at head ${head:0:12} — the previous $(( count - 1 )) produced no commit, and after this one the $lane lane is suppressed at this head until it moves (#314)"
        fi
        ;;
      suppress)
        suppressed_keys="$suppressed_keys$key"$'\n'
        log "no resume duty: $repo#$num $lane lane suppressed at $head after $count zero-action dispatches — only a push clears it (#314)"
        ;;
      *) : ;;
    esac
  done < <(printf '%s\n' "$keys" | awk 'NF { print $0 "\tfresh" }' \
    | _resume_breaker "$state" "$breaker")
  _builder_suppression_sync "$marker" "$lane" "$suppressed_keys"
  RESUME_LANE_DISPATCH_NUMS="${nums# }"
}

# _near_miss_dispatch_desc ROWS ACTIONABLE_NUMS — retain near-miss context only
# for PRs the final dispatch union actually admits. A suppressed near-miss must
# not ride an unrelated PR's session, but the context remains useful when the
# same PR is independently admitted by the post-threshold or green-head lane.
_near_miss_dispatch_desc() {
  local rows="$1" actionable_nums="$2"
  local num comment_id desc=""
  while IFS=$'\t' read -r num comment_id; do
    [ -n "$num" ] || continue
    case " $actionable_nums " in
      *" $num "*) desc="$desc; #$num (comment ${comment_id:-unknown})" ;;
    esac
  done <<<"$rows"
  printf '%s\n' "${desc#; }"
}

# _green_head_breaker REPO SLUG ROWS — ROWS is GREEN_HEAD_ROWS. The answer comes
# back in the global GREEN_HEAD_DISPATCH_NUMS, the subset of those PRs the
# green-head bypass may actually resume for this tick. A global for the reason
# _resume_gate states: every report here is a log line and log writes to stdout.
#
# THE BYPASS IS BOUNDED, and this is where (#384, review round 1). The detection
# above holds no state at all, so on its own it would name the same PR every
# tick for as long as the head stood — a resume session every five minutes,
# indefinitely, which is the #314 flood re-entering through the door built to
# end it. That argument is the one this PR already made for the flip-owed lane
# (_resume_gate's RESUME_FORCE_FRESH comment); it is no weaker here, and the
# exposure is larger, because "non-draft, green head, no signal at that head" is
# a shape every PR passes through on the ordinary path between CI concluding and
# its builder signalling.
#
# `_resume_breaker` IS REUSED UNMODIFIED, on the key it already counts by:
# `<repo>#<num>@<head>`, so a push resets the count to one with no separate
# observation, and a PR that stops qualifying drops out of stdin and out of the
# state file.
#
# ITS OWN STATE FILE IS NOT A DETAIL. `_resume_breaker` rebuilds its state from
# stdin alone and `mv`s it into place, so keys absent from a given call are
# pruned — deliberate, and pinned by `resume-breaker-state-prunes`. Two call
# sites sharing `.resume-zero-action.<slug>` would therefore erase each other's
# counters every tick: the gate's drafts are not in this call's stdin and this
# call's PRs are not in the gate's. The lanes get one file each.
#
# SUPPRESSION ENDS THIS BYPASS, NOT THE PR'S CLAIM ON RESUME. A suppressed PR is
# still in `stranded_keys` and its twelve-tick counter still advances untouched,
# but the post-threshold stranded lane now has its own breaker too. Either lane
# may independently dispatch while its own breaker allows it.
#
# A TICK WITH NO ROWS RETURNS EARLY rather than rebuilding an empty state file,
# which is _resume_gate's shape and the breaker's own rule: the count is of
# consecutive DISPATCHES, not consecutive ticks, so a quiet tick in between must
# not silently reset it. Stale keys are pruned by the next tick that has rows.
_green_head_breaker() {
  local repo="$1" slug="$2" rows="$3"
  local key verdict count num head nums="" breaker=3 suppressed_keys=""
  local marker="$DUTY_DIR/.builder-suppressed.$slug.green-head"
  GREEN_HEAD_DISPATCH_NUMS=""
  if [ -z "${rows//[[:space:]]/}" ]; then
    _builder_suppression_sync "$marker" green-head ""
    return 0
  fi
  while IFS=$'\t' read -r key verdict count; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"; head="${key##*@}"
    case "$verdict" in
      dispatch)
        nums="$nums $num"
        log "$repo#$num: green head owed a signal — resuming this tick instead of the twelfth, dispatch $count of $breaker at $head (#384)"
        if [ "$count" -eq "$breaker" ]; then
          # ASSERT ONLY WHAT IS OBSERVED, exactly as the gate's trip does: the
          # trip fires as the third dispatch goes out, so only the first two are
          # known to have produced nothing.
          warn "$repo#$num: green-head resume dispatch $count of $count at head ${head:0:12} — the previous $(( count - 1 )) produced no signal, and after this one the green-head bypass is suppressed at this head until it moves (#314); the twelve-tick counter is untouched and still runs"
        fi
        ;;
      suppress)
        suppressed_keys="$suppressed_keys$key"$'\n'
        log "no resume duty: $repo#$num green-head bypass suppressed at $head after $count zero-action dispatches — only a push clears it (#314); the twelve-tick counter still runs"
        ;;
      *) : ;;
    esac
  done < <(
    printf '%s\n' "$rows" \
      | while IFS=$'\t' read -r num head; do
          [ -n "$num" ] || continue
          [ -n "$head" ] || continue
          printf '%s#%s@%s\tfresh\n' "$repo" "$num" "$head"
        done \
      | _resume_breaker "$DUTY_DIR/.resume-zero-action-green.$slug" "$breaker"
  )
  _builder_suppression_sync "$marker" green-head "$suppressed_keys"
  GREEN_HEAD_DISPATCH_NUMS="${nums# }"
}

# _resume_gate REPO SLUG LISTING — the whole doable-work decision for this
# repo's drafts. It says out loud, once per tick, which drafts it withheld and
# why: a ledger trades a burn for SILENCE, and silence is how the fleet starves
# (#59).
#
# Its two answers come back in GLOBALS, not on stdout, because every one of
# those reports is a log line and log writes to stdout (tick.sh redirects the
# whole tick there). A function that returned the dispatch set through the same
# channel would fold its own reporting into the draft list.
#   RESUME_DISPATCH_NUMS  the space-joined draft numbers resume may dispatch for
#   RESUME_COMMIT_LINES   the ledger lines the SESSION must earn — committed by
#                         the caller only on rc 0, the rule .seen-build and
#                         .seen-ci-red already follow, so a crashed session
#                         re-dispatches next tick rather than losing its wake.
_resume_gate() {
  local repo="$1" slug="$2" listing="$3"
  local key foreign issue issue_ts check_ts lines="" fresh want verdict count num head
  local dispatch_nums="" breaker=3 wake fingerprints suppressed_keys=""
  local marker="$DUTY_DIR/.builder-suppressed.$slug.draft"
  local -A ts_by_key=() issue_by_key=()
  RESUME_COMMIT_LINES=""
  RESUME_DISPATCH_NUMS=""
  # FAIL OPEN, AND SAY SO. jq's stderr is no longer swallowed, and a filter that
  # breaks returns nonzero here so the caller keeps its pre-gate draft list: a
  # broken gate must not become a silent permanent stall, which is the exact
  # failure #59 names ("stop paying, do not stop saying") and the one this whole
  # PR is built on. Nothing is committed on this path, so the next working tick
  # decides afresh.
  if ! fingerprints="$(printf '%s' "$listing" | _resume_pr_fingerprints "$repo")"; then
    warn "$repo: the resume fingerprint filter failed; dispatching resume ungated this tick"
    return 1
  fi
  while IFS=$'\t' read -r key issue; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"
    # The floor is `0`, which sorts below any ISO-8601 stamp: a draft nobody
    # else has touched still produces a well-formed ledger line rather than a
    # blank second field, which ledger_filter's NF>=2 guard would drop silently.
    if ! foreign="$(_resume_newest_foreign "$repo" "$num" "$ME")"; then
      warn "$repo#$num: the foreign-activity lookup failed for the resume fingerprint; using the issue half this tick"
      foreign=""
    fi
    [ -n "$foreign" ] || foreign="0"
    # THE REFERENCED ISSUE IS IN THE FINGERPRINT, at one API call per draft per
    # tick, because without it the gate converts a flood into a stall: on this
    # very incident the wake landed as a comment on #290, not on #311, and a
    # PR-only fingerprint would have held the builder asleep through its own
    # park being lifted. Drafts per builder are ~1; the call is affordable and
    # the stall is not. REST, not `gh issue view` — that path dies on crew's
    # projects-classic GraphQL — and `updated_at` moves on label events as well
    # as comments, which is what a park lifted by label alone looks like.
    issue_ts=""
    if [ -n "$issue" ]; then
      issue_ts="$(gh api "repos/$repo/issues/$issue" --jq '.updated_at' 2>/dev/null || echo "")"
      [ -n "$issue_ts" ] || warn "$repo: issue #$issue lookup failed for the resume fingerprint; using the PR half this tick"
    fi
    # The comparison is and must stay LEXICAL: both sides are ISO-8601, which is
    # why the value carries only timestamps (the head lives in the id). With the
    # `0` floor now assigned literally just above, shellcheck infers a number and
    # wants -gt, which would compare `2026-08-03T…` as arithmetic and abort.
    # shellcheck disable=SC2071  # ISO-8601 stamps; lexical is the whole scheme
    [ -n "$issue_ts" ] && [ "$issue_ts" \> "$foreign" ] && foreign="$issue_ts"
    # THE CHECK HALF (#384). A session that parks waiting for CI is unwakeable
    # by the event it is waiting for unless the conclusion is in this value:
    # PR #381 held its signal for `ci-floor`, the check went green, and nothing
    # in the fingerprint could move. Read off the listing the block already
    # fetched, so it costs no call; fail-soft on the _resume_newest_foreign
    # contract — a lookup that failed drops this half rather than inventing a
    # stamp, since an invented one is a wake spent on evidence that is not there.
    check_ts=""
    if ! check_ts="$(_resume_newest_check "$listing" "$num")"; then
      warn "$repo#$num: the check-conclusion lookup failed for the resume fingerprint; using the other halves this tick (#384)"
      check_ts=""
    fi
    # shellcheck disable=SC2071  # ISO-8601 stamps; lexical is the whole scheme
    [ -n "$check_ts" ] && [ "$check_ts" \> "$foreign" ] && foreign="$check_ts"
    ts_by_key["$key"]="$foreign"
    issue_by_key["$key"]="$issue"
    lines="$lines$key $foreign"$'\n'
  done <<<"$fingerprints"
  if [ -z "${lines//[[:space:]]/}" ]; then
    _builder_suppression_sync "$marker" draft ""
    return 0
  fi
  fresh="$(printf '%s' "$lines" | ledger_filter "$DUTY_DIR/.seen-resume")"
  # One line per withheld draft, every tick it is withheld — not report_suppressed's
  # speak-on-change. This branch already logs once per tick either way, so naming
  # the drafts it skipped adds no volume and removes the one thing #59 warns
  # about: a suppression nobody can see.
  printf '%s' "$lines" \
    | ledger_suppressed "$DUTY_DIR/.seen-resume" \
    | while read -r key _; do
        [ -n "$key" ] || continue
        log "no resume duty: ${key%@*} unchanged at ${key##*@}"
      done
  while IFS=$'\t' read -r key verdict count; do
    [ -n "$key" ] || continue
    num="${key#*#}"; num="${num%@*}"; head="${key##*@}"
    case "$verdict" in
      dispatch)
        dispatch_nums="$dispatch_nums $num"
        RESUME_COMMIT_LINES="$RESUME_COMMIT_LINES$key ${ts_by_key[$key]}"$'\n'
        if [ "$count" -eq "$breaker" ]; then
          # The park declares what it waits on, and the WARN carries it where
          # one is parseable: a human or a chair reading duty.log should not
          # have to open the PR to learn which issue the wake is expected on.
          if [ -n "${issue_by_key[$key]}" ]; then
            wake="$repo#${issue_by_key[$key]}"
          else
            wake="none parseable from the PR body"
          fi
          # ASSERT ONLY WHAT IS OBSERVED. The trip fires as the third dispatch
          # goes out, so only the first two are known to have produced nothing;
          # the third has not run yet. Naming all three as commitless would be
          # one session ahead of the evidence.
          warn "$repo#$num: resume dispatch $count of $count at head ${head:0:12} — the previous $(( count - 1 )) produced no commit, and after this one resume is suppressed at this head until it moves (#314); declared wake: $wake"
        fi
        ;;
      suppress)
        suppressed_keys="$suppressed_keys$key"$'\n'
        log "no resume duty: $repo#$num breaker-suppressed at $head after $count zero-action dispatches — only a push clears it (#314)"
        ;;
      *) : ;;   # held by the ledger; already named above
    esac
  done < <(
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # RESUME_FORCE_FRESH IS THE LEDGER'S OVERRIDE, NOT ITS REPLACEMENT
      # (#384). A draft owed a flip is terminal precisely because its head has
      # not moved and nobody else has spoken — the two things the fingerprint is
      # made of — so the ledger is right to hold it and would hold it forever.
      # The override goes HERE rather than around the gate so the forced key
      # still passes through _resume_breaker: an unbounded bypass would dispatch
      # every five minutes for as long as the draft stands, and the zero-action
      # bound is what stops that at three (#314).
      if grep -qxF "$key" <<<"${RESUME_FORCE_FRESH:-}"; then
        printf '%s\tfresh\n' "$key"
      elif grep -qxF "$key ${ts_by_key[$key]}" <<<"$fresh"; then
        printf '%s\tfresh\n' "$key"
      else
        printf '%s\theld\n' "$key"
      fi
    done < <(printf '%s' "$lines" | awk 'NF{print $1}') \
      | _resume_breaker "$DUTY_DIR/.resume-zero-action.$slug" "$breaker"
  )
  _builder_suppression_sync "$marker" draft "$suppressed_keys"
  RESUME_DISPATCH_NUMS="${dispatch_nums# }"
}

# _ci_red_rollup_settled EXPECTED_HEAD — stdin is the post-session gh-pr-view
# object. Success means this ci-red ledger item may be committed. A pending
# rollup at the same head, or an unreadable snapshot, remains retryable. Head
# movement is settled for the old key; the new head gets its own ledger id.
_ci_red_rollup_settled() {
  local expected_head="$1" snapshot head state
  snapshot="$(cat)"
  head="$(printf '%s' "$snapshot" | jq -r '.headRefOid // ""' 2>/dev/null)"
  [ -n "$head" ] || return 1
  [ "$head" != "$expected_head" ] && return 0
  state="$(printf '%s' "$snapshot" \
    | jq -c '[. + {reviewRequests:[], latestOpinionatedReviews:[]}]' 2>/dev/null \
    | jq -r --argjson panel '[]' --arg repo _ --arg human '' \
        -f "$BUILDER_LIB_DIR/jq/head-checks.jq" 2>/dev/null | cut -f4)"
  [ -n "$state" ] && [ "$state" != "pending" ]
}

duty_builder() {
  local duty_repos R
  _repair_seen_build_264
  # Both halves are registry-derived, so this union IS repos.txt and the tick
  # reads nothing outside it (#728). The union is kept rather than collapsed:
  # _discover_my_pr_repos is the seam single-role.md decouples, and its second
  # half is what the reviewer sweep hands over when both roles are enabled.
  duty_repos="$({ read_repo_list "$REPOS_FILE"; _discover_my_pr_repos; } | awk 'NF && !seen[$0]++')"
  _builder_suppression_prune "$duty_repos"

  while IFS= read -r R; do
    [ -z "$R" ] && continue
    _builder_repo "$R"
  done <<<"$duty_repos"
}


# --- The handoff note (#760) --------------------------------------------------
#
# The builder's own record of a claim is the pull request body's `## Worklog`
# and `## Round log` (BUILDER.md): what was done, verified, and next. The
# engine does not write it — the session does — but the engine READS it first
# and keeps a copy: at every dispatch for a claim the sections are fetched,
# saved to $DUTY_DIR/.handoff-<repo>-<num> (the probe ships it, the store
# holds it, so a re-minted box and the host both have the last checkpoint),
# and injected into the prompt ahead of the repository. After a session that
# ran to completion the copy is refreshed — the checkpoint. A fetch that
# fails falls back to the copy, never to nothing said.
_handoff_file() { printf '%s/.handoff-%s-%s' "$DUTY_DIR" "${1//\//_}" "$2"; }

# _handoff_sections BODY — the two sections, each to its next `## ` heading.
_handoff_sections() {
  awk '
    /^## (Worklog|Round log)[[:space:]]*$/ { keep = 1; print; next }
    /^## / { keep = 0 }
    keep { print }
  ' <<<"$1"
}

# _handoff_fetch REPO NUM — fetch, save, print the note (or the saved copy).
_handoff_fetch() {
  local repo="$1" num="$2" file body head note
  file="$(_handoff_file "$repo" "$num")"
  if body="$(gh pr view "$num" -R "$repo" --json body,headRefOid \
      --jq '.headRefOid + "\n" + (.body // "")' 2>/dev/null)" && [ -n "$body" ]; then
    head="${body%%$'\n'*}"
    note="$(_handoff_sections "${body#*$'\n'}")"
    { printf '# %s#%s head=%s at=%s\n' "$repo" "$num" "$head" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf '%s\n' "$note"; } >"$file.tmp" && mv -f "$file.tmp" "$file"
  fi
  [ -r "$file" ] || return 1
  if [ -z "${head:-}" ]; then
    # The live body could not be read: the copy is served, SAID to be a copy,
    # with the head it was taken at, so a note from an older head is never
    # read as current.
    local hdr; hdr="$(head -1 "$file")"
    printf '(stale copy: the live body could not be read; this note is from %s)\n' \
      "$(printf '%s' "$hdr" | sed -n 's/^# [^ ]* \(head=[^ ]* at=[^ ]*\).*/\1/p')"
  fi
  sed '1d' "$file"
}

# _handoff_block REPO NUMS — the prompt block for these pull requests.
_handoff_block() {
  local repo="$1" nums="$2" num note out=""
  for num in $nums; do
    case "$num" in ''|none|*[!0-9]*) continue ;; esac
    note="$(_handoff_fetch "$repo" "$num" 2>/dev/null || true)"
    [ -n "${note//[[:space:]]/}" ] || note="(no worklog yet — start one under \`## Worklog\` in the PR body)"
    out="$out### $repo#$num
$note

"
  done
  [ -n "$out" ] || { printf 'none\n'; return 0; }
  printf '%s' "$out"
}

# --- Parked waits (#760) -----------------------------------------------------
#
# park-until.sh leaves $DUTY_DIR/.wait-<repo>-<num> — `repo num head at` —
# and ends the session. Every builder tick reads them: a wait whose checks
# have concluded, or whose head has moved since (the wait is moot), is due:
# the file is removed and the pull request joins this tick's resume set with
# `why=wait#repo#num`. A wait still pending costs one API read and nothing
# else. The host's tick reads the same files from the store while the box
# sleeps (shared/lib/host/wake.sh), so a parked box is woken for it.
_builder_waits_due() { # REPO — due pull request numbers, one per line
  local repo="$1" f wrepo num head at rollup pending now_head
  for f in "$DUTY_DIR/.wait-${repo//\//_}-"*; do
    [ -f "$f" ] || continue
    read -r wrepo num head at <"$f" || continue
    [ "$wrepo" = "$repo" ] || continue
    rollup="$(gh pr view "$num" -R "$repo" --json headRefOid,statusCheckRollup 2>/dev/null)" || continue
    now_head="$(jq -r '.headRefOid // ""' <<<"$rollup")"
    pending="$(jq -r '[.statusCheckRollup[]? | select((.conclusion // "") == "" and ((.status // "") == "QUEUED" or (.status // "") == "IN_PROGRESS" or (.status // "") == "PENDING" or (.status // "") == "WAITING" or (.status // "") == "REQUESTED" or (.status // "") == "EXPECTED" or (.state // "") == "PENDING" or (.state // "") == "EXPECTED"))] | length' <<<"$rollup")"
    if [ "$pending" = 0 ] || { [ -n "$now_head" ] && [ "$now_head" != "$head" ]; }; then
      log "$repo#$num: parked wait is due (pending=$pending head=${now_head:0:7} parked-at=${head:0:7} since $at)"
      printf '%s\n' "$num"
    fi
  done
}

# _builder_waits_clear REPO NUMS — the due waits, consumed: called once the
# tick has acted on them (the resume session ran to completion, or there was
# nothing left to resume), never before, so a clone or session failure keeps
# the wake (#760).
_builder_waits_clear() {
  local repo="$1" num
  for num in $2; do rm -f "$DUTY_DIR/.wait-${repo//\//_}-$num"; done
}

_builder_repo() {
  local R="$1"
  local slug="${R//\//__}" owner="${R%%/*}" name="${R##*/}"
  local dir="$WORK_DIR/$slug"
  local wt_rules round_rules oneshot_rules panel_json operator_clause
  wt_rules="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name")"
  oneshot_rules="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"
  operator_clause="$(_operator_build_prompt_clause "${LABEL_OPERATOR:-}")"
  local wait_rules wait_nums wait_why=""
  wait_rules="$(render_prompt fragment-wait-rules.txt BIN="$BIN_DIR" REPO="$R")"
  # Parked waits that have concluded join this tick's resume set (#760).
  wait_nums="$(_builder_waits_due "$R" | tr '\n' ' ')"
  wait_nums="${wait_nums% }"
  # shellcheck disable=SC2086  # the numbers split into lines on purpose
  [ -z "$wait_nums" ] || wait_why="$(printf '%s\n' $wait_nums | sed "s|^|wait#$R#|" | paste -sd, -)"

  # panel_for_repo deliberately falls back to FLEET_BENCH when neither the
  # local clone nor the contents API yields a roster. Resolve this author-aware
  # panel once for the whole repository tick; redraft, request and convergence
  # all consume the same roster.
  panel_json="$(panel_for_repo "$R" "$dir" "$ME" | jq -c --arg me "$ME" '. - [$me]')"

  # This must precede resume discovery. A completed foreign review is the wake;
  # after the author-owned conversion below, the same tick's draft listing and
  # resume gate can deliver that fix round to its builder.
  _redraft_authored_rounds "$R" "$panel_json"

  # --- RESUME: interrupted work of mine, checked FIRST. Three shapes: an open
  # draft PR (a session died mid-build), or a claimed issue whose build/*
  # branch exists on my fork with no open PR (died between first push and
  # `gh pr create`). I hold the duty lock, so nothing else of mine can be
  # mid-flight — that lock is what makes resume detection sound. ---
  local resume_json draft_nums orphan_nums="" stranded_nums="" stranded_keys
  local stranded_due_nums="" stranded_due_keys="" _stranded_key _stranded_num
  local near_miss_rows="" near_miss_nums="" near_miss_keys="" near_miss_desc="" _nm_num
  local green_head_rows="" green_head_nums="" flip_owed_nums=""
  local claimed_nums open_heads merged_heads
  # `comments` and `reviews` are deliberately NOT requested: those nested
  # connections are generated as `first: 100` and never paginate, so reading the
  # foreign half from here caps it at the oldest hundred (_resume_pr_fingerprints).
  # The SIGNAL half needs the same depth from the other end of the thread and is
  # read per PR just below (_resume_attach_comments), never from here.
  #
  # `statusCheckRollup` and `reviewRequests` ARE requested, and neither is a
  # capped connection in the sense above: the rollup is scoped to one head and
  # the requests to one PR, both bounded by construction rather than by a
  # thread's length. They are what the three #384 predicates read, and asking
  # for them here is what keeps that whole feature at ZERO additional API calls
  # — the same listing already being fetched now answers "when did this head
  # last conclude", "what did it conclude", and "has anyone been asked".
  resume_json="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft,headRefOid,body,statusCheckRollup,reviewRequests 2>/dev/null || echo err)"
  if [ "$resume_json" = "err" ]; then
    draft_nums=err
    stranded_keys=err
    RESUME_FORCE_FRESH=""
  else
    draft_nums="$(printf '%s' "$resume_json" | jq -r '.[] | select(.isDraft) | .number' \
      2>/dev/null | tr '\n' ' ' || echo err)"
    # The signal half is read from the thread itself, per PR, because the
    # listing's nested connection cannot carry it (_resume_attach_comments).
    _resume_attach_comments "$R" "$resume_json"
    resume_json="${RESUME_LISTING:-$resume_json}"
    stranded_keys="$(printf '%s' "$resume_json" \
      | _stranded_resume_keys "$R" "$ME" "$MARK_ANSWERED" 2>/dev/null || echo err)"
    _near_miss_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$resume_json"
    near_miss_rows="$NEAR_MISS_ROWS"
    # The two check-evidence predicates (#384), each buying one resume session
    # and nothing else. Both run before the gate below, because the flip-owed
    # one hands it RESUME_FORCE_FRESH.
    _green_head_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$resume_json"
    green_head_rows="$GREEN_HEAD_ROWS"
    _flip_owed_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$panel_json" "$resume_json"
    flip_owed_nums="$(printf '%s' "$FLIP_OWED_ROWS" | tr '\n' ' ')"
  fi
  claimed_nums="$(gh issue list -R "$R" --state open --label "$LABEL_CLAIMED" \
    --assignee "$ME" --json number --jq '.[].number' 2>/dev/null || echo err)"
  open_heads="$(gh pr list -R "$R" --state open --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  # A merged build/* branch is NOT interrupted work: its PR landed, and the
  # claim lingers only until GitHub closes the issue on the merge (a same-repo
  # PR always carries Closes #N since ceremony 0.7.11; after-close work is a
  # successor issue minted at the split, never residue on this one — the
  # `post-merge` queue row it used to wait in is retired). Treating it as an orphan
  # phantom-rebuilds merged code every tick and holds the build slot against
  # ready work (incubator#55/#64). Gather merged heads and exclude them below,
  # so every box gets this in the shared engine instead of re-deriving it by
  # hand per box (codex's per-box bridge, heavy-duty/crew#19).
  merged_heads="$(gh pr list -R "$R" --state merged --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  if [ "$draft_nums" = "err" ] || [ "$stranded_keys" = "err" ] \
    || [ "$claimed_nums" = "err" ] || [ "$open_heads" = "err" ] || [ "$merged_heads" = "err" ]; then
    warn "$R: resume detection failed (a listing errored); skipping resume this tick"
    draft_nums=""
  else
    stranded_due_nums="$(printf '%s\n' "$stranded_keys" \
      | _stranded_resume_due "$DUTY_DIR/.resume-unsignalled.$slug" 12 \
      | tr '\n' ' ')"
    while IFS= read -r _stranded_key; do
      [ -n "$_stranded_key" ] || continue
      _stranded_num="${_stranded_key#*#}"; _stranded_num="${_stranded_num%@*}"
      case " $stranded_due_nums " in
        *" $_stranded_num "*) stranded_due_keys="$stranded_due_keys$_stranded_key"$'\n' ;;
      esac
    done <<<"$stranded_keys"
    _resume_lane_breaker "$R" stranded \
      "$DUTY_DIR/.resume-zero-action-stranded.$slug" "$stranded_due_keys"
    stranded_nums="$RESUME_LANE_DISPATCH_NUMS"
    # THE BYPASS RIDES BESIDE THE THRESHOLD, NEVER THROUGH IT (#319). A
    # near-miss PR is in `stranded_keys` like any other unsignalled PR, so its
    # counter advances above exactly as it would have; what is added here is a
    # second, independent reason to be due this tick. `_stranded_resume_due`
    # keeps its threshold, its per-key counters and its state-file format —
    # nothing about genuine silence is collapsed, and a fleet upgrading mid-run
    # finds `.resume-unsignalled.<slug>` exactly as it left it.
    while IFS=$'\t' read -r _nm_num _; do
      [ -n "$_nm_num" ] || continue
      while IFS= read -r _stranded_key; do
        [ -n "$_stranded_key" ] || continue
        _stranded_num="${_stranded_key#*#}"; _stranded_num="${_stranded_num%@*}"
        [ "$_stranded_num" = "$_nm_num" ] || continue
        near_miss_keys="$near_miss_keys$_stranded_key"$'\n'
      done <<<"$stranded_keys"
    done <<<"$near_miss_rows"
    _resume_lane_breaker "$R" near-miss \
      "$DUTY_DIR/.resume-zero-action-nearmiss.$slug" "$near_miss_keys"
    near_miss_nums="$RESUME_LANE_DISPATCH_NUMS"
    if [ -n "${near_miss_nums// /}" ]; then
      stranded_nums="$(printf '%s %s' "$stranded_nums" "$near_miss_nums" \
        | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    fi
    # The green-head bypass rides BESIDE the threshold on the same terms (#384):
    # a second, independent reason to be due, added to the stranded set without
    # touching _stranded_resume_due's counters, threshold or state-file format.
    # A fleet upgrading mid-run finds `.resume-unsignalled.<slug>` as it left it.
    #
    # ...and THROUGH the breaker, which is the half #319's near-miss union does
    # not have and this one must (review round 1 on #384). Beside answers "is
    # this PR due at all"; through answers "how many times may being due buy a
    # session before the evidence is that the sessions are producing nothing".
    # _green_head_breaker holds the whole of that second question, including why
    # it counts on a state file of its own.
    _green_head_breaker "$R" "$slug" "$green_head_rows"
    green_head_nums="$GREEN_HEAD_DISPATCH_NUMS"
    if [ -n "${green_head_nums// /}" ]; then
      stranded_nums="$(printf '%s %s' "$stranded_nums" "$green_head_nums" \
        | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    fi
    near_miss_desc="$(_near_miss_dispatch_desc "$near_miss_rows" "$stranded_nums")"
    # A merged branch never resumes and is not an orphan: it waits for GitHub's
    # close. Re-entry for residue is a successor issue and a fresh branch.
    orphan_nums="$(_orphan_claim_nums "$name" "$claimed_nums" "$merged_heads" "$open_heads")"
    # THE DOABLE-WORK GATE (#314). Every other wake in this engine is
    # ledger-filtered; resume was the one that was not, and a park is invisible
    # to a bare "is there a draft" test. Applied to DRAFTS only: an orphaned
    # claim has no PR to fingerprint, and a stranded ready PR already carries
    # its own 12-tick counter above.
    # Fail open: a gate that cannot run leaves the pre-gate draft list standing
    # and has already warned. Over-dispatching for one tick is recoverable; a
    # silent stall is what #314 is about.
    if _resume_gate "$R" "$slug" "$resume_json"; then
      draft_nums="$RESUME_DISPATCH_NUMS"
    fi
  fi

  # --- The round cap, counted before any session is dispatched (#502). Placed
  # here and not beside the other renders at the top because it reads the
  # authored-PR listing the resume block just fetched, which is the enumeration
  # it would otherwise pay a second `gh pr list` for. Every builder-side prompt
  # below carries `round_rules`, so counting first is what lets the boundary
  # reach the resume, ci-red and build sessions alike — and the resume one is
  # the session that actually performs the cut, on the draft the engine made
  # when round 5 closed against its author. ---
  _round_cap_census "$R" "$panel_json" "$resume_json"
  round_rules="$(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH" MARK_ADDRESSING="$MARK_ADDRESSING" MARK_ANSWERED="$MARK_ANSWERED" ROUND_CAP="$ROUND_CAP_NAMED")"

  if [ -n "$wait_nums" ]; then
    draft_nums="$(printf '%s %s' "${draft_nums:-}" "$wait_nums" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | paste -sd' ' -)"
  fi
  if [ -n "${draft_nums// /}" ] || [ -n "${orphan_nums// /}" ] || [ -n "${stranded_nums// /}" ]; then
    log "$R: resume duty (drafts: ${draft_nums:-none}; orphaned claims:${orphan_nums:-" none"}; unsignalled ready PRs: ${stranded_nums:-none}; of those, signals that missed the wire: ${near_miss_desc:-none}, green heads owed a signal: ${green_head_nums:-none}; drafts owed a flip: ${flip_owed_nums:-none})"
    ensure_main_clone "$R" "$dir" || return 0
    RUN_SESSION_RC=1
    local handoff_block
    handoff_block="$(render_prompt fragment-handoff.txt \
      HANDOFF="$(_handoff_block "$R" "${draft_nums:-} ${stranded_nums:-}")")"
    SESSION_TASK="$(printf '%s\n' "${draft_nums:-}" "${stranded_nums:-}" | tr ' ' '\n' | awk 'NF' | sort -un | paste -sd, -)" \
    WAKE_REASON="${WAKE_REASON:-cron}${wait_why:+,$wait_why}" \
    run_session resume "$R" "$dir" "$TIMEOUT_RESUME" \
      "$(render_prompt resume.txt ME="$ME" REPO="$R" NAME="$name" \
        DRAFTS="${draft_nums:-none}" ORPHANS="${orphan_nums:-none}" \
        STRANDED="${stranded_nums:-none}" NEAR_MISS="${near_miss_desc:-none}" \
        GREEN_HEAD="${green_head_nums:-none}" FLIP_OWED="${flip_owed_nums:-none}" \
        MARK_RESUME="$MARK_RESUME" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules" \
        HANDOFF_BLOCK="$handoff_block" WAIT_RULES="$wait_rules")"
    # The checkpoint: the copy the host and a re-minted box read is the
    # session's own last word, refreshed only when it ran to completion.
    [ "${RUN_SESSION_RC:-1}" -ne 0 ] || _handoff_block "$R" "${draft_nums:-} ${stranded_nums:-}" >/dev/null
    [ "${RUN_SESSION_RC:-1}" -ne 0 ] || _builder_waits_clear "$R" "$wait_nums"
    # Committed only on rc 0, exactly as .seen-build and .seen-ci-red are: a
    # crashed or timed-out session must re-dispatch next tick, never lose the
    # wake it never got to act on.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
      printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$DUTY_DIR/.seen-resume"
    fi
  else
    log "$R: no resume duty"
    # A due wait with nothing to resume names a pull request this tick no
    # longer owes anything on: spent, so the host stops waking for it.
    _builder_waits_clear "$R" "$wait_nums"
  fi

  # --- One listing of my open PRs, several facts. The state of the check at
  # the head was never read by this engine at all: `statusCheckRollup` appeared
  # nowhere in it. That single omission is both #45 (a fix round opened on a red
  # head spends a full panel round relaying a failure the author already had)
  # and #17 (a red head with no round owed and no conflict woke nothing, so an
  # approved, mergeable PR stranded on a transient CI failure). One datum, two
  # bugs — and the round-owed signal was already fetching this exact listing, so
  # headRefOid and statusCheckRollup ride along for no additional call.
  local mine_json mine_rows pr_payload N
  mine_json="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,isDraft,reviewRequests,updatedAt,headRefOid,statusCheckRollup \
    2>/dev/null || echo err)"
  if [ "$mine_json" = "err" ]; then
    mine_rows=err
  else
    # Fetch the head-carrying opinionated verdicts before any session so they
    # can drive round_owed. The gh-pr-list latestReviews field cannot
    # substitute: COMMENTED masks a standing blocker there, and its commit.oid
    # is empty (#147). Handoff deliberately fetches again after the sessions:
    # this early snapshot can be an hour old by then.
    #
    # The same nodes carry the HUMAN's verdict, which is why round_owed's second
    # clause costs no call (#452): the maintainer is off-panel, so nothing else
    # in the engine was reading it, and a human CHANGES_REQUESTED woke no
    # builder at all. `reviewRequests` is already on the listing above, which is
    # the other half of that clause — the request is what spends the wake.
    for N in $(printf '%s' "$mine_json" \
      | jq -r '.[] | select(.isDraft | not) | .number'); do
      pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          latestOpinionatedReviews(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{author{login} state commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" 2>/dev/null || echo '')"
      if [ -z "$pr_payload" ]; then
        warn "$R#$N: review fetch failed; round reads not-owed this tick (request and handoff fetch later)"
        continue
      fi
      mine_json="$(printf '%s' "$mine_json" | jq -c \
        --argjson num "$N" \
        --argjson reviews "$(printf '%s' "$pr_payload" \
          | jq -c '.data.repository.pullRequest.latestOpinionatedReviews.nodes')" \
        'map(if .number == $num then . + {latestOpinionatedReviews:$reviews} else . end)')"
    done
    # `${FLEET_HUMAN:-}`, not a bare deref: this file runs under `set -u` and
    # FLEET_HUMAN has no shipped default — fleet.defaults.conf does not carry
    # it, only the operator's fleet.conf does. _handoff_finalize can deref it
    # bare because it runs once a round; this line runs on every tick for every
    # repo, so an operator who never set it would lose the whole builder tick
    # rather than just the handoff. Empty is the predicates' documented "matches
    # nobody", so such a fleet degrades to exactly today's behaviour.
    mine_rows="$(printf '%s' "$mine_json" \
      | jq -r --argjson panel "$panel_json" --arg repo "$R" \
        --arg human "${FLEET_HUMAN:-}" \
        -f "$DUTY_DIR/lib/jq/head-checks.jq" 2>/dev/null || echo err)"
  fi

  # The check state and head SHA per PR, indexed by number — the green-head
  # precondition the engine's panel request is gated on (#133). Read off the
  # same head-checks rows the round gate already computed, so the request rides
  # the one gh-pr-list snapshot and adds no call. head_by_num pins which head
  # that check state describes, so a push landing after this snapshot defers the
  # request rather than requesting on a head nobody has seen settle.
  local -A check_by_num=() head_by_num=()
  local _hc_key _hc_upd _hc_head _hc_state _hc_rest _hc_num
  if [ "$mine_rows" != "err" ]; then
    while IFS=$'\t' read -r _hc_key _hc_upd _hc_head _hc_state _hc_rest; do
      [ -n "$_hc_key" ] || continue
      _hc_num="${_hc_key##*#}"
      check_by_num[$_hc_num]="$_hc_state"
      head_by_num[$_hc_num]="$_hc_head"
    done <<<"$mine_rows"
  fi

  # --- CI-RED: a PR of mine whose check FAILED at the current head. Placed
  # before BUILD on purpose — a builder repairs its own red PR before claiming
  # another issue (ceremony#163: full-panel approvals at the head, mergeable,
  # and stranded on an HTTP 429 while a job downloaded actions/checkout. No PR
  # code ever ran. No wake condition covered it, because CI-red is actionable
  # authored work even when there is no requested change and no conflict).
  #
  # THE LEDGER ID CARRIES THE HEAD, AND ITS VALUE IS A FIXED SENTINEL. Both
  # halves are deliberate. ledger_filter re-fires when the value sorts GREATER,
  # and a SHA has no order — keyed the usual way, a corrective push whose oid
  # happened to sort below the previous one would be SUPPRESSED, killing
  # exactly the wake this block exists to deliver. So the head goes in the id,
  # where a new head is an id never seen and always fires; and the value cannot
  # advance within one head, which is "never blind-rerun a deterministic
  # failure" (#17's fifth bullet) expressed as data rather than as an
  # instruction a session may forget. updatedAt is wrong here for the same
  # reason from the other side: a comment on the PR would advance it and buy
  # another rerun of an unchanged tree.
  local red_items red_fresh red_key red_checks red_num
  if [ "$mine_rows" = "err" ]; then
    warn "$R: CI-red detection failed; skipping"
  else
    red_items="$(awk -F'\t' '$4 == "red" { print $1 "@" $3 "\thead\t" $6 }' <<<"$mine_rows")"
    red_fresh="$(printf '%s\n' "$red_items" | ledger_filter "$DUTY_DIR/.seen-ci-red")"
    # A red head we have already spent a session on is still red. Stop paying
    # for it; do not stop saying it (#59).
    printf '%s\n' "$red_items" \
      | ledger_suppressed "$DUTY_DIR/.seen-ci-red" \
      | report_suppressed "$DUTY_DIR/.suppressed-ci-red.$slug" "$R: ci-red"
    if [ -z "${red_fresh//[[:space:]]/}" ]; then
      log "$R: no ci-red duty"
    else
      while IFS=$'\t' read -r red_key _ red_checks; do
        [ -n "$red_key" ] || continue
        red_num="${red_key#*#}"; red_num="${red_num%@*}"
        log "$R#$red_num: check RED at head — launching ci-red session (${red_checks:-unknown})"
        ensure_main_clone "$R" "$dir" || continue
        local red_handoff
        red_handoff="$(render_prompt fragment-handoff.txt HANDOFF="$(_handoff_block "$R" "$red_num")")"
        RUN_SESSION_RC=1
        run_session ci-red "$R#$red_num" "$dir" "$TIMEOUT_CIRED" \
          "$(render_prompt ci-red.txt ME="$ME" REPO="$R" NUM="$red_num" \
            CHECKS="${red_checks:-unknown}" WT_RULES="$wt_rules" \
            ROUND_RULES="$round_rules" \
            HANDOFF_BLOCK="$red_handoff" WAIT_RULES="$wait_rules")"
        if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
          local settled_json
          settled_json="$(gh pr view "$red_num" -R "$R" \
            --json number,isDraft,updatedAt,headRefOid,statusCheckRollup \
            2>/dev/null || echo err)"
          if [ "$settled_json" = "err" ]; then
            warn "$R#$red_num: check rollup re-read failed; leaving ci-red head uncommitted"
          else
            if ! printf '%s' "$settled_json" | _ci_red_rollup_settled "${red_key##*@}"; then
              log "$R#$red_num: check still pending after ci-red session; leaving head uncommitted for retry"
            else
              printf '%s\thead\n' "$red_key" | ledger_commit "$DUTY_DIR/.seen-ci-red"
            fi
          fi
        fi
      done <<<"$red_fresh"
    fi
  fi

  # --- BUILD: ready unclaimed issues, or my PRs whose round is WHOLE.
  # Rounds are answered whole (BUILDER.md): a changes-request is actionable
  # only when no panel review request is still outstanding. Ready issues
  # with an assignee are mid-claim, not pickable — counting them launched
  # sessions with nothing to do (codex's 69% busy-tick rate). ---
  #
  # Enumerated, not counted, and filtered through a seen-ledger — the same fix
  # (c)/(d) got on 2026-07-25 and (a)/(b) got in #59. A `ready` issue clears
  # this signal only when the session CLAIMS it, which is an action the session
  # may correctly decline (out of scope, unbuildable, needs a ruling). Declined
  # once, a bare count re-fires a build session every tick forever — and build
  # carries TIMEOUT_BUILD=3600, four times triage's ceiling, over every repo in
  # repos.txt. This was the most expensive instance of the defect and the last
  # one anybody looked at. (That sentence read "a repo set WIDER than repos.txt
  # (_discover_my_pr_repos above)" until #728. Both halves of that union have
  # been registry-derived since the org-wide author sweep went, so the claim
  # contradicted the containment it sits inside.)
  # ONE issue listing, two derived facts. Two calls could disagree about the
  # board between them, and the assigned-count is only meaningful relative to
  # the same snapshot the pickable set came from.
  local ready_json ready_count ready_assigned cr_count open_pr_count head_checks="-"
  local ready_items="" cr_items=""
  # The same one listing, two more derived facts — the board's own numbers,
  # taken before the seen-ledger hides anything and before the slot gate zeroes
  # the set, because by the time the no-duty line is reached every survivor is
  # zero and none of them says which zero this is (#345).
  local ready_board=0 board_read=1 ledgered_rounds=0 slot_prs="" open_pr_ids=""
  ready_json="$(gh issue list -R "$R" --state open --label "$LABEL_READY" \
    --json number,assignees,labels,updatedAt 2>/dev/null || echo err)"
  if [ "$ready_json" = "err" ]; then
    ready_count=err
    board_read=0
  else
    ready_items="$(printf '%s' "$ready_json" \
      | _ready_issue_lines "$R" "${LABEL_OPERATOR:-}" 2>/dev/null || true)"
    ready_assigned="$(printf '%s' "$ready_json" \
      | jq '[.[] | select((.assignees | length) > 0)] | length' 2>/dev/null || echo 0)"
    ready_board="$(printf '%s\n' "$ready_items" | awk 'NF{c++} END{print c+0}')"
    ready_count="$(printf '%s\n' "$ready_items" \
      | ledger_filter "$DUTY_DIR/.seen-build" | awk 'NF{c++} END{print c+0}')"
    # ready+assigned is a board anomaly (a claim swaps ready→claimed); it
    # doesn't wake a builder, but it must not be invisible either — only
    # the triage box's hygiene can fix it.
    [ "$ready_assigned" -gt 0 ] && log "NOTE: $R has $ready_assigned ready issue(s) WITH an assignee (board anomaly; hygiene's to fix)"
  fi
  # Same treatment for the owed-round signal: a round the session declines to
  # answer is a permanent wake otherwise. number+updatedAt travel so the ledger
  # re-wakes on a push or a new review, which is exactly when it should.
  #
  # A RED HEAD IS NOT A ROUND (#45). The rule is the author's: a review request
  # requires a green check at the head, because a red check is the author's own
  # signal and not the panel's work. Measured on crew#40 — two consecutive
  # heads, four reviewer-rounds, every one relaying a CI failure already visible
  # in the job log. The most expensive of the four opened with "CI is red at
  # this head … that gates my approval" and stopped looking, so the cost is not
  # the wasted round, it is the findings that round did not make.
  #
  # Enforced here rather than left to the prompt. The doctrine belongs in
  # fragment-round-rules.txt as well, and is there — but a rule only a model can
  # apply is a rule that gets dropped under a long context, and this one has to
  # hold for every round of every builder. Nothing is stranded by the exclusion:
  # a red head has already woken the ci-red block above, which is the work that
  # has to happen first regardless.
  #
  # ADMIT `green` OR `none`; HOLD `red` AND `pending` (danmt's ruling, #64).
  #
  # The gate is a whitelist for the same reason `is_green` is: "everything but
  # red" is a fallthrough, and a fallthrough is what the CANCELLED bug was.
  # The three states are three different facts and get three behaviours.
  #
  #   red      HELD, and it is the author's own work. Wakes ci-red above.
  #   pending  HELD, and it is NOT the author's work — it is a check that has
  #            not answered yet. Opening the round now spends the panel on a
  #            head that may go red, which is exactly what #45 measured on
  #            crew#40. Transient by definition: the item re-evaluates next
  #            tick (5 minutes) and admits itself once the check settles
  #            green. Must NOT wake ci-red — nothing has failed.
  #   none     ADMITTED. Terminal, not transient: a repo with no CI configured
  #            is `none` FOREVER, so holding on it means the engine can never
  #            open a review round in that repo at all. head-checks.jq already
  #            rules this a state of its own rather than a not-green one — "a
  #            repo with no CI configured and a repo whose checks all passed
  #            are different facts, and only one of them is evidence."
  #
  # Two holds, two messages. A pending hold that borrowed the red wording
  # ("CI first") would tell the operator the author owes work when the author
  # owes nothing but a wait, and that misreading is the whole distinction the
  # ruling draws.
  #
  # An admitted `none` head still travels into the build prompt: the session is
  # bound by the same green-at-the-head rule, and `none` is the one state where
  # there is no check coming to wait for. Telling it so beats it inferring so.
  local blocked_rounds held_rounds
  if [ "$mine_rows" = "err" ]; then
    cr_items=""
    cr_count=err
    head_checks="-"
  else
    cr_items="$(awk -F'\t' '$5 == "owed" && ($4 == "green" || $4 == "none") { print $1, $2 }' <<<"$mine_rows")"
    blocked_rounds="$(awk -F'\t' '$5 == "owed" && $4 == "red" { print $1 }' <<<"$mine_rows")"
    for N in $blocked_rounds; do
      log "$N: round owed, but the check at its head is RED — CI first, no panel round (#45)"
    done
    held_rounds="$(awk -F'\t' '$5 == "owed" && $4 == "pending" { print $1 }' <<<"$mine_rows")"
    for N in $held_rounds; do
      log "$N: round owed, but the check at its head has not finished — waiting for it to settle, no panel round yet (#45)"
    done
    # Admitted on no evidence rather than on green: named, and handed on.
    head_checks="$(awk -F'\t' '$5 == "owed" && $4 == "none" { s = s (s ? "; " : "") $1 " (no checks configured)" } END { print s }' <<<"$mine_rows")"
    [ -n "$head_checks" ] && log "$R: round(s) admitted with no check at the head — $head_checks"
    head_checks="${head_checks:--}"
    # cr_count runs the SAME filter over a different set, so the ledger cause
    # has to be attributed per count or the no-duty line names the wrong noun
    # (#345). This is the rounds side's pre-filter number.
    ledgered_rounds="$(printf '%s\n' "$cr_items" | awk 'NF{c++} END{print c+0}')"
    cr_count="$(printf '%s\n' "$cr_items" \
      | ledger_filter "$DUTY_DIR/.seen-build" | awk 'NF{c++} END{print c+0}')"
  fi
  # Whatever the ledger hid is still real work that nobody has done — the
  # engine stops paying for it, and says so once per change to the set.
  # Per repo, for the reason spelled out in duty-triage.sh: _builder_repo runs
  # once per repo, and one shared state file makes every repo clobber the last.
  printf '%s\n%s\n' "$ready_items" "$cr_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-build" \
    | report_suppressed "$DUTY_DIR/.suppressed-build.$slug" "$R: build"
  if [ "$ready_count" = "err" ] && [ "$cr_count" != "err" ]; then
    # Issue listing fails where issues are disabled (forks); that must not
    # blind the PR-based round detection.
    warn "$R: ready-issue detection failed (issues disabled?); counting 0"
    ready_count=0
  fi
  if [ "$cr_count" != "err" ]; then
    # Any open authored PR occupies the active-build slot. A completed round
    # still wakes so it can be answered, but ready work never starts beside an
    # awaiting-review or draft PR. Post-merge waits have no open PR to count.
    open_pr_count="$(printf '%s' "$mine_json" | jq 'length' 2>/dev/null || echo 0)"
    # Named, not counted: `slot held by heavy-duty/ceremony#231` is the answer
    # to "why did the claim not happen", and the count alone is not (#345).
    # Sorted so the line is stable across ticks whatever order gh returns.
    open_pr_ids="$(printf '%s' "$mine_json" \
      | jq -r --arg repo "$R" '[.[].number] | sort | map("\($repo)#\(.)") | join(", ")' \
        2>/dev/null || true)"
    _gate_ready_for_open_pr || true
  fi
  if [ "$cr_count" = "err" ]; then
    warn "$R: build-duty detection failed; skipping build this tick"
  elif [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    log "$R: build duty (ready unclaimed=$ready_count, whole rounds owed=$cr_count)"
    ensure_main_clone "$R" "$dir" || return 0
    RUN_SESSION_RC=1
    run_session build "$R" "$dir" "$TIMEOUT_BUILD" \
      "$(render_prompt build.txt ME="$ME" REPO="$R" TRIAGE="$FLEET_TRIAGE" \
        CLAIM="$BIN_DIR/claim-issue.sh" \
        POST_ONCE="$BIN_DIR/post-once.sh" \
        DECLINE_MARK="$_DECLINE_MARK" DECLINE_REASONS="$_DECLINE_REASONS" \
        OPERATOR_CLAUSE="$operator_clause" \
        HEAD_CHECKS="$head_checks" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules" ONESHOT_RULES="$oneshot_rules" \
        WAIT_RULES="$wait_rules")"
    # Record what this session SAW, at the state it saw it in — but only if the
    # session actually ran to completion. A crash or timeout leaves the ids
    # uncommitted so the next tick retries: declined and never-got-there must
    # not look the same to the ledger.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      local ready_commit="" ready_reread=1 post_ready_json post_ready_ids
      if [ -n "${ready_items//[[:space:]]/}" ]; then
        if post_ready_json="$(gh issue list -R "$R" --state open --label "$LABEL_READY" \
          --json number,assignees 2>/dev/null)"; then
          post_ready_ids="$(printf '%s' "$post_ready_json" | jq -r --arg repo "$R" \
            '.[] | select((.assignees | length) == 0) | "\($repo)#\(.number)"' 2>/dev/null || true)"
          ready_commit="$(_ready_lines_to_commit "$ready_items" "$post_ready_ids")"
        else
          ready_reread=0
          warn "$R: post-session ready re-query failed; committing no ready lines (#264)"
        fi
      fi
      # The reason travels with the ids, from the board and not from the
      # session's exit: what the session left behind is a comment on the issue,
      # and reading it back here is the only step that turns a per-box ledger
      # entry into something the operator's next no-duty line can name (#462).
      # Only the lines actually being ledgered — a set the session ACTED on
      # commits nothing (#264), and a decline recorded against an id that will
      # re-wake next tick would be reported as held when it is not.
      #
      # The re-read flag travels with the lines because an empty set is
      # ambiguous without it: see _record_declines (claude-bot, round 1).
      _record_declines "$R" "$slug" "$ready_commit" "$ready_reread"
      printf '%s\n%s\n' "$ready_commit" "$cr_items" | ledger_commit "$DUTY_DIR/.seen-build"
    fi
  else
    log "$R: no build duty ($(_no_build_duty_reason \
      "$ready_board" "$ledgered_rounds" "$slot_prs" "$board_read" \
      "$(_declined_for_board "$slug" "$ready_items")"))"
  fi

  # --- HANDOFF: a converged round of mine that owes the human. Convergence
  # computed directly: every panelist's latest opinionated review APPROVES
  # the CURRENT head, no panel request outstanding, PR mergeable RIGHT NOW,
  # no standing unanswered CHANGES_REQUESTED from the human at that head
  # (#452), and THIS HEAD NOT ALREADY HANDED OFF — the refire guard, read off
  # my own MARK_HANDOFF comment at this head (#535). The human is off-panel,
  # so without that guard this wake fires forever after a successful handoff.
  #
  # THE GUARD READS A FACT THE ENGINE OWNS, NEVER A LABEL (#535). It used to
  # read state:needs-human, which the RECONCILER owns and takes off for reasons
  # of its own, each of them correct under its rule: a human CHANGES_REQUESTED
  # (#452 — the ball is the builder's), or blocker:ci-red moving the PR to
  # state:addressing (#535). Every removal re-armed the wake at an unchanged
  # head: the panel still approved, a label does not move mergeable, so the
  # handoff re-requested the human and re-set the label, and the reconciler
  # took it off again — at tick cadence, 135 label events in 6h19m on crew#516,
  # over a red that was main's own and no push by the builder could clear.
  # #452 fixed one trigger with the $human_block disqualifier (kept exactly as
  # it was: a human block at the head is the builder's work, not a handoff to
  # suppress, and the builder's signal at that head spends it so an argued
  # answer still converges and still reaches the human). The guard itself was
  # the defect, and no writer had to yield to fix it: the handoff at a head is
  # the builder's own durable fact, already posted as `MARK_HANDOFF <head>` by
  # _handoff_finalize, so converged.jq reads that line and nothing else. A
  # handed-off head stays handed off until the head MOVES — a push, a rebase or
  # a force-push re-arms the wake; a label removal, a check flipping colour or
  # a reconciler state change does not. The suppressed refire is logged, by
  # PR and head (D5), so the guard is never mistaken for a guard that is not
  # there.
  #
  # HANDOFF IS DELIBERATELY NOT GATED ON A GREEN HEAD, and the obvious
  # improvement is the bug (grok, #64). Adding `&& check_state == "green"`
  # here reads as symmetry with the round gate above, but the two wakes have
  # opposite failure modes: ci-red fires at most ONCE PER HEAD by design (the
  # ledger id carries the oid), so under a red that no push can clear — a
  # runner outage, a failure already on main — ci-red goes quiet after its one
  # session and a green-gated handoff would then wake nothing at all. That is
  # ceremony#163 exactly: full-panel approvals, mergeable, and stranded, which
  # is the incident #17 was filed from. A converged PR reaching the human with
  # a red check is a human's call to make; a converged PR reaching nobody is
  # the failure this module exists to end. ---
  local my_open converged handoff_signal handoff_head handoff_prs="" _pr_at_cap=false
  if [ "$mine_json" = "err" ]; then
    warn "$R: handoff detection failed; skipping"
  else
    # Stay on the same authored-PR snapshot used above. A second listing could
    # add a PR for which this tick has no cached review payload, or drop one
    # whose round was just evaluated.
    my_open="$(printf '%s' "$mine_json" \
      | jq -r '.[] | select(.isDraft | not) | .number')"
    for N in $my_open; do
      # Round-log mirroring runs EVERY tick over my open PRs — not only at
      # handoff — so the body's Round log tracks each round as it is answered
      # (#91 / ceremony#196: "at re-request time"). Since #133 the re-request is
      # the engine's own act (_request_panel, just below), so this sweep and the
      # request share the tick — mirror first, then request. Marker-keyed and
      # idempotent, so a re-tick writes nothing. Best-effort: never blocks the
      # request or the handoff detection below.
      # final=false: per-tick mirroring records only superseded rounds and
      # defers the live one, so a round mid-flight is never stamped as answered
      # before its whole-round reply lands (round-log.jq live-round note).
      _mirror_rounds "$R" "$N" false
      # Sessions above can run for up to an hour and can push a new head while
      # reviewers also act. Fetch again here so request-panel and convergence
      # never act on the early round-detection snapshot (#147). This one read
      # drives both panel request and convergence; a fetch failure or GraphQL
      # error body skips both this tick.
      # createdAt and submittedAt are the ORDERING evidence (#286): whether the
      # signal answers a verdict or merely predates it is a question about time,
      # and this payload already drives the request, so asking for the two
      # timestamps costs no extra call.
      if ! pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid mergeable
          labels(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{name}}
          comments(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){nodes{author{login} body createdAt}}
          reviewRequests(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{requestedReviewer{... on User{login}}}}
          latestOpinionatedReviews(first:'"$OPERATING_LIMIT_GITHUB_PANEL_NODES"'){nodes{author{login} state submittedAt commit{oid}}}
        } } }' -f owner="$owner" -f name="$name" -F num="$N" 2>/dev/null)"; then
        warn "$R#$N: PR state fetch failed; skipping request and handoff this tick"
        continue
      fi
      if ! printf '%s' "$pr_payload" \
        | jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1; then
        warn "$R#$N: PR state payload unusable; skipping request and handoff this tick"
        continue
      fi
      # Request the panel when the round is signalled answered at a green head
      # (#133). When it requests, converged.jq below returns false on the same
      # payload (not every panelist approves the head), so the two never both
      # fire — no continue needed.
      #
      # THE CAP NEVER SUPPRESSES A HANDOFF, and this is the one place where it
      # could: the suppression below is an early return inside _request_panel,
      # so execution CONTINUES into the convergence check regardless of it.
      # That holds unconditionally, whatever the census answered. Written down
      # because it read the other way on this PR's first head and both
      # change-requesting reviewers found it (#566).
      #
      # WHAT IS *NOT* CLAIMED HERE: that at_cap and converged are never both
      # true. On the ordinary path they are not — a fifth round that closed with
      # a full approval still standing at the current head is carved out of
      # at_cap in round-cap.jq, so a PR the human is about to merge is never
      # named for the cut. But $approvals_stand is keyed to the CAP round's
      # head, deliberately (roundcap-later-approval-does-not-lift-the-cap), so a
      # SIXTH round approving a newer head unanimously leaves at_cap true beside
      # a true convergence: the PR hands off AND keeps being named in
      # {{ROUND_CAP}} until a human merges it. Reachable only from outside this
      # build — round six exists only if someone requested the panel past the
      # suppression above — and the amended criterion is scoped to "a fifth
      # round that passes" (#502 D2b), so it does not govern that shape. Named
      # rather than asserted away, because the comment that asserted it away was
      # wrong (@claude-bot-andresmgsl, #566 round 2).
      # The seventh argument is this tick's census answer for THIS PR (#502
      # D2a). Passed rather than read off the global inside the helper, so the
      # suppression is visible at the call site and drivable from a fixture.
      if _at_round_cap "$R" "$N"; then _pr_at_cap=true; else _pr_at_cap=false; fi
      _request_panel "$R" "$N" "$pr_payload" "$panel_json" \
        "${check_by_num[$N]:-}" "${head_by_num[$N]:-}" "$_pr_at_cap"
      # The SAME licence object _request_panel reads, off the same payload and
      # through the same program (#452). converged.jq spends the human's block
      # with it exactly as request-panel.jq spends a panelist's: one predicate
      # for "what did the session signal, and when", never a second copy.
      handoff_signal="$(printf '%s' "$pr_payload" \
        | jq -c --arg me "$ME" --arg mark "$MARK_ANSWERED" \
            -f "$DUTY_DIR/lib/jq/answered-head.jq" 2>/dev/null)"
      [ -n "$handoff_signal" ] || handoff_signal='{"sha":"","createdAt":""}'
      # Against the SAME sized panel the request was made from (#761).
      _panel_effective "$R" "$N" "$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$pr_payload" 2>/dev/null)" "$panel_json"
      converged="$(printf '%s' "$pr_payload" \
        | jq -r --argjson panel "$_PANEL_EFFECTIVE_JSON" --argjson roster "$panel_json" --arg me "$ME" --arg mark_handoff "$MARK_HANDOFF" \
            --arg human "${FLEET_HUMAN:-}" --argjson signal "$handoff_signal" \
            -f "$DUTY_DIR/lib/jq/converged.jq" 2>/dev/null || echo err)"
      case "$converged" in
        true)  handoff_prs="$handoff_prs $N" ;;
        false) : ;;
        # The refire guard held (#535 D5): the wake would have fired and the
        # head already carries my MARK_HANDOFF line. Said out loud, naming the
        # PR and the head, because a guard that silently does nothing is
        # indistinguishable from a guard that is not there (#501's dead
        # detector). One line per tick per suppressed PR, nothing written.
        handed-off)
          handoff_head="$(printf '%s' "$pr_payload" \
            | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
          log "$R#$N: converged at head ${handoff_head:-?} — already handed off at this head; refire suppressed (#535)" ;;
        # UNKNOWN mergeability is GitHub's post-merge recompute flap; the
        # next tick sees the real value. Logged distinctly so a converged-
        # but-deferred PR is never mistaken for an unconverged round.
        defer-unknown) log "$R#$N: converged but mergeability UNKNOWN — deferring to next tick" ;;
        *)     warn "$R#$N: handoff-state fetch failed; skipping" ;;
      esac
    done
    # Option B (#91, ceremony#196): handoff is fully mechanical — no session,
    # no clone. The engine mirrors any un-recorded rounds into the body's Round
    # log, posts the factual handoff comment, requests the human, and sets
    # state:needs-human. No prose is composed here, so no model is spent; the
    # authored record already lives in the Round log, written per round.
    for N in $handoff_prs; do
      log "$R#$N: round converged — handing off (no session, no clone)"
      _handoff_finalize "$R" "$N"
    done
    [ -z "$handoff_prs" ] && log "$R: no handoff duty"
  fi

  # --- REBASE: only CONFLICTING fires; UNKNOWN waits out the flap. Drafts
  # excluded — a conflicting draft belongs to resume, and a panel must never
  # be requested on a draft. ---
  local conflict_prs
  conflict_prs="$(gh pr list -R "$R" --state open --author "$ME" \
    --json number,mergeable,isDraft \
    --jq '.[] | select((.isDraft | not) and .mergeable == "CONFLICTING") | .number' 2>/dev/null || echo err)"
  if [ "$conflict_prs" = "err" ]; then
    warn "$R: rebase detection failed; skipping"
  elif [ -n "$conflict_prs" ]; then
    for N in $conflict_prs; do
      log "$R#$N: conflicting — launching rebase session"
      ensure_main_clone "$R" "$dir" || continue
      run_session rebase "$R#$N" "$dir" "$TIMEOUT_REBASE" \
        "$(render_prompt rebase.txt ME="$ME" REPO="$R" NUM="$N" MARK_ANSWERED="$MARK_ANSWERED" WT_RULES="$wt_rules")"
    done
  else
    log "$R: no rebase duty"
  fi

  # --- WORKTREE hygiene: a build/* worktree is removable only when its
  # branch has PR history AND no PR on it remains open — `--state all` with
  # a joined state list, so a newer closed PR can never shadow an older open
  # one (the .[0]-of-newest-first bug in codex's variant could delete a live
  # branch). A branch with no PR at all is an in-flight claim: resume's
  # business, stays. A dirty worktree is preserved to a `wip/` ref before it
  # is removed and left alone where that push does not land (#168), and the
  # fact that it was left is reported once per (worktree, dirt state) rather
  # than on every tick (#167, _wt_release above). The preservation's record goes
  # on the PR this same lookup found — one query knows both that the branch is
  # done and which PR it was done by, so the record costs no second call and
  # cannot name a different PR than the removal was decided on. Highest number
  # wins where a branch carries several: none is OPEN by the time we are here,
  # so the newest is the one the worktree was last living under. ---
  if [ -d "$dir/.git" ]; then
    git -C "$dir" worktree prune 2>/dev/null || true
    local wt_branch wt_path wt_prs pr_states pr_num
    while read -r wt_branch wt_path; do
      [ -z "$wt_branch" ] && continue
      wt_prs="$(gh pr list -R "$R" --author "$ME" --head "$wt_branch" \
        --state all --json state,number 2>/dev/null || echo err)"
      if [ "$wt_prs" = err ]; then
        warn "$R: worktree-hygiene PR lookup failed for $wt_branch; leaving it"
        continue
      fi
      pr_states="$(printf '%s' "$wt_prs" | jq -r '[.[].state] | join(" ")' 2>/dev/null)"
      case "$pr_states" in
        ""|*OPEN*) : ;;
        *)
          pr_num="$(printf '%s' "$wt_prs" | jq -r 'max_by(.number).number // empty' 2>/dev/null)"
          log "$R: $wt_branch is done ($pr_states) — removing worktree $wt_path"
          _wt_release "$dir" "$R" "$wt_branch" "$wt_path" "$pr_num" "$DUTY_DIR/.seen-wt-dirty" || true
          git -C "$dir" worktree prune 2>/dev/null || true
          ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain \
      | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/build\//{b=$2; sub("refs/heads/","",b); print b, p}')
  fi
}
