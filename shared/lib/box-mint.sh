#!/usr/bin/env bash
# shared/lib/box-mint.sh — THE single writer of crew's fresh-mint sequence
# (#679 D9). cli/crew's `create_box` and drill/rehearsal.sh's phase-0 mint both
# call in here; neither spells the sequence itself.
#
# WHY A SHARED WRITER AND NOT "THE DRILL CALLS CREW'S MINT" (#679 D9, and both
# landings were live options). The drill deliberately does NOT call `crew new`:
# it mints at the role's own size, mirroring `crew new` rather than invoking it
# (#607 D4, drill/rehearsal.sh:311-313), and it cannot invoke it — `crew` is the
# thing the drill is about to INSTALL, so it is not on the host's PATH when
# phase 0 runs, and `crew hire` refuses to create anything (cli/crew:2369).
# Fixing both by hand and leaving them mirrored is refused by #679 D9 in as many
# words, and this fleet has paid for that shape twice already: blockers.jq
# against issueflow-reconcile, and the two SESSION END emitters that shipped
# broken twice before #553 bound them. So: one writer, two callers.
#
# WHAT CHANGED AND WHY THE OLD FORM CANNOT SURVIVE. crew used to mint with
# `box new --template <agent>-box`. box 0.10.0 RETIRES that spelling outright —
# bin/box:2094-2096 refuses `--template claude-box` and its three siblings, and
# the four agent tenants are gone from templates/ — while `crew down --force`
# has required box 0.10.0 or later since it landed. So crew contradicted itself:
# a host below 0.10.0 lost `down --force`, a host at or above it lost `crew new`,
# and there was no third option. The clone path (`box new --from`) is untouched
# by any of this and stays exactly as it was.
#
# THE SEQUENCE BOX TEACHES, AND CREW OWNS ALL THREE STEPS (#679 D1):
#
#   1. a blank `box new`, at the role's explicit size and the agent's own user
#   2. rig, present in the guest
#   3. `rig bootstrap <agent>-box`
#
# D4 — HOW RIG REACHES THE GUEST, decided here and recorded in #679's PR body
# before this code was written: CREW INSTALLS IT, from inside the root door box
# opens, as part of the mint. The alternative was to require rig in the seed,
# and it is not available: box's one internal seed is `tenant`, whose whole
# declared contract is that it converges nothing ("box provisions and manages
# VMs, and it does not converge them" — templates/tenant/box.env), so requiring
# rig in the seed means requiring a seed box does not ship. crew would then die
# AFTER `box new` had already created a box, leaving a half-minted guest on
# every host running box's own default mint, which is every host. D1 also says
# crew owns all three steps in as many words, and a seed-supplied rig makes step
# 2 the seed's.
#
# THE ROOT DOOR IS STDIN, NOT AN ARGV. `box root <box>` is `incus exec <inst> --
# bash -l` (bin/box:2792) — a login shell with no command payload — so the
# converge script is piped into it. That door authorizes through the HOST's
# incus socket and needs no sudoers entry in the guest, which is the only reason
# this works at all: box's tenant seed creates the tenant UNPRIVILEGED, with the
# absence of a `sudo:` line called out as deliberate in templates/tenant/
# user-data.yaml. `box exec <box> -- sudo rig bootstrap …` would therefore fail
# on a blank box, and the root door is the channel box itself names in the
# refusal that retired the templates: "converge it yourself inside
# 'box root <box>'".
#
# D10 — THE TENANT KEEPS THE AGENT'S OWN NAME. The retired <agent>-box template
# set BOX_USER to the agent (claude, codex, grok, kimi); the blank seed that
# replaces it sets BOX_USER="dev". So the blank mint would silently rename every
# guest tenant unless crew says otherwise. crew therefore passes `--user
# <agent>` at the mint and names NO --user on the bootstrap — rig's <agent>-box
# roles assume a matching tenant unless told, and here it matches. Preserving
# the name keeps cli/crew's own convergence_recovery line true ("box shell <n> →
# sudo rig bootstrap <agent>-box"), and keeps every snapshot, runbook and
# operator habit built on it true.
#
# D3 — SIZING STAYS CREW'S AND STAYS EXPLICIT. box's refusal teaches
# `--size medium`, but the role profiles carry BOX_CPU / BOX_MEMORY / BOX_DISK
# (4 / 8GiB / 60GiB for builder and reviewer at #607's parity) and a named size
# class would quietly re-open the sizing defect #607 closed — `medium` happens
# to equal the current figures and would stop doing so the day a profile moves.
# box 0.10.0 accepts all three on the default mint and resolves them ahead of
# --size: "Resources resolve most-specific-first: --cpu/--memory/--disk, then
# BOX_CPU / BOX_MEMORY / BOX_DISK, then --size, then the selected seed's
# defaults" (bin/box, `box new --help`). So the flags ride and no size class is
# passed.

# shellcheck disable=SC1091
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/platform.sh"

# box_mint_converge_script AGENT — the guest-side half, as text.
#
# Rendered rather than run here because the box transport boundary is the only
# thing an offline test can stand at: a stub intercepts `box` and answers for
# the whole guest, so anything a test can assert about this sequence has to be
# in the argv crew hands `box` — and for the root door, that argv is this
# script. It is therefore written to be READ: the bootstrap is a bare top-level
# line, not buried in a conditional, so a fixture can pin the exact invocation
# rather than grep a paragraph for a substring.
#
# The rig installed when rig is ABSENT is the one this crew DECLARES, pinned by
# RIG_REF, and not "whatever is latest": a mint is not the place to take a
# lottery ticket on another tool's release, and pinning makes the declaration in
# platform.sh load-bearing rather than decorative. An rig that is already there
# is left alone — replacing an operator's rig during a box mint is not crew's
# call, and report_platform is what says so when it is below the floor.
#
# `set -eu` and no pipefail: the one pipeline here is curl into bash, whose
# failure is the bash half's to report, and rig's installer is the thing that
# would be silenced.
box_mint_converge_script() { # AGENT
  local agent="$1"
  cat <<EOF
set -eu
export DEBIAN_FRONTEND=noninteractive
if ! command -v rig >/dev/null 2>&1; then
  command -v curl >/dev/null 2>&1 ||
    { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
  curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh |
    RIG_REF=$CREW_PLATFORM_RIG_MIN bash
  hash -r 2>/dev/null || true
fi
rig bootstrap $agent-box
EOF
}

# box_mint_fresh NAME AGENT CPU MEMORY DISK — the whole sequence, one call.
#
# </dev/null on `box new` for the reason it is on every other box call crew
# makes from a roster loop: create_box and the drill both run inside loops
# reading from a FIFO, and any stdin-inheriting `box` subcommand drains it
# (#48). The root door is the one call that MUST take stdin, and it takes the
# converge script and nothing else, so the FIFO is never what it reads.
#
# Returns non-zero at the first failing step and says which one. A mint that
# created a box and then failed to converge it leaves that box standing — it is
# the operator's to inspect or remove — and crew reports the state rather than
# unwinding it, because a half-converged box that crew silently deleted is a
# diagnosis nobody gets to make.
box_mint_fresh() { # NAME AGENT CPU MEMORY DISK
  local name="$1" agent="$2" cpu="$3" memory="$4" disk="$5"
  box new --name "$name" --user "$agent" \
    --cpu "$cpu" --memory "$memory" --disk "$disk" </dev/null || return 1
  box_mint_converge_script "$agent" | box root "$name" || {
    echo "crew: $name was minted but rig did not converge it as $agent-box." >&2
    echo "crew: the box is left standing; converge it by hand and re-run:" >&2
    echo "crew:   box root $name    # then: rig bootstrap $agent-box" >&2
    return 1
  }
}
