# duty-review.sh — the reviewer wake: outstanding review requests, one
# merged candidate set, verdict dedup by head SHA, re-request auto-approve.
#
# Doctrine (REVIEWER.md / FLEET.md), as amended by danmt 2026-07-25:
#  - repos.txt IS the scope. A review request authorizes a review only in a
#    repo this box carries. The previous rule ("a request anywhere in the org
#    or a fleet fork is authorization; no repo list scopes it") made every
#    box's write surface the entire org, which no registry could bound: the
#    #26 interlock narrows repos.txt and so confined triage and hygiene, but
#    NOT this module. Scope is now the registry.
#    Corrected 2026-07-27 (#52): this note used to claim the interlock also
#    confined ATTENTION. It does not, and never did — duty-attention.sh reads
#    the authenticated-user issues endpoint on purpose, cross-repo, and
#    reaches repos not in repos.txt. That inaccuracy mattered: it is the kind
#    of claim that reads like coverage, which is the whole complaint #52 was
#    filed about. drill/rehearsal-safety.sh now checks attention separately
#    rather than assuming repos.txt bounds it.
#  - Awareness is still org-wide, but it never acts. One search query per
#    tick reports requests outside the registry, so the failure mode the old
#    rule existed to prevent (cast#143: a converged round sat unowed for 40
#    minutes) surfaces as a logged line instead of silence. If one of those
#    matters, the repo belongs in repos.txt — that is an operator decision,
#    not something a sweep should make by writing to a repo nobody listed.
#  - Truth comes from object endpoints (pulls API, pulls/N/reviews). The
#    SEARCH index lags — it caused missed wakes (cast#143, box#164, rig#112,
#    nine hours) and double reviews (#26, #29). Search only ADDS candidates.
#  - ONE candidate set, merged and deduped by (repo, PR) BEFORE acting —
#    sequential source passes double-announced on ceremony#32 (grok + kimi).
#  - requested_reviewers self-clears on submit, but only when a verdict lands.
#    A completed session may correctly decline or fail its one-shot submit, so
#    unchanged requests also pass through a seen-ledger (#61). A changed PR
#    advances updated_at and wakes again.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

# Repos where I author an open PR — read off the sweep's own pulls pages at
# zero extra API cost (claude-bot's cast#143 fix). Consumed by duty-builder.
REVIEW_MY_PR_REPOS=""

# rereq_decision <mine_oid> <head> <mine_state> <mine_at> <req_at> [auto_on]
# The re-request policy as a PURE function, so every transition is fixture-
# testable (#114). Emits exactly one of:
#   queue        — the head moved past my verdict, OR (the #114 fix) a
#                  re-request arrived over a STANDING non-approval
#                  (CHANGES_REQUESTED / DISMISSED) at an unchanged head. A live
#                  block is not a stale verdict: only a real re-review can judge
#                  whether it was resolved in-thread, so never auto-approve it.
#   auto-approve — my standing APPROVED covers this head and a newer re-request
#                  arrived. ceremony#94's operator ruling: a stale approval must
#                  not sit as a blocker. This narrowing SERVES that intent.
#   skip         — my verdict covers this head and no newer re-request exists
#                  (request mid-clear or stale search index).
#
# AUTO_APPROVE_REREQUEST governs ONE edge: whether a standing APPROVED under a
# newer re-request auto-approves or queues a real review (#151). It does NOT
# govern whether the re-request is consulted. It used to: the flag sat in front
# of the whole timestamp comparison, so `auto=0` collapsed BOTH branches to
# `skip`, and a box with the flag off answered "standing block + newer
# re-request + unchanged head" with `skip` every tick, forever — the reviewer
# never came back and the round could not converge. That cost ceremony#207 37
# minutes and needed clearing by hand; the box that re-reviewed the same head
# fine differed by configuration, not by engine.
rereq_decision() {
  local mine_oid="$1" head="$2" mine_state="$3" mine_at="$4" req_at="$5" auto="${6:-1}"
  if [ "$mine_oid" != "$head" ]; then echo queue; return 0; fi
  if [ "$req_at" != "-" ] && [ "$mine_at" != "-" ] && [[ "$req_at" > "$mine_at" ]]; then
    if [ "$mine_state" = "APPROVED" ]; then
      if [ "$auto" = "1" ]; then echo auto-approve; else echo skip; fi
    else
      echo queue
    fi
  else
    echo skip
  fi
}

# _mark_addressing REPO NUM ROSTER_JSON — after MY verdict lands, evaluate the
# round and, if it closed WITHOUT full approval, set state:addressing (#130).
#
# The reviewer that lands the last verdict does this, not the author's next
# builder tick: it is already here, it already computed the round to decide its
# own action, and it does the right thing even when the author's box is the one
# that is down — the case the board most needs to survive. addressing.jq is the
# deliberate mirror of converged.jq; ROSTER_JSON is the PR repo's full panel and
# the PR AUTHOR (not $ME the reviewer) is subtracted here, since the required
# verdicts are the panel minus the author.
#
# Best-effort and gating NOTHING: this runs AFTER the verdict has already
# landed, so a failed label write costs a stale board the reconciler corrects
# on its next sweep, never a lost or blocked verdict. The engine write is
# optimistic; the reconciler stays authoritative.
_mark_addressing() {
  local repo="$1" num="$2" roster_json="$3" owner name payload author eff_panel verdict
  owner="${repo%%/*}"; name="${repo##*/}"
  payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      headRefOid
      author{login}
      labels(first:50){nodes{name}}
      reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
      latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null || echo '')"
  [ -n "$payload" ] || { warn "review: $repo#$num addressing eval fetch failed; skipping (best-effort)"; return 0; }
  author="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.author.login // ""' 2>/dev/null)"
  eff_panel="$(printf '%s' "$roster_json" | jq -c --arg a "$author" '. - [$a]' 2>/dev/null || echo '[]')"
  verdict="$(printf '%s' "$payload" \
    | jq -r --argjson panel "$eff_panel" --arg addressing "$LABEL_ADDRESSING" \
        -f "$DUTY_DIR/lib/jq/addressing.jq" 2>/dev/null || echo err)"
  case "$verdict" in
    true)
      log "review: $repo#$num round closed without full approval — setting $LABEL_ADDRESSING"
      gh issue edit "$num" -R "$repo" --add-label "$LABEL_ADDRESSING" >/dev/null 2>&1 \
        || warn "review: $repo#$num could not set $LABEL_ADDRESSING (reconciler will)"
      ;;
    false) : ;;
    *) warn "review: $repo#$num addressing eval failed; skipping (best-effort)" ;;
  esac
  return 0
}

duty_review() {
  local candidates="" page SR sweep_complete=1 acted_prs=""
  # The registry is the scope. Object endpoints only — one authoritative
  # pulls page per carried repo, never the lagging search index.
  while IFS= read -r SR; do
    [ -n "$SR" ] || continue
    page="$(gh api "repos/$SR/pulls?state=open&per_page=100" --paginate 2>/dev/null | jq -cs 'add // []')" \
      || { warn "review: pulls fetch failed for $SR; skipping repo this tick"; sweep_complete=0; continue; }
    candidates="$candidates
$(printf '%s' "$page" | jq -r --arg me "$ME" --arg sr "$SR" \
      '.[] | select(.draft | not) | select([.requested_reviewers[].login] | index($me)) | "\(.created_at) \(.updated_at) \($sr) \(.number)"')"
    if printf '%s' "$page" | jq -e --arg me "$ME" '[.[] | select(.user.login == $me)] | length > 0' >/dev/null; then
      REVIEW_MY_PR_REPOS="$REVIEW_MY_PR_REPOS $SR"
    fi
  done < <(read_repo_list "$REPOS_FILE")

  # Awareness pass — reports, never acts. A request outside the registry is
  # an operator signal ("should this box carry that repo?"), not a licence to
  # write to it. Cheap by construction: one search call, and the index's lag
  # is acceptable for a hint in a way it never was for the queue itself.
  local outside cand unscoped=""
  outside="$(gh search prs --review-requested="$ME" --state open --limit 50 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if ! read_repo_list "$REPOS_FILE" | grep -qxF "${cand%%#*}"; then
      unscoped="$unscoped $cand"
    fi
  done <<<"$outside"
  if [ -n "$unscoped" ]; then
    warn "review: request(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
  fi

  # One candidate per (repo, PR) — first mention wins (the authoritative
  # sweep precedes the backstop), then oldest-first for the acting order.
  candidates="$(printf '%s\n' "$candidates" | awk 'NF==4 && !seen[$3"#"$4]++' | sort)"
  if [ -z "$candidates" ]; then
    # Only a complete empty sweep proves the suppressed set cleared. A failed
    # repo page makes the set unknown, so preserve its prior report state.
    printf '' | report_suppressed_if_complete "$sweep_complete" \
      "$DUTY_DIR/.suppressed-review" "review"
    log "review: no outstanding review requests anywhere"
    return 0
  fi

  local _created updated N owner name fields head mine_oid mine_at mine_state req_at head_now body decision
  local queue item queue_items=""
  while read -r _created updated SR N; do
    [ -z "${N:-}" ] && continue
    queue=0
    owner="${SR%%/*}"; name="${SR##*/}"
    # Per-PR dedup guard: my own latest VERDICT's commit oid vs the live
    # head — one GraphQL call fetches both plus what the re-request rule
    # needs. states filter excludes COMMENTED: a comment is a non-verdict.
    fields="$(RV_ME="$ME" gh api graphql \
      -f query='query($owner:String!,$name:String!,$num:Int!,$me:String!){
        repository(owner:$owner,name:$name){ pullRequest(number:$num){
          headRefOid
          reviews(author:$me,last:1,states:[APPROVED,CHANGES_REQUESTED,DISMISSED]){nodes{commit{oid} submittedAt state}}
          timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT],last:20){
            nodes{... on ReviewRequestedEvent{createdAt requestedReviewer{... on User{login}}}}}
        } } }' \
      -f owner="$owner" -f name="$name" -F num="$N" -f me="$ME" \
      --jq '.data.repository.pullRequest as $pr
        | ($pr.reviews.nodes[0] // {}) as $mine
        | ([$pr.timelineItems.nodes[] | select((.requestedReviewer.login // "") == env.RV_ME) | .createdAt] | max // "-") as $req
        | "\($pr.headRefOid) \($mine.commit.oid // "-") \($mine.submittedAt // "-") \($mine.state // "-") \($req)"' \
      2>/dev/null || echo err)"
    if [ "$fields" = "err" ]; then
      warn "review: $SR#$N state fetch failed; skipping this tick"
      sweep_complete=0
      continue
    fi
    # DISMISSED is now in the states filter and $mine_state carries the verdict:
    # a re-request over my STANDING verdict must branch on whether that verdict
    # is an APPROVED (auto-approvable) or a live block (a real re-review is owed).
    read -r head mine_oid mine_at mine_state req_at <<<"$fields"

    decision="$(rereq_decision "$mine_oid" "$head" "$mine_state" "$mine_at" "$req_at" "${AUTO_APPROVE_REREQUEST:-1}")"
    case "$decision" in
      auto-approve)
        # My standing APPROVED covers this head and a newer re-request arrived
        # (ceremony#94). Head re-verified live immediately before submitting;
        # the submit goes through the one-shot gate like any verdict. This path
        # never enters the queue-side ledger.
        head_now="$(gh api "repos/$SR/pulls/$N" --jq .head.sha 2>/dev/null || echo err)"
        if [ "$head_now" = "$head" ]; then
          body="$(mktemp)"
          printf 'Re-requested at unchanged head %s — my latest review already covers this tree; approving per the re-request rule.\n' "$head" >"$body"
          # --supersede-own: the approval must REPLACE my stale verdict at this
          # same head; the gate's normal already-present check would refuse it
          # and the wake would refire forever. Idempotent across ticks because
          # the new approval makes mine_at newer than req_at.
          if "$BIN_DIR/submit-verdict.sh" "$SR" "$N" "$head" approve "$body" --supersede-own; then
            log "review: $SR#$N auto-approved re-request at unchanged head ${head:0:12}"
            # A verdict landed — evaluate the round for state:addressing (#130).
            acted_prs="$acted_prs $SR#$N"
          else
            warn "review: $SR#$N auto-approve did not land (will retry next tick)"
          fi
          rm -f "$body"
        elif [ "$head_now" = "err" ]; then
          warn "review: $SR#$N head re-verify failed; deferring"
          sweep_complete=0
        else
          log "review: $SR#$N head moved during dedup — queued for a real review"
          queue=1
        fi
        ;;
      queue)
        # Either the head moved past my verdict, or (#114) a re-request landed
        # over a STANDING request-changes / dismissed verdict at an unchanged
        # head. Route it to a real review round; never rubber-stamp a live block.
        # The queued session's verdict is admitted at this same head by
        # submit-verdict.sh's (me, PR, head, round) coverage key.
        if [ "$mine_oid" = "$head" ]; then
          log "review: $SR#$N re-requested at unchanged head ${head:0:12} over a standing ${mine_state} — queuing a real review, not auto-approving (#114)"
        fi
        queue=1
        ;;
      skip)
        log "review: $SR#$N my latest review already covers head ${head:0:12}; skipping (request mid-clear or stale search)"
        ;;
    esac

    [ "$queue" -eq 1 ] || continue
    item="$SR#$N $updated"
    queue_items="$queue_items
$item"
  done <<<"$candidates"

  # Partition the whole queue once. Besides avoiding one ledger read per PR,
  # using the exact inverse helpers guarantees every queued item is either
  # prompted or reported as suppressed, never both and never neither.
  local fresh_items suppressed
  fresh_items="$(printf '%s\n' "$queue_items" | ledger_filter "$DUTY_DIR/.seen-review")"
  suppressed="$(printf '%s\n' "$queue_items" | ledger_suppressed "$DUTY_DIR/.seen-review")"
  printf '%s\n' "$suppressed" \
    | report_suppressed_if_complete "$sweep_complete" \
        "$DUTY_DIR/.suppressed-review" "review"

  # Assemble prompts only from the fresh partition. Its input follows the
  # oldest-first candidate order, so repo and PR ordering remain unchanged.
  local -A repo_prs=() repo_items=()
  local repo_order=() key
  while read -r key updated; do
    [ -n "${updated:-}" ] || continue
    SR="${key%#*}"
    N="${key##*#}"
    if [ -z "${repo_prs[$SR]:-}" ]; then repo_order+=("$SR"); fi
    repo_prs[$SR]="${repo_prs[$SR]:-}$N "
    repo_items[$SR]="${repo_items[$SR]:-}
$key $updated"
  done <<<"$fresh_items"

  # One session per repo covering all its pending PRs, oldest first —
  # amortizes checkout and session cost (grok/kimi pattern).
  local dir slug prompt prs
  for SR in "${repo_order[@]}"; do
    prs="${repo_prs[$SR]% }"
    slug="${SR//\//__}"
    log "review: $SR needs verdicts on: $prs — launching review session"
    dir="$WORK_DIR/$slug-review"
    ensure_checkout "$SR" "$dir" || continue
    prompt="$(render_prompt review.txt ME="$ME" REPO="$SR" PRS="$prs" \
      BIN="$BIN_DIR" WT_DIR="$TREES_DIR/$slug" \
      MARK_REVIEWING="$MARK_REVIEWING" \
      ONESHOT_RULES="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")")"
    RUN_SESSION_RC=1
    run_session review "$SR" "$dir" "$TIMEOUT_REVIEW" "$prompt"
    # Commit exactly the PRs named in this repo's prompt, and only when the
    # session completed. A crash or timeout must retry; a completed session
    # that declined or could not submit must settle until the PR changes.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      printf '%s\n' "${repo_items[$SR]}" | ledger_commit "$DUTY_DIR/.seen-review"
    fi
    # These PRs may now carry a verdict this session landed — evaluate each for
    # state:addressing (#130), regardless of rc: a session that submitted a
    # verdict and then timed out on later work still closed a round, and
    # addressing.jq is a no-op when it did not.
    local _rn
    for _rn in $prs; do acted_prs="$acted_prs $SR#$_rn"; done
  done

  # --- state:addressing, engine-side (#130): the reviewer that landed the last
  # verdict this tick marks the round without waiting for the scheduled
  # reconciler. Bounded to the PRs this box actually acted on — an auto-approve
  # or a review session — never a whole-board sweep. addressing.jq no-ops unless
  # the round closed without full approval and the label is not already set, so
  # a re-tick writes nothing. Roster resolved once per repo.
  local ap SRa Na
  local -A roster_cache=()
  for ap in $acted_prs; do
    [ -n "$ap" ] || continue
    SRa="${ap%#*}"; Na="${ap##*#}"
    if [ -z "${roster_cache[$SRa]:-}" ]; then
      roster_cache[$SRa]="$(panel_for_repo "$SRa" "$WORK_DIR/${SRa//\//__}-review")"
    fi
    _mark_addressing "$SRa" "$Na" "${roster_cache[$SRa]}"
  done
}
