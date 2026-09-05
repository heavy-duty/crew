#!/usr/bin/env bash
# Offline contract suite for crew restart/down. The real verbs run unchanged;
# only the host-owned box CLI/control channel is replaced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
# The declared platform, read out of the declaration rather than pinned here,
# for the same reason the role sizes further down are read out of reviewer.conf:
# these cases are ABOUT the declaration, and a fixture holding its own copy of
# the number is the second statement of it that #679 D11 exists to remove.
#
# SOURCED HERE, AT THE TOP, AND EXPORTED. The box stub below stands in for a
# host at the floor, so the floor is what it must answer by default, and both
# the stub and run_crew's env defaults are written before the first case runs —
# fleet-floor/test/stub-box already reads the declaration for exactly this
# reason and the two stubs should not disagree about where the number lives.
# The D11 guard does not reach shared/test/, so a literal here is precisely the
# copy that would rot quietly on the next bump (#679 round 1, kimi).
# shellcheck source=shared/lib/platform.sh
source "$ROOT/shared/lib/platform.sh"
export CREW_PLATFORM_BOX_MIN CREW_PLATFORM_RIG_MIN
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
CONF="$TMP/conf"
SHIM="$TMP/shim"
STATE="$TMP/state"
PROBE_BIN="$TMP/probe-bin"
NO_FLOCK_BIN="$TMP/no-flock-bin"
# #590. The host maintenance lock and job log are HOST state, so they must be
# pointed somewhere disposable or this suite writes into the machine's real
# ~/.local/state — and two suites exercising the two scheduled verbs would then
# contend for one real lock and skip each other's runs.
HOSTSTATE="$TMP/host-state"
HOSTLOG="$HOSTSTATE/host-maintenance.log"
HOSTLOCK="$HOSTSTATE/.host-maintenance.lock"
# A PATH carrying the box shim and the tools crew reaches before need_flock,
# and deliberately NOT flock: the refusal to run unlocked is a contract, and a
# fixture cannot assert it while the real flock is reachable.
NO_HOST_FLOCK_BIN="$TMP/no-host-flock-bin"
mkdir -p "$CONF" "$SHIM" "$STATE" "$STATE/guests" "$PROBE_BIN" "$NO_FLOCK_BIN" \
  "$HOSTSTATE" "$NO_HOST_FLOCK_BIN"
for host_tool in bash env readlink dirname basename head tail sed awk grep tr cat \
                 cut sort mkdir wc mv rm date sleep find ln chmod id uname; do
  host_tool_path="$(command -v "$host_tool" 2>/dev/null)" || continue
  ln -sf "$host_tool_path" "$NO_HOST_FLOCK_BIN/$host_tool"
done
ln -s "$(command -v cat)" "$PROBE_BIN/cat"
ln -s "$(command -v cat)" "$NO_FLOCK_BIN/cat"
cat >"$PROBE_BIN/date" <<'EOF'
#!/bin/bash
printf '%s\n' "${LIFE_NOW:-10000}"
EOF
cp "$PROBE_BIN/date" "$NO_FLOCK_BIN/date"
cat >"$PROBE_BIN/flock" <<'EOF'
#!/bin/bash
exit "${LIFE_FLOCK_RC:-0}"
EOF
chmod +x "$PROBE_BIN/date" "$PROBE_BIN/flock" "$NO_FLOCK_BIN/date"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta codex reviewer
EOF

# A COMPLETE fleet definition whose roster names nobody — the nothing-to-do
# case (#590 D2), and it has to be a real definition rather than a missing file
# so that resolution succeeds and the run reaches the job log to say so.
CONF_EMPTY="$TMP/conf-empty"
mkdir -p "$CONF_EMPTY"
cp "$CONF/fleet.conf" "$CONF/repos.txt" "$CONF/notify-repos.txt" \
  "$CONF/doctrine.conf" "$CONF_EMPTY/"
cat >"$CONF_EMPTY/fleet.roster" <<'EOF'
# every row a comment: a roster that names no box
EOF

cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
state_dir="$LIFE_STATE"
calls="$state_dir/calls"
cmd="${1:-}"; shift || true
case "$cmd" in
  --version|-V)
    # `box --version`'s real shape, `box <ver> (<root>)` (bin/box:27). The
    # platform check parses field 2 out of it, so the whole line is reproduced
    # rather than the bare number: a reader that accepted a bare number would
    # pass a fixture no real box can produce.
    printf 'box %s (/opt/box/versions/%s)\n' \
      "${LIFE_BOX_VERSION:-$CREW_PLATFORM_BOX_MIN}" \
      "${LIFE_BOX_VERSION:-$CREW_PLATFORM_BOX_MIN}"
    ;;
  root)
    # The root door, which is `incus exec <inst> -- bash -l` — a login shell
    # with NO command payload (bin/box:2792), so what crew hands it arrives on
    # STDIN. That payload is crew's whole statement about how a box gets
    # converged, and it is captured here for the same reason `new`'s argv is:
    # the box transport boundary is the only place an offline test can stand.
    name="$1"
    printf 'root %s\n' "$name" >>"$calls"
    cat >"$state_dir/root-script-$name"
    [ "${LIFE_ROOT_FAIL:-}" != "$name" ] || exit 1
    # A converged box carries rig's provenance manifest from here on, which is
    # what the platform check reads back out of the guest.
    printf '%s\n' "${LIFE_GUEST_RIG:-$CREW_PLATFORM_RIG_MIN}" >"$state_dir/rig-$name"
    ;;
  list)
    # LIFE_BOX_LIST overrides the fleet this host has, for the platform cases
    # that need a host with NO boxes — which is a real state (a fresh install)
    # and the one where there is no guest for rig to be read out of at all.
    names="${LIFE_BOX_LIST-alpha beta offroster}"
    if [ "${1:-}" = --json ]; then
      printf '['
      sep=""
      for n in $names; do printf '%s{"name":"%s"}' "$sep" "$n"; sep=","; done
      printf ']\n'
    else
      printf 'NAME\n'
      for n in $names; do printf '%s\n' "$n"; done
    fi
    ;;
  exec)
    name="$1"; shift
    script="${*: -1}"
    current="running"
    [ ! -s "$state_dir/state-$name" ] || current="$(cat "$state_dir/state-$name")"
    [ "$current" != stopped ] || exit 1
    if [[ "$script" == *'flock -n "$lock"'* ]]; then
      probe="$state_dir/probe-$name"
      value="${LIFE_PROBE_DEFAULT:-idle:0}"
      if [ -s "$probe" ]; then
        value="$(head -1 "$probe")"
        tail -n +2 "$probe" >"$probe.next"
        mv "$probe.next" "$probe"
      fi
      guest_home="$state_dir/guests/$name"
      mkdir -p "$guest_home/duty"
      rm -f "$guest_home/duty/.duty.lock.since"
      case "$value" in
        idle:*) probe_path="$LIFE_PROBE_BIN"; probe_rc=0 ;;
        busy:*)
          probe_path="$LIFE_PROBE_BIN"; probe_rc=1
          printf '%s\n' "$((10000 - ${value#busy:}))" >"$guest_home/duty/.duty.lock.since"
          ;;
        since:*)
          probe_path="$LIFE_PROBE_BIN"; probe_rc=1
          printf '%s\n' "${value#since:}" >"$guest_home/duty/.duty.lock.since"
          ;;
        no-flock) probe_path="$LIFE_NO_FLOCK_BIN"; probe_rc=0 ;;
        flock-error) probe_path="$LIFE_PROBE_BIN"; probe_rc=2 ;;
        stop-during-probe)
          printf 'stopped\n' >"$state_dir/state-$name"
          exit 1
          ;;
        transport|unreadable) exit 1 ;;
        empty) exit 0 ;;
        *) exit 2 ;;
      esac
      probe_output="$(env HOME="$guest_home" PATH="$probe_path" LIFE_FLOCK_RC="$probe_rc" LIFE_NOW=10000 \
        /bin/bash -c "$script")"
      printf '%s\n' "$probe_output" >"$state_dir/probe-result-$name"
      printf '%s\n' "$probe_output"
    elif [[ "$script" == *'df -Pk'* ]]; then
      printf 'free-probe %s\n' "$name" >>"$calls"
      ready_file="$state_dir/ready-fails-$name"
      if [ -f "$state_dir/started-$name" ] && [ -s "$ready_file" ]; then
        remaining="$(cat "$ready_file")"
        if [ "$remaining" -gt 0 ]; then
          printf '%s\n' "$((remaining - 1))" >"$ready_file"
          exit 1
        fi
      fi
      if [ -f "$state_dir/started-$name" ]; then free=1200; else free=1000; fi
      # The stub stands at the box transport boundary, so it returns what the
      # complete remote pipeline prints, not df's intermediate table.
      printf '%s\n' "$free"
    elif [[ "$script" == *'duty-snapshot.*'* ]]; then
      printf 'cleanup %s\n' "$name" >>"$calls"
    elif [[ "$script" == *'/etc/rig/manifest'* ]]; then
      # rig's provenance manifest, read where rig RUNS — inside the guest
      # (#679 D15). A box converged during this run has its own recorded
      # version; every other box answers LIFE_GUEST_RIG, whose three special
      # spellings are the three findings that are not "a number":
      #   none    the box answers and carries no manifest — rig never converged
      #   absent  the box does not answer at all — crew knows nothing about it
      # The two must never collapse (crew#220 rule 5), which is why `probe=ok`
      # is emitted on its own line before anything else is read.
      # Recorded, because "this guest was read" is itself a contract: a box on
      # the host but not in the roster must be skipped BEFORE this door opens,
      # not filtered out of the report afterwards (#679 round 1).
      #
      # Narrowed to the PLATFORM check's own wire, because TWO different reads
      # of this file arrive at this branch: the platform check's
      # (shared/lib/platform.sh) and `rig_report`'s convergence probe
      # (cli/crew:1766-1777), which is roster-scoped already and is not what the
      # off-roster case is about. A marker counting both reads 2 on one report
      # and turns the assertion into a puzzle. `echo probe=ok` does not separate
      # them — both carry it, deliberately, as crew#220 rule 5's marker — so the
      # token is `cat /etc/rig/manifest`, which only the platform probe sends.
      # The day that probe is rewritten this marker stops firing and
      # platform-roster-box-is-opened-once reds, which is the correct failure:
      # it says the read this suite is pinning changed shape.
      case "$script" in
        *'cat /etc/rig/manifest'*) printf 'rig-probe %s\n' "$name" >>"$calls" ;;
      esac
      version="${LIFE_GUEST_RIG:-$CREW_PLATFORM_RIG_MIN}"
      [ ! -s "$state_dir/rig-$name" ] || version="$(cat "$state_dir/rig-$name")"
      [ "$version" != absent ] || exit 1
      printf 'probe=ok\n'
      if [ "$version" != none ]; then
        printf 'schema=1\nbootstrapped_by=%s\nconverged_by=%s\n' "$version" "$version"
      fi
    else
      exit 2
    fi
    ;;
  down)
    if [ "${1:-}" = --help ]; then
      [ "${LIFE_FORCE_HELP:-yes}" = yes ] && printf 'usage: box down <box> [--force]\n'
      exit 0
    fi
    name="$1"; shift || true
    printf 'down %s%s\n' "$name" "${1:+ $1}" >>"$calls"
    if [ "$name" = "${LIFE_DOWN_FAIL:-}" ]; then exit 1; fi
    if [ "$name" != "${LIFE_STOP_NOT_TAKE:-}" ]; then printf 'stopped\n' >"$state_dir/state-$name"; fi
    ;;
  start)
    name="$1"
    printf 'start %s\n' "$name" >>"$calls"
    printf 'running\n' >"$state_dir/state-$name"
    : >"$state_dir/started-$name"
    printf '%s\n' "${LIFE_READY_FAILS:-0}" >"$state_dir/ready-fails-$name"
    ;;
  info)
    name="$1"
    state="running"; [ ! -s "$state_dir/state-$name" ] || state="$(cat "$state_dir/state-$name")"
    # The resource keys ride the same passthrough the real `box info --json`
    # is: `incus list --format json`, config and devices verbatim. Empty
    # LIFE_BOX_RESOURCES is the box that answers about its status and nothing
    # else, which is what #607 D5's note has to survive without inventing a
    # figure.
    # A box that cannot be read AT ALL is a different answer from one that
    # answers without resource keys, and it reaches a different line of the
    # reader — the shell fallback rather than jq's own defaults.
    [ "${LIFE_BOX_RESOURCES:-}" != unreadable ] || exit 1
    if [ -n "${LIFE_BOX_RESOURCES:-}" ]; then
      IFS='|' read -r r_cpu r_mem r_disk <<<"$LIFE_BOX_RESOURCES"
      printf '[{"status":"%s","expanded_config":{"limits.cpu":"%s","limits.memory":"%s"},"expanded_devices":{"root":{"type":"disk","size":"%s"}}}]\n' \
        "$state" "$r_cpu" "$r_mem" "$r_disk"
    else
      printf '[{"status":"%s"}]\n' "$state"
    fi
    ;;
  new)
    # `box new --help` is the capability probe's whole input (#607 D5). The
    # sentence WRAPS in box's real help output and it is reproduced wrapped
    # here on purpose: a probe that matched line-by-line would pass a fixture
    # that joined it and fail against the box an operator actually has.
    if [ "${1:-}" = --help ]; then
      case "${LIFE_CLONE_SIZING:-yes}" in
        yes)
          printf 'usage: box new --name <box> [--from <src>[/<snap>]]\n'
          printf 'Named sizes select fresh-mint bundles. A --from clone instead accepts the\n'
          printf 'explicit --cpu/--memory/--disk flags (#171). They ride the copy itself.\n' ;;
        old)
          printf 'usage: box new --name <box> [--from <src>[/<snap>]]\n'
          printf -- '--cpu/--memory/--disk shape a fresh mint; a clone carries its source resources.\n' ;;
        *) exit 2 ;;
      esac
      exit 0
    fi
    printf 'new %s\n' "$*" >>"$calls"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SHIM/box"

reset_case() {
  find "$STATE" -mindepth 1 -maxdepth 1 -type f -delete
  find "$STATE/guests" -mindepth 1 -delete
  : >"$STATE/calls"
  # The job log is per-case evidence, so it starts empty; the lock file itself
  # is left alone, because a case that HOLDS it does so across this call.
  rm -f "$HOSTLOG" "$HOSTLOG.1" "$HOSTLOCK.holder"
}

job_log() { cat "$HOSTLOG" 2>/dev/null || true; }

# A job log already past HOST_JOB_LOG_MAX, carrying one marker line so the
# generation it ends up in can be named. A REAL oversized file rather than a
# tuned threshold: 5 MiB is tick.sh's number, hardcoded there and here for the
# same reason, and a fixture that moved it would be asserting against a knob
# that does not exist on the host. 6 MiB of one repeated byte costs a second
# and no correctness.
big_host_log() { # MARKER
  printf '%s\n' "$1" >"$HOSTLOG"
  head -c $((6 * 1024 * 1024)) /dev/zero | tr '\0' 'p' >>"$HOSTLOG"
  printf '\n' >>"$HOSTLOG"
}

# Hold the host maintenance lock the way a running job holds it: an open fd
# with flock on it, released when the fd closes. Not a lock FILE — the file
# always exists, and a fixture that created one and called that "held" would
# pass against a crew that never locked anything.
hold_host_lock() {
  exec {HOLDFD}>>"$HOSTLOCK"
  flock -n "$HOLDFD"
}
release_host_lock() { exec {HOLDFD}>&-; }

run_crew() {
  env CREW_CONFIG_DIR="${LIFE_CONF:-$CONF}" CREW_HOST_STATE_DIR="$HOSTSTATE" \
    LIFE_STATE="$STATE" \
    LIFE_PROBE_DEFAULT="${LIFE_PROBE_DEFAULT:-idle:0}" \
    LIFE_FORCE_HELP="${LIFE_FORCE_HELP:-yes}" \
    LIFE_DOWN_FAIL="${LIFE_DOWN_FAIL:-}" \
    LIFE_STOP_NOT_TAKE="${LIFE_STOP_NOT_TAKE:-}" \
    LIFE_READY_FAILS="${LIFE_READY_FAILS:-0}" \
    LIFE_CLONE_SIZING="${LIFE_CLONE_SIZING:-yes}" \
    LIFE_BOX_RESOURCES="${LIFE_BOX_RESOURCES:-}" \
    LIFE_BOX_VERSION="${LIFE_BOX_VERSION:-$CREW_PLATFORM_BOX_MIN}" \
    LIFE_GUEST_RIG="${LIFE_GUEST_RIG:-$CREW_PLATFORM_RIG_MIN}" \
    LIFE_ROOT_FAIL="${LIFE_ROOT_FAIL:-}" \
    LIFE_BOX_LIST="${LIFE_BOX_LIST-alpha beta offroster}" \
    LIFE_PROBE_BIN="$PROBE_BIN" LIFE_NO_FLOCK_BIN="$NO_FLOCK_BIN" \
    CREW_DRAIN_POLL_SECONDS=0 CREW_RESTART_READY_POLL_SECONDS=0 \
    CREW_RESTART_READY_ATTEMPTS=3 PATH="${LIFE_PATH:-$SHIM:$PATH}" bash "$CLI" "$@"
}

capture() {
  if OUT="$(run_crew "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

reset_case
capture help restart
case "$OUT" in *'usage: crew restart <box>... | --all [--force-after <hours>]'*'only when a valid continuous lock age is available'*'stop that does not take is never followed by a start'*) r1=complete ;; *) r1="$OUT" ;; esac
t lifecycle-help-renders-table-and-detail complete "$r1"
capture help
case "$OUT" in *'3  lifecycle work completed after a busy restart skip or a down drain wait'*) r1=documented ;; *) r1="$OUT" ;; esac
t lifecycle-help-documents-skip-status documented "$r1"

reset_case
capture restart alpha
t lifecycle-idle-restart-exits-zero 0 "$RC"
t lifecycle-idle-restart-stops-then-starts $'down alpha\nstart alpha' \
  "$(grep -E '^(down|start) alpha' "$STATE/calls")"
t lifecycle-idle-restart-cleans-before-stop 1 "$(grep -c '^cleanup alpha$' "$STATE/calls")"
case "$OUT" in *'free 1000 → 1200 KiB (delta +200 KiB)'*) r1=reported ;; *) r1="$OUT" ;; esac
t lifecycle-idle-restart-reports-space-delta reported "$r1"

reset_case
LIFE_READY_FAILS=2 capture restart alpha
t lifecycle-restart-waits-for-guest-readiness 0 "$RC"
t lifecycle-restart-retries-post-start-probe 4 "$(grep -c '^free-probe alpha$' "$STATE/calls")"
unset LIFE_READY_FAILS

reset_case
LIFE_READY_FAILS=5 capture restart alpha
t lifecycle-restart-readiness-timeout-is-failure 1 "$RC"
case "$OUT" in *'guest stayed unreachable after 3 probes'*'box shell alpha'*) r1=actionable ;; *) r1="$OUT" ;; esac
t lifecycle-restart-readiness-timeout-is-actionable actionable "$r1"
unset LIFE_READY_FAILS

reset_case
printf 'stopped\n' >"$STATE/state-alpha"
capture restart alpha
t lifecycle-stopped-restart-starts-without-drain 0 "$RC"
t lifecycle-stopped-restart-does-not-stop-again 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-stopped-restart-starts 1 "$(grep -c '^start alpha$' "$STATE/calls")"
t lifecycle-stopped-restart-cleans-after-start 1 "$(grep -c '^cleanup alpha$' "$STATE/calls")"
case "$OUT" in *'alpha: already stopped; starting'*'started from stopped'*) r1=accurate ;; *) r1="$OUT" ;; esac
t lifecycle-stopped-restart-pins-precheck-wording accurate "$r1"

reset_case
printf 'busy:60\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-busy-restart-has-skip-status 3 "$RC"
case "$OUT" in *'alpha: SKIPPED busy'*'skipped: alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-busy-restart-is-named named "$r1"
t lifecycle-busy-restart-never-stops 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

for unreadable_mode in no-flock flock-error transport empty; do
  reset_case
  printf '%s\n' "$unreadable_mode" >"$STATE/probe-alpha"
  capture restart alpha
  t "lifecycle-$unreadable_mode-is-busy-skip" 3 "$RC"
  t "lifecycle-$unreadable_mode-never-stops" 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
done

reset_case
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture restart alpha --force-after 1
t lifecycle-force-after-restarts 0 "$RC"
case "$OUT" in *'force-after reached; restarting'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-force-after-is-announced named "$r1"

for invalid_since in 18446744073709551617 10002; do
  reset_case
  printf 'since:%s\n' "$invalid_since" >"$STATE/probe-alpha"
  capture restart alpha --force-after 1
  t "lifecycle-invalid-since-$invalid_since-is-busy-skip" 3 "$RC"
  case "$OUT" in *'SKIPPED busy — duty lock age unavailable'*) r1=unavailable ;; *) r1="$OUT" ;; esac
  t "lifecycle-invalid-since-$invalid_since-age-is-unavailable" unavailable "$r1"
  t "lifecycle-invalid-since-$invalid_since-probe-normalizes-age" 'busy -1' \
    "$(cat "$STATE/probe-result-alpha")"
  t "lifecycle-invalid-since-$invalid_since-never-cycles" 0 "$(grep -cE '^(down|start) alpha' "$STATE/calls" || true)"
done

reset_case
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture restart alpha --force-after 08
t lifecycle-force-after-leading-zero-is-decimal 3 "$RC"
t lifecycle-force-after-leading-zero-does-not-cycle 0 "$(grep -cE '^(down|start) alpha' "$STATE/calls" || true)"

reset_case
capture restart alpha --force-after 00
t lifecycle-force-after-zero-spelling-refuses 2 "$RC"
t lifecycle-force-after-zero-spelling-mutates-nothing 0 "$(grep -cE '^(down|start) ' "$STATE/calls" || true)"

reset_case
capture restart alpha --force-after 99999999999999999999
t lifecycle-force-after-over-range-refuses 2 "$RC"
t lifecycle-force-after-over-range-mutates-nothing 0 "$(grep -cE '^(down|start) ' "$STATE/calls" || true)"

reset_case
LIFE_STOP_NOT_TAKE=alpha capture restart alpha
t lifecycle-stop-not-taken-is-failure 1 "$RC"
t lifecycle-stop-not-taken-never-starts 0 "$(grep -c '^start alpha' "$STATE/calls" || true)"
case "$OUT" in *'stop did not take'*'NOT starting'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-stop-not-taken-is-named named "$r1"
unset LIFE_STOP_NOT_TAKE

reset_case
capture restart --all
t lifecycle-all-restarts-roster 2 "$(grep -c '^start ' "$STATE/calls")"
t lifecycle-all-leaves-offroster 0 "$(grep -c 'offroster' "$STATE/calls" || true)"

reset_case
printf 'busy:65\nidle:0\n' >"$STATE/probe-alpha"
capture down
t lifecycle-down-waits-then-completes-with-wait-status 3 "$RC"
case "$OUT" in *'alpha: waiting for duty lock held 1m'*'crew down --force'*'down: 2 stopped, 1 waited'*) r1=loud ;; *) r1="$OUT" ;; esac
t lifecycle-down-wait-is-loud loud "$r1"
t lifecycle-plain-down-never-forces 0 "$(grep -c -- '--force' "$STATE/calls" || true)"

reset_case
printf 'stopped\n' >"$STATE/state-alpha"
capture down
t lifecycle-down-already-stopped-terminates 0 "$RC"
t lifecycle-down-already-stopped-does-not-call-down 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-down-continues-after-stopped-box 1 "$(grep -c '^down beta' "$STATE/calls")"

reset_case
printf 'stop-during-probe\n' >"$STATE/probe-alpha"
capture down
t lifecycle-down-stopped-during-probe-terminates 0 "$RC"
t lifecycle-down-stopped-during-probe-does-not-call-down 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

reset_case
printf 'stop-during-probe\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-restart-stopped-during-probe-starts 0 "$RC"
t lifecycle-restart-stopped-during-probe-does-not-stop 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-restart-stopped-during-probe-calls-start 1 "$(grep -c '^start alpha$' "$STATE/calls")"

reset_case
LIFE_FORCE_HELP=no capture down --force
t lifecycle-old-box-force-refuses 1 "$RC"
case "$OUT" in *'requires box 0.10.0 or later'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-old-box-force-names-requirement named "$r1"
t lifecycle-old-box-force-mutates-nothing 0 "$(grep -c '^down ' "$STATE/calls" || true)"
unset LIFE_FORCE_HELP

reset_case
capture down --force
t lifecycle-force-down-exits-zero 0 "$RC"
t lifecycle-force-down-uses-box-feature 2 "$(grep -cE '^down (alpha|beta) --force$' "$STATE/calls")"
t lifecycle-force-down-skips-drain 0 "$(grep -c '^cleanup ' "$STATE/calls" || true)"

reset_case
LIFE_DOWN_FAIL=alpha capture down
t lifecycle-partial-down-is-nonzero 1 "$RC"
case "$OUT" in *'down FAILED on alpha (stop command failed)'*'down: 1 stopped'*'1 failed'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-partial-down-is-named named "$r1"
case "$OUT" in *'(state: failed)'*) r1="$OUT" ;; *) r1=hidden ;; esac
t lifecycle-partial-down-hides-internal-sentinel hidden "$r1"
unset LIFE_DOWN_FAIL

# --- #590: the host schedule, its lock, its log and its exit statuses --------
#
# THE SUBJECT IS THE UNATTENDED CALLER. Everything above asserts what the verbs
# do to boxes; these assert what they leave behind for somebody who was asleep
# when they ran. They live in THIS suite rather than a third one because it is
# the suite `crew restart` already has, and the daily line is `crew restart`.

# D1 — the example file. The charter is checkable by reading it, so read it:
# a cron line that grew its own flock or its own redirect is the exact drift
# shared/crontab.example was written to end, and it would arrive as a helpful
# edit rather than as a mistake anybody argued for.
HOST_CRONTAB="$ROOT/shared/host-crontab.example"
host_cron_lines="$(grep -vE '^[[:space:]]*(#|$)' "$HOST_CRONTAB" || true)"
t hostcron-example-exists yes "$([ -f "$HOST_CRONTAB" ] && echo yes || echo no)"
t hostcron-schedules-the-daily-restart-alone 1 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c '[^[:space:]]' || true)"
t hostcron-no-flock-in-any-line 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c 'flock' || true)"
t hostcron-no-redirect-in-any-line 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c '[>|]' || true)"
# This one keeps its literal spaces and its narrow fields on purpose, and the
# asymmetry with the reset pattern below is the point: it asserts a line is
# PRESENT, so a stricter read can only turn it red. The reset assertions assert
# an ABSENCE, where every shape the pattern does not know is a silent pass —
# which is why they were widened to cron's real separator and this was not.
t hostcron-daily-line-is-restart-all 1 \
  "$(printf '%s\n' "$host_cron_lines" | grep -cE '^[0-9]+ [0-9]+ \* \* \* .*crew restart --all$' || true)"
# #678 — THE WEEKLY RESET IS DEFERRED TO 0.1.4, AND THE ABSENCE IS THE
# ASSERTION. `crew reset --all` restores each box to its `armed` checkpoint,
# and that restore has no carve-out for $DUTY_DIR: it takes duty.log, and it
# clears the resume breaker with no push, against #314's invariant that only a
# push clears it. The count above cannot carry this on its own — a file that
# lost the DAILY line instead would also hold one job line — so the shape is
# asserted from both ends, the right line present and the wrong one absent.
#
# One pattern serves both reset assertions, because they ask the same question
# of two different inputs and must not drift apart. It matches the SCHEDULE
# PREFIX a cron entry starts with, in both forms cron accepts: five fields, or
# one of the @-special strings. `@weekly $HOME/.local/bin/crew reset --all` is
# a job line, and a five-field pattern alone reads it as prose
# (@claude-bot-andresmgsl, #683).
#
# Fields 1-3 stay numeric-and-star deliberately, and that is load-bearing
# rather than lazy: the commented-out assertion below runs this same pattern
# over the file's PROSE with the comment marker stripped, and admitting names
# in the leading fields would make an ordinary English sentence of five words
# followed by `crew reset` — which this file's own deferral block very nearly
# is — match as a cron entry. Fields 4 and 5 admit names because cron does
# (`0 5 * * SUN`), and no sentence opens with two numbers and a star.
#
# THE SEPARATOR IS BLANK, NOT SPACE, and the entry may be indented. cron
# splits fields on runs of spaces OR TABS, so a literal ` +' let
# `# @weekly<TAB>… crew reset --all` (@codex-bot-andresmgsl, #683) and
# `#<TAB>10<TAB>5<TAB>*<TAB>*<TAB>0<TAB>… crew reset --all`
# (@claude-bot-andresmgsl, #683) past this pattern entirely — 141/0, nothing
# died, so the weekly reset was one uncomment away with the guard green. Both
# branches take [[:blank:]]+, including the separator after an @-special, and
# `^[[:blank:]]*' admits the indented entry cron also accepts. Widening the
# separator does not widen what counts as a schedule: [[:blank:]] is what was
# already meant by a space, so the numeric-fields reasoning above is untouched
# and the file's own prose still does not match.
#
# AND THE SAME IS TRUE ONE TOKEN TO THE RIGHT. The command is split on blanks
# by the shell exactly as the fields are by cron, so while the tail read a
# literal `crew reset' the widening stopped at the schedule and
# `# 10 5 * * 0 … crew<TAB>reset --all` was still 141/0 — nothing died, the
# same one-uncomment-from-live hole in a different position
# (@claude-bot-andresmgsl, #683). `crew[[:blank:]]+reset' closes it. No braces
# here: no parameter expansion precedes the bracket, so SC1087 does not arise.
cron_num='[0-9*][0-9,*/-]*'
cron_named='[0-9A-Za-z*][0-9A-Za-z,*/-]*'
cron_at='@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)'
# The braces are required, not style: `$cron_num[[:blank:]]' reads as an array
# subscript to shellcheck, which is SC1087 at ERROR severity and reds ci-shell.
cron_five="${cron_num}[[:blank:]]+${cron_num}[[:blank:]]+${cron_num}[[:blank:]]+"
cron_five="${cron_five}${cron_named}[[:blank:]]+${cron_named}[[:blank:]]+"
cron_entry="^[[:blank:]]*(${cron_five}|${cron_at}[[:blank:]]+).*crew[[:blank:]]+reset"
# Read over the job lines, by the shape of a cron entry rather than by two
# leading integers: `*/10 5 * * 0 … crew reset --all` is a reset job line, and
# an `^[0-9]+ [0-9]+` pattern let it through while the assertion's NAME claimed
# otherwise (@claude-bot-andresmgsl, #683). The count above would have caught
# it; a guard that leans on a neighbour is one edit from catching nothing.
t hostcron-schedules-no-reset-job-line 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -cE "$cron_entry" || true)"
# AND IT MUST NOT BE REINSTATABLE BY UNCOMMENTING. This is the one assertion
# here that reads the whole file rather than the job lines, because a
# commented-out job line is invisible to every assertion above it and a
# crontab is the one file nobody diffs. It reads the SHAPE and not the verb:
# comments that NAME `crew reset` are wanted — the deferral is argued in them,
# and the verb is still available on demand — so what is banned is a comment
# whose text is a cron ENTRY — a schedule prefix and the reset behind it, in
# either of the forms cron accepts.
#
# AND THE MARKERS REPEAT. `#+' strips one RUN of them, so `# # 10 5 * * 0 …
# crew reset --all' left a `#' standing in front of the schedule fields, where
# `cron_entry''s `^[[:blank:]]*' cannot reach it — 141/0, nothing died, the
# same one-uncomment-from-live shape two keystrokes further out
# (@claude-bot-andresmgsl, #683; criterion 3, amended by triage 2026-09-05).
# `([[:space:]]*#+)+' strips every run and the whitespace between them, which
# is what the assertion's name has claimed all along. It cannot over-reach: the
# group only repeats where what follows a marker run is whitespace and more
# markers, so a comment that merely NAMES the verb is untouched.
t hostcron-has-no-commented-out-reset-job-line 0 \
  "$(sed -E 's/^([[:space:]]*#+)+[[:space:]]*//' "$HOST_CRONTAB" \
     | grep -cE "$cron_entry" || true)"
# The deferral is only reversible on purpose if the file says where the
# argument lives. D2 requires the comment block to name this issue and the
# collector that returns the line.
# Presence, not a count: the prose is entitled to cite either number more than
# once, and pinning a tally would make a second mention a red check. Bounded on
# the right, though — a bare `#678` is a prefix of `#6789`, so an unrelated
# citation would satisfy a substring read (@claude-bot-andresmgsl, #683).
t hostcron-deferral-names-its-issue yes \
  "$(grep -qE '#678([^0-9]|$)' "$HOST_CRONTAB" && echo yes || echo no)"
t hostcron-deferral-names-what-returns-it yes \
  "$(grep -qE '#328([^0-9]|$)' "$HOST_CRONTAB" && echo yes || echo no)"
# #589's refusal must never be handed a way past it: --force on a scheduled
# reset is the silent fleet-wide downgrade the interlock exists to prevent,
# and it would arrive as a one-word edit. The guard outlives the line it was
# written for — a reinstated reset carrying --force is exactly the edit it has
# to catch — so it is renamed to the job lines it actually reads.
t hostcron-no-job-line-carries-force 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c -- '--force' || true)"

capture help
case "$OUT" in *'4  nothing was attempted'*) r1=documented ;; *) r1="$OUT" ;; esac
t hostjob-help-documents-nothing-to-do documented "$r1"
capture help restart
case "$OUT" in *'host maintenance lock'*) r1=documented ;; *) r1="$OUT" ;; esac
t hostjob-restart-help-names-the-lock documented "$r1"

# D2 — a run that did nothing still says so, at both boundaries. This is the
# whole point of the log: silence at a boundary has to mean cron is dead, and
# it cannot mean that if a quiet run is also silent.
reset_case
LIFE_CONF="$CONF_EMPTY" capture restart --all
t hostjob-empty-roster-is-nothing-to-do 4 "$RC"
case "$OUT" in *'restart: no box selected — nothing to do'*) r1=said ;; *) r1="$OUT" ;; esac
t hostjob-empty-roster-says-so said "$r1"
case "$(job_log)" in
  *'restart run start'*'restart: no box selected'*'restart run end: nothing to do (exit 4)'*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-empty-roster-writes-both-boundaries logged "$r1"
t hostjob-empty-roster-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"

# D2 — a skipped box is NAMED in the log rather than omitted, and the boundary
# line carries the status a cron mail would have shown.
reset_case
printf 'busy:60\n' >"$STATE/probe-alpha"
capture restart --all
t hostjob-busy-run-exits-skipped-busy 3 "$RC"
case "$(job_log)" in
  *'restart run start'*'alpha: SKIPPED busy'*'skipped: alpha'*'restart run end: some boxes SKIPPED busy (exit 3)'*) r1=complete ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-log-names-the-skipped-box complete "$r1"

# D2 — a failing run reaches the log too, and its boundary line does not claim
# the run succeeded.
reset_case
LIFE_STOP_NOT_TAKE=alpha capture restart alpha
t hostjob-failed-run-exits-one 1 "$RC"
case "$(job_log)" in
  *'restart FAILED on alpha'*'restart run end: a box FAILED or was REFUSED (exit 1)'*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-log-carries-the-failure logged "$r1"
unset LIFE_STOP_NOT_TAKE

# D3 — the exit status is what a cron mail is read off, so the four outcomes
# must be four numbers. Asserted TOGETHER and in one line, because the property
# is distinctness: three separate assertions all pass on a verb that returns
# the same code for two different things.
reset_case; capture restart alpha; rc_ok=$RC
reset_case; printf 'busy:60\n' >"$STATE/probe-alpha"; capture restart alpha; rc_busy=$RC
reset_case; LIFE_STOP_NOT_TAKE=alpha capture restart alpha; rc_failed=$RC
unset LIFE_STOP_NOT_TAKE
reset_case; LIFE_CONF="$CONF_EMPTY" capture restart --all; rc_none=$RC
t hostjob-four-outcomes-are-four-statuses '0 3 1 4' \
  "$rc_ok $rc_busy $rc_failed $rc_none"

# D3 — the host lock. A second job started while the first holds it does not
# run, and says which job holds it.
reset_case
hold_host_lock
printf '%s reset 4242\n' "$(( $(date +%s) - 42 ))" >"$HOSTLOCK.holder"
capture restart --all
release_host_lock
t hostjob-lock-held-exits-nothing-to-do 4 "$RC"
# The seconds are not pinned — the age is computed against a real clock at run
# time, and an exact match would be a flake waiting for a slow runner.
case "$OUT" in
  *"SKIPPED — the host maintenance lock is held by 'crew reset' (running "*", pid 4242)"*"no box was touched"*) r1=named ;;
  *) r1="$OUT" ;;
esac
t hostjob-lock-held-names-the-holder named "$r1"
t hostjob-lock-held-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"
case "$(job_log)" in
  *"restart run skipped: the host maintenance lock is held by 'crew reset'"*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-lock-held-logs-the-skip logged "$r1"
# A run that never started must not claim it did: `run start` in the log is the
# line every reader uses to say cron fired AND the job ran.
case "$(job_log)" in *'run start'*) r1="$(job_log)" ;; *) r1=absent ;; esac
t hostjob-lock-held-writes-no-start-line absent "$r1"

# D3 — the holder is reported from a record, so an absent or malformed record
# must read as "I do not know" and never as a name. Sending an operator to look
# at a job that was not running is worse than saying nothing.
for holder_record in '' 'not-a-timestamp reset 1'; do
  reset_case
  hold_host_lock
  if [ -n "$holder_record" ]; then printf '%s\n' "$holder_record" >"$HOSTLOCK.holder"; fi
  capture restart --all
  release_host_lock
  t "hostjob-unknown-holder-still-skips-[${holder_record:-empty}]" 4 "$RC"
  case "$OUT" in *'its holder record is missing or unreadable'*) r1=honest ;; *) r1="$OUT" ;; esac
  t "hostjob-unknown-holder-does-not-guess-[${holder_record:-empty}]" honest "$r1"
done

# The green case from the test plan: two jobs colliding produce ONE run and ONE
# skip line — and the lock is released by the holder going away, not by a
# timeout, so the fleet is not wedged until somebody notices.
reset_case
hold_host_lock
printf '%s reset 4242\n' "$(date +%s)" >"$HOSTLOCK.holder"
capture restart alpha
rc_blocked=$RC
release_host_lock
capture restart alpha
t hostjob-collision-then-release '4 0' "$rc_blocked $RC"
t hostjob-collision-logs-one-skip 1 "$(grep -c 'run skipped:' "$HOSTLOG" || true)"
t hostjob-collision-logs-one-start 1 "$(grep -c 'run start' "$HOSTLOG" || true)"
t hostjob-collision-cycles-the-box-once 1 "$(grep -c '^start alpha$' "$STATE/calls" || true)"

# D2 — ROTATION BELONGS TO THE HOLDER. The evidence contract is that one run's
# start, output and end are readable together; a contender that rotated the log
# it does not own would split the run in flight across two generations, because
# `tee -a` holds the inode and host_job_log reopens by name. A reader of either
# generation then sees a start with no end — the one shape this log reserves for
# cron itself being dead.
#
# First the holder's side, so "nobody rotates" cannot pass this block: an
# oversized log IS cut, and the whole of the run that cut it is on the near side
# of the cut, with the previous generation's marker on the far side.
reset_case
big_host_log MARKER-previous-generation
capture restart alpha
gen_new="$(job_log)"
# Read the old generation's head, not the whole 6 MiB of it.
gen_old="$(head -c 120 "$HOSTLOG.1" 2>/dev/null || true)"
r1="start=$(grep -c 'run start' <<<"$gen_new" || true)"
r1="$r1 end=$(grep -c 'run end' <<<"$gen_new" || true)"
r1="$r1 box=$(grep -c 'alpha: restarted' <<<"$gen_new" || true)"
r1="$r1 marker=$(grep -c MARKER-previous-generation <<<"$gen_new" || true)"
t hostjob-rotate-holder-keeps-its-run-in-one-generation \
  'start=1 end=1 box=1 marker=0' "$r1"
# 'cut' quoted: bare, shellcheck reads the assignment as the cut(1) command.
case "$gen_old" in MARKER-previous-generation*) r1='cut' ;; *) r1="${gen_old:0:80}" ;; esac
t hostjob-rotate-holder-cuts-the-old-generation cut "$r1"

# Then the contender's: the lock is held, the log is oversized, and this
# invocation is not entitled to rotate it. The marker stands for the holder's
# in-flight evidence — it must not move — and no generation may be cut at all.
reset_case
big_host_log MARKER-in-flight
hold_host_lock
printf '%s reset 4242\n' "$(date +%s)" >"$HOSTLOCK.holder"
capture restart alpha
rc_blocked=$RC
release_host_lock
r1="rc=$rc_blocked"
r1="$r1 marker=$(grep -c MARKER-in-flight "$HOSTLOG" || true)"
r1="$r1 rotated=$([ -e "$HOSTLOG.1" ] && echo 1 || echo 0)"
r1="$r1 skip=$(grep -c 'run skipped:' "$HOSTLOG" || true)"
t hostjob-rotate-contender-rotates-nothing \
  'rc=4 marker=1 rotated=0 skip=1' "$r1"

# A lock that cannot be taken is not a lock. Without flock on PATH the verb
# REFUSES rather than running unlocked — the fail-open here is an on-demand
# `crew reset --all` rolling a fleet back underneath a restart that is
# mid-cycle. The LOCK is what this guards and this merge does not touch it:
# both verbs still contend for it. What changed is only who calls the reset —
# an operator at a prompt rather than a weekly cron entry (#678), and #328
# returns the schedule on 0.1.4 without moving a line of this.
reset_case
LIFE_PATH="$SHIM:$NO_HOST_FLOCK_BIN" capture restart --all
t hostjob-no-flock-refuses 1 "$RC"
case "$OUT" in *"needs 'flock'"*'refuses rather than'*) r1=named ;; *) r1="$OUT" ;; esac
t hostjob-no-flock-names-why named "$r1"
t hostjob-no-flock-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"

# A rejected invocation takes no fleet-wide lock and writes no boundary line:
# it is not a run, and a `run start` for a typo'd flag would make the log lie
# about how often the schedule fired.
reset_case
capture restart alpha --force-after 00
t hostjob-usage-error-still-exits-two 2 "$RC"
t hostjob-usage-error-writes-no-log '' "$(job_log)"

# --- `crew new` sizes the box it mints (#607) -------------------------------
# Asserted at the box transport boundary — the argv crew hands `box new` — for
# the reason every other case in this suite is: the sizing a role gets is a
# statement crew makes to the host, and it is the whole of crew's half of it.
# A test that minted a real box would prove the same thing about incus.
#
# Its own fleet definition, so the roster rows these cases need do not enter
# the --all iterations above and shift their counts. (The declaration itself is
# sourced at the top of this file, before the box stub is written.)
CONF_NEW="$TMP/conf-new"
mkdir -p "$CONF_NEW"
cp "$CONF/fleet.conf" "$CONF/repos.txt" "$CONF/notify-repos.txt" \
  "$CONF/doctrine.conf" "$CONF_NEW/"
cat >"$CONF_NEW/fleet.roster" <<'EOF'
gamma claude reviewer
delta claude reviewer goldbox/gold
epsilon claude builder
EOF

# The criterion in the issue's own words: a reviewer roster line with no 4th
# column produces a box at 4 vCPU / 8GiB / 60GiB. Read out of reviewer.conf at
# run time and not pinned here, so this case follows the conf it is about.
read -r EXP_CPU EXP_MEM EXP_DISK <<<"$(
  bash -c '. "$1"; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' \
    _ "$SHARED/conf/roles/reviewer.conf")"

reset_case
LIFE_CONF="$CONF_NEW" capture new gamma
t new-fresh-mint-exits-zero 0 "$RC"
# RENAMED from new-fresh-mint-carries-the-role-size (#679 D5). The old name was
# true of what it asserted and said nothing about the half that was broken: the
# argv it pinned was `--template claude-box`, a spelling box 0.10.0 refuses
# outright, so a green suite proved crew still emitted a command no supported
# box would run. These names say which contract is being guarded, so the next
# reader sees a deliberate statement rather than an edited string.
t new-fresh-mint-is-blank-and-names-no-template \
  "new --name gamma --user claude --cpu $EXP_CPU --memory $EXP_MEM --disk $EXP_DISK" \
  "$(grep '^new ' "$STATE/calls")"
t new-fresh-mint-sizes-the-reviewer-at-builder-parity \
  "new --name gamma --user claude --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$STATE/calls")"

# The criterion in the issue's own words: no --template on ANY path, asserted
# over the RECORDED ARGV and not by reading the source. A source grep would pass
# on a file that built the flag out of two variables.
t new-fresh-mint-emits-no-template-flag 0 \
  "$(grep -c -- '--template' "$STATE/calls" || true)"

# Step 3 of the sequence, at the only boundary an offline test can stand at:
# `box root` takes no argv, so what crew hands the guest arrives on stdin, and
# that script IS crew's statement about how a box gets converged.
t new-fresh-mint-opens-the-root-door 1 "$(grep -c '^root gamma$' "$STATE/calls" || true)"
t new-fresh-mint-bootstraps-the-agents-rig-role \
  "rig bootstrap claude-box" \
  "$(grep -E '^rig bootstrap ' "$STATE/root-script-gamma" || true)"
# D10's second half, and it is the half a careless implementation gets wrong:
# the tenant is named ONCE, at the mint, and the bootstrap inherits it. A
# --user on the bootstrap would be rig being told a tenant it can already see.
t new-fresh-mint-bootstrap-names-no-user 0 \
  "$(grep -c -- '--user' "$STATE/root-script-gamma" || true)"
# The rig a mint installs is the one crew DECLARES, not whatever is latest: a
# mint is not the place to take a lottery ticket on another tool's release.
t new-fresh-mint-pins-the-declared-rig 1 \
  "$(grep -c "RIG_REF=$CREW_PLATFORM_RIG_MIN" "$STATE/root-script-gamma" || true)"

# THE TWO SURFACES AN OPERATOR READS WITHOUT OPENING THE SOURCE (#679 D2, and
# the fence triage widened onto them on 2026-09-05 upholding codex-bot's
# round-2 block). The argv above is only half the retirement: `crew help`'s
# LIFECYCLE text and `crew new`'s success response both went on describing an
# <agent>-box BOX TEMPLATE — a thing box 0.10.0 refuses and D2 makes rig's ROLE.
# A tree that emits the right argv and then tells the operator it used a
# template is still shipping the contradiction, one layer up, on the two
# sentences most operators will ever read about this mint.
#
# THE EVIDENCE IS THE COMMANDS' OWN OUTPUT AND NOT THE SOURCE, in the
# criterion's own words. A source grep passes on a sentence assembled out of two
# variables, and it cannot tell the LIVE text apart from the comments beside it
# that describe the retired form deliberately — cli/crew:1523 and
# shared/lib/box-mint.sh:55 both say "template" on purpose and must keep saying
# it, which is why a grep guard was not asked for and is not written here.
#
# TWO CASES AND NOT ONE, because the criterion says EITHER surface. A single
# guard that reads only one of them passes half the criterion in silence and
# reads exactly like a working one, so the issue's two probes drive them
# separately and each names the case that dies.
reset_case
capture help
t help-lifecycle-advertises-no-box-template 0 \
  "$(grep -ci 'template' <<<"$OUT" || true)"
t help-lifecycle-names-rigs-role-instead 1 \
  "$(grep -cF 'rig converges it into its' <<<"$OUT" || true)"

reset_case
LIFE_CONF="$CONF_NEW" capture new gamma
t new-response-advertises-no-box-template 0 \
  "$(grep -ci 'template' <<<"$OUT" || true)"
# ...and the tense is the other half of the same sentence's defect, which a
# rewording that only drops the word "template" would leave in place.
# box_mint_fresh returns only AFTER `rig bootstrap` has completed, so a response
# saying the vendor CLI is "converging" describes a step that finished before it
# printed — and an operator who reads it as in flight waits for something that
# is not coming, or logs in to a box they believe is half built.
t new-response-says-convergence-completed 1 \
  "$(grep -cF "vendor CLI converged by rig into the claude-box role" <<<"$OUT" || true)"

# THE CLONE PATH PRINTS THIS SAME RESPONSE, and on it there was no template, no
# rig and no bootstrap at all — the box was copied from a gold snapshot and
# carries whatever that snapshot carried. So the sentence is BRANCHED rather
# than reworded, and this is the case that proves the branch is there: one
# corrected sentence passes both cases above and still lies here.
reset_case
LIFE_CONF="$CONF_NEW" capture new delta
t new-clone-response-says-only-that-it-was-copied \
  "delta is created — copied from goldbox/gold." \
  "$(grep -F 'delta is created' <<<"$OUT" || true)"
t new-clone-response-makes-no-rig-claim 0 \
  "$(grep -c 'converged by rig' <<<"$OUT" || true)"

# The role mapping is ASSERTED and not merely present — one case per profile,
# because a hardcoded `claude-box` passes the gamma case above and is wrong for
# three quarters of the fleet.
cat >"$CONF_NEW/fleet.roster" <<'EOF'
gamma claude reviewer
delta claude reviewer goldbox/gold
epsilon claude builder
zeta codex reviewer
eta grok reviewer
theta kimi reviewer
EOF
for profile in claude:gamma codex:zeta grok:eta kimi:theta; do
  prof_agent="${profile%%:*}"; prof_box="${profile##*:}"
  reset_case
  LIFE_CONF="$CONF_NEW" capture new "$prof_box"
  t "new-fresh-mint-$prof_agent-tenant-is-the-agents-own-name" \
    "new --name $prof_box --user $prof_agent --cpu 4 --memory 8GiB --disk 60GiB" \
    "$(grep '^new ' "$STATE/calls")"
  t "new-fresh-mint-$prof_agent-bootstraps-its-own-rig-role" \
    "rig bootstrap $prof_agent-box" \
    "$(grep -E '^rig bootstrap ' "$STATE/root-script-$prof_box" || true)"
done

# A mint that created a box and then failed to converge it says so, names the
# box as left standing, and fails — the alternative is a guest that looks hired
# and carries no vendor CLI, which is the defect crew#220 exists to close.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_ROOT_FAIL=gamma capture new gamma
t new-fresh-mint-unconverged-fails 1 "$RC"
case "$OUT" in
  *"was minted but rig did not converge it as claude-box"*"box root gamma"*) r1=named ;;
  *) r1="$OUT" ;;
esac
t new-fresh-mint-unconverged-names-the-repair named "$r1"

# D5, the half that lands — and it lands in TWO figures, not three. box 0.10.0
# takes --cpu and --memory on a copy unconditionally, but --disk only where the
# SOURCE has a root device of its own: a VM whose root is profile-inherited, or
# a source box cannot read, makes it refuse and die before `incus copy`, so
# nothing is created at all. crew therefore never passes --disk on this path.
# Triage ruled it on #607 (2026-09-03): no branch of this fix may turn a roster
# line that mints today into one that does not.
#
# The exact argv IS the assertion. A `--disk` creeping back in is invisible to
# every other test here and kills every gold-snapshot roster line on the first
# host whose gold predates box's own `--device root,size=` mints.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_RESOURCES="$EXP_CPU|$EXP_MEM|30GiB" capture new delta
t new-clone-sized-exits-zero 0 "$RC"
t new-clone-sized-carries-cpu-and-memory-only \
  "new --name delta --from goldbox/gold --cpu $EXP_CPU --memory $EXP_MEM" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-sized-passes-no-disk 0 \
  "$(grep -c -- '--disk' <<<"$(grep '^new ' "$STATE/calls")" || true)"
# A PARTIAL landing is a legitimate outcome and must be said out loud (#607
# criterion 5 as amended) — so the sized branch reports too, per figure, and
# the figure that did not ride is named as not applied rather than omitted.
t new-clone-sized-still-reports-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
note_line="$(grep '^note: ' <<<"$OUT" || true)"
t new-clone-sized-reports-cpu-applied 1 \
  "$(grep -cF 'cpu applied' <<<"$note_line" || true)"
t new-clone-sized-reports-memory-applied 1 \
  "$(grep -cF 'memory applied' <<<"$note_line" || true)"
t new-clone-sized-reports-disk-not-applied 1 \
  "$(grep -cF 'disk NOT applied' <<<"$note_line" || true)"
t new-clone-sized-names-the-carried-disk 1 \
  "$(grep -cF "carries $EXP_CPU cpu / $EXP_MEM / 30GiB" <<<"$note_line" || true)"

# D5, the half that cannot: an older box refuses the flags on a copy outright,
# so the clone is made unsized — passing them would kill every gold-snapshot
# roster line, which is the #590 defect — and ONE line names the box, all three
# verdicts, and both sizes.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old LIFE_BOX_RESOURCES='2|4GiB|30GiB' \
  capture new delta
t new-clone-unsized-exits-zero 0 "$RC"
t new-clone-unsized-passes-no-sizing-flags "new --name delta --from goldbox/gold" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-unsized-note-is-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
note_line="$(grep '^note: ' <<<"$OUT" || true)"
for needle in delta 'carries 2 cpu / 4GiB / 30GiB' \
              "profile asks $EXP_CPU cpu / $EXP_MEM / $EXP_DISK" \
              'cpu NOT applied' 'memory NOT applied' 'disk NOT applied'; do
  t "new-clone-unsized-note-names-${needle// /-}" 1 \
    "$(grep -cF "$needle" <<<"$note_line" || true)"
done
# Nothing crew did not ask for is ever reported as applied — the whole line's
# worth is that "applied" means verified.
t new-clone-unsized-claims-nothing-applied 0 \
  "$(grep -cE '(cpu|memory|disk) applied' <<<"$note_line" || true)"
# ...and the route the line hands the operator repairs EVERY figure it renders
# a verdict for. This is the branch where all three read NOT applied, so a
# route missing one is a figure the operator is told about and cannot fix.
# Memory is the figure #607 exists over — codex-reviewer died with exit 137 —
# and it was the one the first cut of this line omitted (round 1).
t new-clone-unsized-route-repairs-cpu 1 \
  "$(grep -cF "limits.cpu $EXP_CPU" <<<"$note_line" || true)"
t new-clone-unsized-route-repairs-memory 1 \
  "$(grep -cF "limits.memory $EXP_MEM" <<<"$note_line" || true)"
t new-clone-unsized-route-repairs-disk 1 \
  "$(grep -cF "root size=$EXP_DISK" <<<"$note_line" || true)"

# The probe fails CLOSED. A box whose help cannot be read at all is treated as
# one that cannot size a clone: the cost of guessing wrong that way is this
# note, and the cost of guessing wrong the other way is a `crew new` that dies
# on a roster line that worked yesterday.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=broken LIFE_BOX_RESOURCES='2|4GiB|30GiB' \
  capture new delta
t new-clone-unreadable-help-does-not-size "new --name delta --from goldbox/gold" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-unreadable-help-still-reports 1 "$(grep -c '^note: ' <<<"$OUT" || true)"

# A figure that does not read says so. The alternative — printing the profile's
# own numbers, or nothing — is a note that states as fact something crew never
# read off the daemon.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old capture new delta
t new-clone-unreadable-resources-are-not-invented 1 \
  "$(grep -c 'carries ? cpu / ? / ?' <<<"$OUT" || true)"

# ...and the same answer when the box cannot be read at all, which is a
# different line of the reader: jq's defaults answer the first case, the
# shell's the second, and only one of them runs per case.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old LIFE_BOX_RESOURCES=unreadable \
  capture new delta
t new-clone-unreadable-box-still-reports-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
t new-clone-unreadable-box-invents-nothing 1 \
  "$(grep -c 'carries ? cpu / ? / ?' <<<"$OUT" || true)"

# An unreadable figure on a flag crew DID pass is "unverified" and never
# "applied": the sized branch asked for cpu and memory, and a daemon that will
# not say what the box carries has not confirmed they landed.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_RESOURCES=unreadable capture new delta
t new-clone-sized-unreadable-is-unverified 1 \
  "$(grep -cF 'cpu unverified, memory unverified' <<<"$OUT" || true)"
t new-clone-sized-unreadable-claims-nothing-applied 0 \
  "$(grep -cE '(cpu|memory|disk) applied' <<<"$OUT" || true)"

# The builder is untouched by all of this and mints at its own figures — the
# parity is reviewer→builder, not a new tier for both.
reset_case
LIFE_CONF="$CONF_NEW" capture new epsilon
t new-builder-mint-is-blank-at-its-own-figures \
  "new --name epsilon --user claude --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$STATE/calls")"

# --- the platform declaration (#679 Part 2) ---------------------------------
# The check REPORTS and never refuses (D14), so every case here reads the
# output and the exit status separately: a finding that changed an exit status
# would be the refusal D14 forbids, wearing a report's clothes.
#
# `crew up --dry-run` is the surface, because it is the read form of the verb —
# it needs no operator configuration, so the check can be exercised without the
# fixture standing up a whole configured host to reach it.

# ONE declaration, and the criterion read literally (D11): the two floor values
# appear exactly twice in the tree's executable sources — the two lines that
# declare them — and nowhere else.
#
# NON-COMMENT LINES ONLY, and the line is drawn deliberately. cli/crew's probes
# still explain in prose that box 0.10.0 is when `down --force` and clone sizing
# ARRIVED, and that sentence is a different statement from the floor: it stays
# true when the floor moves, because it is about box's history and not about
# what crew requires. What D11 removes is a second live source of the number,
# and a comment is not one.
#
# The literals come from the declaration rather than being spelled here, so a
# bump does not have to remember this fixture — and so this guard cannot be the
# third copy of the number it exists to forbid.
PLATFORM_DECL_HITS="$(
  cd "$ROOT" || exit 1
  for f in install.sh dist/*.sh shared/bin/*.sh shared/lib/*.sh \
           shared/lib/common/*.sh shared/install.sh cli/crew drill/*.sh \
           shared/conf/fleet.defaults.conf shared/conf/agents/*.conf \
           shared/conf/roles/*.conf; do
    [ -f "$f" ] || continue
    grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
      | grep -cE "(${CREW_PLATFORM_BOX_MIN//./\\.}|${CREW_PLATFORM_RIG_MIN//./\\.})" \
      | sed "s|^|$f |"
  done | awk '$2 > 0 { print $1 ":" $2 }'
)"
t platform-declared-exactly-once "shared/lib/platform.sh:2" "$PLATFORM_DECL_HITS"

# A host AT the floor is silent. Not "quiet", not "one reassuring line": no
# output at all, because a check that speaks on a healthy fleet is a check
# operators learn to scroll past.
reset_case
LIFE_CONF="$CONF_NEW" capture up --dry-run
t platform-at-the-floor-is-silent 0 "$(grep -c 'platform check' <<<"$OUT" || true)"
t platform-at-the-floor-exits-zero 0 "$RC"

# ...and so is a host ABOVE it. This is D13 — floors, not equality — and 0.10.1
# is not a hypothetical: it exists on box's main today, so an equality pin would
# make an error of a fleet nothing is wrong with.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_VERSION=0.10.1 capture up --dry-run
t platform-above-the-floor-is-silent 0 "$(grep -c 'platform check' <<<"$OUT" || true)"
# The -dev of a version ABOVE the floor is above it too. Both tools ship -dev
# spellings on main, and a comparison that read 0.10.1-dev as below 0.10.0 would
# fire on every host tracking either tree.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_VERSION=0.10.1-dev capture up --dry-run
t platform-above-the-floor-dev-is-silent 0 "$(grep -c 'platform check' <<<"$OUT" || true)"

# The host the rig half of these cases stands on, and it is a MIXED one on
# purpose (#679 round 1). `gamma` and `delta` are rows of $CONF_NEW's roster
# that exist as boxes — crew's own fleet. `offroster` is a box on the same host
# that crew was never asked about, which is `box new --name ada --user ada` from
# box's own README and is the state any operator reaches the first time they
# mint anything of their own. `epsilon` is the third roster row and has no box,
# so the intersection is proved from both sides at once: a roster row without a
# box is not a guest, and a guest outside the roster is not crew's.
PLAT_BOXES="gamma delta offroster"

# A box BELOW the floor is a finding, and the finding names ALL FIVE figures
# (D16): crew's own version, box found and wanted, rig found and wanted. A
# message naming only the offending half makes the reader go looking for the
# other, and this triple is the thing the fleet had been reasoning about without
# ever writing it down.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST="$PLAT_BOXES" LIFE_BOX_VERSION=0.9.1 \
  capture up --dry-run
t platform-below-the-floor-reports 1 "$(grep -c 'platform check' <<<"$OUT" || true)"
t platform-below-the-floor-does-not-refuse 0 "$RC"
# Anchored to the check's OWN line: `crew up --dry-run` prints the engine
# version once per roster row, so a bare count of `crew@<ver>` passes on a
# report that never names it.
t platform-below-the-floor-names-crews-own-version 1 \
  "$(grep -cF "platform check — this crew is crew@$(head -1 "$ROOT/VERSION")" <<<"$OUT" || true)"
t platform-below-the-floor-names-box-found-and-wanted 1 \
  "$(grep -cF "box: 0.9.1 found, $CREW_PLATFORM_BOX_MIN wanted" <<<"$OUT" || true)"
t platform-below-the-floor-names-rig-found-and-wanted 1 \
  "$(grep -cF "rig: $CREW_PLATFORM_RIG_MIN found, $CREW_PLATFORM_RIG_MIN wanted" \
     <<<"$OUT" || true)"

# A missing rig is a FINDING, not a crash and not a silent pass. `none` here is
# a box that answered and carries no /etc/rig/manifest — a guest rig was
# supposed to have converged and did not.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST="$PLAT_BOXES" LIFE_GUEST_RIG=none \
  capture up --dry-run
t platform-missing-rig-reports 1 "$(grep -c 'platform check' <<<"$OUT" || true)"
t platform-missing-rig-does-not-crash 0 "$RC"
t platform-missing-rig-names-the-box 1 \
  "$(grep -c 'gamma carries no /etc/rig/manifest' <<<"$OUT" || true)"
t platform-missing-rig-still-names-all-five 1 \
  "$(grep -cF "rig: none found, $CREW_PLATFORM_RIG_MIN wanted" <<<"$OUT" || true)"
# ...and the box crew was never asked about is NOT that finding, on the run
# where it would be loudest: `offroster` carries no manifest either, and the
# whole difference between it and `gamma` is the roster.
t platform-missing-rig-leaves-offroster-alone 0 \
  "$(grep -c 'offroster carries no /etc/rig/manifest' <<<"$OUT" || true)"

# A rig BELOW the floor is the other rig finding, and it names which guest.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST="$PLAT_BOXES" LIFE_GUEST_RIG=0.3.2 \
  capture up --dry-run
# Per GUEST, and named: rig is a per-box fact, so two below-floor guests are
# two findings and each says which box it is about.
t platform-below-floor-rig-reports 1 \
  "$(grep -c 'gamma was converged by 0.3.2, below the floor' <<<"$OUT" || true)"
t platform-below-floor-rig-names-every-guest 2 \
  "$(grep -c 'was converged by 0.3.2, below the floor' <<<"$OUT" || true)"

# THE OFF-ROSTER BOX IS NOT READ AND NOT REPORTED (#679 round 1, claude-bot's
# blocking finding). `crew up` promises that a box on this host but not in the
# roster is `left alone` (cli/crew:2670) and `crew upgrade --all` already
# intersects to the roster (cli/crew:4298); a platform check that enumerated
# `box list` broke that promise twice over — it turned an operator's own box
# into a finding on a fleet nothing is wrong with, and it opened a login shell
# inside a guest crew has no mandate over to do it.
#
# Both halves are asserted, and the second is the one a "drop the finding" fix
# would leave broken: the stub records every call it is given, so the absence of
# any `exec offroster` row is the proof the box was skipped BEFORE the read and
# not merely after it. The shape is lifecycle-all-leaves-offroster's, deliberately
# — this is the same promise, kept by a second verb.
# Anchored to the check's own finding lines (`crew:   · …`) rather than to the
# whole run: `crew up` NAMES offroster elsewhere, in its `left alone` list, and
# a bare grep would be asserting the opposite of the promise by accident.
t platform-offroster-is-in-no-finding 0 \
  "$(grep -c '^crew:   · .*offroster' <<<"$OUT" || true)"
t platform-offroster-is-never-opened 0 \
  "$(grep -c '^rig-probe offroster$' "$STATE/calls" || true)"
# The 0 above is only worth something if the probe fires at all, and on a box
# whose only difference from offroster is the roster row.
t platform-roster-box-is-opened-once 1 \
  "$(grep -c '^rig-probe gamma$' "$STATE/calls" || true)"
# ...and the roster row that has no box is not invented into one: `epsilon` is
# in $CONF_NEW's roster and is not on this host, so it is neither read nor named.
t platform-roster-row-without-a-box-is-not-a-guest 0 \
  "$(grep -c 'epsilon was converged' <<<"$OUT" || true)"

# A host with no boxes says nothing about rig, and that is not an omission: rig
# runs INSIDE the guest (D15), so a host with no guest has nothing to look in,
# and the next mint is what puts one there. The box half is still checked.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST='' capture up --dry-run
t platform-no-boxes-is-silent 0 "$(grep -c 'platform check' <<<"$OUT" || true)"
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST='' LIFE_BOX_VERSION=0.9.1 capture up --dry-run
t platform-no-boxes-still-checks-the-host-half 1 \
  "$(grep -cF "box: 0.9.1 found, $CREW_PLATFORM_BOX_MIN wanted" <<<"$OUT" || true)"
t platform-no-boxes-says-so-rather-than-inventing-a-rig 1 \
  "$(grep -cF 'rig: no boxes found' <<<"$OUT" || true)"

# D14, and this is what a careless implementation breaks. The two call sites
# keep their OWN consequences and the version decides neither: `down --force`
# refuses because there is no down --force to degrade to, and clone sizing warns
# and continues because a clone carrying its source's size is still a clone.
# Asserted at a below-floor box, where a version-driven check would be loudest.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_FORCE_HELP=no LIFE_BOX_VERSION=0.9.1 capture down --force
t platform-down-force-still-refuses-below-the-floor 1 "$RC"
case "$OUT" in
  *"crew down --force requires box $CREW_PLATFORM_BOX_MIN or later"*"this host's box has no down --force"*) r1=unchanged ;;
  *) r1="$OUT" ;;
esac
t platform-down-force-message-is-unchanged unchanged "$r1"
# ...and the refusal is the CAPABILITY's, never the version's: a box at the
# floor whose help does not carry --force is still refused.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_FORCE_HELP=no LIFE_BOX_VERSION=0.10.0 capture down --force
t platform-down-force-refuses-on-capability-not-version 1 "$RC"
# ...and the converse, which is the half a version check would get wrong: a box
# BELOW the declared floor whose help DOES carry --force is not refused.
# (`crew down` takes no box names — it is the roster-wide verb — so the case is
# the bare --force, and the roster it reads names no box that exists.)
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_VERSION=0.9.1 capture down --force
t platform-down-force-allowed-on-capability-below-the-floor 0 "$RC"
t platform-down-force-below-the-floor-is-not-refused 0 \
  "$(grep -c 'requires box' <<<"$OUT" || true)"

# Clone sizing degrades and continues — it never refuses — with the box below
# the floor. `crew new delta` clones, and LIFE_CLONE_SIZING=old is the box whose
# help does not offer the flags.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old LIFE_BOX_VERSION=0.9.1 capture new delta
t platform-clone-sizing-degrades-rather-than-refusing 0 "$RC"
t platform-clone-sizing-still-mints 1 "$(grep -c '^new --name delta --from ' "$STATE/calls" || true)"
t platform-clone-sizing-note-reads-the-declaration 1 \
  "$(grep -cF "predates $CREW_PLATFORM_BOX_MIN clone sizing" <<<"$OUT" || true)"

# D8's fence, read from the side that proves it held: the clone argv is
# byte-identical to what it was before this change. A --user or a dropped flag
# creeping onto this path is invisible to every other case here.
reset_case
LIFE_CONF="$CONF_NEW" capture new delta
t platform-clone-argv-is-byte-identical \
  "new --name delta --from goldbox/gold --cpu 4 --memory 8GiB" \
  "$(grep '^new ' "$STATE/calls")"
t platform-clone-opens-no-root-door 0 "$(grep -c '^root ' "$STATE/calls" || true)"

# D12's other half, and the criterion is a COMPARISON rather than two separate
# readings: `crew up` and the installer both report a below-floor box, and
# their messages are IDENTICAL. So both surfaces are driven here, against the
# same stub host at the same below-floor version, and the two blocks are
# diffed. Asserting each one separately against a pinned string would pass on
# two reporters that had drifted into two wordings a fixture happened to have
# been updated for twice.
#
# The installer runs for real and offline, out of this tree into scratch — the
# same thing shared/test/install-lifecycle.sh does — because the finding is
# printed by a `report_platform` call in install.sh's own body, and a source
# grep would not notice the day it stopped being reached.
platform_block() { # TEXT — the report, from its first line to its last
  awk '/platform check/,/built and tested against/' <<<"${1:-}"
}

#
# BOTH SURFACES ARE GIVEN THE SAME FLEET DEFINITION, and since #679's round 1
# that is load-bearing rather than incidental. The rig half reads the guests
# crew was asked about, so "identical" is a claim about two verbs on ONE host —
# same box, same roster, same guests — and a fixture that gave `crew up` a
# roster and the installer a bare scratch HOME would be diffing two different
# machines and calling the difference a wording. `crew up` resolves $CONF_NEW
# through CREW_CONFIG_DIR the way every case here does; the installer is handed
# the same directory, and platform_roster_names resolves it identically.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_LIST="$PLAT_BOXES" LIFE_BOX_VERSION=0.9.1 \
  capture up --dry-run
up_block="$(platform_block "$OUT")"

INSTALL_HOME="$TMP/install-home"
mkdir -p "$INSTALL_HOME"
install_out="$(
  env HOME="$INSTALL_HOME" XDG_CONFIG_HOME="$INSTALL_HOME/xdg" CREW_YES=1 \
    CREW_HOME="$INSTALL_HOME/share" CREW_BIN="$INSTALL_HOME/bin" \
    CREW_CONFIG_DIR="$CONF_NEW" \
    LIFE_STATE="$STATE" LIFE_BOX_VERSION=0.9.1 \
    LIFE_GUEST_RIG="$CREW_PLATFORM_RIG_MIN" \
    LIFE_BOX_LIST="$PLAT_BOXES" \
    PATH="$SHIM:$PATH" bash "$ROOT/install.sh" 2>&1 || true
)"
install_block="$(platform_block "$install_out")"
t platform-installer-reports-a-below-floor-box 1 \
  "$(grep -c 'platform check' <<<"$install_out" || true)"
t platform-installer-and-up-report-identically "$up_block" "$install_block"
# The installer still installs. D14 is not a rule about `crew` alone: a floor
# that refused an install would be the same conversion of a report into a
# refusal, at the surface where it costs the most.
t platform-installer-still-finishes 1 \
  "$(grep -c 'done (' <<<"$install_out" || true)"

# THE FIRST INSTALL, which has no fleet definition at all — the state of every
# host the moment before `crew init`, and the one the installer actually meets
# most often. It is not a finding. The BOX half is still checked, because the
# floor is a fact about this host and needs no roster to be true, and it is the
# half the operator on box 0.9.x is here to be told about. The RIG half says
# `no boxes` and invents no verdict: with nothing crew was asked about, there is
# no guest it has any business opening, which is the same silence D15 already
# gives a host with no boxes at all.
#
# Its own state dir, so the recorded calls below are this run's alone.
FRESH_STATE="$TMP/state-fresh"
FRESH_HOME="$TMP/install-home-fresh"
mkdir -p "$FRESH_STATE" "$FRESH_HOME/xdg"
# Created empty rather than left to the stub, so the read below is a count of
# zero rows and not a read of a missing path — which is the same answer for a
# different reason and compares unequal to every expectation.
: >"$FRESH_STATE/calls"
fresh_out="$(
  env HOME="$FRESH_HOME" XDG_CONFIG_HOME="$FRESH_HOME/xdg" CREW_YES=1 \
    CREW_HOME="$FRESH_HOME/share" CREW_BIN="$FRESH_HOME/bin" \
    LIFE_STATE="$FRESH_STATE" LIFE_BOX_VERSION=0.9.1 \
    LIFE_GUEST_RIG="$CREW_PLATFORM_RIG_MIN" \
    LIFE_BOX_LIST="$PLAT_BOXES" \
    PATH="$SHIM:$PATH" bash "$ROOT/install.sh" 2>&1 || true
)"
t platform-first-install-still-checks-the-host-half 1 \
  "$(grep -cF "box: 0.9.1 found, $CREW_PLATFORM_BOX_MIN wanted" <<<"$fresh_out" || true)"
t platform-first-install-invents-no-rig-verdict 1 \
  "$(grep -cF 'rig: no boxes found' <<<"$fresh_out" || true)"
t platform-first-install-opens-no-guest 0 \
  "$(grep -c '^rig-probe ' "$FRESH_STATE/calls" || true)"
t platform-first-install-still-finishes 1 \
  "$(grep -c 'done (' <<<"$fresh_out" || true)"

# TWO WORDINGS THE REPORT GOT WRONG ON HOSTS NOTHING IS WRONG WITH (#679 round
# 2, claude-bot's non-blocking notes). Both are reachable, and neither was
# fixtured — which is how they survived a round that measured everything else.
#
# THE PATH IS BUILT RATHER THAN STRIPPED. `command -v` answers out of PATH, so
# the only way to make a tool absent is to hand the run a PATH that never had
# it: $BARE carries the handful of binaries the reporter itself uses and neither
# `box` nor `jq`. The two preconditions below assert that emptiness, because a
# case that quietly found a jq would pass for the wrong reason and read exactly
# like a working one.
#
# report_platform is driven directly rather than through a verb: `crew up` needs
# a box to converge and the installer needs a whole tree, and what is under test
# is one sentence the reporter prints. The two surfaces that call it are already
# diffed against each other above.
BARE="$TMP/bare-bin"
mkdir -p "$BARE"
for bare_tool in bash env awk sed grep head sort paste cut tr cat timeout; do
  bare_path="$(command -v "$bare_tool" 2>/dev/null)" || continue
  ln -sf "$bare_path" "$BARE/$bare_tool"
done

plat_probe() { # PATH — the report, both streams
  # `$1` in the -c string is the CHILD shell's first positional — the path
  # passed after the `_` — so the single quotes are the point, and expanding it
  # here would substitute this function's own argument, the PATH.
  # shellcheck disable=SC2016
  env -i PATH="$1" HOME="$TMP" LIFE_STATE="$STATE" \
    CREW_PLATFORM_BOX_MIN="$CREW_PLATFORM_BOX_MIN" \
    LIFE_BOX_VERSION=0.9.1 LIFE_GUEST_RIG="$CREW_PLATFORM_RIG_MIN" \
    LIFE_BOX_LIST="$PLAT_BOXES" CREW_CONFIG_DIR="$CONF_NEW" \
    "$BARE/bash" -c '. "$1"; report_platform 0.0.0-probe' \
    _ "$SHARED/lib/platform.sh" 2>&1 || true
}

t platform-nobox-probe-really-has-no-box "" \
  "$(env -i PATH="$BARE" "$BARE/bash" -c 'command -v box || true')"
t platform-nojq-probe-really-has-no-jq "" \
  "$(env -i PATH="$SHIM:$BARE" "$BARE/bash" -c 'command -v jq || true')"

# crew installed before box is the ordinary first install, not an exotic one,
# and the box half's default used to be the PHRASE "not found" dropped into a
# sentence that already said `found`.
nobox_out="$(plat_probe "$BARE")"
t platform-no-box-on-path-reports-none-found 1 \
  "$(grep -cF "box: none found, $CREW_PLATFORM_BOX_MIN wanted" <<<"$nobox_out" || true)"
t platform-no-box-on-path-does-not-say-found-twice 0 \
  "$(grep -c 'not found found' <<<"$nobox_out" || true)"
# ...and the finding under it is unchanged: this was a wording defect in the
# found/wanted line and nothing else moves.
t platform-no-box-on-path-still-names-the-finding 1 \
  "$(grep -c 'box: not found on PATH' <<<"$nobox_out" || true)"
# The rig half cannot look either, and says so rather than reporting a fleet.
t platform-no-box-on-path-does-not-claim-an-empty-fleet 1 \
  "$(grep -cF 'rig: not read (no box on this host)' <<<"$nobox_out" || true)"

# `no boxes found` on a host with three boxes, because the reader could not be
# run: box list is JSON and jq is what parses it. "No boxes" and "could not
# look" are different answers, and reporting the fleet as empty is the more
# expensive of the two to be wrong about.
nojq_out="$(plat_probe "$SHIM:$BARE")"
t platform-no-jq-says-the-guests-were-not-read 1 \
  "$(grep -cF 'rig: not read (no jq on this host)' <<<"$nojq_out" || true)"
t platform-no-jq-does-not-claim-an-empty-fleet 0 \
  "$(grep -cF 'rig: no boxes found' <<<"$nojq_out" || true)"
# The box half is the one that matters at install time and it is unaffected —
# the degradation stays a degradation, and D14 is untouched by either wording.
t platform-no-jq-still-reports-the-box-half 1 \
  "$(grep -cF "box: 0.9.1 found, $CREW_PLATFORM_BOX_MIN wanted" <<<"$nojq_out" || true)"
t platform-no-jq-does-not-refuse 1 \
  "$(grep -c 'rather than refusing' <<<"$nojq_out" || true)"

suite_finish
