# head-checks.jq — one row per open non-draft PR I authored, joining the two
# author-side facts that share a listing: the state of the check AT THE HEAD,
# and whether a fix round is owed.
#
# THE THIRD ROUND PREDICATE. `round_owed` below is the sibling of
# `converged.jq` and `addressing.jq`, and the three are kept deliberate mirrors
# (#130, #147): converged asks "did every panelist approve THIS head?",
# addressing asks "did every panelist review THIS head and at least one NOT
# approve?", round_owed asks "does a panelist's verdict AT THIS HEAD request
# changes, with nobody still owing one?". Same field, same head-scoping, same
# empty-datum handling — a reader who finds one of the three has found all
# three. #130 reconciled the first two and left this one out; #147 is the bill
# for that, and the reconciliation note is on `round_owed` itself.
#
# Input: the `gh pr list --json number,isDraft,updatedAt,headRefOid,
# statusCheckRollup` array, each element carrying an injected `.reviewState` —
# the bare GraphQL `pullRequest` object (headRefOid, reviewRequests,
# latestOpinionatedReviews) that converged.jq and addressing.jq read, fetched
# per PR by duty-builder.sh. Absent (the fetch failed) means no round is
# claimed for that PR this tick; the caller says so out loud.
# Args: $panel (JSON array of logins, author already subtracted), $repo.
#
# Output, one TAB-delimited row per PR:
#
#   <repo>#<num> \t <updatedAt> \t <headRefOid> \t green|red|pending|none \t owed|- \t <failing checks>
#
# Tabs, not spaces: a check is named "release-exercise / fixture-chain" and the
# last field carries those names, so a space-delimited table would need them
# mangled to stay parseable. The names are here rather than in a second jq
# program because a second program means a second copy of the failure
# predicate below, and two copies of a predicate are two predicates.
#
# THE ROLLUP MIXES TWO SHAPES. A check is either a CheckRun (carries
# .conclusion, and .status while it is still running) or a StatusContext
# (carries .state). Discriminating on .__typename and reading only .conclusion
# is the bug this file exists in order to not have: crew's own CI is a single
# CheckRun, so that version passes every test in this repo and reads a FAILING
# StatusContext as green on any repo that uses one — green for a reason
# unrelated to what it claims, which is #50's shape. The two key sets are
# disjoint, so no discriminator is needed: ask both questions of every node.

# GREEN IS A WHITELIST, AND EVERYTHING UNRECOGNISED IS RED (codex, #64).
#
# The first version enumerated the failing conclusions and let the rest fall
# through to green, on the rationale that a CANCELLED run is usually one
# superseded by a newer push. That rationale is wrong: `statusCheckRollup` is
# ALREADY scoped to the current head, so a run superseded by a push is not in
# this list at all. What is in it is a manual cancellation, or a same-head
# concurrency cancellation — a head that is not passing, read as green.
#
# The cost was both halves of this feature at once: the build path could open a
# panel round on a non-green head (#45's gate defeated) and the ci-red wake
# would never investigate it (#17's wake blinded). CANCELLED and STALE were the
# instances codex found; fail-closed is what stops the NEXT conclusion GitHub
# adds from doing the same thing silently.
#
# Both fields are bound BEFORE the lookup: `["A"] | index(.conclusion)` rebinds
# `.` to the array literal and then indexes an array with a string, which is a
# jq error, not a false.
def is_green:
  (.conclusion // "") as $c | (.state // "") as $s
  | ((["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) != null)
    or ($s == "SUCCESS");

# Pending is not red. Gating a fix round on a check that has not finished would
# stall every round behind a queued runner (#45 is about a FAILED check, which
# is the author's own signal — a running one is nobody's yet).
def is_pending:
  (.status // "") as $st | (.state // "") as $s
  | ((["QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"] | index($st)) != null)
    or ((["PENDING", "EXPECTED"] | index($s)) != null);

# Neither passing nor still running: the head is not green, whatever the reason.
def is_blocking: (is_green or is_pending) | not;

# "none" is its own state, never green: a repo with no CI configured and a
# repo whose checks all passed are different facts, and only one of them is
# evidence.
def check_state:
  (.statusCheckRollup // []) as $c
  | if   ($c | length) == 0             then "none"
    elif ($c | map(is_blocking) | any)  then "red"
    elif ($c | map(is_pending) | any)   then "pending"
    else "green" end;

# A round is owed when a panelist's latest opinionated verdict AT THE CURRENT
# HEAD requests changes and no panel review request is still outstanding —
# rounds are answered whole (BUILDER.md). Computed from
# latestOpinionatedReviews, never reviewDecision, which is empty without branch
# protection (ceremony#26/#39).
#
# IT READ `latestReviews` AND NO HEAD AT ALL UNTIL #147, and that cost two
# defects the other two predicates never had:
#
#   1. A CHANGES_REQUESTED at a SUPERSEDED head still marked a round owed. An
#      opinion is of a specific tree; a verdict on a head the builder has
#      already pushed past has not reviewed the tree it is being woken about.
#   2. `latestReviews` is the latest review of ANY state, so a reviewer who
#      requested changes and then left a plain COMMENTED review had the change
#      request replaced in that field — the round went un-owed, nobody was
#      woken, and no label was wrong. That is the #114 auto-approve-over-a-
#      standing-blocker family, on the builder side.
#
# THE TRAP THIS DOES NOT FALL INTO: `gh pr list --json latestReviews` carries
# `.commit.oid` in its schema and returns it EMPTY (verified on
# heavy-duty/ceremony#207). Head-filtering THAT listing compares every verdict
# against "" , matches nothing, and marks every round un-owed — an occasional
# mask converted into a total silent stall of the builder fix-round path. The
# head-carrying verdicts must come from GraphQL, so they do: `.reviewState` is
# the same object converged.jq and addressing.jq are handed, and `latestReviews`
# is no longer fetched at all. The must-fail fixture for this lives in
# shared/test/run.sh and asserts a round is STILL owed beside an `"oid": ""`.
#
# NO reviewState, OR ONE DESCRIBING A DIFFERENT HEAD, IS NOT A ROUND. The
# listing and the per-PR read are two calls, so a push landing between them
# leaves verdicts scoped to a head this row does not describe. Deferring costs
# one tick and self-heals; claiming a round on it would open a panel round on a
# head nobody has seen settle, which is the mismatch #133 already defers on.
def round_owed:
  (.reviewState // null) as $rs
  | if $rs == null
       or (($rs.headRefOid // "") == "")
       or ($rs.headRefOid != .headRefOid) then false
    else
      (($rs.reviewRequests.nodes // [] | map(.requestedReviewer.login // empty)
        | map(select(. as $l | ($panel | index($l)) != null)) | length) == 0)
      and (($rs.latestOpinionatedReviews.nodes // []
            | map(select(.state == "CHANGES_REQUESTED"
                         and .commit.oid == $rs.headRefOid) | .author.login)
            | map(select(. as $l | ($panel | index($l)) != null)) | length) > 0)
    end;

def failing_names:
  [(.statusCheckRollup // [])[] | select(is_blocking)
   | "\(.name // .context // "?") (\(.conclusion // .state // "?"))"]
  | if length == 0 then "-" else join(", ") end;

.[]
| select(.isDraft | not)
| "\($repo)#\(.number)\t\(.updatedAt)\t\(.headRefOid)\t\(check_state)\t\(if round_owed then "owed" else "-" end)\t\(failing_names)"
