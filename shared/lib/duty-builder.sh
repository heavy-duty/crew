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

# Author-side duty repos are repos.txt-scoped, like every other module
# (danmt 2026-07-25). This previously swept the org, on the rationale that
# cast#143's converged round sat unowed 40 minutes while every tick looked
# only at ceremony — but an org-wide author sweep also lets a builder box
# act on repos nobody put in its registry, which is the same unbounded write
# surface the reviewer sweep had. The miss cast#143 describes is now a
# logged line (below) rather than silence, and the repair is to add the repo.
_discover_my_pr_repos() {
  if [ -n "$REVIEW_MY_PR_REPOS" ] || has_role reviewer; then
    # shellcheck disable=SC2086  # splitting the space-joined list is the point
    printf '%s\n' $REVIEW_MY_PR_REPOS
    return 0
  fi
  local SR
  while IFS= read -r SR; do
    [ -n "$SR" ] || continue
    if gh api "repos/$SR/pulls?state=open&per_page=100" --paginate 2>/dev/null \
      | jq -se --arg me "$ME" '[add[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      printf '%s\n' "$SR"
    fi
  done < <(read_repo_list "$REPOS_FILE")
}

# Awareness pass — reports, never acts. Mirrors the reviewer sweep: an open
# PR I authored in a repo outside the registry is an operator signal, not
# licence to work it.
_warn_unscoped_authored() {
  local mine cand unscoped=""
  mine="$(gh search prs --author="$ME" --state open --limit 50 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if ! read_repo_list "$REPOS_FILE" | grep -qxF "${cand%%#*}"; then
      unscoped="$unscoped $cand"
    fi
  done <<<"$mine"
  if [ -n "$unscoped" ]; then
    warn "builder: authored PR(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
  fi
}

# _mirror_rounds REPO NUM — mirror each whole-round reply into the PR body's
# `## Round log` (#91, ceremony#196 option B). The builder owes the reply and
# nothing else; the engine copies it into the body where the merging human
# looks. round-log.jq picks the author's comments after each round's newest
# verdict, keys each by `<!-- round:<head-sha> -->`, and returns the whole new
# body only when something is un-recorded — so an already-mirrored round makes
# a retry a no-op. Body writes go through REST: `gh pr edit --body-file` dies
# on crew's projects-classic GraphQL and writes nothing. This is best-effort
# and the handoff NEVER blocks on it (the same rule as the label write).
_mirror_rounds() {
  # FINAL (default false) is true only at the handoff straggler: it finalizes
  # the live last round too. Per-tick mirroring leaves the live round deferred
  # so a still-arriving round is never stamped "no written reply" (round-log.jq).
  local repo="$1" num="$2" final="${3:-false}" owner name payload newbody
  owner="${repo%%/*}"; name="${repo##*/}"
  # The assignment's status is tested outside the substitution: GraphQL errors
  # may write a non-empty JSON body to stdout, but their non-zero status still
  # reaches this guard (#155).
  payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      body
      reviews(first:100){nodes{author{login} state commit{oid} submittedAt}}
      comments(first:100){nodes{author{login} body createdAt}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)" \
    || { warn "$repo#$num: round-log fetch failed; body left as-is (handoff continues)"; return 0; }
  newbody="$(printf '%s' "$payload" \
    | jq -r --arg me "$ME" --argjson final "$final" -f "$DUTY_DIR/lib/jq/round-log.jq" 2>/dev/null)" \
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
      latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
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
# prevent. Order is chosen for crash-safety, not priority — state:needs-human
# is written LAST because it is the convergence refire guard (converged.jq's
# $not_handed): a box that dies before it refires next tick, and every write
# above is a no-op on the retry (post-once dedup, an already-requested
# reviewer, an already-present round marker). Requesting the human does not
# suppress the refire — converged.jq counts only PANEL requests, and the human
# is off-panel.
_handoff_finalize() {
  local repo="$1" num="$2" comment
  _mirror_rounds "$repo" "$num" true   # finalize the live round: the PR is converging
  comment="$(_handoff_comment "$repo" "$num")"
  if [ -n "$comment" ]; then
    "$BIN_DIR/post-once.sh" "$repo" "$num" "$comment" \
      || warn "$repo#$num: handoff comment did not post (best-effort; label still set)"
  else
    warn "$repo#$num: could not render the handoff comment this tick (best-effort)"
  fi
  gh api "repos/$repo/pulls/$num/requested_reviewers" \
    -f "reviewers[]=$FLEET_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: review request for @$FLEET_HUMAN failed (already requested?)"
  gh issue edit "$num" -R "$repo" --add-label "$LABEL_NEEDS_HUMAN" >/dev/null 2>&1 \
    || warn "$repo#$num: could not set $LABEL_NEEDS_HUMAN"
}

# _request_panel REPO NUM PAYLOAD PANEL_JSON CHECK_STATE HC_HEAD — engine-side
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
_request_panel() {
  local repo="$1" num="$2" payload="$3" panel_json="$4" check_state="$5" hc_head="$6"
  local gql_head answered_head to_request rvr requested_any=0
  gql_head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
  [ -n "$gql_head" ] || { warn "$repo#$num: no head in payload; not requesting"; return 0; }
  # THE SIGNAL GATE. The latest MARK_ANSWERED comment of mine names the head the
  # round was answered at; the engine acts only when that head is the current
  # one. No marker, or a marker for a superseded head (a fix was pushed after
  # the answer and not yet re-signalled), means the round is not answered here —
  # hold, do not infer done-ness from the push.
  answered_head="$(printf '%s' "$payload" \
    | jq -r --arg me "$ME" --arg mark "$MARK_ANSWERED" \
        -f "$DUTY_DIR/lib/jq/answered-head.jq" 2>/dev/null)"
  if [ "$answered_head" != "$gql_head" ]; then
    log "$repo#$num: no round-answered signal at head ${gql_head:0:12} — not requesting (#133)"
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
  to_request="$(printf '%s' "$payload" \
    | jq -r --argjson panel "$panel_json" -f "$DUTY_DIR/lib/jq/request-panel.jq" 2>/dev/null)"
  [ -n "${to_request//[[:space:]]/}" ] || return 0
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

duty_builder() {
  local duty_repos R
  duty_repos="$({ read_repo_list "$REPOS_FILE"; _discover_my_pr_repos; } | awk 'NF && !seen[$0]++')"
  _warn_unscoped_authored

  while IFS= read -r R; do
    [ -z "$R" ] && continue
    _builder_repo "$R"
  done <<<"$duty_repos"
}

_builder_repo() {
  local R="$1"
  local slug="${R//\//__}" owner="${R%%/*}" name="${R##*/}"
  local dir="$WORK_DIR/$slug"
  local wt_rules round_rules oneshot_rules panel_json
  wt_rules="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name")"
  round_rules="$(render_prompt fragment-round-rules.txt TRIAGE="$FLEET_TRIAGE" BENCH="$FLEET_BENCH" MARK_ADDRESSING="$MARK_ADDRESSING" MARK_ANSWERED="$MARK_ANSWERED")"
  oneshot_rules="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")"

  # --- RESUME: interrupted work of mine, checked FIRST. Two shapes: an open
  # draft PR (a session died mid-build), or a claimed issue whose build/*
  # branch exists on my fork with no open PR (died between first push and
  # `gh pr create`). I hold the duty lock, so nothing else of mine can be
  # mid-flight — that lock is what makes resume detection sound. ---
  local draft_nums orphan_nums="" claimed_nums open_heads merged_heads N branch
  draft_nums="$(gh pr list -R "$R" --state open --author "$ME" --draft \
    --json number --jq '.[].number' 2>/dev/null | tr '\n' ' ' || echo err)"
  claimed_nums="$(gh issue list -R "$R" --state open --label "$LABEL_CLAIMED" \
    --assignee "$ME" --json number --jq '.[].number' 2>/dev/null || echo err)"
  open_heads="$(gh pr list -R "$R" --state open --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  # A merged build/* branch is NOT interrupted work: its PR landed, and the
  # claim lingers only until triage moves the issue to its post-merge state
  # (heavy-duty/ceremony#172 — the PR carried Refs #N, not Closes, because the
  # remaining ACs are post-merge and triage-owned). Treating it as an orphan
  # phantom-rebuilds merged code every tick and holds the build slot against
  # ready work (incubator#55/#64). Gather merged heads and exclude them below,
  # so every box gets this in the shared engine instead of re-deriving it by
  # hand per box (codex's per-box bridge, heavy-duty/crew#19).
  merged_heads="$(gh pr list -R "$R" --state merged --author "$ME" \
    --json headRefName --jq '.[].headRefName' 2>/dev/null || echo err)"
  if [ "$draft_nums" = "err" ] || [ "$claimed_nums" = "err" ] || [ "$open_heads" = "err" ] || [ "$merged_heads" = "err" ]; then
    warn "$R: resume detection failed (a listing errored); skipping resume this tick"
    draft_nums=""
  else
    for N in $claimed_nums; do
      branch="$(gh api "repos/$ME/$name/git/matching-refs/heads/build/$N-" \
        --jq '.[0].ref // "" | sub("^refs/heads/"; "")' 2>/dev/null || echo "")"
      [ -z "$branch" ] && continue
      # Post-merge wait, not an orphan: the branch already merged. Never resume
      # it — re-entry for any residue is a fresh branch off current main, by
      # a builder claiming the re-readied issue normally (#172), not this one.
      if printf '%s\n' "$merged_heads" | grep -qx "$branch"; then continue; fi
      if ! printf '%s\n' "$open_heads" | grep -qx "$branch"; then
        orphan_nums="$orphan_nums $N"
      fi
    done
  fi
  if [ -n "${draft_nums// /}" ] || [ -n "${orphan_nums// /}" ]; then
    log "$R: resume duty (drafts: ${draft_nums:-none}; orphaned claims:${orphan_nums:-" none"})"
    ensure_main_clone "$R" "$dir" || return 0
    run_session resume "$R" "$dir" "$TIMEOUT_RESUME" \
      "$(render_prompt resume.txt ME="$ME" REPO="$R" NAME="$name" \
        DRAFTS="${draft_nums:-none}" ORPHANS="${orphan_nums:-none}" \
        MARK_RESUME="$MARK_RESUME" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules")"
  else
    log "$R: no resume duty"
  fi

  panel_json="$(panel_for_repo "$R" "$dir" | jq -c --arg me "$ME" '. - [$me]')"

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
    for N in $(printf '%s' "$mine_json" \
      | jq -r '.[] | select(.isDraft | not) | .number'); do
      pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
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
    mine_rows="$(printf '%s' "$mine_json" \
      | jq -r --argjson panel "$panel_json" --arg repo "$R" \
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
        RUN_SESSION_RC=1
        run_session ci-red "$R#$red_num" "$dir" "$TIMEOUT_CIRED" \
          "$(render_prompt ci-red.txt ME="$ME" REPO="$R" NUM="$red_num" \
            CHECKS="${red_checks:-unknown}" WT_RULES="$wt_rules")"
        if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
          printf '%s\thead\n' "$red_key" | ledger_commit "$DUTY_DIR/.seen-ci-red"
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
  # carries TIMEOUT_BUILD=3600, four times triage's ceiling, over a repo set
  # WIDER than repos.txt (_discover_my_pr_repos above). This was the most
  # expensive instance of the defect and the last one anybody looked at.
  # ONE issue listing, two derived facts. Two calls could disagree about the
  # board between them, and the assigned-count is only meaningful relative to
  # the same snapshot the pickable set came from.
  local ready_json ready_count ready_assigned cr_count open_pr_count head_checks="-"
  local ready_items="" cr_items=""
  ready_json="$(gh issue list -R "$R" --state open --label "$LABEL_READY" \
    --json number,assignees,updatedAt 2>/dev/null || echo err)"
  if [ "$ready_json" = "err" ]; then
    ready_count=err
  else
    ready_items="$(printf '%s' "$ready_json" | jq -r --arg repo "$R" \
      '.[] | select((.assignees | length) == 0) | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null || true)"
    ready_assigned="$(printf '%s' "$ready_json" \
      | jq '[.[] | select((.assignees | length) > 0)] | length' 2>/dev/null || echo 0)"
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
    if [ "$open_pr_count" -gt 0 ] && [ "$ready_count" -gt 0 ]; then
      log "$R: $open_pr_count open authored PR(s) occupy the build slot — not claiming a ready issue"
      ready_count=0
    fi
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
        HEAD_CHECKS="$head_checks" \
        WT_RULES="$wt_rules" ROUND_RULES="$round_rules" ONESHOT_RULES="$oneshot_rules")"
    # Record what this session SAW, at the state it saw it in — but only if the
    # session actually ran to completion. A crash or timeout leaves the ids
    # uncommitted so the next tick retries: declined and never-got-there must
    # not look the same to the ledger.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      printf '%s\n%s\n' "$ready_items" "$cr_items" | ledger_commit "$DUTY_DIR/.seen-build"
    fi
  else
    log "$R: no build duty"
  fi

  # --- HANDOFF: a converged round of mine that owes the human. Convergence
  # computed directly: every panelist's latest opinionated review APPROVES
  # the CURRENT head, no panel request outstanding, PR mergeable RIGHT NOW,
  # and state:needs-human not already set (the human is off-panel — without
  # the refire guard this wake fires forever after a successful handoff).
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
  local my_open converged handoff_prs=""
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
      if ! pr_payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid mergeable
          labels(first:50){nodes{name}}
          comments(last:100){nodes{author{login} body}}
          reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
          latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
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
      _request_panel "$R" "$N" "$pr_payload" "$panel_json" \
        "${check_by_num[$N]:-}" "${head_by_num[$N]:-}"
      converged="$(printf '%s' "$pr_payload" \
        | jq -r --argjson panel "$panel_json" --arg needs_human "$LABEL_NEEDS_HUMAN" \
            -f "$DUTY_DIR/lib/jq/converged.jq" 2>/dev/null || echo err)"
      case "$converged" in
        true)  handoff_prs="$handoff_prs $N" ;;
        false) : ;;
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
  # business, stays. A dirty worktree is never force-removed. ---
  if [ -d "$dir/.git" ]; then
    git -C "$dir" worktree prune 2>/dev/null || true
    local wt_branch wt_path pr_states
    while read -r wt_branch wt_path; do
      [ -z "$wt_branch" ] && continue
      pr_states="$(gh pr list -R "$R" --author "$ME" --head "$wt_branch" \
        --state all --json state --jq '[.[].state] | join(" ")' 2>/dev/null || echo err)"
      case "$pr_states" in
        err)       warn "$R: worktree-hygiene PR lookup failed for $wt_branch; leaving it" ;;
        ""|*OPEN*) : ;;
        *)
          log "$R: $wt_branch is done ($pr_states) — removing worktree $wt_path"
          if git -C "$dir" worktree remove "$wt_path" 2>/dev/null; then
            git -C "$dir" branch -D "$wt_branch" 2>/dev/null || true
          else
            warn "worktree $wt_path not clean; leaving it for inspection"
          fi
          git -C "$dir" worktree prune 2>/dev/null || true
          ;;
      esac
    done < <(git -C "$dir" worktree list --porcelain \
      | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/build\//{b=$2; sub("refs/heads/","",b); print b, p}')
  fi
}
