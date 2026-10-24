#!/usr/bin/env bash
# fleet-floor/test/boxside.sh — actually RUN the two scripts that normally only
# ever execute inside a box, and check the collector can read what they emit.
#
# Sourced by test/run.sh (which provides ok/fail/t); runnable on its own too.
#
# Why this exists: everything else in the suite drives the collector against
# test/stub-box, which INTERCEPTS `box exec` and answers with what probe.sh is
# believed to produce. That makes 90-odd collector assertions circular — they
# validate the parser against an imitation, and a real bug in probe.sh or in
# the message script would sail straight through. Neither script needs a box to
# run: probe.sh reads files and asks `crontab`/`gh`, and the message script
# needs only a shell and a fake vendor CLI. So they are run for real here, and
# their output is fed to the REAL parser.
#
# The message script is the sharpest edge in the whole change: a nested
# `nohup setsid bash -c '...'` carrying an operator-supplied prompt. If its
# quoting is wrong, the prompt is mangled or — worse — executed.
set -uo pipefail

BS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BS_FLOOR="$(dirname "$BS_HERE")"
BS_ROOT="$(dirname "$BS_FLOOR")"

# Standalone mode: provide the reporters test/run.sh would have given us.
if ! declare -F ok >/dev/null; then
  PASS=0 SKIP=0
  declare -a FAILS=()
  ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
  fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
  skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
  t()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
  BS_STANDALONE=1
fi

BS_TMP="$(mktemp -d)"
# No EXIT trap here: sourced into run.sh, one would fire at ITS exit and, worse,
# a backgrounded subshell would inherit it. The caller's cleanup owns lifetime;
# standalone mode cleans up at the bottom.

echo
echo "== box-side scripts, executed for real"

# --------------------------------------------------------------------------
# probe.sh
# --------------------------------------------------------------------------
BS_H="$BS_TMP/probehome"
mkdir -p "$BS_H/duty/logs"
cp -R "$BS_ROOT/shared/lib" "$BS_H/duty/lib"
echo "crew@0.2.0 (deadbee)" > "$BS_H/duty/VERSION"
printf '# comment\nheavy-duty/ceremony\nheavy-duty/rig\n' > "$BS_H/duty/repos.txt"
BS_NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  echo "$BS_NOW duty run start"
  echo "$BS_NOW heavy-duty/rig: build duty (ready unclaimed=1, whole rounds owed=0)"
  echo "$BS_NOW SESSION START kind=build key=rig#12 timeout=7200s log=/x/a.log"
  echo "$BS_NOW SESSION END kind=build key=rig#12 rc=0 dur=55s outcome=ok"
} > "$BS_H/duty/duty.log"
touch "$BS_H/duty/logs/20260726T090000Z-build-rig_12.log"
# A session that is RUNNING holds a `<slog>.peak` scratch file beside the log
# it is measuring (#473), and removes it before SESSION END — so LOG_DIR is
# not session logs alone for exactly as long as a poll might land in. The
# listing selects on `*.log` so that file never spends one of the forty
# slots, and this is the fixture that says so against the real probe.sh.
touch "$BS_H/duty/logs/20260726T090000Z-build-rig_12.log.peak"
printf '1700000000-11-1\t2026-08-28T09:00:00Z\twarn\tgithub_connection_nodes\t90\t100\theavy-duty/crew#482\tfixture says ::phantom key\n' \
  >"$BS_H/duty/.limit-events"
printf '1700000001-11-2\t2026-08-28T09:00:01Z\terror\tgithub_connection_nodes\t110\t100\theavy-duty/crew#482\tfixture crossed\n' \
  >>"$BS_H/duty/.limit-events"
printf '4\n' >"$BS_H/duty/.limit-events.dropped"
BS_PROBE_BEFORE="$(find "$BS_H/duty" -type f -printf '%P\t%m\t' -exec sha256sum {} \; | sort)"

HOME="$BS_H" DUTY_DIR="$BS_H/duty" \
  bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" \
  > "$BS_TMP/probe.out" 2>"$BS_TMP/probe.err"
t "probe.sh exits 0" 0 "$?"

# The contract that matters is not the text — it is that floor.py's own parser
# gets every key it later reads. A missing key is a TypeError several panels
# deep, long after the poll that caused it.
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_TMP/probe.out" > "$BS_TMP/probe.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
meta, lines = floor.parse_probe(open(sys.argv[1]).read())
need = ("engine", "integrity", "uptime", "now", "gh", "vendor", "suppression", "cron", "paused", "repos", "sessionlogs", "limitdropped", "limit-events", "tick-health")
print("MISSING=%s" % ",".join(k for k in need if k not in meta))
print("ENGINE=%s" % meta.get("engine", ""))
print("UPTIME_OK=%s" % str(meta.get("uptime", "").isdigit()))
print("REPOS=%d" % len(meta.get("repos", "").split()))
print("SESSLOGS=%s" % " ".join(meta.get("sessionlogs", "").split()))
print("LOGLINES=%d" % len(lines))
sess, cur = floor.derive_sessions(lines, time.time())
print("SESSIONS=%d" % len(sess))
print("SESSKEY=%s" % (sess[0]["key"] if sess else ""))
print("QUEUE=%d" % len(floor.derive_queue(lines)))
print("EVENTS=%d" % len(meta.get("limit-events", [])))
print("EVENT_ERROR=%d" % sum("\terror\t" in e for e in meta.get("limit-events", [])))
print("DROPPED=%s" % meta.get("limitdropped", ""))
print("PHANTOM=%s" % meta.get("phantom", "absent"))
health = floor.parse_tick_health(meta.get("tick-health", []))
print("HEALTH=%s" % (health["ticks"] if health else "absent"))
print("HEALTH_KIND=%s" % (health["kinds"][0]["kind"] if health and health["kinds"] else "absent"))
PY
bs_get() { sed -n "s/^$1=//p" "$BS_TMP/probe.parsed"; }
t "probe.sh: parser gets every key it reads" "" "$(bs_get MISSING)"
t "probe.sh: full engine stamp carried through" "crew@0.2.0 (deadbee)" "$(bs_get ENGINE)"
t "probe.sh: uptime is a number"   True "$(bs_get UPTIME_OK)"
t "probe.sh: repos.txt comments stripped" 2 "$(bs_get REPOS)"
t "probe.sh: a running session's .peak scratch file is not a session log" \
  "20260726T090000Z-build-rig_12.log" "$(bs_get SESSLOGS)"
t "probe.sh: log section delimited" 4 "$(bs_get LOGLINES)"
t "probe.sh: sessions parse from real output" 1 "$(bs_get SESSIONS)"
t "probe.sh: session key intact" "rig#12" "$(bs_get SESSKEY)"
t "probe.sh: queue derived from real output" 1 "$(bs_get QUEUE)"
t "probe.sh: carries every durable floor event" 2 "$(bs_get EVENTS)"
t "probe.sh: preserves crossed-limit event text" 1 "$(bs_get EVENT_ERROR)"
t "probe.sh: carries the cumulative drop counter" 4 "$(bs_get DROPPED)"
t "probe.sh: a bare :: word inside the section is not a key" absent "$(bs_get PHANTOM)"
t "probe.sh: shared tick health crosses the real wire" 1 "$(bs_get HEALTH)"
t "probe.sh: reconstructed kind data crosses the real wire" build "$(bs_get HEALTH_KIND)"
BS_PROBE_AFTER="$(find "$BS_H/duty" -type f -printf '%P\t%m\t' -exec sha256sum {} \; | sort)"
t "probe.sh: limit carry leaves DUTY_DIR byte-identical" "$BS_PROBE_BEFORE" "$BS_PROBE_AFTER"

printf '%s\tdraft\theavy-duty/crew#561@abcdef123456\n' \
  "$(( $(date +%s) - 780 ))" >"$BS_H/duty/.builder-suppressed.heavy-duty__crew.draft"
printf '%s\tnear-miss\theavy-duty/box#222@fedcba654321\n' \
  "$(( $(date +%s) - 120 ))" >"$BS_H/duty/.builder-suppressed.heavy-duty__box.near-miss"
HOME="$BS_H" DUTY_DIR="$BS_H/duty" \
  bash "$BS_FLOOR/server/probe.sh" </dev/null >"$BS_TMP/probe-suppressed.out"
case "$(sed -n 's/^::suppression //p' "$BS_TMP/probe-suppressed.out")" in
  7[0-9][0-9]' draft heavy-duty/crew#561@abcdef123456') r1=carried ;;
  *) r1=missing ;;
esac
t "probe.sh: suppression carries age, lane, and PR head" carried "$r1"
t "probe.sh: oldest active suppression episode wins" 1 \
  "$(grep -c 'draft heavy-duty/crew#561@abcdef123456' "$BS_TMP/probe-suppressed.out")"
rm -f "$BS_H/duty/.builder-suppressed.heavy-duty__crew.draft" \
  "$BS_H/duty/.builder-suppressed.heavy-duty__box.near-miss"

# --- engine integrity, end to end (#159, #190) -----------------------------
#
# The collector suite asserts the wire VALUE of ::integrity and cannot assert
# its truth: stub-box has no installed tree to hash, so it answers from the
# fixture. Here the REAL engine-manifest.sh runs under the REAL probe.sh over a
# tree this file controls, which is the only place the hash can prove anything
# — the same division shared/test/run.sh makes for the `crew status` half.
bs_integrity() {  # DUTY_DIR -> the one word this probe emitted
  HOME="$BS_H" DUTY_DIR="$1" \
    bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" 2>/dev/null \
    | sed -n 's/^::integrity //p' | head -1
}
# The state every box is in on the day content stamping ships: an engine, and
# no tool to check it with. UNVERIFIED, never modified — a fleet that reads
# modified everywhere the day this lands has learned the word means nothing.
t "probe.sh: an engine with no manifest tool is unverified, never modified" \
  unverified "$(bs_integrity "$BS_H/duty")"

mkdir -p "$BS_H/duty/bin"
cp "$BS_ROOT/shared/bin/engine-manifest.sh" "$BS_H/duty/bin/engine-manifest.sh"
chmod +x "$BS_H/duty/bin/engine-manifest.sh"
DUTY_DIR="$BS_H/duty" "$BS_H/duty/bin/engine-manifest.sh" --record
t "probe.sh: a recorded, untouched engine is current" current "$(bs_integrity "$BS_H/duty")"

# The failure the instrument exists to catch: a hotfix applied by hand to a box
# whose VERSION still names what it shipped with. A comment line, so the file it
# lands in stays runnable — what is under test is the hash, not the syntax.
printf '# hotfix applied by hand\n' >> "$BS_H/duty/bin/engine-manifest.sh"
t "probe.sh: a hand-edited engine reports modified" modified "$(bs_integrity "$BS_H/duty")"
# The half that makes the verdict worth rendering: the CLAIM does not move when
# the files do, so a tile showing the version alone shows a box that was
# hotfixed as though nothing had happened.
t "probe.sh: the version claim does not move with the files" \
  "crew@0.2.0 (deadbee)" "$(head -1 "$BS_H/duty/VERSION")"

# A box with no engine at all: absent, and it must not borrow the fallback's
# `unverified` — there is nothing installed to be unverified about.
BS_BARE="$BS_TMP/barehome"
mkdir -p "$BS_BARE/duty"
t "probe.sh: a box with no engine reports absent" absent "$(bs_integrity "$BS_BARE/duty")"

# --- the box vitals record, carried verbatim (#483 D1) ---------------------
#
# The collector suite drives parse_vitals against a record IT wrote, which
# proves the parser and nothing about the selection. This runs the real
# probe.sh over a real duty.log, which is the only place the two halves of
# "the two readers cannot disagree" meet: the newest record, unchanged.
bs_vitals() {  # DUTY_DIR -> the ::vitals line this probe emitted
  HOME="$BS_H" DUTY_DIR="$1" \
    bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" 2>/dev/null \
    | sed -n 's/^::vitals //p' | head -1
}
# Every box on the day this lands, and every box for its first tick: a duty.log
# with no record in it. EMPTY, and the collector renders no section — never a
# hardware reading nobody took.
t "probe.sh: a log with no vitals record carries none" "" "$(bs_vitals "$BS_H/duty")"

BS_VITALS_OLD="VITALS ts=2026-08-27T09:00:00Z cores=2 disk_pct=48 platform=linux"
BS_VITALS_NEW="VITALS ts=2026-08-28T09:00:00Z cores=2 load1=0.10 mem_total_mb=3850"
BS_VITALS_NEW="$BS_VITALS_NEW mem_shared_mb=103 mem_avail_mb=3128 swap_active_mb=0"
BS_VITALS_NEW="$BS_VITALS_NEW swap_configured_mb=8192 disk_total_mb=29696 disk_used_mb=14254"
BS_VITALS_NEW="$BS_VITALS_NEW disk_pct=48 disk_series=2026-08-01T12:50:01+00:00@5,2026-08-27T18:35:01+00:00@48"
BS_VITALS_NEW="$BS_VITALS_NEW platform=linux os=debian-13"
BS_VITALS_NEW="$BS_VITALS_NEW finding=swap-configured-inactive:configured_mb=8192,active_mb=0"
{ printf '%s\n' "$BS_VITALS_OLD"
  # An unclean stop below the engine can leave NUL bytes in duty.log. The
  # newest records after them remain authoritative; the probe reads the file
  # as text instead of letting grep suppress every later match (#608).
  printf '\0\0\0'
  echo "$BS_NOW duty run start"
  printf '%s\n' "$BS_VITALS_NEW"
  echo "$BS_NOW heavy-duty/rig: build duty (ready unclaimed=1, whole rounds owed=0)"; } \
  >> "$BS_H/duty/duty.log"
# Keep the newest record outside the transported 600-line tail. Binary safety
# must not turn the whole-file selection rule into a cheaper, incomplete scan.
for BS_FILLER in $(seq 1 601); do
  printf 'fixture noise %s\n' "$BS_FILLER"
done >> "$BS_H/duty/duty.log"

# VERBATIM, and the NEWEST. Byte-for-byte equality is the assertion, not "it
# contains the fields": a probe that reformatted the line would put the floor
# one word away from `crew status` and the criterion is that they cannot be.
t "probe.sh: the newest vitals record is carried verbatim" \
  "$BS_VITALS_NEW" "$(bs_vitals "$BS_H/duty")"

bs_tickage() {  # DUTY_DIR -> the numeric ::tickage value this probe emitted
  HOME="$BS_H" DUTY_DIR="$1" \
    bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" 2>/dev/null \
    | sed -n 's/^::tickage //p' | head -1
}
BS_BINARY_FRESH_AGE="$(bs_tickage "$BS_H/duty")"
case "$BS_BINARY_FRESH_AGE" in
  ''|*[!0-9]*) r1=invalid ;;
  *) [ "$BS_BINARY_FRESH_AGE" -le 10 ] && r1=fresh || r1=stale ;;
esac
t "probe.sh: a fresh timestamp after NUL bytes remains fresh" fresh "$r1"

# The alarm remains intact: binary-safe means later records are visible, not
# automatically healthy. With an old trailing timestamp the same damaged log
# must still report an age beyond two five-minute tick boundaries.
BS_BINARY_SILENT="$BS_TMP/binary-silent"
cp -R "$BS_H/duty" "$BS_BINARY_SILENT"
{
  printf '%s duty run start\n' "$(date -u -d '@'$(( $(date +%s) - 4000 )) '+%Y-%m-%dT%H:%M:%SZ')"
  printf '\0\0\0'
  printf '%s duty run end\n' "$(date -u -d '@'$(( $(date +%s) - 3900 )) '+%Y-%m-%dT%H:%M:%SZ')"
} > "$BS_BINARY_SILENT/duty.log"
BS_BINARY_SILENT_AGE="$(bs_tickage "$BS_BINARY_SILENT")"
case "$BS_BINARY_SILENT_AGE" in
  ''|*[!0-9]*) r1=invalid ;;
  *) [ "$BS_BINARY_SILENT_AGE" -ge 600 ] && r1=silent || r1=fresh ;;
esac
t "probe.sh: a genuinely stale timestamp after NUL bytes stays silent" silent "$r1"

# The fixture log puts an OLDER record above the newest one and two ordinary
# lines after it, so neither `tail -1` of the file nor the first match lands on
# the right line. And one `::vitals` line, never two: parse_probe splits keys
# on newlines, so a second line would be read as a key of its own and the
# record would arrive truncated at the collector.
t "probe.sh: exactly one vitals line reaches the wire" 1 \
  "$(HOME="$BS_H" DUTY_DIR="$BS_H/duty" bash "$BS_FLOOR/server/probe.sh" \
     < "$BS_ROOT/shared/conf/agents/claude.conf" 2>/dev/null \
     | grep -c '^::vitals ')"

# The collector's parser, over what the real probe really emitted — the half
# the stub can only imitate.
# The record travels as argv, not on stdin: `python3 - <<PY` is already
# spending stdin on the script itself, and a `sys.stdin.read()` there comes
# back empty — which reads exactly like a probe that emitted nothing.
BS_SERVER="$BS_FLOOR/server" python3 - "$(bs_vitals "$BS_H/duty")" \
  > "$BS_TMP/vitals.parsed" 2>&1 <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
from floor.units import parse_vitals
v = parse_vitals(sys.argv[1])
print("TS=%s" % v["ts"])
print("CORES=%s" % v["fields"].get("cores", ""))
print("SERIES=%d" % len(v["series"]))
print("FIRSTPCT=%s" % (v["series"][0]["pct"] if v["series"] else ""))
print("FINDING=%s" % (v["findings"][0] if v["findings"] else ""))
PY
bs_vget() { sed -n "s/^$1=//p" "$BS_TMP/vitals.parsed"; }
t "probe.sh: the collector parses the real record" "2026-08-28T09:00:00Z" "$(bs_vget TS)"
t "probe.sh: the carried record keeps its fields" 2 "$(bs_vget CORES)"
t "probe.sh: the backfilled disk series survives the wire" 2 "$(bs_vget SERIES)"
t "probe.sh: the series' oldest reading survives the wire" 5 "$(bs_vget FIRSTPCT)"
t "probe.sh: the finding survives the wire, worded by the record" \
  "swap-configured-inactive: configured_mb=8192, active_mb=0" "$(bs_vget FINDING)"

# --------------------------------------------------------------------------
# the message script — the operator prompt must survive as ONE argv element
# --------------------------------------------------------------------------
BS_M="$BS_TMP/msghome"
mkdir -p "$BS_M/duty/logs" "$BS_M/bin"
cat > "$BS_TMP/agent.conf" <<'EOF'
TIMEOUT_ATTENTION=1800
BOT_PATH_PREPEND="$HOME/.local/bin"
BOT_CLI_CMD=(fake-cli --flag -p)
bot_cli_probe() { true; }
bot_session_acted() { return 1; }
EOF
cat > "$BS_M/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$3" > "${BS_TIMEOUT_FILE:?}"
exec /usr/bin/timeout "$@"
EOF
cat > "$BS_M/bin/fake-cli" <<'EOF'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#"
printf 'LAST=%s\n' "${*: -1}"
[ -z "${BS_STAMP_FILE:-}" ] || printf '%s\n' "$DUTY_SESSION_STAMP" > "$BS_STAMP_FILE"
EOF
chmod +x "$BS_M/bin/fake-cli" "$BS_M/bin/timeout"

# Every metacharacter an operator might type, plus non-ASCII. Single-quoted on
# purpose: the payload must reach the box LITERAL, so bash must not expand it
# here — expanding it would make the test send something tamer than it claims.
# shellcheck disable=SC2016
BS_PROMPT='check PR #40 "now"; rm -rf /tmp/floor-boxside-pwned; $(id) `whoami` & | ; é'
# The prompt path carries the collector's per-request token now, so the
# standalone run has to mint one the same way and write to the matching name.
BS_TOK="boxsidetest$$"

BS_SH="$BS_TMP/message.sh"
BS_PROMPT_FILE="$BS_M/duty/.floor-prompt.$BS_TOK"
BS_SERVER="$BS_FLOOR/server" BS_TOK="$BS_TOK" BS_PROMPT="$BS_PROMPT" \
  BS_PROMPT_FILE="$BS_PROMPT_FILE" \
  python3 - "$BS_SH" "$BS_TMP/expected-floor-prompt" <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
prompt = floor.floor_message_prompt(os.environ["BS_PROMPT"])
open(sys.argv[1], "w").write(floor.MESSAGE_SH.replace("__TOK__", os.environ["BS_TOK"]))
open(sys.argv[2], "w").write(prompt)
open(os.environ["BS_PROMPT_FILE"], "w").write(prompt)
PY

HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  BS_STAMP_FILE="$BS_TMP/message.stamp" \
  BS_TIMEOUT_FILE="$BS_TMP/message.timeout" \
  bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
t "message: script exits 0" 0 "$?"

# The session is detached on purpose, so wait for its END marker rather than
# racing it.
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done

if [ -e /tmp/floor-boxside-pwned ]; then
  fail "message: prompt cannot execute" "/tmp/floor-boxside-pwned was created"
  rm -f /tmp/floor-boxside-pwned
else
  ok "message: prompt cannot execute"
fi

# The log name carries the per-request token now (…-operator-floor-<tok>.log),
# which is what stops two same-second sessions overwriting each other.
BS_LOG_FILE="$(find "$BS_M/duty/logs" -name '*operator-floor*.log' -print -quit)"
BS_LOG="$(cat "$BS_LOG_FILE" 2>/dev/null)"
t "message: prompt arrives as ONE argv element" "ARGC=3" "$(printf '%s\n' "$BS_LOG" | sed -n 's/^\(ARGC=[0-9]*\)$/\1/p')"
t "message: envelope precedes operator text byte-identically" \
  "$(cat "$BS_TMP/expected-floor-prompt")" \
  "$(printf '%s\n' "$BS_LOG" | sed '1d; 2s/^LAST=//')"
t "message: dispatch carries its exact session stamp" "${BS_LOG_FILE##*/}" \
  "$(cat "$BS_TMP/message.stamp")"

if grep -q 'SESSION START kind=operator key=floor' "$BS_M/duty/duty.log"; then
  ok "message: writes a SESSION START marker"
else
  fail "message: writes a SESSION START marker" "$(cat "$BS_M/duty/duty.log")"
fi
BS_START="$(grep 'SESSION START kind=operator' "$BS_M/duty/duty.log")"
t "message: one resolved timeout drives record and wall" \
  "$(sed -n 's/.* timeout=\([0-9]*\)s .*/\1/p' <<<"$BS_START")" \
  "$(cat "$BS_TMP/message.timeout")"
if grep -q 'SESSION END kind=operator key=floor rc=0 .* outcome=ok' "$BS_M/duty/duty.log"; then
  ok "message: writes a SESSION END marker with rc"
else
  fail "message: writes a SESSION END marker with rc" "$(cat "$BS_M/duty/duty.log")"
fi
BS_END="$(grep 'SESSION END kind=operator' "$BS_M/duty/duty.log")"
t "message: SESSION END records final log bytes" "$(wc -c < "$BS_LOG_FILE" | tr -d ' ')" \
  "$(sed -n 's/.* log=\([^ ]*\).*/\1/p' <<<"$BS_END")"
t "message: SESSION END records no surviving stamped process" 0 \
  "$(sed -n 's/.* left=\([^ ]*\).*/\1/p' <<<"$BS_END")"
case "$BS_END" in
  *' reply_tail='*' log='*' left='*) r1='reply_tail log left' ;;
  *) r1=WRONG-ORDER ;;
esac
t "message: evidence fields follow reply_tail in order" 'reply_tail log left' "$r1"

# An operator session must show up in the console's history like any other, so
# the markers it writes have to survive the collector's own parser.
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_M/duty/duty.log" > "$BS_TMP/msg.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
sess, cur = floor.derive_sessions(open(sys.argv[1]).read().splitlines(), time.time())
print("N=%d" % len(sess))
print("KIND=%s" % (sess[0]["kind"] if sess else ""))
print("OUT=%s" % (sess[0]["out"] if sess else ""))
print("ACTED=%s" % (sess[0]["acted"] if sess else ""))
print("REPLY=%s" % (sess[0]["reply"] if sess else ""))
PY
t "message: its markers parse back as a session" 1 "$(sed -n 's/^N=//p' "$BS_TMP/msg.parsed")"
t "message: session kind is 'operator'" operator "$(sed -n 's/^KIND=//p' "$BS_TMP/msg.parsed")"
t "message: successful no-action session parses as no-op" no "$(sed -n 's/^ACTED=//p' "$BS_TMP/msg.parsed")"
t "message: final reply tail parses for the floor" "$BS_PROMPT" "$(sed -n 's/^REPLY=//p' "$BS_TMP/msg.parsed")"

# The envelope is a required shipped input, not an optional hint. If packaging
# or a later refactor drops it, fail before launching a raw operator message.
BS_SERVER="$BS_FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
# The one call site here that does NOT use the pre-split `import floor`, and
# the reason is worth the line: this case REBINDS module globals, and the
# compatibility block restores reading the surface, not writing it. Assigning
# floor.FLOOR_ENVELOPE sets a package attribute do_command never reads, so the
# 394bdad form of this test would quietly stop testing the envelope and start
# reporting 'unknown box'. floor/init.sh pins that seam as a declared limit.
import floor.actions
floor.actions.FLOOR_ENVELOPE = "/definitely/missing/fragment-floor-envelope.txt"
floor.actions.read_roster = lambda: [{"box": "test-box"}]
status, result = floor.actions.do_command(
    [], {"action": "message", "box": "test-box", "prompt": "operator text"})
if status != 500 or "floor message envelope unavailable" not in result.get("error", ""):
    raise SystemExit("missing envelope did not fail the message action loudly")
PY
t "message: missing envelope fails loudly" 0 "$?"

if grep -Fq 'model_reasoning_effort="medium"' "$BS_ROOT/shared/conf/agents/codex.conf"; then
  ok "message: codex profile pins medium reasoning effort"
else
  fail "message: codex profile pins medium reasoning effort" "pin missing"
fi

# A profile without the optional action hook must stay honest: successful is
# not evidence of action, and absence of a classifier is never a false no-op.
sed '/^bot_session_acted()/d' "$BS_TMP/agent.conf" > "$BS_TMP/agent-hookless.conf"
: > "$BS_M/duty/duty.log"
cp "$BS_TMP/expected-floor-prompt" "$BS_M/duty/.floor-prompt.$BS_TOK"
HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  BS_TIMEOUT_FILE="$BS_TMP/message-hookless.timeout" \
  bash "$BS_SH" < "$BS_TMP/agent-hookless.conf" >/dev/null 2>&1
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done
if grep -q 'SESSION END kind=operator key=floor rc=0 .* outcome=ok acted=unknown ' "$BS_M/duty/duty.log"; then
  ok "message: hookless profile records acted=unknown"
else
  fail "message: hookless profile records acted=unknown" "$(cat "$BS_M/duty/duty.log")"
fi

# A failing vendor CLI must be recorded as FAILED with its real rc, not swallowed.
cat > "$BS_M/bin/fake-cli" <<'EOF'
#!/usr/bin/env bash
echo boom >&2; exit 3
EOF
chmod +x "$BS_M/bin/fake-cli"
: > "$BS_M/duty/duty.log"
# MESSAGE_SH consumes the prompt file (rm after read), so the second run needs
# its own — which is the point of the per-request path.
cp "$BS_TMP/expected-floor-prompt" "$BS_M/duty/.floor-prompt.$BS_TOK"
HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  BS_TIMEOUT_FILE="$BS_TMP/message-failed.timeout" \
  bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done
if grep -q 'SESSION END kind=operator key=floor rc=3 .* outcome=FAILED' "$BS_M/duty/duty.log"; then
  ok "message: a failed session is recorded FAILED with its rc"
else
  fail "message: a failed session is recorded FAILED with its rc" "$(cat "$BS_M/duty/duty.log")"
fi

# #537 — the empty operator override follows the largest session budget in
# scope. Drive MESSAGE_SH itself so these rows cover the shell resolution,
# not a second implementation in the test.
bs_operator_timeout_case() { # NAME EXPECTED CONFIG
  local name="$1" expected="$2" config="$3" home="$BS_TMP/timeout-$1" token="timeout$1$$"
  local script="$BS_TMP/timeout-$1.sh" actual=""
  mkdir -p "$home/duty/logs" "$home/bin"
  cp "$BS_M/bin/fake-cli" "$BS_M/bin/timeout" "$home/bin/"
  BS_SERVER="$BS_FLOOR/server" BS_TOKEN="$token" python3 - "$script" <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
from floor.actions import MESSAGE_SH
open(sys.argv[1], "w").write(MESSAGE_SH.replace("__TOK__", os.environ["BS_TOKEN"]))
PY
  printf 'operator timeout test\n' > "$home/duty/.floor-prompt.$token"
  HOME="$home" DUTY_DIR="$home/duty" PATH="$home/bin:$PATH" \
    BS_TIMEOUT_FILE="$home/wall" bash "$script" <<<"$config" >/dev/null 2>&1
  for _ in $(seq 1 40); do
    grep -q 'SESSION END kind=operator' "$home/duty/duty.log" 2>/dev/null && break
    sleep 0.1
  done
  actual="$(sed -n 's/.* timeout=\([0-9]*\)s .*/\1/p' "$home/duty/duty.log" | head -1)|$(cat "$home/wall" 2>/dev/null)"
  t "message: $name operator timeout" "$expected|$expected" "$actual"
}

# shellcheck disable=SC2016  # These are bytes sourced later under the case HOME.
BS_BASE_CONF='BOT_PATH_PREPEND="$HOME/bin"
BOT_CLI_CMD=(fake-cli)'
BS_DEFAULT_CONF="$(cat "$BS_ROOT/shared/conf/fleet.defaults.conf")"
BS_BUILDER_CONF="$(cat "$BS_ROOT/shared/conf/roles/builder.conf")"
BS_TRIAGE_CONF="$(cat "$BS_ROOT/shared/conf/roles/triage.conf")"
BS_REVIEWER_CONF="$(cat "$BS_ROOT/shared/conf/roles/reviewer.conf")"
bs_operator_timeout_case builder 3600 "$BS_DEFAULT_CONF"$'\n'"$BS_BASE_CONF"$'\n'"$BS_BUILDER_CONF"
bs_operator_timeout_case triage 3000 "$BS_DEFAULT_CONF"$'\n'"$BS_BASE_CONF"$'\n'"$BS_TRIAGE_CONF"
bs_operator_timeout_case reviewer 2700 "$BS_DEFAULT_CONF"$'\n'"$BS_BASE_CONF"$'\n'"$BS_REVIEWER_CONF"
bs_operator_timeout_case no-role 1800 "$BS_DEFAULT_CONF"$'\n'"$BS_BASE_CONF"
TIMEOUT_AMBIENT_ONLY=9999 bs_operator_timeout_case ambient-excluded 1800 \
  "$BS_DEFAULT_CONF"$'\n'"$BS_BASE_CONF"
bs_operator_timeout_case fleet-override 4100 "$BS_DEFAULT_CONF"$'\nTIMEOUT_OPERATOR=4100\n'"$BS_BASE_CONF"$'\n'"$BS_BUILDER_CONF"

# Prove the winning value comes from the role layer, not merely from a later
# assignment in a synthetic stream: ask Fleet to build the stream from an
# independent operator definition with fleet=4100 and reviewer=4200.
BS_LAYERED_DIR="$BS_TMP/operator-timeout-config"
mkdir -p "$BS_LAYERED_DIR/roles"
printf 'fixture claude reviewer\n' > "$BS_LAYERED_DIR/fleet.roster"
printf 'heavy-duty/crew\n' > "$BS_LAYERED_DIR/repos.txt"
printf 'TIMEOUT_OPERATOR=4100\n' > "$BS_LAYERED_DIR/fleet.conf"
printf 'TIMEOUT_OPERATOR=4200\nTIMEOUT_REVIEW=2700\n' > "$BS_LAYERED_DIR/roles/reviewer.conf"
BS_ROLE_OVERRIDE_CONF="$(CREW_CONFIG_DIR="$BS_LAYERED_DIR" BS_SERVER="$BS_FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
from floor.fleet import Fleet
print(Fleet(3600).operator_conf("claude", "reviewer"), end="")
PY
)"
bs_operator_timeout_case role-override 4200 "$BS_ROLE_OVERRIDE_CONF"$'\n'"$BS_BASE_CONF"

# Drive the roster's real comma-joined representation through Fleet and then
# MESSAGE_SH. Both role profiles must survive the transport, and 3600 wins.
BS_MULTI_ROLE_CONF="$(BS_SERVER="$BS_FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
from floor.fleet import Fleet
print(Fleet(3600).operator_conf("claude", "builder,reviewer"), end="")
PY
)"
bs_operator_timeout_case multi-role 3600 "$BS_MULTI_ROLE_CONF"$'\n'"$BS_BASE_CONF"

# All TIMEOUT_* variables in the shipped layers are session budgets today.
# Pin the census so a future non-session variable cannot silently inflate the
# max; its author must either rename it or deliberately update this contract.
BS_TIMEOUT_NAMES="$(sed -n 's/^[[:space:]]*\(TIMEOUT_[A-Z0-9_]*\)=.*/\1/p' \
  "$BS_ROOT/shared/conf/fleet.defaults.conf" "$BS_ROOT/shared/conf/agents/"*.conf \
  "$BS_ROOT/shared/conf/roles/"*.conf | sort -u | tr '\n' ' ')"
t "message: TIMEOUT_* census contains session budgets only" \
  "TIMEOUT_ATTENTION TIMEOUT_BUILD TIMEOUT_CIRED TIMEOUT_HYGIENE TIMEOUT_MENTION TIMEOUT_OPERATOR TIMEOUT_REBASE TIMEOUT_RELEASE TIMEOUT_RESUME TIMEOUT_REVIEW TIMEOUT_TRIAGE " \
  "$BS_TIMEOUT_NAMES"

# --------------------------------------------------------------------------
# PAUSE_SH / RESUME_SH — run for real against a real crontab(1) stand-in.
#
# This is the pair #188 was about, and it is exactly the circularity this file
# exists to break: every other assertion about pause and resume is made against
# test/stub-box's imitation of them, so the bug — `grep -c` exits 1 on a zero
# count, and it was the last command, so the count WAS the verdict — could not
# be seen from the collector side at all. Here the scripts run, against a
# crontab whose contents the test controls, and the exit status is read.
# --------------------------------------------------------------------------
BS_C="$BS_TMP/cronbin"; mkdir -p "$BS_C"
BS_CRON="$BS_TMP/crontab.state"
# Only the two forms floor.py's scripts use: `-l` to read, `-` to replace from
# stdin. Anything else is a script doing something this stand-in has not been
# shown to model, and must fail loudly rather than be quietly accepted.
# `-l` with no crontab exits 1 the way cron(8)'s does — that is the real
# zero-line case, and swallowing it here would fake the bug away.
#
# The install is ATOMIC (temp file, then rename), like the real crontab(1),
# which stages into the spool and renames. Truncating in place would be a
# stand-in bug rather than a script bug, but it is the one that bites hardest
# if the scripts ever go back to piping a live read into a live write
# (`crontab -l | sed | crontab -`, both ends open at once): a `cat > $STATE`
# empties the file the reader at the head of the same pipeline is still
# reading, and the box loses its crontab. The scripts snapshot the crontab
# first and write from the snapshot, so they do not do that today.
cat > "$BS_C/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [ -s "$CRONTAB_STATE" ] || { echo "no crontab for tester" >&2; exit 1; }
      cat "$CRONTAB_STATE" ;;
  -)  if [ "${CRONTAB_RO:-0}" = 1 ]; then cat >/dev/null; echo "crontab: installing new crontab: permission denied" >&2; exit 1; fi
      tmp="$(mktemp)"; cat > "$tmp"; mv -f "$tmp" "$CRONTAB_STATE" ;;
  *)  echo "crontab: unsupported argument ${1:-}" >&2; exit 1 ;;
esac
EOF
chmod +x "$BS_C/crontab"

BS_SERVER="$BS_FLOOR/server" BS_OUT="$BS_TMP" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
out = os.environ["BS_OUT"]
open(os.path.join(out, "pause.sh"), "w").write(floor.PAUSE_SH)
open(os.path.join(out, "resume.sh"), "w").write(floor.RESUME_SH)
PY

# bs_ctl <pause|resume> -> writes $BS_TMP/ctl.out and $BS_TMP/ctl.err, echoes rc
bs_ctl() {
  local rc=0
  PATH="$BS_C:$PATH" CRONTAB_STATE="$BS_CRON" CRONTAB_RO="${BS_RO:-0}" \
    bash "$BS_TMP/$1.sh" >"$BS_TMP/ctl.out" 2>"$BS_TMP/ctl.err" || rc=$?
  echo "$rc"
}
bs_armed()  { grep -cE '^[^#].*tick\.sh' "$BS_CRON" 2>/dev/null || true; }
bs_paused() { grep -c '^#CREW-FLOOR-PAUSED' "$BS_CRON" 2>/dev/null || true; }

# shellcheck disable=SC2016  # a crontab line is stored unexpanded; $HOME is cron's
printf '*/5 * * * * $HOME/duty/bin/tick.sh\n17 2 * * * unrelated-job\n' > "$BS_CRON"
t "pause: exits 0 on an armed box"      0 "$(bs_ctl pause)"
t "pause: comments the tick line out"   1 "$(bs_paused)"
t "pause: no live tick line remains"    0 "$(bs_armed)"
t "pause: says what it did"    "paused 1" "$(cat "$BS_TMP/ctl.out")"
# The unrelated line is somebody else's job. A control that quietly rewrote it
# would be a far worse bug than the one being fixed.
t "pause: leaves unrelated crontab lines alone" 1 "$(grep -c '^17 2 \* \* \* unrelated-job$' "$BS_CRON")"

t "resume: exits 0"                     0 "$(bs_ctl resume)"
t "resume: restores the live line"      1 "$(bs_armed)"
t "resume: no commented line remains"   0 "$(bs_paused)"
t "resume: says what it did"  "resumed 1" "$(cat "$BS_TMP/ctl.out")"

# #188 itself. Every drill box is in this state for its whole run — cron is
# disarmed before any tick — so this path is the one the drill always took, and
# it used to exit 1 and be rendered "command refused".
printf '17 2 * * * unrelated-job\n' > "$BS_CRON"
t "pause: a box with no armed line exits 0"  0 "$(bs_ctl pause)"
case "$(cat "$BS_TMP/ctl.out")" in
  "nothing to pause"*) ok "pause: a box with no armed line says nothing to pause" ;;
  *) fail "pause: a box with no armed line says nothing to pause" "$(cat "$BS_TMP/ctl.out")" ;;
esac
t "pause: nothing to pause changes nothing" "17 2 * * * unrelated-job" "$(cat "$BS_CRON")"

t "resume: nothing paused exits 0"  0 "$(bs_ctl resume)"
case "$(cat "$BS_TMP/ctl.out")" in
  "nothing to resume"*) ok "resume: nothing paused says so" ;;
  *) fail "resume: nothing paused says so" "$(cat "$BS_TMP/ctl.out")" ;;
esac

# The count is what THIS call moved, not the post-state total. A box carrying
# a `#CREW-FLOOR-PAUSED` line from an earlier pause AND one armed line pauses
# exactly one line; reporting the total would say `paused 2`. Nothing in the
# fleet produces this crontab today — a second pause short-circuits to
# `nothing to pause` — which is why it is asserted here rather than left to a
# scenario that cannot reach it (kimi, round 1).
# shellcheck disable=SC2016
printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n*/5 * * * * $HOME/duty/bin/other-tick.sh\n' > "$BS_CRON"
t "pause: a pre-paused line is not counted as this call's work" 0 "$(bs_ctl pause)"
t "pause: counts only the lines it commented"        "paused 1" "$(cat "$BS_TMP/ctl.out")"
t "pause: the pre-existing marker is left as it was"          2 "$(bs_paused)"

# Symmetric on the way back: resume moves both commented lines, and says 2 —
# the number it uncommented, not the number of live lines it can see after.
t "resume: exits 0 with two paused lines"    0 "$(bs_ctl resume)"
t "resume: counts only the lines it restored" "resumed 2" "$(cat "$BS_TMP/ctl.out")"
t "resume: both lines are live"              2 "$(bs_armed)"

# A live tick line that was never paused must not be counted by resume either.
# shellcheck disable=SC2016
printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n7 * * * * $HOME/duty/bin/other-tick.sh\n' > "$BS_CRON"
t "resume: exits 0 alongside an already-live line"  0 "$(bs_ctl resume)"
t "resume: an already-live line is not this call's" "resumed 1" "$(cat "$BS_TMP/ctl.out")"

# No crontab AT ALL: `crontab -l` exits 1, which is the shape that made the
# zero count indistinguishable from a broken box in the first place.
: > "$BS_CRON"
t "pause: no crontab at all is still not a failure" 0 "$(bs_ctl pause)"

# ...and a write that genuinely fails must redden the row and SAY why, which is
# the whole point of not spending the exit status on a count.
# shellcheck disable=SC2016
printf '*/5 * * * * $HOME/duty/bin/tick.sh\n' > "$BS_CRON"
BS_RO=1
t "pause: a refused crontab write exits non-zero" 1 "$(bs_ctl pause)"
case "$(cat "$BS_TMP/ctl.err")" in
  *"crontab write failed"*) ok "pause: a refused write states its reason" ;;
  *) fail "pause: a refused write states its reason" "$(cat "$BS_TMP/ctl.err")" ;;
esac
BS_RO=0

rm -rf "$BS_TMP"

# --------------------------------------------------------------------------
# probe.sh in DEGRADED boxes. These are the shapes a real fleet actually has
# during setup and after failures, and probe.sh runs with `set -u` only (never
# -e) precisely so it reports them instead of returning nothing.
# --------------------------------------------------------------------------
bs_probe() {  # bs_probe <home> -> writes $BS_TMP/deg.out, echoes rc
  local h="$1" rc=0
  HOME="$h" DUTY_DIR="$h/duty" \
    bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" \
    > "$BS_TMP/deg.out" 2>"$BS_TMP/deg.err" || rc=$?
  echo "$rc"
}
bs_key() { sed -n "s/^::$1 //p" "$BS_TMP/deg.out" | head -1; }
bs_has() { grep -q "^::$1" "$BS_TMP/deg.out"; }

# A box created but never hired: no ~/duty at all.
BS_BARE="$BS_TMP/bare"; mkdir -p "$BS_BARE"
t "degraded: no duty dir -> still exits 0" 0 "$(bs_probe "$BS_BARE")"
t "degraded: no duty dir -> empty engine" "" "$(bs_key engine)"
if bs_has logstart && bs_has logend; then ok "degraded: no duty dir -> log section still delimited"
else fail "degraded: no duty dir -> log section still delimited" "$(cat "$BS_TMP/deg.out")"; fi
if bs_has uptime; then ok "degraded: no duty dir -> uptime still reported"
else fail "degraded: no duty dir -> uptime still reported" "missing"; fi

# duty.log with CRLF line endings — probe.sh strips \r so the parser's
# anchored timestamp regex still matches.
BS_CRLF="$BS_TMP/crlf"; mkdir -p "$BS_CRLF/duty"
printf '%s duty run start\r\n%s SESSION END kind=build key=x#1 rc=0 dur=9s outcome=ok\r\n' \
  "$BS_NOW" "$BS_NOW" > "$BS_CRLF/duty/duty.log"
bs_probe "$BS_CRLF" >/dev/null
if grep -q $'\r' "$BS_TMP/deg.out"; then
  fail "degraded: CRLF stripped from duty.log" "carriage returns survived into the record"
else ok "degraded: CRLF stripped from duty.log"; fi
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_TMP/deg.out" > "$BS_TMP/crlf.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
meta, lines = floor.parse_probe(open(sys.argv[1]).read())
sess, _ = floor.derive_sessions(lines, time.time())
print("N=%d" % len(sess))
PY
t "degraded: CRLF log still parses a session" 1 "$(sed -n 's/^N=//p' "$BS_TMP/crlf.parsed")"

# An unreadable duty.log (wrong owner/mode after a botched restore).
BS_UNREAD="$BS_TMP/unread"; mkdir -p "$BS_UNREAD/duty"
echo "$BS_NOW duty run start" > "$BS_UNREAD/duty/duty.log"
chmod 000 "$BS_UNREAD/duty/duty.log"
t "degraded: unreadable duty.log -> still exits 0" 0 "$(bs_probe "$BS_UNREAD")"
if bs_has logend; then ok "degraded: unreadable duty.log -> record stays well-formed"
else fail "degraded: unreadable duty.log -> record stays well-formed" "$(cat "$BS_TMP/deg.out")"; fi
chmod 644 "$BS_UNREAD/duty/duty.log"

# A big duty.log: the probe must bound what it ships, or every poll drags
# megabytes per box across box exec.
BS_BIG="$BS_TMP/big"; mkdir -p "$BS_BIG/duty"
awk -v n="$BS_NOW" 'BEGIN{for(i=0;i<8000;i++) print n" filler line "i}' > "$BS_BIG/duty/duty.log"
bs_probe "$BS_BIG" >/dev/null
BS_LINES="$(sed -n '/^::logstart$/,/^::logend$/p' "$BS_TMP/deg.out" | sed '1d;$d' | wc -l)"
if [ "$BS_LINES" -le 600 ]; then ok "degraded: big duty.log is capped at 600 lines ($BS_LINES)"
else fail "degraded: big duty.log is capped at 600 lines" "shipped $BS_LINES"; fi

# --------------------------------------------------------------------------
# The flow-reported signals. These exist BECAUSE the probe no longer tests a
# credential or shells out to anything: every one is a file the duty engine
# writes and probe.sh only reads. stub-box imitates all four, so without these
# assertions the collector would be verified entirely against the imitation —
# and `emit_probe` claiming `::gh flowing` proves nothing about whether the
# real script ever emits it.
# --------------------------------------------------------------------------

# The healthy shape: engine present, no failure recorded.
BS_FLOW="$BS_TMP/flow"; mkdir -p "$BS_FLOW/duty"
echo "crew@0.4.1 (feedbee)" > "$BS_FLOW/duty/VERSION"
echo "$BS_NOW duty run start" > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
t "flow: no failure recorded -> gh nofail"     nofail "$(bs_key gh)"
t "flow: no failure recorded -> vendor nofail" nofail "$(bs_key vendor)"
# The box reports the AGE and the host applies the rule — so the threshold
# lives once, in floor.py, instead of a third time inside the box in bash.
BS_AGE="$(bs_key tickage)"
if [ -n "$BS_AGE" ] && [ "$BS_AGE" -ge 0 ] && [ "$BS_AGE" -lt 120 ]; then
  ok "flow: a fresh tick is reported as an age ($BS_AGE s)"
else fail "flow: a fresh tick is reported as an age" "got '$BS_AGE'"; fi

# THE finding this state exists for. VERSION is written once by install.sh and
# never touched again, so it proves the engine was INSTALLED, not that it has
# RUN. A box hired last month, cron since disarmed, token expired last week
# records no rejection because nothing runs to be rejected — and reported
# `flowing`, the exact "logged-out box renders green" failure the value was
# introduced to prevent.
printf '%s duty run start\n' "$(date -u -d '@'"$(( $(date +%s) - 4000 ))" '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
BS_OLD="$(bs_key tickage)"
if [ -n "$BS_OLD" ] && [ "$BS_OLD" -gt 600 ]; then
  ok "flow: a long-dead engine reports an age past the death rule ($BS_OLD s)"
else fail "flow: a long-dead engine reports an age past the death rule" "got '$BS_OLD'"; fi
# The BOX still says nofail — it does not decide. floor.py ages this into
# `stale`, and floor/ping.sh asserts that it does.
t "flow: the box reports a fact, not a verdict" nofail "$(bs_key gh)"
# A recorded rejection still outranks staleness: it is a fact, not an absence.
echo "$BS_NOW 401 Bad credentials" > "$BS_FLOW/duty/.auth-fail.gh"
bs_probe "$BS_FLOW" >/dev/null
t "flow: a rejection outranks everything" missing "$(bs_key gh)"
rm -f "$BS_FLOW/duty/.auth-fail.gh"
printf '%s duty run start\n' "$BS_NOW" > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
if bs_has authfail; then fail "flow: healthy box emits no authfail" "$(bs_key authfail-gh)"
else ok "flow: healthy box emits no authfail"; fi

# No engine: nothing has run, so nothing is KNOWN. The distinction from
# `flowing` is the whole point — a box that has never ticked cannot have a
# working credential inferred from the absence of a failure.
BS_NOENG="$BS_TMP/noeng"; mkdir -p "$BS_NOENG/duty"
bs_probe "$BS_NOENG" >/dev/null
t "flow: no engine -> gh unknown, never flowing"     unknown "$(bs_key gh)"
t "flow: no engine -> vendor unknown, never flowing" unknown "$(bs_key vendor)"

# A recorded gh rejection.
echo "$BS_NOW 401 Bad credentials" > "$BS_FLOW/duty/.auth-fail.gh"
bs_probe "$BS_FLOW" >/dev/null
t "flow: gh rejection -> gh missing" missing "$(bs_key gh)"
if [ -n "$(bs_key authfail-gh)" ]; then ok "flow: gh rejection -> reason carried to the operator"
else fail "flow: gh rejection -> reason carried to the operator" "empty"; fi
# The marker names ONE service; the other must not be condemned with it.
t "flow: a gh rejection does not mark the vendor missing" nofail "$(bs_key vendor)"
rm -f "$BS_FLOW/duty/.auth-fail.gh"

# lockheld: a duty run in flight, and the half-written file that a probe
# landing mid-`date +%s >` will read. A bogus age here would render as a
# 56-year-old session and read as a catastrophic wedge.
printf '%s' "$(( $(date +%s) - 2820 ))" > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
BS_HELD="$(bs_key lockheld)"
if [ "${BS_HELD:-0}" -ge 2815 ] && [ "${BS_HELD:-0}" -le 2830 ]; then
  ok "flow: lockheld is the age of the run in flight ($BS_HELD s)"
else fail "flow: lockheld is the age of the run in flight" "got '$BS_HELD'"; fi
echo "not-a-number" > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
if bs_has lockheld; then fail "flow: a corrupt lock stamp emits nothing" "$(bs_key lockheld)"
else ok "flow: a corrupt lock stamp emits nothing"; fi
: > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
if bs_has lockheld; then fail "flow: an empty lock stamp emits nothing" "$(bs_key lockheld)"
else ok "flow: an empty lock stamp emits nothing"; fi
rm -f "$BS_FLOW/duty/.duty.lock.since"

# The probe must not have reacquired a network dependency. `gh` and the vendor
# CLIs are on the box's PATH, so a future edit calling either would pass every
# assertion above and quietly cost 450ms per box per poll again.
# Anchored to COMMAND POSITION, not to the word appearing anywhere: `gh` and
# `vendor` are also legitimate wire-key names in this file, and a bare word
# match condemned `for svc in gh vendor`. Comments are stripped first so the
# rationale above each check cannot trip the check.
BS_NETRE='(^|[;&|(]|\bif |\bthen |\belse )[[:space:]]*(gh|bot_cli_probe|claude|codex|kimi)([[:space:]]|$)'
BS_PROBE_CODE="$(sed 's/#.*//' "$BS_FLOOR/server/probe.sh")"
if grep -qE "$BS_NETRE" <<<"$BS_PROBE_CODE"; then
  fail "flow: probe.sh invokes no network command" \
       "$(sed 's/#.*//' "$BS_FLOOR/server/probe.sh" | grep -nE "$BS_NETRE")"
else ok "flow: probe.sh invokes no network command"; fi
# ...and the guard is worth nothing if it cannot see the thing it forbids.
if grep -qE "$BS_NETRE" <<<'if gh auth status; then :; fi'; then
  ok "flow: the no-network guard detects a reintroduced gh call"
else fail "flow: the no-network guard detects a reintroduced gh call" "guard is blind"; fi

# --------------------------------------------------------------------------
# cli/crew's auth_from_flow, EXECUTED FOR REAL.
#
# The third box-side script, and it arrives for the reason the first two did.
# test/stub-box answers `crew status`'s read by hand-writing the field line it
# believes auth_from_flow produces, so every cli.sh assertion about that table
# is circular in exactly the way #188 was: the script could stop emitting a
# field entirely and nothing on the collector side would notice. It needs no
# box — pure local file reads, one `crontab -l`, and an awk pass over the log.
#
# The case it must survive is #624's: the in-flight `SESSION START`'s own
# `timeout=` is what `crew status` grades a held lock against, and the token is
# OPTIONAL, appears among tokens the engine keeps appending, and belongs to one
# depth of a START/END stack. None of those three can be checked by grepping
# the source, and none of them is visible to the stub.
# --------------------------------------------------------------------------
BS_FLOW_SH="$(awk '
  /^auth_from_flow\(\) \{$/     { inf = 1; next }
  inf && /^  bxn "\$1" .$/      { body = 1; next }
  body && /^  . 2>\/dev\/null/  { body = 0; inf = 0 }
  body                          { print }
' "$BS_ROOT/cli/crew")"
# The script is a single-quoted shell word inside cli/crew, so its own literal
# single quotes arrive escaped. Undo that, or the two comments carrying one
# are a syntax error the moment this runs.
BS_FLOW_SH="${BS_FLOW_SH//\'\\\'\'/\'}"
if [ -n "$BS_FLOW_SH" ] && grep -q 'SESSION START' <<<"$BS_FLOW_SH" \
   && bash -n <<<"$BS_FLOW_SH" 2>/dev/null; then
  ok "flow-cli: the box script could be extracted from cli/crew"
else
  fail "flow-cli: the box script could be extracted from cli/crew" \
       "extraction produced $(wc -l <<<"$BS_FLOW_SH") lines that do not parse"
fi

# A crontab(1) stand-in of its own: the pair built for PAUSE_SH lived in the
# $BS_TMP the degraded section already removed and rebuilt.
BS_FC="$BS_TMP/flowcron"; mkdir -p "$BS_FC"
cat > "$BS_FC/crontab" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-l" ] || { echo "unsupported: ${1:-}" >&2; exit 1; }
[ -s "$CRONTAB_STATE" ] || { echo "no crontab for tester" >&2; exit 1; }
cat "$CRONTAB_STATE"
EOF
chmod +x "$BS_FC/crontab"
# shellcheck disable=SC2016  # a crontab line is stored unexpanded; $HOME is cron's
printf '*/5 * * * * $HOME/duty/bin/tick.sh\n' > "$BS_FC/state"

# bs_flow <home> -> the one field line the script prints, \r stripped exactly
# as the caller strips it. `head -1` is what `read -r` does to the trailing
# blank line the script emits.
bs_flow() {
  HOME="$1" PATH="$BS_FC:$PATH" CRONTAB_STATE="$BS_FC/state" \
    bash -c "$BS_FLOW_SH" 2>/dev/null | tr -d '\r' | head -1
}
# bs_flow_log <home> LINES... — a duty.log built from `<seconds-ago> <rest>`.
bs_flow_log() {
  local h="$1" line ago rest; shift
  mkdir -p "$h/duty"
  : > "$h/duty/duty.log"
  for line in "$@"; do
    ago="${line%% *}"; rest="${line#* }"
    printf '%s %s\n' \
      "$(date -u -d "@$(( $(date +%s) - ago ))" '+%Y-%m-%dT%H:%M:%SZ')" "$rest" \
      >> "$h/duty/duty.log"
  done
}
bs_flow_field() { awk -v n="$1" '{print $n}' <<<"$2"; }

BS_FH="$BS_TMP/flowcli"; mkdir -p "$BS_FH/duty"
echo "crew@0.4.1 (feedbee)" > "$BS_FH/duty/VERSION"
printf '%s' "$(( $(date +%s) - 2400 ))" > "$BS_FH/duty/.duty.lock.since"

# #624's own box: a `build` in flight, declaring the 3600s ceiling
# roles/builder.conf gives that lane, with the two tokens the engine appends
# after it. The ceiling must come out even though `timeout=` is neither the
# first token nor the last.
bs_flow_log "$BS_FH" \
  "3700 duty run start" \
  "3690 SESSION START kind=build key=crew#624 timeout=3600s log=/h/g.log holder=tick sid=8f1c0a2e"
BS_FLOW_LINE="$(bs_flow "$BS_FH")"
t "flow-cli: the script emits thirteen fields" 13 "$(awk '{print NF}' <<<"$BS_FLOW_LINE")"
t "flow-cli: the in-flight ceiling is carried out" 3600 \
  "$(bs_flow_field 13 "$BS_FLOW_LINE")"
t "flow-cli: ...beside its lane" build "$(bs_flow_field 12 "$BS_FLOW_LINE")"
# The half a field count cannot see. These are the two fields the ceiling was
# appended AFTER, and #189 is the record of what pushing one off costs: a
# paused box emitted an extra line, `read` saw only the first, and the operator
# was told to re-hire a box they had just paused.
t "flow-cli: session-active still lands in field 10" 1 \
  "$(bs_flow_field 10 "$BS_FLOW_LINE")"
BS_FLOW_LOCK="$(bs_flow_field 11 "$BS_FLOW_LINE")"
if [ -n "$BS_FLOW_LOCK" ] && [ "$BS_FLOW_LOCK" -ge 2400 ] && [ "$BS_FLOW_LOCK" -lt 2460 ]; then
  ok "flow-cli: the lock age still lands in field 11 ($BS_FLOW_LOCK s)"
else
  fail "flow-cli: the lock age still lands in field 11" "got '$BS_FLOW_LOCK'"
fi

# An engine older than #538 wrote no `timeout=` at all. -1 is "nothing
# declared", and it is what makes an un-upgraded box's reading identical to
# the one it got before this change.
bs_flow_log "$BS_FH" \
  "800 duty run start" \
  "790 SESSION START kind=build key=crew#77 log=/h/h.log"
t "flow-cli: a START with no timeout= declares no ceiling" "build -1" \
  "$(awk '{print $12, $13}' <<<"$(bs_flow "$BS_FH")")"

# The token is SCANNED, so a line that carries it in another position still
# answers, and one that merely contains the letters does not.
bs_flow_log "$BS_FH" \
  "600 SESSION START kind=triage key=board holder=tick sid=abc timeout=2400s log=/h/i.log"
t "flow-cli: the ceiling is scanned, not counted off the line" "triage 2400" \
  "$(awk '{print $12, $13}' <<<"$(bs_flow "$BS_FH")")"
bs_flow_log "$BS_FH" \
  "600 SESSION START kind=build key=crew#9 attn_timeout=99s log=/h/j.log"
t "flow-cli: a lookalike token declares no ceiling" "build -1" \
  "$(awk '{print $12, $13}' <<<"$(bs_flow "$BS_FH")")"

# The numbers belong to a DEPTH, not to the file: an END pops the session it
# closes and the enclosing START's own ceiling is what remains in flight.
bs_flow_log "$BS_FH" \
  "7000 SESSION START kind=build key=crew#a timeout=3600s log=/h/a.log" \
  "300 SESSION START kind=review key=crew#b timeout=2400s log=/h/b.log" \
  "60 SESSION END kind=review key=crew#b rc=0 dur=240s outcome=ok"
t "flow-cli: an END pops its own START's ceiling" "build 3600" \
  "$(awk '{print $12, $13}' <<<"$(bs_flow "$BS_FH")")"

# Nothing in flight: no ceiling to declare, whatever the closed sessions said.
bs_flow_log "$BS_FH" \
  "600 SESSION START kind=build key=crew#c timeout=3600s log=/h/c.log" \
  "60 SESSION END kind=build key=crew#c rc=0 dur=540s outcome=ok"
BS_FLOW_LINE="$(bs_flow "$BS_FH")"
t "flow-cli: a closed session declares nothing" "- -1" \
  "$(awk '{print $12, $13}' <<<"$BS_FLOW_LINE")"
t "flow-cli: ...and reports no session in flight" 0 \
  "$(bs_flow_field 10 "$BS_FLOW_LINE")"

# The other way a session stops being in flight, and until round 1 it was the
# one the wire lied about: an orphan past the six-hour bound is a crashed
# session, not live work, and the floor holds NO kind and NO ceiling for it —
# its `cur` is None. The script used to emit that dead START's numbers anyway,
# inertly, correct only because `cmd_status` gates them on field 10. A field
# that is wrong-but-unread is a second source of truth waiting for a reader,
# which is the thing auth_from_flow exists to refuse, so it now says what the
# floor says (round 1, claude-bot).
bs_flow_log "$BS_FH" \
  "25000 duty run start" \
  "24990 SESSION START kind=build key=crew#d timeout=3600s log=/h/d.log holder=tick sid=dead1"
BS_FLOW_LINE="$(bs_flow "$BS_FH")"
t "flow-cli: an orphan past the six-hour bound declares nothing" "- -1" \
  "$(awk '{print $12, $13}' <<<"$BS_FLOW_LINE")"
t "flow-cli: ...and reports no session in flight either" 0 \
  "$(bs_flow_field 10 "$BS_FLOW_LINE")"

# bs_flow_cur <log> — `derive_sessions`'s in-flight session over the same file
# the shell just scanned, as `<kind> <timeout>` or `none`. One reader of the
# floor, for the same reason duty_log_of is one writer of the fixtures: two
# spellings of "what the floor makes of this log" could drift apart and leave
# every cross-reader case below comparing a box against itself.
bs_flow_cur() {
  BS_SERVER="$BS_FLOOR/server" python3 - "$1" <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
_, cur = floor.derive_sessions(open(sys.argv[1]).read().splitlines(), time.time())
print("%s %s" % (cur["kind"], cur["timeout"]) if cur else "none")
PY
}

t "flow-cli: ...and the floor makes nothing of that log either" none \
  "$(bs_flow_cur "$BS_FH/duty/duty.log")"

# The floor reads the same evidence, and this is where the two readers are held
# together on it: `derive_sessions` over the same log must name the same lane
# and the same ceiling the shell just scanned. A private regex on either side
# is the disagreement auth_from_flow exists to remove.
bs_flow_log "$BS_FH" \
  "3690 SESSION START kind=build key=crew#624 timeout=3600s log=/h/g.log holder=tick sid=8f1c0a2e"
BS_FLOW_CUR="$(bs_flow_cur "$BS_FH/duty/duty.log")"
t "flow-cli: both readers scan one line to the same ceiling" "$BS_FLOW_CUR" \
  "$(awk '{print $12, $13}' <<<"$(bs_flow "$BS_FH")")"

# ...and the same claim where the two readers' LANGUAGES disagree about the
# digits rather than about the line (round 1, codex-bot). `TIMEOUT_BUILD=0900`
# is a role conf a host may hold: nothing between it and `session.sh`'s
# `timeout=${tmo}s` canonicalises, and GNU `timeout 0900` runs that session.
# Neither reader rewrites the box's record — D1 is that the record is read —
# so the wire carries `0900` and each reader turns it into a number itself.
# Python reads a leading zero as decimal. Bash reads it as OCTAL, so a
# `crew status` without the `10#` took `0900` into `$(( ))` as an invalid
# octal literal and died out of the middle of the roster loop, on a box the
# floor rendered fine. The pair below is the wire and the agreement, stated
# separately because only the second one is about both readers.
bs_flow_log "$BS_FH" \
  "600 duty run start" \
  "590 SESSION START kind=build key=crew#624 timeout=0900s log=/h/z.log holder=tick sid=0a1b2c3d"
BS_FLOW_LINE="$(bs_flow "$BS_FH")"
t "flow-cli: a leading-zero ceiling goes out as the record spells it" "build 0900" \
  "$(awk '{print $12, $13}' <<<"$BS_FLOW_LINE")"
# The floor's absolute reading is pinned as well as the agreement: two readers
# that were broken the same way would satisfy an agreement test on its own.
t "flow-cli: the floor reads those digits as nine hundred" "build 900" \
  "$(bs_flow_cur "$BS_FH/duty/duty.log")"
t "flow-cli: ...and the CLI's own canonicalisation reaches the same number" 900 \
  "$(( 10#$(bs_flow_field 13 "$BS_FLOW_LINE") ))"

# ...and the same claim where one reader has no ROOM for the record rather
# than a different reading of it (round 2, codex-bot). Reachable by the same
# argument as `0900`: the conf is operator-editable, nothing between it and
# `timeout=${tmo}s` range-checks, and `timeout 999999999999999999999999 true`
# exits 0. The producer's job is unchanged and that is the point — the wire
# carries the record's own digits whatever either reader can hold, which is D1.
bs_flow_log "$BS_FH" \
  "800 duty run start" \
  "790 SESSION START kind=build key=crew#624 timeout=999999999999999999999999s log=/h/h.log holder=tick sid=1f2e3d4c"
BS_FLOW_LINE="$(bs_flow "$BS_FH")"
t "flow-cli: a ceiling past bash's range goes out as the record spells it" \
  "build 999999999999999999999999" "$(awk '{print $12, $13}' <<<"$BS_FLOW_LINE")"
t "flow-cli: the floor holds every one of those digits" \
  "build 999999999999999999999999" "$(bs_flow_cur "$BS_FH/duty/duty.log")"
# The DIVERGENCE, pinned rather than left to be re-derived. This is the one
# place the two readers cannot be made to reach the same number, and stating
# it here is what keeps a later "simplification" back to plain arithmetic from
# looking harmless: `$(( 10# ))` does not fail on these digits, it WRAPS, and
# a wrapped ceiling is a number that is nobody's record. `cmd_status` saturates
# instead, which reaches the same VERDICT as the floor for every lock age that
# can exist — asserted where verdicts run, in cli.sh and floor/units.sh.
BS_FLOW_WIRE="$(bs_flow_field 13 "$BS_FLOW_LINE")"
if [ "$(( 10#$BS_FLOW_WIRE ))" = "$BS_FLOW_WIRE" ]; then
  BS_FLOW_HOLD=held
else
  BS_FLOW_HOLD=wraps
fi
t "flow-cli: ...which bash's own arithmetic cannot, hence the saturation" \
  wraps "$BS_FLOW_HOLD"

if [ -n "${BS_STANDALONE:-}" ]; then
  echo
  echo "== box-side summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi

# --------------------------------------------------------------------------
# The PING script, EXECUTED FOR REAL.
#
# stub-box answers the ping by pattern-matching the command and always exits
# 0, so every collector assertion about it is circular: removing the `exit 0`
# from the real script changes nothing the stub can see. This is the only
# place the actual shell runs, and the case it must survive is the ORDINARY
# one — a healthy idle box has no .duty.lock.since, `cat` on a missing file
# exits 1, and a non-zero rc is what the ping tier reads as "this guest is
# dead". Get it wrong and a healthy fleet renders UNREACHABLE.
# --------------------------------------------------------------------------
BS_PING="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; sys.stdout.write(floor.PING_SH)')"
if [ -n "$BS_PING" ]; then ok "ping: the script could be extracted from floor.py"
else fail "ping: the script could be extracted from floor.py" "PING_SH is empty"; fi

bs_ping() {  # bs_ping <home> -> writes $BS_TMP/ping.out, echoes rc
  local rc=0
  HOME="$1" DUTY_DIR="$1/duty" sh -c "$BS_PING" \
    > "$BS_TMP/ping.out" 2>"$BS_TMP/ping.err" || rc=$?
  echo "$rc"
}
bs_ping_key() { sed -n "s/^$1 //p" "$BS_TMP/ping.out" | head -1; }

# The normal state of a healthy idle box: engine present, nothing in flight.
BS_PH="$BS_TMP/pinghome"; mkdir -p "$BS_PH/duty"
t "ping: an idle box with NO lock file exits 0" 0 "$(bs_ping "$BS_PH")"
t "ping: ...and reports an empty lock field"    "" "$(bs_ping_key l)"
if [ -n "$(bs_ping_key u)" ]; then ok "ping: uptime rides along"
else fail "ping: uptime rides along" "no u line: $(cat "$BS_TMP/ping.out")"; fi

# A run in flight. duty.sh writes an ABSOLUTE stamp (`date +%s`) and every
# consumer wants the AGE — asserting only that the field is non-empty is what
# let the raw stamp through, and ~1.7e9 compared against STUCK_AFTER_S marked
# every live duty run STUCK with a multi-year duration.
printf '%s' "$(( $(date +%s) - 2820 ))" > "$BS_PH/duty/.duty.lock.since"
t "ping: a run in flight exits 0" 0 "$(bs_ping "$BS_PH")"
BS_L="$(bs_ping_key l)"
if [ -n "$BS_L" ] && [ "$BS_L" -ge 2815 ] && [ "$BS_L" -le 2830 ]; then
  ok "ping: the lock rides along as an AGE, not a timestamp ($BS_L s)"
else
  fail "ping: the lock rides along as an AGE, not a timestamp" \
       "got '$BS_L' — a raw stamp is ~1.7e9 and marks every live run STUCK"
fi

# THE regression. A run that started THIS SECOND must be unremarkable: age ~0,
# far below STUCK_AFTER_S. Asserted against floor.py's real threshold rather
# than a number written here, so the two cannot drift apart.
date +%s > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
BS_FRESH="$(bs_ping_key l)"
BS_STUCK_AT="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; print(floor.STUCK_AFTER_S)')"
if [ -n "$BS_FRESH" ] && [ "$BS_FRESH" -ge 0 ] && [ "$BS_FRESH" -lt "$BS_STUCK_AT" ]; then
  ok "ping: a run that just started is NOT stuck ($BS_FRESH s < $BS_STUCK_AT)"
else
  fail "ping: a run that just started is NOT stuck" \
       "got '$BS_FRESH' against a $BS_STUCK_AT s threshold"
fi
# ...and an old one still escalates, or the guard above could pass by never
# reporting anything at all.
printf '%s' "$(( $(date +%s) - 4000 ))" > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
BS_OLDL="$(bs_ping_key l)"
if [ -n "$BS_OLDL" ] && [ "$BS_OLDL" -gt "$BS_STUCK_AT" ]; then
  ok "ping: a genuinely old lock still crosses the threshold ($BS_OLDL s)"
else
  fail "ping: a genuinely old lock still crosses the threshold" "got '$BS_OLDL'"
fi

# A torn or skewed stamp must report NOTHING rather than a bogus age — duty.sh
# rewrites this file at the top of every run, so a probe can land mid-write.
echo "not-a-number" > "$BS_PH/duty/.duty.lock.since"
t "ping: a corrupt lock stamp exits 0" 0 "$(bs_ping "$BS_PH")"
t "ping: ...and reports no age"        "" "$(bs_ping_key l)"
printf '%s' "$(( $(date +%s) + 5000 ))" > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
t "ping: a future stamp (clock skew) reports no age" "" "$(bs_ping_key l)"

# An unreadable lock file must not fail the ping: the passenger is optional,
# the liveness claim is not.
chmod 000 "$BS_PH/duty/.duty.lock.since"
t "ping: an unreadable lock file still exits 0" 0 "$(bs_ping "$BS_PH")"
chmod 644 "$BS_PH/duty/.duty.lock.since"
rm -f "$BS_PH/duty/.duty.lock.since"

# A created-but-never-hired box has no duty dir at all.
t "ping: a box with no duty dir exits 0" 0 "$(bs_ping "$BS_TMP/nosuchhome")"

# ...and floor.py must parse what the script REALLY emits, not what it is
# believed to emit — the circularity this file exists to break.
bs_ping "$BS_PH" >/dev/null
BS_PARSED="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; f = floor.parse_ping(open(sys.argv[1]).read()); print("uptime=%s lockheld=%s" % (f["uptime"] is not None, f["lockheld"]))' "$BS_TMP/ping.out")"
t "ping: floor.py parses the real script's output" "uptime=True lockheld=None" "$BS_PARSED"
