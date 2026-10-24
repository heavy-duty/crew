# duty-release.sh — the release cut (triage role, #762).
#
# The one duty in this engine that ends at a door a person opens. For every
# track in RELEASE_TRACKS (`owner/repo:path:tag-prefix[:auto|hold]`) the tick
# reads the main clone and the board, and decides — in shell, with every
# refusal's reason on the record — whether main carries a release nobody has
# cut: merges since the track's last tag that touch the track, fragments
# waiting in its changelog.d, VERSION armed `-dev`, CI green at main's head,
# no release PR open, main quiet for RELEASE_QUIET_S, the track not already
# cut. Only then does it buy a session, and the session does the half that
# needs judgment and a toolchain: the assembled section through ceremony's
# own `bin/changelog-assemble` at the consumer's pin, the drill record
# written honestly, one pull request carrying the release label — and then
# it STOPS. The approval is a person's (the site's *Publicar versión*, or a
# maintainer's merge); the engine never merges, tags or dispatches.
#
# One cut at a time, and a cut is never re-pushed: a release PR the engine
# opened is withdrawn when main moves past it ON THE TRACK (stale) and the
# next tick cuts the new head; one a person closed unmerged (refused) stays
# refused for that track state — the ledger remembers the TRACK'S TREE, not
# main's commit, so an off-track merge (the admin's, on the site's repository)
# re-opens nothing, and only new merges on the track make a new cut.
#
# Every piece of the cut's memory is PER TRACK (`<slug>` = repo and prefix),
# so two tracks of one repository never share a cut, a wait or a refusal:
#   .seen-release              `repo:path#<tree sha> 0` — track states the
#                              engine cut or a person refused; never re-cut
#   .release-cut-<slug>        `<pr> <branch> <main sha>` — the open cut
#   .release-due-<slug>        `<repo> <epoch>` — a cut waiting for main to go
#                              quiet; the host tick starts the box when due
#   .release-tried-<slug>      `<tree sha> <n>` — sessions that ended without a
#                              pull request; at RELEASE_MAX_TRIES the state is
#                              refused rather than bought again every tick
# All of them ride the probe to the store and come back across a reset.
#
# shellcheck shell=bash

RELEASE_QUIET_S_DEFAULT=900
RELEASE_MAX_TRIES_DEFAULT=2
RELEASE_CI_GRACE_S_DEFAULT=1800
RELEASE_CEREMONY_REPO_DEFAULT="heavy-duty/ceremony"

# _release_slug REPO PREFIX — the per-track file suffix.
_release_slug() {
  local s="${1//\//_}"
  [ -z "${2:-}" ] || s="$s-${2//\//_}"
  printf '%s\n' "$s"
}

# _release_tracks — RELEASE_TRACKS parsed, one `repo path prefix rule` line
# per entry. Whitespace separates entries; colons separate fields; a missing
# path is `.`, a missing rule is `auto`. An EMPTY prefix is printed as `-`,
# because the line is read back with `read` and an empty field would merge
# with the next; readers map `-` to the empty prefix. An unknown rule reads
# as `hold`, because a rule the operator wrote and the engine cannot read
# must not buy a cut by accident.
_release_tracks() {
  local entry repo path prefix rule
  # shellcheck disable=SC2086  # word-splitting the entries is the format
  for entry in ${RELEASE_TRACKS:-}; do
    IFS=: read -r repo path prefix rule <<<"$entry"
    [ -n "$repo" ] || continue
    [ -n "$path" ] || path=.
    [ -n "$prefix" ] || prefix=-
    rule="${rule:-auto}"
    case "$rule" in
      auto|hold) ;;
      *) warn "release: track $entry: rule '$rule' is neither auto nor hold; read as hold"; rule=hold ;;
    esac
    printf '%s %s %s %s\n' "$repo" "$path" "$prefix" "$rule"
  done
}
_release_prefix() { [ "$1" = - ] && printf '' || printf '%s' "$1"; }

# _release_pin DIR — the ceremony pin the repository's release caller names on
# origin/main, or nothing. The pin is the consumer's, read from its tree and
# never from this engine's own: the two-contracts rule.
_release_pin() {
  local repo_re
  repo_re="$(printf '%s' "${RELEASE_CEREMONY_REPO:-$RELEASE_CEREMONY_REPO_DEFAULT}" | sed 's/[.[\*^$/]/\\&/g')"
  git -C "$1" show origin/main:.github/workflows/release.yml 2>/dev/null \
    | grep -oE "uses:[[:space:]]*$repo_re/\.github/workflows/release\.yml@[^[:space:]]+" \
    | head -1 | sed 's/.*@//'
}

# _release_ceremony_tree PIN — a checkout of ceremony at PIN under the work
# dir, printed; nonzero when it cannot be had. Cached per pin: the pin moves
# rarely and the clone is the one network read the cut makes beyond gh.
_release_ceremony_tree() {
  local pin="$1" dir
  dir="$WORK_DIR/.ceremony-$pin"
  if [ ! -x "$dir/bin/changelog-assemble" ]; then
    rm -rf "$dir"
    gh repo clone "${RELEASE_CEREMONY_REPO:-$RELEASE_CEREMONY_REPO_DEFAULT}" "$dir" \
        -- --quiet --depth 1 --branch "$pin" >/dev/null 2>&1 \
      || { rm -rf "$dir"; return 1; }
    [ -x "$dir/bin/changelog-assemble" ] || { rm -rf "$dir"; return 1; }
  fi
  printf '%s\n' "$dir"
}

# _release_last_tag DIR PREFIX [final] — the track's newest release tag by
# creation date under the prefix: any `X.Y.Z` or `X.Y.Z-rcN` for a candidate,
# and FINAL ONLY when the version being cut is final — the release after an
# rc ladder ships everything since the last final, candidates included, so a
# candidate tag is not where its "since" starts. A bare-prefix track sees no
# other track's prefixed tags: the regex anchors on the digits.
_release_last_tag() {
  local dir="$1" prefix="$2" shape="${3:-any}" re rc
  re="$(printf '%s' "$prefix" | sed 's/[.[\*^$/]/\\&/g')"
  rc='(-rc[0-9]+)?'; [ "$shape" != final ] || rc=''
  git -C "$dir" tag --sort=-creatordate -l "${prefix}*" 2>/dev/null \
    | grep -E "^${re}[0-9]+\.[0-9]+\.[0-9]+${rc}$" | head -1
}

# _release_version DIR PATH — the version main is armed for, from the track's
# VERSION: `X.Y.Z-dev` cuts X.Y.Z, `X.Y.Z-rcN-dev` cuts the candidate. Prints
# nothing when main is not armed, which is its own refusal.
_release_version() {
  local v sub="VERSION"
  [ "$2" = . ] || sub="${2%/}/VERSION"
  v="$(git -C "$1" show "origin/main:$sub" 2>/dev/null | head -1 | tr -d '[:space:]')"
  case "$v" in *-dev) printf '%s\n' "${v%-dev}" ;; *) return 1 ;; esac
}

# _release_pathspec PATH — sets _RELEASE_PATHSPEC, the `git` pathspec for the
# track: its directory, minus its own VERSION, because the merge door's re-arm
# commit (`X.Y.Z` → `X.Y.(Z+1)-dev`) touches VERSION and nothing else and is
# not a merge the track ships. A pull request that moves VERSION beside other
# files still counts, by those files.
_RELEASE_PATHSPEC=()
_release_pathspec() {
  if [ "$1" = . ]; then _RELEASE_PATHSPEC=(-- . ':(exclude)VERSION')
  else _RELEASE_PATHSPEC=(-- "${1%/}" ":(exclude)${1%/}/VERSION"); fi
}

# _release_merges DIR FROM PATH — `sha subject` lines of main's commits since
# FROM (a tag or sha) that touch the track; empty when main carries nothing
# for it. Squash merges are commits, so every row is one merged PR.
_release_merges() {
  local dir="$1" from="$2" path="$3"
  _release_pathspec "$path"
  git -C "$dir" log --no-merges --format='%h %s' "$from..origin/main" "${_RELEASE_PATHSPEC[@]}" 2>/dev/null
}

# _release_track_id DIR PATH — the sha of the TRACK'S TREE at origin/main:
# the identity a cut or a refusal is remembered by. An off-track merge leaves
# it unchanged; any merge on the track changes it.
_release_track_id() {
  local dir="$1" path="$2"
  if [ "$path" = . ]; then git -C "$dir" rev-parse 'origin/main^{tree}' 2>/dev/null
  else git -C "$dir" rev-parse "origin/main:${path%/}" 2>/dev/null; fi
}

# _release_fragments DIR PATH — the fragments waiting in the track's
# changelog.d on main, one name per line, the directory's own README and the
# declared `shape` anchor excluded (the two files changelog-assemble skips).
_release_fragments() {
  local dir="$1" path="$2" sub
  sub="${2%/}/changelog.d"; [ "$path" = . ] && sub="changelog.d"
  git -C "$dir" ls-tree --name-only "origin/main:$sub" 2>/dev/null \
    | grep -vx 'README.md' | grep -vx 'shape'
}

# _release_ci REPO SHA DIR [AGE] — green | none | pending | red | unknown,
# from EVERY check run at SHA (paginated) and the commit's combined status. A
# run not yet completed is pending; failure, timed out, cancelled, action
# required and STALE are red (a stale run says nothing about this tree, so it
# is not green). No run and no status at all is green on a repository with no
# workflows on main; with workflows it means the runs have not reported yet
# (pending) — until the head is AGE seconds old past RELEASE_CI_GRACE_S, when
# it means the workflows do not run on main at all (`none`; the caller cuts).
# Unknown (an API that did not answer) refuses like red: a cut is bought on
# evidence, never on its absence.
_release_ci() {
  local repo="$1" sha="$2" dir="$3" runs statuses n_runs verdict
  runs="$(gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
    --jq '.check_runs[] | "\(.status) \(.conclusion // "")"' 2>/dev/null)" || { echo unknown; return 0; }
  statuses="$(gh api "repos/$repo/commits/$sha/status" \
    --jq '"\(.state) \(.total_count)"' 2>/dev/null)" || { echo unknown; return 0; }
  n_runs="$(printf '%s\n' "$runs" | awk 'NF' | wc -l | tr -d ' ')"
  verdict="$(printf '%s\n' "$runs" | awk 'NF' | jq -Rs '
    split("\n") | map(select(length > 0))
    | if any(.[]; startswith("completed") | not) then "pending"
      elif any(.[]; test(" (failure|timed_out|cancelled|action_required|startup_failure|stale)$")) then "red"
      else "green" end' -r 2>/dev/null)"
  [ -n "$verdict" ] || verdict=unknown
  case "$statuses" in
    "failure "*|"error "*) echo red; return 0 ;;
    "pending "*) case "${statuses#pending }" in 0) ;; *) [ "$verdict" = red ] && echo red || echo pending; return 0 ;; esac ;;
  esac
  if [ "$n_runs" -eq 0 ] && [ "${statuses#* }" = 0 ]; then
    # Workflows exist and none ran on this head: a `pull_request`-only or
    # path-filtered CI never will, so "pending" would hold the track forever.
    # The head is given RELEASE_CI_GRACE_S to start a run; past that, no run
    # is the repository's answer and the head is cut as it stands (`none`).
    if [ -n "$(git -C "$dir" ls-tree --name-only origin/main:.github/workflows 2>/dev/null)" ]; then
      if [ "${4:-0}" -ge "${RELEASE_CI_GRACE_S:-$RELEASE_CI_GRACE_S_DEFAULT}" ] 2>/dev/null; then echo none; else echo pending; fi
    else
      echo green
    fi
    return 0
  fi
  echo "$verdict"
}

# _release_open_prs REPO — `num author branch` lines of the open pull requests
# carrying the release label, whoever opened them.
_release_open_prs() {
  gh pr list -R "$1" --state open --label "${LABEL_RELEASE:-release}" --limit 20 \
    --json number,author,headRefName \
    --jq '.[] | "\(.number) \(.author.login) \(.headRefName)"' 2>/dev/null
}

# _release_branch_is_other_track BRANCH REPO PREFIX — true when BRANCH is the
# cut branch of ANOTHER configured track of the same repository, so a second
# track's open cut does not hold this one (the site's cut does not wait for
# the admin's). A branch no configured track owns holds every track: a release
# PR a person opened by hand is still a release PR.
_release_branch_is_other_track() {
  local branch="$1" repo="$2" prefix="$3" trepo tprefix
  while read -r trepo _ tprefix _; do
    [ "$trepo" = "$repo" ] || continue
    tprefix="$(_release_prefix "$tprefix")"
    [ "$tprefix" != "$prefix" ] || continue
    [ -n "$tprefix" ] || continue
    case "$branch" in release/"$tprefix"[0-9]*) return 0 ;; esac
  done < <(_release_tracks)
  return 1
}

_release_due_write() { # SLUG REPO DUE-EPOCH
  local f
  f="$DUTY_DIR/.release-due-$1"
  printf '%s %s\n' "$2" "$3" >"$f.tmp" && mv -f "$f.tmp" "$f"
}
_release_due_clear() { rm -f "$DUTY_DIR/.release-due-$1"; }

# _release_refuse DIR PATH REPO — the track's current tree, remembered as
# cut-or-refused, so it is never bought again until the track moves.
_release_refuse() {
  local tree
  tree="$(_release_track_id "$1" "$2")"
  [ -n "$tree" ] || return 0
  printf '%s:%s#%s 0\n' "$3" "$2" "$tree" | ledger_commit "$DUTY_DIR/.seen-release"
}

# _release_mine BRANCH REPO NUM — true when every commit on the engine's own
# cut is the engine's: a branch somebody else pushed to is not withdrawn (its
# branch is not deleted, its PR not closed) — it is held, and said.
_release_mine() {
  local authors owner name
  owner="${2%%/*}"; name="${2##*/}"
  # The GIT AUTHOR of every commit, read through GraphQL: `gh pr view --json
  # commits` lists `authors`, which GitHub fills from the Co-Authored-By
  # trailers too, and the engine's commits carry one — so that reading never
  # equalled $ME and no engine cut was ever withdrawn. An author GitHub cannot
  # resolve to a user reads `unknown`, which is not $ME: held, and said.
  # shellcheck disable=SC2016  # GraphQL's own $variables, bound with -f/-F
  authors="$(gh api graphql -f query='query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$num){
      commits(first:100){nodes{commit{author{user{login}}}}}
    } } }' -f owner="$owner" -f name="$name" -F num="$3" \
    --jq '[.data.repository.pullRequest.commits.nodes[].commit.author.user.login // "unknown"] | unique | join(" ")' 2>/dev/null)" || return 1
  [ -n "$authors" ] || return 1
  [ "$authors" = "$ME" ]
}

# _release_settle_cut SLUG REPO PATH DIR — what became of the cut the engine
# holds open for this track, if any. Merged: forgotten. Closed unmerged by a
# person: refused — the track's tree stays in the ledger so it is never
# re-cut. Still open and main moved past it on this track: stale — withdrawn
# (when every commit on it is the engine's), and the next tick cuts the new
# tree. Still open and current: `open`, which holds the track. Sets
# RELEASE_SETTLED to one of none|shipped|refused|withdrawn|open — a variable
# and not stdout, because the function logs on the way.
RELEASE_SETTLED=none
_release_settle_cut() {
  local slug="$1" repo="$2" path="$3" dir="$4" f num branch head state ahead
  RELEASE_SETTLED=none
  f="$DUTY_DIR/.release-cut-$slug"
  [ -f "$f" ] || return 0
  read -r num branch head <"$f" || return 0
  state="$(gh pr view "$num" -R "$repo" --json state,mergedAt \
    --jq '"\(.state) \(.mergedAt // "")"' 2>/dev/null)" || { RELEASE_SETTLED=open; return 0; }
  case "$state" in
    MERGED*) rm -f "$f"; log "release: $repo#$num shipped ($branch) — the cut is forgotten"; RELEASE_SETTLED=shipped; return 0 ;;
    CLOSED*)
      rm -f "$f"
      _release_refuse "$dir" "$path" "$repo"
      log "release: $repo#$num was closed without merging ($branch) — refused; the track at ${head:0:7} is not cut again until it moves"
      RELEASE_SETTLED=refused; return 0 ;;
  esac
  _release_pathspec "$path"
  ahead="$(git -C "$dir" rev-list --count "$head..origin/main" "${_RELEASE_PATHSPEC[@]}" 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    if ! _release_mine "$branch" "$repo" "$num"; then
      warn "release: $repo#$num is stale (main moved past ${head:0:7}) but carries commits that are not $ME's — not withdrawn; it holds the track until a person settles it"
      RELEASE_SETTLED=open; return 0
    fi
    if gh pr close "$num" -R "$repo" --delete-branch \
        --comment "Withdrawn by $ME: main moved past this cut (${ahead} merge(s) on the track since ${head:0:7}). The next tick cuts the new head; nothing here is re-pushed." >/dev/null 2>&1; then
      rm -f "$f"
      log "release: $repo#$num withdrawn ($branch) — main moved $ahead merge(s) past ${head:0:7}; the new head is cut next tick"
      RELEASE_SETTLED=withdrawn; return 0
    fi
    warn "release: $repo#$num is stale (main moved past ${head:0:7}) and could not be withdrawn; it holds the track until it can"
    RELEASE_SETTLED=open; return 0
  fi
  RELEASE_SETTLED=open
}

# _release_gate SLUG REPO PATH PREFIX RULE DIR — the decision table, one row
# per refusal, each a `no release duty:` line. Every refusal but the quiet
# window's clears the track's wait, so a cut refused for another reason never
# keeps waking the box for the window. Sets RELEASE_VERSION, RELEASE_LAST_TAG,
# RELEASE_MAIN_HEAD, RELEASE_TRACK_ID, RELEASE_MERGES,
# RELEASE_FRAGMENTS, RELEASE_PIN, RELEASE_TREE for the caller on success.
RELEASE_VERSION=""; RELEASE_LAST_TAG=""; RELEASE_MAIN_HEAD=""; RELEASE_TRACK_ID=""
RELEASE_MERGES=""; RELEASE_FRAGMENTS=""; RELEASE_PIN=""; RELEASE_TREE=""
_release_gate() {
  local slug="$1" repo="$2" path="$3" prefix="$4" rule="$5" dir="$6"
  local name="$repo ${prefix:-<bare>}@$path" prs num author branch shape
  local head ci age now quiet fresh tried tried_n
  RELEASE_VERSION=""; RELEASE_LAST_TAG=""; RELEASE_MAIN_HEAD=""; RELEASE_TRACK_ID=""
  RELEASE_MERGES=""; RELEASE_FRAGMENTS=""; RELEASE_PIN=""; RELEASE_TREE=""
  _release_due_clear "$slug"
  if [ "$rule" = hold ]; then
    log "no release duty: $name — held by RELEASE_TRACKS (rule hold); the operator cuts"; return 1
  fi
  _release_settle_cut "$slug" "$repo" "$path" "$dir"
  case "$RELEASE_SETTLED" in
    open) log "no release duty: $name — the engine's own release PR is open and current; the approval is a person's"; return 1 ;;
    withdrawn) return 1 ;;
  esac
  prs="$(_release_open_prs "$repo")"
  while read -r num author branch; do
    [ -n "$num" ] || continue
    _release_branch_is_other_track "$branch" "$repo" "$prefix" && continue
    log "no release duty: $name — release PR #$num by $author ($branch) is already open"; return 1
  done <<<"$prs"
  if ! RELEASE_VERSION="$(_release_version "$dir" "$path")"; then
    log "no release duty: $name — VERSION on main is not armed (no -dev suffix); nothing to stamp"; return 1
  fi
  shape=final; case "$RELEASE_VERSION" in *-rc[0-9]*) shape=any ;; esac
  RELEASE_LAST_TAG="$(_release_last_tag "$dir" "$prefix" "$shape")"
  if [ -z "$RELEASE_LAST_TAG" ]; then
    if [ "$shape" = final ] && [ -n "$(_release_last_tag "$dir" "$prefix" any)" ]; then
      log "no release duty: $name — only candidate tags under the prefix ($(_release_last_tag "$dir" "$prefix" any)); the first final is the operator's (the known first-release edge)"; return 1
    fi
    log "no release duty: $name — no release tag under the prefix yet; the first cut is the operator's (the known first-release edge)"; return 1
  fi
  RELEASE_MERGES="$(_release_merges "$dir" "$RELEASE_LAST_TAG" "$path")"
  if [ -z "$RELEASE_MERGES" ]; then
    log "no release duty: $name — main carries nothing for the track since $RELEASE_LAST_TAG"; return 1
  fi
  RELEASE_FRAGMENTS="$(_release_fragments "$dir" "$path")"
  if [ "$shape" = final ] && [ -z "$RELEASE_FRAGMENTS" ]; then
    log "no release duty: $name — $(printf '%s\n' "$RELEASE_MERGES" | awk 'NF' | wc -l | tr -d ' ') merge(s) since $RELEASE_LAST_TAG but no fragment in changelog.d; a release publishes prose"; return 1
  fi
  head="$(git -C "$dir" rev-parse origin/main 2>/dev/null)"
  [ -n "$head" ] || { warn "release: $name — origin/main unreadable in $dir"; return 1; }
  RELEASE_MAIN_HEAD="$head"
  RELEASE_TRACK_ID="$(_release_track_id "$dir" "$path")"
  [ -n "$RELEASE_TRACK_ID" ] || { warn "release: $name — the track's tree is unreadable in $dir"; return 1; }
  fresh="$(printf '%s:%s#%s 0\n' "$repo" "$path" "$RELEASE_TRACK_ID" | ledger_filter "$DUTY_DIR/.seen-release")"
  if [ -z "$fresh" ]; then
    log "no release duty: $name — the track at ${head:0:7} was already cut or refused; only new merges on the track make a new cut"; return 1
  fi
  # Sessions that ended without a pull request, for this very track state:
  # at the cap the state is refused and said, rather than bought every tick
  # until the lane's budget runs out.
  tried=""; tried_n=0
  if [ -r "$DUTY_DIR/.release-tried-$slug" ]; then read -r tried tried_n <"$DUTY_DIR/.release-tried-$slug" || true; fi
  [ "$tried" = "$RELEASE_TRACK_ID" ] || { rm -f "$DUTY_DIR/.release-tried-$slug"; tried_n=0; }
  case "$tried_n" in ''|*[!0-9]*) tried_n=0 ;; esac
  if [ "$tried_n" -ge "${RELEASE_MAX_TRIES:-$RELEASE_MAX_TRIES_DEFAULT}" ]; then
    _release_refuse "$dir" "$path" "$repo"; rm -f "$DUTY_DIR/.release-tried-$slug"
    warn "release: $name — $tried_n session(s) ended without a pull request for the track at ${head:0:7}; refused until the track moves (read the session logs: a missing '${LABEL_RELEASE:-release}' label, an assembler refusal, a leftover fork branch)"
    return 1
  fi
  now="$(date +%s)"
  age=$((now - $(git -C "$dir" log -1 --format=%ct origin/main 2>/dev/null || echo "$now")))
  quiet="${RELEASE_QUIET_S:-$RELEASE_QUIET_S_DEFAULT}"
  case "$quiet" in ''|*[!0-9]*) quiet="$RELEASE_QUIET_S_DEFAULT" ;; esac
  if [ "$age" -lt "$quiet" ]; then
    _release_due_write "$slug" "$repo" $((now + quiet - age))
    log "no release duty: $name — main moved ${age}s ago, under the ${quiet}s quiet window; due in $((quiet - age))s"; return 1
  fi
  ci="$(_release_ci "$repo" "$head" "$dir" "$age")"
  case "$ci" in
    green) ;;
    none) log "release: $name — no CI ran at ${head:0:7} in ${age}s (the repository's workflows do not run on main); the head is cut as it stands" ;;
    pending) log "no release duty: $name — CI at ${head:0:7} is still running; a cut is bought on a green head"; return 1 ;;
    *) log "no release duty: $name — CI at ${head:0:7} is $ci; a cut is bought on a green head"; return 1 ;;
  esac
  RELEASE_PIN="$(_release_pin "$dir")"
  if [ -z "$RELEASE_PIN" ]; then
    log "no release duty: $name — the repository names no ceremony pin in .github/workflows/release.yml; the assembler has no version to run at"; return 1
  fi
  if ! RELEASE_TREE="$(_release_ceremony_tree "$RELEASE_PIN")"; then
    warn "release: $name — ceremony@$RELEASE_PIN could not be checked out; the cut waits"; return 1
  fi
  return 0
}

# _release_after SLUG REPO PATH BRANCH HEAD TRACK_ID — the session's product,
# verified on the board: the ledger row is EARNED by the pull request
# existing, the rule every seen-ledger follows, so a session that died before
# `gh pr create` leaves the track uncut; the try is counted, and the next
# tick cuts it again until RELEASE_MAX_TRIES.
_release_after() {
  local slug="$1" repo="$2" path="$3" branch="$4" head="$5" track_id="$6" num tried tried_n=0
  # A session the lane REFUSED — its budget spent, its terminal breaker tripped
  # — never ran (run_session returns with RUN_SESSION_RC=75), so it is not a
  # try: counting it would refuse the track after two quiet refusals and lose
  # the cut until another merge lands. The lane's own veto says why, once.
  if [ "${RUN_SESSION_RC:-1}" = 75 ]; then
    log "release: $repo — the session was refused by its lane (budget or breaker); not a try, the cut waits for the lane"
    return 1
  fi
  num="$(gh pr list -R "$repo" --state open --label "${LABEL_RELEASE:-release}" --limit 20 \
    --json number,author,headRefName 2>/dev/null \
    | jq -r --arg b "$branch" --arg me "$ME" \
        '.[] | select(.headRefName == $b and .author.login == $me) | .number' 2>/dev/null | head -1)"
  if [ -z "$num" ]; then
    if [ -r "$DUTY_DIR/.release-tried-$slug" ]; then read -r tried tried_n <"$DUTY_DIR/.release-tried-$slug" || true; fi
    [ "${tried:-}" = "$track_id" ] || tried_n=0
    case "$tried_n" in ''|*[!0-9]*) tried_n=0 ;; esac
    tried_n=$((tried_n + 1))
    printf '%s %s\n' "$track_id" "$tried_n" >"$DUTY_DIR/.release-tried-$slug.tmp" \
      && mv -f "$DUTY_DIR/.release-tried-$slug.tmp" "$DUTY_DIR/.release-tried-$slug"
    warn "release: $repo — the session ended without opening $branch (try $tried_n of ${RELEASE_MAX_TRIES:-$RELEASE_MAX_TRIES_DEFAULT}); the track at ${head:0:7} is cut again next tick"
    return 1
  fi
  rm -f "$DUTY_DIR/.release-tried-$slug"
  printf '%s %s %s\n' "$num" "$branch" "$head" >"$DUTY_DIR/.release-cut-$slug.tmp" \
    && mv -f "$DUTY_DIR/.release-cut-$slug.tmp" "$DUTY_DIR/.release-cut-$slug"
  printf '%s:%s#%s 0\n' "$repo" "$path" "$track_id" | ledger_commit "$DUTY_DIR/.seen-release"
  log "release: $repo#$num opened ($branch at ${head:0:7}) — the approval is a person's; the engine stops here"
  return 0
}

duty_release() {
  local repo path prefix rule dir slug name tslug branch wt_rules merges fragments
  [ -n "${RELEASE_TRACKS:-}" ] || return 0
  while read -r repo path prefix rule; do
    [ -n "$repo" ] || continue
    prefix="$(_release_prefix "$prefix")"
    if ! read_repo_list "$REPOS_FILE" | grep -Fx -- "$repo" >/dev/null; then
      warn "release: $repo is in RELEASE_TRACKS but not in this box's registry; skipped"
      continue
    fi
    slug="${repo//\//__}"; name="${repo##*/}"
    tslug="$(_release_slug "$repo" "$prefix")"
    dir="$WORK_DIR/$slug"
    ensure_main_clone "$repo" "$dir" || { warn "release: $repo — main clone unavailable; the cut waits"; continue; }
    git -C "$dir" fetch -q --tags origin 2>/dev/null || warn "release: $repo — tag fetch failed; the last tag may be stale"
    _release_gate "$tslug" "$repo" "$path" "$prefix" "$rule" "$dir" || continue
    branch="release/${prefix}${RELEASE_VERSION}"
    merges="$(printf '%s\n' "$RELEASE_MERGES" | awk 'NF' | paste -sd';' - | sed 's/;/; /g')"
    fragments="$(printf '%s\n' "$RELEASE_FRAGMENTS" | awk 'NF' | paste -sd' ' -)"
    [ -n "$fragments" ] || fragments="none (a candidate is tag-only)"
    wt_rules="$(render_prompt fragment-wt-rules.txt WT_DIR="$TREES_DIR/$slug" ME="$ME" NAME="$name")"
    log "release: $repo — cutting ${prefix}${RELEASE_VERSION} from ${RELEASE_MAIN_HEAD:0:7} (since $RELEASE_LAST_TAG; ceremony@$RELEASE_PIN)"
    RUN_SESSION_RC=1
    run_session release "$repo" "$dir" "${TIMEOUT_RELEASE:-2400}" \
      "$(render_prompt release.txt ME="$ME" REPO="$repo" NAME="$name" TRACK_PATH="$path" TAG_PREFIX="$prefix" VERSION="$RELEASE_VERSION" LAST_TAG="$RELEASE_LAST_TAG" MAIN_HEAD="$RELEASE_MAIN_HEAD" MERGES="$merges" FRAGMENTS="$fragments" CEREMONY_PIN="$RELEASE_PIN" CEREMONY_TREE="$RELEASE_TREE" BRANCH="$branch" LABEL_RELEASE="${LABEL_RELEASE:-release}" WT_RULES="$wt_rules")"
    _release_after "$tslug" "$repo" "$path" "$branch" "$RELEASE_MAIN_HEAD" "$RELEASE_TRACK_ID" || true
  done < <(_release_tracks)
  return 0
}
