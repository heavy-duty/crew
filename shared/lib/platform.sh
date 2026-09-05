#!/usr/bin/env bash
# shared/lib/platform.sh — the ONE declaration of the platform this crew was
# built and tested against, and the one reporter that reads it (#679 Part 2).
#
# Before this file there was no declaration at all: the number 0.10.0 lived
# twice inside cli/crew, once as a hard refusal (`crew down --force`) and once
# as a soft degradation (clone sizing), each having learned it independently,
# and neither install nor `crew up` said a word. An operator on box 0.9.x
# installed cleanly, hired boxes, ran duty for days and met the requirement for
# the first time at `crew down --force` — a verb reached in an incident, which
# is the worst possible moment to discover a platform floor.
#
# FLOORS, NOT EQUALITY, AND THE OPPOSITE IS ONE LINE TO REVERSE (#679 D13).
# The declaration means "built and tested against box 0.10.0 and rig 0.4.0":
# below the floor is a finding, at or above it is silence. Exact-equality
# pinning would make box 0.10.1 — which exists on box's main today — an error
# on a fleet nothing is wrong with, and would put the fleet into a lockstep
# upgrade it has no mechanism for. If exact pinning is wanted, the comparison
# in platform_below_floor is the single line to change and nothing else moves.
#
# THE CHECK REPORTS; IT NEVER REFUSES (#679 D14). Refuse-or-degrade is decided
# by the CAPABILITY, never by the version, and each call site keeps its own
# consequence: `crew down --force` still refuses below the floor because there
# is no `down --force` to degrade to, and clone sizing still warns and
# continues because a clone that carries its source's size is still a clone.
# Both keep probing box's own help for the capability — a version string is a
# proxy a fork or a local build gets wrong — and read only the NUMBER IN THEIR
# MESSAGE from here. A check that turned the degradation into a refusal would
# break rosters that work today.
#
# THE TWO HALVES ARE NOT READ THE SAME WAY, AND THAT IS THE POINT (#679 D15).
# box runs on the HOST, so `box --version` answers for it wherever crew runs.
# rig runs INSIDE THE GUEST — under #679 D4 crew installs it there as part of
# the mint — so there is no host-side rig to interrogate, and its version is
# read back out of the boxes, from the /etc/rig/manifest that rig itself writes
# (crew#220). A host with no boxes therefore reports nothing about rig: there
# is no guest to look in yet, and the next mint is what puts one there. A box
# IN THE ROSTER that exists and carries no readable rig version is a finding,
# because that is a guest rig was supposed to have converged and did not — and
# the roster is what makes "was supposed to" true of it. A box on the host that
# crew was never asked about is neither read nor reported; see
# platform_roster_names for why that scope, and not `box list`, is the fleet.
#
# THE REPORT NAMES ALL FIVE, ALWAYS (#679 D16): crew's own version, the box
# version found and wanted, and the rig version found and wanted. A message
# naming only the offending half makes the reader go looking for the other, and
# this triple is the thing the fleet has been reasoning about without ever
# writing it down. The reporting shape is version-skew.sh's, deliberately: that
# file reports host-versus-engine skew on a different axis and never refuses
# the flip, which is the same discipline, and reusing it beats inventing a
# second vocabulary for "your versions disagree".

# --- the declaration -------------------------------------------------------
# A bump is these two lines and nothing else. Every other statement of a box or
# rig version in the tree is a COMMENT about when a capability arrived, which
# is a different sentence and does not move when the floor does.
CREW_PLATFORM_BOX_MIN="0.10.0"
CREW_PLATFORM_RIG_MIN="0.4.0"

# platform_version_of LINE — the bare version out of a `<tool> <ver> (<root>)`
# answer, which is the shape both box and rig print for --version:
#
#     box 0.10.0 (/opt/box/versions/0.10.0)
#     rig 0.4.0 (/home/dev/.local/share/rig/versions/0.4.0)
#
# Empty for anything that is not that shape, so an error message, a usage dump
# or a `command not found` degrades to "not found" rather than being compared
# as if it were a version.
platform_version_of() { # LINE
  local line="${1:-}" v
  v="$(awk 'NR==1 {print $2}' <<<"$line" 2>/dev/null || true)"
  case "$v" in
    [0-9]*.[0-9]*) printf '%s\n' "$v" ;;
    *) : ;;
  esac
}

# platform_below_floor FOUND WANTED — true when FOUND is strictly below WANTED.
#
# Compared field by field as integers rather than with sort -V, because the
# pre-release suffixes both tools use (0.10.1-dev, 0.3.2-dev) sort AFTER their
# release under -V and BEFORE it under semver, and the answer that matters here
# is that 0.10.1-dev is not below the 0.10.0 floor. The suffix is therefore
# dropped and the numeric triple alone decides; a -dev of the floor version
# itself reads as the floor, which is the forgiving direction and the one this
# file's whole disposition is set to.
#
# An unparseable or empty FOUND is NOT below the floor by this function — the
# caller distinguishes "absent" from "old", because they are different findings
# and only one of them is fixed by upgrading.
platform_below_floor() { # FOUND WANTED
  local found="${1:-}" wanted="${2:-}" i f w
  [ -n "$found" ] && [ -n "$wanted" ] || return 1
  found="${found%%-*}"; wanted="${wanted%%-*}"
  for i in 1 2 3; do
    f="$(cut -d. -f"$i" <<<"$found")"; w="$(cut -d. -f"$i" <<<"$wanted")"
    case "$f" in ''|*[!0-9]*) f=0 ;; esac
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    [ "$f" -lt "$w" ] && return 0
    [ "$f" -gt "$w" ] && return 1
  done
  return 1
}

# platform_box_version — what THIS host's box answers, or empty when there is
# no box on PATH at all. `|| true` for the reason it is on every other probe in
# this fleet: an unreachable tool must degrade to a finding, never kill a
# caller running under `set -e`.
platform_box_version() {
  command -v box >/dev/null 2>&1 || return 0
  platform_version_of "$(box --version 2>/dev/null | head -1 || true)"
}

# platform_roster_names [ROSTER_FILE] — the boxes THIS crew was asked about, one
# name per line; empty when there is no fleet definition to read.
#
# A BOX ON THE HOST THAT IS NOT IN THE ROSTER IS NOT THIS CHECK'S BUSINESS
# (#679, round 1). It is crew's settled position, and it is load-bearing enough
# to have a flag behind it: `crew up` leaves such a box alone and says so in as
# many words — `boxes on this host but not in the roster (left alone):`
# (cli/crew:2670) — `crew upgrade --all` intersects `box list` with the roster
# rather than reaching every box (cli/crew:4298), and `--allow-offroster` is the
# deliberate override for the verbs that take one. A guest crew was never asked
# about carries no /etc/rig/manifest for a reason that is not a defect, so
# reporting it puts a finding on a healthy fleet the first time crew shares a
# host with an operator's own box — `box new --name ada --user ada` is box's own
# README example — and there would be no way to silence the line. That is the
# failure this check exists to avoid, arriving through the back door.
#
# THE CALLER PASSES ITS OWN RESOLVED ROSTER WHERE IT HAS ONE. cli/crew resolves
# a fleet definition at startup, with a cascade this file must not grow a second
# and divergent answer to, so `crew up` hands its $ROSTER down. Only the
# installer takes the fallback below, and the fallback deliberately reads the
# OPERATOR-OWNED locations alone: cli/crew also falls back to $PWD and to the
# shipped examples/, which are conveniences for running a command out of a
# checkout rather than statements about which boxes this host owns, and an
# installer that adopted them would report on a fleet that is not there.
#
# No fleet definition is not a finding either. That is the state of a host the
# moment before its first `crew init`, and it lands on the same silence D15
# already gives a host with no boxes: there is nothing crew was asked about, so
# there is nothing to say about rig.
platform_roster_names() { # [ROSTER_FILE]
  local roster="${1:-}"
  if [ -z "$roster" ]; then
    if [ -n "${CREW_ROSTER:-}" ]; then
      roster="$CREW_ROSTER"
    elif [ -n "${CREW_CONFIG_DIR:-}" ]; then
      roster="$CREW_CONFIG_DIR/fleet.roster"
    else
      roster="${XDG_CONFIG_HOME:-$HOME/.config}/crew/fleet.roster"
    fi
  fi
  [ -r "$roster" ] || return 0
  # `|| true` because a roster of nothing but comments is a real file and an
  # empty match, and grep's rc 1 there would kill a caller under `set -e`.
  { grep -vE '^[[:space:]]*(#|$)' "$roster" || true; } | awk '{print $1}'
}

# platform_guest_rig_versions — one `<box>\t<version>` row per box that answers,
# read from the provenance file rig writes inside the guest, /etc/rig/manifest
# (crew#220):
#
#     /etc/rig/manifest   schema=1
#                         bootstrapped_by=0.4.0
#                         converged_by=0.4.0
#
# converged_by first and bootstrapped_by as the fallback: they are the same rig
# on a box nothing has re-converged, and where they differ the converging one is
# the rig whose behaviour the box now carries.
#
# The version is empty for a box that answered with no /etc/rig/manifest — a
# guest rig never converged — and it still emits a row, because "answered, no rig"
# and "did not answer" are different findings and collapsing them is exactly the
# defect crew#220's rule 5 exists to prevent. A box that does not answer at all
# emits nothing: crew knows nothing about it, and a platform report is not the
# surface that should be inventing a verdict for an unreachable box.
#
# 0644 both, so this read takes no sudo and must not grow one.
#
# THE WALK IS THE ROSTER, NOT THE HOST. `box list` is still what enumerates —
# crew reports on boxes that exist, not on roster rows that do not — but a name
# the roster does not carry is skipped BEFORE the exec, so an off-roster box is
# never opened, never mind reported. Skipping before rather than after is the
# half that matters: `crew up`'s promise at cli/crew:2670 is that such a box is
# left alone, and opening a login shell inside it to read its files is not
# leaving it alone, however quietly the answer is then discarded.
#
# THE COST, since it is paid on an interactive path. The walk is sequential with
# a 10s timeout per guest, so a report costs up to 10s × ROSTER boxes before
# `crew up` or the installer does anything. That is the same shape and the same
# bound as hired_engine_versions' walk beside it (shared/lib/version-skew.sh),
# which runs on these same two surfaces today; one slow idiom shared beats a
# second faster one invented for the neighbour of the job it already does. The
# roster scoping above is what keeps the bound to the boxes crew owns.
#
# WHY THIS RETURNS NOTHING IS A SEPARATE QUESTION FROM WHAT IT RETURNED, and
# platform_guest_read_blocker below is where it is answered. "no boxes" and
# "could not look" are different sentences, and this function cannot tell them
# apart on its own: it emits rows, and an empty set of rows is what both look
# like from the outside.
platform_guest_rig_versions() { # [ROSTER_FILE]
  command -v box >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local name answer version roster_names
  roster_names="$(platform_roster_names "${1:-}")"
  [ -n "$roster_names" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qxF -- "$name" <<<"$roster_names" || continue
    answer="$(timeout 10 box exec "$name" -- bash -lc \
      'echo probe=ok; [ -r /etc/rig/manifest ] && cat /etc/rig/manifest' \
      </dev/null 2>/dev/null | tr -d '\r' || true)"
    case "$answer" in *probe=ok*) : ;; *) continue ;; esac
    version="$(sed -n 's/^converged_by=//p' <<<"$answer" | head -1)"
    [ -n "$version" ] ||
      version="$(sed -n 's/^bootstrapped_by=//p' <<<"$answer" | head -1)"
    printf '%s\t%s\n' "$name" "$version"
  done < <(box list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
}

# platform_guest_read_blocker — empty when the guests CAN be read, whether or
# not there turn out to be any; otherwise the short reason none of them was.
#
# "NO BOXES" AND "COULD NOT LOOK" ARE DIFFERENT ANSWERS (#679 round 2). Without
# this, a host with a full fleet and no `jq` was told `rig: no boxes found` —
# the fleet reported as empty because the reader could not be run. The two
# blockers are facts about the HOST, not about the fleet: without `box` there is
# no way to enumerate guests at all, and `box list --json` is JSON, so without
# `jq` the enumeration cannot be parsed.
#
# NEITHER IS A FINDING, and this function deliberately produces none. A missing
# box is already the box half's own finding, and a missing jq is the installer's
# business rather than the platform floor's — crew degrades on it everywhere
# else too. What was wrong was the WORDING of the found/wanted line, so that is
# all this corrects.
platform_guest_read_blocker() {
  command -v box >/dev/null 2>&1 || { printf 'no box on this host\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'no jq on this host\n'; return 0; }
}

# report_platform CREW_VERSION — the whole check, in the one wording both
# surfaces print (#679 D12). Silent and rc 0 when everything is at or above its
# floor; otherwise one block on stderr naming all five figures (#679 D16).
#
# NEVER refuses and never returns non-zero: the consequence belongs to the call
# site and the version never decides it (#679 D14). install.sh and `crew up`
# both call this and both keep going.
#
# ROSTER_FILE is the fleet whose guests the rig half reads, and it is optional
# only because one of the two surfaces has no resolver of its own: `crew up`
# passes its already-resolved $ROSTER, the installer passes nothing and
# platform_roster_names resolves from the environment. D12's "identical
# messages" is a statement about the two surfaces on ONE host, and on one host
# those two answers are the same fleet definition — which is why the fixture
# that diffs them gives both the same one rather than only the verb.
#
# THAT IDENTITY HOLDS PER ENVIRONMENT, NOT PER LOGIN (#679 round 2, and the
# limit is written down here rather than left to be rediscovered). Both surfaces
# resolve CREW_ROSTER → CREW_CONFIG_DIR → XDG, so they agree wherever they see
# the same environment. An operator whose CREW_CONFIG_DIR is exported from a
# shell rc and who then installs under `sudo` with a reset HOME gets the box
# half identical and the rig half silent, because the installer is reading a
# different environment rather than a different host. That is inherent to
# environment-driven config and is not something this reporter can second-guess:
# adopting $PWD or the shipped examples/ to paper over it is exactly the
# guessing platform_roster_names refuses above.
report_platform() { # CREW_VERSION [ROSTER_FILE]
  local crew_version="${1:-unknown}" roster="${2:-}"
  local box_found box_shown rows rig_shown blocker name version line findings=""
  box_found="$(platform_box_version)"

  if [ -z "$box_found" ]; then
    findings="${findings}box: not found on PATH — crew cannot mint, hire or stop a box without it"$'\n'
  elif platform_below_floor "$box_found" "$CREW_PLATFORM_BOX_MIN"; then
    findings="${findings}box: below the floor — 'crew down --force' refuses, and a clone is not sized"$'\n'
  fi

  rows="$(platform_guest_rig_versions "$roster")"
  while IFS=$'\t' read -r name version; do
    [ -n "$name" ] || continue
    if [ -z "$version" ]; then
      findings="${findings}rig: $name carries no /etc/rig/manifest — rig never converged that guest"$'\n'
    elif platform_below_floor "$version" "$CREW_PLATFORM_RIG_MIN"; then
      findings="${findings}rig: $name was converged by $version, below the floor"$'\n'
    fi
  done <<<"$rows"

  [ -n "${findings//[$'\n'[:space:]]/}" ] || return 0

  # EACH HALF CARRIES ITS OWN VERB rather than the format string hardcoding
  # `found`, and both reasons are round 2's. The box default used to be the
  # phrase "not found", which rendered as `box: not found found, 0.10.0 wanted`
  # on the most ordinary first install there is — crew installed before box. And
  # the rig half has a third answer that is neither a version nor a count: it
  # could not look, which "<something> found" cannot say at all.
  box_shown="${box_found:-none} found"
  rig_shown="$(platform_rig_summary "$rows") found"
  blocker="$(platform_guest_read_blocker)"
  if [ -n "$blocker" ] && [ -z "${rows//[$'\n'[:space:]]/}" ]; then
    rig_shown="not read ($blocker)"
  fi

  # All five, in every finding. The found/wanted pairs come first because they
  # are what the reader is here for; the per-box detail follows.
  printf 'crew: platform check — this crew is crew@%s\n' "$crew_version" >&2
  printf 'crew:   box: %s, %s wanted (on this host)\n' \
    "$box_shown" "$CREW_PLATFORM_BOX_MIN" >&2
  printf 'crew:   rig: %s, %s wanted (inside the boxes)\n' \
    "$rig_shown" "$CREW_PLATFORM_RIG_MIN" >&2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'crew:   · %s\n' "$line" >&2
  done <<<"$findings"
  printf 'crew: crew is built and tested against box %s and rig %s; below either, crew still runs and says so here rather than refusing\n' \
    "$CREW_PLATFORM_BOX_MIN" "$CREW_PLATFORM_RIG_MIN" >&2
}

# platform_rig_summary ROWS — the rig half of the found/wanted line. rig is a
# per-guest fact and there are N guests, so "found" is the SET, deduplicated and
# in a stable order; a box answering with no /etc/rig/manifest contributes `none`.
# `no boxes` where there is no guest to look in at all — which is a statement
# about the fleet and not about rig, and is why it is not a finding.
platform_rig_summary() { # ROWS
  local rows="${1:-}" out
  [ -n "${rows//[$'\n'[:space:]]/}" ] || { printf 'no boxes\n'; return 0; }
  out="$(awk -F '\t' 'NF { print ($2 == "" ? "none" : $2) }' <<<"$rows" \
    | sort -u | paste -sd, - )"
  printf '%s\n' "${out:-no boxes}"
}
