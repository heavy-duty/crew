#!/usr/bin/env bash
# Sourceable helpers for the triage-role release leg (#762). The live leg runs
# only from rehearsal.sh's authenticated triage block; every predicate stays
# here so CI can feed it the duty's real line shapes and the board's real JSON
# without a drill host (shared/test/drill.sh executes them).
#
# What this covers that nothing in drill/ read before. #762 shipped
# `duty_release`, the one duty that ends at a door a person opens, and
# shared/test/release.sh proves its decision table against a git fixture and a
# stubbed `gh`. Nothing proved the other half: that on a REAL repository, at a
# real ceremony pin, one tick buys one session that opens one release pull
# request carrying the version, the assembled section, the consumed fragment
# and the drill record — and that the next tick opens nothing. That is #762's
# first acceptance criterion read live, and its idempotence:
#
#   1. one invocation of the duty over a fresh track cuts it: exactly one
#      `release: REPO#N opened` line, and exactly one open release-labelled
#      pull request for the track's branch on the board;
#   2. the pull request is the cut: labelled, against main, from the box
#      identity's fork, its files the track's VERSION (stamped to the bare
#      version), CHANGELOG.md, the drill record, and the fragment REMOVED;
#   3. a second invocation opens nothing — the engine's own open cut holds the
#      track, and the board still carries one release pull request;
#   4. a person closing it unmerged is a refusal the engine remembers: the
#      third invocation records it and deletes the cut's branch on the fork.
#
# The track is FRESH per round: its own directory under release-drill/ and its
# own tag prefix, both stamped, so a reused sandbox carries no cut, refusal or
# tag a previous round left, and the first-release edge (no tag yet is the
# operator's cut) is met by tagging the seed before arming VERSION.
#
# Why the leg calls duty_release directly, like the attention-audit leg calls
# its audit. The duty runs every tick but is gated on a quiet window and a CI
# grace sized for production (RELEASE_QUIET_S, RELEASE_CI_GRACE_S); waiting
# them out would spend wall clock re-proving two clocks shared/test/release.sh
# already pins. So the leg sources common.sh, load_conf, the module, sets both
# to 0 with RELEASE_TRACKS naming this round's track only, and reads the
# invocation's own stdout — the same bytes duty.sh writes to duty.log, without
# a window a concurrent tick could write into.
#
# What it does not claim. The cut is assembled by a real model session and the
# drill record is whatever that session honestly wrote; the leg grades the
# record's PRESENCE, never its prose. The approval half — the consumer's own
# door (la-familia-site's *Publicar versión*) — is not on a sandbox and stays
# the seven-day run's reading (#762 rows 5–6).

if ! declare -F rehearsal_verdict_record >/dev/null 2>&1; then
  # shellcheck source=drill/rehearsal-verdict.sh
  . "$(dirname "${BASH_SOURCE[0]}")/rehearsal-verdict.sh"
fi

# The registry the EXIT trap reads (rehearsal.sh's cleanup_all): every object
# is registered the moment it exists, and never from inside a command
# substitution, whose subshell would take the registry with it.
REHEARSAL_RELEASE_REPO=""
REHEARSAL_RELEASE_FILES=""
REHEARSAL_RELEASE_TAG=""
REHEARSAL_RELEASE_FORK=""
REHEARSAL_RELEASE_BRANCH=""
REHEARSAL_RELEASE_PR=""
REHEARSAL_RELEASE_SLUG=""

rehearsal_release_verdict() {
  rehearsal_verdict_record "${REHEARSAL_RELEASE_STATUS:-}" "$@"
}

# --- classifiers: output and JSON in, a verdict out --------------------------

# rehearsal_release_opened_pr OUT REPO — the number in the ONE `release:
# REPO#N opened (` line of an invocation's output; nothing when there is no
# such line or more than one (one tick, one cut: two is its own failure, and a
# number picked from two would grade it green).
rehearsal_release_opened_pr() {
  local out="$1" repo="$2" lines
  lines="$(grep -F "release: $repo#" <<<"$out" | grep -E " opened \(" || true)"
  [ "$(awk 'NF' <<<"$lines" | wc -l | tr -d ' ')" = 1 ] || return 0
  sed -nE "s|.*release: ${repo//./\\.}#([0-9]+) opened \(.*|\1|p" <<<"$lines" | head -1
}

# rehearsal_release_second_tick OUT REPO TRACK_PATH PREFIX — what a tick over a
# track with the engine's own cut open did: `held` (the duty said its own open
# cut holds the track), `cut` (it bought another session or opened another
# pull request — the defect), or `unknown` (it said neither, which proves
# nothing either way and is not an ok).
rehearsal_release_second_tick() {
  local out="$1" repo="$2" path="$3" prefix="$4"
  if grep -F "release: $repo — cutting " <<<"$out" >/dev/null \
     || grep -F "release: $repo#" <<<"$out" | grep -E " opened \(" >/dev/null; then
    printf 'cut\n'; return 0
  fi
  if grep -Fx -- "no release duty: $repo ${prefix:-<bare>}@$path — the engine's own release PR is open and current; the approval is a person's" \
       < <(sed -E 's/^[0-9TZ:-]+ //' <<<"$out") >/dev/null; then
    printf 'held\n'; return 0
  fi
  printf 'unknown\n'
}

# rehearsal_release_refused OUT REPO PR — `refused` when the invocation after
# a person closed the cut unmerged recorded the refusal, `unknown` otherwise.
rehearsal_release_refused() {
  local out="$1" repo="$2" pr="$3"
  if grep -F "release: $repo#$pr was closed without merging" <<<"$out" | grep -F -- "— refused;" >/dev/null; then
    printf 'refused\n'
  else
    printf 'unknown\n'
  fi
}

# rehearsal_release_open_count PULLS_JSON BRANCH — open pull requests carrying
# the release label whose head is BRANCH, from `gh api repos/R/pulls` JSON.
rehearsal_release_open_count() {
  jq -r --arg b "$2" --arg l "${LABEL_RELEASE:-release}" \
    '[.[] | select(.state == "open" and .head.ref == $b and any(.labels[]; .name == $l))] | length' \
    <<<"$1" 2>/dev/null || printf 'unreadable\n'
}

# rehearsal_release_pr_shape PULL_JSON IDENTITY BRANCH — `ok`, or the first
# thing about the pull request that is not the cut: its label, its base, its
# head branch, or the fork it comes from.
rehearsal_release_pr_shape() {
  jq -r --arg me "$2" --arg b "$3" --arg l "${LABEL_RELEASE:-release}" '
    if (.state != "open") then "not open (\(.state))"
    elif (any(.labels[]; .name == $l) | not) then "no \($l) label"
    elif (.base.ref != "main") then "base is \(.base.ref), not main"
    elif (.head.ref != $b) then "head is \(.head.ref), not \($b)"
    elif (.head.repo.owner.login != $me) then "head is on \(.head.repo.full_name), not a fork \($me) owns"
    else "ok" end' <<<"$1" 2>/dev/null || printf 'unreadable pull request\n'
}

# rehearsal_release_files_shape FILES_JSON TRACK_PATH VERSION FRAGMENT — `ok`,
# or what the cut's file set is missing, from `gh api repos/R/pulls/N/files`.
# The four the cut is: VERSION and CHANGELOG.md modified, the drill record
# added, the consumed fragment removed. Anything else in the diff is the
# session's business and is not graded here.
rehearsal_release_files_shape() {
  jq -r --arg p "$2" --arg v "$3" --arg f "$4" '
    def has($name; $statuses): any(.[]; .filename == $name and (.status as $s | $statuses | index($s)));
    if (has("\($p)/VERSION"; ["modified"]) | not) then "VERSION not modified"
    elif (has("\($p)/CHANGELOG.md"; ["modified"]) | not) then "CHANGELOG.md not modified"
    elif (has("\($p)/drills/\($v).md"; ["added"]) | not) then "no drill record drills/\($v).md"
    elif (has("\($p)/changelog.d/\($f)"; ["removed"]) | not) then "fragment \($f) not consumed"
    else "ok" end' <<<"$1" 2>/dev/null || printf 'unreadable file list\n'
}

# --- the sandbox -------------------------------------------------------------

# rehearsal_release_put REPO PATH CONTENT MESSAGE — one file, one commit on
# main, through the contents API as the HOST identity (the sandbox's owner).
# Updates carry the blob's sha, which the API requires.
rehearsal_release_put() {
  local repo="$1" path="$2" content="$3" message="$4" sha
  sha="$(gh api "repos/$repo/contents/$path?ref=main" --jq .sha 2>/dev/null || true)"
  gh api -X PUT "repos/$repo/contents/$path" -f message="$message" \
    -f content="$(printf '%s' "$content" | base64 | tr -d '\n')" \
    ${sha:+-f sha="$sha"} >/dev/null
}

# rehearsal_release_sync REPO PATH CONTENT MESSAGE — a shared sandbox file is
# written when main does not already carry exactly CONTENT: absent, or left by
# a round run at another ceremony pin or doctrine. A reused sandbox keeps one
# copy, and that copy is always crew's current one (#767 round 3: written only
# when absent, a later round cut at the first round's pin).
rehearsal_release_sync() {
  local cur
  cur="$(gh api "repos/$1/contents/$2?ref=main" --jq .content 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ "$cur" = "$(printf '%s' "$3")" ] && return 0
  rehearsal_release_put "$@"
}

# rehearsal_release_seed REPO TRACK_PATH PREFIX PIN — the track, built the way
# a consumer's is: tagged at 0.0.1 BEFORE VERSION is armed (no tag yet is the
# operator's first cut, which the duty refuses on purpose), then armed
# 0.0.2-dev, then one change on the track — a fragment, the only shape a
# final cut ships. The shared files — the release caller naming the pin and
# the doctrine the session is told to read — are synced to crew's own, so a
# reused sandbox keeps one copy at crew's current pin. Registers as it goes;
# call it bare.
rehearsal_release_seed() {
  local repo="$1" path="$2" prefix="$3" pin="$4" main_sha
  REHEARSAL_RELEASE_REPO="$repo"
  # A workflow_dispatch-only caller: the duty reads the pin off it, and it
  # never runs, so no check run lands on the sandbox's main (the duty's CI
  # read then answers `none`, which RELEASE_CI_GRACE_S=0 lets it cut).
  rehearsal_release_sync "$repo" .github/workflows/release.yml "name: release
# Drill fixture (crew's release leg, #762): the duty reads the ceremony pin
# below. Dispatch-only, so nothing ever runs on this sandbox.
on: workflow_dispatch
jobs:
  release:
    uses: heavy-duty/ceremony/.github/workflows/release.yml@$pin
" "drill: release caller at ceremony@$pin" || return 1
  rehearsal_release_sync "$repo" .ceremony/RELEASES.md "$(cat "$ROOT/.ceremony/RELEASES.md")" \
    "drill: release doctrine" || return 1
  rehearsal_release_sync "$repo" AGENTS.md "# Drill sandbox

A fixture repository for crew's drill. Its doctrine is \`.ceremony/\`; a track
under \`release-drill/\` is a release fixture with its own VERSION, CHANGELOG.md,
changelog.d/ and drills/." "drill: doctrine entrypoint" || return 1
  rehearsal_release_put "$repo" "$path/VERSION" "0.0.1
" "drill: track $path at 0.0.1" || return 1
  REHEARSAL_RELEASE_FILES="$path/VERSION"
  rehearsal_release_put "$repo" "$path/CHANGELOG.md" "# Changelog

A drill fixture's ledger (crew's release leg, #762).

<!-- Release sections land below this line, newest first, each stamped by the
release PR from the fragments in changelog.d/. -->
" "drill: track changelog" || return 1
  REHEARSAL_RELEASE_FILES="$REHEARSAL_RELEASE_FILES $path/CHANGELOG.md"
  rehearsal_release_put "$repo" "$path/changelog.d/README.md" "$(cat "$ROOT/changelog.d/README.md")" \
    "drill: track changelog.d" || return 1
  REHEARSAL_RELEASE_FILES="$REHEARSAL_RELEASE_FILES $path/changelog.d/README.md"
  rehearsal_release_put "$repo" "$path/drills/README.md" "# Drill records

One file per version, \`drills/<version>.md\`, holding at least one
non-whitespace character. This track is a drill fixture with nothing to
install or walk, so a record may be a WAIVER: state that the drill is waived
and why, naming every file the release changes. Never claim a step that did
not run.
" "drill: track drill doctrine" || return 1
  REHEARSAL_RELEASE_FILES="$REHEARSAL_RELEASE_FILES $path/drills/README.md"
  main_sha="$(gh api "repos/$repo/commits/main" --jq .sha)" || return 1
  gh api -X POST "repos/$repo/git/refs" -f ref="refs/tags/${prefix}0.0.1" -f sha="$main_sha" >/dev/null || return 1
  REHEARSAL_RELEASE_TAG="${prefix}0.0.1"
  rehearsal_release_put "$repo" "$path/VERSION" "0.0.2-dev
" "drill: arm $path for 0.0.2" || return 1
  rehearsal_release_put "$repo" "$path/changelog.d/1.md" "### Added

- The drill track's first change: a fragment for the release leg to consume (#762).
" "drill: a change on track $path" || return 1
  REHEARSAL_RELEASE_FILES="$REHEARSAL_RELEASE_FILES $path/changelog.d/1.md"
}

# rehearsal_release_invoke REPO TRACK_PATH PREFIX — one run of the duty over
# this round's track alone, inside the box's own lock so a stray tick cannot
# interleave, with the two production clocks at zero. Prints its stdout.
rehearsal_release_invoke() {
  local track="$1:$2:$3:auto"
  bx "flock -w 600 \"\$HOME/duty/.duty.lock\" bash -c '
    set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    ME=\"\$(gh_identity)\"
    source \"\$DUTY_DIR/lib/duty-release.sh\"
    RELEASE_TRACKS=\"$track\" RELEASE_QUIET_S=0 RELEASE_CI_GRACE_S=0
    duty_release
  '" 2>&1
}

# --- cleanup -----------------------------------------------------------------

# Everything the leg made, unwound from the registry: the cut closed if a
# person has not already, its branch deleted on the fork, the seed tag and the
# track's files removed, and the box's per-track memory dropped. The shared
# caller and doctrine stay: the next round reuses them. Never fails the round.
rehearsal_release_cleanup() {
  local repo="$REHEARSAL_RELEASE_REPO" file sha
  [ -n "$repo" ] || return 0
  if [ -n "$REHEARSAL_RELEASE_PR" ]; then
    gh pr close "$REHEARSAL_RELEASE_PR" -R "$repo" >/dev/null 2>&1 || true
  fi
  if [ -n "$REHEARSAL_RELEASE_FORK" ] && [ -n "$REHEARSAL_RELEASE_BRANCH" ]; then
    bx "gh api -X DELETE 'repos/$REHEARSAL_RELEASE_FORK/git/refs/heads/$REHEARSAL_RELEASE_BRANCH'" >/dev/null 2>&1 || true
  fi
  if [ -n "$REHEARSAL_RELEASE_TAG" ]; then
    gh api -X DELETE "repos/$repo/git/refs/tags/$REHEARSAL_RELEASE_TAG" >/dev/null 2>&1 || true
  fi
  for file in $REHEARSAL_RELEASE_FILES; do
    sha="$(gh api "repos/$repo/contents/$file?ref=main" --jq .sha 2>/dev/null || true)"
    [ -n "$sha" ] || continue
    gh api -X DELETE "repos/$repo/contents/$file" -f message="drill: remove release fixture $file" \
      -f sha="$sha" >/dev/null 2>&1 || true
  done
  if [ -n "$REHEARSAL_RELEASE_SLUG" ]; then
    bx "rm -f ~/duty/.release-cut-$REHEARSAL_RELEASE_SLUG ~/duty/.release-tried-$REHEARSAL_RELEASE_SLUG ~/duty/.release-due-$REHEARSAL_RELEASE_SLUG" >/dev/null 2>&1 || true
  fi
  REHEARSAL_RELEASE_REPO="" REHEARSAL_RELEASE_FILES=""
  REHEARSAL_RELEASE_TAG="" REHEARSAL_RELEASE_FORK="" REHEARSAL_RELEASE_BRANCH=""
  REHEARSAL_RELEASE_PR="" REHEARSAL_RELEASE_SLUG=""
  return 0
}

# graded NAME PREDICATE... — a row, with what it read under a red.
rehearsal_release_graded() {
  local name="$1" read; shift
  if read="$("$@" 2>&1)" && [ "$read" = ok ]; then
    ok "$name"; return 0
  fi
  echo "  read: $read"
  fail "$name"; return 1
}

# --- the leg -----------------------------------------------------------------

# rehearsal_release_drill REPO IDENTITY — the triage-role leg (#762).
# shellcheck disable=SC2016  # the inline predicates expand in their own bash -c
rehearsal_release_drill() {
  local repo="$1" identity="$2" owner pin stamp path prefix branch fork
  local out1 out2 out3 pr pulls pull files tick refusal
  # Declared above the first `fail`, for the reason the audit leg gives: a
  # re-initialisation below one would let a red row return an ok verdict.
  local release_ok=0

  if [ "${REHEARSAL_RELEASE_DRILL:-1}" -eq 0 ]; then
    skip "release: one cut per tick on a fresh track, held, then refused (--no-release-drill)"
    rehearsal_release_verdict skip "--no-release-drill"
    return 0
  fi
  owner="${repo%%/*}"
  if [ "$identity" = "$owner" ]; then
    skip "release: the cut pushes from a fork the box identity owns, and $identity owns $repo itself"
    rehearsal_release_verdict skip "box identity $identity owns the sandbox; a cut needs a fork it owns"
    return 0
  fi
  pin="$(grep -oE 'heavy-duty/ceremony/\.github/workflows/release\.yml@[^[:space:]]+' \
    "$ROOT/.github/workflows/release.yml" | head -1 | sed 's/.*@//')"
  if [ -z "$pin" ]; then
    fail "release: crew's own ceremony pin resolves"
    rehearsal_release_verdict fail "crew's release.yml names no ceremony pin"
    return 1
  fi

  # The fork the cut is pushed from — the builder block's helpers, as this
  # box's identity. Resolved, or created and then resolved.
  if ! fork="$(rehearsal_resolve_builder_fork "$repo" "$identity" 2>/dev/null)"; then
    rehearsal_create_builder_fork "$repo" >/dev/null 2>&1 || true
    wait_for 120 "release: box-owned fork of the sandbox resolves" \
      rehearsal_resolve_builder_fork "$repo" "$identity"
    fork="$(rehearsal_resolve_builder_fork "$repo" "$identity" 2>/dev/null || true)"
  fi
  if [ -z "$fork" ]; then
    fail "release: box-owned fork of the sandbox"
    rehearsal_release_verdict fail "no fork of $repo owned by $identity"
    return 1
  fi
  REHEARSAL_RELEASE_FORK="$fork"
  gh api "repos/$repo/labels" -f name="${LABEL_RELEASE:-release}" -f color=0052cc >/dev/null 2>&1 || true

  stamp="$(date -u +%Y%m%d%H%M%S)"
  path="release-drill/$stamp"
  prefix="drill$stamp-"
  branch="release/${prefix}0.0.2"
  REHEARSAL_RELEASE_SLUG="$(printf '%s-%s' "${repo//\//_}" "${prefix//\//_}")"
  # NOT a command substitution: the seed registers what it makes.
  if rehearsal_release_seed "$repo" "$path" "$prefix" "$pin"; then
    ok "release: a fresh track tagged ${prefix}0.0.1, armed 0.0.2-dev, one fragment merged"
  else
    fail "release: a fresh track tagged ${prefix}0.0.1, armed 0.0.2-dev, one fragment merged"
    rehearsal_release_cleanup
    rehearsal_release_verdict fail "the track could not be seeded"
    return 1
  fi
  REHEARSAL_RELEASE_BRANCH="$branch"

  # -- tick 1: one cut --
  out1="$(rehearsal_release_invoke "$repo" "$path" "$prefix")" || true
  pr="$(rehearsal_release_opened_pr "$out1" "$repo")"
  if [ -n "$pr" ]; then
    REHEARSAL_RELEASE_PR="$pr"
    ok "release: one tick opened one release PR (#$pr)"
  else
    printf '%s\n' "$out1" | grep -E 'release' | sed 's/^/  read: /' | tail -12
    fail "release: one tick opened one release PR"
    rehearsal_release_cleanup
    rehearsal_release_verdict fail "the first tick opened no release PR (or more than one)"
    return 1
  fi
  pulls="$(gh api "repos/$repo/pulls?state=open&per_page=100" 2>/dev/null || printf '[]')"
  rehearsal_release_graded "release: the board carries exactly one release PR for the track" \
    bash -c '[ "$1" = 1 ] && echo ok || echo "count $1"' _ "$(rehearsal_release_open_count "$pulls" "$branch")" \
    || release_ok=1
  pull="$(gh api "repos/$repo/pulls/$pr" 2>/dev/null || printf '{}')"
  rehearsal_release_graded "release: the PR is the cut — labelled, against main, from $identity's fork" \
    rehearsal_release_pr_shape "$pull" "$identity" "$branch" || release_ok=1
  files="$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" 2>/dev/null | jq -s 'add // []' 2>/dev/null || printf '[]')"
  rehearsal_release_graded "release: VERSION, CHANGELOG.md and the drill record changed; the fragment consumed" \
    rehearsal_release_files_shape "$files" "$path" 0.0.2 1.md || release_ok=1
  # Read on the fork, where the head commit was pushed: the base repository
  # serves a fork's commit only through the network's shared objects.
  rehearsal_release_graded "release: VERSION at the PR's head reads 0.0.2" \
    bash -c 'v="$(gh api "repos/$1/contents/$2/VERSION?ref=$3" --jq .content 2>/dev/null | base64 -d 2>/dev/null | tr -d "[:space:]")"; [ "$v" = 0.0.2 ] && echo ok || echo "VERSION reads [$v]"' \
    _ "$fork" "$path" "$(jq -r '.head.sha // empty' <<<"$pull")" || release_ok=1

  # -- tick 2: the open cut holds the track --
  out2="$(rehearsal_release_invoke "$repo" "$path" "$prefix")" || true
  tick="$(rehearsal_release_second_tick "$out2" "$repo" "$path" "$prefix")"
  rehearsal_release_graded "release: a second tick opens nothing — the engine's own cut holds the track" \
    bash -c '[ "$1" = held ] && echo ok || echo "the second tick read: $1"' _ "$tick" || release_ok=1
  pulls="$(gh api "repos/$repo/pulls?state=open&per_page=100" 2>/dev/null || printf '[]')"
  rehearsal_release_graded "release: still exactly one release PR after the second tick" \
    bash -c '[ "$1" = 1 ] && echo ok || echo "count $1"' _ "$(rehearsal_release_open_count "$pulls" "$branch")" \
    || release_ok=1

  # -- a person refuses it: closed unmerged, remembered, its branch freed --
  gh pr close "$pr" -R "$repo" >/dev/null 2>&1 || true
  out3="$(rehearsal_release_invoke "$repo" "$path" "$prefix")" || true
  refusal="$(rehearsal_release_refused "$out3" "$repo" "$pr")"
  rehearsal_release_graded "release: a cut closed unmerged is recorded as refused" \
    bash -c '[ "$1" = refused ] && echo ok || echo "the tick after the close read: $1"' _ "$refusal" || release_ok=1
  rehearsal_release_graded "release: the refused cut's branch is deleted on the fork" \
    bash -c 'if gh api "repos/$1/git/ref/heads/$2" >/dev/null 2>&1; then echo "refs/heads/$2 still on $1"; else echo ok; fi' \
    _ "$fork" "$branch" || release_ok=1
  if grep -F "release: $repo — cutting " <<<"$out3" >/dev/null; then
    echo "  read: $(grep -F "release: $repo — cutting " <<<"$out3" | head -1)"
    fail "release: the refused track is not cut again"; release_ok=1
  else
    ok "release: the refused track is not cut again"
  fi

  rehearsal_release_cleanup
  if [ "$release_ok" -eq 0 ]; then
    rehearsal_release_verdict ok
    return 0
  fi
  rehearsal_release_verdict fail "a cut, hold or refusal row is red (see the release: rows)"
  return 1
}
