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
#    A completed session is therefore settled only by its exact-head verdict
#    or a recognized park. Missing verdicts retry three times before the local
#    seen-ledger bounds spending; the live GitHub request remains untouched.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

REVIEW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# reclaim_detached_review_worktrees — remove throwaway worktrees left by a
# review session that ended before its own cleanup. This runs before any
# dispatch, so it never races a worktree the current tick is creating (#597).
#
# Detached HEAD is the starting ownership boundary, not sufficient proof that
# a tree is dead. A parked review deliberately outlives its launching tick, and
# Git detaches builder worktrees during operations such as rebase and bisect.
# Names remain deliberately irrelevant because a reviewer may make an
# auxiliary worktree such as base-<N> while investigating a collision.
#
# THE PR'S STATE IS NO PART OF THE PREDICATE (D1, amended by triage
# 2026-09-02). The builder's "an open PR exists on it" test does not transfer:
# a builder worktree HOLDS A BRANCH and is durable state across ticks, so an
# open PR really does mean its owner will return to it. A review worktree is a
# per-session throwaway — review.txt has one session create it with
# `git worktree add --detach` and remove it after the verdict, and nothing
# about it carries across ticks. Three mechanisms already answer "is this in
# use", and none is the PR's state: duty.sh's box-wide flock means a tree
# present at tick start belongs to a session that has ended (#597 D2);
# _review_detached_run_protects holds anything a live detached command may be
# standing in; and _review_detached_run_blocks_dispatch stops that repository
# dispatching at all while such a run is live.
#
# So on the review side an open PR does not mean "still in use" — it means
# "this PR will be reviewed again", which is precisely when the fixed path
# review-<N> has to be free. Gating on it reproduced #597's incident verbatim
# on the exact population that issue's first criterion was written for: a
# killed review's own review-<N> is by construction one whose PR is still
# open, because that is why the tick retries it. This walk therefore makes no
# `gh` call at all.
_review_detached_run_protects() {
  local candidate="$1"
  local stamp repo pr head digest remote

  REVIEW_DETACHED_RUN_SUBJECT=""
  remote="$(git -C "$candidate" remote get-url origin 2>/dev/null || true)"

  while IFS= read -r -d '' stamp; do
    repo="$(_detached_field "$stamp" repo)"
    pr="$(_detached_field "$stamp" pr)"
    head="$(_detached_field "$stamp" head)"
    digest="$(_detached_field "$stamp" digest)"
    case "$remote" in
      */"$repo"|*/"$repo".git|*:"$repo"|*:"$repo".git) : ;;
      *) continue ;;
    esac
    detached_run_read "$repo" "$pr" "$head" "$digest" >/dev/null
    if [ "$DETACHED_RUN_STATE" = running ]; then
      REVIEW_DETACHED_RUN_SUBJECT="$repo#$pr@$head"
      return 0
    fi
  done < <(find "$DUTY_DIR/.detached-runs" -type f -name '*.stamp' -print0 2>/dev/null)
  return 1
}

# A live run does not record the worktree paths selected by its model-authored
# command. Same-repository candidates must therefore remain conservative even
# when an auxiliary tree is at the base head, and every review for that
# repository must wait rather than dispatch into a path reclaim could not
# safely distinguish (#597 rounds 4-5).
_review_detached_run_blocks_dispatch() {
  local wanted_repo="$1" stamp repo pr head digest

  REVIEW_DETACHED_RUN_SUBJECT=""
  while IFS= read -r -d '' stamp; do
    repo="$(_detached_field "$stamp" repo)"
    pr="$(_detached_field "$stamp" pr)"
    head="$(_detached_field "$stamp" head)"
    digest="$(_detached_field "$stamp" digest)"
    [ "$repo" = "$wanted_repo" ] || continue
    detached_run_read "$repo" "$pr" "$head" "$digest" >/dev/null
    if [ "$DETACHED_RUN_STATE" = running ]; then
      REVIEW_DETACHED_RUN_SUBJECT="$repo#$pr@$head"
      return 0
    fi
  done < <(find "$DUTY_DIR/.detached-runs" -type f -name '*.stamp' -print0 2>/dev/null)
  return 1
}

_review_common_dir() {
  local candidate="$1" common_dir
  common_dir="$(git -C "$candidate" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_dir" in
    /*) printf '%s\n' "$common_dir" ;;
    *) (cd "$candidate/$common_dir" 2>/dev/null && pwd -P) ;;
  esac
}

_review_git_operation_in_progress() {
  local git_dir="$1"
  [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ] \
    || [ -f "$git_dir/BISECT_LOG" ] || [ -f "$git_dir/MERGE_HEAD" ] \
    || [ -f "$git_dir/CHERRY_PICK_HEAD" ] || [ -f "$git_dir/REVERT_HEAD" ]
}

_review_remote_repo() { # $1=checkout -> owner/repo
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    https://github.com/*) printf '%s\n' "${url#https://github.com/}" ;;
    git@github.com:*) printf '%s\n' "${url#git@github.com:}" ;;
    ssh://git@github.com/*) printf '%s\n' "${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
}

# A dirty detached worktree is never deleted, and preserving it must never cost
# the path (D3, amended by triage 2026-09-02). Leaving it in place preserves the
# work and keeps #597's collision: the retry meets the tree at the very path the
# prompt tells it to create. Move it to a sibling instead, so the fixed
# review-<N> path is free and the work survives byte-identical.
#
# The fail-safe direction is always DO NOT DELETE, never delete to free the
# path: any move failure leaves the tree exactly where it was and says so. A
# tree already named kept-* is preserved where it stands and is never moved
# twice; once its dirt is gone the ordinary rule above reclaims it, which is
# what keeps this bounded rather than a second accumulation.
_review_preserve_dirty_worktree() { # $1=candidate $2=common dir $3=head $4=dirt
  local candidate="$1" common_dir="$2" head="$3" dirt_summary="$4"
  local base parent stem target n

  base="${candidate##*/}"
  parent="${candidate%/*}"
  if [[ "$base" == kept-* ]]; then
    warn "review: dirty detached worktree $candidate is preserved where it stands ($dirt_summary)"
    return 0
  fi

  stem="$parent/kept-$base-${head:0:7}"
  target="$stem"
  n=2
  # Occupied means the NAME is taken, not that it resolves: -e follows the link
  # and so reads a dangling symlink as free, which would pick a destination the
  # move then fails on — and a failed move leaves the dirty tree on the fixed
  # review-<N> path, reproducing #597 through the one input the suffix loop
  # exists to survive. -L answers about the entry itself.
  while [ -e "$target" ] || [ -L "$target" ]; do
    target="$stem-$n"
    n=$((n + 1))
  done

  if git --git-dir="$common_dir" worktree move "$candidate" "$target" >/dev/null 2>&1; then
    warn "review: dirty detached worktree $candidate preserved as $target ($dirt_summary)"
  else
    warn "review: dirty detached worktree $candidate could not be preserved as $target; left exactly where it is ($dirt_summary)"
  fi
  return 0
}

review_cleanup_stale_build_outputs() {
  local clone candidate rel repo
  for clone in "$WORK_DIR"/*-review; do
    [ -d "$clone/.git" ] || continue
    repo="$(_review_remote_repo "$clone")" || {
      warn "review: cannot resolve repository for $clone; leaving its build output"
      continue
    }
    if _review_detached_run_blocks_dispatch "$repo"; then
      log "review: preserved build output in $clone; protected by active detached run $REVIEW_DETACHED_RUN_SUBJECT"
      continue
    fi
    while IFS= read -r -d '' candidate; do
      rel="${candidate#"$clone"/}"
      # -X is the safety boundary: only ignored, reproducible material goes.
      # Tracked files under a commonly generated directory (for example a
      # checked-in dist metadata) and ordinary untracked evidence both stay.
      git -C "$clone" clean -fdX -- "$rel" >/dev/null 2>&1 || {
        warn "review: could not clear ignored build output $candidate"
        continue
      }
      [ -e "$candidate" ] || log "review: cleared ignored build output $candidate"
    done < <(find "$clone" -type d \
      \( -name node_modules -o -name dist -o -name .next -o -name test-results \) \
      -print0 -prune 2>/dev/null)
  done
  return 0
}

reclaim_detached_review_worktrees() {
  local candidate top head git_dir common_dir dirt dirt_summary

  while IFS= read -r -d '' candidate; do
    candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" || continue
    top="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)"
    [ "$top" = "$candidate" ] || continue
    if git -C "$candidate" symbolic-ref -q HEAD >/dev/null 2>&1; then
      continue
    fi

    head="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
    git_dir="$(git -C "$candidate" rev-parse --absolute-git-dir 2>/dev/null || true)"
    common_dir="$(_review_common_dir "$candidate" || true)"
    if [ -z "$head" ] || [ -z "$git_dir" ] || [ -z "$common_dir" ]; then
      continue
    fi
    _review_git_operation_in_progress "$git_dir" && continue
    # The run stamp's head is engine-owned identity. The supervisor cwd is
    # not: reviewer sessions launch in the main clone and may pass a worktree
    # path to the detached command. Protect candidates at a verified live
    # repository, including auxiliary base-head worktrees. Other repositories
    # remain reclaimable.
    if _review_detached_run_protects "$candidate"; then
      log "review: preserved detached worktree $candidate; protected by active detached run $REVIEW_DETACHED_RUN_SUBJECT"
      continue
    fi
    if ! dirt="$(git -C "$candidate" status --porcelain --untracked-files=all 2>/dev/null)"; then
      continue
    fi
    dirt_summary="$(printf '%s\n' "$dirt" | awk '
      /^\?\?/ { u++; next }
      NF      { m++ }
      END     { printf "%d modified, %d untracked", m+0, u+0 }')"
    if [ -n "$dirt" ]; then
      _review_preserve_dirty_worktree "$candidate" "$common_dir" "$head" "$dirt_summary"
      continue
    fi
    if git --git-dir="$common_dir" worktree remove --force "$candidate" >/dev/null 2>&1; then
      log "review: reclaimed detached worktree $candidate at $head ($dirt_summary)"
    else
      warn "review: could not reclaim detached worktree $candidate at $head"
    fi
  done < <(find -H "$TREES_DIR" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
  review_cleanup_stale_build_outputs
  return 0
}

# Mutation probes are disposable copies, not worktrees and not review records.
# A reviewer may leave one behind when a later step fails, so the engine owns
# the cleanup boundary: once that repository has no live detached review run,
# every mutation-* sibling it could have created is dead scratch (#606).
# Restrict the walk to direct children of the rendered review-worktree parent;
# never follow a symlink and never widen an unresolved path into rm's target set.
review_cleanup_mutation_copies() { # $1=review-worktree parent $2=repo
  local parent="$1" repo="$2" candidate
  [ -d "$parent" ] || return 0
  if _review_detached_run_blocks_dispatch "$repo"; then
    log "review: preserved mutation copies in $parent; protected by active detached run $REVIEW_DETACHED_RUN_SUBJECT"
    return 0
  fi
  while IFS= read -r -d '' candidate; do
    case "$candidate" in
      "$parent"/mutation-*) : ;;
      *) continue ;;
    esac
    if rm -rf -- "$candidate"; then
      log "review: removed mutation copy $candidate"
    else
      warn "review: could not remove mutation copy $candidate"
    fi
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -name 'mutation-*' -print0 2>/dev/null)
  return 0
}

# Repos where I author an open PR — read off the sweep's own pulls pages at
# zero extra API cost (claude-bot's cast#143 fix). Consumed by duty-builder.
REVIEW_MY_PR_REPOS=""

# rereq_decision <mine_oid> <head> <mine_state> <mine_at> <req_at> [auto_on] [park_state]
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
#   parked       — detached verification is still running for this PR/head.
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
  local park_state="${7:-none}"
  case "$park_state" in
    parked) echo parked; return 0 ;;
    ready|expired) echo queue; return 0 ;;
  esac
  if [ "$mine_oid" != "$head" ]; then echo queue; return 0; fi
  if [ "$req_at" != "-" ] && [ "$mine_at" != "-" ] && [[ "$req_at" > "$mine_at" ]]; then
    if [ "$mine_state" = "APPROVED" ] && [ "$auto" = "1" ]; then echo auto-approve; else echo queue; fi
  else
    echo skip
  fi
}

# _review_verdict_at_head REPO NUM HEAD — positive postcondition for a
# completed review session. The captured candidate head is deliberate: a
# verdict on a head that moved during the session belongs to the next round.
# DISMISSED stays in the query so last:1 sees the latest opinionated review;
# the positive state check below rejects it instead of exposing an older verdict.
# REVIEW_VERDICT_POSTCONDITION distinguishes an ordinary miss from an
# unreadable lookup without weakening either one into a verdict.
_review_verdict_at_head() {
  local repo="$1" num="$2" head="$3" owner name payload row oid state extra
  owner="${repo%%/*}"; name="${repo##*/}"
  REVIEW_VERDICT_POSTCONDITION=lookup-error
  if ! payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!,$me:String!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      reviews(author:$me,last:1,states:[APPROVED,CHANGES_REQUESTED,DISMISSED]){nodes{commit{oid} submittedAt state}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" -f me="$ME" 2>/dev/null)"; then
    return 1
  fi
  if ! printf '%s' "$payload" | jq -e '
      ((.errors // []) | length == 0) and
      (.data.repository.pullRequest | type == "object") and
      (.data.repository.pullRequest.reviews.nodes | type == "array")' >/dev/null 2>&1; then
    return 1
  fi
  row="$(printf '%s' "$payload" | jq -r '
    .data.repository.pullRequest.reviews.nodes[0] // {}
    | "\(.commit.oid // "-") \(.state // "-")"' 2>/dev/null)" || return 1
  read -r oid state extra <<<"$row"
  if [ -n "${extra:-}" ] || [ -z "${oid:-}" ] || [ -z "${state:-}" ]; then
    return 1
  fi
  REVIEW_VERDICT_POSTCONDITION=none
  if [ "$oid" = "$head" ]; then
    case "$state" in
      APPROVED|CHANGES_REQUESTED)
        REVIEW_VERDICT_POSTCONDITION="$state"
        return 0
        ;;
    esac
  fi
  return 1
}

# The retry budget is local spending state, not GitHub state. One entry per
# PR/head keeps a moved head fresh; clearing by PR removes every stale-head
# remainder when a durable verdict or park settles the request.
_review_owed_clear() { # $1=repo $2=num
  local repo="$1" num="$2" ledger="$DUTY_DIR/.review-owed" tmp prefix
  prefix="$repo#$num@"
  [ -e "$ledger" ] || return 0
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! awk -v p="$prefix" 'index($1,p) != 1 { print }' "$ledger" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    return 1
  fi
}

# A complete authoritative pulls sweep proves which review requests remain
# live. Drop retry state for every request absent from that set; under a
# partial sweep absence proves nothing, so the caller never invokes this.
_review_owed_prune_inactive() { # $1="REPO#PR ..."
  local active=" $1 " ledger="$DUTY_DIR/.review-owed" tmp input
  [ -e "$ledger" ] || return 0
  input="$ledger"
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! awk -v active="$active" '
    NF >= 2 {
      subject=$1
      sub(/@[^@]*$/, "", subject)
      if (index(active, " " subject " ")) print
    }
  ' "$input" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    return 1
  fi
}

_review_owed_attempt() { # $1=repo $2=num $3=head; prints new attempt count
  local repo="$1" num="$2" head="$3" ledger="$DUTY_DIR/.review-owed" tmp prefix key input count
  prefix="$repo#$num@"; key="$prefix$head"
  input="$ledger"; [ -e "$input" ] || input=/dev/null
  if ! count="$(awk -v k="$key" '$1 == k { print $2+0; found=1; exit } END { if (!found) print 0 }' "$input")"; then
    return 1
  fi
  count=$((count + 1))
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! awk -v p="$prefix" '
    index($1,p) == 1 { next }
    NF >= 2 { print }
  ' "$input" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! printf '%s %s\n' "$key" "$count" >>"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$ledger"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$count"
}

_review_owed_exhausted() { [ "$1" -ge 3 ]; }

# _review_check_evidence_from_payload REPO NUM SNAPSHOT CURRENT_HEAD — render
# the check evidence handed to a reviewer. SNAPSHOT is one `gh pr view` object:
# its headRefOid and statusCheckRollup are one atomic view, so every conclusion
# is pinned to the SHA it describes. CURRENT_HEAD is fetched afterwards; a push
# between the two reads therefore weakens the evidence visibly instead of
# silently presenting an older run as current (#532).
#
# The aggregate grade comes from head-checks.jq, the same reader that gates the
# builder path. The prose listing only exposes GitHub's own names and
# conclusions; it does not make a second green/red judgement.
_review_check_evidence_from_payload() {
  local repo="$1" num="$2" snapshot="$3" current_head="$4"
  local row checked_head state entries relation
  row="$(printf '%s' "$snapshot" | jq -c '[.]' 2>/dev/null \
    | jq -r --argjson panel '[]' --arg repo "$repo" --arg human '' \
        -f "$REVIEW_LIB_DIR/jq/head-checks.jq" 2>/dev/null)" || row="" # Decision-path empty fallback: the next branch names unavailable evidence and asks the reviewer to verify independently.
  if [ -z "$row" ]; then
    printf -- '- %s#%s: check evidence unavailable; verify it independently.\n' "$repo" "$num"
    return 0
  fi

  checked_head="$(cut -f3 <<<"$row")"
  state="$(cut -f4 <<<"$row")"
  entries="$(printf '%s' "$snapshot" | jq -r '
    [(.statusCheckRollup // [])
      | group_by([
          (.name // .context // "?"),
          (.__typename // ""),
          (.workflowName // "")
        ])[]
      | max_by([
          (.startedAt // .createdAt // ""),
          (.completedAt // "")
        ])
      | "\(.name // .context // "?")=\(.conclusion // .state // .status // "?")"]
    | join(", ")' 2>/dev/null)" || entries="" # Decision-path empty fallback: the rendered row says the rollup is unreadable and grants no conclusion.
  if [ "$current_head" = unknown ]; then
    relation="current head unavailable"
  elif [ "$checked_head" = "$current_head" ]; then
    relation="this head"
  else
    relation="older SHA; current head $current_head"
  fi

  if [ "$state" = none ] && [ "$checked_head" = "$current_head" ]; then
    printf -- '- %s#%s: none at this head %s.\n' "$repo" "$num" "$checked_head"
  elif [ "$state" = none ]; then
    printf -- '- %s#%s: none at checked head %s (%s).\n' \
      "$repo" "$num" "$checked_head" "$relation"
  else
    printf -- '- %s#%s: checks at %s (%s; aggregate %s): %s.\n' \
      "$repo" "$num" "$checked_head" "$relation" "$state" "${entries:-unreadable rollup}"
  fi
  return 0
}

_review_check_evidence() {
  local repo="$1" num="$2" snapshot current_head
  if ! snapshot="$(gh pr view "$num" -R "$repo" \
    --json number,isDraft,reviewRequests,updatedAt,headRefOid,statusCheckRollup 2>/dev/null)"; then
    printf -- '- %s#%s: check evidence unavailable; verify it independently.\n' "$repo" "$num"
    return 0
  fi
  current_head="$(gh api "repos/$repo/pulls/$num" --jq .head.sha 2>/dev/null || echo unknown)"
  _review_check_evidence_from_payload "$repo" "$num" "$snapshot" "$current_head"
}

_review_check_evidence_list() {
  local repo="$1" prs="$2" evidence_n
  for evidence_n in $prs; do
    _review_check_evidence "$repo" "$evidence_n"
  done
}

# _mark_addressing REPO NUM — after MY verdict lands, evaluate the
# round and, if it closed WITHOUT full approval, set state:addressing (#130).
#
# The reviewer that lands the last verdict does this, not the author's next
# builder tick: it is already here, it already computed the round to decide its
# own action, and it does the right thing even when the author's box is the one
# that is down — the case the board most needs to survive. addressing.jq is the
# deliberate mirror of converged.jq. The PR AUTHOR from the payload selects an
# optional author-specific panel, then is subtracted from that panel as the
# final safety net.
#
# Best-effort and gating NOTHING: this runs AFTER the verdict has already
# landed, so a failed label write costs a stale board the reconciler corrects
# on its next sweep, never a lost or blocked verdict. The engine write is
# optimistic; the reconciler stays authoritative.
_mark_addressing() {
  local repo="$1" num="$2" owner name payload author roster_json eff_panel verdict head sized_panel
  owner="${repo%%/*}"; name="${repo##*/}"
  if ! payload="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      headRefOid
      author{login}
      labels(first:50){nodes{name}}
      reviewRequests(first:50){nodes{requestedReviewer{... on User{login}}}}
      latestOpinionatedReviews(first:50){nodes{author{login} state commit{oid}}}
    } } }' -f owner="$owner" -f name="$name" -F num="$num" 2>/dev/null)"; then
    warn "review: $repo#$num addressing eval fetch failed; skipping (best-effort)"
    return 0
  fi
  if ! printf '%s' "$payload" | jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1; then
    warn "review: $repo#$num addressing eval payload unusable; skipping (best-effort)"
    return 0
  fi
  author="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.author.login // ""' 2>/dev/null)"
  roster_json="$(panel_for_repo "$repo" "$WORK_DIR/${repo//\//__}-review" "$author")"
  eff_panel="$(printf '%s' "$roster_json" | jq -c --arg a "$author" '. - [$a]' 2>/dev/null || echo '[]')"
  # The panel for THIS head is the risk-sized subset (#761): the round closed
  # when the reviewers the head was asked of have all spoken, and a low-risk
  # head asked of one reviewer is marked on that one verdict. _panel_effective
  # is duty-builder.sh's and duty.sh sources that module ahead of every duty;
  # a harness that loads this file alone reads the whole roster.
  head="$(printf '%s' "$payload" | jq -r '.data.repository.pullRequest.headRefOid // ""' 2>/dev/null)"
  sized_panel="$eff_panel"
  if declare -F _panel_effective >/dev/null 2>&1; then
    _panel_effective "$repo" "$num" "$head" "$eff_panel"
    sized_panel="$_PANEL_EFFECTIVE_JSON"
  fi
  verdict="$(printf '%s' "$payload" \
    | jq -r --argjson panel "$sized_panel" --argjson roster "$eff_panel" --arg addressing "$LABEL_ADDRESSING" \
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
  local -A candidate_heads=() park_states=() park_results=() park_reasons=() park_digests=()
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
  local outside cand repo_list unscoped=""
  outside="$(gh search prs --review-requested="$ME" --state open --limit 50 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    repo_list="$(read_repo_list "$REPOS_FILE")"
    if ! grep -qxF "${cand%%#*}" <<<"$repo_list"; then
      unscoped="$unscoped $cand"
    fi
  done <<<"$outside"
  if [ -n "$unscoped" ]; then
    warn "review: request(s) outside repos.txt, NOT acted on:$unscoped — add the repo to repos.txt if this box should carry it"
  fi

  # A complete authoritative sweep also owns the ending of a park whose
  # request disappeared. Under a partial sweep absence proves nothing, so the
  # process and record are preserved until a complete read can judge them.
  if [ "$sweep_complete" -eq 1 ]; then
    local active_requests
    active_requests="$(printf '%s\n' "$candidates" \
      | awk 'NF == 4 && !seen[$3 "#" $4]++ { out=out (out ? " " : "") $3 "#" $4 } END { print out }')"
    review_park_prune_inactive "$active_requests"
    _review_owed_prune_inactive "$active_requests" \
      || warn "review: could not prune missing-verdict attempts for ended requests"
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
    if ! fields="$(RV_ME="$ME" gh api graphql \
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
      2>/dev/null)"; then
      warn "review: $SR#$N state fetch failed; skipping this tick"
      sweep_complete=0
      continue
    fi
    # DISMISSED is now in the states filter and $mine_state carries the verdict:
    # a re-request over my STANDING verdict must branch on whether that verdict
    # is an APPROVED (auto-approvable) or a live block (a real re-review is owed).
    read -r head mine_oid mine_at mine_state req_at <<<"$fields"
    candidate_heads["$SR#$N"]="$head"
    review_park_inspect "$SR" "$N" "$head"
    park_states["$SR#$N"]="$REVIEW_PARK_STATE"
    park_results["$SR#$N"]="$REVIEW_PARK_RESULTS"
    park_reasons["$SR#$N"]="$REVIEW_PARK_REASON"
    park_digests["$SR#$N"]="$REVIEW_PARK_DIGESTS"

    decision="$(rereq_decision "$mine_oid" "$head" "$mine_state" "$mine_at" "$req_at" "${AUTO_APPROVE_REREQUEST:-1}" "$REVIEW_PARK_STATE")"
    case "$decision" in
      auto-approve)
        # My standing APPROVED covers this head and a newer re-request arrived
        # (ceremony#94). Head re-verified live immediately before submitting;
        # the submit goes through the one-shot gate like any verdict. This path
        # never enters the queue-side ledger.
        _review_owed_clear "$SR" "$N" \
          || warn "review: $SR#$N could not clear settled missing-verdict attempts"
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
      parked)
        _review_owed_clear "$SR" "$N" \
          || warn "review: $SR#$N could not clear parked missing-verdict attempts"
        log "review: $SR#$N parked at head ${head:0:12} (${REVIEW_PARK_REASON:-detached verification still running}) — dispatch suppressed"
        ;;
      skip)
        _review_owed_clear "$SR" "$N" \
          || warn "review: $SR#$N could not clear settled missing-verdict attempts"
        log "review: $SR#$N my latest review already covers head ${head:0:12}; skipping (request mid-clear or stale search)"
        ;;
    esac

    if [ "$queue" -eq 1 ] && _review_detached_run_blocks_dispatch "$SR"; then
      log "review: $SR#$N dispatch suppressed at ${head:0:12}; active detached run $REVIEW_DETACHED_RUN_SUBJECT makes same-repository worktree ownership ambiguous"
      queue=0
    fi

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
  local dir slug prompt prs check_evidence expected_heads park_evidence ready_prs
  local commit_items captured_prs key_pr updated attempt
  for SR in "${repo_order[@]}"; do
    prs="${repo_prs[$SR]% }"
    slug="${SR//\//__}"
    log "review: $SR needs verdicts on: $prs — launching review session"
    dir="$WORK_DIR/$slug-review"
    ensure_checkout "$SR" "$dir" || continue
    check_evidence="$(_review_check_evidence_list "$SR" "$prs")"
    expected_heads=""; park_evidence=""; ready_prs=""
    for N in $prs; do
      expected_heads="$expected_heads $N=${candidate_heads["$SR#$N"]}"
      if [ "${park_states["$SR#$N"]:-none}" = ready ]; then
        ready_prs="$ready_prs $N"
        park_evidence="${park_evidence}${park_evidence:+$'\n'}$SR#$N at ${candidate_heads["$SR#$N"]}: ${park_reasons["$SR#$N"]}"$'\n'"${park_results["$SR#$N"]}"
      fi
    done
    expected_heads="${expected_heads# }"; ready_prs="${ready_prs# }"
    local wait_rules
    wait_rules="$(render_prompt fragment-wait-rules-review.txt BIN="$BIN_DIR" REPO="$SR")"
    prompt="$(render_prompt review.txt ME="$ME" REPO="$SR" PRS="$prs" \
      BIN="$BIN_DIR" DUTY="$DUTY_DIR" REVIEW_WT_PARENT="$TREES_DIR/$slug" \
      MARK_REVIEWING="$MARK_REVIEWING" \
      HEAD_CHECKS="$check_evidence" \
      PARK_RESULTS="${park_evidence:--}" \
      WAIT_RULES="$wait_rules" \
      ONESHOT_RULES="$(render_prompt fragment-oneshot-rules.txt BIN="$BIN_DIR")")"
    RUN_SESSION_RC=1
    RUN_SESSION_LOG=""
    SESSION_TASK="$(printf '%s' "$prs" | tr -s ' ' ',')" \
    run_session review "$SR" "$dir" "$TIMEOUT_REVIEW" "$prompt"
    review_cleanup_mutation_copies "$TREES_DIR/$slug" "$SR"
    # Commit exactly the PRs named in this repo's prompt, and only when the
    # session completed. A crash or timeout retries without spending the
    # bounded budget. A completed session settles only on an exact-head verdict
    # or a park it captured; otherwise its third missing-verdict attempt bounds
    # local spending while the live GitHub request remains untouched.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
      review_park_capture "${RUN_SESSION_LOG:-}" "$SR" "$expected_heads"
      if [ "$REVIEW_PARK_CAPTURE_INVALID" -eq 1 ]; then
        warn "review: $SR completed with an invalid PARKED declaration — withholding its seen-ledger commit so the request retries"
      else
        captured_prs=" $REVIEW_PARK_CAPTURED "
        commit_items=""
        while read -r key updated; do
          [ -n "${updated:-}" ] || continue
          key_pr="${key##*#}"
          if [[ "$captured_prs" == *" $key_pr "* ]]; then
            _review_owed_clear "$SR" "$key_pr" \
              || warn "review: $SR#$key_pr could not clear parked missing-verdict attempts"
          elif _review_verdict_at_head "$SR" "$key_pr" "${candidate_heads["$SR#$key_pr"]}"; then
            commit_items="$commit_items
$key $updated"
            _review_owed_clear "$SR" "$key_pr" \
              || warn "review: $SR#$key_pr could not clear settled missing-verdict attempts"
          else
            # A lookup failure is still one completed reviewer attempt without
            # a durable verdict, so it warns and spends the same bounded budget.
            if [ "$REVIEW_VERDICT_POSTCONDITION" = lookup-error ]; then
              warn "review: $SR#$key_pr post-session verdict lookup failed; request remains owed"
            fi
            if ! attempt="$(_review_owed_attempt "$SR" "$key_pr" "${candidate_heads["$SR#$key_pr"]}")"; then
              warn "review: $SR#$key_pr could not update its missing-verdict attempt counter; request remains owed"
              continue
            fi
            if _review_owed_exhausted "$attempt"; then
              warn "review: $SR#$key_pr at ${candidate_heads["$SR#$key_pr"]} still has no exact-head verdict after $attempt attempts — settling local spend; GitHub request remains live"
              commit_items="$commit_items
$key $updated"
              _review_owed_clear "$SR" "$key_pr" \
                || warn "review: $SR#$key_pr could not clear exhausted missing-verdict attempts"
            fi
          fi
        done <<<"${repo_items[$SR]}"
        printf '%s\n' "$commit_items" | ledger_commit "$DUTY_DIR/.seen-review"
        # A ready park is consumed only by a completed follow-up session. If
        # that session declared another park for the same PR, capture replaced
        # the record and it remains the next tick's source of truth.
        for N in $ready_prs; do
          _review_park_cleanup_runs "$SR" "$N" "${candidate_heads["$SR#$N"]}" \
            "${park_digests["$SR#$N"]}"
          if [[ "$captured_prs" != *" $N "* ]]; then
            review_park_clear "$SR" "$N" "${candidate_heads["$SR#$N"]}"
          fi
        done
      fi
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
  # a re-tick writes nothing. _mark_addressing resolves the effective roster
  # from the author already present in its GraphQL payload.
  local ap SRa Na
  for ap in $acted_prs; do
    [ -n "$ap" ] || continue
    SRa="${ap%#*}"; Na="${ap##*#}"
    _mark_addressing "$SRa" "$Na"
  done
}
