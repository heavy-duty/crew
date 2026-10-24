# head-checks.jq — one row per open non-draft PR I authored, joining the two
# author-side facts that share a listing: the state of the check AT THE HEAD,
# and whether a fix round is owed.
#
# Its round-close predicate is the third sibling of converged.jq and
# addressing.jq. All three consume latestOpinionatedReviews and scope verdicts
# to the current head; keep their fixtures paired so those rules cannot drift.
#
# Input: the `gh pr list --json number,isDraft,reviewRequests,updatedAt,
# headRefOid,statusCheckRollup` array, augmented by the caller with
# latestOpinionatedReviews from its per-PR GraphQL payload.
# Args: $panel (JSON array of logins, author already subtracted), $repo,
# $human (the maintainer's login — FLEET_HUMAN; "" from a caller that reads
# only the check column).
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
# superseded by a newer push. `statusCheckRollup` is scoped to the current
# head, but it can retain several same-head generations of one check name.
# The latest generation is the evidence; a CANCELLED latest generation is a
# head that is not passing and must not be read as green.
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
#
# A CONCLUDED CHECK IS NOT PENDING, WHATEVER ITS STATUS SAYS (#634). GitHub can
# leave a finished CheckRun carrying `status: IN_PROGRESS` beside a set
# `conclusion`; the run never revises itself, so a status-only reading graded
# that head pending for as long as it existed, and the engine held the panel
# request at a head it would never regrade (ceremony#593: 10h17m unrequested on
# a green PR). The conclusion is the verdict and the status only says whether
# one has been reached, so a set conclusion wins over a running status. The
# guard is on the conclusion's presence, not on `is_green`, so a running status
# beside a non-green conclusion falls through to `is_blocking` — pending never
# masks red. `check_state`'s order (red, then pending, then green) is NOT the
# place for this: testing green first would also grade a head green while a
# second check was genuinely still running, which is #45's gate defeated. A
# running run reaches here as `conclusion: null` or, from `gh`, as `""`; both
# read as not yet concluded.
def is_pending:
  (.conclusion // "") as $c | (.status // "") as $st | (.state // "") as $s
  | ($c == "")
    and (((["QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"] | index($st)) != null)
      or ((["PENDING", "EXPECTED"] | index($s)) != null));

# Neither passing nor still running: the head is not green, whatever the reason.
def is_blocking: (is_green or is_pending) | not;

# A workflow can start several runs with the same check name at one head.
# GitHub keeps every run in statusCheckRollup, including concurrency-cancelled
# runs superseded by a later run. Only that later run is evidence about the
# check. Evidence providers stay separate even when a StatusContext context
# equals a CheckRun name, and same-named jobs in different workflows remain
# independent. startedAt (or a status's createdAt) identifies the generation;
# completedAt breaks same-second CheckRun ties. A still-running tied rerun
# therefore loses to completed evidence, which is the fail-closed direction.
def latest_checks:
  (.statusCheckRollup // [])
  | group_by([
      (.name // .context // "?"),
      (.__typename // ""),
      (.workflowName // "")
    ])
  | map(max_by([
      (.startedAt // .createdAt // ""),
      (.completedAt // "")
    ]));

# "none" is its own state, never green: a repo with no CI configured and a
# repo whose checks all passed are different facts, and only one of them is
# evidence.
def check_state:
  latest_checks as $c
  | if   ($c | length) == 0             then "none"
    elif ($c | map(is_blocking) | any)  then "red"
    elif ($c | map(is_pending) | any)   then "pending"
    else "green" end;

# A round is owed when a panelist's latest OPINIONATED review AT THIS HEAD
# requests changes and no panel review request is still outstanding — rounds
# are answered whole (BUILDER.md). Computed from latestOpinionatedReviews,
# never latestReviews (COMMENTED can mask a standing blocker) and never
# reviewDecision (empty without branch protection; ceremony#26/#39).
#
# THE HUMAN IS THE SECOND CLAUSE (#452). BUILDER.md's Handoff ends "address
# what comes back and re-hand-off the same way", and until this clause existed
# nothing woke the builder to do it: the panel clause requires the
# change-requester to be in $panel, and the maintainer is off-panel by
# construction, so a human CHANGES_REQUESTED reached no wake in the engine at
# all — not ci-red (a failing check only), not rebase (CONFLICTING only), not
# resume (every path wants the latest signal NOT to name the head, and after a
# completed handoff it does).
#
# The "not currently requested" guard is the exact mirror of the panel clause's
# "no panel review request is still outstanding", and it is what SPENDS the
# wake: the handoff re-requests the human, and the clause goes false. A
# declined session is handled by the existing .seen-build ledger keyed on
# updatedAt, the same way it already handles a declined panel round.
#
# $human ALONE, never "not in $panel" (D3), and head-scoped like every verdict
# here: an advisory off-panel reviewer stays advisory (BUILDER.md) and triage
# does not vote on PRs, so keying on panel membership would wake the builder
# for every off-panel opinion on the board. An empty $human matches nobody.
def round_owed:
  .headRefOid as $head
  | (([.latestOpinionatedReviews[]?
      | select(.state == "CHANGES_REQUESTED" and .commit.oid == $head)
      | .author.login | select(. as $l | ($panel | index($l)) != null)] | length > 0)
     and (([.reviewRequests[]? | .login // empty
            | select(. as $l | ($panel | index($l)) != null)] | length) == 0))
  or (($human // "") != ""
      and ([.latestOpinionatedReviews[]?
            | select(.state == "CHANGES_REQUESTED" and .commit.oid == $head)
            | select((.author.login // "") == $human)] | length > 0)
      and (([.reviewRequests[]? | .login // empty
             | select(. == $human)] | length) == 0));

def failing_names:
  [latest_checks[] | select(is_blocking)
   | "\(.name // .context // "?") (\(.conclusion // .state // "?"))"]
  | if length == 0 then "-" else join(", ") end;

.[]
| select(.isDraft | not)
| "\($repo)#\(.number)\t\(.updatedAt)\t\(.headRefOid)\t\(check_state)\t\(if round_owed then "owed" else "-" end)\t\(failing_names)"
