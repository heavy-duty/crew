#!/usr/bin/env bash
# Offline contract suite for `crew reset` — the `armed` checkpoint (#589).
# The real verb runs unchanged; only the host-owned box CLI/control channel is
# replaced, exactly as cli-lifecycle.sh does for restart/down.
#
# THE ORDERING TEST IS THE ONE THAT NEEDED DESIGNING. D7's whole content is
# "reclaim, then measure, then decide", and an assertion that merely watches
# both calls happen would pass on the inverted order too. So the stub makes the
# box's disk reading DEPEND on the sweep: `df` answers RST_PCT_BEFORE until
# reap-now.sh has run against that box and RST_PCT_AFTER afterwards. A cut that
# measured first would read 95% and refuse the box this suite proves is cut —
# the fixture cannot pass with the steps the other way round.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
# A literal here pins the fixture to one release rung instead of to the verb;
# #659's bare release cut exposed that collision. Read the committed tree just
# as the engine does, then derive both fixture roles from it. The suffixes make
# today's values distinct; the guard remains a tripwire for a future derivation.
ENGINE_VERSION="$(git -C "$ROOT" show HEAD:VERSION | tr -d '\r\n')"
BOX_STAMP_VERSION="${ENGINE_VERSION}-box-stamp-fixture"
CHECKPOINT_VERSION="${ENGINE_VERSION}-checkpoint-fixture"
if [ "$BOX_STAMP_VERSION" = "$ENGINE_VERSION" ] ||
   [ "$CHECKPOINT_VERSION" = "$ENGINE_VERSION" ] ||
   [ "$BOX_STAMP_VERSION" = "$CHECKPOINT_VERSION" ]; then
  printf 'fixture version collision: engine=%s box=%s checkpoint=%s\n' \
    "$ENGINE_VERSION" "$BOX_STAMP_VERSION" "$CHECKPOINT_VERSION" >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
CONF="$TMP/conf"
SHIM="$TMP/shim"
STATE="$TMP/state"
PROBE_BIN="$TMP/probe-bin"
# #590. `crew reset` takes a host lock and writes a host job log. It was the
# weekly scheduled job when that was written; since #678 it is unscheduled and
# on demand, and the lock and the log are the verb's either way — which is why
# this sandboxing is unaffected. Both are pointed at this sandbox —
# otherwise the suite writes into the machine's real ~/.local/state, and
# contends over one real lock with any other suite driving `crew restart`.
HOSTSTATE="$TMP/host-state"
HOSTLOG="$HOSTSTATE/host-maintenance.log"
mkdir -p "$CONF" "$SHIM" "$STATE" "$STATE/guests" "$PROBE_BIN" "$HOSTSTATE"
ln -s "$(command -v cat)" "$PROBE_BIN/cat"
cat >"$PROBE_BIN/date" <<'EOF'
#!/bin/bash
printf '%s\n' "${RST_NOW:-10000}"
EOF
cat >"$PROBE_BIN/flock" <<'EOF'
#!/bin/bash
exit "${RST_FLOCK_RC:-0}"
EOF
chmod +x "$PROBE_BIN/date" "$PROBE_BIN/flock"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta codex reviewer
EOF

cat >"$SHIM/box" <<'SHIMEOF'
#!/usr/bin/env bash
set -u
state_dir="$RST_STATE"
calls="$state_dir/calls"
snaps_of() { cat "$state_dir/snaps-$1" 2>/dev/null; }
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"alpha"},{"name":"beta"},{"name":"offroster"}]\n'
    else
      printf 'NAME\nalpha\nbeta\noffroster\n'
    fi
    ;;
  info)
    name="$1"; shift || true
    state="running"
    [ ! -s "$state_dir/state-$name" ] || state="$(cat "$state_dir/state-$name")"
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"%s","status":"%s","state":{"status":"%s"}}]\n' "$name" "$state" "$state"
      exit 0
    fi
    printf 'info %s\n' "$name" >>"$calls"
    # A listing crew cannot read at all — D4's third value. Deliberately NOT
    # an empty SNAPSHOTS block: the point is that "I could not look" must not
    # score the same as "I looked and there is none".
    if [ "$name" = "${RST_INFO_BROKEN:-}" ]; then
      printf 'NAME       %s\nSTATE      %s\n' "$name" "$state"
      exit 0
    fi
    printf 'NAME       %s\nSTATE      %s\nTYPE       vm\n\n' "$name" "$state"
    if [ -s "$state_dir/snaps-$name" ]; then
      printf 'SNAPSHOTS\n'
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '  %-14s%s\n' "$s" "2026-09-02T00:00Z"
      done <"$state_dir/snaps-$name"
      printf '\n'
      printf 'Clone one:  box new --name <new> --from %s/armed\n' "$name"
    else
      printf 'SNAPSHOTS  (none)\n\n'
      printf 'Take one:   box snapshot %s authed\n' "$name"
    fi
    ;;
  snapshot)
    name="$1"; label="${2:-}"
    printf 'snapshot %s %s\n' "$name" "$label" >>"$calls"
    if [ "$name" = "${RST_SNAPSHOT_FAIL:-}" ]; then exit 1; fi
    # incus refuses a label that already exists; the real thing does too, and
    # the re-cut path is only correct because it deletes first.
    if grep -qx -- "$label" <<<"$(snaps_of "$name")"; then
      echo "Error: snapshot \"$label\" already exists" >&2; exit 1
    fi
    printf '%s\n' "$label" >>"$state_dir/snaps-$name"
    printf '%s\n' "$label"
    ;;
  restore)
    name="$1"; label="${2:-}"
    printf 'restore %s %s%s\n' "$name" "$label" "${3:+ $3}" >>"$calls"
    if [ "$name" = "${RST_RESTORE_FAIL:-}" ]; then exit 1; fi
    grep -qx -- "$label" <<<"$(snaps_of "$name")" || { echo "Error: no snapshot $label" >&2; exit 1; }
    ;;
  incus)
    name="$1"; shift
    [ "${1:-}" != -- ] || shift
    printf 'incus %s %s\n' "$name" "$*" >>"$calls"
    case "${1:-} ${2:-}" in
      "snapshot delete")
        label="${4:-}"
        if [ "$name" = "${RST_SNAPDEL_FAIL:-}" ]; then exit 1; fi
        grep -vx -- "$label" "$state_dir/snaps-$name" >"$state_dir/snaps-$name.n" 2>/dev/null
        mv "$state_dir/snaps-$name.n" "$state_dir/snaps-$name"
        ;;
      *) exit 2 ;;
    esac
    ;;
  down)
    name="$1"; shift || true
    printf 'down %s%s\n' "$name" "${1:+ $1}" >>"$calls"
    if [ "$name" = "${RST_DOWN_FAIL:-}" ]; then exit 1; fi
    if [ "$name" != "${RST_STOP_NOT_TAKE:-}" ]; then printf 'stopped\n' >"$state_dir/state-$name"; fi
    ;;
  start)
    name="$1"
    printf 'start %s\n' "$name" >>"$calls"
    if [ "$name" = "${RST_START_FAIL:-}" ]; then exit 1; fi
    printf 'running\n' >"$state_dir/state-$name"
    ;;
  new)
    printf 'new %s\n' "$*" >>"$calls"
    ;;
  exec)
    name="$1"; shift
    script="${*: -1}"
    current="running"
    [ ! -s "$state_dir/state-$name" ] || current="$(cat "$state_dir/state-$name")"
    [ "$current" != stopped ] || exit 1
    if [[ "$script" == *'flock -n "$lock"'* ]]; then
      probe="$state_dir/probe-$name"
      value="${RST_PROBE_DEFAULT:-idle:0}"
      if [ -s "$probe" ]; then
        value="$(head -1 "$probe")"
        tail -n +2 "$probe" >"$probe.next"
        mv "$probe.next" "$probe"
      fi
      guest_home="$state_dir/guests/$name"
      mkdir -p "$guest_home/duty"
      rm -f "$guest_home/duty/.duty.lock.since"
      case "$value" in
        idle:*) probe_rc=0 ;;
        busy:*)
          probe_rc=1
          printf '%s\n' "$((10000 - ${value#busy:}))" >"$guest_home/duty/.duty.lock.since"
          ;;
        unreadable) exit 1 ;;
        *) exit 2 ;;
      esac
      env HOME="$guest_home" PATH="$RST_PROBE_BIN" RST_FLOCK_RC="$probe_rc" RST_NOW=10000 \
        /bin/bash -c "$script"
    elif [[ "$script" == *'echo "::logstart"'* ]]; then
      # The drain's full probe (#761): a reset drains the box to the store
      # before the disk goes back. RST_DRAIN_FAIL names a box whose drain
      # answers nothing, which the store refuses as a truncated record.
      # First in the chain: probe.sh carries most of the strings the arms
      # below key on, so behind them it would never be reached.
      printf 'drain %s\n' "$name" >>"$calls"
      [ "$name" != "${RST_DRAIN_FAIL:-}" ] || exit 0
      printf '::engine 9.9.9\n::integrity current\n::agent claude\n::uptime 1\n::now 2026-10-23T12:00:00Z\n'
      printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n::vitals \n'
      printf '::logstart\n2026-10-23T11:00:00Z duty run start\n::logend\n'
      printf '::statefiles .seen-build\n::filestart .seen-build\no/r#1 2026-10-23T00:00:00Z\n::fileend\n'
      printf '::logfrom 1\n::logtotal 1\n::filestart duty.log\n2026-10-23T11:00:00Z duty run start\n::fileend\n'
    elif [[ "$script" == *'gh auth status'* ]]; then
      printf 'login-probe %s\n' "$name" >>"$calls"
      case " ${RST_LOGGED_IN:-} " in *" $name "*) exit 0 ;; *) exit 1 ;; esac
    elif [[ "$script" == *'engine-manifest.sh'* ]]; then
      printf 'engine-probe %s\n' "$name" >>"$calls"
      stamp_var="RST_STAMP_$name"
      stamp="${!stamp_var:-}"
      if [ -z "$stamp" ]; then
        printf 'state=absent\nstamp=\nrecorded=\n'
      else
        printf 'state=current\nstamp=crew@%s\nrecorded=crew@%s\n' "$stamp" "$stamp"
      fi
    elif [[ "$script" == *'/etc/rig/role'* ]]; then
      # rig's convergence marker. Needed because this suite now drives `crew
      # hire` and `crew up` for real — the stale mark is theirs as much as
      # `crew upgrade`'s — and the convergence guard runs ahead of everything.
      printf 'rig-probe %s\n' "$name" >>"$calls"
      agent_var="RST_AGENT_$name"
      printf 'probe=ok\nmarker=role=%s-box tenant=yes host=no\n' "${!agent_var:-claude}"
    elif [[ "$script" == *'instance.conf'* ]]; then
      # The agent the box was ACTUALLY installed as. D1's vendor half reads it
      # from here rather than from the roster, so this arm — not the roster
      # file — is what an off-roster box or a mis-installed one answers with.
      printf 'agent-probe %s\n' "$name" >>"$calls"
      agent_var="RST_AGENT_$name"
      printf '%s\n' "${!agent_var:-}"
    elif [[ "$script" == *'bot_cli_probe'* ]]; then
      # D1's vendor login probe. The profile arrives on stdin, so drain it —
      # a shim that leaves it unread makes the real caller's redirect look
      # like it worked for a reason that has nothing to do with the probe.
      cat >/dev/null
      printf 'vendor-probe %s\n' "$name" >>"$calls"
      case " ${RST_VENDOR_OUT:-} " in *" $name "*) exit 1 ;; *) exit 0 ;; esac
    elif [[ "$script" == *'reap-now.sh'* ]]; then
      printf 'reap %s\n' "$name" >>"$calls"
      if [ "$name" = "${RST_REAP_FAIL:-}" ]; then
        echo "reap-now.sh: a duty tick holds .duty.lock — nothing run" >&2
        exit "${RST_REAP_RC:-199}"
      fi
      : >"$state_dir/reaped-$name"
      echo "reaper: transcripts reclaimed 12345 bytes in 3 files"
    elif [[ "$script" == *'df -Pk /'* ]]; then
      printf 'root-df %s\n' "$name" >>"$calls"
      # THE ORDERING FIXTURE: the reading depends on the sweep having run.
      if [ -f "$state_dir/reaped-$name" ]; then
        printf '%s%%\n' "${RST_PCT_AFTER:-40}"
      else
        printf '%s%%\n' "${RST_PCT_BEFORE:-40}"
      fi
    elif [[ "$script" == *'du -shx'* ]]; then
      printf 'large-probe %s\n' "$name" >>"$calls"
      [ -n "${RST_LARGE:-}" ] || exit 1
      printf '%s\n' "$RST_LARGE"
    elif [[ "$script" == *'df -Pk'* ]]; then
      printf 'free-probe %s\n' "$name" >>"$calls"
      printf '1200\n'
    elif [[ "$script" == *'destination="$HOME/duty/'* ]]; then
      # The memory write-back rides bxput (#761): the archive arrives on
      # stdin and the remote script names its destination under ~/duty.
      cat >/dev/null
      printf 'memory %s %s\n' "$name" "$(printf '%s' "$script" | sed -n 's|.*destination="\$HOME/duty/\([^"]*\)".*|\1|p' | head -1)" >>"$calls"
    elif [[ "$script" == *'tar -xf .memory-restore.tar'* ]]; then
      # ...and is unpacked under the duty lock; the box answers `restored`.
      printf 'memory-unpack %s\n' "$name" >>"$calls"
      [ "$name" != "${RST_UNPACK_FAIL:-}" ] || exit 1
      echo restored
      cat >/dev/null
    elif [[ "$script" == *'touch ~/duty/.memory-pending'* ]]; then
      # The checkpoint's marker (#763 re-review): set on the live box for the
      # snapshot's duration, lifted after it and by the memory's return.
      printf 'pending-on %s\n' "$name" >>"$calls"
    elif [[ "$script" == *'rm -f ~/duty/.memory-pending'* ]]; then
      printf 'pending-off %s\n' "$name" >>"$calls"
    elif [[ "$script" == *'crontab -l'* ]]; then
      exit 1
    else
      # The hire and upgrade paths' staging and install execs. Logged rather
      # than matched one by one: this suite's subject is the checkpoint mark
      # they leave behind, not the transport #159 already covers. RST_INSTALL_
      # FAIL breaks the first of them, which is how the "mark landed, install
      # failed" arm — the chosen residual of marking first — is driven.
      # The engine install itself gets its own line. `exec` also counts the
      # registry and identity reads a hire makes BEFORE the gate, so a fixture
      # asserting "nothing was installed" has to name the install and not the
      # channel it travels on.
      # Anchored on install_staged_engine's own retire line, not on the string
      # `install.sh` — that appears in stage_engine's `test -f` too, and
      # counting both made a single install look like two.
      case "$script" in *'retired obsolete box-side engine source'*) printf 'install %s\n' "$name" >>"$calls" ;; esac
      # A hire carrying a credential pool names it on the install line (#761).
      case "$script" in
        *"--pool '"*) printf 'pool %s %s\n' "$name" "$(printf '%s' "$script" | sed -n "s/.*--pool '\([^']*\)'.*/\1/p" | head -1)" >>"$calls" ;;
      esac
      printf 'exec %s\n' "$name" >>"$calls"
      if [ "$name" = "${RST_INSTALL_FAIL:-}" ]; then exit 1; fi
    fi
    ;;
  *) exit 2 ;;
esac
SHIMEOF
chmod +x "$SHIM/box"

reset_case() {
  find "$STATE" -mindepth 1 -maxdepth 1 -type f -delete
  find "$STATE/guests" -mindepth 1 -delete 2>/dev/null
  # chmod first: the unwritable-record fixtures leave this directory read-only
  # on purpose, and an `rm -rf` that silently failed there would carry one
  # case's record into the next case as a phantom checkpoint.
  [ ! -d "$CONF/checkpoints" ] || chmod u+w "$CONF/checkpoints"
  rm -rf "$CONF/checkpoints"
  : >"$STATE/calls"
}

run_crew() {
  env CREW_CONFIG_DIR="$CONF" CREW_HOST_STATE_DIR="$HOSTSTATE" \
    RST_STATE="$STATE" RST_PROBE_BIN="$PROBE_BIN" \
    RST_PROBE_DEFAULT="${RST_PROBE_DEFAULT:-idle:0}" \
    RST_LOGGED_IN="${RST_LOGGED_IN:-alpha beta}" \
    RST_VENDOR_OUT="${RST_VENDOR_OUT:-}" RST_REAP_RC="${RST_REAP_RC:-199}" \
    RST_INSTALL_FAIL="${RST_INSTALL_FAIL:-}" \
    RST_AGENT_alpha="${RST_AGENT_alpha-claude}" RST_AGENT_beta="${RST_AGENT_beta-codex}" \
    RST_AGENT_offroster="${RST_AGENT_offroster-claude}" \
    RST_STAMP_alpha="${RST_STAMP_alpha-$BOX_STAMP_VERSION}" \
    RST_STAMP_beta="${RST_STAMP_beta-$BOX_STAMP_VERSION}" \
    RST_PCT_BEFORE="${RST_PCT_BEFORE:-40}" RST_PCT_AFTER="${RST_PCT_AFTER:-40}" \
    RST_LARGE="${RST_LARGE-13G /swapfile;13G /swapfile-drill;19G /var;6.9G /home;}" \
    RST_INFO_BROKEN="${RST_INFO_BROKEN:-}" RST_REAP_FAIL="${RST_REAP_FAIL:-}" \
    RST_SNAPSHOT_FAIL="${RST_SNAPSHOT_FAIL:-}" RST_SNAPDEL_FAIL="${RST_SNAPDEL_FAIL:-}" \
    RST_RESTORE_FAIL="${RST_RESTORE_FAIL:-}" RST_DOWN_FAIL="${RST_DOWN_FAIL:-}" \
    RST_STOP_NOT_TAKE="${RST_STOP_NOT_TAKE:-}" RST_START_FAIL="${RST_START_FAIL:-}" \
    CREW_RESET_CUT_MAX_USED_PCT="${CREW_RESET_CUT_MAX_USED_PCT-80}" \
    CREW_DRAIN_POLL_SECONDS=0 CREW_RESTART_READY_POLL_SECONDS=0 \
    CREW_RESTART_READY_ATTEMPTS=3 PATH="$SHIM:$PATH" bash "$CLI" "$@"
}

capture() {
  if OUT="$(run_crew "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

# arm NAME [VERSION] — the state a real `--cut` leaves: the guest-side label
# AND its host-side record. The two are separate stores and drift apart in
# real life, so the label-only helper below is a DIFFERENT state and not a
# shorthand for this one — a restore of it is refused, and the fixture for
# that says so by name. The green path is still proved by driving the real
# `--cut` (reset-restores-and-starts and friends do exactly that); this pair
# exists so the fixtures that are about something else can set a starting
# state without four commands.
arm() {
  arm_label_only "$1"
  mkdir -p "$CONF/checkpoints"
  {
    printf '# crew reset checkpoint record for %s (#589 D5). Written by the fixture.\n' "$1"
    printf 'CHECKPOINT_VERSION=%s\n' "${2:-$CHECKPOINT_VERSION}"
    printf 'CHECKPOINT_CUT_AT=2026-09-02T00:00:00Z\n'
    printf 'CHECKPOINT_STALE=\n'
  } >"$CONF/checkpoints/$1.conf"
}
arm_label_only() { printf '%s\n' "armed" >"$STATE/snaps-$1"; }
calls_of() { grep -c "^$1" "$STATE/calls" 2>/dev/null || true; }

# --- D2: the help states the credential fact and the trust boundary ---------

reset_case
capture help reset
case "$OUT" in *'LIVE CREDENTIALS'*'trust boundary'*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-states-credentials-and-trust-boundary stated "$r1"
case "$OUT" in *"refused as a 'crew new --from' source"*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-states-clone-refusal stated "$r1"
case "$OUT" in *"never rolled back to 'bootstrapped'"*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-rules-out-other-labels stated "$r1"
capture help
case "$OUT" in *'reset'*"Restore boxes to their 'armed' checkpoint"*) r1=listed ;; *) r1="$OUT" ;; esac
t reset-appears-in-the-command-table listed "$r1"

# --- D1: --cut refuses a box that is not logged in, and one that is not hired

reset_case
RST_LOGGED_IN="beta" capture reset --cut alpha
t reset-cut-refuses-unauthenticated-box 1 "$RC"
case "$OUT" in *'alpha: REFUSED — not logged in'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unauthenticated-is-named named "$r1"
t reset-cut-unauthenticated-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_STAMP_alpha="" capture reset --cut alpha
t reset-cut-refuses-unhired-box 1 "$RC"
case "$OUT" in *'alpha: REFUSED — not hired'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unhired-is-named named "$r1"
t reset-cut-unhired-cuts-nothing 0 "$(calls_of 'snapshot')"

# LOGGED IN IS BOTH HALVES. `crew help`'s own lifecycle prose puts the vendor
# CLI's login beside `gh auth login` as one human step, and the cut proved only
# the GitHub half — so a box with live GitHub credentials and a logged-out
# Claude/Codex CLI was checkpointed as `armed`. That is the half-built box D1
# refuses: every session it starts dies at the model, and the checkpoint would
# freeze that state as the one the fleet returns to every week.
reset_case
RST_VENDOR_OUT=alpha capture reset --cut alpha
t reset-cut-refuses-a-vendor-logged-out-box 1 "$RC"
case "$OUT" in *'alpha: REFUSED — its claude CLI is not logged in'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-vendor-logout-is-named named "$r1"
t reset-cut-vendor-logout-cuts-nothing 0 "$(calls_of 'snapshot')"
# The GitHub half passed. Without that, this fixture would pass on the old
# code too — it has to be the vendor probe that does the refusing.
t reset-cut-vendor-logout-passed-the-github-half 1 "$(calls_of 'login-probe alpha')"
t reset-cut-probes-the-vendor-login 1 "$(calls_of 'vendor-probe alpha')"
# Never reached the reaper: D1 is a precondition, not a post-check.
t reset-cut-vendor-logout-never-reaps 0 "$(calls_of 'reap')"

# The agent comes from the instance.conf the install wrote, not the roster, so
# it covers an off-roster box and answers with what the box IS. A box that
# cannot say is refused rather than probed against a guess.
reset_case
RST_AGENT_alpha="" capture reset --cut alpha
t reset-cut-refuses-a-box-with-no-recorded-agent 1 "$RC"
case "$OUT" in *'does not say which agent it was installed as'*'crew hire alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unknown-agent-is-named named "$r1"
t reset-cut-unknown-agent-never-probes-a-vendor 0 "$(calls_of 'vendor-probe')"
t reset-cut-unknown-agent-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_AGENT_alpha=nosuchvendor capture reset --cut alpha
t reset-cut-refuses-an-agent-with-no-profile 1 "$RC"
case "$OUT" in *"installed as agent 'nosuchvendor'"*'resolves to no profile'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unresolvable-profile-is-named named "$r1"
t reset-cut-unresolvable-profile-cuts-nothing 0 "$(calls_of 'snapshot')"

# The vendor probe is per-box and reads the box's own agent: beta is a codex
# box, and its refusal says codex.
reset_case
RST_VENDOR_OUT=beta capture reset --cut beta
case "$OUT" in *'beta: REFUSED — its codex CLI is not logged in'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-vendor-refusal-names-the-boxs-own-agent named "$r1"

# --- D5's write side: an unparseable stamp is not a version to record -------
#
# This coerced to the literal `unknown` and RECORDED it, so `--cut` put a
# nonempty non-version into CHECKPOINT_VERSION by its own hand and the
# emptiness check downstream sailed past it. Legacy SHA-only stamps are a
# supported, reachable state (fleet-floor/test/cli.sh pins them), so this is
# the ordinary path for an old box and not a corner.
reset_case
RST_STAMP_alpha=1a2b3c4d capture reset --cut alpha
t reset-cut-refuses-an-unparseable-stamp 1 "$RC"
case "$OUT" in *"engine stamp 'crew@1a2b3c4d' is not a version that can be recorded"*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unparseable-stamp-is-named named "$r1"
t reset-cut-unparseable-stamp-cuts-nothing 0 "$(calls_of 'snapshot')"
t reset-cut-unparseable-stamp-records-nothing absent \
  "$([ -e "$CONF/checkpoints/alpha.conf" ] && echo present || echo absent)"
# The refusal is a precondition: nothing was reclaimed or measured for it.
t reset-cut-unparseable-stamp-never-reaps 0 "$(calls_of 'reap')"

# --- D7: reclaim, THEN measure, THEN decide ---------------------------------
# 95% before the sweep, 60% after: a cut that measured first refuses this box.

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=60 capture reset --cut alpha
t reset-cut-reaper-brings-box-under-threshold 0 "$RC"
t reset-cut-reclaims-before-measuring $'reap alpha\nroot-df alpha' \
  "$(grep -E '^(reap|root-df) alpha$' "$STATE/calls")"
t reset-cut-takes-the-snapshot 1 "$(calls_of 'snapshot alpha armed')"
case "$OUT" in *'reclaiming before measuring'*'reaper: transcripts reclaimed 12345 bytes'*) r1=forwarded ;; *) r1="$OUT" ;; esac
t reset-cut-forwards-the-sweep-evidence forwarded "$r1"
case "$OUT" in *"alpha: armed cut at crew@$BOX_STAMP_VERSION; root filesystem 60% used"*) r1=reported ;; *) r1="$OUT" ;; esac
t reset-cut-reports-the-post-reclaim-figure reported "$r1"

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=95 capture reset --cut alpha
t reset-cut-refuses-a-box-still-fat 1 "$RC"
case "$OUT" in *'alpha: REFUSED — root filesystem 95% used after reclaiming, over the 80% ceiling'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-cut-over-threshold-is-refused refused "$r1"
# D7 step 3: the COMPOSITION, not only the percentage.
case "$OUT" in *'largest: 13G /swapfile;13G /swapfile-drill;19G /var;6.9G /home'*) r1=composed ;; *) r1="$OUT" ;; esac
t reset-cut-refusal-names-what-is-large composed "$r1"
t reset-cut-over-threshold-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=95 RST_LARGE="" capture reset --cut alpha
case "$OUT" in *'largest: unavailable'*) r1=honest ;; *) r1="$OUT" ;; esac
t reset-cut-unreadable-composition-is-honest honest "$r1"

reset_case
RST_REAP_FAIL=alpha capture reset --cut alpha
t reset-cut-refuses-when-the-sweep-cannot-run 1 "$RC"
case "$OUT" in *'REFUSED — the on-demand reaper did not complete'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unswept-box-is-named named "$r1"
t reset-cut-unswept-box-is-never-measured 0 "$(calls_of 'root-df')"
t reset-cut-unswept-box-cuts-nothing 0 "$(calls_of 'snapshot')"

# THE REFUSAL NAMES THE CAUSE IT ACTUALLY HAD. reap-now.sh documents three
# exits and this asserted the first for all of them. 127 is not a corner: it
# is every box still on a pre-#589 engine, which is the whole fleet on the
# first fleet-wide `--cut` anybody runs — and telling that operator a duty
# tick holds a lock sends them to look at the wrong thing entirely.
reset_case
RST_REAP_FAIL=alpha RST_REAP_RC=199 capture reset --cut alpha
case "$OUT" in *'a duty tick took the duty lock between the drain probe and now'*) r1=lock ;; *) r1="$OUT" ;; esac
t reset-cut-reaper-199-is-named-as-the-lock lock "$r1"

reset_case
RST_REAP_FAIL=alpha RST_REAP_RC=127 capture reset --cut alpha
t reset-cut-reaper-127-is-refused 1 "$RC"
case "$OUT" in *'this box has no reap-now.sh — its engine predates it'*'crew upgrade alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-reaper-127-names-the-missing-script named "$r1"
case "$OUT" in *'duty tick'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-reaper-127-does-not-blame-the-lock quiet "$r1"
t reset-cut-reaper-127-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_REAP_FAIL=alpha RST_REAP_RC=1 capture reset --cut alpha
case "$OUT" in *'(it exited 1)'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-reaper-other-status-is-reported-as-itself named "$r1"
case "$OUT" in *'duty tick'*|*'no reap-now.sh'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-reaper-other-status-claims-neither-named-cause quiet "$r1"

# --- D5: the cut records its version; a re-cut replaces the label -----------

reset_case
capture reset --cut alpha
t reset-cut-records-the-version "CHECKPOINT_VERSION=$BOX_STAMP_VERSION" \
  "$(grep '^CHECKPOINT_VERSION=' "$CONF/checkpoints/alpha.conf")"
t reset-cut-records-no-stale-mark 'CHECKPOINT_STALE=' \
  "$(grep '^CHECKPOINT_STALE=' "$CONF/checkpoints/alpha.conf")"

# The write that cannot land. `armed` IS on the box by then — the snapshot is
# taken before the record is written — so this is the state D4 and D5 argue
# about most: a label with no record. The FAILED line has to be crew's own and
# nothing else's, and the temporary must not survive, matching
# checkpoint_mark_stale, whose two arms already clean up after themselves.
#
# The directory is created and THEN made read-only, so `mkdir -p` succeeds and
# the failure is the write itself. Made read-only after creation and not by
# locking `$CONF`, which would have failed one line earlier at the mkdir and
# tested a different arm.
reset_case
mkdir -p "$CONF/checkpoints"
chmod 500 "$CONF/checkpoints"
capture reset --cut alpha
chmod u+w "$CONF/checkpoints"
t reset-cut-unrecordable-version-fails 1 "$RC"
case "$OUT" in *'was cut but its version could not be recorded'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unrecordable-version-is-named named "$r1"
# The shell's own diagnostic never appears above crew's line: the redirection
# failure is swallowed the way its sibling's is.
case "$OUT" in *'bash:'*|*'Permission denied'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-unrecordable-version-prints-no-raw-shell-error quiet "$r1"
# And no litter. Nothing READS a stray `<box>.conf.tmp.<pid>` — only
# `<box>.conf` is ever read — so this is the two halves of one store answering
# a failed write the same way, not a correctness claim.
t reset-cut-unrecordable-version-leaves-no-temp 0 \
  "$(find "$CONF" -name 'alpha.conf.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
#
# THE `rm -f` HALF OF THAT CLEANUP HAS NO FIXTURE, AND THAT IS REPORTED
# RATHER THAN PAPERED OVER. A redirection that fails in a read-only directory
# creates nothing to strand, so this case exercises the message and not the
# cleanup; only the `mv` arm could leave a temporary, and `mv file dir`
# SUCCEEDS by moving into it rather than failing, so this harness cannot
# reach it either. The cleanup stays because its sibling
# `checkpoint_mark_stale` has it on both arms and one store answering a failed
# write two ways is the drift worth avoiding — not because it is tested.

reset_case
arm alpha
capture reset --cut alpha
t reset-recut-succeeds 0 "$RC"
t reset-recut-deletes-the-old-label-first 1 "$(calls_of 'incus alpha snapshot delete')"
t reset-recut-leaves-exactly-one-armed 1 "$(grep -cx armed "$STATE/snaps-alpha")"

reset_case
arm alpha
RST_SNAPDEL_FAIL=alpha capture reset --cut alpha
t reset-recut-refuses-when-the-old-label-survives 1 "$RC"
case "$OUT" in *'could not replace the existing armed checkpoint; it is unchanged'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-recut-failure-is-named named "$r1"

# The cut fails with a previous label already deleted: the box really does
# have no checkpoint, and the message says so.
reset_case
arm alpha
RST_SNAPSHOT_FAIL=alpha capture reset --cut alpha
t reset-cut-snapshot-failure-is-loud 1 "$RC"
case "$OUT" in *'previous one was already removed'*'this box now has NO checkpoint'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-snapshot-failure-names-the-repair named "$r1"

# The same failure with NOTHING deleted must not claim the box lost a
# checkpoint it never had: a false alarm sends an operator to repair a box
# that is fine, and the reverse is worse.
reset_case
RST_SNAPSHOT_FAIL=alpha capture reset --cut alpha
t reset-cut-first-snapshot-failure-is-a-failure 1 "$RC"
case "$OUT" in *"checkpoint state is unchanged"*) r1=accurate ;; *) r1="$OUT" ;; esac
t reset-cut-first-snapshot-failure-claims-no-loss accurate "$r1"
case "$OUT" in *'now has NO checkpoint'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-first-snapshot-failure-raises-no-false-alarm quiet "$r1"

# An unreadable listing is not "no label to replace": the cut refuses rather
# than deleting nothing and then failing on an armed that was perfectly good.
reset_case
arm alpha
RST_INFO_BROKEN=alpha capture reset --cut alpha
t reset-cut-unreadable-listing-refuses 1 "$RC"
case "$OUT" in *'cannot tell whether armed is there to replace'*'nothing cut and nothing removed'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unreadable-listing-is-named named "$r1"
t reset-cut-unreadable-listing-cuts-nothing 0 "$(calls_of 'snapshot')"
t reset-cut-unreadable-listing-removes-nothing 0 "$(calls_of 'incus')"

# --- D4: box info is the only thing that knows a label exists ---------------

reset_case
capture reset alpha
t reset-refuses-a-box-with-no-checkpoint 1 "$RC"
case "$OUT" in *'alpha: REFUSED — no armed checkpoint'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-missing-checkpoint-is-named named "$r1"
# It is a FAILURE, never a skip: a box the reset cannot perform must not be
# counted beside the ones a live duty lock legitimately deferred.
case "$OUT" in *'reset: 0 restored, 0 skipped-busy, 1 failed'*'failed: alpha'*) r1=failed ;; *) r1="$OUT" ;; esac
t reset-missing-checkpoint-is-not-skipped failed "$r1"
# The refusal that matters: it does NOT fall back to another label.
t reset-missing-checkpoint-restores-nothing 0 "$(calls_of 'restore')"

reset_case
printf 'bootstrapped\npristine\n' >"$STATE/snaps-alpha"
capture reset alpha
t reset-does-not-fall-back-to-bootstrapped 1 "$RC"
t reset-does-not-restore-any-other-label 0 "$(calls_of 'restore')"
case "$OUT" in *'it is NOT rolled back to any other label'*) r1=explicit ;; *) r1="$OUT" ;; esac
t reset-other-labels-refusal-is-explicit explicit "$r1"

reset_case
arm alpha
RST_INFO_BROKEN=alpha capture reset alpha
t reset-refuses-an-unreadable-listing 1 "$RC"
case "$OUT" in *'could not read its snapshot labels'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-unreadable-listing-is-named named "$r1"
t reset-unreadable-listing-restores-nothing 0 "$(calls_of 'restore')"

# --- D3: the green path — restore and start ---------------------------------

reset_case
arm alpha
capture reset --cut alpha
reset_case_calls="$STATE/calls"
: >"$reset_case_calls"
capture reset alpha
t reset-restores-and-starts 0 "$RC"
t reset-stops-before-restoring $'down alpha\nrestore alpha armed --force\nstart alpha' \
  "$(grep -E '^(down|restore|start) alpha' "$STATE/calls")"
# The store half (#761): drained before the disk goes back, memory written
# back onto the restored disk before the first tick.
t reset-drains-before-stopping "drain alpha|down alpha" \
  "$(grep -E '^(drain|down) alpha' "$STATE/calls" | paste -sd'|' -)"
t reset-writes-the-memory-back-after-the-start 1 \
  "$(awk '/^start alpha/{s=NR} /^memory alpha .memory-restore.tar/{m=NR} END{print (s && m && m>s) ? 1 : 0}' "$STATE/calls")"
t reset-unpacks-the-memory-under-the-duty-lock 1 \
  "$(awk '/^memory alpha .memory-restore.tar/{m=NR} /^memory-unpack alpha/{u=NR} END{print (m && u && u>m) ? 1 : 0}' "$STATE/calls")"
case "$OUT" in *"alpha: memory restored from the store"*) r1=reported ;; *) r1="$OUT" ;; esac
t reset-memory-restore-is-reported reported "$r1"
case "$OUT" in *"alpha: restored to armed (crew@$BOX_STAMP_VERSION) and started"*) r1=reported ;; *) r1="$OUT" ;; esac
t reset-restore-is-reported reported "$r1"
# The memory's return lifts `.memory-pending` in the same locked step that
# unpacks it, and a reset that cannot read the store is a FAILURE (#763
# re-review) — not "no memory", which is a store that holds nothing for the
# box and lifts the marker so its ticks run.
t reset-the-unpack-lifts-the-marker-in-the-locked-step 1 \
  "$(grep -c 'flock .duty.lock -c "tar -xf .memory-restore.tar && rm -f .memory-restore.tar .memory-pending"' "$CLI")"
reset_case
arm alpha
printf 'stopped\n' >"$STATE/state-alpha"
: >"$STATE/calls"
CREW_FLOOR_STORE="$STATE/absent/fleet.sqlite" capture reset alpha
t reset-a-store-that-cannot-be-read-is-a-failure 1 "$RC"
case "$OUT" in *'alpha: memory restore FAILED — the store could not be read'*) r1=said ;; *) r1="$OUT" ;; esac
t reset-the-unreadable-store-is-said said "$r1"
case "$OUT" in *'alpha: FAILED — restored to armed and started, but its memory did not come back from the store'*) r1=said ;; *) r1="$OUT" ;; esac
t reset-the-failed-memory-fails-the-restore said "$r1"
case "$OUT" in *'reset: 0 restored, 0 skipped-busy, 1 failed'*) r1=counted ;; *) r1="$OUT" ;; esac
t reset-the-failed-memory-is-counted counted "$r1"
CREW_CONFIG_DIR="$CONF" CREW_FLOOR_STORE="$STATE/fresh.sqlite" python3 "$ROOT/fleet-floor/server/floor/store.py" init >/dev/null
printf 'stopped\n' >"$STATE/state-alpha"
: >"$STATE/calls"
CREW_FLOOR_STORE="$STATE/fresh.sqlite" capture reset alpha
t reset-a-store-with-no-memory-for-the-box-is-not-a-failure 0 "$RC"
case "$OUT" in *'alpha: the store holds no memory file to restore (first reset, or never drained)'*) r1=said ;; *) r1="$OUT" ;; esac
t reset-no-memory-is-said-as-that said "$r1"
t reset-no-memory-lifts-the-marker-so-the-box-ticks 1 "$(calls_of 'pending-off alpha')"
# The checkpoint carries the marker: set before the snapshot, lifted after it.
reset_case
arm alpha
: >"$STATE/calls"
capture reset --cut alpha
t cut-sets-memory-pending-before-the-snapshot 1 \
  "$(awk '/^pending-on alpha/{p=NR} /^snapshot alpha armed/{s=NR} END{print (p && s && p<s) ? 1 : 0}' "$STATE/calls")"
t cut-lifts-memory-pending-from-the-live-box-after-it 1 \
  "$(awk '/^snapshot alpha armed/{s=NR} /^pending-off alpha/{o=NR} END{print (s && o && o>s) ? 1 : 0}' "$STATE/calls")"
# THE PAUSE AND THE CAP ARE KEPT (#763 re-review). Under --all a paused box
# is left alone, as the daily restart leaves it; by name it is restored, its
# memory written back, its crontab paused again and stopped. A box restored
# while the cap is full goes back down for the host tick to start.
reset_case
arm alpha "$BOX_STAMP_VERSION"
arm beta "$BOX_STAMP_VERSION"
mkdir -p "$CONF/store/paused"; : >"$CONF/store/paused/alpha"
: >"$STATE/calls"
capture reset --all
case "$OUT" in *'alpha: paused — left alone'*) r1=left ;; *) r1="$OUT" ;; esac
t reset-all-leaves-a-paused-box-alone left "$r1"
t reset-all-restores-nothing-for-a-paused-box 0 "$(calls_of 'restore alpha')"
t reset-all-still-restores-the-others 1 "$(calls_of 'restore beta armed')"
: >"$STATE/calls"
capture reset alpha
t reset-by-name-restores-a-paused-box 1 "$(calls_of 'restore alpha armed')"
t reset-by-name-stops-a-paused-box-again-after-its-memory 1 \
  "$(awk '/^memory-unpack alpha/{m=NR} /^down alpha/{if(m && NR>m)d=NR} END{print (m && d) ? 1 : 0}' "$STATE/calls")"
case "$OUT" in *"alpha: restored to armed (crew@$BOX_STAMP_VERSION), its memory written back, and stopped again — it is paused"*) r1=said ;; *) r1="$OUT" ;; esac
t reset-the-paused-stop-is-said said "$r1"
rm -f "$CONF/store/paused/alpha"
reset_case
arm alpha "$BOX_STAMP_VERSION"
arm beta "$BOX_STAMP_VERSION"
printf 'FLEET_MAX_RUNNING=1\n' >>"$CONF/fleet.conf"
printf 'running\n' >"$STATE/state-beta"
: >"$STATE/calls"
capture reset alpha
t reset-a-box-past-the-cap-goes-back-down-after-its-memory 1 \
  "$(awk '/^memory-unpack alpha/{m=NR} /^down alpha/{if(m && NR>m)d=NR} END{print (m && d) ? 1 : 0}' "$STATE/calls")"
case "$OUT" in *"alpha: restored to armed (crew@$BOX_STAMP_VERSION), its memory written back, and stopped again — 1 of 1 boxes running; the host tick starts it when there is work"*) r1=said ;; *) r1="$OUT" ;; esac
t reset-the-cap-stop-is-said said "$r1"
t reset-the-cap-stop-is-not-a-failure 0 "$RC"
sed -i '/^FLEET_MAX_RUNNING=1$/d' "$CONF/fleet.conf"

reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
RST_STOP_NOT_TAKE=alpha capture reset alpha
t reset-stop-not-taken-is-failure 1 "$RC"
t reset-stop-not-taken-never-restores 0 "$(calls_of 'restore')"
case "$OUT" in *'stop did not take'*'NOT restoring'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-stop-not-taken-is-named named "$r1"

# --- D5: the engine-version interlock ---------------------------------------
# The recorded version and the live one disagree, by any route.

reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
RST_STAMP_alpha=0.1.4 capture reset alpha
t reset-refuses-a-version-mismatch 1 "$RC"
case "$OUT" in *"cut at crew@$BOX_STAMP_VERSION and the box now runs crew@0.1.4"*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-version-mismatch-names-both-and-the-repair named "$r1"
t reset-version-mismatch-restores-nothing 0 "$(calls_of 'restore')"

# `crew upgrade` marks the checkpoint stale IN THE SAME WRITE, and the reset
# immediately afterwards is refused by that recorded fact.
reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
capture upgrade alpha
t reset-upgrade-succeeds 0 "$RC"
case "$OUT" in *"alpha's armed checkpoint is now STALE"*'crew reset --cut alpha'*) r1=announced ;; *) r1="$OUT" ;; esac
t reset-upgrade-announces-the-stale-mark announced "$r1"
t reset-upgrade-writes-the-stale-mark 1 \
  "$(grep -c '^CHECKPOINT_STALE=[0-9]' "$CONF/checkpoints/alpha.conf")"
: >"$STATE/calls"
capture reset alpha
t reset-after-upgrade-is-refused 1 "$RC"
case "$OUT" in *"was cut at crew@$BOX_STAMP_VERSION and the box was upgraded to crew@"*'silently downgrade the engine'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-stale-checkpoint-names-both-versions named "$r1"
t reset-stale-checkpoint-restores-nothing 0 "$(calls_of 'restore')"
# A re-cut clears the mark and the reset then proceeds.
: >"$STATE/calls"
capture reset --cut alpha
t reset-recut-clears-the-stale-mark 'CHECKPOINT_STALE=' \
  "$(grep '^CHECKPOINT_STALE=' "$CONF/checkpoints/alpha.conf")"
: >"$STATE/calls"
capture reset alpha
t reset-after-recut-proceeds 0 "$RC"
t reset-after-recut-restores 1 "$(calls_of 'restore alpha armed')"

# An upgrade of a box with NO checkpoint invents no record to invalidate.
reset_case
capture upgrade alpha
t reset-upgrade-without-a-checkpoint-writes-nothing absent \
  "$([ -f "$CONF/checkpoints/alpha.conf" ] && echo present || echo absent)"

# --- D5: AN UNKNOWN VERSION IS NOT A MATCHING ONE ---------------------------
#
# The label is guest-side and the record is host-side, so an `armed` snapshot
# with no readable record is a reachable state, not a hypothetical: `--cut`'s
# own checkpoint_record failing after `box snapshot` landed leaves exactly
# this behind (and says so), as do a re-pointed CREW_CONFIG_DIR and a host
# config restored from a backup predating the cut. Restoring it cannot be
# proved not to downgrade the engine, which is the whole of D5's hazard.

# NO LIVE STAMP EITHER, and that is the point of this first case rather than
# an incidental. With a readable live version the mismatch arm below would
# also catch an empty recorded one, so a fixture written that way passes with
# this refusal deleted — it would be pinning the wrong guard. Here nothing but
# the record could answer the question, which is the state the old code
# restored at `crew@unknown`.
reset_case
arm_label_only alpha
RST_STAMP_alpha="" capture reset alpha
t reset-armed-without-a-record-is-refused 1 "$RC"
case "$OUT" in *'records no engine version'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-recordless-checkpoint-names-the-repair named "$r1"
t reset-recordless-checkpoint-restores-nothing 0 "$(calls_of 'restore')"
t reset-recordless-checkpoint-stops-nothing 0 "$(calls_of 'down')"
case "$OUT" in *'restored to armed'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-recordless-checkpoint-never-reports-a-restore quiet "$r1"

# The same absence WITH a readable live version: the recordless refusal is the
# one that fires, ahead of the mismatch arm, so the operator is told the
# record is missing rather than shown a version pair with one side blank.
reset_case
arm_label_only alpha
capture reset alpha
t reset-recordless-with-a-live-stamp-is-refused 1 "$RC"
case "$OUT" in *'records no engine version'*) r1=recordless ;; *) r1="$OUT" ;; esac
t reset-recordless-refusal-outranks-the-mismatch-arm recordless "$r1"

# The same box after an upgrade. This is the transcript that must never read
# `restored to armed (crew@unknown)` again: cmd_upgrade writes no mark on a
# box with no record — correctly, there is nothing to invalidate — so the
# record is not where the refusal can come from, and the reset must refuse on
# the absence itself.
reset_case
arm_label_only alpha
capture upgrade alpha
t reset-recordless-upgrade-succeeds 0 "$RC"
case "$OUT" in *'checkpoint is now STALE'*|*'could NOT be marked stale'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-recordless-upgrade-invents-no-record quiet "$r1"
: >"$STATE/calls"
RST_STAMP_alpha=0.9.9 capture reset alpha
t reset-after-upgrade-of-a-recordless-box-is-refused 1 "$RC"
# The transcript this must never print again is `restored to armed
# (crew@unknown) and started` at RC 0.
case "$OUT" in *'restored to armed'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-recordless-box-after-upgrade-never-reports-a-restore quiet "$r1"
t reset-recordless-box-after-upgrade-restores-nothing 0 "$(calls_of 'restore')"

# A record that exists but carries no version — MALFORMED. The comment here
# used to say "unreadable and malformed land in the same place" while testing
# only this one, which is the gap the round-3 review named: a readable file
# with no key is not a failed read, and only the failed read exercises what
# `sed` does when it cannot open the file at all. Both are now driven, this
# one first.
reset_case
arm_label_only alpha
mkdir -p "$CONF/checkpoints"
printf 'CHECKPOINT_STALE=\n' >"$CONF/checkpoints/alpha.conf"
capture reset alpha
t reset-malformed-record-is-refused 1 "$RC"
t reset-malformed-record-restores-nothing 0 "$(calls_of 'restore')"

# --- AND THE RECORD THAT GENUINELY CANNOT BE READ ---------------------------
#
# Mode 000, holding a PERFECTLY GOOD version: the only thing wrong with it is
# that `sed` cannot open it. The distinction from the malformed case above is
# the whole point — a readable file with no key exercises the parse, this one
# exercises the failure of the read, and they were one fixture pretending to
# be two.
#
# What must hold is what holds for every other unreadable thing in this verb:
# the named per-box refusal, the fleet summary underneath it, nothing
# restored, and — on the fleet paths — the OTHER boxes carried through. A
# failed read must not be able to take a fleet verb down between one box and
# the next.
#
# Mode 000 means nothing to uid 0, and these are deliberately NOT guarded on
# it: under a root runner the file reads fine, the box restores, and the first
# assertion goes red — loudly, and not vacuously green. That is the same
# answer the suite's existing permission fixtures give (the `chmod 500`
# unwritable-mark cases above), so this adds no new convention: this suite
# wants a non-root runner and says so by failing rather than by skipping.
reset_case
arm alpha
chmod 000 "$CONF/checkpoints/alpha.conf"
capture reset alpha
chmod 600 "$CONF/checkpoints/alpha.conf"
t reset-unreadable-record-is-refused 1 "$RC"
case "$OUT" in *'records no engine version'*'missing, unreadable or malformed'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-is-named named "$r1"
t reset-unreadable-record-restores-nothing 0 "$(calls_of 'restore')"
t reset-unreadable-record-stops-nothing 0 "$(calls_of 'down')"
case "$OUT" in *'restored to armed'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-unreadable-record-never-reports-a-restore quiet "$r1"
# THE SUMMARY IS REACHED. A read that aborted the command instead of
# answering would take this line with it, and the operator would be left
# with a verb that stopped rather than a box that refused.
case "$OUT" in *'reset: 0 restored, 0 skipped-busy, 1 failed'*'failed: alpha'*) r1=summarised ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-still-reaches-the-summary summarised "$r1"

# The fleet path: alpha refuses, beta restores, both are counted.
reset_case
arm alpha
arm beta "$BOX_STAMP_VERSION"
chmod 000 "$CONF/checkpoints/alpha.conf"
capture reset --all
chmod 600 "$CONF/checkpoints/alpha.conf"
t reset-all-unreadable-record-is-a-failure 1 "$RC"
case "$OUT" in *"beta: restored to armed (crew@$BOX_STAMP_VERSION) and started"*) r1=restored ;; *) r1="$OUT" ;; esac
t reset-all-unreadable-record-does-not-take-the-loop-down restored "$r1"
t reset-all-unreadable-record-restores-exactly-the-other-box 1 "$(calls_of 'restore beta armed')"
t reset-all-unreadable-record-restores-nothing-for-its-own-box 0 "$(calls_of 'restore alpha')"
case "$OUT" in *'reset: 1 restored, 0 skipped-busy, 1 failed'*) r1=counted ;; *) r1="$OUT" ;; esac
t reset-all-unreadable-record-is-counted counted "$r1"

# The pre-install gate reads the same field. Here the refusal comes from
# checkpoint_mark_stale, one line further on — the field read is what runs
# FIRST, so an abort there would beat the refusal to it.
reset_case
arm alpha
chmod 000 "$CONF/checkpoints/alpha.conf"
capture upgrade alpha
chmod 600 "$CONF/checkpoints/alpha.conf"
case "$OUT" in *'could NOT be marked stale'*'Nothing was staged and nothing was installed'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-refuses-the-upgrade refused "$r1"
t reset-unreadable-record-upgrade-installs-nothing 0 "$(calls_of 'install alpha')"
case "$OUT" in *'checkpoint is now STALE'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-unreadable-record-upgrade-claims-nothing quiet "$r1"

# And the loop the review asked to see pinned: `upgrade --all` refuses the
# box it cannot read and installs on the next one.
reset_case
arm alpha
arm beta
chmod 000 "$CONF/checkpoints/alpha.conf"
capture upgrade --all
chmod 600 "$CONF/checkpoints/alpha.conf"
case "$OUT" in *'upgrade REFUSED on alpha'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-upgrade-all-refuses-its-own-box refused "$r1"
t reset-unreadable-record-upgrade-all-installs-nothing-for-it 0 "$(calls_of 'install alpha')"
t reset-unreadable-record-upgrade-all-lets-the-next-box-through 1 "$(calls_of 'install beta')"
case "$OUT" in *"beta's armed checkpoint is now STALE"*) r1=marked ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-upgrade-all-marks-the-next-box marked "$r1"

# NONEMPTY IS NOT THE SAME QUESTION AS COMPARABLE, and `unknown` is the value
# that proves it: a `--cut` used to write that string itself out of a stamp it
# could not parse. Emptiness was all the restore checked, so the record read as
# present and the transcript `restored to armed (crew@unknown) and started`
# came back at exit 0. Driven with NO live stamp, which is the state a stopped
# box is in by construction — it is the only state where nothing else can
# catch it.
for bad in unknown 1a2b3c4d 0.1 'crew@0.1.3'; do
  reset_case
  arm alpha "$bad"
  RST_STAMP_alpha="" capture reset alpha
  label="$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')"
  t "reset-nonversion-record-$label-is-refused" 1 "$RC"
  t "reset-nonversion-record-$label-restores-nothing" 0 "$(calls_of 'restore')"
  case "$OUT" in *"records '$bad'"*'is not an engine version'*) r1=named ;; *) r1="$OUT" ;; esac
  t "reset-nonversion-record-$label-is-named" named "$r1"
  case "$OUT" in *'restored to armed'*) r1="$OUT" ;; *) r1=quiet ;; esac
  t "reset-nonversion-record-$label-never-reports-a-restore" quiet "$r1"
done

# And the shapes that ARE versions still restore, so the guard is a version
# test and not a "looks like 0.1.3" test.
for good in 0.1.3 0.1.3-dev 12.0.4-rc.1; do
  reset_case
  arm alpha "$good"
  RST_STAMP_alpha="" capture reset alpha
  t "reset-version-record-$good-restores" 0 "$RC"
done

# --- checkpoint_field's contract, driven where nothing suppresses it --------
#
# THE CASES ABOVE CANNOT KILL THIS ONE, AND THAT IS WHY IT EXISTS. `crew`
# runs under `set -euo pipefail`, and checkpoint_field used to end on a bare
# pipeline: an unreadable record made it exit 2 through pipefail, a duplicate
# key would make it exit 141 through head's SIGPIPE. Whether that aborts the
# command or is inert depends entirely on the CALLER — bash suppresses errexit
# for the whole dynamic extent of a function invoked in a condition or an
# `&&`/`||` list, and all three call sites are exactly that:
#
#   hire_box       checkpoint_stale_gate "$name" "$want" || return 1
#   cmd_upgrade    if ! checkpoint_stale_gate "$b" "$want"; then
#   cmd_reset      if restore_box "$name"; then
#
# So the mode-000 fixtures above pass with the fix reverted. They pin
# behaviour that must not regress; they cannot pin the fix. What they cannot
# reach is a call site written as a plain statement — the natural shape, and
# the one that would abort a fleet verb between two boxes — so the helper is
# taken out of production and run where errexit is live.
#
# Extracted, not copied. This suite family's idiom (boot-gate.sh's gate block,
# common.sh's cleanup_all), and it fails closed the same way: if cli/crew ever
# stops carrying the function under this name the extraction goes empty and
# the case below reds, rather than quietly testing a fixture's own copy of
# code that has moved on.
CPF_SRC="$TMP/checkpoint-field.sh"
awk '/^checkpoint_field\(\) \{/,/^\}$/' "$CLI" >"$CPF_SRC"
t reset-checkpoint-field-extracted-from-the-real-file 1 \
  "$(grep -c '^checkpoint_field() {' "$CPF_SRC")"
CPF_DRIVER="$TMP/checkpoint-field-driver.sh"
cat >"$CPF_DRIVER" <<'CPFEOF'
#!/usr/bin/env bash
# The production shell options, and NO suppressing context: the helper is
# called from a plain assignment, which is what every future call site is one
# refactor away from being.
set -euo pipefail
CONFIG_DIR="$1"
checkpoint_dir() { printf '%s\n' "$CONFIG_DIR/checkpoints"; }
checkpoint_file() { printf '%s\n' "$(checkpoint_dir)/$1.conf"; }
source "$2"
v="$(checkpoint_field CHECKPOINT_VERSION alpha)"
printf 'REACHED [%s]\n' "$v"
CPFEOF
reset_case
arm alpha
chmod 000 "$CONF/checkpoints/alpha.conf"
CPF_OUT="$(bash "$CPF_DRIVER" "$CONF" "$CPF_SRC" 2>/dev/null)" && CPF_RC=0 || CPF_RC=$?
chmod 600 "$CONF/checkpoints/alpha.conf"
# The statement AFTER the assignment runs. Reverting the fix stops here at
# rc 2 with no output at all, which is the failure the review reproduced.
t reset-checkpoint-field-unreadable-does-not-abort-its-caller 0 "$CPF_RC"
t reset-checkpoint-field-unreadable-answers-empty 'REACHED []' "$CPF_OUT"

# A readable record still answers, so the absorption did not turn the helper
# into one that says nothing.
reset_case
arm alpha
CPF_OUT="$(bash "$CPF_DRIVER" "$CONF" "$CPF_SRC" 2>/dev/null)" && CPF_RC=0 || CPF_RC=$?
t reset-checkpoint-field-readable-still-answers "REACHED [$CHECKPOINT_VERSION]" "$CPF_OUT"
t reset-checkpoint-field-readable-does-not-abort 0 "$CPF_RC"

# A missing record: the `[ -f ]` arm, which always returned 0 and still must.
reset_case
CPF_OUT="$(bash "$CPF_DRIVER" "$CONF" "$CPF_SRC" 2>/dev/null)" && CPF_RC=0 || CPF_RC=$?
t reset-checkpoint-field-missing-answers-empty 'REACHED []' "$CPF_OUT"
t reset-checkpoint-field-missing-does-not-abort 0 "$CPF_RC"

# A record carrying the key TWICE — and this case earned its place: it FAILED
# against the first version of the fix, which kept `head -1` and absorbed the
# pipeline's status. `head` closes the pipe after the first line, sed takes
# SIGPIPE, pipefail promotes 141, and absorbing that answered EMPTY for a
# readable record with a perfectly good version in it — turning an abort into
# a false refusal, which is not an improvement. The pipe is gone instead. 2000
# trailing lines so the race is not a coin toss.
reset_case
arm alpha
{ printf 'CHECKPOINT_VERSION=%s\n' "$CHECKPOINT_VERSION"; for _ in $(seq 1 2000); do printf 'CHECKPOINT_VERSION=9.9.9\n'; done; } \
  >"$CONF/checkpoints/alpha.conf"
CPF_OUT="$(bash "$CPF_DRIVER" "$CONF" "$CPF_SRC" 2>/dev/null)" && CPF_RC=0 || CPF_RC=$?
t reset-checkpoint-field-duplicate-key-does-not-abort 0 "$CPF_RC"
t reset-checkpoint-field-duplicate-key-takes-the-first "REACHED [$CHECKPOINT_VERSION]" "$CPF_OUT"

# --- D5: THE STALE MARK IS A PRECONDITION TO MOVING THE ENGINE --------------
#
# Round 2 found the mark was written AFTER the install, by ONE of the three
# routes that install an engine. Both halves were wrong, and both are pinned
# here.
#
# The write side first. This is the state the old fixture could not reach: a
# record carrying a VALID version, and a mark that genuinely cannot be
# written. The directory is read-only, so the rewrite's temporary cannot be
# created — the record itself is untouched and perfectly readable, which is
# precisely why nothing downstream would have noticed. Marking afterwards left
# the box running a new engine and its checkpoint claiming the old one is
# current; marking first refuses the install instead, so the two stay in
# agreement and nothing drifts.
reset_case
arm alpha "$BOX_STAMP_VERSION"
chmod 500 "$CONF/checkpoints"
capture upgrade alpha
chmod u+w "$CONF/checkpoints"
t reset-unwritable-stale-mark-does-not-take-the-command-down 0 "$RC"
case "$OUT" in *'could NOT be marked stale'*'Nothing was staged and nothing was installed'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-unwritable-stale-mark-is-named refused "$r1"
case "$OUT" in *'upgrade REFUSED on alpha — its engine is unchanged'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-unwritable-stale-mark-says-the-engine-is-unchanged named "$r1"
case "$OUT" in *'checkpoint is now STALE'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-unwritable-stale-mark-claims-nothing quiet "$r1"
# NOTHING WAS INSTALLED. The whole value of a precondition is that the thing
# it guards did not happen.
t reset-unwritable-stale-mark-installs-nothing 0 "$(calls_of 'install alpha')"
t reset-unwritable-stale-mark-leaves-the-record-intact \
  "$(printf 'CHECKPOINT_VERSION=%s\nCHECKPOINT_STALE=' "$BOX_STAMP_VERSION")" \
  "$(grep -E '^CHECKPOINT_(VERSION|STALE)=' "$CONF/checkpoints/alpha.conf")"
# And the box is still restorable, correctly: its engine never moved.
: >"$STATE/calls"
capture reset alpha
t reset-after-a-refused-upgrade-still-restores 0 "$RC"
t reset-after-a-refused-upgrade-restores-once 1 "$(calls_of 'restore alpha armed')"

# One box refusing must not take the loop down: `crew upgrade --all` is what
# maintenance runs, and a fleet stopping at its first broken config directory
# is the shape #37 and the reaper's own _reaper_whole both exist to avoid.
reset_case
arm_label_only alpha
mkdir -p "$CONF/checkpoints"
printf 'CHECKPOINT_STALE=\n' >"$CONF/checkpoints/alpha.conf"
arm beta
capture upgrade --all
case "$OUT" in *'upgrade REFUSED on alpha'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-unwritable-stale-mark-refuses-only-its-own-box refused "$r1"
case "$OUT" in *'upgrade REFUSED on beta'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-unwritable-stale-mark-does-not-take-the-loop-down quiet "$r1"
t reset-unwritable-stale-mark-lets-the-next-box-through 1 "$(calls_of 'install beta')"

# The read arm of the same failure — a record with nothing for `grep -v` to
# select — lands in the same place. Two failure modes, one contract.
reset_case
arm_label_only alpha
mkdir -p "$CONF/checkpoints"
printf 'CHECKPOINT_STALE=\n' >"$CONF/checkpoints/alpha.conf"
capture upgrade alpha
case "$OUT" in *'could NOT be marked stale'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-unreadable-record-also-refuses-the-upgrade refused "$r1"
t reset-unreadable-record-installs-nothing 0 "$(calls_of 'install alpha')"

# THE CHOSEN RESIDUAL: the mark lands and the install then fails. The
# checkpoint now reads stale for a move that did not happen, so a reset
# refuses this box. That is a FALSE refusal and it is the direction to fail
# in — the other direction is a silent engine downgrade with nothing red
# anywhere — so it is said at the failure rather than met weeks later.
reset_case
arm alpha
RST_INSTALL_FAIL=alpha capture upgrade alpha
case "$OUT" in *'upgrade FAILED on alpha'*'stays marked'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-failed-install-names-the-stale-mark-it-left named "$r1"
: >"$STATE/calls"
capture reset alpha
t reset-after-a-failed-install-is-refused 1 "$RC"
t reset-after-a-failed-install-restores-nothing 0 "$(calls_of 'restore')"

# --- D5: EVERY ROUTE THAT INSTALLS AN ENGINE MARKS THE CHECKPOINT -----------
#
# `checkpoint_mark_stale` had one caller, `cmd_upgrade`. But `hire_box`
# installs whenever the version does not match, unconditionally on a `-dev`
# tree, and on --force; `cmd_up` calls `hire_box` for every roster box. So a
# routine `crew up` moved the engine past the checkpoint and marked nothing,
# and the only thing left holding D5 was restore_box's LIVE comparison — read
# through `box exec`, which a stopped box cannot answer at all.
reset_case
arm alpha
capture hire alpha
t reset-hire-succeeds 0 "$RC"
case "$OUT" in *"alpha's armed checkpoint is now STALE"*'engine moving to crew@'*) r1=marked ;; *) r1="$OUT" ;; esac
t reset-hire-marks-the-checkpoint-stale marked "$r1"
: >"$STATE/calls"
capture reset alpha
t reset-after-a-hire-is-refused 1 "$RC"
case "$OUT" in *'REFUSED'*'restoring it would silently downgrade the engine'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-after-a-hire-names-the-downgrade named "$r1"
t reset-after-a-hire-restores-nothing 0 "$(calls_of 'restore')"

# THE STOPPED VARIANT — the one that was reachable and silent. `hired_at` is
# read through `box exec`, so a stopped box answers nothing and the live
# comparison read that silence as agreement; the transcript was `restored to
# armed (crew@VERSION) and started` at exit 0. A fleet with boxes down is
# exactly the state `crew reset --all` is for.
reset_case
arm alpha
capture hire alpha
printf 'stopped\n' >"$STATE/state-alpha"
: >"$STATE/calls"
RST_STAMP_alpha="" capture reset alpha
t reset-after-a-hire-of-a-stopped-box-is-refused 1 "$RC"
case "$OUT" in *'restored to armed'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-stopped-hired-box-never-reports-a-restore quiet "$r1"
t reset-stopped-hired-box-restores-nothing 0 "$(calls_of 'restore')"
t reset-stopped-hired-box-is-not-stopped-again 0 "$(calls_of 'down')"

# A same-version hire follows the release shape. A `-dev` tree re-bakes and
# marks even though both sides read the same version; a non-dev tree takes the
# documented already-hired skip. Deleting the `*-dev*` shortcut makes the dev
# side skip too, so this case catches that mutation while staying rung-wide.
reset_case
arm alpha "$ENGINE_VERSION"
RST_STAMP_alpha="$ENGINE_VERSION" capture hire alpha
case "$ENGINE_VERSION" in
  *-dev*)
    case "$OUT" in *"alpha's armed checkpoint is now STALE"*) r1=marked ;; *) r1="$OUT" ;; esac
    t reset-same-version-dev-rebake-marks-the-checkpoint marked "$r1"
    expected_reset_rc=1 expected_restores=0
    ;;
  *)
    case "$OUT" in *"version $ENGINE_VERSION matches, skipping"*) r1=skipped ;; *) r1="$OUT" ;; esac
    t reset-same-version-release-hire-skips skipped "$r1"
    expected_reset_rc=0 expected_restores=1
    ;;
esac
: >"$STATE/calls"
RST_STAMP_alpha="$ENGINE_VERSION" capture reset alpha
t reset-after-a-same-version-hire-follows-the-release-shape "$expected_reset_rc" "$RC"
t reset-after-a-same-version-hire-restores-as-expected "$expected_restores" "$(calls_of 'restore')"

# `crew up` is the routine caller, and it marks every roster box it hires.
reset_case
arm alpha
arm beta
capture up
t reset-up-marks-every-roster-box \
  "CHECKPOINT_STALE=$ENGINE_VERSION"$'\n'"CHECKPOINT_STALE=$ENGINE_VERSION" \
  "$(grep -h '^CHECKPOINT_STALE=' "$CONF/checkpoints/alpha.conf" "$CONF/checkpoints/beta.conf")"

# A hire whose mark cannot be written installs nothing, exactly as an upgrade
# does — the gate is one helper and both callers take its answer.
reset_case
arm alpha
chmod 500 "$CONF/checkpoints"
capture hire alpha
chmod u+w "$CONF/checkpoints"
t reset-hire-with-an-unwritable-mark-fails 1 "$RC"
case "$OUT" in *'could NOT be marked stale'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-hire-with-an-unwritable-mark-is-named refused "$r1"
t reset-hire-with-an-unwritable-mark-installs-nothing 0 "$(calls_of 'install alpha')"

# A box with NO record is still rc 0 with nothing written: there is nothing to
# invalidate, and inventing a record would make the reset refuse with a
# version pair crew made up rather than for the true reason.
reset_case
capture hire alpha
t reset-hire-of-an-uncheckpointed-box-succeeds 0 "$RC"
case "$OUT" in *'STALE'*|*'could NOT be marked'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-hire-invents-no-record quiet "$r1"
t reset-hire-writes-no-record-file absent \
  "$([ -e "$CONF/checkpoints/alpha.conf" ] && echo present || echo absent)"

# THE CHOSEN RESIDUAL, SAID IN THE SAME AMOUNT BY BOTH ROUTES. The mark lands
# and the install then fails, so the checkpoint reads stale for a move that did
# not happen and a reset refuses this box until it is re-cut. `cmd_upgrade`
# named that at its failure from the round it was introduced; `hire_box` — the
# route `crew up` takes for the whole roster — did not, and two install routes
# saying different amounts about one state is the drift this gate exists to
# remove.
reset_case
arm alpha
RST_INSTALL_FAIL=alpha capture hire alpha
t reset-failed-hire-fails 1 "$RC"
case "$OUT" in *'hire FAILED'*'stays marked'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-failed-hire-names-the-stale-mark-it-left named "$r1"
# And the refusal it predicts is the one that actually happens.
: >"$STATE/calls"
capture reset alpha
t reset-after-a-failed-hire-is-refused 1 "$RC"
t reset-after-a-failed-hire-restores-nothing 0 "$(calls_of 'restore')"

# The other half: a box with NO record is told nothing about a mark that was
# never written. Guarded on the record for the same reason the gate refuses to
# invent one — a message about a stale checkpoint on a box that has none sends
# an operator to re-cut something that does not exist.
reset_case
RST_INSTALL_FAIL=alpha capture hire alpha
t reset-failed-hire-of-an-uncheckpointed-box-fails 1 "$RC"
case "$OUT" in *'stays marked'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-failed-hire-of-an-uncheckpointed-box-claims-no-mark quiet "$r1"

# --- D6: the drain contract, inherited from #588 ----------------------------

for path in "--cut alpha" "alpha"; do
  reset_case
  arm alpha
  printf 'busy:60\n' >"$STATE/probe-alpha"
  # shellcheck disable=SC2086  # the two argument shapes are the point
  capture reset $path
  label="$(printf '%s' "$path" | tr -d ' -')"
  t "reset-busy-$label-has-skip-status" 3 "$RC"
  case "$OUT" in *'alpha: SKIPPED busy — duty lock held for 1m'*'skipped: alpha'*) r1=named ;; *) r1="$OUT" ;; esac
  t "reset-busy-$label-is-named" named "$r1"
  t "reset-busy-$label-mutates-nothing" 0 "$(grep -cE '^(snapshot|restore|down|start) ' "$STATE/calls" || true)"
done

reset_case
arm alpha
printf 'unreadable\n' >"$STATE/probe-alpha"
capture reset alpha
t reset-unreadable-lock-is-a-busy-skip 3 "$RC"
t reset-unreadable-lock-mutates-nothing 0 "$(grep -cE '^(snapshot|restore) ' "$STATE/calls" || true)"

reset_case
arm alpha "$BOX_STAMP_VERSION"
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture reset alpha --force-after 1
t reset-force-after-proceeds 0 "$RC"
case "$OUT" in *'force-after reached; proceeding'*) r1=announced ;; *) r1="$OUT" ;; esac
t reset-force-after-is-announced announced "$r1"
t reset-force-after-restores 1 "$(calls_of 'restore alpha armed')"

# --force-after FORCES THE RESTORE AND NOT THE CUT, and the cut path says so
# rather than discovering it. D6 gives the flag the same meaning on both
# paths; D7 step 1 makes the cut run a reaper that takes this same duty lock
# with `flock -n`. Both cannot hold. Forcing the cut anyway would either sweep
# under a live session (#457 D1's hazard) or freeze an unreclaimed box as the
# floor every later reset returns to — so a held lock skips the cut at 3
# however old it is, which is what `crew help reset` states the contract to
# be. What must never happen again is the emergent answer: announcing
# "proceeding" and then failing at 1 in the reaper, without measuring.
reset_case
arm alpha
printf 'busy:7260\n' >"$STATE/probe-alpha"
RST_PCT_BEFORE=95 RST_PCT_AFTER=60 capture reset --cut alpha --force-after 1
t reset-cut-force-after-is-a-busy-skip 3 "$RC"
case "$OUT" in *'alpha: SKIPPED busy — duty lock held for 2h 01m'*'--force-after does not apply to --cut'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-force-after-refusal-is-named named "$r1"
case "$OUT" in *'force-after reached; proceeding'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-force-after-announces-nothing-it-cannot-do quiet "$r1"
t reset-cut-force-after-never-reaps 0 "$(calls_of 'reap')"
t reset-cut-force-after-never-measures 0 "$(calls_of 'root-df')"
t reset-cut-force-after-cuts-nothing 0 "$(calls_of 'snapshot')"
case "$OUT" in *'reset --cut: 0 cut, 1 skipped-busy, 0 failed'*'skipped: alpha'*) r1=skipped ;; *) r1="$OUT" ;; esac
t reset-cut-force-after-is-counted-as-skipped skipped "$r1"

# The help is the other half of "stated rather than emergent".
reset_case
capture help reset
# One line, not two: the help wraps, and a needle spanning its line break
# would read as absent while the sentence is plainly there (#363's lesson,
# from the other side).
case "$OUT" in *'forces the RESTORE path only, and does not apply to --cut'*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-states-force-after-does-not-apply-to-cut stated "$r1"

reset_case
capture reset alpha --force-after 00
t reset-force-after-zero-spelling-refuses 2 "$RC"
t reset-force-after-zero-mutates-nothing 0 "$(grep -cE '^(snapshot|restore|down) ' "$STATE/calls" || true)"

reset_case
capture reset alpha --force-after 99999999999999999999
t reset-force-after-over-range-refuses 2 "$RC"

# The threshold is an env override, so it is validated like one: a malformed
# value must refuse UP FRONT, not reach `[ -gt ]` and end a fleet-wide cut
# halfway through with some boxes checkpointed and no summary.
reset_case
CREW_RESET_CUT_MAX_USED_PCT=80% capture reset --cut alpha
t reset-malformed-threshold-refuses 1 "$RC"
case "$OUT" in *'CREW_RESET_CUT_MAX_USED_PCT must be a whole percentage'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-malformed-threshold-is-named named "$r1"
t reset-malformed-threshold-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
CREW_RESET_CUT_MAX_USED_PCT=140 capture reset --cut alpha
t reset-over-100-threshold-refuses 1 "$RC"
t reset-over-100-threshold-cuts-nothing 0 "$(calls_of 'snapshot')"

# ON THE PATH THAT READS IT, and only there. The variable's name says which
# half of the verb it belongs to, and an operator with a malformed value
# exported in their shell was having every restore die on a threshold the
# restore never consults.
reset_case
arm alpha "$BOX_STAMP_VERSION"
CREW_RESET_CUT_MAX_USED_PCT=80% capture reset alpha
t reset-malformed-threshold-does-not-block-a-restore 0 "$RC"
t reset-malformed-threshold-restores 1 "$(calls_of 'restore alpha armed')"
case "$OUT" in *'CREW_RESET_CUT_MAX_USED_PCT'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-malformed-threshold-is-not-mentioned-on-the-restore-path quiet "$r1"

reset_case
capture reset --all alpha
t reset-all-with-names-is-a-usage-error 2 "$RC"
reset_case
capture reset
t reset-no-target-is-a-usage-error 2 "$RC"

# --- --all is the ROSTER, never every box on the host -----------------------

# `arm` and not a bare label here: this fixture's subject is WHICH boxes the
# roster covers, so it must set a state whose restore is legitimate. Arming
# three labels with no records — which is what it did — asserted that a
# checkpoint of unknown version restores, blessing the D5 fail-open below in
# a fixture that is not even about D5.
reset_case
arm alpha "$BOX_STAMP_VERSION"
arm beta "$BOX_STAMP_VERSION"
arm offroster "$BOX_STAMP_VERSION"
capture reset --all
t reset-all-restores-the-roster 2 "$(calls_of 'restore')"
t reset-all-leaves-offroster 0 "$(grep -c 'offroster' "$STATE/calls" || true)"

# --- a stopped box: refused for the CUT, restored where it stands -----------
#
# Only the cut looks inside the box — the login probe, the engine stamp, the
# reaper and `df` all run in it. The restore reads a host-side record and
# stops the box as its first act anyway, so refusing it there was gratuitous
# and disagreed with the sibling verb (`crew restart` answers this same state
# by starting the box).

reset_case
arm alpha
printf 'stopped\n' >"$STATE/state-alpha"
capture reset --cut alpha
t reset-cut-stopped-box-is-refused 1 "$RC"
case "$OUT" in *'alpha: REFUSED — stopped'*'reads its login, its engine and its disk from inside it'*'box start alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-stopped-box-is-named named "$r1"
t reset-cut-stopped-box-cuts-nothing 0 "$(calls_of 'snapshot')"
# And it is refused HERE, not incidentally three steps later by a login probe
# that a stopped box cannot answer: the restore path's announcement must not
# appear on a cut.
case "$OUT" in *'already stopped; restoring'*) r1="$OUT" ;; *) r1=quiet ;; esac
t reset-cut-stopped-box-does-not-take-the-restore-path quiet "$r1"
case "$OUT" in *'reset --cut: 0 cut, 0 skipped-busy, 1 failed'*) r1=failed ;; *) r1="$OUT" ;; esac
t reset-cut-stopped-box-is-a-failure-not-a-skip failed "$r1"

reset_case
arm alpha
printf 'stopped\n' >"$STATE/state-alpha"
capture reset alpha
t reset-stopped-box-is-restored 0 "$RC"
case "$OUT" in *'alpha: already stopped; restoring'*) r1=announced ;; *) r1="$OUT" ;; esac
t reset-stopped-box-is-announced announced "$r1"
# Not stopped a second time, and started at the end — cycle_box's own answer.
t reset-stopped-box-is-not-stopped-again 0 "$(calls_of 'down')"
t reset-stopped-box-restores-and-starts $'restore alpha armed --force\nstart alpha' \
  "$(grep -E '^(restore|start) alpha' "$STATE/calls")"

reset_case
capture reset nosuchbox
t reset-absent-box-is-a-failure 1 "$RC"
case "$OUT" in *'nosuchbox: not present'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-absent-box-is-named named "$r1"

# --- D2: an armed checkpoint is never a clone source ------------------------
#
# A MINT IS COUNTED BY ITS --name, not by the `new` verb. The clone path asks
# `box new --help` first — the clone-sizing capability probe (#607 D5) — and the
# stub logs every `new` it is handed, so a bare `^new` count reads the question
# as a second box. Counting the mints by the flag only a mint carries keeps this
# block measuring what it is about (which sources are refused) rather than how
# many times crew happened to say the word.
reset_case
capture new --name gamma --role builder --agent claude --from alpha/armed
t reset-armed-is-refused-as-a-clone-source 1 "$RC"
case "$OUT" in *"refusing to clone 'alpha/armed'"*"alpha's live credentials"*) r1=named ;; *) r1="$OUT" ;; esac
t reset-clone-refusal-is-named named "$r1"
t reset-clone-refusal-mints-nothing 0 "$(calls_of 'new --name')"
# ...and it is refused before crew touches box at all. The credential guard sits
# at the top of create_box, above the role conf and above the probe, so the
# refusal costs no round trip — and pinning that here is what keeps it there
# when the next flag needs asking about.
t reset-clone-refusal-never-even-probes 0 "$(calls_of 'new --help')"

# A gold snapshot is still a clone source: the guard is the label, not --from.
reset_case
capture new --name gamma --role builder --agent claude --from alpha/gold-crew-0.1.3
t reset-gold-remains-a-clone-source 0 "$RC"
t reset-gold-clone-mints 1 "$(calls_of 'new --name')"

# The roster's own fourth column goes through the same guard: create-all and
# up read it, and a roster line is exactly where this would go unnoticed.
reset_case
printf 'gamma claude builder alpha/armed\n' >>"$CONF/fleet.roster"
capture new gamma
t reset-roster-armed-source-is-refused 1 "$RC"
t reset-roster-armed-source-mints-nothing 0 "$(calls_of 'new --name')"
sed -i '/^gamma /d' "$CONF/fleet.roster"

# --- the on-demand reaper entry point (D7 step 1) ---------------------------
#
# The lock gate is the subject. reap-now.sh takes $DUTY_DIR/.duty.lock exactly
# as duty.sh does, so a tick or a live session holding it means the sweep does
# not run — #457 D1's own hazard note is a reaper deleting files under a
# running session, and this is the one reaper call not already inside a tick.
REAPNOW="$SHARED/bin/reap-now.sh"
RDUTY="$TMP/reapduty"
mkdir -p "$RDUTY/conf/agents" "$RDUTY/conf/roles" "$RDUTY/.claude/projects" "$RDUTY/.cache"
ln -s "$SHARED/lib" "$RDUTY/lib"
cp "$SHARED/conf/fleet.defaults.conf" "$RDUTY/conf/"
cp "$SHARED/conf/agents/claude.conf" "$RDUTY/conf/agents/"
cp "$SHARED/conf/roles/builder.conf" "$RDUTY/conf/roles/"
printf 'BOT_AGENT=claude\nBOT_ROLES=builder\n' >"$RDUTY/conf/instance.conf"

if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
t reapnow-runs-with-a-free-lock 0 "$rc"
case "$out" in *'on-demand sweep requested'*'reaper sweep starting'*) r1=swept ;; *) r1="$out" ;; esac
t reapnow-performs-the-sweep swept "$r1"

# Held by somebody else: refused, named, and nothing swept.
exec 9>"$RDUTY/.duty.lock"
flock -n 9
if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
exec 9>&-
t reapnow-refuses-a-held-lock 199 "$rc"
case "$out" in *'a duty tick holds'*'nothing run'*) r1=named ;; *) r1="$out" ;; esac
t reapnow-held-lock-is-named named "$r1"
case "$out" in *'reaper sweep starting'*) r1="$out" ;; *) r1=unswept ;; esac
t reapnow-held-lock-sweeps-nothing unswept "$r1"

# It runs REGARDLESS of the stamp, and does not move the box's daily cadence.
printf '%s\n' "$(date +%s)" >"$RDUTY/.reaper-last"
if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
t reapnow-ignores-a-fresh-reaper-last 0 "$rc"
case "$out" in *'reaper sweep starting'*) r1=swept ;; *) r1="$out" ;; esac
t reapnow-sweeps-despite-the-stamp swept "$r1"
# Named in its header, read nowhere: the three mentions are the comment that
# explains why the stamp is neither consulted nor written.
t reapnow-does-not-read-the-stamp 0 \
  "$(grep -v '^[[:space:]]*#' "$REAPNOW" | grep -c 'reaper-last' | tr -d ' ')"

# --- #590 D4: THE FLEET-WIDE RESET INHERITS THIS REFUSAL AND MUST NOT WEAKEN
# IT --- and it is the RESET VERB that inherits it, under whatever calls it.
# #590 D4 wrote this contract for the weekly cron entry; #678 defers that entry
# to 0.1.4 (#328), so the caller today is an operator at a keyboard. The
# contract is unchanged by that, which is the whole point of stating it against
# the verb: it holds for the hand-run fleet-wide reset now and for the
# scheduled one when #328 returns it, with no rework here either way.
#
# Everything above proves the interlock refuses. What a FLEET-WIDE run adds is
# that nobody is watching each box while it goes, so the refusal has to survive
# into the host job log intact — the word, the two versions, and the repair —
# and the run has to end there rather than doing something else instead. These
# cases live in THIS suite and not in cli-lifecycle.sh because the checkpoint
# rig is here; duplicating it to assert a `crew reset` contract would give the
# fleet two fixtures of one thing that could drift apart.
#
# THE UNATTENDED SHAPE, `reset --all`, deliberately: `--force` does not exist on
# this path and no caller passes a flag that could stand in for one, so the
# fixture drives exactly what an operator's fleet-wide reset does. #678 defers
# the weekly cron entry to 0.1.4 (#328), so today that caller is a prompt and
# not a schedule — which changes who types it, not one byte of what it runs, so
# this fixture is the right shape under both and needs no rework when #328
# lands.
reset_case
rm -f "$HOSTLOG"
arm alpha
arm beta "$BOX_STAMP_VERSION"
: >"$STATE/calls"
capture upgrade alpha
: >"$STATE/calls"
capture reset --all
t reset-weekly-refusal-is-not-a-restore 1 "$RC"
case "$OUT" in
  *'alpha: REFUSED'*"was cut at crew@$CHECKPOINT_VERSION and the box was upgraded to crew@"*'Repair with: crew reset --cut alpha'*) r1=named ;;
  *) r1="$OUT" ;;
esac
t reset-weekly-refusal-names-the-repair named "$r1"
# THE RUNBOOK QUOTES THIS LINE, AND NOW IT CANNOT DRIFT FROM IT. The sample in
# shared/docs/host-maintenance.md is what an operator matches Sunday's log
# against; two arms print a refusal on this path (the stale mark, and the
# live-read backstop for an engine no crew verb installed) and the runbook
# documents the first, so a reader comparing it against the second has to
# compare by eye. Pinned against the SHIPPED OUTPUT rather than the source
# string, because the output is what the operator sees. The versions and the
# box name are the two things an illustration is entitled to differ on, so the
# comparison is over the shape with those folded out; every other word,
# including the repair command, must be identical.
refusal_shape() { # BOX  (text on stdin)
  tr -s '[:space:]' ' ' |
    sed -e 's/^ //' -e 's/ $//' -e 's/crew@[0-9][0-9A-Za-z.+-]*/crew@V/g' \
        -e "s/$1/BOX/g"
}
doc_refusal="$(awk '/^  claude-builder: REFUSED/,/^```$/' \
  "$ROOT/shared/docs/host-maintenance.md" | grep -v '^```$')"
t reset-weekly-refusal-is-the-runbooks-sample \
  "$(refusal_shape alpha <<<"$(grep 'alpha: REFUSED' <<<"$OUT")")" \
  "$(refusal_shape claude-builder <<<"$doc_refusal")"
t reset-weekly-refusal-restores-nothing-for-that-box 0 "$(calls_of 'restore alpha')"
# NO FALLBACK LABEL. `bootstrapped` and `pristine` both exist on a real box and
# both would "work"; either would return a creds-free, unhired box and read as
# a successful fleet-wide reset. The assertion is over every restore call the
# run made, not over alpha's, because a fallback would arrive as a second call.
t reset-weekly-refusal-restores-no-other-label 0 \
  "$(grep -cE '^restore .*(bootstrapped|pristine)' "$STATE/calls" || true)"
# And it does not simply stop: the sibling box is still maintained, which is
# what makes the refusal a per-box outcome rather than an aborted run.
t reset-weekly-refusal-does-not-abort-the-run 1 "$(calls_of 'restore beta armed')"

# THE LOG IS THE OPERATOR'S ONLY SURFACE HERE, because a fleet-wide run prints
# per-box detail nobody reads box by box. The refusal, its repair and the
# boundary must all be in it.
case "$(cat "$HOSTLOG" 2>/dev/null || true)" in
  *'reset run start'*'alpha: REFUSED'*'Repair with: crew reset --cut alpha'*'reset run end: a box FAILED or was REFUSED (exit 1)'*) r1=logged ;;
  *) r1="$(cat "$HOSTLOG" 2>/dev/null || true)" ;;
esac
t reset-weekly-refusal-reaches-the-job-log logged "$r1"

# The repair, driven: a re-cut clears the mark and the next `reset --all`
# restores the box it refused. This is the ordering rule
# shared/docs/host-maintenance.md states, executed rather than asserted in
# prose — and the rule is now anchored to the next RESET rather than to a
# deadline, because #678 leaves nothing scheduling one.
: >"$STATE/calls"
capture reset --cut alpha
: >"$STATE/calls"
rm -f "$HOSTLOG"
capture reset --all
t reset-weekly-after-recut-proceeds 0 "$RC"
t reset-weekly-after-recut-restores-the-refused-box 1 "$(calls_of 'restore alpha armed')"
case "$(cat "$HOSTLOG" 2>/dev/null || true)" in
  *'reset run end: every selected box acted on (exit 0)'*) r1=logged ;;
  *) r1="$(cat "$HOSTLOG" 2>/dev/null || true)" ;;
esac
t reset-weekly-after-recut-logs-a-clean-boundary logged "$r1"

# ── #761 — N members per subscription: `crew hire --pool` names the pool ────
# Several members hired on one vendor subscription share a credential pool,
# and `crew usage --by pool` reads the quota where it is spent. The pool is a
# safe token, carried to the box's install line, written into instance.conf.
# Here and not in cli-lifecycle because this shim is the one that carries a
# hire through to its install exec.
reset_case
capture hire alpha --pool 'bad token'
t hire-pool-must-be-a-safe-token 2 "$RC"
reset_case
capture hire alpha --pool claude-max-1
t hire-pool-hires 0 "$RC"
t hire-pool-reaches-the-install-line 1 "$(grep -c '^pool alpha claude-max-1$' "$STATE/calls" || true)"

suite_finish
