#!/usr/bin/env bash
# Sourceable fixture and invariant helpers for drill/rehearsal.sh. These stay
# separate so their failure cases can be exercised without credentials or a
# host-side drill box.

# --- the board vocabulary, read off the box (#735) ----------------------------
#
# Every LABEL_* is operator-configurable. load_fleet_conf sources
# fleet.defaults.conf, then fleet.conf OVER it, and restores exactly six values
# afterwards — the MARK_* wire protocol (shared/lib/common/conf.sh:13-25). Not
# one LABEL_* is in that set, so an operator file genuinely moves every name in
# shared/conf/fleet.defaults.conf, and the engine then reads the moved one:
# duty_attention fetches `labels=$LABEL_ATTENTION` (duty-attention.sh:115) and
# the triage module grades the queue on the six queue names (duty-triage.sh).
#
# So the drill has to mint and match the same names. A fixture minted with the
# shipped English `attention` on a box that moved it is a demand the engine
# never fetches: the phase-2 wake spends its 900 seconds and reds on a correct
# engine. Same read, same shape as the attention census's own
# (rehearsal-safety.sh:483-518) — defaults, then fleet.conf over them, in ONE
# call per box.
#
# MARK_* is deliberately NOT read here. The marks are a wire protocol the
# loader restores over any operator file, and rehearsal_attention_census_take
# and rehearsal_load_installed_answer_mark below read them from the defaults
# ALONE for that reason. Resolving a mark through fleet.conf would key an
# assertion on a mark the engine never writes with.
REHEARSAL_LABEL_ATTENTION=""
REHEARSAL_LABEL_NEEDS_TRIAGE=""
REHEARSAL_LABEL_READY=""
REHEARSAL_LABEL_CLAIMED=""
REHEARSAL_LABEL_BLOCKED=""
REHEARSAL_LABEL_EPIC=""
REHEARSAL_BOARD_LABEL_REASON=""
REHEARSAL_QUEUE_LABELS=""

# Read positionally, never through `sed '/^$/d'`: a box that resolves no
# LABEL_BLOCKED must leave REHEARSAL_LABEL_BLOCKED empty and be refused for
# that, not shift LABEL_EPIC up into its slot and mint a board whose
# names are silently one place out.
#
# A positional read can be shifted by a value of its OWN, though, which
# emptiness cannot catch: a name carrying an embedded newline emits two lines,
# every slot below it lands one place out, and the LAST value is dropped — so
# all six slots are non-empty and the guard below never runs. The box
# therefore terminates its seven values with a sentinel and the read refuses
# unless the eighth line is exactly that: positive evidence that the seven
# lines read are the seven that were written. A value that IS the sentinel
# cannot fake it, because the sentinel carries whitespace and the guard below
# refuses any name that does.
rehearsal_load_installed_board_labels() {
  local conf name value missing="" terminator="" read_conf
  local sentinel='--- end of the board vocabulary ---'
  REHEARSAL_BOARD_LABEL_REASON=""
  # shellcheck disable=SC2016  # every LABEL_* expands inside the box; the sentinel is this side's
  read_conf='set -a
             . ~/duty/conf/fleet.defaults.conf
             [ ! -f ~/duty/conf/fleet.conf ] || . ~/duty/conf/fleet.conf
             printf "%s\n" "$LABEL_ATTENTION" "$LABEL_NEEDS_TRIAGE" \
               "$LABEL_READY" "$LABEL_CLAIMED" "$LABEL_BLOCKED" \
               "$LABEL_EPIC" '"'$sentinel'"
  # `s/\r$//` and not the drill's usual `tr -d '\r'`, at this one site. The CR
  # this read has to survive is the TRANSPORT's: bx hands the box's stdout back
  # through a channel that may translate line endings, and a CR sitting at the
  # end of a line is that translation. A CR ANYWHERE ELSE is a byte inside the
  # operator's value, and stripping it is the one place this read would guess on
  # the operator's behalf — the elsewhere-identical `tr -d '\r'` sites feed
  # values the drill prints or compares, where this one feeds a value the guard
  # below REFUSES for carrying whitespace. So the interior CR is left in, and
  # `*[[:space:]]*` declines it by the same rule as a space or a tab.
  #
  # One case stays irreducible: a name whose LAST byte is a CR arrives as
  # `value\r\n`, byte-identical to a transport-translated `value\n`, and is read
  # as `value`. Nothing at this layer can tell those apart.
  conf="$(bx "$read_conf" | sed 's/\r$//')" || conf=""
  {
    IFS= read -r REHEARSAL_LABEL_ATTENTION
    IFS= read -r REHEARSAL_LABEL_NEEDS_TRIAGE
    IFS= read -r REHEARSAL_LABEL_READY
    IFS= read -r REHEARSAL_LABEL_CLAIMED
    IFS= read -r REHEARSAL_LABEL_BLOCKED
    IFS= read -r REHEARSAL_LABEL_EPIC
    IFS= read -r terminator
  } <<<"$conf" || true
  # A name carrying whitespace is refused rather than half-supported, for
  # rehearsal-breaker.sh:117-122's reason: GitHub accepts one and every
  # `grep -qx`, `-f "labels[]=…"` and jq needle downstream would have to agree
  # about the quoting, so the drill declines to guess on the operator's behalf.
  for name in ATTENTION NEEDS_TRIAGE READY CLAIMED BLOCKED EPIC; do
    eval "value=\$REHEARSAL_LABEL_$name"
    case "$value" in
      '')             missing="$missing${missing:+, }LABEL_$name" ;;
      *[[:space:]]*)  missing="$missing${missing:+, }LABEL_$name (whitespace)" ;;
    esac
  done
  [ -z "$missing" ] || {
    # shellcheck disable=SC2034  # printed by rehearsal.sh's refusal, like REHEARSAL_ATTENTION_REASON
    REHEARSAL_BOARD_LABEL_REASON="the box's installed configuration resolved no usable $missing"
    return 1
  }
  # After the emptiness check, so a box that answered nothing at all is still
  # reported as the missing names it could not resolve rather than as a
  # terminator that never arrived. Both refuse; only the console text differs.
  [ "$terminator" = "$sentinel" ] || {
    # shellcheck disable=SC2034  # printed by rehearsal.sh's refusal, like REHEARSAL_ATTENTION_REASON
    REHEARSAL_BOARD_LABEL_REASON="the box's installed configuration did not answer seven \
names in seven lines: the read ended at '$terminator' rather than the vocabulary's own \
terminator, so at least one name carries a newline and every slot below it is one place out"
    return 1
  }
}

# The whole board vocabulary, minted under the names the box will actually
# grade. The COLOURS stay literal: no colour is configurable, so only the name
# side of each pair moves.
rehearsal_mint_board_vocabulary() {
  local repo="$1"
  set -- \
    "$REHEARSAL_LABEL_ATTENTION"    d93f0b \
    "$REHEARSAL_LABEL_NEEDS_TRIAGE" fbca04 \
    "$REHEARSAL_LABEL_READY"        0e8a16 \
    "$REHEARSAL_LABEL_CLAIMED"      1d76db \
    "$REHEARSAL_LABEL_BLOCKED"      b60205 \
    "$REHEARSAL_LABEL_EPIC"         5319e7
  while [ "$#" -gt 0 ]; do
    gh api "repos/$repo/labels" -f name="$1" -f color="$2" >/dev/null 2>&1 || true
    shift 2
  done
}

rehearsal_load_installed_queue_labels() {
  local count
  # fleet.conf OVER the defaults (#735 D2). The engine grades the queue on the
  # effective names, so the set the stray-ruling assertion matches an issue's
  # labels against has to be resolved from them too. Five is the count since
  # ceremony 0.7.11 retired `post-merge`: a fleet.conf that collides two names
  # onto one string resolves four through
  # `sort -u` and reds here.
  # shellcheck disable=SC2016  # the label variables expand inside the box
  REHEARSAL_QUEUE_LABELS="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    [ ! -f ~/duty/conf/fleet.conf ] || . ~/duty/conf/fleet.conf
    printf "%s\n" \
      "$LABEL_READY" "$LABEL_CLAIMED" "$LABEL_BLOCKED" \
      "$LABEL_EPIC" "$LABEL_NEEDS_TRIAGE"
  ' | sed -e 's/\r$//' -e '/^$/d' | sort -u)"
  # The same end-of-line CR strip the board read carries, for a reason this
  # issue created: before it, this set was only COUNTED, and a transport that
  # translated line endings resolved every name that happened to end in CR and
  # the row still read green. It is now the set an issue's labels are matched
  # against, where a trailing CR matches nothing the board carries and the stray
  # assertion reds on a correct engine. Only the end-of-line CR, for the reason
  # stated at the board read.
  #
  # Resolved here rather than at the call site, so the set the stray assertion
  # matches against and the set this row counts cannot drift apart — and so a
  # fixture can read the set itself instead of re-deriving it and passing under
  # its own mutation.
  count="$(printf '%s\n' "$REHEARSAL_QUEUE_LABELS" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -eq 5 ]; then
    ok "triage: installed queue-label set resolves five names"
    return 0
  fi

  echo "triage: installed queue-label set resolved $count name(s):"
  printf '%s\n' "$REHEARSAL_QUEUE_LABELS" | sed 's/^/  /'
  fail "triage: installed queue-label set resolves five names"
  return 1
}

# The board invariant, read back: no open issue may remain queue-unlabelled.
# Matched against the effective set, so an issue triage moved into a renamed
# `ready` satisfies it and one carrying only the shipped English name on a
# renamed board does not.
#
# `grep -qxF` over the newline-separated SET, and never an `-E` pattern joined
# out of it. A label name is operator DATA: joined with `|` and read as an ERE,
# `LABEL_READY="ready.v2"` accepts an issue carrying the different label
# `readyXv2`, because `.` is a wildcard — the predicate then reports a board it
# never matched, which is this issue's own defect pointed the other way. A name
# carrying `|` is worse: it re-partitions the alternation and each fragment
# becomes a queue name the board does not have. `-F` takes each line as a fixed
# string and `-x` anchors it whole, so the comparison is the one D1 asks for.
#
# And `--` before it, because the SET is still an OPERAND, and an operand is the
# third place a resolved name stops being data. A name beginning with `-` sorts
# to the front of the set, so the operand begins with a hyphen and grep reads it
# as an option bundle. Which of two failures follows depends only on the
# letters: `LABEL_READY="-alert"` parses as `-a -l -e`, and `-e` then takes the
# REST of the operand — newlines and all — as its pattern argument, so the
# patterns compared are `rt`, `blocked`, `claimed`… The issue carrying the exact
# `-alert` reads STRAY and one carrying the fragment `rt` reads RULED, silently,
# on a board that has neither. `LABEL_READY="-active"` reaches `-t`, which is no
# option at all, and grep exits 2 with a usage message: every issue reads stray.
# The loader cannot catch either — both names are non-empty and whitespace-free,
# so both are names it must accept. `--` ends the option list and the set goes
# back to being the operand it always was.
#
# A here-string and not a pipe into `grep -q`: `grep -q` exits on its first
# match and the producer takes SIGPIPE, which under `set -o pipefail` makes the
# whole command red at random (#449). The guard in shared/test/common.sh reds on
# the shape itself.
#
# `queue_names`, not `names`. shellcheck resolves a sourced file's locals into
# the sourcing file's namespace, and `names` there turns shared/test/common.sh's
# own `r1=names-arrival-tick` into an arithmetic suggestion (SC2100) in a line
# this issue never touched — the same trap rehearsal-attention-audit.sh records
# against `rows`.
rehearsal_stray_left_the_queue() {
  local repo="$1" num="$2" queue_names
  [ -n "$REHEARSAL_QUEUE_LABELS" ] || return 1
  queue_names="$(gh api "repos/$repo/issues/$num" --jq '.labels[].name')" || return 1
  grep -qxF -- "$REHEARSAL_QUEUE_LABELS" <<<"$queue_names"
}

rehearsal_load_installed_answer_mark() {
  local mark
  # shellcheck disable=SC2034  # sourced global consumed by rehearsal.sh
  REHEARSAL_MARK_ANSWERED=""
  # shellcheck disable=SC2016  # the wire variable expands inside the box
  if ! mark="$(bx '
    set -a
    . ~/duty/conf/fleet.defaults.conf
    printf "%s\n" "$MARK_ANSWERED"
  ')" || [ -z "$mark" ]; then
    fail "builder: installed round-answer mark resolves"
    return 1
  fi
  # shellcheck disable=SC2034  # sourced global consumed by rehearsal.sh
  REHEARSAL_MARK_ANSWERED="$mark"
  ok "builder: installed round-answer mark resolves"
}

# --- phase-2's own fixtures, and the predicates that read them back -----------
#
# Sourceable for this file's stated reason: the three mints below and the three
# predicates that grade them are the sites #735 moved off the shipped English
# names, and a mint that asks for one name while its predicate matches another
# cannot be caught by reading either half. Each pair is driven against a stub
# board in shared/test/drill.sh instead. Every one prints its issue number on
# stdout or matches on the box's own effective name; none of them spells a
# board label.
#
# THE NAME NEVER REACHES jq AS SOURCE TEXT. A resolved name is operator data,
# so the two label predicates below fetch the issue JSON and pass it through
# `jq -e --arg`, the shape rehearsal_attention_is_ready_from_json already uses
# (rehearsal-attention.sh:139-142). Interpolated into the filter instead,
# LABEL_ATTENTION='needs"human' ends the string literal and the filter does not
# compile — so the predicate returns 1 on a CORRECT board and reds the round on
# a correct engine — and a backslash-bearing name mis-grades silently.
#
# That is also why neither reads a boolean back through `gh api --jq`, which
# MARSHALS it: a filter yielding null prints NOTHING where real jq prints
# "null", so the old `grep -qx true` idiom existed to put a token on stdout in
# both states. `jq -e` carries the answer in its exit status instead, and the
# marshalling cannot reach it. The `--jq` reads that remain here yield strings.

rehearsal_mint_attention_demand() {
  local repo="$1" identity="$2" title="$3" body="$4"
  gh api "repos/$repo/issues" -f title="$title" -f body="$body" \
    -f "assignees[]=$identity" \
    -f "labels[]=$REHEARSAL_LABEL_ATTENTION" --jq .number
}

# rc 2 on a name the box never resolved, for the reason
# rehearsal_attention_is_ready_from_json states: `index("") == null` is true, so
# an unresolved name would report this demand CLEARED on every board, green on
# every correct engine. Unreachable in the shipped tree — the board read refuses
# above the first mint and every caller is below it — and guarded anyway, where
# its sibling is. Loudly since #749: the reason goes to stderr, and `wait_for`
# prints it with the row it refuses.
rehearsal_attention_flag_cleared() {
  rehearsal_issue_lacks_label "$1" "$2" "$REHEARSAL_LABEL_ATTENTION"
}

# rehearsal_issue_lacks_label REPO NUM LABEL — the one predicate behind both
# label-removal rows, speaking wait_for's state protocol (#749):
#   0  the label is absent — the row is satisfied
#   1  the label is still present — not yet
#   2  cannot grade — the name is empty, for the reason the callers state
#   3  could not read — the API refused or answered something jq cannot parse
# "I found nothing" and "I could not look" are different answers, and the old
# `|| return 1` flattened the second into the first, so a round failed two rows
# against a correct engine. What was read goes to stderr either way: the label
# set on a successful read, the reason on a failed one — wait_for prints the
# last of it with a failing row, so the FAIL names what the predicate saw.
rehearsal_issue_lacks_label() {
  local repo="$1" num="$2" label="$3" issue_json names
  if [ -z "$label" ]; then
    echo "cannot grade: the label name is empty" >&2
    return 2
  fi
  if ! issue_json="$(gh api "repos/$repo/issues/$num")"; then
    echo "could not read repos/$repo/issues/$num" >&2
    return 3
  fi
  if ! names="$(jq -r '[.labels[].name] | join(" ")' <<<"$issue_json" 2>/dev/null)"; then
    echo "could not read: repos/$repo/issues/$num answered something that is not an issue" >&2
    return 3
  fi
  echo "labels on $repo#$num: [$names]" >&2
  if jq -e --arg label "$label" \
    '([.labels[].name] | index($label)) == null' >/dev/null <<<"$issue_json"; then
    return 0
  fi
  return 1
}

# rehearsal_lane_budget KIND — the session ceiling the box installed for a
# lane, TIMEOUT_<KIND>, read through the layering the engine's own load_conf
# applies (shared/lib/common/conf.sh): defaults, fleet.conf over them,
# instance.conf, the agent profile, then one role profile per role. Printed
# as a bare integer. Fails, printing nothing, when the box does not answer or
# answers something that is not a positive integer — so a row graded on it
# refuses rather than grading on a budget the drill invented (#750).
rehearsal_lane_budget() {
  local kind="$1" read_conf value
  case "$kind" in
    *[!A-Z_]*|'') return 1 ;;
  esac
  # shellcheck disable=SC2016  # every $ below expands inside the box
  read_conf='set -a
             . ~/duty/conf/fleet.defaults.conf
             [ ! -f ~/duty/conf/fleet.conf ] || . ~/duty/conf/fleet.conf
             . ~/duty/conf/instance.conf
             . ~/duty/conf/agents/"$BOT_AGENT".conf
             for role in $BOT_ROLES; do . ~/duty/conf/roles/"$role".conf; done
             printf "%s\n" "$TIMEOUT_'"$kind"'"'
  value="$(bx "$read_conf" 2>/dev/null)" || return 1
  value="$(printf '%s\n' "$value" | tr -d '\r' | tail -n 1)"
  case "$value" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$value"
}

rehearsal_mint_builder_ready_fixture() {
  local repo="$1" title="$2" body="$3"
  gh api "repos/$repo/issues" -f title="$title" -f body="$body" \
    -f "labels[]=$REHEARSAL_LABEL_READY" --jq .number
}

# Same two reasons, same shape: `--arg` so the name cannot be read as filter
# source, and rc 2 rather than grading a claim release against a name nothing on
# the board carries.
rehearsal_builder_left_the_queue() {
  rehearsal_issue_lacks_label "$1" "$2" "$REHEARSAL_LABEL_READY"
}

rehearsal_builder_slot_prs_from_json() {
  jq -r '.[].number' <<<"$1"
}

rehearsal_builder_pr_for_issue_from_json() {
  local issue="$1" pulls_json="$2" pr
  pr="$(jq -r --arg issue "$issue" '
    [ .[]
      | select(
          (.body // "")
          | test(
              "(?im)(^|\\s)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#"
              + $issue + "([^0-9]|$)"
            )
        )
      | .number
    ]
    | if length == 1 then .[0] else empty end
  ' <<<"$pulls_json")" || return
  [ -n "$pr" ] || return 1
  printf '%s\n' "$pr"
}

rehearsal_builder_prs_for_issue_from_json() {
  local issue="$1" pulls_json="$2"
  jq -r --arg issue "$issue" '
    .[]
    | select(
        (.body // "")
        | test(
            "(?im)(^|\\s)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s+#"
            + $issue + "([^0-9]|$)"
          )
      )
    | .number
  ' <<<"$pulls_json"
}

rehearsal_builder_open_prs_json() {
  local repo="$1" author="$2"
  # The pulls endpoint reflects a new PR immediately; `gh pr list --author`
  # goes through search and can lag behind the tick the drill is measuring.
  gh api "repos/$repo/pulls?state=open&per_page=100" --paginate \
    | jq -s --arg author "$author" \
      '[add[] | select(.user.login == $author) | {number, body}]'
}

rehearsal_builder_slot_prs() {
  local repo="$1" author="$2" pulls_json
  pulls_json="$(rehearsal_builder_open_prs_json "$repo" "$author")" || return
  rehearsal_builder_slot_prs_from_json "$pulls_json"
}

rehearsal_builder_pr_for_issue() {
  local repo="$1" author="$2" issue="$3" pulls_json
  pulls_json="$(rehearsal_builder_open_prs_json "$repo" "$author")" || return
  rehearsal_builder_pr_for_issue_from_json "$issue" "$pulls_json"
}

rehearsal_fixture_record_issue() {
  local repo="$1" issue="$2"
  if [ -n "${REHEARSAL_FIXTURE_REPO:-}" ] \
      && [ "$REHEARSAL_FIXTURE_REPO" != "$repo" ]; then
    echo "teardown: refusing to mix fixture repositories: $REHEARSAL_FIXTURE_REPO and $repo" >&2
    return 1
  fi
  REHEARSAL_FIXTURE_REPO="$repo"
  case " ${REHEARSAL_FIXTURE_ISSUES:-} " in
    *" $issue "*) ;;
    *) REHEARSAL_FIXTURE_ISSUES="${REHEARSAL_FIXTURE_ISSUES:+$REHEARSAL_FIXTURE_ISSUES }$issue" ;;
  esac
}

rehearsal_fixture_record_pr() {
  local repo="$1" pr="$2"
  if [ -n "${REHEARSAL_FIXTURE_REPO:-}" ] \
      && [ "$REHEARSAL_FIXTURE_REPO" != "$repo" ]; then
    echo "teardown: refusing to mix fixture repositories: $REHEARSAL_FIXTURE_REPO and $repo" >&2
    return 1
  fi
  REHEARSAL_FIXTURE_REPO="$repo"
  case " ${REHEARSAL_FIXTURE_PRS:-} " in
    *" $pr "*) ;;
    *) REHEARSAL_FIXTURE_PRS="${REHEARSAL_FIXTURE_PRS:+$REHEARSAL_FIXTURE_PRS }$pr" ;;
  esac
}

rehearsal_fixture_record_builder_issue() {
  local repo="$1" author="$2" issue="$3"
  if [ -n "${REHEARSAL_FIXTURE_BUILDER_AUTHOR:-}" ] \
      && [ "$REHEARSAL_FIXTURE_BUILDER_AUTHOR" != "$author" ]; then
    echo "teardown: refusing to mix fixture builder authors: $REHEARSAL_FIXTURE_BUILDER_AUTHOR and $author" >&2
    return 1
  fi
  rehearsal_fixture_record_issue "$repo" "$issue" || return
  REHEARSAL_FIXTURE_BUILDER_AUTHOR="$author"
  case " ${REHEARSAL_FIXTURE_BUILDER_ISSUES:-} " in
    *" $issue "*) ;;
    *) REHEARSAL_FIXTURE_BUILDER_ISSUES="${REHEARSAL_FIXTURE_BUILDER_ISSUES:+$REHEARSAL_FIXTURE_BUILDER_ISSUES }$issue" ;;
  esac
}

rehearsal_fixture_record_branch() {
  local repo="$1" branch="$2"
  if [ -n "${REHEARSAL_FIXTURE_REPO:-}" ] \
      && [ "$REHEARSAL_FIXTURE_REPO" != "$repo" ]; then
    echo "teardown: refusing to mix fixture repositories: $REHEARSAL_FIXTURE_REPO and $repo" >&2
    return 1
  fi
  REHEARSAL_FIXTURE_REPO="$repo"
  case " ${REHEARSAL_FIXTURE_BRANCHES:-} " in
    *" $branch "*) ;;
    *) REHEARSAL_FIXTURE_BRANCHES="${REHEARSAL_FIXTURE_BRANCHES:+$REHEARSAL_FIXTURE_BRANCHES }$branch" ;;
  esac
}

rehearsal_assert_reuse_sandbox_clean() {
  local reuse="$1" repo="$2" reuse_objects
  [ "$reuse" -eq 1 ] || return 0
  if ! reuse_objects="$(rehearsal_open_sandbox_objects "$repo")"; then
    echo "phase 2: cannot inspect $repo before --reuse" >&2
    return 1
  fi
  if [ -n "$reuse_objects" ]; then
    echo "phase 2: REFUSING --reuse because $repo is not clean:" >&2
    printf '  %s\n' "$reuse_objects" >&2
    echo "close or remove these objects before re-running; this round deletes only fixtures it records itself" >&2
    return 1
  fi
}

# A builder checkout needs a head repository owned by the identity inside the
# box.  The sandbox belongs to the host identity, so being its collaborator is
# not enough: ensure_main_clone deliberately refuses to invent a push target.
# Read the upstream's direct-fork endpoint rather than guessing GitHub's name;
# an unrelated repository may make GitHub choose crew-drill-builder-1.
rehearsal_builder_forks() { # <sandbox> <box-identity>
  local repo="$1" owner="$2"
  gh api --paginate "repos/$repo/forks?per_page=100" \
    | jq -sr --arg owner "$owner" '
        add
        | .[]
        | select(.owner.login == $owner)
        | .full_name'
}

rehearsal_resolve_builder_fork() { # <sandbox> <box-identity>
  local repo="$1" owner="$2" matches count
  if ! matches="$(rehearsal_builder_forks "$repo" "$owner")"; then
    echo "builder: cannot inspect forks of $repo" >&2
    return 1
  fi
  count="$(awk 'NF { n++ } END { print n+0 }' <<<"$matches")"
  case "$count" in
    1) awk 'NF { print; exit }' <<<"$matches" ;;
    0)
      echo "builder: no fork of $repo is owned by box identity $owner" >&2
      return 1 ;;
    *)
      echo "builder: $count forks of $repo are owned by box identity $owner; refusing ambiguity:" >&2
      while read -r fork; do [ -n "$fork" ] && echo "  $fork" >&2; done <<<"$matches"
      return 1 ;;
  esac
}

rehearsal_create_builder_fork() { # <sandbox>
  local repo="$1"
  bx "gh api -X POST 'repos/$repo/forks' --jq .full_name"
}

rehearsal_open_sandbox_objects() {
  local repo="$1"
  gh api "repos/$repo/issues?state=open&per_page=100" --paginate \
    | jq -sr 'add[] | (if has("pull_request") then "pull" else "issue" end)
      + " #" + (.number | tostring) + " — " + .title'
}

rehearsal_cleanup_owned_fixtures() {
  local repo="${REHEARSAL_FIXTURE_REPO:-}" pr issue branch failed=0
  local pull_json pulls_json head_repo head_ref
  [ -n "$repo" ] || return 0

  if [ -n "${REHEARSAL_FIXTURE_BUILDER_ISSUES:-}" ]; then
    if pulls_json="$(rehearsal_builder_open_prs_json \
        "$repo" "${REHEARSAL_FIXTURE_BUILDER_AUTHOR:-}")"; then
      for issue in $REHEARSAL_FIXTURE_BUILDER_ISSUES; do
        while read -r pr; do
          [ -n "$pr" ] && rehearsal_fixture_record_pr "$repo" "$pr"
        done < <(rehearsal_builder_prs_for_issue_from_json "$issue" "$pulls_json")
      done
    else
      echo "teardown: WARNING — could not discover the owned builder fixture PR" >&2
      failed=1
    fi
  fi

  for pr in ${REHEARSAL_FIXTURE_PRS:-}; do
    [ -n "$pr" ] || continue
    pull_json="$(gh api "repos/$repo/pulls/$pr")" || {
      echo "teardown: WARNING — could not inspect owned fixture PR #$pr" >&2
      failed=1
      pull_json='{}'
    }
    head_repo="$(jq -r '.head.repo.full_name // ""' <<<"$pull_json")"
    head_ref="$(jq -r '.head.ref // ""' <<<"$pull_json")"
    if gh api -X PATCH "repos/$repo/pulls/$pr" -f state=closed >/dev/null; then
      echo "teardown: closed owned fixture PR #$pr"
    else
      echo "teardown: WARNING — could not close owned fixture PR #$pr" >&2
      failed=1
    fi
    if [ "$head_repo" = "$repo" ] && [ -n "$head_ref" ]; then
      rehearsal_fixture_record_branch "$repo" "$head_ref"
    fi
  done
  for branch in ${REHEARSAL_FIXTURE_BRANCHES:-}; do
    [ -n "$branch" ] || continue
    if gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null; then
      echo "teardown: deleted owned fixture branch $branch"
    else
      echo "teardown: WARNING — could not delete owned fixture branch $branch" >&2
      failed=1
    fi
  done
  for issue in ${REHEARSAL_FIXTURE_ISSUES:-}; do
    [ -n "$issue" ] || continue
    if gh api -X PATCH "repos/$repo/issues/$issue" -f state=closed >/dev/null; then
      echo "teardown: closed owned fixture issue #$issue"
    else
      echo "teardown: WARNING — could not close owned fixture issue #$issue" >&2
      failed=1
    fi
  done

  if [ "$failed" -eq 0 ]; then
    REHEARSAL_FIXTURE_REPO=""
    REHEARSAL_FIXTURE_PRS=""
    REHEARSAL_FIXTURE_ISSUES=""
    REHEARSAL_FIXTURE_BRANCHES=""
    REHEARSAL_FIXTURE_BUILDER_AUTHOR=""
    REHEARSAL_FIXTURE_BUILDER_ISSUES=""
  fi
  return "$failed"
}

rehearsal_builder_fixture_panel_content() {
  local author="$1" reviewer="$2"
  printf 'panel[%s]=%s\n' "$author" "$reviewer"
}

rehearsal_install_builder_fixture_panel() {
  local repo="$1" author="$2" reviewer="$3" path=.github/labels.conf
  local content current_sha=""
  content="$(rehearsal_builder_fixture_panel_content "$author" "$reviewer")"
  current_sha="$(gh api "repos/$repo/contents/$path" --jq .sha 2>/dev/null || true)"
  if [ -n "$current_sha" ]; then
    gh api -X PUT "repos/$repo/contents/$path" \
      -f message="drill: set builder fixture panel" \
      -f content="$(printf '%s' "$content" | base64 -w0)" \
      -f sha="$current_sha" >/dev/null
  else
    gh api -X PUT "repos/$repo/contents/$path" \
      -f message="drill: set builder fixture panel" \
      -f content="$(printf '%s' "$content" | base64 -w0)" >/dev/null
  fi
}

rehearsal_builder_is_draft_from_json() {
  jq -e '.draft == true' >/dev/null <<<"$1"
}

rehearsal_builder_head_is_from_json() {
  local expected="$1" pull_json="$2"
  jq -e --arg expected "$expected" '.head.sha == $expected' \
    >/dev/null <<<"$pull_json"
}

rehearsal_builder_has_answer_signal_from_json() {
  local mark="$1" author="$2" head="$3" after="$4" comments_json="$5"
  jq -e \
    --arg mark "$mark" --arg author "$author" --arg head "$head" \
    --arg after "$after" '
    any(.[];
      .user.login == $author
      and (.created_at // "") > $after
      and ((.body // "") | startswith($mark))
      and (((.body // "") | ltrimstr($mark)
        | try capture("(?<sha>[0-9a-f]{40})").sha catch "") == $head)
    )
  ' >/dev/null <<<"$comments_json"
}

rehearsal_builder_check_state_from_json() {
  local context="$1" status_json="$2"
  jq -r --arg context "$context" '
    [(.statuses // [])[] | select(.context == $context)]
    | sort_by(.created_at)
    | last
    | .state // ""
  ' <<<"$status_json"
}

rehearsal_builder_requested_from_json() {
  local reviewer="$1" requested_json="$2"
  jq -e --arg reviewer "$reviewer" \
    'any((.users // [])[]; .login == $reviewer)' >/dev/null <<<"$requested_json"
}

rehearsal_builder_pr_is_draft() {
  local repo="$1" pr="$2" pull_json
  pull_json="$(gh api "repos/$repo/pulls/$pr")" || return
  rehearsal_builder_is_draft_from_json "$pull_json"
}

rehearsal_builder_head_is() {
  local repo="$1" pr="$2" expected="$3" pull_json
  pull_json="$(gh api "repos/$repo/pulls/$pr")" || return
  rehearsal_builder_head_is_from_json "$expected" "$pull_json"
}

rehearsal_builder_has_answer_signal() {
  local repo="$1" pr="$2" mark="$3" author="$4" head="$5" after="$6" comments_json
  comments_json="$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate | jq -s 'add')" || return
  rehearsal_builder_has_answer_signal_from_json \
    "$mark" "$author" "$head" "$after" "$comments_json"
}

rehearsal_builder_check_state() {
  local repo="$1" head="$2" context="$3" status_json
  status_json="$(gh api "repos/$repo/commits/$head/status")" || return
  rehearsal_builder_check_state_from_json "$context" "$status_json"
}

rehearsal_builder_requested() {
  local repo="$1" pr="$2" reviewer="$3" requested_json
  requested_json="$(gh api "repos/$repo/pulls/$pr/requested_reviewers")" || return
  rehearsal_builder_requested_from_json "$reviewer" "$requested_json"
}

rehearsal_builder_not_requested() {
  local repo="$1" pr="$2" reviewer="$3" requested_json
  requested_json="$(gh api "repos/$repo/pulls/$pr/requested_reviewers")" || return
  ! rehearsal_builder_requested_from_json "$reviewer" "$requested_json"
}

rehearsal_set_builder_head_status() {
  local repo="$1" head="$2" context="$3" state="$4" description="$5"
  gh api "repos/$repo/statuses/$head" \
    -f state="$state" -f context="$context" \
    -f description="$description" >/dev/null
}

rehearsal_builder_signal_window_from_json() {
  local mark="$1" author="$2" head="$3" after="$4" context="$5" comments_json="$6" status_json="$7" state
  if ! rehearsal_builder_has_answer_signal_from_json \
      "$mark" "$author" "$head" "$after" "$comments_json"; then
    printf 'waiting\n'
    return 0
  fi
  state="$(rehearsal_builder_check_state_from_json "$context" "$status_json")"
  if [ "$state" = pending ]; then
    printf 'caught\n'
  else
    printf 'closed:%s\n' "${state:-no-status}"
  fi
}

rehearsal_wait_builder_signal_window() {
  local seconds="$1" repo="$2" pr="$3" mark="$4" author="$5" head="$6" after="$7" context="$8"
  local end=$((SECONDS + seconds)) comments_json status_json result
  while [ "$SECONDS" -lt "$end" ]; do
    comments_json="$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate | jq -s 'add')" || comments_json='[]'
    status_json="$(gh api "repos/$repo/commits/$head/status")" || status_json='{"statuses":[]}'
    result="$(rehearsal_builder_signal_window_from_json \
      "$mark" "$author" "$head" "$after" "$context" "$comments_json" "$status_json")"
    case "$result" in
      caught)
        ok "builder: round answer is signalled while head check is pending"
        return 0 ;;
      closed:*)
        skip "builder: pending-check signal window closed before it could be observed (check ${result#closed:}); round answer signal was present"
        return 0 ;;
    esac
    sleep 10
  done
  fail "builder: round answer is signalled while head check is pending (timeout ${seconds}s)"
  return 1
}

rehearsal_wait_builder_signal_window_with_prereqs() {
  local mark="$4" after="$7"
  if [ -z "$mark" ]; then
    skip "builder: round answer signal window unavailable (installed answer mark unresolved)"
    return 0
  fi
  if [ -z "$after" ]; then
    skip "builder: round answer signal window unavailable (changes-requested review boundary unresolved)"
    return 0
  fi
  rehearsal_wait_builder_signal_window "$@"
}

rehearsal_report_missing_builder_pr() {
  skip "builder: initial PR is ready for its fixture panel"
  skip "builder: host reviewer requested for initial round"
  skip "builder: installed round-answer mark resolves"
  skip "builder: host changes-requested review submitted"
  skip "builder: pending head status established"
  skip "builder: changes-requested round returns PR to draft"
  skip "builder: round answer is signalled while head check is pending"
  skip "builder: fix round kept the fixture head stable"
  skip "builder: panel request withheld while head check is pending"
  skip "builder: settled head status established"
  skip "builder: panel request issued after head settles"
}

rehearsal_report_occupied_builder_slot() {
  local author="$1"
  fail "builder: opened a PR for the ready issue"
  fail "builder: PR authored by $author for this run's fixture issue"
  skip "builder fixture is unassigned (ready+assigned is not pickable)"
  skip "builder: PR branch is build/*"
  skip "builder: issue moved off ready (claimed)"
  skip "builder: no duplicate PR on re-tick"
  skip "builder: fixture panel names the host reviewer"
  skip "builder: initial PR is ready for its fixture panel"
  skip "builder: host reviewer requested for initial round"
  skip "builder: installed round-answer mark resolves"
  skip "builder: host changes-requested review submitted"
  skip "builder: pending head status established"
  skip "builder: changes-requested round returns PR to draft"
  skip "builder: round answer is signalled while head check is pending"
  skip "builder: fix round kept the fixture head stable"
  skip "builder: panel request withheld while head check is pending"
  skip "builder: settled head status established"
  skip "builder: panel request issued after head settles"
}
