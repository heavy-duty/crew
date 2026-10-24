#!/usr/bin/env bash
# duty.sh — the duty engine. One tick: boot gate, then every duty the box's
# roles enable, in fleet-standard priority order:
#
#   attention (all roles) → triage signals → review queue → resume → ci-red →
#   build → handoff → rebase → worktree hygiene → backlog hygiene (hourly) →
#   reaper (daily, every role)
#
# ci-red sits between resume and build because a builder repairs its own red
# PR before claiming another issue (ceremony BUILDER.md, "Your own red head
# outranks a new claim"). This header is what FLEET.md's duty order is
# reconciled against, so it is not decoration: a header that lags the module
# order is how the #149 drift went unnoticed.
#
# All DETECTION happens here in plain bash against GitHub's object APIs; the
# model is spawned only when a duty exists, with a role prompt rendered from
# prompts/. The scripts never write to the board themselves — with one
# operator-ruled exception (the re-request auto-approve, which goes through
# the submit gate like any verdict). Detection here, judgment in sessions.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

# Manual invocations take the same lock the cron tick uses. The old scripts
# locked only in the crontab line, so a debugging run raced the tick.
if [ -z "${DUTY_LOCKED:-}" ]; then
  # `|| rc=$?` is load-bearing under `set -e`: a bare non-zero flock exits
  # the shell HERE, so the sentinel message below never ran and a contended
  # manual run printed nothing at all — exit 199 with total silence, which
  # is the failure this message exists to prevent. tick.sh avoids the same
  # trap by not using `set -e` at all.
  rc=0
  env DUTY_LOCKED=1 DUTY_DIR="$DUTY_DIR" flock -n -E 199 "$DUTY_DIR/.duty.lock" "$0" "$@" || rc=$?
  # An `if` block, not `[ … ] && echo …`: that form returns 1 on a non-199
  # exit and, as the last command before `exit`, would take `set -e` with it
  # — the same shape as the install.sh bug behind #25.
  if [ "$rc" -eq 199 ]; then
    echo "duty.sh: a tick already holds $DUTY_DIR/.duty.lock — nothing run" >&2
  fi
  exit "$rc"
fi

# Re-exec from a private snapshot: bash reads scripts lazily, and an
# in-place edit under a running tick corrupts the reader's byte offset
# (claude-bot, 2026-07-22). The snapshot dies with the run.
if [ -z "${DUTY_SNAPSHOT:-}" ]; then
  snap="$(mktemp "${TMPDIR:-/tmp}/duty-snapshot.XXXXXX.sh")"
  cp "$0" "$snap"
  DUTY_SNAPSHOT="$snap" exec bash "$snap"
fi
trap 'rm -f "$DUTY_SNAPSHOT" "$DUTY_DIR/.duty.lock.since"' EXIT
date +%s >"$DUTY_DIR/.duty.lock.since"

# shellcheck source=../lib/common.sh disable=SC1091
source "$DUTY_DIR/lib/common.sh"
load_conf
# A box restored from its weekly checkpoint boots with `.memory-pending` (the
# host's `reset --cut` leaves it in the snapshot): its memory — the ledgers,
# the breakers, the counters — is the host's to write back, and a tick that
# ran first would re-buy every refusal the box had already made and then be
# written over (#761, #763 review). So the tick waits, under its own lock,
# for up to MEMORY_PENDING_GRACE_S of uptime; the host lifts the marker in
# the same locked step that unpacks the memory. Past the grace the host did
# not come, and the box runs without it, saying so once.
if [ -e "$DUTY_DIR/.memory-pending" ]; then
  _mp_up="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
  case "$_mp_up" in ''|*[!0-9]*) _mp_up=0 ;; esac
  if [ "$_mp_up" -lt "${MEMORY_PENDING_GRACE_S:-1800}" ]; then
    log "duty tick skipped: the host has not written this box's memory back yet (up ${_mp_up}s; waits ${MEMORY_PENDING_GRACE_S:-1800}s)"
    exit 0
  fi
  warn "memory restore did not arrive within ${MEMORY_PENDING_GRACE_S:-1800}s of boot; this box runs without its ledgers from here"
  rm -f "$DUTY_DIR/.memory-pending"
fi
# The wake's reason (#759): the host writes $DUTY_DIR/.wake-reason before it
# ticks a box it started, and every SESSION END this tick carries it as
# `why=`; the box's own cron finds nothing and ticks as `cron`. Consumed, so a
# reason never outlives the tick it bought.
WAKE_REASON="$(head -c 200 "$DUTY_DIR/.wake-reason" 2>/dev/null | tr -d '\r\n' || true)"
rm -f "$DUTY_DIR/.wake-reason"
[ -n "$WAKE_REASON" ] || WAKE_REASON=cron
export WAKE_REASON
rm -f "$DUTY_DIR/.tick-acted"
# idle_ticks_account (shared/lib/common/session.sh, beside the .tick-acted
# stamp it reads) is called on every exit path below, right after the
# `duty run end` line.
mkdir -p "$WORK_DIR" "$TREES_DIR" "$LOG_DIR"
# shellcheck source=../lib/duty-review.sh disable=SC1091
source "$DUTY_DIR/lib/duty-review.sh"

log "duty run start"
# A stable identity for every run_session call in this process. Terminal
# breakers use it to probe at most once per kind per tick after opening.
# shellcheck disable=SC2034  # consumed dynamically by common.sh
DUTY_TICK_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"

# A session killed WITH the box never reached its own SESSION END, and this
# tick is the first thing that runs once the box is back. Reconciled HERE,
# above every duty and above the boot gate, for two reasons: a tick that the
# boot gate stops still owes the answer, and running before any dispatch is
# what makes "unanswered" mean "left by a previous run" and never "started a
# moment ago by this one" (#478).
session_reconcile_orphans
reclaim_detached_review_worktrees

# --- Once-per-boot sanity gate. The kernel boot id changes on every reboot;
# the first tick after a restart probes auth and disk and prunes worktrees
# left by the crash. The marker is written ONLY when gh and the box CLI both
# authenticate — a box with dead credentials re-checks (loudly) every tick
# instead of silently playing with them. On failure the operator is alerted
# once per boot: the boot gate that only ever wrote to a quieter log was the
# fleet's silent-starvation mode (the triage box is the minting SPOF). ---
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
report_profile_classifier_gaps "$boot_id"
if [ "$(cat "$DUTY_DIR/.boot-id" 2>/dev/null)" != "$boot_id" ]; then
  # The reboot reaches duty.log and not only boot-check.log (#609). A killed
  # process tree writes none of tick.sh's three failure shapes — the parent
  # that writes them dies too — so the tick after a restart is the only place
  # the fact can still be stated, and it is stated on the line above the
  # missing SESSION END rather than in a quieter file nobody tails.
  #
  # Emitted on the path taken for EVERY boot, above the success/failure branch
  # below: a box whose gate then fails must report both facts, and the boot a
  # degraded box just took is the one most worth reporting.
  #
  # Two shapes, on the evidence and never on the clock. The restart shape
  # requires a PREVIOUS boot id to have differed from; with no marker, or an
  # empty one a truncated write left behind, there is no such id and the box
  # has no restart on record — so it gets the first-tick shape. Claiming a
  # restart that did not happen is the same class of defect as saying nothing.
  if [ -s "$DUTY_DIR/.boot-id" ]; then
    log "boot gate: new boot id ${boot_id:0:8} — the box restarted since the last tick"
  else
    log "boot gate: first tick on this box (boot id ${boot_id:0:8})"
  fi
  {
    echo "== boot check $(date -Is) =="
    gh auth status || true
    df -h / | tail -1
    bot_cli_probe && echo "cli probe: ok" || echo "cli probe: FAILED"
    for d in "$WORK_DIR"/*/; do
      { [ -d "$d/.git" ] && git -C "$d" worktree prune -v; } || true
    done
  } >>"$DUTY_DIR/boot-check.log" 2>&1
  if gh auth status >/dev/null 2>&1 && bot_cli_probe; then
    echo "$boot_id" >"$DUTY_DIR/.boot-id"
  else
    warn "boot gate: auth probe failed — duty continues degraded, re-checking every tick"
    if [ "$(cat "$DUTY_DIR/.boot-alerted" 2>/dev/null)" != "$boot_id" ]; then
      alert "⚠️ $(hostname): boot gate failed (gh or CLI auth dead) — box is degraded"
      echo "$boot_id" >"$DUTY_DIR/.boot-alerted"
    fi
  fi
fi

# Identity comes from the token, not a hardcoded string: two of five boxes
# had both, used inconsistently. Resolved AFTER the boot gate so dead
# credentials hit the diagnostics above, not an opaque set -e death here.
# gh_identity, not a bare `gh api user`: the SAME single call also carries the
# token's expiry header and tells us whether the credential was rejected, so
# the floor learns both from the request the tick was making anyway. Nothing
# polls `gh auth status` any more — see common.sh.
ME="$(gh_identity)"
# Free, local, and every tick: reads the vendor's credential file rather than
# asking the vendor. The boot gate above still pays for one real bot_cli_probe
# per boot, which is where certainty is worth a round-trip.
check_vendor_credential
# The member's login, for the host's wake decision (#759): the host reads it
# from the store, the store pulls it from this file, and nothing on the host
# has to hold a box's token to know whose work a pull request is.
[ -z "$ME" ] || printf '%s\n' "$ME" >"$DUTY_DIR/.identity"
if [ -z "$ME" ]; then
  warn "cannot resolve own login (gh auth dead?) — nothing to do this tick"
  log "duty run end"
  idle_ticks_account
  exit 0
fi

# Identity's second carrier (#294). $ME is the gh half; git holds a COPY, and
# until now nothing kept it converged — the builder-identity split rotated the
# gh credential alone, so a split box authored every commit as the account it
# carried BEFORE the split and GitHub bylined that droid on this box's own PRs.
#
# Converged HERE: after $ME resolves, because that is the source of truth, and
# before the first duty dispatch below, because after it a session could
# already have committed. Nothing between these two points writes a commit.
#
# A box that cannot be made to byline itself spends no session at all. That is
# the refusal #294 asks for, and it is deliberately narrow: convergence has
# already tried, so reaching here means git would demonstrably commit under
# another droid's name. Running anyway is how the record got corrupted.
if ! converge_git_identity "$ME"; then
  identity_failure="$(git_identity_failure_message)"
  warn "$identity_failure — no session this tick"
  case "${GIT_IDENTITY_FAILURE_KIND:-identity}" in
    credential)
      note_auth_failure gh "$GIT_IDENTITY_FAILURE_EVIDENCE"
      log "duty run end"
      idle_ticks_account
      exit 0
      ;;
  esac
  # Once per boot, on the channel the auth watchdog already uses: this is a
  # by-hand repair (git config --global user.email), so re-alerting every five
  # minutes would train the operator to ignore the one channel that matters.
  if [ "$(cat "$DUTY_DIR/.identity-alerted" 2>/dev/null)" != "$boot_id" ]; then
    alert "🪪 $(hostname): $identity_failure — refusing to run sessions that would commit as somebody else"
    echo "$boot_id" >"$DUTY_DIR/.identity-alerted"
  fi
  log "duty run end"
  idle_ticks_account
  exit 0
fi

# shellcheck source=../lib/duty-attention.sh disable=SC1091
source "$DUTY_DIR/lib/duty-attention.sh"
# shellcheck source=../lib/duty-builder.sh disable=SC1091
source "$DUTY_DIR/lib/duty-builder.sh"
# shellcheck source=../lib/duty-triage.sh disable=SC1091
source "$DUTY_DIR/lib/duty-triage.sh"

# ATTENTION is role-independent and runs FIRST, per FLEET.md: a parked
# demand outranks every queue.
duty_attention

if has_role triage; then
  duty_triage
fi

if has_role reviewer; then
  duty_review
fi

if has_role builder; then
  duty_builder
fi

# Backlog hygiene: triage-only, self-scheduling (runs when HYGIENE_INTERVAL
# has elapsed, whatever tick that lands on — a skipped top-of-hour tick
# delays it instead of losing the hour). Shares this tick's lock, so it can
# never race the triage sweep over the same checkouts (the old separate
# hygiene cron could, and did share ~/duty/work with duty.sh unlocked).
if has_role triage; then
  now="$(date +%s)"
  last="$(cat "$DUTY_DIR/.hygiene-last" 2>/dev/null || echo 0)"
  if [ $((now - last)) -ge "$HYGIENE_INTERVAL" ]; then
    # shellcheck source=../lib/duty-hygiene.sh disable=SC1091
    source "$DUTY_DIR/lib/duty-hygiene.sh"
    duty_attention_audit
    duty_hygiene && echo "$now" >"$DUTY_DIR/.hygiene-last"
  fi
fi

# The release cut (#762): triage-only, every tick, decided in shell against
# the main clone and the board; a session is bought only for a head that is
# green, quiet, fragment-bearing and not yet cut, and it stops at the pull
# request. Nothing to do when RELEASE_TRACKS is empty, which is what ships.
if has_role triage; then
  # shellcheck source=../lib/duty-release.sh disable=SC1091
  source "$DUTY_DIR/lib/duty-release.sh"
  duty_release
fi

# The reaper: EVERY role, self-scheduling on its own stamp file, inside this
# tick's lock (#457). Not under `has_role triage` and not beside the hygiene
# clock above: a builder box accretes at least as fast as the triage box the
# measurements came from, and a second stamp file in that block is where a
# reaper would break the attention-audit leg's deliberate use of
# `.hygiene-last`. The module is sourced before the interval test because the
# cadence default lives with the sweep that honours it; sourcing has no side
# effect (`reaper-module-standalone`).
# shellcheck source=../lib/duty-reaper.sh disable=SC1091
source "$DUTY_DIR/lib/duty-reaper.sh"
reaper_interval
reaper_now="$(date +%s)"
reaper_last="$(cat "$DUTY_DIR/.reaper-last" 2>/dev/null || echo 0)"
if [ $((reaper_now - reaper_last)) -ge "$REAPER_INTERVAL_SECONDS" ]; then
  duty_reaper && echo "$reaper_now" >"$DUTY_DIR/.reaper-last"
fi

log "duty run end"
idle_ticks_account
