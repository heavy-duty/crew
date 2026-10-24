# duty-triage.sh — the triage wake signals, per repo in repos.txt, in the
# order they run:
#   (d) unread mentions (one tick-wide session, and it goes FIRST)
#   (a) needs-triage issues        (b) queue-unlabeled strays
#   (c) discussions without my voice
#   (e) blocked issues whose named blockers all landed (a LEAD, not a verdict)
#   (f) declared predecessors whose state changed (a LEAD, not a verdict)
#
# The board poll follows the mention session because that session can run for
# TIMEOUT_MENTION (25 minutes) and can itself change the board: polled first,
# the launch decision is made on a snapshot up to 25 minutes stale, which
# spends a triage session on leads that died mid-session and defers a signal
# born during it by a full tick (#253).
#
# Architectural spine (dan-claude-bot): this module only ever WAKES a
# session — it never edits a label itself. A parser bug becomes a false lead
# the session rejects, not a wrong board write. Every signal is fail-safe:
# (e)'s unknown blocker counts as still-open — a cross-repo one included,
# since it parses keyed by its whole token and no local state map resolves
# it (#632) — and the hourly hygiene sweep is the unconditional backstop for
# anything detection misses.
#
# Every board read is isolated per signal per repo: one transient API failure
# degrades to a logged skip, never an aborted tick (the old duty.sh died
# mid-queue on the first failure, silently skipping every later repo). The
# notifications read is deliberately tick-wide: one snapshot feeds every repo.
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended

# The selector is lib/jq/discussions.jq (#757 D8): a thread wakes triage when
# its last word is not triage's own, or when triage's own last word carries a
# `returns on <date>` that has arrived. Bodies and timestamps are fetched for
# that; the old query read logins only and could not see a promise at all.
_triage_discussion_items() {  # _triage_discussion_items REPO OWNER NAME
  local repo="$1" owner="$2" name="$3"
  TR_ME="$ME" TR_R="$repo" TR_TODAY="$(date -u +%Y-%m-%d)" \
    gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        discussions(first:50,states:OPEN){
          nodes{ number updatedAt
            comments(last:50){ nodes{ author{ login } body createdAt
              replies(last:20){ nodes{ author{ login } body createdAt } } } } }
        }
      }
    }' --jq "$(cat "$DUTY_DIR/lib/jq/discussions.jq")"
}

_triage_unblockable_items() {  # _triage_unblockable_items REPO BLOCKED_JSON NUMSTATES
  local repo="$1" blocked_json="$2" numstates="$3" numbers
  numbers="$(jq -r --argjson S "$numstates" -f "$DUTY_DIR/lib/jq/blockers.jq" \
    <<<"$blocked_json" 2>/dev/null)" || return 1
  jq -r --arg repo "$repo" --arg numbers "$numbers" '
    ($numbers | split(",")) as $due
    | .[]
    | select((.number | tostring) as $number | $due | index($number))
    | "\($repo)#\(.number) \(.updatedAt)"
  ' <<<"$blocked_json" 2>/dev/null
}

_triage_graph_edges() {  # _triage_graph_edges REPO ISSUES_JSON
  local repo="$1" issues_json="$2"
  jq -c --arg repo "$repo" '
    # Keep byte-identical with lib/jq/blockers.jq: signal (e) and signal (f)
    # deliberately recognize the same declaration grammar.
    def blockers:
      def mask: if test("\\([^()]*\\)") then gsub("\\((?<p>[^()]*)\\)"; "[" + (.p | gsub("[.;](?=\\s|$)"; ",")) + "]") | mask else . end; mask
      | gsub("\\((?<p>[^()\\n]*)(?=\\n|$)"; "[" + (.p | gsub("[.;](?=[ \\t])"; ",")) + "]")
      | [ match("(?<![`\"])[Bb]locked by((?:[^.;]|[.;](?=[A-Za-z0-9]))*)"; "g").captures[0].string ] | join(" ")
      | [ scan("(?:^|[^A-Za-z0-9_/.-])((?:[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+#[0-9]+|#([0-9]+))") | .[1] // .[0] ];
    [ .[] as $issue
      | (($issue.body // "") | blockers[]) as $predecessor
      | {edge:"\($repo)#\($issue.number)#\($predecessor)", predecessor:$predecessor} ]
  ' <<<"$issues_json" 2>/dev/null
}

_triage_graph_items() {  # _triage_graph_items EDGES_JSON NUMSTATES
  local edges_json="$1" numstates="$2"
  jq -r --argjson S "$numstates" '
    .[]
    | ($S[.predecessor] // "UNKNOWN") as $state
    | select($state == "OPEN" or $state == "CLOSED" or $state == "MERGED")
    | "\(.edge) \($state)"
  ' <<<"$edges_json" 2>/dev/null
}

_triage_graph_changes() {  # _triage_graph_changes LEDGER; stdin: EDGE STATE
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN {
      while ((getline line < L) > 0) {
        n=split(line,a," "); if (n>=2) seen[a[1]]=a[2]
      }
      close(L)
    }
    NF>=2 {
      before = ($1 in seen) ? seen[$1] : "UNSEEN"
      if (before != $2) print $1, before, $2
    }
  '
}

_triage_graph_commit() {  # _triage_graph_commit; stdin: EDGE STATE
  local ledger="$DUTY_DIR/.seen-graph" tmp
  tmp="$(mktemp "${ledger}.XXXXXX")"
  awk -v L="$ledger" '
    BEGIN {
      while ((getline line < L) > 0) {
        n=split(line,a," "); if (n>=2) seen[a[1]]=a[2]
      }
      close(L)
    }
    NF>=2 { seen[$1]=$2 }
    END { for (edge in seen) print edge, seen[edge] }
  ' >"$tmp"
  mv -f "$tmp" "$ledger"
}

_triage_signal_numbers() {  # stdin: REPO#NUMBER UPDATED_AT
  awk 'NF {
    number=$1; sub(/^.*#/, "#", number)
    numbers = numbers separator number; separator=", "
  } END { print numbers }'
}

# --- #503: round count as sizing evidence, in front of triage ---------------
#
# Doctrine names round growth as evidence for the NEXT mint (`TRIAGE.md`
# `## Sizing`, ceremony#419), and the cap it is read against is five. The engine
# already counts rounds, but only in the shape D1 calls insufficient:
# `_round_cap_census` in duty-builder.sh, per PR, over OPEN authored PRs, and
# interesting exactly when one stalls. This is the other reading of the same
# number — per issue, over the whole history, as a distribution — put in front
# of the agent that makes the sizing judgement.
#
# IT IS CONTEXT, NOT A SIGNAL, AND THAT IS THE POINT OF D4. "No automatic
# action. This surfaces evidence." A wake IS an action: it spends a model
# session. And a distribution moves whenever any PR anywhere gains a round, so
# as a wake it would re-fire on an unchanged board every tick forever — #59's
# defect exactly, on a signal that can never clear itself because there is
# nothing for a session to DO about it. So this runs only where a triage session
# is ALREADY launching, below the `signals` early return: a quiet tick pays
# nothing, and every tick that could act on the evidence carries it.
#
# It writes no label, opens and closes nothing, and gates no dispatch. Its only
# effect on the tick is one prompt slot.
#
# COST, MEASURED RATHER THAN CHARACTERISED. One paginated GraphQL call per page
# of PRs, per triage SESSION — not per tick; a quiet tick makes no call at all
# and triage503-quiet-tick-reads-no-rounds pins that. Against heavy-duty/crew in
# August 2026 that is 5 pages, 3,241,721 bytes, ~16 seconds, and it is re-fetched
# in full each session with nothing cached between them.
#
# THAT FIGURE GROWS WITH BOARD HISTORY AND NOTHING BOUNDS IT, which is stated
# here rather than hidden because it is a real property of asking for the whole
# history — and D5 requires the whole history, since "history is included, or the
# first reading is meaningless". Closed PRs are in the query for that reason. The
# bulk of the bytes is PR bodies, which the attribution needs and GraphQL cannot
# truncate, so there is no field to drop; the cheap win available was the fold,
# which is now one pass rather than one per page (see the loop). If a board ever
# outgrows GraphQL's query-timeout budget the read fails CLOSED — the evidence is
# discarded, the session runs on the signals that woke it — which is why this is
# a documented cost and not a correctness risk.
#
# A FETCH FAILURE COSTS THE EVIDENCE AND NOTHING ELSE. Every warn returns with
# ROUND_COUNT_EVIDENCE empty, the fragment is omitted, and the session runs on
# the signals that woke it. Sizing evidence is an input to a human-grade
# judgement, and a partial distribution would be a wrong one presented as
# measured — so a page that fails discards the read rather than reporting a
# board that is missing its oldest PRs.
ROUND_COUNT_EVIDENCE=""

# _triage_round_count REPO — set ROUND_COUNT_EVIDENCE to the rendered fragment.
#
# THE ISSUE PATTERN IS duty-builder.sh's `_RESUME_ISSUE_RE`, referenced and not
# restated. That constant's own header gives the reason: "a second copy of a
# regex whose every clause was bought by a named failure is a second thing to
# keep true, and the drift would be silent — both copies parse, and only one of
# them is right" (#479). Reaching across duty modules for it is deliberate and
# safe: bin/duty.sh sources all four unconditionally, before any role dispatch,
# so the constant is defined on a triage-only box too — pinned by a case in
# shared/test/triage.sh so a later reordering cannot silently empty it.
#
# THE CAP IS READ FROM round-cap.jq, never restated here. "THE CAP IS A LITERAL
# HERE AND NOWHERE ELSE" (#502 D1), so the distribution is read against five by
# asking the program that owns the five, on an empty payload.
_triage_round_count() {
  local repo="$1" owner name cursor="" page nodes measured
  local pages="" all evidence rows shown stats total cap
  local -a after=()
  ROUND_COUNT_EVIDENCE=""
  owner="${repo%%/*}"; name="${repo##*/}"

  # Refused rather than defaulted. An empty pattern attributes every PR to no
  # issue, which does not fail — it reports a board where nothing has ever taken
  # a round, and that reads as a measurement rather than as a missing module.
  if [ -z "${_RESUME_ISSUE_RE:-}" ]; then
    warn "$repo: round-count evidence skipped (the issue pattern is unset; is duty-builder.sh sourced?)"
    return 0
  fi
  cap="$(printf '{}' \
    | jq -L "$DUTY_DIR/lib/jq" --argjson panel '[]' \
        -f "$DUTY_DIR/lib/jq/round-cap.jq" 2>/dev/null \
    | jq -r '.cap // empty' 2>/dev/null)"
  if [ -z "$cap" ]; then
    warn "$repo: round-count evidence skipped (the round cap could not be read)"
    return 0
  fi

  while :; do
    # `-F after=null` is a JSON null on the first page; `-f` sends a string on
    # every page after it. An empty STRING is not a cursor, so the two forms are
    # not interchangeable and the first page cannot use `-f`.
    if [ -z "$cursor" ]; then after=(-F after=null); else after=(-f after="$cursor"); fi
    if ! page="$(gh api graphql -f owner="$owner" -f name="$name" "${after[@]}" -f query='
      query($owner:String!,$name:String!,$after:String){
        repository(owner:$owner,name:$name){
          pullRequests(first:'"$OPERATING_LIMIT_GITHUB_PR_PAGE"',
                       states:[OPEN,CLOSED,MERGED],
                       orderBy:{field:CREATED_AT,direction:DESC},
                       after:$after){
            pageInfo{ hasNextPage endCursor }
            nodes{
              number body
              commits(last:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){
                totalCount nodes{ commit{ oid committedDate } } }
              reviews(first:'"$OPERATING_LIMIT_GITHUB_CONNECTION_NODES"'){
                totalCount nodes{ author{ login } state commit{ oid } submittedAt } }
            }
          }
        }
      }' 2>/dev/null)"; then
      warn "$repo: round-count fetch failed; no sizing evidence this session"
      return 0
    fi
    if ! nodes="$(printf '%s' "$page" \
        | jq -c '.data.repository.pullRequests.nodes // []' 2>/dev/null)"; then
      warn "$repo: round-count parse failed; no sizing evidence this session"
      return 0
    fi
    # The same overflow assessment _round_cap_census makes, for the same reason:
    # a PR whose review or commit history is longer than the unpaginated window
    # is counted short, and a distribution built on a silently short count is
    # the misreport this evidence exists to prevent.
    measured="$(printf '%s' "$nodes" | jq -r '
      [ .[] | .commits.totalCount, .reviews.totalCount ] | map(. // 0) | max // 0' 2>/dev/null)" \
      || measured=invalid
    if ! operating_limit_assess github_connection_nodes "$measured" "$repo" "" \
        'round-count history exceeds its unpaginated GraphQL window'; then
      return 0
    fi
    # THE PAGES DO NOT TRAVEL ON ARGV (#479, and round 1 of #503). This line
    # accumulated with `--argjson a "$all" --argjson b "$nodes"`, which makes
    # each JSON value ONE argv element — and a single element is bounded by
    # MAX_ARG_STRLEN, 131,072 bytes, not by the ARG_MAX everyone quotes. Crew's
    # own first page of fifty PRs is ~1.10 MB of `nodes`, eight times the limit,
    # so `execve` failed with E2BIG on the FIRST page of every real board: the
    # fetch succeeded, the fold did not, and the branch below warned and
    # returned with no evidence. It failed the same way every session, on inputs
    # that only ever grow, and it failed QUIETLY — one warn, the fragment
    # omitted, the session launching normally. A green suite read as coverage
    # because every fixture was one small page.
    #
    # So the pages are APPENDED, one compact array per line, and folded once
    # after the loop through a pipe. `printf` is a shell builtin, so the payload
    # is never a process argument at any size — the same reason the reads below
    # send `$all` down a pipe rather than passing it. The alternative remedy,
    # `--slurpfile` from a process substitution (_resume_attach_comments, and
    # the header at duty-builder.sh:1338 that named it), fixes the same bound;
    # this shape is preferred here because the fold also stops being quadratic.
    # The `--argjson` form re-serialised and re-parsed the ENTIRE accumulated
    # history once per page — five pages of crew is ~10 MB of jq parsing to
    # build 3.2 MB — where one fold reads each page exactly once.
    pages="$pages$nodes"$'\n'
    [ "$(printf '%s' "$page" \
      | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' 2>/dev/null)" = true ] || break
    cursor="$(printf '%s' "$page" \
      | jq -r '.data.repository.pullRequests.pageInfo.endCursor // empty' 2>/dev/null)"
    [ -n "$cursor" ] || break
  done

  # The one fold. It is still a local deterministic operation on values already
  # in hand, so a failure here is structural rather than transient — but the
  # answer stays the same as the per-page branch it replaces, and for the reason
  # this module's header gives: a partial distribution presented as measured is
  # a worse output than no evidence at all, so the read is discarded whole.
  all="$(printf '%s' "$pages" | jq -c -s 'add // []' 2>/dev/null)" || all="" # Decision-path empty fallback: the next branch warns and discards the read whole.
  if [ -z "$all" ]; then
    warn "$repo: round-count accumulate failed; no sizing evidence this session"
    return 0
  fi

  if ! evidence="$(printf '%s' "$all" \
      | jq -c -L "$DUTY_DIR/lib/jq" --arg re "$_RESUME_ISSUE_RE" --argjson cap "$cap" \
          -f "$DUTY_DIR/lib/jq/round-count.jq" 2>/dev/null)"; then
    warn "$repo: round-count eval failed; no sizing evidence this session"
    return 0
  fi
  # Gated on there being an ISSUE to report, not on the distribution being
  # non-empty: a board whose only PRs are still unreviewed has an empty
  # distribution and rows worth rendering, and gating on the distribution would
  # withhold the evidence from exactly the young board that has the least of it.
  total="$(printf '%s' "$evidence" | jq -r '.issues | length' 2>/dev/null || echo 0)"
  [ "$total" -gt 0 ] || return 0

  # EVERY ISSUE GETS ITS ROW, and the criterion is why: "each issue's PR round
  # count is readable by the triage duty". A bound would have been comfortable —
  # sorted descending, the tail it dropped would be the low-round issues that
  # teach least — but the distribution alone cannot answer "how many rounds did
  # #482 take", which is the lookup a sizing judgement actually makes. One short
  # line per issue is what that costs, and the board's own size is its bound.
  # Sorted by count descending so the outlier D3's example is about reads first.
  # An issue whose PR has taken no rounds yet gets its row too, at 0. It is held
  # out of the MEDIAN for the reason the program's header gives, and that is a
  # statement about the arithmetic and not about what triage may see — leaving it
  # off the list would make "each issue's count is readable" false for exactly
  # the issues a sizing judgement is most likely to be made about.
  rows="$(printf '%s' "$evidence" | jq -r '
    .issues[]
    | "  - #\(.issue): \(.rounds) round(s) over \(.prs | length) PR(s) — "
      + (.prs | map("#\(.)") | join(", "))' 2>/dev/null)"
  shown="$(printf '%s\n' "$rows" | awk 'NF{c++} END{print c+0}')"
  # STATS is built into its own variable rather than inline. render_prompt call
  # sites are parsed by a suite guard that folds a call to one logical line and
  # reads to its first `)`, so a nested $(jq …) — whose program is full of them —
  # hides every slot written after it, and the slot goes unsupplied in
  # production exactly as invisibly.
  stats="$(printf '%s' "$evidence" | jq -r --argjson cap "$cap" '
    .distribution
    | "\(.issues) issue(s) with at least one round; min \(.min), median \(.median), "
      + "max \(.max); \(.at_or_over_cap) at or over the cap of \($cap); "
      + "\(.pending) issue(s) with a PR but no round yet; "
      + "\(.unattributed) PR(s) naming no issue."' 2>/dev/null)"
  ROUND_COUNT_EVIDENCE="$(render_prompt fragment-round-count.txt \
    ROWS="$rows" SHOWN="$shown" STATS="$stats" CAP="$cap")"
  return 0
}

duty_triage() {
  local R notification_pages all_mentions repo_json fresh_threads fresh_json fresh_mentions
  local keep_threads keep_json mentions mcount mention_rc
  local -a repos=()
  mapfile -t repos < <(read_repo_list "$REPOS_FILE")

  # (d) unread mentions — one notifications snapshot and one session for the
  # whole tick. A discussion's `author` and `comment` notifications count too
  # (#757 D8): a human answering a thread triage opened arrives as `author`,
  # not `mention`, and was dropped — five of ten non-mention rows on
  # 2026-09-03 were exactly that shape. The session remains first, so every per-repo board poll below
  # observes changes made while answering a mention (#253).
  all_mentions='[]'
  repo_json="$(printf '%s\n' "${repos[@]}" | awk 'NF' | jq -R . | jq -cs .)"
  if [ "${#repos[@]}" -eq 0 ]; then
    :
  elif notification_pages="$(gh api notifications --paginate 2>/dev/null)" &&
     all_mentions="$(printf '%s\n' "$notification_pages" | jq -c -s --argjson repos "$repo_json" '
       (add // [])
       | [ .[]
           | select((.reason == "mention" or .reason == "team_mention"
                     or ((.subject.type // "") == "Discussion"
                         and (.reason == "author" or .reason == "comment")))
                    and (.repository.full_name as $repo | $repos | index($repo)))
           | {repo: .repository.full_name, thread: .id,
              subject: .subject.url, updated: .updated_at} ]
     ' 2>/dev/null)"; then
    :
  else
    warn "notifications probe failed; mention wake skipped this tick"
    all_mentions='[]'
  fi
  fresh_threads="$(printf '%s\n' "$all_mentions" \
    | jq -r '.[] | "\(.thread) \(.updated)"' 2>/dev/null \
    | ledger_filter "$DUTY_DIR/.seen-mentions")"
  if [ -n "$fresh_threads" ]; then
    fresh_json="$(printf '%s\n' "$fresh_threads" | awk 'NF { print $1 }' | jq -R . | jq -cs .)"
    fresh_mentions="$(jq -c --argjson fresh "$fresh_json" \
      '[ .[] | select(.thread as $thread | $fresh | index($thread)) ]' <<<"$all_mentions")"
  else
    fresh_mentions='[]'
  fi
  keep_threads="$(printf '%s\n' "$fresh_threads" \
    | awk -v ceiling="$MENTION_THREAD_CEILING" 'NF && selected < ceiling {
        print $1; selected++
      }')"
  if [ -n "$keep_threads" ]; then
    keep_json="$(printf '%s\n' "$keep_threads" | jq -R . | jq -cs .)"
    mentions="$(jq -c --argjson keep "$keep_json" \
      '[ .[] | select(.thread as $thread | $keep | index($thread)) ]' <<<"$all_mentions")"
  else
    mentions='[]'
  fi
  mcount="$(jq 'length' <<<"$mentions" 2>/dev/null || echo 0)"
  if [ "$mcount" -gt 0 ]; then
    log "fleet: ${mcount} unread mention(s) — launching one mention session"
    RUN_SESSION_RC=1
    run_session mention fleet "$DUTY_DIR" "$TIMEOUT_MENTION" \
      "$(render_prompt mention.txt ME="$ME" MENTIONS="$mentions")"
    mention_rc="${RUN_SESSION_RC:-1}"
    # One transaction for the batch: a crash or timeout commits none, so every
    # thread retries next tick. The ceiling's remainder was never selected and
    # therefore remains uncommitted too.
    if [ "$mention_rc" -eq 0 ]; then
      printf '%s\n' "$mentions" | jq -r '.[] | "\(.thread) \(.updated)"' \
        | ledger_commit "$DUTY_DIR/.seen-mentions"
    fi
  fi

  for R in "${repos[@]}"; do
    _triage_repo "$R" \
      "$(jq --arg repo "$R" '[.[] | select(.repo == $repo)] | length' \
        <<<"$fresh_mentions" 2>/dev/null || echo 0)" \
      "$(jq --arg repo "$R" '[.[] | select(.repo == $repo)] | length' \
        <<<"$mentions" 2>/dev/null || echo 0)"
  done
}

_triage_repo() {
  local R="$1"
  local mention_count="${2:-0}"
  local selected_mention_count="${3:-0}"
  local owner="${R%%/*}" name="${R##*/}"
  local signals="" nt stray undisc unblockable="" graph_changes="" dir prompt
  local fresh_nt="" fresh_stray="" fresh_discussions=""

  # (a) and (b) are BOARD-STATE signals, and both are enumerated rather than
  # counted so they can be compared against what a previous session already
  # looked at. A count cannot be: it says how many, never which, so an issue a
  # session correctly DECLINED to label re-fired a full model session every
  # tick, forever (#59 — observed as 11 triage sessions in 50 minutes on an
  # unchanged board). That is the same defect (c) and (d) were fixed for on
  # 2026-07-25, and (a)/(b) were left with the assumption that they clear
  # themselves. They only clear if the session labels EVERY issue it sees.
  #
  # One ledger for both: they are open issues in a single numbering space, and
  # the sets are disjoint by construction — a stray carries none of the six
  # queue labels, so it can never also be needs-triage. Keys are REPO-qualified
  # for the reason (c) records: one ledger spans every repo in repos.txt, and a
  # bare number let rig#1 shadow ceremony#1.
  #
  # Fetch and parse are SEPARATE steps, matching the builder's shape below
  # (kimi-bot, #60 review). Piped together, a jq that fails after gh succeeded
  # appends `err` to whatever it had already emitted, so the `= err` test misses
  # and a PARTIAL list is processed as a complete one — with the probe-failed
  # warn swallowed. The list being short is harmless (absent items re-appear
  # next tick, the safe direction); losing the warn is not, because a probe that
  # cannot tell must say so. That is this whole issue's argument.
  local nt_items="" stray_items="" issue_json
  issue_json="$(gh issue list -R "$R" --state open --limit 200 \
    --json number,body,updatedAt,labels 2>/dev/null || echo err)"
  if [ "$issue_json" = err ]; then
    warn "$R: open-board probe failed"
    issue_json='[]'
  fi
  if ! nt_items="$(printf '%s' "$issue_json" \
      | jq -r --arg r "$R" --arg n "$LABEL_NEEDS_TRIAGE" \
        '.[] | select([.labels[].name] | index($n))
          | "\($r)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
    warn "$R: needs-triage parse failed"
    nt_items=""
  else
    fresh_nt="$(printf '%s\n' "$nt_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board")"
    nt="$(printf '%s\n' "$fresh_nt" | awk 'NF{c++} END{print c+0}')"
    [ "$nt" -gt 0 ] && signals="$signals ${nt}x needs-triage;"
  fi

  # (b) queue-unlabeled strays: the board invariant, quoted from LABELS.md, is
  # that every open issue "is either needs-triage, epic, or carries exactly one
  # of ready / claimed / blocked" — FIVE labels, read from the conf so the set
  # here and LABELS.md's sentence are asserted equal by the suite. It was six
  # with `post-merge` from #358 until ceremony 0.7.11 retired that row: after-
  # close work is now a successor issue minted at the split, so a merged issue
  # closes and needs no terminal queue state. The detector asks exactly one
  # question — does this issue carry a queue label — and the composition rules
  # are the sweep's, not this signal's.
  if ! stray_items="$(printf '%s' "$issue_json" \
      | jq -r --arg repo "$R" --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" --arg b "$LABEL_BLOCKED" \
           --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
        '.[] | select( ([.labels[].name]
            | map(. == $r or . == $c or . == $b or . == $e or . == $n) | any) | not )
          | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
    warn "$R: stray parse failed"
    stray_items=""
  else
    fresh_stray="$(printf '%s\n' "$stray_items" \
      | ledger_filter "$DUTY_DIR/.seen-triage-board")"
    stray="$(printf '%s\n' "$fresh_stray" | awk 'NF{c++} END{print c+0}')"
    [ "$stray" -gt 0 ] && signals="$signals ${stray}x queue-unlabeled;"
  fi

  # Everything the ledger just hid is still a live board-invariant violation.
  # Stop paying for it; do NOT stop saying it.
  # State file PER REPO. _triage_repo runs once per repos.txt entry, so a single
  # shared file has repo B overwrite repo A's saved set — and a repo with
  # nothing suppressed rm -f's it outright. Next tick A's unchanged set looks
  # new and warns again, which is precisely the every-tick spam the change
  # detection exists to prevent, on precisely the multi-repo box #59 is about
  # (codex-bot and grok-bot both caught this; grok-bot reproduced the flip-flop).
  # After #253 this reports the board as it stood when the launch decision was
  # made, which is what the message claims — so the WARN now lands after the
  # mention session's SESSION START/END lines rather than before them.
  printf '%s\n%s\n' "$nt_items" "$stray_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-triage-board" \
    | report_suppressed "$DUTY_DIR/.suppressed-triage-board.${R//\//_}" "$R: board"

  # (c) open discussions with no comment or reply by me — but wake only for
  # ones whose activity ADVANCED since I last handled this repo. A discussion
  # held for a human ruling (needs-ruling) carries no comment of mine by
  # design; keying on that alone re-fired a full triage session every tick
  # forever (the overnight burn). updatedAt now travels too; `uncommented_disc`
  # holds every currently-uncommented one as "REPO#number updatedAt" lines and
  # is committed after the triage session, so a held one is marked seen at its
  # current state. The key is REPO-qualified: discussion numbers are
  # per-repository but this ledger is one file across every repo in repos.txt,
  # so a bare number let rig#1 shadow ceremony#1 (codex, #16 review). Limits
  # (50/50/20) truncate very busy threads — safe direction (re-wake), hygiene
  # is the backstop.
  local uncommented_disc
  if ! uncommented_disc="$(_triage_discussion_items "$R" "$owner" "$name" 2>/dev/null)"; then
    warn "$R: discussion probe failed (discussions disabled?)"
    uncommented_disc=""
  else
    fresh_discussions="$(printf '%s\n' "$uncommented_disc" \
      | ledger_filter "$DUTY_DIR/.seen-discussions")"
    undisc="$(printf '%s\n' "$fresh_discussions" | awk 'NF{c++} END{print c+0}')"
    [ "$undisc" -gt 0 ] && signals="$signals ${undisc}x uncommented discussions;"
  fi

  # (e) blocked issues whose named blockers all landed. The parser is
  # deliberately narrow (see lib/jq/blockers.jq — corpus-tested); issue and
  # PR numbering is shared, so the state map needs both lists. Fail-safe by
  # construction: an unknown number counts as still-open, and so does a
  # cross-repo reference, which is keyed by its whole token (owner/repo#N)
  # and therefore never resolves against this map (#632).
  local blocked_json numstates graph_edges='[]' graph_items=""
  local unblockable_items="" fresh_unblockable=""
  blocked_json="$(jq -c --arg b "$LABEL_BLOCKED" \
    '[.[] | select([.labels[].name] | index($b))]' <<<"$issue_json" 2>/dev/null || echo '[]')"
  graph_edges="$(_triage_graph_edges "$R" "$issue_json" || echo '[]')"
  if [ "$(jq 'length' <<<"$graph_edges" 2>/dev/null || echo 0)" -gt 0 ]; then
    numstates="$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                    gh pr    list -R "$R" --state all --limit 500 --json number,state; } 2>/dev/null \
      | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries' || echo '{}')"
    if ! graph_items="$(_triage_graph_items "$graph_edges" "$numstates")"; then
      warn "$R: dependency graph parse failed"
      graph_items=""
    fi
    if [ "$(jq 'length' <<<"$blocked_json" 2>/dev/null || echo 0)" -gt 0 ] && \
       ! unblockable_items="$(_triage_unblockable_items "$R" "$blocked_json" "$numstates")"; then
      warn "$R: unblockable parse failed"
      unblockable_items=""
    fi
  fi
  graph_changes="$(printf '%s\n' "$graph_items" \
    | _triage_graph_changes "$DUTY_DIR/.seen-graph")"
  [ -n "$graph_changes" ] && signals="$signals graph-changed;"
  fresh_unblockable="$(printf '%s\n' "$unblockable_items" \
    | ledger_filter "$DUTY_DIR/.seen-unblockable")"
  unblockable="$(printf '%s\n' "$fresh_unblockable" | awk 'NF {
    number=$1; sub(/^.*#/, "", number); due = due sep number; sep="," }
    END { print due }')"
  [ -n "$unblockable" ] && signals="$signals unblockable:${unblockable};"
  printf '%s\n' "$unblockable_items" \
    | ledger_suppressed "$DUTY_DIR/.seen-unblockable" \
    | report_suppressed "$DUTY_DIR/.suppressed-unblockable.${R//\//_}" "$R: unblockable"

  if [ -z "$signals" ]; then
    if [ "$mention_count" -eq 0 ]; then
      log "$R: quiet — no mentions, no triage signals, no session launched"
    elif [ "$selected_mention_count" -eq 0 ]; then
      log "$R: mentions deferred by fleet ceiling — no triage signals, no repo session launched"
    else
      log "$R: no triage signals — mention session was the only wake"
    fi
    return 0
  fi

  log "$R: signals:$signals launching triage session"
  dir="$WORK_DIR/${R//\//__}"
  ensure_checkout "$R" "$dir" || return 0
  local signal_items="" signal_block="" unblockable_item="" graph_item="" graph_lines=""
  if [ -n "$fresh_nt" ]; then
    signal_items="- Needs-triage issues: $(printf '%s\n' "$fresh_nt" | _triage_signal_numbers)"
  fi
  if [ -n "$fresh_stray" ]; then
    signal_items="${signal_items:+$signal_items
}- Queue-unlabeled issues: $(printf '%s\n' "$fresh_stray" | _triage_signal_numbers)"
  fi
  if [ -n "$fresh_discussions" ]; then
    signal_items="${signal_items:+$signal_items
}- Unresolved discussions without your voice: $(printf '%s\n' "$fresh_discussions" | _triage_signal_numbers)"
  fi
  if [ -n "$unblockable" ]; then
    unblockable_item="$(render_prompt fragment-unblockable.txt \
      NUMS="#${unblockable//,/, #}")"
    signal_items="${signal_items:+$signal_items
}$unblockable_item"
  fi
  if [ -n "$graph_changes" ]; then
    graph_lines="$(printf '%s\n' "$graph_changes" | awk 'NF>=3 {
      split($1, edge, "#")
      printf "  - #%s depends on #%s: %s -> %s\n", edge[2], edge[3], $2, $3
    }')"
    graph_item="$(render_prompt fragment-graph-changed.txt EDGES="$graph_lines")"
    signal_items="${signal_items:+$signal_items
}$graph_item"
  fi
  signal_block="$(render_prompt fragment-signals.txt SIGNAL_ITEMS="$signal_items")"
  # Sizing evidence (#503), gathered HERE and nowhere earlier: the session is
  # already launching, so this buys context for a session the board paid for
  # rather than becoming a reason to spend one. It sets no signal, so it cannot
  # reach the `signals` test above even by accident.
  _triage_round_count "$R"
  prompt="$(render_prompt triage.txt ME="$ME" REPO="$R" SIGNAL_BLOCK="$signal_block" \
    ROUND_EVIDENCE="$ROUND_COUNT_EVIDENCE")"
  RUN_SESSION_RC=1
  run_session triage "$R" "$dir" "$TIMEOUT_TRIAGE" "$prompt"
  # Mark each signal at the state in which the session LEFT it, not the state
  # that launched the session. That prevents the session's own comments from
  # re-waking it next tick. A third-party write racing the re-read is swallowed
  # in the safe direction: hourly hygiene remains the unconditional backstop,
  # and every stable suppressed set is still reported. Never substitute now():
  # the board's own timestamps are the evidence the next tick compares.
  #
  # Committed ONLY on rc 0, exactly as (c) is: a crashed or timed-out session
  # must leave its ids uncommitted so the next tick retries. That distinction —
  # declined vs never got there — is the whole reason this is safe.
  if [ "${RUN_SESSION_RC:-1}" -eq 0 ]; then
    local post_board_json post_nt="" post_stray="" post_discussions=""
    local post_blocked post_numstates post_unblockable="" post_graph="" post_graph_edges='[]'
    post_board_json="$(gh issue list -R "$R" --state open --limit 200 \
      --json number,body,labels,updatedAt 2>/dev/null || echo err)"
    if [ "$post_board_json" = err ]; then
      warn "$R: post-session board probe failed; ledgers left unchanged"
    else
      if ! post_nt="$(printf '%s' "$post_board_json" | jq -r --arg repo "$R" \
          --arg n "$LABEL_NEEDS_TRIAGE" \
          '.[] | select([.labels[].name] | index($n))
            | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
        warn "$R: post-session needs-triage parse failed"
        post_nt=""
      fi
      if ! post_stray="$(printf '%s' "$post_board_json" \
          | jq -r --arg repo "$R" --arg r "$LABEL_READY" --arg c "$LABEL_CLAIMED" \
              --arg b "$LABEL_BLOCKED" \
              --arg e "$LABEL_EPIC" --arg n "$LABEL_NEEDS_TRIAGE" \
            '.[] | select( ([.labels[].name]
                | map(. == $r or . == $c or . == $b or . == $e or . == $n) | any) | not )
              | "\($repo)#\(.number) \(.updatedAt)"' 2>/dev/null)"; then
        warn "$R: post-session stray parse failed"
        post_stray=""
      fi
      printf '%s\n%s\n' "$post_nt" "$post_stray" \
        | ledger_commit "$DUTY_DIR/.seen-triage-board"

      post_blocked="$(printf '%s' "$post_board_json" | jq -c \
        --arg b "$LABEL_BLOCKED" '[.[] | select([.labels[].name] | index($b))]' 2>/dev/null || echo err)"
      if [ "$post_blocked" = err ]; then
        warn "$R: post-session blocked parse failed"
      fi
      post_graph_edges="$(_triage_graph_edges "$R" "$post_board_json" || echo '[]')"
      if [ "$(jq 'length' <<<"$post_graph_edges" 2>/dev/null || echo 0)" -gt 0 ]; then
        post_numstates="$( { gh issue list -R "$R" --state all --limit 500 --json number,state
                            gh pr    list -R "$R" --state all --limit 500 --json number,state; } 2>/dev/null \
          | jq -s 'add | map({key:(.number|tostring), value:.state}) | from_entries' || echo err)"
        if [ "$post_numstates" = err ] || ! post_graph="$(_triage_graph_items \
             "$post_graph_edges" "$post_numstates")"; then
          warn "$R: post-session dependency graph probe failed; graph and unblockable ledgers left unchanged"
        else
          printf '%s\n' "$post_graph" | _triage_graph_commit
          if [ "$post_blocked" != err ] && \
             [ "$(jq 'length' <<<"$post_blocked" 2>/dev/null || echo 0)" -gt 0 ]; then
            if post_unblockable="$(_triage_unblockable_items "$R" "$post_blocked" "$post_numstates")"; then
              printf '%s\n' "$post_unblockable" | ledger_commit "$DUTY_DIR/.seen-unblockable"
            else
              warn "$R: post-session unblockable probe failed; ledger left unchanged"
            fi
          fi
        fi
      fi
    fi

    if post_discussions="$(_triage_discussion_items "$R" "$owner" "$name" 2>/dev/null)"; then
      printf '%s\n' "$post_discussions" | ledger_commit "$DUTY_DIR/.seen-discussions"
    else
      warn "$R: post-session discussion probe failed; ledger left unchanged"
    fi
  fi
}
