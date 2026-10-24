#!/usr/bin/env bash
# fleet-floor/test/run.sh — test the collector and the page with no fleet.
#
#   fleet-floor/test/run.sh [--no-browser]
#
# A stub `box` CLI (test/stub-box) stands in for Incus, driven by
# test/fixtures/fleet.txt, so every box state the floor must render — running,
# stopped, unreachable, wedged, cron-silent, paused, freshly hired with no
# sessions, unauthenticated, and a box whose log is hostile or corrupt — is
# reachable here instead of only on a real host. The drill covers the other
# half (drill/rehearsal-app.sh: the same assertions against real boxes).
#
# The browser half needs playwright-core; it is SKIPPED, loudly, when absent,
# because a silently-skipped UI test reads exactly like a passing one.
# The source-path directive below makes each `source "$HERE/floor/<m>.sh"`
# resolve, so shellcheck can see that the helpers defined here ARE called
# from the module suites and stops reporting every one as unreachable.
# A line must never OPEN with the word after a `#` being `shellcheck`: that
# parses as a directive and reds the whole file (SC1073).
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR="$(dirname "$HERE")"

BROWSER=1
[ "${1:-}" = "--no-browser" ] && BROWSER=0

PASS=0 SKIP=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
# t NAME EXPECTED ACTUAL — the fixture-test idiom from shared/test/run.sh
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# A busy port surfaced as a python traceback from deep inside socketserver,
# which reads like the collector is broken rather than like another copy of
# this suite is already running. Say so plainly, and name the way out.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; }; return 1; }
# Every port this suite binds: the main collector, the collector-death one, the
# fast-polling churn one, and #204's empty-floor one. Checked up front, because
# a busy port discovered four minutes in reads as a broken collector.
for _p in "${FLOOR_TEST_PORT:-8791}" $(( ${FLOOR_TEST_PORT:-8791} + 1 )) \
          $(( ${FLOOR_TEST_PORT:-8791} + 2 )) $(( ${FLOOR_TEST_PORT:-8791} + 3 )) \
          $(( ${FLOOR_TEST_PORT:-8791} + 4 )); do
  if port_busy "$_p"; then
    echo "port $_p is already in use — another run of this suite is probably still going." >&2
    echo "  re-run with a different base:  FLOOR_TEST_PORT=8891 $0 $*" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG DUTY_DIR
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
PORT="${FLOOR_TEST_PORT:-8791}"
USER=operator
PASSWD="test-$$"

# Resolve the ping fixture knobs once. The collector and any suite that imports
# its effective production constants must describe the same running server.
FLOOR_TEST_PING_INTERVAL="${FLOOR_TEST_PING_INTERVAL:-2}"
FLOOR_TEST_PING_TIMEOUT="${FLOOR_TEST_PING_TIMEOUT:-4}"
FLOOR_TEST_PING_FAILS="${FLOOR_TEST_PING_FAILS:-2}"
export FLOOR_TEST_PING_INTERVAL FLOOR_TEST_PING_TIMEOUT FLOOR_TEST_PING_FAILS

export FLOOR_FIXTURE="$HERE/fixtures/fleet.txt"
# The fleet under the page is the fixture, so the walk may demand the states
# only the fixture guarantees: a hostile-log box, a first-session box, several
# offline. The drill deliberately does NOT set this -- a real fleet has no such
# boxes, and a healthy one has nothing offline, so those demands would fail on
# every host forever. cli.sh asserts both halves of that split.
export FLOOR_TEST_FIXTURE=1
export FLOOR_CALLS="$TMP/box-calls.log"
export FLOOR_STATE="$TMP/state"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$FLOOR_STATE"
ln -sf "$HERE/stub-box" "$TMP/bin/box"
: > "$FLOOR_CALLS"

# Keep ambient operator and duty configuration out of fixture resolution.
# These static assertions make removing either half fail in this suite.
if grep -Fqx 'unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG DUTY_DIR' "$HERE/run.sh"; then
  ok "suite unsets ambient crew and duty config"
else
  fail "suite unsets ambient crew and duty config" "guard missing"
fi
# shellcheck disable=SC2016  # Match the literal assignment in this file.
if grep -Fqx 'export XDG_CONFIG_HOME="$TMP/xdg-empty"' "$HERE/run.sh"; then
  ok "suite pins empty XDG config"
else
  fail "suite pins empty XDG config" "guard missing"
fi

# The fixture fleet is handed to the collector by env, NOT by swapping the
# tracked fleet.roster and restoring it on exit: any killed run then left the
# real roster clobbered in the working tree, one `git add -A` away from being
# committed.
export CREW_FLOOR_ROSTER="$HERE/fixtures/roster.txt"
export FLOOR_TEST_VERSION="crew 9.8.7-fixture ($FLOOR)"
# Exercise the same prerelease grammar used by candidate drills. The stub box
# emits this as its installed engine stamp; browser.js then has to carry the
# suffix all the way through the tile's integrity verdict.
export FLOOR_TEST_ENGINE_VERSION="9.9.9-rc1"

# ...and the suite's own operator fleet DEFINITION, which is a different thing
# (#244). `crew floor` and floor.py now refuse under the examples fallback,
# and CREW_FLOOR_ROSTER does not lift that: it selects a roster file while
# fleet.conf and the agent profiles still come from the resolved config dir.
# Exporting only the roster left every case here resolving that dir to the
# shipped examples/ — i.e. to the refusal. Built under $TMP, so it is the
# suite's own definition and not anything ambient: the unset above still keeps
# the operator's real config out, and this puts a known one in its place.
export CREW_CONFIG_DIR="$TMP/opconfig"
mkdir -p "$CREW_CONFIG_DIR"
cp "$HERE/fixtures/roster.txt" "$CREW_CONFIG_DIR/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CREW_CONFIG_DIR/fleet.conf"
printf 'heavy-duty/crew\n' >"$CREW_CONFIG_DIR/repos.txt"
# The alert sink is a host command from fleet.conf. `tee` is deliberately
# boring: it makes every delivered stdin message observable without a network
# service, credential, or box-side helper.
export FLOOR_ALERT_LOG="$TMP/reachability-alerts.log"
: >"$FLOOR_ALERT_LOG"
printf 'FLEET_FLOOR_ALERT_CHANNEL="tee -a %s"\n' "$FLOOR_ALERT_LOG" \
  >>"$CREW_CONFIG_DIR/fleet.conf"
if [ -f "$CREW_CONFIG_DIR/fleet.roster" ] && [ "$CREW_CONFIG_DIR" = "$TMP/opconfig" ]; then
  ok "suite serves its own operator fleet definition, not the shipped examples"
else
  fail "suite serves its own operator fleet definition, not the shipped examples" \
       "every floor.py in this suite would hit the #244 refusal"
fi

# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  [ -n "${SRV2:-}" ] && kill "$SRV2" 2>/dev/null
  [ -n "${SRV3:-}" ] && kill "$SRV3" 2>/dev/null
  [ -n "${SRV4:-}" ] && kill "$SRV4" 2>/dev/null
  [ -n "${SRV5:-}" ] && kill "$SRV5" 2>/dev/null
  [ -n "${SRV6:-}" ] && kill "$SRV6" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

if python3 "$HERE/concurrent-actions.py"; then
  ok "fleet-wide actions run concurrently in stable order"
else
  fail "fleet-wide actions run concurrently in stable order" "see output above"
fi

api() {  # api METHOD PATH [BODY] -> "<status>\n<body>"
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s -u "$USER:$PASSWD" -X "$m" -H 'Content-Type: application/json' \
      -d "$b" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  else
    curl -s -u "$USER:$PASSWD" -X "$m" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  fi
}
status() { api "$@" | tail -1; }
body()   { api "$@" | sed '$d'; }
jqf()    { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
unit()   { body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1']
print(json.dumps(u[0]) if u else '{}')"; }
uf()     { unit "$1" | python3 -c "import json,sys;u=json.load(sys.stdin);print($2)" 2>/dev/null; }
# ufg BOX EXPR — like uf, with `g` bound to the snapshot's own `generated`
# epoch: a reading that is "on the host timeline" is on the timeline of the
# poll that produced it, not of whatever wall clock the assertion runs under
# (a slower poll — the store's full pull, a loaded runner — made the old
# `time.time()` comparison stale by the time units.sh reached it, #758).
ufg()    { body GET /api/fleet | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1'][0]
g=datetime.datetime.strptime(d['generated'],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
print($2)" 2>/dev/null; }

echo "== collector"
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
CREW_FLOOR_PING_INTERVAL="$FLOOR_TEST_PING_INTERVAL" \
CREW_FLOOR_PING_TIMEOUT="$FLOOR_TEST_PING_TIMEOUT" \
CREW_FLOOR_PING_FAILS="$FLOOR_TEST_PING_FAILS" \
CREW_FLOOR_VERSION="$FLOOR_TEST_VERSION" \
  python3 "$FLOOR/server/floor.py" >"$TMP/server.log" 2>&1 &
SRV=$!

for _ in $(seq 1 60); do
  curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$SRV" 2>/dev/null || { echo "collector died:"; cat "$TMP/server.log"; exit 1; }
  sleep 0.5
done
# The first poll must finish before any fleet assertion, or every one of them
# races the collector's startup and fails intermittently.
for _ in $(seq 1 80); do
  [ "$(body GET /api/fleet | jqf "len(d['units'])")" != "0" ] && break
  sleep 0.5
done

export PORT USER PASSWD TMP
# One suite per collector module, at the path that mirrors it (#508 D2). They
# share this collector and this file's reporters rather than each booting their
# own: eight servers would cost CI eight first polls to assert what one does.
#
# The ORDER is load-bearing, and what it constrains is READS, not writes: a
# suite belongs after whatever writes the stub state it reads. ping.sh is last
# because the ping tier reads state the control verbs write; `wake-silent`
# runs after the fixture's stopped box has been started, same rule, same
# direction.
#
# "A suite that mutates stub state belongs at or after actions.sh" would be a
# tidier rule and it is FALSE one file away: floor/server.sh's concurrency
# block fires five real `pause` commands at ff-idle and is sourced before
# actions.sh. That is fine, and why it is fine is the actual rule — `pause`
# writes ff-idle.cron, the only assertions that read ff-idle read .state
# (actions.sh's power verbs), and nothing downstream reads ff-idle's paused
# flag at all. No read to order against, so no constraint. In cases.sh that
# block ran AFTER those power verbs (line 379 against 247) and here it runs
# before them; both trees green is the evidence that the distinction is real
# and not a story.
#
# What this does NOT preserve is cases.sh's exact interleaving, and it cannot:
# grouping by module is the whole of D2, and cases.sh ran each module's blocks
# scattered through the file. Measured at the split on the --no-browser set,
# branch against 394bdad, pivoting on the first actions.sh assertion
# (`cmd: pause ok`) in each tree:
#
#   after -> before   51 names
#   before -> after    0 names
#
# One direction, all of it. Nothing that ran before the control verbs now runs
# after them, so no assertion reads state that is MORE mutated than it used to
# be; the 51 read state that is less. They are `server.sh`'s HTTP/`logs:`/
# concurrency rows, `fleet.sh`'s wedged-and-garbage rows, `units.sh`'s
# snapshot-shape rows, and the `integrity:`/`ping:`/`creds:` rows that are
# static greps or read fields the control verbs do not write. Both trees run
# all of them green, which is the two-sided evidence: each asserts the same
# value before the control verbs that it asserted after them.
#
# Re-measuring this needs one normalisation. `flow: a fresh tick is reported
# as an age (N s)` puts a MEASURED duration in the assertion name, so two runs
# of the same tree can differ by that one name; strip the parenthetical before
# comparing the sets or it reports a difference that is a clock, not an order.
#
# So the invariant to keep when adding a suite is the read: place it after
# whatever writes the state it reads, and if nothing it reads is written here,
# position is free.
# init.sh reads no stub state at all — it imports the package and asks what is
# on it — so by the rule above its position is free. It goes first because it
# is the package root, and because if the compatibility block is broken the
# clearest possible report is the first suite saying so.
# shellcheck source=floor/init.sh
source "$HERE/floor/init.sh"
# shellcheck source=floor/units.sh
source "$HERE/floor/units.sh"
# shellcheck source=floor/roster.sh
source "$HERE/floor/roster.sh"
# shellcheck source=floor/fleet.sh
source "$HERE/floor/fleet.sh"
# store.sh reads no state another suite writes — its first half drives
# store.py in-process over fixture records and its second boots a collector
# of its own on PORT+4 over a private fixture — so by the rule above its
# position is free; it sits with the collector suites it is about (#758).
# shellcheck source=floor/store.sh
source "$HERE/floor/store.sh"
# shellcheck source=floor/server.sh
source "$HERE/floor/server.sh"
# shellcheck source=floor/actions.sh
source "$HERE/floor/actions.sh"
# shellcheck source=floor/ping.sh
source "$HERE/floor/ping.sh"
# Reachability transitions ride the ping tier and are asserted last, after the
# earlier suites have left that tier running through many unchanged rounds.
# That ordering is what makes alerts.sh's one-edge assertion a deduplication
# test rather than a single-poll happy path.
# shellcheck source=floor/alerts.sh
source "$HERE/floor/alerts.sh"
# registry.sh WRITES the fleet definition this whole file resolves against, so
# by the read rule above it goes after every suite that reads it — and it puts
# a `gh` stub on PATH, which boxside.sh below must not inherit. It restores
# both before it returns; the position is the belt to that file's braces.
# shellcheck source=floor/registry.sh
source "$HERE/floor/registry.sh"
# The two scripts that normally only run inside a box, executed for real —
# without this the collector assertions above are circular (they validate the
# parser against stub-box's imitation of probe.sh, not against probe.sh).
# shellcheck source=boxside.sh
source "$HERE/boxside.sh"
# `crew floor` itself: the only part an operator types, and where the auth
# decision is made.
# shellcheck source=cli.sh
source "$HERE/cli.sh"

# ---- browser -------------------------------------------------------------
if [ "$BROWSER" -eq 1 ]; then
  echo
  echo "== page"
  # Both halves must be present: the driver, and a browser for it to drive.
  # PW_CHROME lets CI point at the runner's preinstalled Chrome instead of
  # downloading one.
  CHROME_BIN="${PW_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
  # On a developer machine a missing browser is a skip; in CI it is a failure.
  # Same words, different verdict: locally not everyone has Chrome, but a
  # skipped UI test on the merge gate reads exactly like a passing one.
  # CI sets FLOOR_TEST_REQUIRE_BROWSER=1.
  if [ "${FLOOR_TEST_REQUIRE_BROWSER:-0}" = "1" ]; then
    absent() { fail "browser walk" "$1 (FLOOR_TEST_REQUIRE_BROWSER=1: this is a failure, not a skip)"; }
  else
    absent() { skip "browser walk" "$1"; }
  fi
  if ! command -v node >/dev/null; then
    absent "node not installed"
  elif ! (cd "$HERE" && node -e "require('playwright-core')") >/dev/null 2>&1; then
    absent "playwright-core not installed (npm i playwright-core)"
  elif [ ! -x "$CHROME_BIN" ]; then
    absent "no browser at $CHROME_BIN (set PW_CHROME)"
  else
    export PW_CHROME="$CHROME_BIN"
    # Run the walk, then check it actually ASSERTED something.
    #
    # "0 failed" is not the same as "it ran". A walk that finds no hostile box,
    # or returns early from a block, exits 0 having asserted a fraction of what
    # it claims to cover — which is how a suite goes green while the coverage
    # quietly drains out of it. The walk's own tail line reports its count, so
    # hold it to a floor. Raise these when the walk gains permanent checks;
    # they are a tripwire, not a target.
    walk() { # walk <label> <floor> <args...>
      local label="$1" floor="$2"; shift 2
      local log rc n
      log="$TMP/walk-$(printf '%s' "$label" | tr -cd '[:alnum:]').log"
      node "$HERE/browser.js" "$@" 2>&1 | tee "$log"; rc="${PIPESTATUS[0]}"
      if [ "$rc" -ne 0 ]; then
        fail "$label" "see output above"
        return
      fi
      ok "$label"
      n="$(sed -n 's/.*-- browser: \([0-9]*\) ok.*/\1/p' "$log" | tail -1)"
      if [ -z "$n" ]; then
        fail "$label: reported its assertion count" "no '-- browser: N ok' line; the walk exited 0 without a summary"
      elif [ "$n" -lt "$floor" ]; then
        fail "$label: asserted enough to be meaningful" "only $n checks ran, expected >= $floor — a block returned early"
      else
        ok "$label: asserted $n checks (>= $floor)"
      fi
    }
    # 30 -> 40 with the heartbeat/stuck/renew assertions, then -> 38 when the
    # renewal countdown was dropped and its four checks went with it, then -> 39
    # when the engine assertion split in two: a shape check that holds on any
    # fleet, and the exact-fixture check that only this run can make (#202).
    # Moved deliberately each time: the floor exists so a walk that silently
    # stops asserting cannot still exit 0, and it caught that removal. 39 -> 53
    # with #203's fourteen: the disarmed box and the genuinely silent one across
    # four readouts each plus a reachability check, and the paused box's four,
    # captured where the walk pauses one itself. 53 -> 61 with #190's seven: the
    # engine tile's integrity verdict on any fleet, the three fixture verdicts
    # rendering distinctly with a reachability check for each of the two new
    # boxes, and the guard that keeps the rescoped gh check from retiring
    # itself — the gh check is rescoped, not added, so it counts zero.
    #
    # Seven added to 53 is 60, and this says 61: the number is now the walk's
    # EXACT green count, measured, and the one check of slack the old floor
    # carried is spent on purpose. A tripwire a check can be deleted under is
    # not one — with slack, removing an assertion still clears the floor, which
    # is precisely the silent drain this number exists to catch (#190's test
    # plan asks for that case by name). The count is deterministic in a green
    # run: every conditional block here is guarded by a check that fails when
    # its box is unreachable, so a run that asserts fewer than 61 is already red.
    # 61 -> 65 with #347's API-to-canvas exact-version pair, its two-width
    # cross-layer collision guard, and the room-HUD exact-version assertion.
    # 65 -> 74 with #204's nine: the hired tile's count and its command, the two
    # shape checks that hold on any fleet (nothing unhired is drawn, nothing
    # unmeasurable is dropped), the four fixture boxes that make the decision
    # table's rows bite by name, and the payload guard that keeps the filter
    # page-side. Three assertions were RENAMED rather than added — the roster
    # count, the unit tile and the reachability sweep now say "deployed" where
    # they said "declared" — so they count zero, and the floor moves by the nine
    # that are new. The DEMO floor is untouched: every one of the nine is inside
    # `if (LIVE)`, because DEMO has no collector and so no hired verdict.
    # 74 -> 80 with #312's chip vocabulary, the three named-fixture selections,
    # and both chip-to-tile count agreements. The shared vocabulary check also
    # runs in DEMO; its three mode-specific selections move that floor 10 -> 14.
    # 80 -> 81 with #489's one assertion per browser-walk width replacing the
    # old aggregate verdict. A missing width can no longer hide behind the other.
    # 81 -> 87 with #486's cross-layer six. Three on the sentence BEFORE the
    # click: the collector's wedge verdict reaching the page, the restart
    # confirmation naming the force path from it, and the reachable box that
    # must not be told it will be killed. Three on the sentence AFTER it: a
    # restart that escalated saying so, a graceful one claiming nothing of the
    # kind, and the force-stop verb not narrating itself twice. All six are
    # inside `if (LIVE)` — the first three read the payload this collector
    # serves at CREW_FLOOR_PING_FAILS=2, which DEMO has no collector for — so
    # the DEMO floor below is unmoved.
    #
    # 87 -> 96 with #486's round 2, which closes the gap between the sentence
    # and the request. Six on the mode: the wedged box authorising the force
    # path it was shown and the reachable one authorising only the gentle path
    # (a pair, because a plan whose words and mode disagree is the bug itself),
    # the console re-opened to drive the SHIPPED click rather than the hook,
    # that click putting a mode on the wire at all, and a refusal arriving as
    # the collector's words rather than as "HTTP 409" or as a failure. Three
    # more on the status line's failure path: a restart that killed the guest
    # and then could not start it saying so, a gentle failure claiming no kill,
    # and a force stop that itself failed not being reported as one. All nine
    # are inside `if (LIVE)`, so the DEMO floor below is again unmoved.
    walk "browser walk" 96 "http://127.0.0.1:$PORT/" "$TMP/shots" "$USER" "$PASSWD"
    # DEMO is a shipped mode, not a fallback: `open index.html` must still work
    # with no collector, no network and every control visibly disabled.
    walk "browser walk (DEMO mode)" 14 "file://$FLOOR/index.html" "$TMP/shots-demo"

    # The #226 acceptance criteria: deterministic stills (zero steady-state
    # builds), bounded portrait motion, reproducible dev renders, reduced
    # motion. Runs on DEMO because its roster is static — the "stable roster"
    # the claims are about.
    echo
    echo "== portrait motion (#226)"
    if node "$HERE/motion.js" "file://$FLOOR/index.html"; then
      ok "portrait motion: #226 acceptance criteria"
    else
      fail "portrait motion: #226 acceptance criteria" "see output above"
    fi

    # Killed collector, on its own throwaway instance so the walk above keeps
    # the one it was using.
    echo
    echo "== collector death"
    SPORT=$((PORT + 1))
    CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$SPORT" \
    CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
    CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
      python3 "$FLOOR/server/floor.py" >"$TMP/server2.log" 2>&1 &
    SRV2=$!
    # Wait for its FIRST POLL, not just the socket: a page that loads against a
    # collector with no snapshot yet sees an empty fleet, and the stale test
    # would then be asserting against a page that never went live.
    for _ in $(seq 1 120); do
      floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$SPORT/api/fleet" 2>/dev/null)"
      grep -q '"box"' <<<"$floor_snapshot" && break
      sleep 0.5
    done
    if node "$HERE/stale.js" "http://127.0.0.1:$SPORT/" "$SRV2" "$USER" "$PASSWD"; then
      ok "page reports a dead collector"
    else
      fail "page reports a dead collector" "see output above"
    fi
    kill "$SRV2" 2>/dev/null

    # The roster changing under an open console. Its own collector: this one
    # polls fast and owns a scratch roster the test is allowed to edit.
    echo
    echo "== roster churn"
    CPORT=$((PORT + 2))
    cp "$HERE/fixtures/roster.txt" "$TMP/churn-roster.txt"
    CREW_FLOOR_ROSTER="$TMP/churn-roster.txt" \
    CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$CPORT" \
    CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=6 \
    CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
      python3 "$FLOOR/server/floor.py" >"$TMP/server3.log" 2>&1 &
    SRV3=$!
    for _ in $(seq 1 120); do
      floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$CPORT/api/fleet" 2>/dev/null)"
      grep -q '"box"' <<<"$floor_snapshot" && break
      sleep 0.5
    done
    if SHOT_DIR="$TMP" node "$HERE/churn.js" "http://127.0.0.1:$CPORT/" \
         "$TMP/churn-roster.txt" "$USER" "$PASSWD"; then
      ok "roster churn"
    else
      fail "roster churn" "see output above"
    fi

    # The read-only walk is NOT here. It used to be: a second full walk with
    # FLOOR_TEST_READONLY=1, watching the stub's call log to prove no control
    # command was issued. It cost ~3 minutes of a 10-minute CI to assert a
    # property about a fleet CI does not have, re-checking navigation, identity
    # and XSS that the walk above checked two minutes earlier.
    #
    # It moved to drill/rehearsal-app.sh, which has real boxes and wraps the
    # real `box` CLI to read the calls. CI tests the plumbing; the drill is what
    # gets to the metal. cli.sh asserts the drill still carries it, so this is a
    # move and not a deletion — a check that leaves CI and lands nowhere is the
    # same as a check that was deleted, and reads better in a commit message.

    # A box changing STATE under an open console. Shares the fast-polling
    # collector above: every other page test enters a console and leaves within
    # one poll, so the live-update path is otherwise untested.
    #
    # But sharing it has an edge: churn.js removes the roster's first box and
    # restores the file in its teardown, and the collector only notices on its
    # next poll. transition.js walks the floor BY ROSTER INDEX, so against the
    # mid-restore snapshot it clicks one cell left of its target — or, on the
    # other side of the poll, finds no working box at all. Wait for the
    # restored fleet to be back in the snapshot before standing on it.
    for _ in $(seq 1 40); do
      floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$CPORT/api/fleet" 2>/dev/null)"
      grep -q '"ff-working"' <<<"$floor_snapshot" && break
      sleep 0.5
    done
    echo
    echo "== state transition"
    if SHOT_DIR="$TMP" node "$HERE/transition.js" "http://127.0.0.1:$CPORT/" "$USER" "$PASSWD"; then
      ok "state transition under an open console"
    else
      fail "state transition under an open console" "see output above"
    fi

    # A fleet of only deliberately-stopped boxes (#203). It has to be its own
    # roster: the assertion is "the alarm counter reads zero", and the fixture
    # fleet is seventeen boxes broken in seventeen ways on purpose. Reuses the
    # churn collector — its roster is the scratch copy those tests already
    # rewrite, and a fourth collector would cost CI a minute to say the same
    # thing. LAST, for the same reason: it leaves that roster at two boxes.
    #
    # ff-paused is re-paused by hand here. `wake-silent` in the collector cases
    # resumes it (test/floor/actions.sh), and the stub keeps that decision in a state
    # file, so by this point in the suite the fixture's paused box is not one.
    echo
    echo "== a disarmed fleet raises no alarm (#203)"
    echo paused > "$FLOOR_STATE/ff-paused.cron"
    printf 'ff-disarmed   grok    builder\nff-paused     codex   reviewer\n' \
      > "$TMP/churn-roster.txt"
    # Both halves, not just the count: the roster shrinking to two is one poll,
    # the re-pause landing in the snapshot can be the next one, and standing on
    # the first alone asserts against a box the collector still thinks is armed.
    for _ in $(seq 1 40); do
      if curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$CPORT/api/fleet" 2>/dev/null \
           | python3 -c "
import json,sys
u=json.load(sys.stdin)['units']
sys.exit(0 if len(u)==2 and all(x['disarmed'] for x in u) and any(x['paused'] for x in u) else 1)"; then
        break
      fi
      sleep 0.5
    done
    if node "$HERE/stopped.js" "http://127.0.0.1:$CPORT/" "$USER" "$PASSWD"; then
      ok "a disarmed fleet raises no alarm"
    else
      fail "a disarmed fleet raises no alarm" "see output above"
    fi
    kill "$SRV3" 2>/dev/null

    # An all-unhired fleet, and the first box hired into it (#204). Its own
    # collector, because it is the one test here that owns BOTH halves of the
    # stub's input: a roster of two, and a private copy of the fleet fixture it
    # rewrites mid-run to hire a box. Reusing the churn collector would have
    # meant editing the fixture every other test in this suite reads.
    #
    # Fast interval: the acceptance criterion is that a console appears on the
    # NEXT POLL with no restart, so the poll is the thing being waited on.
    echo
    echo "== the empty floor, and the first box hired into it (#204)"
    HPORT=$((PORT + 3))
    printf 'hf-nothired   kimi    builder\nhf-absent     kimi    triage\n' \
      > "$TMP/hired-roster.txt"
    printf 'hf-nothired    running  nothired\nhf-absent      absent   working\n' \
      > "$TMP/hired-fixture.txt"
    FLOOR_FIXTURE="$TMP/hired-fixture.txt" \
    CREW_FLOOR_ROSTER="$TMP/hired-roster.txt" \
    CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$HPORT" \
    CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=4 \
    CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
    CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
      python3 "$FLOOR/server/floor.py" >"$TMP/server4.log" 2>&1 &
    SRV4=$!
    for _ in $(seq 1 120); do
      floor_snapshot="$(curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$HPORT/api/fleet" 2>/dev/null)"
      grep -q '"hf-nothired"' <<<"$floor_snapshot" && break
      sleep 0.5
    done
    if SHOT_DIR="$TMP" node "$HERE/hired.js" "http://127.0.0.1:$HPORT/" \
         "$TMP/hired-fixture.txt" "$USER" "$PASSWD"; then
      ok "the empty floor, and the first box hired into it"
    else
      fail "the empty floor, and the first box hired into it" "see output above"
    fi
    kill "$SRV4" 2>/dev/null
  fi
fi

echo
echo "== summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
