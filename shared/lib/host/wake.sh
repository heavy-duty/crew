# shared/lib/host/wake.sh — the host's wake decision (#759).
#
# One board read per repository per tick, on the HOST, joined with the store:
# a box is started only when the board changed since this member last saw it
# AND the change names work the member's roles own AND the member's own
# memory — its ledgers, its breakers, its budgets, all in the store — does not
# already answer it. A box the host does not start spends nothing, which is
# the whole lever: the 2026-08-24 bill was 4,005 sessions on two lanes that
# woke every tick on an unchanged board.
#
# Sourced by cli/crew. Every outside read goes through one of two seams —
# wake_gh (the board) and wake_store (the store) — so the suite drives the
# decision with fixtures and no network. Nothing here starts or stops a box:
# this file DECIDES, cli/crew's tick ACTS, and the two stay apart so a
# decision is testable without a host.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # jq and GraphQL programs carry their own $vars

wake_gh()    { gh "$@"; }
wake_store() { store_py "$@"; }

# wake_board_rows REPO — the board as rows, one per open object, or nothing
# and 1 when any read failed (an unreadable board is "no change": the next
# tick reads again, and nothing starts on a guess).
#   I <num> <updatedAt> <labels,csv|-> <assignees,csv|->
#   P <num> <updatedAt> <author> <draft 0|1> <requested,csv|->
#   D <num> <updatedAt>
wake_board_rows() {
  local repo="$1" owner name issues prs discs
  owner="${repo%%/*}"; name="${repo#*/}"
  issues="$(wake_gh issue list -R "$repo" --state open --limit 200 \
    --json number,updatedAt,labels,assignees \
    --jq '.[] | "I \(.number) \(.updatedAt) \(([.labels[].name] | join(",")) | if . == "" then "-" else . end) \(([.assignees[].login] | join(",")) | if . == "" then "-" else . end)"' 2>/dev/null)" || return 1
  prs="$(wake_gh pr list -R "$repo" --state open --limit 100 \
    --json number,updatedAt,author,isDraft,reviewRequests \
    --jq '.[] | "P \(.number) \(.updatedAt) \(.author.login // "-") \(if .isDraft then 1 else 0 end) \(([.reviewRequests[]?.login // .reviewRequests[]?.name // empty] | join(",")) | if . == "" then "-" else . end)"' 2>/dev/null)" || return 1
  discs="$(wake_gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){
      discussions(first:50,states:OPEN){ nodes{ number updatedAt } } } }' \
    --jq '.data.repository.discussions.nodes[] | "D \(.number) \(.updatedAt)"' 2>/dev/null)" || return 1
  printf '%s\n%s\n%s\n' "$issues" "$prs" "$discs" | sed '/^$/d'
}

# wake_digest — one token for a board's rows, so "did anything move" is a
# string compare and the previous reading is one short file per repo.
wake_digest() { sha256sum | cut -c1-16; }

# wake_reasons ROLES LOGIN REPO ROWS — the work this member's roles own on
# this board, one reason per line, as `kind#repo#num <updatedAt>` (the
# timestamp is what the ledger veto compares). Role rules, deliberately
# coarse — the box's own tick does the precise detection once it is awake:
#   every role  attention#…  an issue labelled attention assigned to me
#   builder     ready#…      a ready issue nobody is assigned to
#               pr#…         an open pull request of mine (a round may be owed)
#   reviewer    review#…     a pull request requesting my review
#   triage      board#REPO   anything at all moved (needs-triage, strays, a
#                            discussion — triage's signals read the whole board)
wake_reasons() {
  local roles="$1" login="$2" repo="$3" rows="$4"
  local kind num ts a b c
  while read -r kind num ts a b c; do
    [ -n "$kind" ] || continue
    case "$kind" in
      I)
        case ",$a," in *",attention,"*) case ",$b," in *",$login,"*) [ -n "$login" ] && echo "attention#$repo#$num $ts" ;; esac ;; esac
        case " $roles " in *" builder "*)
          case ",$a," in *",ready,"*) [ "$b" = - ] && echo "ready#$repo#$num $ts" ;; esac ;;
        esac ;;
      P)
        case " $roles " in *" builder "*)
          [ -n "$login" ] && [ "$a" = "$login" ] && echo "pr#$repo#$num $ts" ;;
        esac
        case " $roles " in *" reviewer "*)
          [ -n "$login" ] && case ",$c," in *",$login,"*) echo "review#$repo#$num $ts" ;; esac ;;
        esac ;;
    esac
  done <<<"$rows"
  case " $roles " in *" triage "*) [ -n "$rows" ] && echo "board#$repo -" ;; esac
  return 0
}

# wake_ledger_seen BOX ITEM TS — has this member already handled ITEM
# (repo#num) at or past TS? Read from every ledger the store holds for the
# box: the engine's seen-ledgers are `id ts` rows and ids are `repo#num`.
wake_ledger_seen() {
  local box="$1" item="$2" ts="$3" id seen_ts
  while read -r id seen_ts; do
    [ "$id" = "$item" ] || continue
    [ "$seen_ts" \< "$ts" ] || return 0
  done < <(wake_store ledger --box "$box" 2>/dev/null)
  return 1
}

# wake_breaker_tripped BOX KIND — the lane's terminal breaker, from the store.
wake_breaker_tripped() {
  local status
  status="$(wake_store state --box "$1" --name ".session-terminal.$2" 2>/dev/null | head -1 | cut -f2)"
  [ "$status" = tripped ]
}

# wake_budget_exhausted BOX KIND — sessions of this kind in the window, from
# the store, against the ceiling the role conf declares (BUDGET_SESSIONS_<KIND>
# with the kind folded as the engine folds it). No ceiling, no veto.
wake_budget_exhausted() {
  local box="$1" kind="$2" suffix var ceiling window n
  suffix="${kind//[^[:alnum:]]/_}"; suffix="${suffix^^}"
  var="BUDGET_SESSIONS_$suffix"; ceiling="${!var:-0}"
  case "$ceiling" in ''|*[!0-9]*|0) return 1 ;; esac
  window="${BUDGET_WINDOW:-86400}"
  n="$(wake_store sessions-count --box "$box" --kind "$kind" --since "$((window / 3600))h" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge "$ceiling" ]
}

# wake_veto BOX REASONS [STATE] — the reasons that survive the member's own memory,
# one per line, plus `veto:<reason>:<why>` lines for the dropped ones (the
# tick logs those: a veto that is silent is a wake that is missing).
wake_veto() {
  local box="$1" reasons="$2" state="${3:-running}" reason ts kind item lane
  while read -r reason ts; do
    [ -n "$reason" ] || continue
    kind="${reason%%#*}"; item="${reason#*#}"
    # A due wait is answered by the RESUME session, so it is vetoed by that
    # lane's budget: a wait the budget refused would otherwise wake the box
    # every tick until the window rolls.
    case "$kind" in attention) lane=attention ;; ready|pr) lane=build ;; review) lane=review ;; board) lane=triage ;; wait) lane=resume ;; *) lane="$kind" ;; esac
    if [ "$kind" != board ] && [ "$ts" != - ] && wake_ledger_seen "$box" "$item" "$ts"; then
      echo "veto:$reason:seen"; continue
    fi
    # The store's copy of a tripped breaker is read only while the box runs:
    # only the box's own gate can clear it (a probe, a trial dispatch), so a
    # stopped box is started for the work and its gate decides — otherwise a
    # breaker frozen in the store would keep the lane off forever.
    if [ "$state" = running ] && wake_breaker_tripped "$box" "$lane"; then echo "veto:$reason:breaker-$lane"; continue; fi
    if wake_budget_exhausted "$box" "$lane"; then echo "veto:$reason:budget-$lane"; continue; fi
    echo "$reason $ts"
  done <<<"$reasons"
}

# wake_wait_reasons BOX — parked waits the member left (park-until.sh), read
# from the store while the box sleeps: one whose checks have concluded is a
# reason of its own, `wait#repo#num`, never ledger-vetoed (the member parked
# it on purpose). A wait still pending costs one read and no wake.
wake_wait_reasons() {
  local box="$1" name content wrepo num head _at pending
  while IFS=$'\t' read -r name content; do
    case "$name" in .wait-*) ;; *) continue ;; esac
    read -r wrepo num head _at <<<"$content"
    { [ -n "$wrepo" ] && [ -n "$num" ]; } || continue
    pending="$(wake_gh pr view "$num" -R "$wrepo" --json headRefOid,statusCheckRollup 2>/dev/null \
      | jq -r --arg head "$head" 'if (.headRefOid // "") != $head then 0 else ([.statusCheckRollup[]? | select((.conclusion // "") == "" and ((.status // "") == "QUEUED" or (.status // "") == "IN_PROGRESS" or (.status // "") == "PENDING" or (.status // "") == "WAITING" or (.status // "") == "REQUESTED" or (.status // "") == "EXPECTED" or (.state // "") == "PENDING" or (.state // "") == "EXPECTED"))] | length) end' 2>/dev/null)"
    [ "$pending" = 0 ] && echo "wait#$wrepo#$num -"
  done < <(wake_store states --box "$box" --prefix .wait- 2>/dev/null)
  return 0
}

# wake_release_reasons BOX — a cut the member deferred for main to go quiet
# (duty-release.sh writes `.release-due-<slug>` as `repo <epoch>`), read from
# the store while the box sleeps: due is a reason of its own, `release#repo`,
# never ledger-vetoed (the member deferred it on purpose). Not yet due costs
# nothing and wakes nothing.
wake_release_reasons() {
  local box="$1" name content rrepo due now
  now="$(date +%s)"
  while IFS=$'\t' read -r name content; do
    case "$name" in .release-due-*) ;; *) continue ;; esac
    read -r rrepo due <<<"$content"
    { [ -n "$rrepo" ] && [ -n "$due" ]; } || continue
    case "$due" in *[!0-9]*|'') continue ;; esac
    [ "$now" -ge "$due" ] && echo "release#$rrepo -"
  done < <(wake_store states --box "$box" --prefix .release-due- 2>/dev/null)
  return 0
}

# wake_why REASONS — the `why=` token the box's SESSION END lines will carry:
# the surviving reasons' names, comma-joined, one token.
wake_why() {
  printf '%s\n' "$1" | grep -v '^veto:' | awk 'NF {print $1}' | paste -sd, - | tr -d ' '
}
