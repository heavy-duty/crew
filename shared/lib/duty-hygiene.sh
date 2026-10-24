# duty-hygiene.sh — the backlog-hygiene sweep (triage role, hourly), gated on
# whether the board moved. There is no cheap shell test for "this label is no
# longer true", so the sweep itself stays judgment-only — but whether a sweep
# could find anything at all IS cheap: a label cannot have become untrue if
# nothing on the board changed since the last session looked. The judgment is
# the expensive half and it is still the model's; the trigger is the cheap half
# and it is now a listing (#465).
#
# It stays the backstop for every fail-safe default in duty-triage.sh. Two
# things keep that true rather than nominal: HYGIENE_FLOOR, which sweeps a
# never-changing board anyway because some of what hygiene owns turns on the
# clock and not on the board (a 48h reclaim, an issue the world made obsolete); and a gate that FAILS OPEN — a listing that errors
# or a ledger line that will not parse sweeps and warns, because a budget that
# cannot read its balance must not spend, while a backstop that cannot read the
# board must not stop being the backstop (#59, #464).
#
# shellcheck shell=bash

# The floor's shipped default, in seconds, used only when the loaded role conf
# predates it. Config and engine are installed together, but they can skew
# across an upgrade, and under `set -u` a bare reference would abort the whole
# tick rather than degrade — the wrong direction for a value whose only job is
# to make the sweep MORE frequent. Kept equal to shared/conf/roles/triage.conf,
# and `hygiene-floor-default-matches-conf` fails if the two ever drift.
HYGIENE_FLOOR_DEFAULT=86400

# The cap on the bounded listing. Reaching it means the board is larger than the
# digest can see, so a change past the cap would be invisible — that is a hole,
# not a saving, and it fails open like every other thing this gate cannot read.
HYGIENE_LISTING_LIMIT=500

# _hygiene_listing REPO — the one bounded read the gate is allowed, and the
# whole of its API cost. Four fields, because the digest is asserted one field
# at a time: `number` catches an issue arriving or (by its absence from an
# open-state listing) closing, `updatedAt` catches a body or comment, `labels`
# catches the queue moves that are this sweep's entire subject, and `assignees`
# catches the claim moves the reclaim clock reads. stderr is NOT swallowed: a
# gate that cannot read the board says why, in the log the operator already has.
_hygiene_listing() { # $1=repo -> listing JSON on stdout, nonzero if gh could not say
  gh issue list -R "$1" --state open --limit "$HYGIENE_LISTING_LIMIT" \
    --json number,updatedAt,labels,assignees
}

# _hygiene_digest — stdin the listing JSON, stdout one digest for the whole
# board. Nonzero if it cannot be computed, INCLUDING when the listing came back
# at the cap: a truncated board is not a board, and the caller sweeps.
#
# `cksum`, not `sha256sum`, for the reason _wt_dirt_id records: this is an
# identity for a local state file, not provenance, and cksum is POSIX, so the
# engine gains no new dependency on a fleet whose boxes differ in what is
# installed. Rows are sorted before hashing so the digest is a property of the
# BOARD and not of the order gh happened to return it in.
#
# THE MULTI-VALUE FIELDS ARE `tojson`, NOT `join(",")`. A separator join is not
# injective over names that may contain the separator: one label named `a,b` and
# two labels named `a` and `b` flatten to the identical field, so two different
# boards digest the same and a real change is suppressed. `updatedAt` sits in
# the same row and GitHub bumps it on every label event, so no live board can
# reach the collision today — but that is a fact about GitHub, not about this
# function, and a fingerprint must not borrow its injectivity from a neighbour.
# `tojson` quotes and escapes each element, so the array is recoverable from the
# field and distinct arrays give distinct fields. Assignees get the same
# treatment: a login cannot contain a comma, and this should not depend on it.
_hygiene_digest() {
  local json rows count
  json="$(cat)"
  [ -n "${json//[[:space:]]/}" ] || return 1
  rows="$(printf '%s' "$json" | jq -r '
      .[] | [ (.number|tostring),
              .updatedAt,
              ([.labels[].name]      | sort | tojson),
              ([.assignees[].login]  | sort | tojson) ] | @tsv
    ')" || return 1
  count="$(printf '%s\n' "$rows" | awk 'NF{c++} END{print c+0}')"
  [ "$count" -lt "$HYGIENE_LISTING_LIMIT" ] || return 1
  printf '%s' "$rows" | LC_ALL=C sort | cksum | awk '{print $1 "-" $2}'
}

# _hygiene_ledger_line REPO — this repo's row of .seen-hygiene, or nothing.
#
# rc 0 means the ledger was READ: the row is on stdout, and empty stdout means
# this repo has no row yet. NONZERO means it could not be read at all — awk's
# own status, propagated rather than translated, since the caller only asks
# whether the read happened. The two must not collapse into "no row": an
# unreadable ledger would then report itself as a first sweep — the right
# ACTION, since a first sweep sweeps, but silently, and a gate that cannot read
# its own state must say so like every other fail-open branch here (#59). No row
# and no ledger at all are both rc 0; only a file that exists and will not open
# is nonzero.
_hygiene_ledger_line() {
  local ledger="$DUTY_DIR/.seen-hygiene"
  [ -f "$ledger" ] || return 0
  awk -v r="$1" '$1 == r { print; exit }' "$ledger"
}

# _hygiene_ledger_commit REPO DIGEST EPOCH — replace this repo's row, keep every
# other, atomically. Same mv-into-place discipline as ledger_commit. Nonzero if
# the row did not land, and the caller says so: a rewrite that fails silently
# leaves the digest uncommitted, which re-sweeps next interval and is safe, but
# a ledger that has stopped accepting writes is an operator's problem and the
# only place it can surface is the log.
#
# The rebuild runs in a SUBSHELL so a failed `awk` can abort before the `mv`:
# in a `{ }` group the `exit` would take the whole duty tick with it, and
# without one a truncated rebuild would be moved into place, dropping every
# other repo's row.
_hygiene_ledger_commit() {
  local ledger="$DUTY_DIR/.seen-hygiene" tmp
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  (
    if [ -f "$ledger" ]; then awk -v r="$1" '$1 != r' "$ledger" || exit 1; fi
    printf '%s %s %s\n' "$1" "$2" "$3"
  ) >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ledger"
}

# _hygiene_gate REPO — rc 0 sweep this repo, rc 1 skip it. Two answers come back
# in globals rather than on stdout, for the reason _resume_gate states: every
# report here is a log line and log writes to stdout, so a function returning
# its answer through the same channel would fold its own reporting into it.
#   HYGIENE_DIGEST         what to commit AFTER the session, empty when the gate
#                          could not read the board (nothing is committed then,
#                          so the next interval decides afresh).
#   HYGIENE_SWEEP_REASON   changed | first | floor | fail-open — logged, and the
#                          difference between a saving and a hole.
#
# THE COMPARISON IS EQUALITY, NOT ledger_filter's ORDERING, and that is the one
# design choice in this file worth arguing. ledger_filter re-fires when the
# value sorts GREATER, which is right for a timestamp and wrong for a digest: a
# board that changed into a state whose digest happens to sort below the stored
# one would be suppressed exactly when it moved. _wt_dirt_id answers the same
# problem by putting the fingerprint in the ID and a sentinel in the value —
# correct there, but here it would leave a board that returns to a previous
# state (a label added then removed) matching an id it has already seen, and
# hygiene's whole subject is labels going on and off. So the row is keyed by
# repo and compared for INEQUALITY, which fires in both directions and holds
# one row per repo forever rather than one per state ever seen. The floor needs
# a second field on that row anyway, which the two-field ledger cannot carry.
_hygiene_gate() {
  local repo="$1" line rest listing digest now age line_rc=0
  local prev_digest="" prev_ts=""
  local floor="${HYGIENE_FLOOR:-$HYGIENE_FLOOR_DEFAULT}"
  HYGIENE_DIGEST=""
  HYGIENE_SWEEP_REASON=""
  # The `:-` above supplies a value for an ABSENT conf; this supplies one for a
  # conf that set the wrong thing. Without it `HYGIENE_FLOOR=12h` makes the
  # comparison below an `integer expression expected` error, the floor branch
  # never fires, and the skip line reports `999999s of the 12hs floor elapsed —
  # no session this interval`: the module declaring the floor exceeded in the
  # act of declining to sweep. That is fail-CLOSED on the one value whose whole
  # job is to make the sweep more frequent, and it is the inverse of what the
  # rest of this file does with input it cannot read.
  case "$floor" in
    ''|*[!0-9]*)
      warn "$repo: HYGIENE_FLOOR is not a whole number of seconds ($floor); using the ${HYGIENE_FLOOR_DEFAULT}s default this interval (#465)"
      floor="$HYGIENE_FLOOR_DEFAULT"
      ;;
  esac
  line="$(_hygiene_ledger_line "$repo")" || line_rc=$?
  if [ "$line_rc" -ne 0 ]; then
    warn "$repo: the hygiene ledger could not be read; sweeping ungated this interval and committing nothing over it (#59)"
    HYGIENE_SWEEP_REASON=fail-open
    return 0
  fi
  if [ -n "$line" ]; then
    # Split by expansion rather than `read`, which would need a discard
    # variable for the repo field it already matched on. A row short of three
    # fields collapses to a non-numeric timestamp and falls into the malformed
    # branch below, which is where a short row belongs.
    rest="${line#* }"
    prev_digest="${rest%% *}"
    prev_ts="${rest#* }"
    # `case`, not `printf | grep -Eq`: this file sets no pipefail of its own but
    # is sourced by one that does, and a `grep -q` that exits on its first match
    # SIGPIPEs its producer into a 141 the pipeline then adopts. The repo guards
    # that shape (#449); pure bash has neither the pipeline nor the dependency.
    case "$prev_ts" in
      ''|*[!0-9]*) prev_ts="" ;;
    esac
    if [ -z "$prev_digest" ] || [ -z "$prev_ts" ]; then
      warn "$repo: the hygiene ledger row is malformed ($line); sweeping this interval and rewriting it (#465)"
      prev_digest=""
      prev_ts=""
    fi
  fi
  if ! listing="$(_hygiene_listing "$repo")"; then
    warn "$repo: the hygiene board listing failed; sweeping ungated this interval — a gate that cannot read the board must not stop being the backstop (#59)"
    HYGIENE_SWEEP_REASON=fail-open
    return 0
  fi
  if ! digest="$(printf '%s' "$listing" | _hygiene_digest)"; then
    warn "$repo: the hygiene board digest could not be computed (unparseable, or ${HYGIENE_LISTING_LIMIT}+ open issues); sweeping ungated this interval (#59)"
    HYGIENE_SWEEP_REASON=fail-open
    return 0
  fi
  HYGIENE_DIGEST="$digest"
  if [ -z "$prev_digest" ]; then
    HYGIENE_SWEEP_REASON=first
    return 0
  fi
  if [ "$digest" != "$prev_digest" ]; then
    HYGIENE_SWEEP_REASON=changed
    return 0
  fi
  now="$(date +%s)"
  age=$((now - prev_ts))
  if [ "$age" -ge "$floor" ]; then
    HYGIENE_SWEEP_REASON=floor
    return 0
  fi
  # EVERY INTERVAL, not report_suppressed's speak-on-change. This branch is the
  # one that spends nothing, so its line costs nothing either, and it removes
  # the thing #59 warns about: a suppression nobody can see. "stop paying, do
  # NOT stop saying."
  log "no hygiene duty: $repo board unchanged at $digest, ${age}s of the ${floor}s floor elapsed — no session this interval"
  return 1
}

duty_hygiene() {
  local R dir
  log "hygiene sweep starting"
  while IFS= read -r R; do
    [ -z "$R" ] && continue
    if ! _hygiene_gate "$R"; then
      continue
    fi
    log "$R: launching hygiene sweep ($HYGIENE_SWEEP_REASON)"
    dir="$WORK_DIR/${R//\//__}"
    ensure_checkout "$R" "$dir" || continue
    # Reset before the call, not after, the discipline duty-attention, -builder
    # and -review already follow. RUN_SESSION_RC is a global that outlives one
    # iteration, so an iteration whose session never ran would otherwise be
    # judged on the PREVIOUS repo's result and commit a digest nothing swept.
    # (The terminal breaker is not that case — it sets 75 itself, at
    # shared/lib/common/breaker.sh:44 — but it is not the only path that can
    # decline, and a reset that assumes failure costs nothing and cannot lie.)
    RUN_SESSION_RC=1
    run_session hygiene "$R" "$dir" "$TIMEOUT_HYGIENE" \
      "$(render_prompt hygiene.txt ME="$ME" REPO="$R")"
    # THE LEDGER IS EARNED BY THE SESSION, the rule .seen-build and .seen-resume
    # already follow: a crashed or timed-out session leaves the row uncommitted
    # and re-sweeps next interval rather than losing its wake to a digest it
    # never acted on.
    if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "$HYGIENE_DIGEST" ]; then
      _hygiene_ledger_commit "$R" "$HYGIENE_DIGEST" "$(date +%s)" ||
        warn "$R: the hygiene ledger row could not be written; the board re-sweeps next interval (#465)"
    fi
  done < <(read_repo_list "$REPOS_FILE")
  return 0
}
