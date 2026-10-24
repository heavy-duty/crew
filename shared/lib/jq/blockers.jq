# blockers.jq — from an array of {number, body} blocked issues and a state
# map $S ({"<number>": "OPEN|CLOSED|MERGED"}), emit the comma-joined numbers
# whose every named blocker has landed.
#
# Parsing is deliberately narrow. Issue bodies open with a line like
#   "Part of #1. Blocked by #5, #6, #7, #9 (and #10 for the label bootstrap).
#    Blocks #13 (the pilot needs a tag to pin)."
# so three things must hold: read only the "Blocked by" clause (never
# "Blocks", the inverse relation in the same line); stop at that clause's
# first sentence end; and pick up #N inside its parentheses, which are real
# blockers. Hence match up to the clause's sentence terminator and scan that
# span only. The terminator is a "." or ";" not followed by a letter or digit
# (the grammar ceremony's issueflow-reconcile reads): the stop that closes
# "Blocked by heavy-duty/la-familia-site#5." ends the clause, the dot inside
# "v1.2" does not, and a soft-wrapped clause continues across its newline (#632).
#
# A marker that opens a code span or a quotation — a backtick or a double
# quote immediately before "Blocked by" — is a QUOTATION of some other issue's
# clause, not a declaration of this one, and contributes nothing: a body that
# quoted another issue's hold clause in prose used to parse to a phantom
# blocker set (crew#602, #642, #652, each repaired by hand with a hyphen). A
# struck-through or emphasised marker (~~Blocked by #5~~, **Blocked by #5.**)
# still declares (#632).
#
# Fail-safe by construction: a member the state map cannot resolve defaults
# to "OPEN", so a parse miss leaves the issue blocked and the hygiene sweep
# catches it — and that holds for references as well as for numbers.
# Cross-repo blockers ("Blocked by owner/repo#N", or the unowned "repo#N")
# parse as a member keyed by their WHOLE token, never by their bare number:
# $S is keyed by this repository's numbers and can never hold such a key, so
# the member reads "OPEN" by construction and the issue stays held, which is
# the sweep's own verdict (FLAG_CROSS_REPO) and what TRIAGE.md asks for —
# triage verifies those and flips them by hand. Keyed by bare number instead,
# incubator#421 would resolve against THIS repository's #421 (#632 D1). The
# bare alternative stays keyed by its number alone: a local blocker that is
# still open must never be captured with its "#" and so read "OPEN" (#632).
def blockers:
  def mask: if test("\\([^()]*\\)") then gsub("\\((?<p>[^()]*)\\)"; "[" + (.p | gsub("[.;](?=\\s|$)"; ",")) + "]") | mask else . end; mask
  | gsub("\\((?<p>[^()\\n]*)(?=\\n|$)"; "[" + (.p | gsub("[.;](?=[ \\t])"; ",")) + "]")
  | [ match("(?<![`\"])[Bb]locked by((?:[^.;]|[.;](?=[A-Za-z0-9]))*)"; "g").captures[0].string ] | join(" ")
  | [ scan("(?:^|[^A-Za-z0-9_/.-])((?:[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+#[0-9]+|#([0-9]+))") | .[1] // .[0] ];
[ .[]
  | . as $i
  | (($i.body // "") | blockers) as $b
  | select(($b | length) > 0)
  | select(all($b[]; ($S[.] // "OPEN") | . == "CLOSED" or . == "MERGED"))
  | $i.number ]
| join(",")
