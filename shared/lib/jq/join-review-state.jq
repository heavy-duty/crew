# join-review-state.jq — attach each PR's review state to its listing row.
#
# Input: the `gh pr list` array head-checks.jq consumes.
# Args: $rs, an object keyed by PR number AS A STRING, each value the bare
# GraphQL `pullRequest` object _review_state echoed.
# Output: the same array, every element carrying `.reviewState` — the payload
# for that number, or null when the read failed, was skipped (drafts are never
# fetched), or described a head the listing did not see.
#
# A FILE RATHER THAN AN INLINE PROGRAM, because null is the load-bearing case
# and an inline one-liner is the kind of thing that gets "simplified" to
# `$rs[...]` with the `// null` dropped. Dropping it makes `.reviewState` absent
# rather than null, which head-checks.jq reads identically — today. It is here
# so the null path has a fixture (#147).
map(. + {reviewState: ($rs[(.number | tostring)] // null)})
