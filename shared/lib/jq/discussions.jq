# discussions.jq — signal (c)'s selector: which open discussions wake triage
# (#757 D8, from the record on #328). Input: the repository discussions
# payload (number, updatedAt, comments with author/body/createdAt and their
# replies). Env: TR_ME (my login), TR_R (owner/repo), TR_TODAY (YYYY-MM-DD).
#
# A discussion wakes triage when its last word is not triage's own — no
# comment at all, or the newest comment or reply by someone else — and when
# triage's own last word carries `returns on YYYY-MM-DD` and that date has
# arrived. The old rule dropped every thread $ME had ever commented on, so
# converging a discussion was the act that removed it from the wake set for
# good: an *ask* or *escalate* with a dated return promise was never read
# again (15 open, 1 selected, five carrying expired promises on 2026-09-03).
#
# Emits "repo#N <ts>": the thread's updatedAt, or the return date as a
# midnight timestamp when that is later — the seen-ledger keys on the
# timestamp, and a return date arriving moves nothing on GitHub, so the clock
# has to move the key itself. Dates compare lexically, as every ledger does.
def all_comments:
  [ .comments.nodes[]? | ., (.replies.nodes[]?) ]
  | map(select((.createdAt // "") != ""));
def last_word: all_comments | sort_by(.createdAt) | last;
def return_date:
  ((.body // "") | [scan("returns on ([0-9]{4}-[0-9]{2}-[0-9]{2})")] | last)
  | if . == null then null else .[0] end;
[ .data.repository.discussions.nodes[]
  | . as $d
  | (last_word) as $last
  | (if $last == null then "open"
     elif ($last.author.login // "") != env.TR_ME then "theirs"
     else (($last | return_date) as $r
           | if $r != null and $r <= env.TR_TODAY then "due:\($r)" else "mine" end)
     end) as $why
  | select($why != "mine")
  | (if ($why | startswith("due:"))
     then ([ $d.updatedAt, ($why[4:] + "T00:00:00Z") ] | max)
     else $d.updatedAt end) as $ts
  | "\(env.TR_R)#\($d.number) \($ts)" ]
| .[]
