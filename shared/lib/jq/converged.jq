# converged.jq — handoff convergence predicate. Input: the GraphQL pullRequest
# payload (headRefOid, mergeable, reviewRequests, latestOpinionatedReviews,
# comments). Args: $panel (JSON array of logins, author already subtracted),
# $me (my login), $mark_handoff (the MARK_HANDOFF wire string), $human (the
# maintainer's login — FLEET_HUMAN; "" from a caller that is not asking about
# a round), $signal (answered-head.jq's {sha, createdAt}, the same object
# request-panel.jq is handed).
#
# Output, one word:
#   true           converged and mergeable RIGHT NOW — hand off
#   false          not converged
#   handed-off     converged and mergeable, and ALREADY handed off at this
#                  head — the refire guard; the caller logs it and does nothing
#   defer-unknown  converged but mergeability UNKNOWN — GitHub's post-merge
#                  recompute flap; wait for the next tick, never act on it
#
# THE REFIRE GUARD READS THE ENGINE'S OWN MARK, NEVER A LABEL (#535). It used
# to read `state:needs-human`, which the ceremony reconciler owns and takes off
# for reasons of its own — a human CHANGES_REQUESTED (#452), `blocker:ci-red`
# moving the PR to `state:addressing` (#535) — and each removal re-armed the
# wake at an unchanged head: the panel still approved, nothing moved mergeable,
# so the handoff re-fired, the reconciler took the label back off, and the two
# wrote over each other at tick cadence (135 label events in 6h19m on crew#516,
# over a red on main that no push by the builder could clear). #452 patched one
# trigger; the guard itself was the defect. The fact it stood for — "this head
# has been handed off" — is the builder's own, and `_handoff_finalize` already
# posts it: a comment by $me whose FIRST LINE is `$mark_handoff <head>`. That
# line is the guard now. A push, a rebase or a force-push is a new head with no
# such line, and re-arms the wake (D2); a label removal, a check changing
# colour or a reconciler state change does not. The label is not read here at
# all — "head moved with the label still present" must hand off again.
#
# Whole-line, never substring: post-once.sh's own dedup discipline (ceremony#32),
# so a short-sha mention in prose can never read as the mark.
#
# Computed from latestOpinionatedReviews, never reviewDecision (empty
# without branch protection — stalled rounds for a day, ceremony#26/#39).
# Approvals must be AT the current head: an approval is of a specific tree.
.data.repository.pullRequest as $pr
| (($pr.reviewRequests.nodes | map(.requestedReviewer.login // empty)
    | map(select(. as $l | ($roster | index($l)) != null)) | length) == 0) as $no_panel_reqs
| ([$pr.comments.nodes[]?
     | select((.author.login // "") == $me
              and (((.body // "") | split("\n") | first) == ($mark_handoff + " " + $pr.headRefOid)))]
   | length > 0) as $handed_at_head
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
         | .author.login)) as $head_approvers
# An EMPTY panel must never converge vacuously — a bare panel= line (or a
# panel that named only the author) would otherwise hand off every open PR
# with zero reviews.
| (($panel | length > 0) and (($panel - $head_approvers) | length == 0)) as $panel_approves
# THE HUMAN'S OWN VERDICT DISQUALIFIES (#452). BUILDER.md's Handoff ends
# "address what comes back and re-hand-off the same way", and without this the
# engine could not: every builder wake is scoped to $panel and the human is
# off-panel by construction, so a maintainer's CHANGES_REQUESTED woke nothing
# while THIS predicate stayed true — the panel still approved the head, and a
# review does not move mergeable. The reconciler wrote state:addressing, the
# next tick re-fired the handoff, and the finalizer re-requested the human and
# re-set state:needs-human. The change request never reached the builder, and
# the PR bounced straight back at the human carrying a fresh nag.
#
# $human ALONE, never "not in $panel" (D3). An off-panel reviewer stays
# advisory (BUILDER.md) and triage does not vote on PRs, so keying on panel
# membership would let one advisory verdict block every handoff on the board.
# An empty $human matches nobody — what a caller reading no round passes.
| ($pr.latestOpinionatedReviews.nodes
   | map(select(($human // "") != ""
                and (.author.login // "") == $human
                and .state == "CHANGES_REQUESTED"
                and .commit.oid == $pr.headRefOid))
   | last) as $human_block
# HEAD-SCOPED, not any-head. GitHub's dismissal semantic — which the ceremony
# reconciler's own read of the human follows — blocks at any head; this file's
# rule is that a verdict is of a specific tree, and any-head here would
# DEADLOCK: after the builder pushes the fix, the handoff is the only thing
# that returns the PR to the human, so a standing stale block would stop the
# very act that clears it.
#
# SPENDABLE, and this is the half that makes an ARGUED answer work. Where the
# builder answers with argument and pushes nothing, request-panel.jq finds
# nobody to request — the panel already approves that head — so only the
# handoff can put the PR back in front of the human. The ordering is #286's
# exactly: the signal must be AT this head and STRICTLY NEWER than the verdict
# it claims to answer, or a signal posted before the block would cancel it. An
# equal-second tie holds, and so does an absent timestamp on either side —
# request-panel.jq's fail-closed direction, for its reason: holding costs one
# tick, failing open costs the bounce above.
| (($signal.sha // "") == $pr.headRefOid
   and ($signal.createdAt // "") != ""
   and ($human_block.submittedAt // "") != ""
   and ($signal.createdAt) > ($human_block.submittedAt)) as $human_answered
| ($human_block != null and ($human_answered | not)) as $human_blocks
# NO GREEN GATE HERE, by decision (D4, grok #64): ci-red fires once per head,
# so under a red no push can clear a green-gated handoff would wake nothing and
# the PR would strand with full approvals (ceremony#163). The handoff reaches
# the human at a red head; the human decides. "handed-off" is reported only
# where "true" would otherwise have been — a converged, MERGEABLE head — so the
# caller's suppression log line means exactly "the wake would have fired".
| if ($no_panel_reqs and $panel_approves and ($human_blocks | not))
  then (if $pr.mergeable == "MERGEABLE"
        then (if $handed_at_head then "handed-off" else "true" end)
        elif $pr.mergeable == "UNKNOWN" then "defer-unknown"
        else "false" end)
  else "false" end
