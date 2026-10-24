# addressing.jq — round-close predicate, the deliberate MIRROR of converged.jq
# (#130). Input: the GraphQL pullRequest payload (headRefOid, labels,
# reviewRequests, latestOpinionatedReviews). Args: $panel (JSON array of
# logins, author already subtracted), $addressing (label name).
#
# Output, one word:
#   true   the round closed WITHOUT full approval — the builder's ball; set
#          state:addressing
#   false  not a closed-without-approval round (still awaiting a verdict,
#          already converged, or the label already stands)
#
# The two predicates share every input and every scoping rule and differ only
# in the conclusion, on purpose: converged.jq asks "did every panelist approve
# THIS head?", addressing.jq asks "did every panelist review THIS head and at
# least one NOT approve?". Writing them as sibling fixtures against the same
# payload is what keeps them from drifting into two hand-rolled round
# predicates that can disagree — a defect waiting to be filed (#130).
#
# Computed from latestOpinionatedReviews, never reviewDecision (empty without
# branch protection — stalled rounds for a day, ceremony#26/#39). Reviews must
# be AT the current head: an opinion is of a specific tree, and a verdict on a
# superseded head has not reviewed the tree the panel is being asked about.
.data.repository.pullRequest as $pr
# Mirror of converged.jq's $not_handed: the engine write is optimistic and the
# add-label is itself idempotent, but gating the predicate on the label being
# ABSENT is what makes "re-ticking writes nothing" true at the jq layer rather
# than relying on GitHub to no-op a redundant PUT (#130 acceptance criterion).
| (($pr.labels.nodes | map(.name) | index($addressing)) == null) as $not_addressing
# Mirror of converged.jq's $no_panel_reqs: a live panel request means the round
# is still open (state:bots-reviewing), not closed. Without this the engine
# would optimistically write state:addressing over a head that was just
# re-requested, and the reconciler would flip it straight back.
| (($pr.reviewRequests.nodes | map(.requestedReviewer.login // empty)
    | map(select(. as $l | ($roster | index($l)) != null)) | length) == 0) as $no_panel_reqs
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.commit.oid == $pr.headRefOid) | .author.login)) as $head_reviewers
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
         | .author.login)) as $head_approvers
# Every panelist has an opinionated verdict at the current head. An EMPTY panel
# never closes a round vacuously — the same guard converged.jq carries against
# a bare panel= line (or a panel naming only the author).
| (($panel | length > 0) and (($panel - $head_reviewers) | length == 0)) as $all_reviewed_at_head
# ... and at least one of those head verdicts is not an approval. This is the
# single bit that flips converged.jq's conclusion: converged needs
# ($panel - $head_approvers) EMPTY, addressing needs it NON-EMPTY.
| (($panel - $head_approvers) | length > 0) as $some_not_approved
| if ($not_addressing and $no_panel_reqs and $all_reviewed_at_head and $some_not_approved)
  then "true" else "false" end
