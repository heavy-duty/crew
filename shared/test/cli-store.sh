#!/usr/bin/env bash
# shared/test/cli-store.sh — the CLI's doors to the host's store (#758), offline.
#
# `crew drain` pulls a box through the one exec site it has always had,
# `crew usage` answers from the store with no box reachable, `crew status`
# prints a reading labelled `stored` for a box that does not answer, and
# `crew up` creates the store. The box CLI is a shim; the record a box answers
# the full probe with is a fixture written here, and every exec is counted so
# the "from the store alone" claim is a number rather than a sentence.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
# shellcheck source=shared/lib/platform.sh
source "$ROOT/shared/lib/platform.sh"
export CREW_PLATFORM_BOX_MIN
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_FLOOR_STORE CREW_MODEL_PRICES
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
CONF="$TMP/conf"; SHIM="$TMP/shim"; STATE="$TMP/state"
mkdir -p "$CONF" "$SHIM" "$STATE"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta  codex  reviewer
EOF
# A complete definition naming nobody: what `crew up` converges when the only
# thing left for it to do is create the store.
CONF_EMPTY="$TMP/conf-empty"
mkdir -p "$CONF_EMPTY"
cp "$CONF/fleet.conf" "$CONF/repos.txt" "$CONF/notify-repos.txt" "$CONF/doctrine.conf" "$CONF_EMPTY/"
printf '# every row a comment\n' >"$CONF_EMPTY/fleet.roster"

# The record alpha answers the full probe with: two sessions a few hours old,
# one priced on the shipped table, so a 24h window holds both and costs one.
ago() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
RECORD="$TMP/record.txt"
{
  printf '::engine crew@9.9.9 (fixture)\n::integrity current\n::agent claude\n::uptime 100\n::now %s\n' "$(ago 0)"
  printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n'
  printf '::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n::vitals \n'
  echo '::logstart'
  printf '%s duty run start\n' "$(ago 7200)"
  printf '%s SESSION END kind=build key=crew#1 rc=0 dur=600s outcome=ok acted=yes reply_tail= log=10 left=0 tier=default peak_rss=100 oom=0 input_tokens=1000000 output_tokens=0 model=claude-sonnet-4-6 pool=pool-x sid=s-1\n' "$(ago 7000)"
  printf '%s SESSION END kind=review key=box#2 rc=- dur=- outcome=ORPHANED acted=unknown reply_tail= log=- left=- tier=unknown peak_rss=- started=%s sid=unknown\n' "$(ago 3600)" "$(ago 3700)"
  echo '::logend'
  printf '::statefiles .seen-build .session-terminal.review\n'
  printf '::filestart .seen-build\ncrew#1 2026-10-01T00:00:00Z\n::fileend\n'
  printf '::filestart .session-terminal.review\n1\ttripped\t9\tno\t0\t0\n::fileend\n'
  printf '::logfrom 1\n::logtotal 3\n'
  echo '::filestart duty.log'
  printf '%s duty run start\n' "$(ago 7200)"
  printf '%s SESSION END kind=build key=crew#1 rc=0 dur=600s outcome=ok acted=yes reply_tail= log=10 left=0 tier=default peak_rss=100 oom=0 input_tokens=1000000 output_tokens=0 model=claude-sonnet-4-6 pool=pool-x sid=s-1\n' "$(ago 7000)"
  printf '%s SESSION END kind=review key=box#2 rc=- dur=- outcome=ORPHANED acted=unknown reply_tail= log=- left=- tier=unknown peak_rss=- started=%s sid=unknown\n' "$(ago 3600)" "$(ago 3700)"
  echo '::fileend'
} >"$RECORD"

cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
cmd="${1:-}"; shift || true
# The verb, the box and the script's FIRST line: the mode a probe runs in is
# exported on that line, and the test reads it back from here.
printf '%s\n' "$cmd ${1:-} $(printf '%s' "${*: -1}" | head -1)" >>"$CS_STATE/calls"
state_of() { cat "$CS_STATE/$1.state" 2>/dev/null || echo running; }
case "$cmd" in
  --version|-V) printf 'box %s (/opt/box/versions/%s)\n' "$CREW_PLATFORM_BOX_MIN" "$CREW_PLATFORM_BOX_MIN" ;;
  list)
    if [ "${1:-}" = --json ]; then
      printf '['; sep=""
      for n in alpha beta; do printf '%s{"name":"%s","state":"%s"}' "$sep" "$n" "$(state_of "$n")"; sep=,; done
      printf ']\n'
    else printf 'NAME\nalpha\nbeta\n'; fi ;;
  info) printf '[{"name":"%s","status":"%s"}]\n' "$1" "$(state_of "$1")" ;;
  exec)
    name="$1"; script="${*: -1}"
    cat >/dev/null
    if [ -f "$CS_STATE/$name.down" ] || [ "$(state_of "$name")" = stopped ]; then
      echo "Error: instance is not running" >&2; exit 1
    fi
    case "$script" in
      *'echo "::logstart"'*) cat "$CS_RECORD" ;;   # the full probe
      *) exit 1 ;;                                  # nothing else answers here
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SHIM/box"
# `gh` so `crew up`'s one-repo-one-fleet sweep degrades to its NOTE instead
# of reaching the network.
printf '#!/usr/bin/env bash\nexit 1\n' >"$SHIM/gh"; chmod +x "$SHIM/gh"

run_crew() {
  env CREW_CONFIG_DIR="${CS_CONF:-$CONF}" CS_STATE="$STATE" CS_RECORD="$RECORD" \
    PATH="$SHIM:$PATH" bash "$CLI" "$@"
}
capture() {  # capture ARGS... — stdout+stderr in $OUT, rc in $RC
  OUT="$(run_crew "$@" 2>&1)"; RC=$?
}
execs() { grep -c '^exec ' "$STATE/calls" 2>/dev/null || true; }
STORE="$CONF/store/fleet.sqlite"
q() {  # q STORE SQL — one value out of the store
  CREW_FLOOR_STORE="$1" PYTHONPATH="$ROOT/fleet-floor/server" python3 -c '
import sys
from floor import store
c = store.connect()
print(c.execute(sys.argv[1]).fetchone()[0])' "$2"
}

# --- the verbs exist, and say what they read ----------------------------------
capture help
t cli-store-help-lists-usage 1 "$(grep -c '^  usage ' <<<"$OUT")"
t cli-store-help-lists-drain 1 "$(grep -c '^  drain ' <<<"$OUT")"
capture help usage
t cli-store-help-usage-names-the-store 1 "$(grep -c "store/fleet.sqlite" <<<"$OUT")"
capture help drain
t cli-store-help-drain-says-before-a-stop 1 "$(grep -c 'before' <<<"$OUT")"

# --- usage before there is a store ------------------------------------------------
capture usage
t cli-store-usage-without-a-store-is-a-failure 1 "$RC"
t cli-store-usage-without-a-store-names-up 1 "$(grep -c "crew up" <<<"$OUT")"
capture usage --since yesterday
t cli-store-usage-bad-window-is-an-invocation-fault 2 "$RC"
capture usage --by vendor
t cli-store-usage-bad-group-is-an-invocation-fault 2 "$RC"

# --- crew up creates the store -------------------------------------------------------
CS_CONF="$CONF_EMPTY" capture up
t cli-store-up-with-nothing-to-do-exits-0 0 "$RC"
t cli-store-up-creates-the-store yes "$([ -f "$CONF_EMPTY/store/fleet.sqlite" ] && echo yes || echo no)"
t cli-store-up-store-has-a-schema-version 2 "$(q "$CONF_EMPTY/store/fleet.sqlite" "SELECT value FROM meta WHERE key='schema_version'")"
CS_CONF="$CONF_EMPTY" capture up --dry-run
t cli-store-up-dry-run-exits-0 0 "$RC"
rm -rf "$CONF_EMPTY/store"
CS_CONF="$CONF_EMPTY" capture up --dry-run
t cli-store-up-dry-run-creates-nothing no "$([ -e "$CONF_EMPTY/store" ] && echo yes || echo no)"

# --- drain: one full probe, landed ----------------------------------------------------
: >"$STATE/calls"
capture drain
t cli-store-drain-needs-a-box 2 "$RC"
capture drain nobody
t cli-store-drain-refuses-an-unknown-box 1 "$RC"
capture drain alpha
t cli-store-drain-exits-0 0 "$RC"
t cli-store-drain-reports-what-landed 1 "$(grep -c '^alpha: 3 lines, 2 sessions, 2 files$' <<<"$OUT")"
t cli-store-drain-is-one-exec 1 "$(execs)"
t cli-store-drain-creates-the-store yes "$([ -f "$STORE" ] && echo yes || echo no)"
t cli-store-drain-lands-every-session-once 2 "$(q "$STORE" "SELECT COUNT(*) FROM sessions WHERE box='alpha'")"
t cli-store-drain-lands-the-ledger 1 "$(q "$STORE" "SELECT COUNT(*) FROM ledger WHERE box='alpha' AND name='.seen-build' AND id='crew#1'")"
t cli-store-drain-lands-the-breaker tripped "$(q "$STORE" "SELECT content FROM state_files WHERE box='alpha' AND name='.session-terminal.review'" | cut -f2)"
t cli-store-drain-records-the-roster-identity "claude builder" "$(q "$STORE" "SELECT agent || ' ' || roles FROM boxes WHERE name='alpha'")"
# The probe went out in full mode from the top — the drain is the whole file.
t cli-store-drain-asks-for-full-mode-from-line-1 yes \
  "$(grep -q 'PROBE_FULL=1 PROBE_LOG_FROM=1' "$STATE/calls" 2>/dev/null && echo yes || echo no)"
capture drain alpha
t cli-store-drain-twice-inserts-nothing 1 "$(grep -c '^alpha: 0 lines, 0 sessions, 2 files$' <<<"$OUT")"
t cli-store-drain-twice-still-two-sessions 2 "$(q "$STORE" "SELECT COUNT(*) FROM sessions WHERE box='alpha'")"

# --- drain: a box that does not answer -------------------------------------------------
touch "$STATE/beta.down"
capture drain beta
t cli-store-drain-of-a-dead-box-fails 1 "$RC"
t cli-store-drain-of-a-dead-box-says-so 1 "$(grep -c 'did not answer' <<<"$OUT")"
t cli-store-drain-of-a-dead-box-records-a-failed-pull 1 "$(q "$STORE" "SELECT COUNT(*) FROM pulls WHERE box='beta' AND ok=0")"
t cli-store-drain-of-a-dead-box-leaves-stored-rows 2 "$(q "$STORE" "SELECT COUNT(*) FROM sessions")"

# --- usage: from the store alone, no box reachable ------------------------------------------
touch "$STATE/alpha.down"
before="$(execs)"
capture usage
t cli-store-usage-exits-0 0 "$RC"
t cli-store-usage-says-no-box-asked 1 "$(grep -c 'no box asked' <<<"$OUT")"
t cli-store-usage-asks-no-box "$before" "$(execs)"
t cli-store-usage-has-a-member-row 1 "$(grep -cE '^alpha +2 +10 +[$]3\.0000 +1 unpriced$' <<<"$OUT")"
t cli-store-usage-totals 1 "$(grep -cE '^total \(24h\) +2 +10 +[$]3\.0000 +1 unpriced$' <<<"$OUT")"
capture usage --since 7d --by pool
t cli-store-usage-by-pool-groups-the-pool 1 "$(grep -cE '^pool-x +1 +10 +[$]3\.0000' <<<"$OUT")"
t cli-store-usage-by-pool-keeps-the-poolless 1 "$(grep -cE '^- +1 +0 +— +1 unpriced$' <<<"$OUT")"
capture usage --by kind
t cli-store-usage-by-kind 2 "$(grep -cE '^(build|review) ' <<<"$OUT")"
capture usage --since 1h
t cli-store-usage-window-excludes-older-sessions 1 "$(grep -cE '^total \(1h\) +0 +0 +—' <<<"$OUT")"

# --- status: the stored reading for a box that does not answer ----------------------------
capture status alpha
t cli-store-status-dead-box-exits-0 0 "$RC"
t cli-store-status-dead-box-is-unreachable 1 "$(grep -c '(unreachable)' <<<"$OUT")"
t cli-store-status-dead-box-prints-the-stored-block 1 "$(grep -c '^  stored (pulled ' <<<"$OUT")"
t cli-store-status-dead-box-names-the-last-session 1 "$(grep -c '^    last session: review box#2 → ORPHANED' <<<"$OUT")"
t cli-store-status-dead-box-prices-the-window 1 "$(grep -c '^    24h 2 session(s), 10m, [$]3.0000 (1 unpriced)$' <<<"$OUT")"
t cli-store-status-dead-box-never-says-live 0 "$(grep -c 'engine: crew@' <<<"$OUT")"
capture status beta
t cli-store-status-never-pulled-box-has-no-stored-block 0 "$(grep -c 'stored' <<<"$OUT")"
capture status
t cli-store-status-table-dead-row-carries-the-brief 1 "$(grep -cE '^alpha .* stored: review box#2 → ORPHANED, .* · pulled .* · 24h 2 session\(s\), 10m, [$]3\.0000 \(1 unpriced\)$' <<<"$OUT")"
t cli-store-status-table-never-pulled-row-has-none 0 "$(grep '^beta ' <<<"$OUT" | grep -c 'stored:')"
echo stopped >"$STATE/alpha.state"
capture status
t cli-store-status-table-stopped-row-carries-the-brief 1 "$(grep -cE '^alpha +stopped .*crew up starts it · stored: review box#2' <<<"$OUT")"
rm -f "$STATE/alpha.state"
# The store is never CREATED by a read: with it gone, status prints no stored
# line and makes no file.
mv "$CONF/store" "$TMP/store-aside"
capture status alpha
t cli-store-status-without-a-store-prints-nothing-stored 0 "$(grep -c 'stored' <<<"$OUT")"
t cli-store-status-never-creates-the-store no "$([ -e "$CONF/store" ] && echo yes || echo no)"
mv "$TMP/store-aside" "$CONF/store"

# --- the fallback refuses a write ----------------------------------------------------------
OUT="$(cd "$TMP" && env -u CREW_CONFIG_DIR CS_STATE="$STATE" CS_RECORD="$RECORD" PATH="$SHIM:$PATH" bash "$CLI" drain alpha 2>&1)"; RC=$?
t cli-store-drain-refuses-under-the-examples-fallback 1 "$(grep -c 'refuses' <<<"$OUT")"
t cli-store-drain-refuses-under-the-examples-fallback-rc 1 "$RC"

# --- the exec budget: the CLI's one exec site is still the only one -----------------------
t cli-store-no-new-box-exec-site 3 \
  "$(grep -vE '^[[:space:]]*#' "$CLI" | sed -e :a -e '/\\$/N; s/\\\n//; ta' | grep -cE 'box exec "')"

suite_finish
