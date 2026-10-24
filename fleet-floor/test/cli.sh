# shellcheck shell=bash  # sourced by run.sh, so it has no shebang of its own
# fleet-floor/test/cli.sh — `crew floor` argument handling and preflight.
#
# Sourced by test/run.sh (which provides ok/fail/t/skip/jqf); runnable standalone.
#
# The CLI is the only part an operator actually types, and it is where the
# auth decision is made: a page that can power-cycle boxes must never come up
# without a password. None of that was covered by the collector or page tests,
# which start floor.py directly and hand it an env.
set -uo pipefail

CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL_FLOOR="$(dirname "$CL_HERE")"
CL_ROOT="$(dirname "$CL_FLOOR")"

if ! declare -F ok >/dev/null; then
  PASS=0 SKIP=0
  declare -a FAILS=()
  ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
  fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
  skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
  t()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
  # jqf EXPR — run.sh's copy, byte for byte: `d` is the JSON read from stdin.
  # Guarded with the rest so it never displaces the aggregate's own (#664).
  jqf()  { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
  # Every name this file calls that the block above does not define lands
  # here, by name, at run time — the one census that cannot be fooled by prose
  # (#664). jqf's 2>/dev/null hid exactly this "command not found" for weeks.
  CL_NOT_FOUND="$(mktemp)"
  command_not_found_handle() { printf '%s\n' "$1" >>"$CL_NOT_FOUND"; return 127; }
  CL_STANDALONE=1
fi

CL_RC=0
CL_TMP="$(mktemp -d)"
mkdir -p "$CL_TMP/bin"
# `crew floor` calls need_box first, so a `box` must exist on PATH; it is never
# actually invoked by the paths under test here.
ln -sf "$CL_HERE/stub-box" "$CL_TMP/bin/box"
export FLOOR_FIXTURE="$CL_HERE/fixtures/fleet.txt"
export FLOOR_STATE="$CL_TMP/state"
export CREW_FLOOR_ROSTER="$CL_HERE/fixtures/roster.txt"

# The fleet DEFINITION, which is a different thing from the roster above:
# `crew floor` and floor.py refuse under the examples fallback (#244), so
# every case here that starts either process needs an operator config dir.
# run.sh exports one for the whole suite; this builds cli.sh's own only when
# it is run standalone. Never overriding run.sh's is deliberate — this file
# ends by removing $CL_TMP, and the browser cases that run after run.sh
# sources it would then be pointed at a directory that no longer exists.
if [ -z "${CREW_CONFIG_DIR:-}" ]; then
  mkdir -p "$CL_TMP/opconfig"
  cp "$CL_HERE/fixtures/roster.txt" "$CL_TMP/opconfig/fleet.roster"
  printf 'FLEET_HUMAN=fixture\n' >"$CL_TMP/opconfig/fleet.conf"
  printf 'heavy-duty/crew\n' >"$CL_TMP/opconfig/repos.txt"
  export CREW_CONFIG_DIR="$CL_TMP/opconfig"
fi

echo
echo "== crew floor CLI"

# crew_floor ARGS... — runs a short-lived `crew floor`, leaving its combined
# output in $CL_TMP/out and its exit status in $CL_RC.
#
# Deliberately NOT `CL_OUT="$(crew_floor ...)"`: command substitution runs the
# function in a subshell, so a CL_RC assigned inside it never reaches the
# caller and every exit-status assertion silently reads 0. That cost a round.
crew_floor() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" timeout 4 "$CL_ROOT/cli/crew" floor "$@" \
    </dev/null > "$CL_TMP/out" 2>&1 || CL_RC=$?
}
cl_out() { cat "$CL_TMP/out"; }

# --- argument errors must be refused, loudly and before anything starts -----
crew_floor --bogus; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ] && grep -q "unknown option" <<<"$CL_OUT"; then
  ok "cli: unknown option refused"
else
  fail "cli: unknown option refused" "rc=$CL_RC out=$CL_OUT"
fi

crew_floor --port; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ]; then ok "cli: --port with no value refused"
else fail "cli: --port with no value refused" "rc=0, out=$CL_OUT"; fi

crew_floor --pass; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ]; then ok "cli: --pass with no value refused"
else fail "cli: --pass with no value refused" "rc=0, out=$CL_OUT"; fi

# --- help ------------------------------------------------------------------
crew_floor --help; CL_OUT="$(cl_out)"
t "cli: --help exits 0" 0 "$CL_RC"
if grep -q "IP:PORT" <<<"$CL_OUT"; then ok "cli: --help explains what it serves"
else fail "cli: --help explains what it serves" "$CL_OUT"; fi
# The help must not stop mid-sentence — this block is extracted by a sed range,
# which is exactly the kind of thing that silently truncates when edited.
CL_OUT_LAST="$(tail -1 <<<"$CL_OUT")"
if grep -q '\.$' <<<"$CL_OUT_LAST"; then ok "cli: --help is not truncated"
else fail "cli: --help is not truncated" "last line: $(printf '%s' "$CL_OUT" | tail -1)"; fi
if grep -q "^cmd_floor" <<<"$CL_OUT"; then
  fail "cli: --help stops before the code" "the function body leaked into help"
else ok "cli: --help stops before the code"; fi

# --- the banner an operator reads -----------------------------------------
crew_floor --local --port 8899; CL_OUT="$(cl_out)"
if grep -q "http://127.0.0.1:8899/" <<<"$CL_OUT"; then ok "cli: --local prints a loopback URL"
else fail "cli: --local prints a loopback URL" "$CL_OUT"; fi
if grep -qi "loopback only" <<<"$CL_OUT"; then ok "cli: --local says it is loopback only"
else fail "cli: --local says it is loopback only" "$CL_OUT"; fi
if grep -q "plain HTTP" <<<"$CL_OUT"; then
  fail "cli: no cleartext warning on loopback" "warned about the network for a loopback bind"
else ok "cli: no cleartext warning on loopback"; fi

crew_floor --port 8898; CL_OUT="$(cl_out)"
if grep -q "plain HTTP" <<<"$CL_OUT"; then ok "cli: warns that a bound port sends the password in clear"
else fail "cli: warns that a bound port sends the password in clear" "$CL_OUT"; fi

# The byline is the launcher's identity, not a value floor.py derives from its
# own path. Start a scratch serving tree twice with VERSION changed between
# starts: the API must carry the exact `crew --version` answer each time.
CL_VERSION_ROOT="$CL_TMP/version-root"
mkdir -p "$CL_VERSION_ROOT/cli"
cp "$CL_ROOT/cli/crew" "$CL_VERSION_ROOT/cli/crew"
ln -s "$CL_ROOT/shared" "$CL_VERSION_ROOT/shared"
ln -s "$CL_ROOT/fleet-floor" "$CL_VERSION_ROOT/fleet-floor"
CL_VERSION_PORT=8879
cl_start_version_floor() {
  PATH="$CL_TMP/bin:$PATH" CREW_CONFIG_DIR="$CREW_CONFIG_DIR" \
  CREW_FLOOR_ROSTER="$CL_HERE/fixtures/roster.txt" CREW_FLOOR_PASS=version-test \
    "$CL_VERSION_ROOT/cli/crew" floor --local --port "$CL_VERSION_PORT" \
      >"$CL_TMP/version-floor.log" 2>&1 &
  CL_VERSION_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS -u operator:version-test \
      "http://127.0.0.1:$CL_VERSION_PORT/api/fleet" >"$CL_TMP/version.json" 2>/dev/null && return 0
    kill -0 "$CL_VERSION_PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}
cl_stop_version_floor() {
  kill "$CL_VERSION_PID" 2>/dev/null || true
  wait "$CL_VERSION_PID" 2>/dev/null || true
}
for CL_VERSION in 7.6.5-fixture 7.6.6-fixture; do
  printf '%s\n' "$CL_VERSION" >"$CL_VERSION_ROOT/VERSION"
  if cl_start_version_floor; then
    CL_GOT_VERSION="$(jqf "d['version']" <"$CL_TMP/version.json")"
    t "cli: floor restart serves exact crew --version output for $CL_VERSION" \
      "crew $CL_VERSION ($CL_VERSION_ROOT)" "$CL_GOT_VERSION"
    cl_stop_version_floor
  else
    fail "cli: floor restart serves exact crew --version output for $CL_VERSION" \
      "collector did not start: $(cat "$CL_TMP/version-floor.log")"
    kill "${CL_VERSION_PID:-}" 2>/dev/null || true
    wait "${CL_VERSION_PID:-}" 2>/dev/null || true
  fi
done

# This is a one-way handoff from the launcher. An absent private environment
# value degrades visibly; floor.py must not grow a second VERSION reader.
CL_FLOOR_FN="$(sed -n '/^cmd_floor()/,/^}/p' "$CL_ROOT/cli/crew")"
# shellcheck disable=SC2016  # the launcher must contain this literal handoff
case "$CL_FLOOR_FN" in
  *'CREW_FLOOR_VERSION="$(version)"'*) ok "cli: floor hands its exact version answer to the server" ;;
  *) fail "cli: floor hands its exact version answer to the server" "version handoff missing" ;;
esac
# Takes every collector source, because the split put them in a package and a
# guard that reads only the entry point would pass on a VERSION read anywhere
# else in it (#508).
collector_derives_version() {
  grep -qE '(open|os\.path\.join|Path|pathlib).*VERSION|VERSION.*(read_text|read_bytes)|CREW_ROOT.*VERSION' "$@"
}
if collector_derives_version "$CL_FLOOR/server/floor.py" "$CL_FLOOR"/server/floor/*.py; then
  fail "collector: version stays launcher-owned" "the collector reads VERSION itself"
else
  ok "collector: version stays launcher-owned"
fi
printf '%s\n' 'value = (Path(ROOT) / "VERSION").read_text()' >"$CL_TMP/pathlib-version-reader.py"
if collector_derives_version "$CL_TMP/pathlib-version-reader.py"; then
  ok "collector: launcher-owned guard catches pathlib VERSION reads"
else
  fail "collector: launcher-owned guard catches pathlib VERSION reads" "pathlib read escaped the guard"
fi
printf '%s\n' 'value = open(os.path.join(ROOT, "VERSION")).read()' >"$CL_TMP/pathjoin-version-reader.py"
if collector_derives_version "$CL_TMP/pathjoin-version-reader.py"; then
  ok "collector: launcher-owned guard catches path-join VERSION reads"
else
  fail "collector: launcher-owned guard catches path-join VERSION reads" "path-join read escaped the guard"
fi

# --- the auth decision -----------------------------------------------------
# A generated password must be generated, not a constant: two runs, two values.
crew_floor --local --port 8897
CL_P1="$(cl_out | sed -n 's/^  password  \([^ ]*\) .*/\1/p')"
crew_floor --local --port 8896
CL_P2="$(cl_out | sed -n 's/^  password  \([^ ]*\) .*/\1/p')"
if [ -n "$CL_P1" ] && [ -n "$CL_P2" ] && [ "$CL_P1" != "$CL_P2" ]; then
  ok "cli: generated passwords differ between runs"
else
  fail "cli: generated passwords differ between runs" "[$CL_P1] vs [$CL_P2]"
fi
if [ "${#CL_P1}" -ge 16 ]; then ok "cli: generated password is long enough (${#CL_P1})"
else fail "cli: generated password is long enough" "${#CL_P1} chars"; fi

crew_floor --local --port 8895 --pass hunter2; CL_OUT="$(cl_out)"
if grep -q "hunter2" <<<"$CL_OUT"; then
  fail "cli: an explicit password is not echoed" "the password was printed back"
else ok "cli: an explicit password is not echoed"; fi

# The collector itself must refuse to serve without one, whatever starts it.
CL_RC2=0
CREW_FLOOR_PASS="" CREW_FLOOR_PORT=8894 timeout 5 python3 "$CL_FLOOR/server/floor.py" \
  > "$CL_TMP/nopass.out" 2>&1 || CL_RC2=$?
if [ "$CL_RC2" -ne 0 ] && grep -q "refusing to serve" "$CL_TMP/nopass.out"; then
  ok "collector: refuses to serve with no password"
else
  fail "collector: refuses to serve with no password" "rc=$CL_RC2 $(cat "$CL_TMP/nopass.out")"
fi

# --- preflight -------------------------------------------------------------
# A missing index.html must be named, not surfaced as a stack trace or a 500
# on first request.
CL_RC3=0
CREW_FLOOR_PASS=x CREW_FLOOR_PORT=8893 CREW_FLOOR_INDEX=/nonexistent/index.html \
  timeout 5 python3 -c "
import os, sys
sys.argv = ['floor.py']
sys.path.insert(0, '$CL_FLOOR/server')
import floor.server
floor.server.INDEX = '/nonexistent/index.html'
try:
    floor.server.main()
except SystemExit as e:
    print(e); sys.exit(1)
" > "$CL_TMP/noindex.out" 2>&1 || CL_RC3=$?
if [ "$CL_RC3" -ne 0 ] && grep -qi "missing" "$CL_TMP/noindex.out"; then
  ok "collector: a missing index.html is named at startup"
else
  fail "collector: a missing index.html is named at startup" "rc=$CL_RC3 $(cat "$CL_TMP/noindex.out")"
fi


# ---------------------------------------------------------------------------
# The roster loops, against a stub fleet.
#
# Nothing in this repo invoked cli/crew until now, and that is the whole reason
# #47 and #48 both reached a real host: `crew status` had NEVER worked on a
# populated fleet, and `crew up` — the steady-state convergence verb — had the
# same two defects. Both failed silently. The jq one printed a header and quit
# (rc=5, jq's runtime-error code, hidden by a `2>/dev/null` on jq itself); the
# stdin one exited 0 with N-1 boxes missing.
#
# The assertion that catches both is the same one, and it is a COUNT: a roster
# of six must produce six rows. #47 yields zero rows, #48 yields one.
# ---------------------------------------------------------------------------
echo
echo "== crew roster loops (stub fleet)"

CL_CREW_FLEET="$CL_HERE/fixtures/cli-fleet.txt"
CL_CREW_ROSTER="$CL_HERE/fixtures/cli-roster.txt"
CL_CREW_N="$(grep -cvE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")"

# Fleet selection is directory-atomic. An explicit directory without its proof
# file is an error; a complete out-of-tree definition drives the normal loops.
CL_BAD_CONFIG="$CL_TMP/bad-config"
mkdir -p "$CL_BAD_CONFIG"
printf 'FLEET_HUMAN=wrong\n' >"$CL_BAD_CONFIG/fleet.conf"
CL_RC=0
CREW_CONFIG_DIR="$CL_BAD_CONFIG" "$CL_ROOT/cli/crew" profiles \
  >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'fleet.roster is required' "$CL_TMP/config-out"; then
  ok "crew config: explicit split-brain directory is refused"
else
  fail "crew config: explicit split-brain directory is refused" \
    "rc=$CL_RC $(cat "$CL_TMP/config-out")"
fi
CL_INCOMPLETE="$CL_TMP/incomplete-config"
mkdir -p "$CL_INCOMPLETE"
printf 'fixture claude builder\n' >"$CL_INCOMPLETE/fleet.roster"
CL_RC=0
CREW_CONFIG_DIR="$CL_INCOMPLETE" "$CL_ROOT/cli/crew" profiles \
  >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'missing: fleet.conf repos.txt' "$CL_TMP/config-out"; then
  ok "crew config: selected directory requires the identity trio"
else
  fail "crew config: selected directory requires the identity trio" \
    "rc=$CL_RC $(cat "$CL_TMP/config-out")"
fi
CL_CONFIG="$CL_TMP/operator-config"
mkdir -p "$CL_CONFIG"
cp "$CL_CREW_ROSTER" "$CL_CONFIG/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CL_CONFIG/fleet.conf"
printf 'heavy-duty/crew\n' >"$CL_CONFIG/repos.txt"
CL_RC=0
PATH="$CL_TMP/bin:$PATH" FLOOR_FIXTURE="$CL_CREW_FLEET" \
FLOOR_STATE="$CL_TMP/crew-state" CREW_CONFIG_DIR="$CL_CONFIG" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" status \
  </dev/null >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
t "crew config: out-of-tree fleet drives roster loops" 0 "$CL_RC"

# crew_cmd ARGS... — cli/crew against the stub fleet, output in $CL_TMP/crew-out.
#
# CREW_CONFIG_DIR is what makes this a CONFIGURED host, and it is not optional
# now that the examples fallback refuses to create or arm anything (#216).
# CREW_ROSTER alone is a roster-only override — by contract it does NOT select
# a fleet context — so every helper below used to resolve to $CREW_ROOT/examples
# and was testing `hire`/`upgrade`/`gold` through the fallback: the one host
# state where those verbs are now supposed to die. The verbs under test are
# right, the host was wrong. $CL_CONFIG carries the same roster, so the loops
# and counts are unchanged; CREW_ROSTER stays for the per-case roster swaps
# (crew_off below), which is exactly the narrow job it is documented to have.
crew_cmd() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_CONFIG_DIR="$CL_CONFIG" CREW_ROSTER="$CL_CREW_ROSTER" \
    timeout 60 "$CL_ROOT/cli/crew" "$@" </dev/null > "$CL_TMP/crew-out" 2>&1 || CL_RC=$?
}

crew_cmd status
t "crew status: exits 0 on a populated fleet" 0 "$CL_RC"

# One row per roster member. Counted by NAME rather than by line, so a banner
# or a note that wraps cannot inflate it.
CL_ROWS=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  grep -qE "^$cl_name " "$CL_TMP/crew-out" && CL_ROWS=$((CL_ROWS + 1))
done < <(grep -vE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")
t "crew status: one row per roster box" "$CL_CREW_N" "$CL_ROWS"
if [ "$CL_ROWS" -ne "$CL_CREW_N" ]; then
  echo "  crew status said:"; sed 's/^/    /' "$CL_TMP/crew-out"
fi

# The per-branch facts the table is supposed to carry. Without these the count
# above could be satisfied by six rows that all say the same wrong thing.
if grep -qE '^cli-stopped +stopped' "$CL_TMP/crew-out"; then
  ok "crew status: a stopped box reads stopped"
else
  fail "crew status: a stopped box reads stopped" "$(grep '^cli-stopped' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-absent .*NOT CREATED' "$CL_TMP/crew-out"; then
  ok "crew status: an absent box says NOT CREATED"
else
  fail "crew status: an absent box says NOT CREATED" "$(grep '^cli-absent' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-noauth .*MISSING' "$CL_TMP/crew-out"; then
  ok "crew status: dead logins are FLAGGED, not blank"
else
  fail "crew status: dead logins are FLAGGED, not blank" "$(grep '^cli-noauth' "$CL_TMP/crew-out")"
fi
# #189 — `crew status` could not answer "is this box armed?" at all, so the
# drill's floor-vs-CLI agreement check had nothing to compare for a disarmed
# box and skipped it, five runs running. The note must also name the FIX:
# an unarmed box needs `crew hire`, and a paused one needs the console, so a
# single "not armed" would send half of them to the wrong place.
if grep -qE '^cli-disarmed .*disarmed .*crew hire' "$CL_TMP/crew-out"; then
  ok "crew status: an unarmed box says disarmed and names the fix"
else
  fail "crew status: an unarmed box says disarmed and names the fix" \
       "$(grep '^cli-disarmed' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-suppressed +suppressed .*for 13m .*draft resume breaker at heavy-duty/crew#561' "$CL_TMP/crew-out"; then
  ok "crew status: breaker-suppressed builder carries age and reason"
else
  fail "crew status: breaker-suppressed builder carries age and reason" \
       "$(grep '^cli-suppressed' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-idle +running ' "$CL_TMP/crew-out" \
   && grep -qE '^cli-unreachable ' "$CL_TMP/crew-out"; then
  ok "crew status: suppressed, idle, and unreachable remain distinct"
else
  fail "crew status: suppressed, idle, and unreachable remain distinct" \
       "$(grep -E '^cli-(suppressed|idle|unreachable)' "$CL_TMP/crew-out")"
fi

# --- STUCK, against the ceiling on the box's own record (#624) --------------
#
# The quartet below is the CLI half of #610's, box for box and number for
# number, and the assertion is that the two consoles now render ONE sentence
# about one box. Before this, `crew status` compared every lock against
# STUCK_AFTER_S — 600s, fleet-wide — so cli-lane-build read STUCK at ten
# minutes while the floor, reading the 3600s ceiling that box's own
# `SESSION START` declares, called it healthy. The operator saw both.
#
# `cl_note` is the row minus its columns: the note is the last field and the
# only one these cases are about. Cut at the LAST run of two or more spaces,
# not by counting columns — ENGINE renders as `crew@X.Y.Z[-suffix] (deadbee)` and
# carries a space of its own, so a field count reads one column short.
cl_note() { sed -n "s/^$1 .*  \(.*\)\$/\1/p" "$CL_TMP/crew-out"; }

# 40 minutes into a build entitled to 3600s. The one row this issue exists for.
if grep -qE '^cli-lane-build .*session active' "$CL_TMP/crew-out" \
   && ! grep -qE '^cli-lane-build .*STUCK' "$CL_TMP/crew-out"; then
  ok "crew status: a build inside its own ceiling is not STUCK"
else
  fail "crew status: a build inside its own ceiling is not STUCK" \
       "$(grep '^cli-lane-build' "$CL_TMP/crew-out")"
fi
# The boundary from both sides, one second apart, and it is `-gt` on this side
# exactly as `held <= bound` is the not-stuck return on the floor's.
if ! grep -qE '^cli-lane-edge .*STUCK' "$CL_TMP/crew-out"; then
  ok "crew status: the ceiling plus the kill grace is not yet STUCK"
else
  fail "crew status: the ceiling plus the kill grace is not yet STUCK" \
       "$(grep '^cli-lane-edge' "$CL_TMP/crew-out")"
fi
# ...and one second past it, worded to the byte as fleet-floor/test/floor's
# `stuck: the note names the lane and its ceiling` asserts of the collector.
t "crew status: one second past the grace is STUCK, naming the ceiling" \
  "STUCK — duty run has held the lock for 1h 01m, past the build session's 1h 00m ceiling" \
  "$(cl_note cli-lane-over)"
# An engine older than the `timeout=` token has no ceiling on the record, so
# the fallback and its wording are today's, unchanged.
t "crew status: a START with no timeout= falls back to STUCK_AFTER_S" \
  "STUCK — duty run has held the lock for 11m" "$(cl_note cli-lane-legacy)"
# Nothing in flight at all: no ceiling can ever catch it, so STUCK_AFTER_S is
# its bound and the sentence says which state it is describing.
t "crew status: a lock held with no session in flight names that" \
  "STUCK — duty run has held the lock for 47m with no session in flight, past 10m" \
  "$(cl_note cli-stuck)"

# --- ...and where the two readers' LANGUAGES disagree about the digits -------
#
# `TIMEOUT_BUILD=0900` is a role conf a host may hold. Nothing between it and
# `session.sh`'s `timeout=${tmo}s` canonicalises, GNU `timeout 0900` runs that
# session, and the floor's `int()` reads 900. Bash reads a leading zero as
# octal and `0900` is not octal, so `$(( session_ceiling + … ))` was a FATAL
# expansion under this file's own `set -euo pipefail` — which makes this the
# only row in the quartet whose failure was never a wrong badge. The pair
# below is the ordinary boundary asked of that value; the row-count assertion
# further up is what catches the abort, and the case after them says so where
# a reader will find it (round 1, codex-bot).
if grep -qE '^cli-lane-zero .*session active' "$CL_TMP/crew-out" \
   && ! grep -qE '^cli-lane-zero .*STUCK' "$CL_TMP/crew-out"; then
  ok "crew status: a leading-zero ceiling is read as decimal, not octal"
else
  fail "crew status: a leading-zero ceiling is read as decimal, not octal" \
       "$(grep '^cli-lane-zero ' "$CL_TMP/crew-out")"
fi
# 800s is inside 900+60 and PAST the 600s constant, so this row also separates
# the two readings rather than merely surviving one: a `crew status` still
# grading against STUCK_AFTER_S calls this box STUCK.
t "crew status: one second past a leading-zero ceiling is STUCK, naming it" \
  "STUCK — duty run has held the lock for 16m, past the build session's 15m ceiling" \
  "$(cl_note cli-lane-zero-over)"
# The abort, asserted AS an abort. `crew status` returning 1 out of its roster
# loop is not a mislabelled box — it is a table that stops, and every row
# after the offending one is simply absent. Two rows follow the pair in the
# fixture, and naming them here is what makes this case fail LOUDLY rather
# than shrink the row count by two somewhere else in the file.
if grep -qE '^cli-unconverged ' "$CL_TMP/crew-out" \
   && grep -qE '^cli-premanifest ' "$CL_TMP/crew-out"; then
  ok "crew status: the rows below a leading-zero ceiling still print"
else
  fail "crew status: the rows below a leading-zero ceiling still print" \
       "table ends at: $(tail -1 "$CL_TMP/crew-out")"
fi

# --- ...and where bash cannot HOLD the record at all ------------------------
#
# `timeout=999999999999999999999999s`, reachable by the same argument the pair
# above rests on and refused for a different reason: this is not a spelling the
# two languages read differently, it is a value one of them has no room for.
# `[ "$session_ceiling" -gt 0 ]` exits 2 on it, so the ceiling clause was
# SKIPPED and `cli-lane-huge` was graded against STUCK_AFTER_S — 700s past a
# 600s constant, STUCK — while the floor's unbounded `int()` graded it against
# 10^24 + 60 and called it healthy. #624's own defect, inside #624's own fix.
# `$(( ))` is no repair either: it wraps silently, so letting the value through
# the guard would have traded a wrong verdict for a fabricated ceiling
# (round 2, codex-bot).
if grep -qE '^cli-lane-huge .*session active' "$CL_TMP/crew-out" \
   && ! grep -qE '^cli-lane-huge .*STUCK' "$CL_TMP/crew-out"; then
  ok "crew status: a ceiling past bash's range is not STUCK at 700s"
else
  fail "crew status: a ceiling past bash's range is not STUCK at 700s" \
       "$(grep '^cli-lane-huge ' "$CL_TMP/crew-out")"
fi
# ...and the OTHER half of that fix, which the box above cannot red. Deleting
# the width gate turns twenty-four nines into 2003764205206896639 — nobody's
# ceiling, but still an enormous one, so `cli-lane-huge` comes out `session
# active` by accident and only the source pin notices. 2^63 wraps NEGATIVE:
# the bound lands below every lock age there is and this row reads STUCK. A
# guard whose behaviour cannot red it is the shape 1b already caught once here.
if grep -qE '^cli-lane-wrap .*session active' "$CL_TMP/crew-out" \
   && ! grep -qE '^cli-lane-wrap .*STUCK' "$CL_TMP/crew-out"; then
  ok "crew status: a ceiling whose wrap goes negative is not STUCK either"
else
  fail "crew status: a ceiling whose wrap goes negative is not STUCK either" \
       "$(grep '^cli-lane-wrap ' "$CL_TMP/crew-out")"
fi
# The NOISE, asserted as absent. `crew status` merges stderr into this capture,
# and a `[` that fails on its operand writes a line of its own between two
# roster rows — not fatal, since an `if` condition is exempt from `set -e`, and
# therefore not caught by the row count or by any verdict assertion. It is
# still a diagnostic the operator cannot attribute to anything on their screen,
# and it is the visible half of the defect above.
if ! grep -q 'integer expression expected' "$CL_TMP/crew-out"; then
  ok "crew status: no integer expression expected lands between the rows"
else
  fail "crew status: no integer expression expected lands between the rows" \
       "$(grep -n 'integer expression expected' "$CL_TMP/crew-out" | head -3)"
fi

# The knob keeps its one meaning and gains no second one. Raising it must
# release the no-session clause and must NOT silently re-cap a declared
# ceiling — which would re-introduce the false alarm this replaces, on exactly
# the boxes whose operator had raised it.
CL_RC=0
PATH="$CL_TMP/bin:$PATH" \
FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
CREW_CONFIG_DIR="$CL_CONFIG" CREW_ROSTER="$CL_CREW_ROSTER" \
CREW_FLOOR_STUCK_AFTER=5000 \
  timeout 60 "$CL_ROOT/cli/crew" status </dev/null > "$CL_TMP/crew-knob" 2>&1 || CL_RC=$?
t "crew status: exits 0 with the operator override set" 0 "$CL_RC"
if ! grep -qE '^cli-stuck .*STUCK' "$CL_TMP/crew-knob"; then
  ok "crew status: CREW_FLOOR_STUCK_AFTER still bounds the no-session clause"
else
  fail "crew status: CREW_FLOOR_STUCK_AFTER still bounds the no-session clause" \
       "$(grep '^cli-stuck' "$CL_TMP/crew-knob")"
fi
if grep -qE '^cli-lane-over .*STUCK' "$CL_TMP/crew-knob"; then
  ok "crew status: the override does not re-cap a declared ceiling"
else
  fail "crew status: the override does not re-cap a declared ceiling" \
       "$(grep '^cli-lane-over' "$CL_TMP/crew-knob")"
fi
# The floor and this CLI must derive credential state from the SAME evidence.
# `rehearsal-app.sh` asserts they agree about every box on a real host, and
# that assertion only means anything while neither has a private source: when
# the floor stopped polling and started reading the engine's markers, a
# `crew status` still running `gh auth status` would have disagreed with it
# for real, on a real fleet, with nothing in CI able to see it.
CL_CLI="$CL_ROOT/cli/crew"
if grep -q 'auth_from_flow' "$CL_CLI"; then
  ok "crew status reads the flow markers, not a second source"
else
  fail "crew status reads the flow markers, not a second source" \
       "cmd_status does not call auth_from_flow"
fi
# Anchored INSIDE cmd_status: the live probes are still correct in `crew hire`,
# where a human is standing there to fix what they find. It is the per-box
# status loop that must not reintroduce them.
CL_STATUS_PROBE="$(awk '
  /^cmd_status\(\)/ { inf = 1; next }
  inf && /^}/         { inf = 0 }
  inf && /gh auth status|vendor_probe/ { print "PROBES"; exit }
' "$CL_CLI")"
if [ -z "$CL_STATUS_PROBE" ]; then
  ok "crew status makes no network auth probe of its own"
else
  fail "crew status makes no network auth probe of its own" \
       "cmd_status still calls gh auth status or vendor_probe"
fi
# Both readers must speak one vocabulary, or "they agree" is a string compare
# between two dialects.
for cl_word in nofail waiting stale missing unknown; do
  if grep -q "$cl_word" "$CL_CLI" && grep -q "$cl_word" "$CL_FLOOR/server/probe.sh"; then
    ok "vocabulary '$cl_word' is shared by crew and probe.sh"
  else
    fail "vocabulary '$cl_word' is shared by crew and probe.sh" "only one side emits it"
  fi
done

if grep -qE '^cli-nothired .*not hired' "$CL_TMP/crew-out"; then
  ok "crew status: an unhired box says so"
else
  fail "crew status: an unhired box says so" "$(grep '^cli-nothired' "$CL_TMP/crew-out")"
fi

# #224 — a hired box with no ~/duty/duty.log made `tail` exit 1, and under
# `set -o pipefail` that status killed the assignment and the whole table with
# it. The row count above already bites (cli-neverticked is FIRST, so the loop
# died before printing anything), but a count alone cannot tell the two
# one-sided fixes apart, and each half is separately reachable:
#
#   · repair only the note string  → the table still truncates → count fails
#   · repair only the truncation   → `no ticks yet` never renders → this fails
#
# Both assertions are therefore required, and so is the fixture ORDER: behind
# a healthy box the truncation would have left cli-hired printed and every
# assertion above green.
if grep -qE '^cli-neverticked .*no ticks yet' "$CL_TMP/crew-out"; then
  ok "crew status: a box that has never ticked reads 'no ticks yet'"
else
  fail "crew status: a box that has never ticked reads 'no ticks yet'" \
       "$(grep '^cli-neverticked' "$CL_TMP/crew-out")"
fi
# #265 — the CREDENTIAL columns of that same row. The NOTE said "no ticks yet"
# while GH and VENDOR beside it said `stale`, which is the row contradicting
# itself: `stale` claims the engine used to talk to these services and has
# stopped. It has never started.
#
# cl_pair NAME REGEX DESC — one row's GH and VENDOR cells, matched as an
# ADJACENT PAIR followed by the start of its NOTE.
#
# A pair and not two greps: floor.py and cli/crew age both services in one
# loop, so a fix that reached `gh` alone leaves `waiting  stale`, and a
# single-cell assertion passes it. Matched by regex rather than by field index
# or character offset because neither survives this table — `$6` is INTEGRITY
# on a hired row and GH on an unhired one, since the stub's ENGINE value
# (`crew@X.Y.Z[-suffix] (deadbee)`) both contains a space and overruns its `%-15s`
# field. Anchoring on the NOTE that follows is what keeps the match honest:
# it pins the cells to their column rather than to any two words in the row.
cl_pair() {
  if grep -qE "$2" "$CL_TMP/crew-out"; then
    ok "$3"
  else
    fail "$3" "$(grep "^$1" "$CL_TMP/crew-out")"
  fi
}
cl_pair cli-neverticked '^cli-neverticked .+ waiting +waiting +no ticks yet$' \
  "crew status: a never-ticked box reports waiting, not stale"
# THE GUARD, and it outranks the fix. Reporting a genuinely silent box as
# "waiting for its first tick" puts a possibly-dead credential behind a
# reassuring word — strictly worse than the bug it fixes. cli-disarmed HAS
# ticked (tickage 4000) and must still read `stale` in both columns.
cl_pair cli-disarmed '^cli-disarmed .+ stale +stale +disarmed' \
  "crew status: a box that ticked and stopped is still stale"
# A recent tick still reads `flowing`: the new branch must not swallow the
# healthy case on its way past.
cl_pair cli-hired '^cli-hired +working .+ flowing +flowing +session active' \
  "crew status: a ticking box still reports flowing"
# The boundary the new branch could have swallowed. It fires only inside the
# `nofail` arm, so a box with no VERSION is untouched — keying it on tickage
# alone would have turned every unhired box into `waiting`, a word that claims
# an engine is installed and about to run. cli-nothired reports tickage -1 too,
# which is exactly what makes this a boundary and not a formality.
cl_pair cli-nothired '^cli-nothired .+ unknown +unknown +crew hire' \
  "crew status: an unhired box is untouched by the waiting branch"
# A recorded rejection still outranks everything above it: cli-noauth reports a
# tick age, but its verdict is decided before any aging happens at all.
cl_pair cli-noauth '^cli-noauth .+ MISSING +MISSING +' \
  "crew status: a recorded rejection still outranks the aged verdicts"
# #265's alignment criterion, pinned where it can actually be broken: the
# format string. The stub's ENGINE value overruns `%-15s`, so no fixture row
# can prove alignment by inspection — but a credential verdict wider than the
# `%-8s` cells would shift the NOTE on every hired row of a real fleet, and
# that is a one-character edit away. `waiting` is seven, so this contract is
# unchanged; the golden compare means widening it has to be deliberate.
CL_FMT="$(sed -n "s/^  local fmt='\(.*\)'\$/\1/p" "$CL_CLI" | head -1)"
t "crew status: the table's column contract is unchanged" \
  '%-20s %-10s %-12s %-15s %-10s %-8s %-8s %s\n' "$CL_FMT"

cl_pair cli-supp-silent '^cli-supp-silent +offline .+ stale +stale +SILENT' \
  "crew status: a silent box outranks a stale suppression marker"
cl_pair cli-supp-unknown '^cli-supp-unknown +offline .+ stale +stale +tick age unknown' \
  "crew status: an unknown tick age outranks suppression"
cl_pair cli-silent '^cli-silent +offline .+ stale +stale +SILENT' \
  "crew status: an armed box that stopped ticking reads SILENT like the floor"
cl_pair cli-supp-working '^cli-supp-working +working .+ flowing +flowing +session active' \
  "crew status: an active session outranks suppression"
cl_pair cli-supp-stuck '^cli-supp-stuck +working .+ flowing +flowing +STUCK' \
  "crew status: a stuck run outranks suppression"
cl_pair cli-hired '^cli-hired +working .+ flowing +flowing +session active' \
  "crew status: a live session renders consistently without suppression"
cl_pair cli-stuck '^cli-stuck +working .+ flowing +flowing +STUCK' \
  "crew status: a stuck run renders consistently without suppression"
cl_pair cli-supp-nots '^cli-supp-nots +suppressed .+ flowing +flowing +for 13m' \
  "crew status: an unparseable log does not invent unknown tick age"
cl_pair cli-supp-old-orphan '^cli-supp-old-orphan +suppressed .+ flowing +flowing +for 13m' \
  "crew status: a session orphan older than six hours is not active"
cl_pair cli-supp-paired '^cli-supp-paired +working .+ flowing +flowing +session active' \
  "crew status: stack pairing retains an earlier unmatched session"
if grep -q 'integer expression expected' "$CL_TMP/crew-out"; then
  fail "crew status: invalid tick ages emit no shell diagnostics" \
    "$(grep 'integer expression expected' "$CL_TMP/crew-out")"
else
  ok "crew status: invalid tick ages emit no shell diagnostics"
fi
CL_WIDE=""
for cl_word in flowing waiting stale missing unknown MISSING; do
  [ "${#cl_word}" -le 8 ] || CL_WIDE="$CL_WIDE $cl_word"
done
t "crew status: every credential verdict fits its 8-wide column" "" "$CL_WIDE"
# The healthy row BELOW it. Named separately from the count so a regression
# says which shape came back rather than only that the total moved.
if grep -qE '^cli-hired ' "$CL_TMP/crew-out"; then
  ok "crew status: a never-ticked box does not suppress the rows after it"
else
  fail "crew status: a never-ticked box does not suppress the rows after it" \
       "cli-hired is missing; the loop stopped at cli-neverticked"
fi
# A box nobody can reach has no duty log EITHER, and the two must not read
# alike: one is fine and one is broken. `crew hire` is the honest note for a
# box that answered no engine report at all (#221 is the same distinction one
# call site over, and these two fixes must not contradict each other).
if grep -qE '^cli-unreachable ' "$CL_TMP/crew-out" &&
   ! grep -qE '^cli-unreachable .*no ticks yet' "$CL_TMP/crew-out"; then
  ok "crew status: an unreachable box is not laundered into 'no ticks yet'"
else
  fail "crew status: an unreachable box is not laundered into 'no ticks yet'" \
       "$(grep '^cli-unreachable' "$CL_TMP/crew-out")"
fi
# The guard, pinned where it lives. The assertions above go red the moment it
# is dropped, but they cannot say WHY; this names the one-line cure and the
# three helpers it matches, so a future edit that "tidies" it away is told
# what it is removing.
CL_TICK_GUARD="$(awk '
  /^cmd_status\(\)/ { inf = 1 }
  inf && /tail -n 1 ~\/duty\/duty\.log/ { print; exit }
' "$CL_CLI")"
if grep -q '|| true' <<<"$CL_TICK_GUARD"; then
  ok "crew status: the duty-log read is guarded, as box_state/box_agent/box_registry are"
else
  fail "crew status: the duty-log read is guarded, as box_state/box_agent/box_registry are" \
       "${CL_TICK_GUARD:-no duty.log read found in cmd_status}"
fi

# Engine INTEGRITY is a column of its own (#159), not a decoration on ENGINE:
# HOST vs ENGINE is skew, integrity is whether the box is running the engine it
# names, and the two call for different actions. Asserted here because a hired
# box reading anything but `current` on a clean stub fleet means the CLI's
# report and the box's answer have drifted apart — the same class of failure
# `crew status` had NEVER worked on a populated fleet.
if grep -q 'INTEGRITY' "$CL_TMP/crew-out"; then
  ok "crew status: the table carries an integrity column"
else
  fail "crew status: the table carries an integrity column" "$(head -1 "$CL_TMP/crew-out")"
fi
if grep -qE "^cli-hired .*current" "$CL_TMP/crew-out"; then
  ok "crew status: a healthy box reads current"
else
  fail "crew status: a healthy box reads current" "$(grep '^cli-hired' "$CL_TMP/crew-out")"
fi

# ---------------------------------------------------------------------------
# `crew status <box>` — the DETAIL view, which is a different code path from
# the table above and had the same defect from the other direction (#221).
#
# The table asks "which boxes are healthy"; this asks "is THIS box healthy",
# and it is what an operator types in the 5 minutes between `crew hire`
# returning and the first cron tick. In that window ~/duty/duty.log does not
# exist yet, `tail` exits 1, and the old `|| echo "  (unreachable)"` reported a
# missing file as a missing box. The line directly above it — `integrity:` —
# is itself a `box exec` round trip that answered, so the view contradicted
# itself on one screen.
#
# Four states, four different sentences, and the fixture fleet already carries
# a box for each.
# ---------------------------------------------------------------------------
echo
echo "== crew status <box> (detail view)"

# The round-trip budget is a criterion of #221's, so it is measured rather than
# reasoned about: a wrapper that COUNTS `box exec` and then delegates to the
# stub unchanged. Nothing else about the run differs.
CL_COUNT_BIN="$CL_TMP/count-bin"
mkdir -p "$CL_COUNT_BIN"
cat >"$CL_COUNT_BIN/box" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = exec ] && printf 'x\n' >>"\${CL_EXEC_LOG:-/dev/null}"
exec "$CL_HERE/stub-box" "\$@"
EOF
chmod +x "$CL_COUNT_BIN/box"

# crew_detail BOX — `crew status BOX` with its round trips counted. Output in
# $CL_TMP/crew-out and status in $CL_RC, exactly as crew_cmd; the exec count
# lands in $CL_EXECN.
CL_EXECN=0
crew_detail() {
  CL_RC=0
  : >"$CL_TMP/execlog"
  PATH="$CL_COUNT_BIN:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_CONFIG_DIR="$CL_CONFIG" CREW_ROSTER="$CL_CREW_ROSTER" \
  CL_EXEC_LOG="$CL_TMP/execlog" \
    timeout 60 "$CL_ROOT/cli/crew" status "$1" \
    </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
  CL_EXECN="$(grep -c . "$CL_TMP/execlog" || true)"
}

# --- the reported case -----------------------------------------------------
# cli-neverticked answers `box exec` and has no ~/duty/duty.log, which is every
# box for the first five minutes of its life. Before the fix this printed
# `(unreachable)`, so the negative half is the proof the test bites.
crew_detail cli-neverticked
t "crew status <box>: a box awaiting its first tick exits 0" 0 "$CL_RC"
if grep -q 'no ticks yet' "$CL_TMP/crew-out" &&
   ! grep -q 'unreachable' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a hired box with no duty log yet is not unreachable"
else
  fail "crew status <box>: a hired box with no duty log yet is not unreachable" \
       "$(cat "$CL_TMP/crew-out")"
fi
# The line has to be actionable, not merely non-alarming: the operator was told
# at hire that the first tick lands on the next 5-minute boundary, and this is
# the same sentence, so the answer to "did my hire work?" reads as the hire's
# own promise. It also names the file, because "no ticks yet" alone does not
# say what the view went looking for.
if grep -qE 'no ticks yet — ~/duty/duty\.log is written by the first tick, at the next 5-minute boundary' \
     "$CL_TMP/crew-out"; then
  ok "crew status <box>: the wait names the duty log and the tick boundary"
else
  fail "crew status <box>: the wait names the duty log and the tick boundary" \
       "$(grep 'no ticks' "$CL_TMP/crew-out")"
fi
# ...and it carries NO hire stamp (#221 criterion 1, amended 2026-08-02). The
# assertion is negative because the positive one above would keep passing if a
# stamp came back appended. The only stamp within reach is the engine VERSION,
# which the `engine:` line two rows up already prints — repeating it here reads
# as a hire TIME, which it is not. `crew@` catches it in any phrasing.
CL_NO_TICKS="$(grep 'no ticks yet' "$CL_TMP/crew-out")"
if ! grep -qE 'hired at|crew@' <<<"$CL_NO_TICKS"; then
  ok "crew status <box>: the wait asserts no hire time"
else
  fail "crew status <box>: the wait asserts no hire time" \
       "$(grep 'no ticks yet' "$CL_TMP/crew-out")"
fi
# #221's round-trip criterion, measured: engine_report, rig_report, and the
# duty-log read. THREE, and the number is the assertion — the reachability
# signal had to come from a probe already made, so a fix that asked the box a
# fourth question (auth_from_flow, a second `tail`, a `test -f`) would be a
# different and more expensive fix than the one specified.
t "crew status <box>: the detail view still costs three round trips" 3 "$CL_EXECN"

# --- the regression guard, and it outranks the fix -------------------------
# A box nobody can reach must not be laundered into "just hasn't ticked yet".
# That failure is strictly worse than the bug being fixed: it puts a dead box
# behind a reassuring sentence. cli-unreachable answers nothing at all.
crew_detail cli-unreachable
t "crew status <box>: an unreachable box still exits 0" 0 "$CL_RC"
CL_ENGINE_LINES="$(grep '^engine:' "$CL_TMP/crew-out")"
if grep -qx 'engine: unknown — the box did not answer' "$CL_TMP/crew-out" &&
   ! grep -q 'hired' <<<"$CL_ENGINE_LINES"; then
  ok "crew status <box>: an unanswered engine report is unknown, not un-hired"
else
  fail "crew status <box>: an unanswered engine report is unknown, not un-hired" \
       "$(grep '^engine:' "$CL_TMP/crew-out" || true)"
fi
if grep -q '(unreachable)' "$CL_TMP/crew-out" &&
   ! grep -q 'no ticks yet' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a box that answers nothing still reads (unreachable)"
else
  fail "crew status <box>: a box that answers nothing still reads (unreachable)" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: the unreachable detail view still costs three round trips" 3 "$CL_EXECN"
# Both halves of the criterion, because they arrive by different routes: a
# STOPPED box fails `box exec` in the daemon, an unreachable one fails inside
# it. The detail view reads neither state directly — it reads the two probes'
# silence — so a change that started special-casing `box_state` here would show
# up as a difference between these two cases.
crew_detail cli-stopped
t "crew status <box>: a stopped box still exits 0" 0 "$CL_RC"
if grep -qx 'engine: unknown — the box did not answer' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a stopped box does not infer an absent engine"
else
  fail "crew status <box>: a stopped box does not infer an absent engine" \
       "$(grep '^engine:' "$CL_TMP/crew-out" || true)"
fi
if grep -q '(unreachable)' "$CL_TMP/crew-out" &&
   ! grep -q 'no ticks yet' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a stopped box still reads (unreachable)"
else
  fail "crew status <box>: a stopped box still reads (unreachable)" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: the stopped detail view still costs three round trips" 3 "$CL_EXECN"

# --- the normal case, unchanged --------------------------------------------
crew_detail cli-hired
t "crew status <box>: a ticking box exits 0" 0 "$CL_RC"
if grep -Fqx "engine: crew@${FLOOR_TEST_ENGINE_VERSION:-0.4.1} (deadbee)" "$CL_TMP/crew-out"; then
  ok "crew status <box>: a hired box keeps its engine line"
else
  fail "crew status <box>: a hired box keeps its engine line" \
       "$(grep '^engine:' "$CL_TMP/crew-out" || true)"
fi
if grep -q 'stub log for cli-hired' "$CL_TMP/crew-out" &&
   ! grep -qE 'unreachable|no ticks yet|not hired' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a box with a duty log still shows its log"
else
  fail "crew status <box>: a box with a duty log still shows its log" \
       "$(cat "$CL_TMP/crew-out")"
fi
# The depth is part of "unchanged output": the detail view shows five lines, and
# a fix that quietly became `tail -n 1` (the TABLE's read, one call site over)
# would still pass every assertion above on a two-line stub log.
if grep -q 'tail -n 5 ~/duty/duty.log' "$CL_CLI"; then
  ok "crew status <box>: the detail view still reads the last 5 lines"
else
  fail "crew status <box>: the detail view still reads the last 5 lines" \
       "no 'tail -n 5 ~/duty/duty.log' in $CL_CLI"
fi
t "crew status <box>: the hired detail view still costs three round trips" 3 "$CL_EXECN"

# #484 — drive the real detail path with a report between its wire marks. This
# catches a renderer that exists only in an extraction harness (or is missing
# from cli/crew entirely), while the parity case below pins its exact strings.
if grep -qx 'tick health:' "$CL_TMP/crew-out" &&
   grep -qx '  Last tick (1d window): 5m ago' "$CL_TMP/crew-out" &&
   grep -qx '  Busy ticks (1d window): 2/3 (66.7%)' "$CL_TMP/crew-out" &&
   grep -qx '  build skips/holds (1d window): 2 skips · budget:1, terminal-breaker:1' "$CL_TMP/crew-out" &&
   grep -qx '  build outcome streak (1d window): died-with-box ×3' "$CL_TMP/crew-out"; then
  ok "crew status <box>: the real detail path renders every tick-health figure"
else
  fail "crew status <box>: the real detail path renders every tick-health figure" \
       "$(sed -n '/^tick health:$/,/^[a-z]/{p}' "$CL_TMP/crew-out")"
fi

# --- the box vitals record (#483) ------------------------------------------
#
# The detail view renders the record tick.sh wrote, and #483's criterion is
# that it and the floor CANNOT disagree about it. Two things are asserted:
# that this reader renders the record at all, and — below — that the strings
# it renders are byte-for-byte the ones the page renders from the same record.
#
# The budget half is empty on a stub box (no lane configured), so this also
# proves the third section is split off correctly rather than swallowed by
# either neighbour.
if grep -qx 'vitals:' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a box carrying a record gets a vitals section"
else
  fail "crew status <box>: a box carrying a record gets a vitals section" \
       "$(cat "$CL_TMP/crew-out")"
fi
CL_VITALS_OUT="$(sed -n '/^vitals:$/,/^[a-z]/{/^  /p}' "$CL_TMP/crew-out")"
t "crew status <box>: the record renders every row it has fields for" \
"  Cores: 2 · load1 0.41
  Memory: 3128 of 3850 MiB available · 103 MiB shared
  Disk: 14254 of 29696 MiB used · 48%
  Swap: 0 MiB active of 8192 MiB configured
  Disk since: 2026-08-01T12:50:01+00:00 · 9% → 48% over 3 boot readings
  Platform: linux · debian-13
  Finding: swap-configured-inactive: configured_mb=8192, active_mb=0
  Finding: cpu-profile-mismatch: want=4, got=2" "$CL_VITALS_OUT"
# The pair, and not one half of it. Either number alone looks explicable — an
# 8 GiB swapfile holding a quarter of the disk reads as used space, and zero
# active swap reads as a box that never configured any — and the finding only
# exists because the record carries both.
if grep -q 'Swap: 0 MiB active of 8192 MiB configured' "$CL_TMP/crew-out" &&
   grep -q 'Finding: swap-configured-inactive' "$CL_TMP/crew-out"; then
  ok "crew status <box>: the swap pair renders beside the finding it produces"
else
  fail "crew status <box>: the swap pair renders beside the finding it produces" \
       "$CL_VITALS_OUT"
fi
# D5 — the series starts at the box's first BOOT, weeks before this probe's
# first tick. A reader that began at the first record would show one point.
if grep -q 'Disk since: 2026-08-01T12:50:01+00:00' "$CL_TMP/crew-out"; then
  ok "crew status <box>: the disk series carries its boot-check history"
else
  fail "crew status <box>: the disk series carries its boot-check history" \
       "$CL_VITALS_OUT"
fi

# D6, on this reader: a box whose `free` failed renders the rows it has and
# omits the ones it does not — never a row of dashes, which would read as a
# measurement of nothing.
crew_detail cli-idle
t "crew status <box>: a degraded record still exits 0" 0 "$CL_RC"
CL_VITALS_DEGRADED="$(sed -n '/^vitals:$/,/^[a-z]/{/^  /p}' "$CL_TMP/crew-out")"
t "crew status <box>: an unreadable field costs its row and no other" \
"  Cores: 2 · load1 0.00
  Disk: 14254 of 29696 MiB used · 48%
  Platform: linux · debian-13" "$CL_VITALS_DEGRADED"
t "crew status <box>: a degraded detail view still costs three round trips" 3 "$CL_EXECN"

# An engine older than the probe writes no record, and the SECTION is omitted
# rather than drawn empty — the same rule the budget half one line down uses,
# and the same one the floor applies to the same absence.
crew_detail cli-silent
if ! grep -q '^vitals:' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a box with no record gets no vitals section"
else
  fail "crew status <box>: a box with no record gets no vitals section" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: a record-less detail view still costs three round trips" 3 "$CL_EXECN"

# #688 — unlike every older scenario, the stub executes this detail view's
# emitted script over a real fixture log. A stale record precedes NUL bytes and
# the fresh record; GNU grep without -a suppresses both and this rendered
# assertion fails, while a source-text assertion would prove no behaviour.
crew_detail cli-binary
t "crew status <box>: a NUL-bearing log still exits 0" 0 "$CL_RC"
if grep -qx '  Cores: 2 · load1 0.41' "$CL_TMP/crew-out" &&
   ! grep -q 'Cores: 1' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a NUL-bearing log renders its newest VITALS record"
else
  fail "crew status <box>: a NUL-bearing log renders its newest VITALS record" \
       "$(cat "$CL_TMP/crew-out")"
fi
if [ -e "$CL_TMP/crew-state/cli-binary.vitals-script-ran" ]; then
  ok "crew status <box>: the NUL-bearing case executes the emitted reader"
else
  fail "crew status <box>: the NUL-bearing case executes the emitted reader" \
       "stub did not record script execution"
fi
if grep -qx 'tick health:' "$CL_TMP/crew-out" &&
   grep -q 'stub log for cli-binary' "$CL_TMP/crew-out" &&
   ! grep -qx 'budget:' "$CL_TMP/crew-out"; then
  ok "crew status <box>: the NUL-bearing scenario preserves adjacent sections"
else
  fail "crew status <box>: the NUL-bearing scenario preserves adjacent sections" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: the NUL-bearing detail view still costs three round trips" 3 "$CL_EXECN"

# --- THE criterion: the two readers cannot disagree (#483 D1) --------------
#
# `crew status` and the floor render the same record, in two languages, from
# two files. Everything else in this suite can only assert each side against
# an expectation written by hand — and two hand-written expectations agree
# until the day someone updates one of them.
#
# So this drives ONE record through BOTH renderers and asserts the outputs are
# identical. cli/crew's `vitals_rows` and index.html's `boxVitalsRows` are
# extracted from their real files, not copied here: a contract asserted
# against a copy is a contract asserted against nothing.
#
# node, because the page's renderer is JavaScript. It is not playwright — no
# browser, no page load, just the function — so this runs wherever node does,
# which on the CI runner is everywhere. Skipped LOUDLY otherwise, per this
# suite's own rule about silently-skipped UI tests.
CL_XREAD_REC='VITALS ts=2026-08-28T09:00:00Z cores=2 load1=0.41 mem_total_mb=3850 mem_shared_mb=103 mem_avail_mb=3128 swap_active_mb=0 swap_configured_mb=8192 disk_total_mb=29696 disk_used_mb=14254 disk_pct=48 disk_series=2026-08-01T12:50:01+00:00@9,2026-08-10T21:15:01+00:00@31,2026-08-27T18:35:01+00:00@48 platform=linux os=debian-13 finding=swap-configured-inactive:configured_mb=8192,active_mb=0 finding=cpu-profile-mismatch:want=4,got=2 finding=disk-low:want=under-90%,got=94% finding=memory-low:want=over-10%-available,got=7%-available(300/3850MiB)'
# A second record built out of HALF-PRESENT pairs, because the rows a reader
# OMITS are as much of the contract as the rows it prints: two renderers can
# agree on a full record and disagree about which absence costs which row, and
# a record that simply lacks both halves of a pair cannot tell them apart —
# every guard passes it identically whether it asks for one field or two.
#
# So: `mem_total_mb` with no `mem_avail_mb`, `swap_active_mb` with no
# `swap_configured_mb`, `disk_total_mb`/`disk_used_mb` with no `disk_pct`, and
# `load1`/`os` with the field each is a suffix OF absent. Every one of those
# rows must be omitted by both readers. Plus a ONE-POINT series, which is the
# other thing two renderers can quietly disagree about — "1 boot reading" and
# "1 boot readings" render from the same record.
CL_XREAD_DEGRADED='VITALS ts=2026-08-28T09:00:00Z load1=0.02 mem_total_mb=3850 swap_active_mb=0 disk_total_mb=29696 disk_used_mb=14254 disk_series=2026-08-01T12:50:01+00:00@9 os=debian-13'

if ! command -v node >/dev/null; then
  skip "crew status <box>: the two readers render the record identically" \
       "node not installed — the page's renderer cannot be executed"
  skip "crew status <box>: the two readers agree on which absence costs which row" \
       "node not installed — the page's renderer cannot be executed"
else
  # Extracted from the real files. Both functions are defined at column 0 and
  # closed by a `}` at column 0, which is the whole extraction rule.
  awk '/^vitals_finding\(\) \{/,/^\}/' "$CL_CLI"  >"$CL_TMP/vrows.sh"
  awk '/^vitals_rows\(\) \{/,/^\}/'    "$CL_CLI" >>"$CL_TMP/vrows.sh"
  # shellcheck disable=SC2016  # $1 is the EXTRACTED script's argument, not ours
  printf 'vitals_rows "$1"\n'                    >>"$CL_TMP/vrows.sh"
  awk '/^function boxVitalsRows\(v\)\{/,/^\}/' "$CL_FLOOR/index.html" >"$CL_TMP/vrows.js"
  cat >>"$CL_TMP/vrows.js" <<'JS'
// The collector's parse, reproduced only as far as the record's own grammar:
// the page never sees a raw record, it sees what units.parse_vitals published.
// Reimplementing the RENDERER here would defeat the test; reimplementing the
// split on `=` cannot, because the assertion is that both renderers agree.
var rec = process.argv[2], out = {fields:{}, series:[], findings:[]};
rec.replace(/^VITALS /, "").split(" ").forEach(function(tok){
  var i = tok.indexOf("="); if (i < 0) return;
  var k = tok.slice(0, i), v = tok.slice(i + 1); if (!v) return;
  if (k === "finding") {
    var j = v.indexOf(":");
    out.findings.push(j < 0 ? v : v.slice(0, j) + ": " + v.slice(j + 1).replace(/,/g, ", "));
  } else if (k === "disk_series") {
    v.split(",").forEach(function(p){
      var a = p.lastIndexOf("@"); if (a < 1) return;
      var pct = p.slice(a + 1); if (!/^[0-9]+$/.test(pct)) return;
      out.series.push({ts: p.slice(0, a), pct: parseInt(pct, 10)});
    });
  } else if (k !== "ts") out.fields[k] = v;
});
process.stdout.write(boxVitalsRows(out).map(function(r){return r[0] + "\t" + r[1];}).join("\n") + "\n");
JS
  cl_xread() {  # cl_xread RECORD -> "same" or a diff of the two renderings
    local sh js
    sh="$(bash "$CL_TMP/vrows.sh" "$1")"
    js="$(node "$CL_TMP/vrows.js" "$1")"
    if [ "$sh" = "$js" ]; then printf 'same\n'
    else printf 'DIFFER\n--- crew status\n%s\n--- floor\n%s\n' "$sh" "$js"; fi
  }
  t "crew status <box>: the two readers render the record identically" \
    same "$(cl_xread "$CL_XREAD_REC")"
  t "crew status <box>: the two readers agree on which absence costs which row" \
    same "$(cl_xread "$CL_XREAD_DEGRADED")"

  CL_HEALTH_REPORT=$'TICK_HEALTH window_s=86400 last_tick_age_s=300 ticks=3 busy=2\nTICK_HEALTH_KIND window_s=86400 kind=build skips=2 holds=budget:1,terminal-breaker:1 outcome=died-with-box streak=3'
  {
    awk '/^_tick_health_window\(\)/,/^\}/' "$CL_ROOT/shared/lib/common/tick-health.sh"
    awk '/^_tick_health_duration\(\)/,/^\}/' "$CL_ROOT/shared/lib/common/tick-health.sh"
    awk '/^tick_health_rows\(\)/,/^\}/' "$CL_ROOT/shared/lib/common/tick-health.sh"
    # shellcheck disable=SC2016  # $1 is the extracted script's argument
    printf 'tick_health_rows "$1"\n'
  } >"$CL_TMP/hrows.sh"
  grep '^function tickHealthWindow\|^function tickHealthDuration' "$CL_FLOOR/index.html" >"$CL_TMP/hrows.js"
  awk '/^function tickHealthRows\(h\)\{/,/^\}/' "$CL_FLOOR/index.html" >>"$CL_TMP/hrows.js"
  cat >>"$CL_TMP/hrows.js" <<'JS'
var h={window:86400,last_tick_age:300,ticks:3,busy:2,kinds:[{kind:"build",skips:2,holds:{budget:1,"terminal-breaker":1},outcome:"died-with-box",streak:3}]};
process.stdout.write(tickHealthRows(h).map(function(r){return r[0]+"\t"+r[1];}).join("\n")+"\n");
JS
  CL_HEALTH_SH="$(bash "$CL_TMP/hrows.sh" "$CL_HEALTH_REPORT")"
  CL_HEALTH_JS="$(node "$CL_TMP/hrows.js")"
  t "crew status <box>: tick-health figures cannot disagree with the floor" \
    "$CL_HEALTH_SH" "$CL_HEALTH_JS"
fi

# A partial answer is not an absent engine: rig_report and the duty-log read
# can both succeed even when engine_report fails. Reverting the duty-log branch
# to key on an empty stamp would turn this reachable hired box into "not hired"
# and hide the log, even though the state discriminator above remains correct.
STUB_ENGINE_REPORT_FAIL=cli-hired crew_detail cli-hired
t "crew status <box>: a box with only the engine probe silent still exits 0" 0 "$CL_RC"
if grep -qx 'engine: unknown — the box did not answer' "$CL_TMP/crew-out" &&
   grep -q 'stub log for cli-hired' "$CL_TMP/crew-out" &&
   ! grep -qE 'unreachable|no ticks yet|not hired' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a silent engine probe does not hide a reachable duty log"
else
  fail "crew status <box>: a silent engine probe does not hide a reachable duty log" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: a partly answered detail view still costs three round trips" 3 "$CL_EXECN"

# --- an un-hired box -------------------------------------------------------
# There is no engine here, so a missing duty log is not the news — and the
# stub deliberately still ANSWERS this read with a log (its `*tail*` case only
# withholds one from `neverticked`). That unfaithfulness is what makes this
# assertion bite: the un-hired verdict has to come from the absent engine, not
# from an empty read it would also have got by accident.
crew_detail cli-nothired
t "crew status <box>: an un-hired box exits 0" 0 "$CL_RC"
if grep -qx 'engine: not hired (no engine)' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a reachable un-hired box keeps its engine line"
else
  fail "crew status <box>: a reachable un-hired box keeps its engine line" \
       "$(grep '^engine:' "$CL_TMP/crew-out" || true)"
fi
if grep -q 'not hired — no engine installed' "$CL_TMP/crew-out" &&
   ! grep -q 'no ticks yet' "$CL_TMP/crew-out"; then
  ok "crew status <box>: an un-hired box reports the absent engine, not a missing log"
else
  fail "crew status <box>: an un-hired box reports the absent engine, not a missing log" \
       "$(cat "$CL_TMP/crew-out")"
fi
t "crew status <box>: the un-hired detail view still costs three round trips" 3 "$CL_EXECN"

# --- a box that is not on the host at all (#97) ----------------------------
# The one case that is a FAILURE rather than a report, and the reason the
# branch above is documented as deliberately narrow. It must survive a change
# that adds three new sentences to the same view.
crew_detail nosuchbox
if [ "$CL_RC" -eq 1 ] && grep -q "no box named 'nosuchbox'" "$CL_TMP/crew-out"; then
  ok "crew status <box>: a box that does not exist still dies with rc=1 (#97)"
else
  fail "crew status <box>: a box that does not exist still dies with rc=1 (#97)" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

# --- the two readers say the same words ------------------------------------
# #221 and #224 are the same distinction one call site apart, and the issue
# makes their agreement an explicit constraint — sharpened by triage on
# 2026-08-02 from "must not contradict" to "must not need a glossary": one
# box, both readers, the SAME phrase. The table prints `no ticks yet` in NOTE
# (#224) and the detail view now prints it too; the floor's `waiting` (#265)
# is the third reader of the same state.
#
# Asserted as one string checked against both outputs rather than two literals
# that happen to match today, so a rename of either reader alone goes red here
# rather than quietly minting the third phrase this constraint exists to
# prevent.
CL_TICKPHRASE='no ticks yet'
crew_cmd status
if grep -qE "^cli-neverticked .*$CL_TICKPHRASE" "$CL_TMP/crew-out" &&
   ! grep -qE '^cli-neverticked .*unreachable' "$CL_TMP/crew-out"; then
  ok "crew status: the table calls a never-ticked box '$CL_TICKPHRASE', not unreachable"
else
  fail "crew status: the table calls a never-ticked box '$CL_TICKPHRASE', not unreachable" \
       "$(grep '^cli-neverticked' "$CL_TMP/crew-out")"
fi
crew_detail cli-neverticked
if grep -q "$CL_TICKPHRASE" "$CL_TMP/crew-out"; then
  ok "crew status: table and detail view name a never-ticked box in the same words"
else
  fail "crew status: table and detail view name a never-ticked box in the same words" \
       "detail view of cli-neverticked does not say '$CL_TICKPHRASE': $(cat "$CL_TMP/crew-out")"
fi

# --- the guard, pinned where it lives --------------------------------------
# The assertions above go red the moment the old form comes back, but they
# cannot say WHY. This names the defect itself: the duty-log read's exit status
# must not be what decides reachability. It is the same shape as the `|| true`
# guard the table's read carries, and for the same reason — a future edit that
# "tidies" this back into a one-liner is told what it is removing.
CL_D5="$(awk '
  /^cmd_status\(\)/ { inf = 1 }
  inf && /tail -n 5 ~\/duty\/duty\.log/ { print; getline; print; exit }
' "$CL_CLI")"
if grep -q '|| true' <<<"$CL_D5" &&
   ! grep -q 'unreachable' <<<"$CL_D5"; then
  ok "crew status <box>: the duty-log read is guarded and decides no reachability"
else
  fail "crew status <box>: the duty-log read is guarded and decides no reachability" \
       "${CL_D5:-no 'tail -n 5' read found in cmd_status}"
fi

# `crew up` reads box info at its OWN call site and runs its own roster loop,
# so it needs its own coverage: #47 and #48 were each present twice, and
# fixing one copy would have left the convergence verb broken. --dry-run
# reaches both the info read and the loop while creating and hiring nothing.
crew_cmd up --dry-run
t "crew up --dry-run: exits 0" 0 "$CL_RC"
CL_SEEN=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  grep -qE "(^|[[:space:]])$cl_name:" "$CL_TMP/crew-out" && CL_SEEN=$((CL_SEEN + 1))
done < <(grep -vE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")
t "crew up --dry-run: reaches every roster box" "$CL_CREW_N" "$CL_SEEN"
if [ "$CL_SEEN" -ne "$CL_CREW_N" ]; then
  echo "  crew up said:"; sed 's/^/    /' "$CL_TMP/crew-out"
fi

# --- stdin and box info are each read in exactly ONE place -----------------
# The counts above catch the two bugs as they manifested. These catch the
# DEFECTS, for any call site added later.
#
# Both #47 and #48 were present TWICE — once in `crew status`, once in
# `crew up` — because each call site carried its own copy of the tricky part:
# the jq filter, and the stdin redirect. Fixing one copy would have left the
# convergence verb broken. So the invariant is the funnel itself: one helper
# each, asserted by COUNT over the code with comments stripped (a bare grep
# matches this file's own explanations — a detector tripping on its own
# documentation, the same trap as the read-only detector that once matched a
# string probe.sh contained).
# Comment lines stripped, and backslash continuations JOINED: vendor_probe puts
# its stdin redirect two lines below the `box exec`, so a per-line grep would
# report the one call site that has always been correct.
cl_code() {
  grep -vE '^[[:space:]]*#' "$CL_ROOT/cli/crew" | sed -e :a -e '/\\$/N; s/\\\n//; ta'
}
# `box exec "` — an actual invocation, always `box exec "$name"`. Deliberately
# not a bare `box exec`: cmd_floor's banner says "polling … over 'box exec'" in
# prose, and a detector that trips on its own documentation is the trap this
# suite has already been caught by twice.
cl_box_execs() { cl_code | grep -E 'box exec "'; }

# `box exec` forwards stdin like ssh, so ONE unredirected call inside a
# `while read … done < <(read_roster)` drains the roster: the loop ends after a
# single box, quietly, rc=0. Three call sites are legitimate — bxn pins
# /dev/null, while bxput and vendor_probe deliberately ship a named file
# (vendor_probe's is the RESOLVED profile — agent_conf, so an operator
# profile is what gets probed, #75).
CL_EXECS="$(cl_box_execs | grep -c . || true)"
t "crew: box exec appears only in bxn, bxput and vendor_probe" 3 "${CL_EXECS:-0}"
if [ "${CL_EXECS:-0}" -ne 3 ]; then
  echo "  call sites:"; cl_box_execs | sed 's/^/    /'
fi
# shellcheck disable=SC2016  # matching the literal redirect text in the source
CL_BARE="$(cl_box_execs | grep -vcE '</dev/null|<"\$\(agent_conf|<"\$source_file' || true)"
t "crew: every box exec call site pins stdin" 0 "${CL_BARE:-0}"
if [ "${CL_BARE:-0}" -ne 0 ]; then
  echo "  unpinned:"
  # shellcheck disable=SC2016  # matching the literal redirect text in the source
  cl_box_execs | grep -vE '</dev/null|<"\$\(agent_conf|<"\$source_file' | sed 's/^/    /'
fi

# `box info --json` returns an array; the filter that read it as an object
# exited 5 and took the command with it. One helper, one filter to be right.
#
# THE GUARD IS ON THE JSON READ, which is the shape that broke. #589 added a
# second reader for a DIFFERENT question — the SNAPSHOTS block that box
# documents as the way to list a box's labels — and it takes the text view, so
# it cannot reproduce the array-indexing failure this exists to prevent. Both
# halves are pinned rather than one relaxed: a future `--json` read outside
# box_state still reds, and a second text reader does too.
#
# Counted as an INVOCATION (`box info "`), never the bare words, for the reason
# cl_box_execs gives about its own: `crew help reset` names 'box info' in prose
# and a detector that trips on its own documentation is the trap this suite has
# already been caught by twice.
CL_INFO_CALLS="$(cl_code | grep -E 'box info "' || true)"
CL_RAWINFO="$(grep -c -- '--json' <<<"$CL_INFO_CALLS" || true)"
# TWO json readers now, and the second is #607 D5's: box_size_fields reads the
# resource keys off the same passthrough so that a clone can name the size it
# actually carries instead of a figure crew never read. The count stays pinned
# rather than removed — a third reader should still cost somebody a deliberate
# decision — but the count was never the property worth having, so the shape
# that broke is asserted directly below.
t "crew: box info --json is read only by box_state and box_size_fields" 2 "${CL_RAWINFO:-0}"
# EVERY --json reader tolerates the array. This is the actual failure (#47):
# the filter that read the array as an object exited 5 and, inside a command
# substitution under `set -euo pipefail`, took the whole command with it —
# `crew status` printing its header and stopping, which reads like an empty
# roster rather than a crash. A count alone would have passed a second reader
# that reproduced it exactly.
CL_JSON_UNGUARDED="$(grep -- '--json' <<<"$CL_INFO_CALLS" \
  | grep -vcF 'if type == "array"' || true)"
t "crew: every box info --json reader tolerates the array" 0 "${CL_JSON_UNGUARDED:-0}"
if [ "${CL_JSON_UNGUARDED:-0}" -ne 0 ]; then
  echo "  unguarded:"
  grep -- '--json' <<<"$CL_INFO_CALLS" | grep -vF 'if type == "array"' | sed 's/^/    /'
fi
CL_TEXTINFO="$(grep -vc -- '--json' <<<"$CL_INFO_CALLS" || true)"
t "crew: the text box info read is the snapshot-label reader alone" 1 "${CL_TEXTINFO:-0}"

# That text reader carries box_state's own discipline: an unreadable listing
# must DEGRADE to a distinct answer, never to "no labels" — #589 D4 refuses on
# the difference, so collapsing the two would restore a box on evidence
# nobody gathered.
CL_BSL="$(sed -n '/^box_snapshot_labels()/,/^}/p' "$CL_ROOT/cli/crew")"
if grep -q 'return 1' <<<"$CL_BSL"; then
  ok "crew: box_snapshot_labels reports an unreadable listing rather than 'none'"
else
  fail "crew: box_snapshot_labels reports an unreadable listing rather than 'none'" \
       "no 'return 1' — an unreadable listing would score as no labels and D4's refusal would restore"
fi

# ...and that helper must DEGRADE rather than die. `set -euo pipefail` plus a
# command substitution is what turned a jq error into a dead command, so the
# fallback is the load-bearing half of the fix, not decoration.
CL_BS="$(sed -n '/^box_state()/,/^}/p' "$CL_ROOT/cli/crew")"
if grep -q '|| true' <<<"$CL_BS" && grep -q '{s:-?}' <<<"$CL_BS"; then
  ok "crew: box_state degrades to '?' instead of killing the command"
else
  fail "crew: box_state degrades to '?' instead of killing the command" \
       "no '|| true' + '\${s:-?}' pair — the next payload shape change exits 5 again"
fi

# The stub must keep presenting the shape that made #47 possible. A stub
# "corrected" to a convenient bare object would let the bug straight back in,
# and every assertion above would still pass.
if grep -q '"state":{"status"' "$CL_HERE/stub-box" && grep -qE "^ +printf '\[\{" "$CL_HERE/stub-box"; then
  ok "stub-box: box info still returns an ARRAY with a state OBJECT"
else
  fail "stub-box: box info still returns an ARRAY with a state OBJECT" \
       "the fixture no longer reproduces the payload #47 died on"
fi

# --- hiring an off-roster box against production is refused (#51) ----------
# A leftover crew-drill-* box, hand-hired to re-arm it, became a second
# production agent racing the real fleet within one tick. The guard is
# structural — roster membership plus the registry the box would actually work
# — so it reaches an ad-hoc box named anything, and it lets a drill box be
# hired as soon as its registry is a sandbox.
mkdir -p "$CL_TMP/crew-state"
crew_cmd hire cli-hired
t "crew hire: an on-roster box is hired without a flag" 0 "$CL_RC"

# A release tree compares the version field, never the whole stamp. Use a
# scratch root because this checkout correctly carries a -dev VERSION, whose
# contract is to re-bake every time.
CL_RELEASE_ROOT="$CL_TMP/release-root"
mkdir -p "$CL_RELEASE_ROOT/cli"
cp "$CL_ROOT/cli/crew" "$CL_RELEASE_ROOT/cli/crew"
cp -R "$CL_ROOT/shared" "$CL_RELEASE_ROOT/shared"
ln -s "$CL_ROOT/examples" "$CL_RELEASE_ROOT/examples"
ln -s "$CL_ROOT/fleet-floor" "$CL_RELEASE_ROOT/fleet-floor"
printf '0.2.0\n' > "$CL_RELEASE_ROOT/VERSION"
crew_release() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_CONFIG_DIR="$CL_CONFIG" CREW_ROSTER="$CL_CREW_ROSTER" \
  STUB_INSTALL_VERSION="${STUB_INSTALL_VERSION:-0.2.0}" \
    timeout 60 "$CL_RELEASE_ROOT/cli/crew" "$@" \
    </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
}

printf 'crew@0.2.0 (aaa)\n' > "$CL_TMP/crew-state/cli-hired.version"
crew_release hire cli-hired
if [ "$CL_RC" -eq 0 ] && grep -q 'version 0.2.0 matches, skipping' "$CL_TMP/crew-out"; then
  ok "crew hire: equal versions skip despite different provenance"
else
  fail "crew hire: equal versions skip despite different provenance" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

printf 'crew@deadbee\n' > "$CL_TMP/crew-state/cli-hired.version"
crew_release status
if grep -qE '^cli-hired .*crew@deadbee' "$CL_TMP/crew-out" &&
   ! grep -qE '^cli-hired .*not hired' "$CL_TMP/crew-out"; then
  ok "crew status: a legacy SHA stamp is hired at an unknown version"
else
  fail "crew status: a legacy SHA stamp is hired at an unknown version" \
       "$(grep '^cli-hired' "$CL_TMP/crew-out")"
fi
crew_release hire cli-hired
if [ "$CL_RC" -eq 0 ] && grep -q '^crew@0.2.0 (fixture)$' "$CL_TMP/crew-state/cli-hired.version"; then
  ok "crew hire: a legacy stamp re-bakes to the release version"
else
  fail "crew hire: a legacy stamp re-bakes to the release version" \
       "rc=$CL_RC stamp=$(cat "$CL_TMP/crew-state/cli-hired.version")"
fi
crew_release hire cli-hired
if [ "$CL_RC" -eq 0 ] && grep -q 'version 0.2.0 matches, skipping' "$CL_TMP/crew-out"; then
  ok "crew hire: a migrated legacy stamp re-bakes only once"
else
  fail "crew hire: a migrated legacy stamp re-bakes only once" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

printf '0.2.0-dev\n' > "$CL_RELEASE_ROOT/VERSION"
printf 'crew@0.2.0-dev (aaa)\n' > "$CL_TMP/crew-state/cli-hired.version"
STUB_INSTALL_VERSION=0.2.0-dev crew_release hire cli-hired
if [ "$CL_RC" -eq 0 ] &&
   grep -q 'development tree — re-baking even when the installed version matches' "$CL_TMP/crew-out"; then
  ok "crew hire: a matching -dev version re-bakes loudly"
else
  fail "crew hire: a matching -dev version re-bakes loudly" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
crew_release upgrade cli-hired
if grep -q 'development tree — upgrade re-bakes unconditionally' "$CL_TMP/crew-out"; then
  ok "crew upgrade: a -dev tree explains its unconditional re-bake"
else
  fail "crew upgrade: a -dev tree explains its unconditional re-bake" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

printf '0.2.0\n' > "$CL_RELEASE_ROOT/VERSION"
printf 'crew@0.2.0 (goldsha)\n' > "$CL_TMP/crew-state/cli-hired.version"
: > "$CL_TMP/gold-calls"
FLOOR_CALLS="$CL_TMP/gold-calls" crew_release gold cli-hired --force
if grep -q 'snapshot cli-hired gold-crew-0.2.0' "$CL_TMP/gold-calls" &&
   grep -q 'gold cut: cli-hired @ crew@0.2.0 (goldsha)' "$CL_TMP/crew-out"; then
  ok "crew gold: label uses version and message keeps full provenance"
else
  fail "crew gold: label uses version and message keeps full provenance" \
       "calls=$(cat "$CL_TMP/gold-calls") out=$(cat "$CL_TMP/crew-out")"
fi

# --- the host ships the engine; boxes never clone crew (#99) ---------------
CL_ENGINE_STATE="$CL_TMP/crew-state"
mkdir -p "$CL_RELEASE_ROOT/versions/0.2.0"
cp -R "$CL_ROOT/shared" "$CL_RELEASE_ROOT/versions/0.2.0/shared"
printf '0.2.0\n' >"$CL_RELEASE_ROOT/versions/0.2.0/VERSION"
printf '0.3.0\n' >"$CL_RELEASE_ROOT/VERSION"
printf 'crew@0.1.0 (legacy)\n' >"$CL_ENGINE_STATE/cli-hired.version"
: >"$CL_TMP/engine-calls"
FLOOR_CALLS="$CL_TMP/engine-calls" crew_release hire cli-hired --ref 0.2.0 --force
if [ "$CL_RC" -eq 0 ] &&
   grep -q 'engine source: installed version 0.2.0' "$CL_TMP/crew-out" &&
   grep -q '^crew@0.2.0 (fixture)$' "$CL_ENGINE_STATE/cli-hired.version"; then
  ok "crew hire: an installed --ref is resolved and stamped on the host"
else
  fail "crew hire: an installed --ref is resolved and stamped on the host" \
       "rc=$CL_RC stamp=$(cat "$CL_ENGINE_STATE/cli-hired.version") out=$(cat "$CL_TMP/crew-out")"
fi
if ! grep -qE 'git (clone|fetch|pull)|git -C ~/crew|github.com/.*/crew' "$CL_TMP/engine-calls"; then
  ok "crew hire: the box makes no crew repository request"
else
  fail "crew hire: the box makes no crew repository request" \
       "$(grep -E 'git (clone|fetch|pull)|git -C ~/crew|github.com/.*/crew' "$CL_TMP/engine-calls")"
fi
# shellcheck disable=SC2016  # matching the remote script's literal $HOME
t "crew hire: exactly one engine archive payload is added" 1 \
  "$(grep -cF 'destination="$HOME/.crew-engine.tgz"' "$CL_TMP/engine-calls")"
if diff -qr "$CL_RELEASE_ROOT/versions/0.2.0/shared" \
  "$CL_ENGINE_STATE/cli-hired.engine-received/shared" >/dev/null &&
   cmp -s "$CL_RELEASE_ROOT/versions/0.2.0/VERSION" \
     "$CL_ENGINE_STATE/cli-hired.engine-received/VERSION"; then
  ok "crew hire: extracted engine bytes match the selected host version"
else
  fail "crew hire: extracted engine bytes match the selected host version"
fi
if [ ! -e "$CL_ENGINE_STATE/cli-hired.engine-stage" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.engine.tgz" ]; then
  ok "crew hire: success removes the box-side stage and archive"
else
  fail "crew hire: success removes the box-side stage and archive"
fi

: >"$CL_TMP/engine-calls"
FLOOR_CALLS="$CL_TMP/engine-calls" crew_release hire cli-hired --ref 0.2.0
if [ "$CL_RC" -eq 0 ] &&
   grep -q 'version 0.2.0 matches, skipping' "$CL_TMP/crew-out" &&
   ! grep -q '.crew-engine.tgz' "$CL_TMP/engine-calls"; then
  ok "crew hire: same release version skips before any transport"
else
  fail "crew hire: same release version skips before any transport" \
       "rc=$CL_RC calls=$(cat "$CL_TMP/engine-calls") out=$(cat "$CL_TMP/crew-out")"
fi

: >"$CL_ENGINE_STATE/cli-hired.has-crew"
crew_release hire cli-hired --ref 0.2.0 --force
if [ "$CL_RC" -eq 0 ] &&
   grep -q 'retired obsolete box-side engine source ~/crew to crew.retired' "$CL_TMP/crew-out" &&
   [ -e "$CL_ENGINE_STATE/cli-hired.crew-retired" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.has-crew" ]; then
  ok "crew hire: a legacy box-side checkout is retired and named"
else
  fail "crew hire: a legacy box-side checkout is retired and named" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
crew_release hire cli-hired --ref 0.2.0 --force
if ! grep -q 'retired obsolete box-side engine source' "$CL_TMP/crew-out"; then
  ok "crew hire: legacy checkout retirement happens only once"
else
  fail "crew hire: legacy checkout retirement happens only once" "$(cat "$CL_TMP/crew-out")"
fi

before_stamp="$(cat "$CL_ENGINE_STATE/cli-hired.version")"
STUB_INSTALL_FAIL=1 crew_release hire cli-hired --ref 0.2.0 --force
if [ "$CL_RC" -ne 0 ] &&
   grep -q 'engine is NOT installed and cron is NOT armed' "$CL_TMP/crew-out" &&
   [ "$before_stamp" = "$(cat "$CL_ENGINE_STATE/cli-hired.version")" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.engine-stage" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.engine.tgz" ]; then
  ok "crew hire: failed install preserves the engine and cleans staging"
else
  fail "crew hire: failed install preserves the engine and cleans staging" \
       "rc=$CL_RC before=$before_stamp after=$(cat "$CL_ENGINE_STATE/cli-hired.version") out=$(cat "$CL_TMP/crew-out")"
fi

STUB_ENGINE_UPLOAD_FAIL=1 crew_release hire cli-hired --ref 0.2.0 --force
if [ "$CL_RC" -ne 0 ] &&
   [ "$before_stamp" = "$(cat "$CL_ENGINE_STATE/cli-hired.version")" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.engine-stage" ] &&
   [ ! -e "$CL_ENGINE_STATE/cli-hired.engine.tgz" ]; then
  ok "crew hire: failed transport preserves the engine and cleans staging"
else
  fail "crew hire: failed transport preserves the engine and cleans staging" \
       "rc=$CL_RC before=$before_stamp after=$(cat "$CL_ENGINE_STATE/cli-hired.version")"
fi

mkdir -p "$CL_RELEASE_ROOT/versions/0.2.1/shared"
cp "$CL_ROOT/shared/install.sh" "$CL_RELEASE_ROOT/versions/0.2.1/shared/install.sh"
crew_release hire cli-hired --ref 0.2.1 --force
if [ "$CL_RC" -ne 0 ] && grep -q 'installed version 0.2.1 is unavailable' "$CL_TMP/crew-out"; then
  ok "crew hire: an installed version without VERSION cannot be shipped"
else
  fail "crew hire: an installed version without VERSION cannot be shipped" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

: >"$CL_TMP/engine-calls"
FLOOR_CALLS="$CL_TMP/engine-calls" crew_release upgrade cli-hired --ref 0.2.0
# shellcheck disable=SC2016  # matching the remote script's literal $HOME
if grep -q 'engine source: installed version 0.2.0' "$CL_TMP/crew-out" &&
   grep -qF 'destination="$HOME/.crew-engine.tgz"' "$CL_TMP/engine-calls" &&
   ! grep -qE 'git (clone|fetch|pull)|git -C ~/crew' "$CL_TMP/engine-calls"; then
  ok "crew upgrade: uses the same host engine transport as hire"
else
  fail "crew upgrade: uses the same host engine transport as hire" \
       "calls=$(cat "$CL_TMP/engine-calls") out=$(cat "$CL_TMP/crew-out")"
fi

: >"$CL_TMP/engine-calls"
FLOOR_CALLS="$CL_TMP/engine-calls" crew_release hire cli-noauth --force
# shellcheck disable=SC2016  # matching the remote script's literal $HOME
if [ "$CL_RC" -eq 0 ] &&
   grep -q 'hired but NOT authenticated' "$CL_TMP/crew-out" &&
   grep -qF 'destination="$HOME/.crew-engine.tgz"' "$CL_TMP/engine-calls"; then
  ok "crew hire: GitHub login is not an installation prerequisite"
else
  fail "crew hire: GitHub login is not an installation prerequisite" \
       "rc=$CL_RC calls=$(cat "$CL_TMP/engine-calls") out=$(cat "$CL_TMP/crew-out")"
fi

# The production roster is authoritative. Explicit profile flags on one of its
# members used to be accepted, echoed as fact, then silently discarded in
# favour of the roster row by install_identity_args (#35 review).
#
# This case reads the roster from the CONFIG DIRECTORY rather than CREW_ROSTER
# — that is the whole point, "the roster in force", not a fixture handed in on
# the side — so it needs its own operator definition. It used to get one by
# accident: with CREW_ROSTER unset it fell through to $CREW_ROOT/examples and
# borrowed examples/fleet.roster's claude-builder line. That is the fallback,
# where `hire` now refuses before it can reach this guard (#216), and it was a
# read of the shipped tree that would have gone quiet the day the real fleet
# changed. The line is written out here instead, so what the guard is supposed
# to be authoritative ABOUT is visible in the test.
CL_PRODCONF="$CL_TMP/prod-config"
mkdir -p "$CL_PRODCONF"
printf 'claude-builder   claude  builder\n' >"$CL_PRODCONF/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CL_PRODCONF/fleet.conf"
printf 'heavy-duty/crew\n' >"$CL_PRODCONF/repos.txt"
CL_PROD_FLEET="$CL_TMP/prod-fleet.txt"
printf 'claude-builder running idle\n' >"$CL_PROD_FLEET"
CL_RC=0
PATH="$CL_TMP/bin:$PATH" \
FLOOR_FIXTURE="$CL_PROD_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
CREW_CONFIG_DIR="$CL_PRODCONF" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" \
    hire claude-builder --agent claude --role reviewer \
    </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] &&
   grep -q 'claude-builder is declared as agent=claude role=builder' "$CL_TMP/crew-out" &&
   grep -q 'roster in force is authoritative' "$CL_TMP/crew-out"; then
  ok "crew hire: explicit profile for a production member is REFUSED"
else
  fail "crew hire: explicit profile for a production member is REFUSED" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

# Same box, off the roster: production registry, so it must be refused.
CL_OFFROSTER="$CL_TMP/offroster.txt"
grep -vE '^cli-hired' "$CL_CREW_ROSTER" > "$CL_OFFROSTER"
crew_off() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_CONFIG_DIR="$CL_CONFIG" CREW_ROSTER="$CL_OFFROSTER" \
    timeout 60 "$CL_ROOT/cli/crew" "$@" </dev/null > "$CL_TMP/crew-out" 2>&1 || CL_RC=$?
}
# The guard compares the registry the BOX carries against the fleet's, so the
# box has to carry the fleet's for "production" to mean anything here. It used
# to line up by coincidence: stub-box hands back a hard-coded
# ceremony/incubator/rig for `~/duty/repos.txt`, and that was a copy of what
# examples/repos.txt held, which the fallback made the production registry. Two
# unrelated files agreeing by looking the same. Written from $CL_CONFIG's own
# registry instead, so the case says what it is testing and cannot pass or fail
# on the stub's default drifting.
cp "$CL_CONFIG/repos.txt" "$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: off-roster + production registry is REFUSED"
else
  fail "crew hire: off-roster + production registry is REFUSED" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# The refusal must be overridable, or an operator who means it has no way
# through and will reach for something worse.
crew_off hire cli-hired --role builder --agent claude --allow-offroster
if [ "$CL_RC" -eq 0 ] && grep -q 'allow-offroster' "$CL_TMP/crew-out"; then
  ok "crew hire: --allow-offroster arms it, and says that is what happened"
else
  fail "crew hire: --allow-offroster arms it, and says that is what happened" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# A registry that shares NOTHING with production is not production, so the
# same off-roster box is fine — which is the state drill/rehearsal.sh leaves a
# drill box in while it runs. "Shares nothing with", not "differs from" (#328):
# the cases under the #488 heading below are where the two come apart.
echo "drill-host/crew-drill-sandbox" > "$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -eq 0 ]; then
  ok "crew hire: off-roster with a DISJOINT sandbox registry is allowed"
else
  fail "crew hire: off-roster with a DISJOINT sandbox registry is allowed" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-hired.repos"

# --- a box narrowed by SELECTION is narrowed, never dirty (#488) ------------
#
# The operator's direction of 2026-08-29: a droid's watch set is drawn from the
# host-level list and the per-box feature toggles over that list, so `crew
# status` and its neighbours "should be aware of this and not mark a member as
# dirty". hire_guard is where that reading bites, and only on the branch where
# the box has NO ~/duty/repos.txt yet: install.sh is about to seed one, and
# what it seeds is this box's own selection. Reading the fleet-wide list there
# called a selected box a production one and refused it over a registry it was
# never going to carry — a narrowed member read as dirty, exactly.
#
# An EMPTY state file is the box with no registry: stub-box `cat`s that file
# and succeeds, so box_registry comes back empty, which is the branch under
# test. `rm` would take the stub's hard-coded fallback instead and never reach
# it.
#
# Two entries fleet-wide, because a selection has to be a PROPER subset for the
# case below to mean anything: with a one-line registry the only subsets are
# the whole thing and nothing, and "nothing" would pass this guard for the
# uninteresting reason that an empty string shares nothing with anything.
printf 'heavy-duty/crew\nheavy-duty/box\n' >"$CL_CONFIG/repos.txt"
: >"$CL_TMP/crew-state/cli-hired.repos"
# THE CONTROL FIRST, or the case under it proves nothing. With no selection the
# box inherits the whole fleet-wide list, which IS production, and #51's
# refusal must still stand — a resolver that read every box as narrowed would
# pass the case below while silently disarming the guard.
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: a box with no registry yet inherits, and production is still refused"
else
  fail "crew hire: a box with no registry yet inherits, and production is still refused" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# A box with a SELECTION is read as carrying its selection, not the fleet-wide
# list (#488 D6) — and a selection that keeps a production repository is
# STILL production (#328). The two halves are asserted apart, because each
# has a way to fail alone: a guard that let the subset through is the
# "differs from" predicate back, #51's second agent racing the fleet for the
# one board it kept; a guard that refused it over `heavy-duty/crew` — a
# repository this box was never going to carry — is the "dirty member" read
# the operator ruled out on 2026-08-29. The refusal names what is actually
# shared, which is the selection, and nothing outside it.
mkdir -p "$CL_CONFIG/repos.d"
printf 'heavy-duty/box\n' >"$CL_CONFIG/repos.d/cli-hired.txt"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: ...while a SELECTION that keeps a production repository is REFUSED"
else
  fail "crew hire: ...while a SELECTION that keeps a production repository is REFUSED" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
CL_SHAREDLINE="$(grep -A1 'shares with the fleet' "$CL_TMP/crew-out" | tail -1 || true)"
case "$CL_SHAREDLINE" in
  *'heavy-duty/crew'*) CL_R1=WIDENED ;;
  *'heavy-duty/box'*)  CL_R1=shared ;;
  *)                   CL_R1="SILENT: $CL_SHAREDLINE" ;;
esac
t "crew hire: ...and the refusal names the shared repository, not the whole fleet list" shared "$CL_R1"
# A selection that names EVERY production repository is the production
# registry under another file, and refuses the same way — naming all of it.
printf 'heavy-duty/crew\nheavy-duty/box\n' >"$CL_CONFIG/repos.d/cli-hired.txt"
crew_off hire cli-hired --role builder --agent claude
CL_SHAREDLINE="$(grep -A1 'shares with the fleet' "$CL_TMP/crew-out" | tail -1 || true)"
if [ "$CL_RC" -ne 0 ] && [[ "$CL_SHAREDLINE" == *'heavy-duty/crew'* && "$CL_SHAREDLINE" == *'heavy-duty/box'* ]]; then
  ok "crew hire: ...and a selection IDENTICAL to production is refused naming all of it"
else
  fail "crew hire: ...and a selection IDENTICAL to production is refused naming all of it" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# --allow-offroster still carries through, and its NOTE names the shared
# repository too: the operator who means it is told what they are arming.
printf 'heavy-duty/box\n' >"$CL_CONFIG/repos.d/cli-hired.txt"
crew_off hire cli-hired --role builder --agent claude --allow-offroster
if [ "$CL_RC" -eq 0 ] && grep -q 'allow-offroster' "$CL_TMP/crew-out" \
   && grep -q 'heavy-duty/box' <<<"$(grep 'allow-offroster' "$CL_TMP/crew-out")"; then
  ok "crew hire: ...and --allow-offroster arms the subset, naming what it shares"
else
  fail "crew hire: ...and --allow-offroster arms the subset, naming what it shares" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# And the line names what install.sh will actually seed. An operator told
# `heavy-duty/crew heavy-duty/box` here would be reading a claim about a board
# this box is never going to see — the print half of the same defect, and the
# half that survives a guard someone later passes --allow-offroster to.
CL_SEEDLINE="$(grep 'registry: none yet' "$CL_TMP/crew-out" || true)"
case "$CL_SEEDLINE" in
  *'heavy-duty/crew'*) CL_R1=WIDENED ;;
  *'heavy-duty/box'*)  CL_R1=selection ;;
  *)                   CL_R1=SILENT ;;
esac
t "crew hire: ...and names the selection it will be seeded with" selection "$CL_R1"
# CONTAINMENT REACHES THE GUARD TOO. A selection naming a repository the
# fleet-wide list no longer holds must not widen what this box is read as
# carrying — the read-time intersection floor/registry.py's `effective` applies,
# applied by the same resolver here. Written past any validator by hand,
# because nothing on the floor will write it.
printf 'heavy-duty/box\nheavy-duty/retired\n' >"$CL_CONFIG/repos.d/cli-hired.txt"
crew_off hire cli-hired --role builder --agent claude
CL_SEEDLINE="$(grep 'registry: none yet' "$CL_TMP/crew-out" || true)"
case "$CL_SEEDLINE" in
  *'heavy-duty/retired'*) CL_R1=SMUGGLED ;;
  *'heavy-duty/box'*)     CL_R1=contained ;;
  *)                      CL_R1=SILENT ;;
esac
t "crew hire: ...with a stale selection intersected, not carried" contained "$CL_R1"
# A box selected down to NOTHING is a supported state, not a missing one, so
# the line has to say that rather than end after "seed " with nothing behind
# it — an operator reading a sentence that trails off cannot tell an empty
# selection from a print that broke.
: >"$CL_CONFIG/repos.d/cli-hired.txt"
crew_off hire cli-hired --role builder --agent claude
CL_SEEDLINE="$(grep 'registry: none yet' "$CL_TMP/crew-out" || true)"
case "$CL_SEEDLINE" in
  *'selects no repositories'*) CL_R1=said ;;
  *'seed'?)                    CL_R1=TRAILED-OFF ;;
  *)                           CL_R1="UNEXPECTED: $CL_SEEDLINE" ;;
esac
t "crew hire: ...and an empty selection is named as one, not left trailing" said "$CL_R1"
# And it HIRES, as it did under `!=`: a box aimed at no board shares nothing
# with production, and is the containment state repos.txt's header describes,
# not a refusal (#328).
t "crew hire: ...and an empty selection still hires, as before" 0 "$CL_RC"
rm -rf "$CL_CONFIG/repos.d"

# --- ONE READER ON BOTH SIDES OF THE PRODUCTION COMPARISON (#488) ----------
#
# `hire_guard` asked `[ "$reg" != "$prod" ]` (now: does `$reg` share nothing
# with `$prod`, #328 — an exact-entry match either way), and since the block
# above both sides DERIVE from the fleet-wide file rather than one being
# assigned from the other: `$reg` through `resolved_registry` →
# `registry_entries`, which strips each line, and `$prod` through
# `production_registry`, which used to hand back raw ones. Two readers of one
# file disagreeing about whitespace, feeding a comparison whose every
# difference is read as "narrowed" and returns 0. One trailing space or a CRLF
# in a hand-edited `repos.txt` and #51's refusal is gone, with the guard's own
# line still printing the production registry back.
#
# Every case above misses it for one reason: they all write
# `printf 'heavy-duty/crew\nheavy-duty/box\n'`, clean lines on both sides, so
# the two readers agree by accident. These write the file an operator actually
# leaves behind — and the branch had already conceded the state is real, by
# fixing the transport half of it (`an indented fleet-wide entry still reaches
# a box that selected it`) while leaving the guard half standing.
printf 'heavy-duty/crew \nheavy-duty/box\n' >"$CL_CONFIG/repos.txt"
: >"$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: a trailing space in the fleet-wide list does not disarm the refusal"
else
  fail "crew hire: a trailing space in the fleet-wide list does not disarm the refusal" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# CRLF for the same reason `box_registry` has carried `tr -d '\r'` since before
# this branch: it is a state these files have been repaired for already.
printf 'heavy-duty/crew\r\nheavy-duty/box\r\n' >"$CL_CONFIG/repos.txt"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: ...and neither does a CRLF one"
else
  fail "crew hire: ...and neither does a CRLF one" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# THE CONTROL, or the two above are satisfied by a guard that refuses
# everything: under the same CRLF list, a box carrying a DISJOINT sandbox
# registry is still allowed. A selection cannot serve as the control any more
# — it is a subset of the list by construction, so it shares with it (#328).
echo "drill-host/crew-drill-sandbox" > "$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -eq 0 ]; then
  ok "crew hire: ...while a DISJOINT sandbox under the same list is still allowed"
else
  fail "crew hire: ...while a DISJOINT sandbox under the same list is still allowed" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-hired.repos"
# THE SAME ASYMMETRY FROM THE OTHER SIDE, and this half predates #488:
# `box_registry` reads the registry the box CARRIES and strips `\r` but never
# spaces, so a carried production registry with one trailing space compares
# unequal to the fleet's and the box is armed against production anyway. Same
# `!=`, same disarm, reached without any selection at all.
printf 'heavy-duty/crew\nheavy-duty/box\n' >"$CL_CONFIG/repos.txt"
printf 'heavy-duty/crew \nheavy-duty/box\n' >"$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: a trailing space in the box's OWN registry does not disarm it either"
else
  fail "crew hire: a trailing space in the box's OWN registry does not disarm it either" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-hired.repos"
printf 'heavy-duty/crew\n' >"$CL_CONFIG/repos.txt"

# The registry must be PRINTED either way: #51's second bullet. A guard that
# only speaks up when it refuses leaves the normal path as silent as before.
crew_cmd hire cli-hired --force
if grep -q '  registry:' "$CL_TMP/crew-out"; then
  ok "crew hire: prints the registry it is arming against"
else
  fail "crew hire: prints the registry it is arming against" "$(cat "$CL_TMP/crew-out")"
fi

# --- one bad box must not abort the fleet (#49) ----------------------------
# crew's top-level `set -e` killed hire-all on the first failure, so a single
# box with an unusable ~/crew blocked every box after it. Asserted over the
# source: the fixture fleet has no way to make a hire fail part-way.
# The call must stay STATUS-CAPTURING rather than bare. `|| rc=$?` replaced the
# `if hire_box …; then` form when hire_box grew a third answer (#220: 0 hired,
# 3 skipped, anything else failed) — the property is unchanged and is the only
# thing asserted here: whatever hire_box returns, `set -e` must not see it.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'hire_box "\$name" "\$agent" "\$role" "\$ref" 0 || rc=\$?' "$CL_ROOT/cli/crew"; then
  ok "crew hire-all: a failing box is caught, not fatal"
else
  fail "crew hire-all: a failing box is caught, not fatal" "the bare hire_box call is back — set -e will abort the fleet"
fi
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'hire-all: \$hired hired, \$skipped skipped, \$failed failed' "$CL_ROOT/cli/crew"; then
  ok "crew hire-all: summarises what it could not do"
else
  fail "crew hire-all: summarises what it could not do" "no failure summary — a partial fleet reads as a whole one"
fi
# ---------------------------------------------------------------------------
# A box whose tenant role never converged (#220).
#
# The reported case: `rig bootstrap` FAILED on one of seven boxes, `box` said
# so unambiguously, and `crew status` moments later reported it as one of seven
# equals — same `running`, same `not hired`, same `unknown`/`unknown`, and a
# NOTE inviting the operator to hire a box that cannot run its agent. Every
# assertion below fails against the pre-#220 CLI, which is what makes them
# worth having.
#
# The three verdicts have to stay separable, and the fixture provides all
# three: cli-unconverged answers with NO marker, cli-unreachable answers
# nothing at all, and cli-nothired is healthy and merely un-hired.
# ---------------------------------------------------------------------------
echo
echo "== crew: rig convergence (#220)"

crew_cmd status
CL_UNCONV="$(grep '^cli-unconverged ' "$CL_TMP/crew-out" || true)"

# 1. The reported case: it must READ as broken.
if grep -q 'INCOMPLETE' <<<"$CL_UNCONV"; then
  ok "crew status: an unconverged box reads INCOMPLETE"
else
  fail "crew status: an unconverged box reads INCOMPLETE" "${CL_UNCONV:-no row at all}"
fi

# 2. …and the NOTE must stop advising the verb that breaks the fleet. This is
#    the half that cost the operator: the table did not merely fail to warn,
#    it actively pointed at `crew hire`.
if grep -q 'rig bootstrap' <<<"$CL_UNCONV" &&
   ! grep -q 'crew hire cli-unconverged' <<<"$CL_UNCONV"; then
  ok "crew status: the note names the bootstrap recovery, not crew hire"
else
  fail "crew status: the note names the bootstrap recovery, not crew hire" "$CL_UNCONV"
fi

# 3. The recovery names the box's OWN tenant, not a generic one — the roster
#    says kimi, so the command an operator pastes has to say kimi-box.
if grep -q 'rig bootstrap kimi-box' <<<"$CL_UNCONV"; then
  ok "crew status: the recovery names the box's own tenant role"
else
  fail "crew status: the recovery names the box's own tenant role" "$CL_UNCONV"
fi

# 4. THE FALSE NEGATIVE, which would be worse than the bug. A healthy un-hired
#    box must be untouched: still `crew hire`, no INCOMPLETE, no new noise. A
#    fix that refuses real boxes is a fleet outage, not a safety feature.
CL_NOTHIRED="$(grep '^cli-nothired ' "$CL_TMP/crew-out" || true)"
if grep -q 'crew hire cli-nothired' <<<"$CL_NOTHIRED" &&
   ! grep -qE 'INCOMPLETE|unknown —' <<<"$CL_NOTHIRED"; then
  ok "crew status: a converged un-hired box is unchanged"
else
  fail "crew status: a converged un-hired box is unchanged" "${CL_NOTHIRED:-no row at all}"
fi

# 5. The ambiguous case is NAMED, and named differently. `unknown` must not
#    collapse into either neighbour: not into INCOMPLETE (crew did not observe
#    a failed bootstrap, it observed nothing) and certainly not into converged.
CL_UNREACH="$(grep '^cli-unreachable ' "$CL_TMP/crew-out" || true)"
if grep -q 'convergence unknown' <<<"$CL_UNREACH"; then
  ok "crew status: an unreachable box reports convergence unknown"
else
  fail "crew status: an unreachable box reports convergence unknown" "${CL_UNREACH:-no row at all}"
fi

# 6. THE LOAD-BEARING HALF. Reporting alone still lets a tired operator hire
#    the box the table told them to hire, and hire is the irreversible verb.
crew_cmd hire cli-unconverged
if [ "$CL_RC" -ne 0 ] && grep -q 'REFUSED' "$CL_TMP/crew-out"; then
  ok "crew hire: an unconverged box is refused, non-zero"
else
  fail "crew hire: an unconverged box is refused, non-zero" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# Naming WHAT is missing is the difference between a refusal an operator can
# act on and one they have to go debug.
if grep -q '/etc/rig/role' "$CL_TMP/crew-out" && grep -q 'rig bootstrap kimi-box' "$CL_TMP/crew-out"; then
  ok "crew hire: the refusal names what is missing and how to fix it"
else
  fail "crew hire: the refusal names what is missing and how to fix it" "$(cat "$CL_TMP/crew-out")"
fi
# It must refuse BEFORE it installs anything. A refusal that has already staged
# the engine is not a refusal.
if ! grep -qE 'hiring cli-unconverged|registry:' "$CL_TMP/crew-out"; then
  ok "crew hire: the refusal comes before any transport or registry work"
else
  fail "crew hire: the refusal comes before any transport or registry work" "$(cat "$CL_TMP/crew-out")"
fi

# 7. The unreachable box refuses too — rule 5 of the spec. The failure mode
#    being closed is a broken box passing for a healthy one, so the case crew
#    cannot see into must refuse rather than proceed.
crew_cmd hire cli-unreachable
if [ "$CL_RC" -ne 0 ] && grep -q 'did not answer' "$CL_TMP/crew-out"; then
  ok "crew hire: an unreachable box is refused, not hired"
else
  fail "crew hire: an unreachable box is refused, not hired" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

# 8. The escape hatch actually hires. An override nobody can use is a wall.
crew_cmd hire cli-unconverged --force
if [ "$CL_RC" -eq 0 ] && grep -q 'hiring anyway (--force)' "$CL_TMP/crew-out"; then
  ok "crew hire --force: the escape hatch still hires"
else
  fail "crew hire --force: the escape hatch still hires" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# …and it stays LOUD. A forced hire of an unconverged box is exactly the member
# that fails every five minutes into a log nobody reads, so the operator who
# asked for it must still be told what they armed.
if grep -q 'NOT CONVERGED' "$CL_TMP/crew-out"; then
  ok "crew hire --force: the override is still loud about what it armed"
else
  fail "crew hire --force: the override is still loud about what it armed" "$(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-unconverged.version"

# 9. BULK. One box must not stop the convergence, and the skip must be counted,
#    named, and reflected in the exit status — a fleet short a member that
#    exits 0 is the same silent partial outage, one level up.
#     The fixture skips THREE, and the spread is the point: cli-unconverged
#     answered and has no marker, while cli-stopped and cli-unreachable answered
#     nothing at all. All three refuse — an unreadable marker is not converged —
#     and all three are skips rather than failures, because none of them was
#     ever eligible to be hired.
crew_cmd hire-all
if grep -qE 'hire-all: [0-9]+ hired, 3 skipped, 0 failed' "$CL_TMP/crew-out"; then
  ok "crew hire-all: an ineligible box is counted as a skip, not a failure"
else
  fail "crew hire-all: an ineligible box is counted as a skip, not a failure" \
       "$(grep '^hire-all:' "$CL_TMP/crew-out" || cat "$CL_TMP/crew-out")"
fi
if grep -q 'not confirmed converged.*cli-unconverged' "$CL_TMP/crew-out"; then
  ok "crew hire-all: the skipped box is NAMED, not just counted"
else
  fail "crew hire-all: the skipped box is NAMED, not just counted" "$(cat "$CL_TMP/crew-out")"
fi
# The summary must not assert the STRONGER fact about the whole set. A box that
# is merely switched off has not failed a bootstrap, and sending an operator to
# `rig bootstrap` for it is a new wrong answer in place of the old one.
CL_SKIPLINE="$(grep '^  not confirmed converged' "$CL_TMP/crew-out" || true)"
if [ -n "$CL_SKIPLINE" ] && ! grep -q 'rig bootstrap' <<<"$CL_SKIPLINE"; then
  ok "crew hire-all: the summary does not blame a bootstrap it did not observe"
else
  fail "crew hire-all: the summary does not blame a bootstrap it did not observe" \
       "${CL_SKIPLINE:-no summary line at all}"
fi
# …and the stopped box's own reason is the honest one.
CL_STOPPED_REFUSAL="$(grep -A2 '^cli-stopped: REFUSED' "$CL_TMP/crew-out")"
if grep -q 'did not answer' <<<"$CL_STOPPED_REFUSAL"; then
  ok "crew hire-all: a stopped box is refused for being unreadable, not unbootstrapped"
else
  fail "crew hire-all: a stopped box is refused for being unreadable, not unbootstrapped" \
       "$(grep -A2 '^cli-stopped' "$CL_TMP/crew-out")"
fi
t "crew hire-all: a skip is not success" 1 "$CL_RC"
# The healthy boxes in the same run were still hired — the whole point of a
# skip rather than an abort. cli-unconverged is LAST in the roster, so this
# also proves the loop reached the end.
if grep -qE '^hire-all: [1-9][0-9]* hired' "$CL_TMP/crew-out"; then
  ok "crew hire-all: healthy boxes are still hired in the same run"
else
  fail "crew hire-all: healthy boxes are still hired in the same run" \
       "$(grep '^hire-all:' "$CL_TMP/crew-out")"
fi

# 10. `crew up --dry-run` is what an operator reads BEFORE the irreversible
#     verb, so it is the last cheap place to stop the lie the NOTE told.
crew_cmd up --dry-run
if grep -qE '^cli-unconverged: WOULD SKIP' "$CL_TMP/crew-out"; then
  ok "crew up --dry-run: does not say WOULD hire about a box it would refuse"
else
  fail "crew up --dry-run: does not say WOULD hire about a box it would refuse" \
       "$(grep '^cli-unconverged' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-nothired: WOULD hire' "$CL_TMP/crew-out"; then
  ok "crew up --dry-run: a converged box still reads WOULD hire"
else
  fail "crew up --dry-run: a converged box still reads WOULD hire" \
       "$(grep '^cli-nothired' "$CL_TMP/crew-out")"
fi

# 11. The single-box view carries rig's provenance — the marker line itself and
#     which rig wrote it. The table has room for one clause; this is where an
#     operator who opened one box gets the rest.
#     The version is asserted BARE, as rig writes it (`converged_by=0.3.2-dev`,
#     no `rig@`), and against the manifest's `converged_*` pair rather than the
#     `bootstrapped_*` one two lines above it — the stub's two pairs differ on
#     purpose, so a read that named the FAMILY (`.*_at=`) rather than the whole
#     key would print the bootstrap's date here, visibly wrong rather than
#     accidentally right. It is a naming discipline, not an anchoring one: the
#     two key names do not overlap, so the `^` in report_field is not what
#     separates them.
crew_cmd status cli-nothired
if grep -qE '^rig: converged — role=.*tenant=yes' "$CL_TMP/crew-out" &&
   grep -qE 'converged by rig 0\.3\.2-dev at ' "$CL_TMP/crew-out" &&
   ! grep -q '0\.3\.1' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a converged box reports its marker and its provenance"
else
  fail "crew status <box>: a converged box reports its marker and its provenance" \
       "$(cat "$CL_TMP/crew-out")"
fi
crew_cmd status cli-unconverged
if grep -q '^rig: INCOMPLETE' "$CL_TMP/crew-out" &&
   grep -q 'rig bootstrap kimi-box' "$CL_TMP/crew-out"; then
  ok "crew status <box>: an unconverged box reports INCOMPLETE and the recovery"
else
  fail "crew status <box>: an unconverged box reports INCOMPLETE and the recovery" \
       "$(cat "$CL_TMP/crew-out")"
fi

# 11b. THE MANIFEST IS CORROBORATING, NEVER LOAD-BEARING — and this is the
#      end-to-end half of it. cli-premanifest carries a valid role line and no
#      /etc/rig/manifest at all, which is what a box converged by a rig older
#      than that file looks like (rig#61). Old, not broken. Gating on a field an
#      older rig never wrote would convert every box on that rig into a refusal,
#      and #220's test plan names that outcome as worse than the bug itself.
#
#      The bulk verbs above already hired it — correctly, it is a healthy box —
#      and the table's marker read is scoped to UN-hired boxes, so put it back
#      the way bring-up finds it first. Without this the table assertion below
#      would pass for the wrong reason: no note at all rather than a hire note.
rm -f "$CL_TMP/crew-state/cli-premanifest.version"
crew_cmd status cli-premanifest
#      The marker's own role name is the stub's, not the roster's — cli.sh sets
#      CREW_ROSTER and not CREW_FLOOR_ROSTER, so stub-box falls back to
#      `claude-box` here exactly as it does for cli-nothired above. What is
#      under test is the verdict without a manifest, so this matches the marker
#      the same generic way that assertion does.
if grep -qE '^rig: converged — role=.*-box tenant=yes host=no' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a converged box with no rig manifest still reads converged"
else
  fail "crew status <box>: a converged box with no rig manifest still reads converged" \
       "$(cat "$CL_TMP/crew-out")"
fi
# It says NOTHING rather than inventing an alarm, an `unknown`, or an empty
# `converged by  at `. A missing provenance file is not a finding.
if ! grep -q 'converged by' "$CL_TMP/crew-out"; then
  ok "crew status <box>: a missing rig manifest is silent, not an alarm"
else
  fail "crew status <box>: a missing rig manifest is silent, not an alarm" \
       "$(grep 'converged by' "$CL_TMP/crew-out")"
fi
# The table row is untouched too — no INCOMPLETE, and the note still offers the
# hire, because this box is genuinely fine.
crew_cmd status
CL_PREMAN="$(grep '^cli-premanifest ' "$CL_TMP/crew-out" || true)"
if grep -q 'crew hire cli-premanifest' <<<"$CL_PREMAN" &&
   ! grep -qE 'INCOMPLETE|unknown —' <<<"$CL_PREMAN"; then
  ok "crew status: a box with no rig manifest is not refused in the table"
else
  fail "crew status: a box with no rig manifest is not refused in the table" \
       "${CL_PREMAN:-no row at all}"
fi
# …and the load-bearing half: it HIRES. A refusal here is the fleet outage.
crew_cmd hire cli-premanifest
if [ "$CL_RC" -eq 0 ] && ! grep -q 'REFUSED' "$CL_TMP/crew-out"; then
  ok "crew hire: a converged box with no rig manifest is hired, not refused"
else
  fail "crew hire: a converged box with no rig manifest is hired, not refused" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-premanifest.version"

# 12. `crew up` runs the same roster loop through its OWN call site, and this
#     suite exists partly because #47 and #48 were each present twice — once in
#     `crew status`, once in `crew up` — so fixing one copy left the other
#     broken. The skip is proved at that call site rather than inferred from
#     hire-all's.
#
#     It skips TWO here, not three: `up` starts a stopped box before hiring it,
#     so cli-stopped converges and is hired in the same run. That difference is
#     the assertion — `up` is the steady-state verb and must not refuse a box
#     merely because it found it switched off.
crew_cmd up
if grep -qE '^up: 2 box\(es\) SKIPPED' "$CL_TMP/crew-out" &&
   grep -q 'cli-unconverged' "$CL_TMP/crew-out"; then
  ok "crew up: skips the unconverged box, counts it, and names it"
else
  fail "crew up: skips the unconverged box, counts it, and names it" \
       "$(grep -E '^up:' "$CL_TMP/crew-out" || cat "$CL_TMP/crew-out")"
fi
t "crew up: a skip is not success" 1 "$CL_RC"
if grep -qE '^cli-stopped: started|^cli-stopped ' "$CL_TMP/crew-out" ||
   grep -q 'started' "$CL_TMP/crew-out"; then
  ok "crew up: a stopped box is started, then hired — not skipped for being off"
else
  fail "crew up: a stopped box is started, then hired — not skipped for being off" \
       "$(cat "$CL_TMP/crew-out")"
fi
# Every healthy box still converged in the same run — the point of a skip
# rather than an abort. cli-unconverged is the skip, and cli-premanifest sits
# BELOW it in the roster, so a loop that aborted on the skip never reaches it.
#
# Read the OUTCOME, never the arm: `hire_box` prints `hiring <box>` when it
# bakes and `<box>: already hired … matches, skipping` when the installed
# version already equals the engine's, and which one fires is the documented
# version split — a `-dev` tree re-bakes unconditionally, a release tree skips a
# box already at the matching version. So `grep hiring cli-disarmed`, the shape
# this case carried until #323, asserted that the tree was `-dev`: it redded on
# every bare-`VERSION` tree and only there, which is exactly once per release
# and never in between. Either line means the loop reached the box, which is
# what "still hired" is about; the engine is untouched.
cl_hire_line() {
  grep -nE "^hiring $1 |^$1: already hired at .* matches, skipping\$" \
    "$CL_TMP/crew-out" | head -1 | cut -d: -f1
}
# For the failure detail: where the box was seen, or that it was not.
cl_hire_where() {
  if [ -n "$1" ]; then echo "at output line $1"; else echo "never reached"; fi
}
CL_DISARMED_AT="$(cl_hire_line cli-disarmed)"
CL_PREMANIFEST_AT="$(cl_hire_line cli-premanifest)"
if [ -n "$CL_DISARMED_AT" ] && [ -n "$CL_PREMANIFEST_AT" ] &&
   [ "$CL_PREMANIFEST_AT" -gt "$CL_DISARMED_AT" ]; then
  ok "crew up: healthy boxes past the skip are still hired"
else
  # Name the two boxes and what was read of each. The detail this replaces
  # claimed "the loop stopped before the end of the roster" — a diagnosis the
  # captured output contradicted, the roster having run to completion (#323).
  fail "crew up: healthy boxes past the skip are still hired" \
       "expected cli-premanifest hired after cli-disarmed: cli-disarmed $(cl_hire_where "$CL_DISARMED_AT"), cli-premanifest $(cl_hire_where "$CL_PREMANIFEST_AT")"
fi
# `box start` wrote a state override; put the fixture back so the rows below
# see the fleet the fixture file declares.
rm -f "$CL_TMP/crew-state/cli-stopped.state"

# 13. THE BUDGET. Convergence is read only for UN-HIRED boxes, so a healthy
#     steady-state fleet pays no extra round trip at all. Asserted over the
#     source rather than by counting calls: the read has to sit inside the
#     `[ -z "$hired" ]` arm, and a later edit that hoists it out of there would
#     add one exec per box per invocation to the verb an operator runs most.
CL_RIGCALL="$(awk '
  /^cmd_status\(\)/ { inf = 1 }
  inf && /if \[ -z "\$hired" \]; then/ { arm = 1 }
  inf && arm && /rig_report/ { print "in-arm"; exit }
  inf && arm && /^    fi$/ { exit }
' "$CL_CLI")"
t "crew status: the marker is read only for un-hired boxes" in-arm "${CL_RIGCALL:-hoisted}"

# The old #49 origin-repair surface disappears with the box-side checkout.
if ! grep -qE 'git clone|remote get-url origin|git -C ~/crew (fetch|pull|checkout)' "$CL_ROOT/cli/crew"; then
  ok "crew hire: no box-side checkout or origin repair remains"
else
  fail "crew hire: no box-side checkout or origin repair remains" \
       "a box-side crew repository command is still present"
fi


# --- a drill must never need to edit the tracked roster --------------------
# Editing fleet.roster to point a drill at a subset is not a tidiness point: the
# #51 registry guard keys on ROSTER MEMBERSHIP, so a drill box listed in
# fleet.roster is a fleet member as far as every safety check is concerned.
# That is how three leftover drill boxes came to be armed against production.
#
# So both readers take an override, and the drill feeds ONE file to all three
# consumers — the collector, the `crew status` it compares against, and its own
# counts. An agreement assertion across two different rosters is worse than no
# assertion, because it looks like one.
echo
echo "== roster overrides (drilling without touching fleet.roster)"

crew_floor --local --port 8892 --roster "$CL_CREW_ROSTER"; CL_OUT="$(cl_out)"
if grep -qF "$CL_CREW_ROSTER" <<<"$CL_OUT"; then
  ok "cli: crew floor --roster is echoed in the banner"
else
  fail "cli: crew floor --roster is echoed in the banner" "$CL_OUT"
fi
crew_floor --local --port 8891 --roster /nonexistent/roster.txt; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ] && grep -q "no roster at" <<<"$CL_OUT"; then
  ok "cli: a missing --roster is named at startup"
else
  fail "cli: a missing --roster is named at startup" "rc=$CL_RC out=$CL_OUT"
fi
crew_floor --local --port 8890; CL_OUT="$(cl_out)"
if grep -q '^  roster ' <<<"$CL_OUT"; then
  ok "cli: crew floor always prints the roster it watches"
else
  fail "cli: crew floor always prints the roster it watches" "$CL_OUT"
fi

# The drill must hand the SAME path to every reader. Asserted over the source:
# a real run needs a host with boxes, and the property wanted is "one list",
# which no single invocation demonstrates.
CL_DRILL_APP="$CL_ROOT/drill/rehearsal-app.sh"
for CL_V in CREW_FLOOR_ROSTER CREW_ROSTER; do
  # shellcheck disable=SC2016  # matching the literal source assignment
  if grep -qE "^export $CL_V=\"\\\$ROSTER\"" "$CL_DRILL_APP"; then
    ok "drill: $CL_V comes from --roster"
  else
    fail "drill: $CL_V comes from --roster" \
         "the collector and the CLI can now be compared across two different rosters"
  fi
done
# ...and nothing may still read fleet.roster directly, which would silently
# reintroduce exactly that split.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_DIRECT="$(grep -vE '^[[:space:]]*#' "$CL_DRILL_APP" | grep -cE '\$ROOT/examples/fleet\.roster' || true)"
t "drill: examples/fleet.roster is read only as the --roster default" 1 "${CL_DIRECT:-0}"
if [ "${CL_DIRECT:-0}" -ne 1 ]; then
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
  grep -nvE '^[[:space:]]*#' "$CL_DRILL_APP" | grep -E '\$ROOT/examples/fleet\.roster' | sed 's/^/    /'
fi

# --- a clone is sized only where this host's box can size one (#607 D5) -----
# The sizing flags on a clone were removed because `box new --from` rejected
# them outright — "a clone carries its source's resources" — so every roster
# line with a 4th-column gold snapshot died at create (#590). box 0.10.0
# reverses that: the flags ride the copy, incus sizing the clone's volume as it
# creates it (box#171). Both boxes are still in the fleet, so what is asserted
# here is not "flags" or "no flags" but that the choice is PROBED — an
# unconditional pass re-breaks #590 on every pre-0.10.0 host.
#
# Source-level, and deliberately so: shared/test/cli-lifecycle.sh drives both
# branches through a box shim and asserts the argv each produces. This says the
# unguarded shape cannot come back, which no single invocation shows.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_FROM="$(sed -n '/if \[ -n "\$from" \]; then/,/^  else/p' "$CL_ROOT/cli/crew")"
if grep -q 'box new --name' <<<"$CL_FROM" &&
   grep -q 'box_supports_clone_sizing' <<<"$CL_FROM"; then
  ok "crew: a --from clone is sized only behind the box capability probe"
else
  fail "crew: a --from clone is sized only behind the box capability probe" \
       "box before 0.10.0 refuses --cpu/--memory/--disk on --from; an unguarded pass fails every gold-snapshot roster line"
fi
# The probe must fail CLOSED, which is what makes the guard above safe on a
# host whose box cannot answer at all: no help text, no sizing flags.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_PROBE="$(sed -n '/^box_supports_clone_sizing() {/,/^}/p' "$CL_ROOT/cli/crew")"
if grep -q 'box new --help' <<<"$CL_PROBE" && grep -q 'grep -qE' <<<"$CL_PROBE"; then
  ok "crew: the clone-sizing probe reads box's own help and matches a needle"
else
  fail "crew: the clone-sizing probe reads box's own help and matches a needle" \
       "a version comparison is a proxy for the capability, and gets a fork or a local build wrong"
fi
# --disk NEVER RIDES A COPY, and this is the assertion the whole block exists
# for now. box serves --disk on a --from only where the SOURCE has a root
# device of its own; a VM whose root is profile-inherited, or a source box
# cannot read, makes it refuse and die BEFORE `incus copy`, so nothing is
# created. That is #590 one layer further in, and the probe cannot see it — the
# root device is a property of the source, not of the binary. Triage ruled it
# out on #607 in as many words: no branch of this fix may turn a roster line
# that mints today into one that does not.
#
# Read off the INVOCATIONS and not off the block, with the backslash
# continuations joined first so a flag on the second line is still part of the
# command it belongs to. The block's own prose names --disk — the report tells
# the operator which flag was withheld, and it should — so a block-wide grep
# would red on the message explaining the guard.
CL_FROM_NEW="$(sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' <<<"$CL_FROM" \
  | grep -E '^[[:space:]]*box new ' || true)"
# Vacuity first: an extraction that matched nothing passes the --disk check
# below for the worst possible reason, and the sed above is exactly the kind of
# thing that goes silently empty when the source is reformatted.
t "crew: both clone branches invoke box new" 2 "$(grep -c . <<<"$CL_FROM_NEW" || true)"
if ! grep -q -- '--disk' <<<"$CL_FROM_NEW"; then
  ok "crew: a --from clone is never handed --disk"
else
  fail "crew: a --from clone is never handed --disk" \
       "box refuses --disk on a copy from a profile-rooted or unreadable source, before anything is created — the clone would not mint at all"
  grep -n -- '--disk' <<<"$CL_FROM_NEW" | sed 's/^/    /'
fi
# EVERY clone reports, sized or not. With --disk withheld by construction the
# best case is a PARTIAL landing — cpu and memory at the role's size, disk at
# the snapshot's — and #607's criterion 5 as amended says a partial landing is
# legitimate and must be said out loud. A branch that printed nothing because
# two of three figures rode would be the silent case in better clothes.
#
# Counted per BRANCH, not once for the block: an earlier cut asserted the call
# existed somewhere inside, and that is satisfied by a block reporting on one
# of its two paths.
CL_FROM_REPORTS="$(grep -c 'clone_size_report ' <<<"$CL_FROM" || true)"
t "crew: both clone branches report what landed" 2 "${CL_FROM_REPORTS:-0}"
# ...and the report is ONE line, per figure, naming the box and both sizes.
#
# Matched on the ECHO and not on the words: the text sitting somewhere in the
# function is not the property — being PRINTED is. An earlier cut of this
# assertion read the whole block, and a mutation turning the echo into a no-op
# left every needle in place and the note unprinted, which is precisely the
# silent case (#607 D5's "must not silently mint").
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_REPORT="$(sed -n '/^clone_size_report() {/,/^}/p' "$CL_ROOT/cli/crew")"
CL_NOTE="$(grep -E '^[[:space:]]*echo "note: ' <<<"$CL_REPORT" || true)"
t "crew: the clone report is exactly one line" 1 \
  "$(grep -c . <<<"$CL_NOTE" || true)"
CL_REPORT_MISSING=""
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
for cl_needle in 'size_verdict "$asked" cpu' 'size_verdict "$asked" memory' \
                 'size_verdict "$asked" disk' 'box_size_fields' \
                 'profile asks $want_cpu'; do
  grep -qF -- "$cl_needle" <<<"$CL_REPORT" \
    || CL_REPORT_MISSING="$CL_REPORT_MISSING $cl_needle"
done
if [ -z "$CL_REPORT_MISSING" ]; then
  ok "crew: the clone report answers per figure, off a size read back off the daemon"
else
  fail "crew: the clone report answers per figure, off a size read back off the daemon" \
       "missing:$CL_REPORT_MISSING — a report that states a size crew never read, or that answers the three figures as one"
fi
# The verdict vocabulary cannot claim a landing crew did not verify: a figure
# crew never asked for, or one that reads back as something else, is NOT
# applied, and one that does not read back at all says so rather than being
# counted as a success.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_VERDICT="$(sed -n '/^size_verdict() {/,/^}/p' "$CL_ROOT/cli/crew")"
if grep -q "printf 'NOT applied" <<<"$CL_VERDICT" &&
   grep -q "printf 'unverified" <<<"$CL_VERDICT" &&
   grep -q "printf 'applied" <<<"$CL_VERDICT"; then
  ok "crew: a figure crew did not ask for, or cannot verify, is never reported as applied"
else
  fail "crew: a figure crew did not ask for, or cannot verify, is never reported as applied" \
       "the verdict collapses to two answers, and the one it loses is the unread figure"
fi

# The status table must fit the names it prints. `crew-drill-reviewer` is 19
# characters and overflowed an 18-wide column, shifting every field after it.
CL_W="$(sed -n "s/^  local fmt='%-\([0-9]*\)s .*/\1/p" "$CL_ROOT/cli/crew")"
CL_LONGEST=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  [ "${#cl_name}" -gt "$CL_LONGEST" ] && CL_LONGEST="${#cl_name}"
done < <(cat "$CL_ROOT/examples/fleet.roster" "$CL_HERE/fixtures/roster.txt" \
              "$CL_HERE/fixtures/cli-roster.txt" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
# Drill boxes are crew-drill-<role>; the longest role is 'reviewer'.
[ "$CL_LONGEST" -lt 19 ] && CL_LONGEST=19
if [ -n "$CL_W" ] && [ "$CL_W" -gt "$CL_LONGEST" ]; then
  ok "crew status: MEMBER column ($CL_W) is wider than the longest box name ($CL_LONGEST)"
else
  fail "crew status: MEMBER column is wider than the longest box name" \
       "column=${CL_W:-?} longest=$CL_LONGEST — the row's remaining fields shift right"
fi


# --- the drill's own harness -----------------------------------------------
# Every check below is a bug that cost a live session on a real host. They are
# all the same shape: a precondition or a premise that does not hold, reported
# as a verdict about the thing under test.
echo
echo "== drill harness (preconditions, artifacts, defaults)"

CL_APP="$CL_ROOT/drill/rehearsal-app.sh"

# --drill-roles generates the roster from the crew-drill-<role> convention, so
# nobody hand-maintains a second copy of a naming rule rehearsal.sh owns.
# Deliberately run WITHOUT a `box` on PATH, so the drill stops at the host check
# — the first thing after roster generation. Reaching that message proves the
# flag parsed and the generated roster passed the `[ -f ]` guard, without
# starting a collector. Standalone this happens for free; sourced from run.sh
# the stub-box is on PATH, which is why the path is stripped explicitly rather
# than assumed (this assertion failed exactly that way once).
CL_NOBOX_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$CL_TMP/bin" | paste -sd: -)"
if PATH="$CL_NOBOX_PATH" command -v box >/dev/null 2>&1; then
  skip "drill: --drill-roles parses and reaches the host check" "a real box CLI is on PATH"
else
  CL_RC=0
  PATH="$CL_NOBOX_PATH" "$CL_APP" --drill-roles "triage builder" >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
  if grep -q "no 'box' on PATH" "$CL_TMP/app.out"; then
    ok "drill: --drill-roles parses and reaches the host check"
  else
    fail "drill: --drill-roles parses and reaches the host check" "$(head -3 "$CL_TMP/app.out")"
  fi
fi
CL_RC=0; "$CL_APP" --drill-roles triage --roster /tmp/x >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'alternatives, not both' "$CL_TMP/app.out"; then
  ok "drill: --roster and --drill-roles are mutually exclusive"
else
  fail "drill: --roster and --drill-roles are mutually exclusive" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
CL_RC=0; "$CL_APP" --drill-roles nosuchrole >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q "unknown role" "$CL_TMP/app.out"; then
  ok "drill: --drill-roles refuses a role that is not a role"
else
  fail "drill: --drill-roles refuses a role that is not a role" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
CL_RC=0; "$CL_APP" --roster /nonexistent/r.txt >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'no roster at' "$CL_TMP/app.out"; then
  ok "drill: a missing --roster is named before anything starts"
else
  fail "drill: a missing --roster is named before anything starts" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi

# The browser precondition must check for a BROWSER, not only the module.
# playwright-core ships without browsers on purpose, so `npm i playwright-core`
# flipped this from a clean skip to a run that died on a missing binary — and
# emitted three failures, one of which blamed the read-only walk. A missing
# dependency must never read as a broken floor.
if grep -q 'PW_CHROME' "$CL_APP" && grep -q 'no browser found' "$CL_APP"; then
  ok "drill: a missing browser is its own named skip, not a walk failure"
else
  fail "drill: a missing browser is its own named skip, not a walk failure" \
       "the precondition still checks only that playwright-core is installed"
fi
# ...and it must find a system Chrome itself, the same probe CI does.
CL_PROBE="$(grep -cE '/usr/bin/google-chrome|/opt/google/chrome' "$CL_APP" || true)"
if [ "${CL_PROBE:-0}" -ge 1 ]; then
  ok "drill: probes the usual browser paths so PW_CHROME is an override"
else
  fail "drill: probes the usual browser paths so PW_CHROME is an override" \
       "PW_CHROME is required knowledge again"
fi

# The no-vacuity check must not count something structurally impossible. The
# collector runs at CREW_FLOOR_INTERVAL=3600, so it polls ONCE at startup; the
# walk reads its cached answer over HTTP and never touches the box layer. The
# old check counted probes inside the walk's window and therefore failed every
# run, including one that had just made 15 assertions on a live fleet.
# Comments stripped: the drill EXPLAINS why the old check was removed, and a
# bare grep matched that explanation — a detector tripping on its own
# documentation, which this file has now been caught by three times.
CL_APP_CODE="$(grep -vE '^[[:space:]]*#' "$CL_APP")"
if grep -q "read-only walk still exercised the real fleet" <<<"$CL_APP_CODE"; then
  fail "drill: no-vacuity check does not count probes that cannot happen" \
       "the probe-window check is back; it cannot pass at CREW_FLOOR_INTERVAL=3600"
else
  ok "drill: no-vacuity check does not count probes that cannot happen"
fi
# What replaced it must still guard the real risk: an EMPTY receipt would make
# "issued no control command" pass forever.
if grep -q 'the box-call receipt is real' "$CL_APP"; then
  ok "drill: still proves the box-call receipt is not empty"
else
  fail "drill: still proves the box-call receipt is not empty" \
       "nothing checks the wrapper recorded anything, so the no-control assertion is vacuous"
fi

# Screenshots are described in browser.js as "for humans" — they must survive
# teardown. They were written into $TMP and rm -rf'd on exit, every run.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'node .*browser\.js.*"\$SHOTS"' "$CL_APP"; then
  ok "drill: screenshots go to a directory that outlives the run"
else
  fail "drill: screenshots go to a directory that outlives the run" \
       "the walk still writes into \$TMP, which teardown deletes"
fi
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -qE 'rm -rf -- "\$TMP"' "$CL_APP" && ! grep -qE 'rm -rf.*\$SHOTS' "$CL_APP"; then
  ok "drill: teardown does not delete the screenshots"
else
  fail "drill: teardown does not delete the screenshots" "the shots directory is removed on exit"
fi

# Watching the walk drive: headless must be a choice, not a hardcode.
CL_BJS2="$CL_HERE/browser.js"
if grep -q 'FLOOR_TEST_HEADED' "$CL_BJS2" && grep -q 'headless: !HEADED' "$CL_BJS2"; then
  ok "browser.js: headed mode is available for watching a walk"
else
  fail "browser.js: headed mode is available for watching a walk" "headless is not overridable"
fi
if grep -q 'FLOOR_TEST_SLOWMO' "$CL_BJS2" && grep -q 'slowMo' "$CL_BJS2"; then
  ok "browser.js: slowMo is available"
else
  fail "browser.js: slowMo is available" "no pacing control"
fi
# CI must never turn them on — headed needs a display, and a slowed walk in CI
# is a timeout waiting to happen.
CL_CI_SHELL="$CL_ROOT/.github/workflows/ci-shell.yml"
CL_CI_FLOOR="$CL_ROOT/.github/workflows/ci-floor.yml"
CL_CI_MISSING=""
for CL_CI_WORKFLOW in "$CL_CI_SHELL" "$CL_CI_FLOOR"; do
  [ -r "$CL_CI_WORKFLOW" ] || CL_CI_MISSING="$CL_CI_MISSING $CL_CI_WORKFLOW"
done
if [ -n "$CL_CI_MISSING" ]; then
  fail "CI does not enable headed/slowMo" "missing or unreadable:$CL_CI_MISSING"
elif grep -qE 'FLOOR_TEST_(HEADED|SLOWMO)' "$CL_CI_SHELL" "$CL_CI_FLOOR"; then
  fail "CI does not enable headed/slowMo" "CI has no display and no time for it"
else
  ok "CI does not enable headed/slowMo"
fi

# The drill's default source must be the tracked mainline. It defaulted to
# dan-claude-bot/crew @ crew/shared-duty — a fork branch from the #16 era — so
# a flagless drill rehearsed code the fleet does not deploy, long after that
# branch merged.
CL_DRILL_SH="$CL_ROOT/drill/rehearsal.sh"
if grep -qE '^REF=.*main' "$CL_DRILL_SH" && grep -qE '^REMOTE=.*heavy-duty/crew' "$CL_DRILL_SH"; then
  ok "drill: defaults to the tracked mainline, not a fork branch"
else
  fail "drill: defaults to the tracked mainline, not a fork branch" \
       "$(grep -E '^(REF|REMOTE)=' "$CL_DRILL_SH" | tr '\n' ' ')"
fi

# ...and the runbook that explains the drill must not send the operator
# somewhere else. It told them to clone dan-claude-bot/crew long after the line
# above moved to the org, and that fork EXISTS — so the clone succeeded and the
# operator rehearsed a tree the drill is not written for, with nothing to say
# so (#302). The pattern is the URL form on purpose: prose that RECORDS the old
# default — the comment above, and rehearsal.sh's own — is the history of why
# it moved, and stays put.
CL_REHEARSAL_MD="$CL_ROOT/shared/docs/rehearsal.md"
CL_FORK_URLS="$(grep -rnE 'github\.com/[A-Za-z0-9._-]+/crew' \
  "$CL_ROOT/shared" "$CL_ROOT/drill" "$CL_ROOT/cli" \
  | grep -v 'github\.com/heavy-duty/crew')"
if [ -n "$CL_FORK_URLS" ]; then
  fail "docs: no personal fork is named as the source of crew" \
       "$(echo "$CL_FORK_URLS" | tr '\n' ' ')"
elif ! grep -q 'git clone https://github.com/heavy-duty/crew' "$CL_REHEARSAL_MD"; then
  fail "docs: no personal fork is named as the source of crew" \
       "the rehearsal runbook's clone command names no heavy-duty remote at all"
else
  ok "docs: no personal fork is named as the source of crew"
fi

# The override has to be findable from the runbook alone — a reader who wants
# to rehearse against a fork should not have to read rehearsal.sh to learn it
# is a flag and not an edit to the clone command (#302).
if grep -q 'CREW_DRILL_REMOTE' "$CL_REHEARSAL_MD" \
   && grep -q -- '--remote' "$CL_REHEARSAL_MD"; then
  ok "docs: the runbook names --remote / CREW_DRILL_REMOTE as the override"
else
  fail "docs: the runbook names --remote / CREW_DRILL_REMOTE as the override" \
       "rehearsal.md must name both, so the fork case never edits the clone"
fi

# rehearsal-all must point the app drill at the boxes it just drilled. Falling
# through to fleet.roster meant comparing the real fleet's members, which do not
# exist on a drill host: three "NOT CREATED vs offline" agreements about nothing.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q -- '--drill-roles "\${DRILLED# }" --agent "\$AGENT"' "$CL_ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all: the app drill sees the boxes this run built, with their agent"
else
  fail "rehearsal-all: the app drill sees the boxes this run built, with their agent" \
       "roles and agent must travel together — a correct role list with a defaulted agent probes the wrong vendor"
fi

# --- the agent column is generated from something TRUE (all three reviewers) --
# `rehearsal-all.sh --agent codex` drilled codex boxes and then generated an app
# roster claiming `claude`, because --agent reached rehearsal.sh but never the
# app phase. The column is load-bearing: floor.py feeds it to probe.sh to pick
# agents/<agent>.conf, and crew status feeds it to vendor_probe. So every
# non-default rehearsal probed the wrong vendor and reported the fleet
# auth-unhealthy — while the agreement assertions stayed GREEN, because both
# readers share the one wrong file. Consistent, wrong data.
#
# That is this PR's own defect class one layer up: "generated, it cannot drift"
# only holds if ALL of it is generated from something true. The role came from
# the drill; the agent silently did not.
if grep -q -- '--agent)         DRILL_AGENT=' "$CL_APP"; then
  ok "drill: rehearsal-app takes an explicit --agent"
else
  fail "drill: rehearsal-app takes an explicit --agent" \
       "the agent is settable only through an undiscoverable env var"
fi
CL_RC=0; "$CL_APP" --drill-roles triage --agent nosuchagent >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q "unknown agent" "$CL_TMP/app.out"; then
  ok "drill: an agent with no profile is refused, not written into the roster"
else
  fail "drill: an agent with no profile is refused, not written into the roster" \
       "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
# Only roles whose drill reached a box; and the narrowing must be announced.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'DRILLED="\$DRILLED \$role"' "$CL_ROOT/drill/rehearsal-all.sh" &&
   grep -q 'roles whose drill never reached a box are excluded' "$CL_ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all: excludes roles that never reached a box, and says so"
else
  fail "rehearsal-all: excludes roles that never reached a box, and says so" \
       "a failed role's absent box becomes a NOT-CREATED-vs-offline non-comparison, silently"
fi

# --- a declaration must be checkable against ground truth -------------------
# The reason the bug above was SILENT: nothing ever compared the roster's agent
# claim with what the box was actually installed as. Both readers took the
# claim on faith and handed it to the vendor probe, so a misdeclared agent is
# indistinguishable from a logged-out box — forever, on the real fleet too.
# Run probe.sh for real against a scratch DUTY_DIR, rather than grepping for
# the line: what matters is that it PARSES instance.conf correctly, and a
# source-grep would pass just as happily on a filter that emits nothing.
# Deliberately not added to fixtures/fleet.txt — three assertions under
# test/floor/ hardcode the fixture's box count (floor/{roster,fleet,server}.sh)
# and browser.js's scroll walk has been destabilised by fleet size before
# (browser.js:246). One more row is not worth that risk for a case a direct
# probe.sh run already answers. #610 did pay that cost, for four rows it could
# not answer any other way: its subject IS the collector's reading of a served
# box, at four lock ages one second apart at the boundary.
CL_PD="$CL_TMP/probe-duty"; mkdir -p "$CL_PD/conf"
printf 'BOT_AGENT=codex\nBOT_ROLES="builder"\n' > "$CL_PD/conf/instance.conf"
CL_PA="$(DUTY_DIR="$CL_PD" bash "$CL_FLOOR/server/probe.sh" </dev/null 2>/dev/null | sed -n 's/^::agent //p')"
t "probe: reports the agent the box was actually installed as" codex "$CL_PA"
# An unhired box has no instance.conf: the key must still be emitted, empty, so
# the floor can tell "no claim to check" from "claim disagrees".
CL_PD2="$CL_TMP/probe-duty-bare"; mkdir -p "$CL_PD2"
CL_PA2="$(DUTY_DIR="$CL_PD2" bash "$CL_FLOOR/server/probe.sh" </dev/null 2>/dev/null | grep -c '^::agent' || true)"
t "probe: an unhired box still emits the key, empty" 1 "${CL_PA2:-0}"
if grep -q 'agent_actual' "$CL_FLOOR/server/floor/units.py"; then
  ok "floor: compares the roster's agent claim against the box"
else
  fail "floor: compares the roster's agent claim against the box" "the claim is still taken on faith"
fi
if grep -q 'box_agent' "$CL_ROOT/cli/crew"; then
  ok "crew status: a failing vendor probe distinguishes logged-out from mislabelled"
else
  fail "crew status: a failing vendor probe distinguishes logged-out from mislabelled" \
       "MISSING still has two causes and names neither"
fi


# ---------------------------------------------------------------------------
# The drill must never run the browser walk in a mutating mode.
#
# codex-bot's finding: gating that on --allow-control only moved the hazard.
# `--allow-control` without `--boxes` skips the narrowed control block, yet the
# browser walk would still pause whichever unit was on screen; and its
# `wake-silent` click is FLEET-WIDE, which --boxes cannot constrain even in
# principle. So the opt-in path broke the script's own guarantee.
#
# Asserted as an INVARIANT over the source rather than by running two argument
# combinations: the property wanted is "for ANY arguments, the walk is
# read-only", and two sampled invocations cannot show that. This can.
# ---------------------------------------------------------------------------
echo
echo "== drill: the browser walk cannot mutate a real fleet"

CL_DRILL="$CL_ROOT/drill/rehearsal-app.sh"
CL_INVOKES="$(grep -cE 'node .*fleet-floor/test/browser\.js' "$CL_DRILL" || true)"
t "drill: exactly one browser.js invocation" 1 "${CL_INVOKES:-0}"

# Every invocation must carry the read-only env on the SAME line.
CL_RO="$(grep -B1 -E 'node .*fleet-floor/test/browser\.js' "$CL_DRILL" | grep -cE 'FLOOR_TEST_READONLY=1' || true)"
t "drill: that invocation is read-only" 1 "${CL_RO:-0}"

# And no branch may hand it an empty/!=1 value, which is how the first fix
# reintroduced the mutating path under --allow-control.
CL_BAD="$(grep -cE 'FLOOR_TEST_READONLY="?\$|FLOOR_TEST_READONLY=""|FLOOR_TEST_READONLY=$' "$CL_DRILL" || true)"
t "drill: read-only is not computed from a variable" 0 "${CL_BAD:-0}"

# The narrowed control block still refuses to act without an explicit allowlist.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -qE 'elif \[ -z "\$BOXES" \]; then' "$CL_DRILL"; then
  ok "drill: --allow-control still requires --boxes"
else
  fail "drill: --allow-control still requires --boxes" "the allowlist guard is gone"
fi

# browser.js must actually honour the flag: no control click outside a
# !READONLY guard. Counted, so a new control added without the guard trips it.
CL_BJS="$CL_HERE/browser.js"
CL_GUARDS="$(grep -cE '!READONLY' "$CL_BJS" || true)"
if [ "${CL_GUARDS:-0}" -ge 3 ]; then
  ok "browser.js: control blocks are behind a READONLY guard (${CL_GUARDS})"
else
  fail "browser.js: control blocks are behind a READONLY guard" "only ${CL_GUARDS:-0} guards found; expected the pause, paused-box and fleet-wide blocks"
fi

# The walk demands fixture-only states (a hostile-log box, a first-session box,
# offline boxes) and must demand them ONLY of the fixture. kimi-bot found the
# drill running the same walk against a real fleet, where those boxes do not
# exist and a healthy fleet has nothing offline: two unconditional hard-fails,
# so "browser walk against the real fleet" could never pass on any host.
#
# Both halves are asserted, because either one alone silently breaks the split:
# run.sh not setting it loses the loud coverage the fixture exists to provide,
# and the drill setting it puts the always-red walk straight back.
if grep -qE '^export FLOOR_TEST_FIXTURE=1' "$CL_HERE/run.sh"; then
  ok "fixture gate: run.sh claims the fixture fleet"
else
  fail "fixture gate: run.sh claims the fixture fleet" \
       "without it the hostile/first-run/offline guards go quiet in the suite"
fi
# Comments stripped first. The drill EXPLAINS why it withholds this flag, and a
# bare `grep FLOOR_TEST_FIXTURE` matched that explanation -- a detector tripping
# on its own documentation, which is the same bug as the read-only detector that
# once matched a string probe.sh itself contained.
CL_DRILL_CODE="$(grep -vE '^[[:space:]]*#' "$CL_DRILL")"
if grep -q 'FLOOR_TEST_FIXTURE=' <<<"$CL_DRILL_CODE"; then
  fail "fixture gate: the drill does NOT claim the fixture fleet" \
       "the drill sets FLOOR_TEST_FIXTURE; the walk will demand boxes a real fleet has no reason to have"
else
  ok "fixture gate: the drill does NOT claim the fixture fleet"
fi
# ...and the walk must actually consult it, rather than the flag being inert.
CL_GATED="$(grep -cE 'FIXTURE &&|if \(FIXTURE\)' "$CL_BJS" || true)"
if [ "${CL_GATED:-0}" -ge 3 ]; then
  ok "fixture gate: the walk gates its fixture-only demands (${CL_GATED})"
else
  fail "fixture gate: the walk gates its fixture-only demands" \
       "only ${CL_GATED:-0} gated sites; expected the hostile, first-run and offline demands"
fi

# The read-only receipt check MOVED here from run.sh; it did not evaporate.
# CI cannot make it honestly (no real fleet), the drill can (real boxes, and a
# logging wrapper ahead of the real `box` on PATH). A check that leaves CI and
# lands nowhere is indistinguishable from one that was deleted, so this suite
# holds the drill to it by name.
if grep -q 'read-only walk issued no control command' "$CL_DRILL"; then
  ok "drill: still asserts the read-only walk touched nothing"
else
  fail "drill: still asserts the read-only walk touched nothing" \
       "the check moved out of run.sh and is not in the drill either"
fi
# ...and it must be checking CALLS, not the flag it set itself. Without the
# wrapper on PATH there is no receipt to read, and the assertion above would
# pass against an empty file forever.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'exec "\$REAL_BOX"' "$CL_DRILL" && grep -q 'PATH="\$TMP/bin:\$PATH"' "$CL_DRILL"; then
  ok "drill: reads the real box calls, not just its own flag"
else
  fail "drill: reads the real box calls, not just its own flag" \
       "no logging wrapper ahead of the real box on PATH"
fi
# The companion no-vacuity check goes with it: a read-only mode that did
# NOTHING would satisfy "issued no control command" perfectly. Two halves, and
# they guard different things — the walk's own assertion count proves the WALK
# did something, and a non-empty receipt proves the RECEIPT is real (without the
# wrapper on PATH, "issued no control command" passes against an empty file
# forever). This used to be a single probe-count check that guarded neither and
# could never pass; see the drill-harness section above.
if grep -q 'browser walk reported its assertion count' "$CL_DRILL"; then
  ok "drill: proves the walk itself did something"
else
  fail "drill: proves the walk itself did something" "the assertion-count check is gone"
fi

# The two invariants below are about the NARROWED control block, not the walk;
# they hold whether or not this file drives a browser. #40 gained them while the
# walk was out of tree, so they are carried forward here rather than reverted --
# re-adding the browser must not quietly drop coverage that outlived it.

# Read-only by default: no control verb may run without ALLOW_CONTROL.
# shellcheck disable=SC2016  # matching the literal source text
if grep -qE 'if \[ "\$ALLOW_CONTROL" -ne 1 \]; then' "$CL_DRILL"; then
  ok "drill: control verbs are opt-in"
else
  fail "drill: control verbs are opt-in" "the ALLOW_CONTROL gate is gone"
fi

# --- the control block arms what it exercises, and disarms it (#188) -------
# All four are asserted over the SOURCE. Each describes what happens when a run
# dies partway or when a box is in a state no invocation here can produce, and
# a sampled run cannot show any of them.

# The verbs had nothing to act on: rehearsal.sh disarms cron before any tick and
# aborts the run if it cannot, so every drill box has no armed `tick.sh` line
# for its whole run. `pause` therefore commented nothing out, and the block
# could only ever assert that the transport was reachable.
if grep -q 'drill_arm_cron' "$CL_DRILL"; then
  ok "drill: the control block arms the tick line it exercises"
else
  fail "drill: the control block arms the tick line it exercises" \
       "every drill box is disarmed by construction, so the verbs assert only the transport"
fi

# Anything it ARMS must be disarmed on the way out, on every exit path. The
# repair used to be a resume of PAUSED_BY_DRILL, the right shape for a block
# that only paused; the block owns the arm now, so the state to restore is
# disarmed and the ledger is ARMED_BY_DRILL.
if grep -q 'ARMED_BY_DRILL' "$CL_DRILL" && grep -q 'trap cleanup EXIT' "$CL_DRILL"; then
  ok "drill: armed tick lines are disarmed on teardown"
else
  fail "drill: armed tick lines are disarmed on teardown" "no ARMED_BY_DRILL/trap pairing"
fi

# ...and the ledger is written BEFORE the arm, or a half-applied arm — a box
# exec that dies with the crontab already installed — is invisible to the trap
# and the box is left ticking.
# shellcheck disable=SC2016  # matching the literal source assignment
CL_ARM_REC="$(grep -n 'ARMED_BY_DRILL="\$ARMED_BY_DRILL' "$CL_DRILL" | cut -d: -f1 | head -1)"
CL_ARM_DO="$(grep -n 'if drill_arm_cron' "$CL_DRILL" | cut -d: -f1 | head -1)"
if [ -n "$CL_ARM_REC" ] && [ -n "$CL_ARM_DO" ] && [ "$CL_ARM_REC" -lt "$CL_ARM_DO" ]; then
  ok "drill: a box is recorded as armed before it is armed"
else
  fail "drill: a box is recorded as armed before it is armed" \
       "record=${CL_ARM_REC:-none} arm=${CL_ARM_DO:-none} — a run that dies mid-arm leaves the box ticking"
fi

# The teardown check must assert the state the drill GUARANTEES. It looked only
# for the absence of a pause marker, which passes on a box that was never armed
# — every drill box — so `left armed` could not fail, and it sat green through
# five drill runs while the verbs beside it were red. Comments are stripped
# first: this file is allowed to describe the check it replaced.
# shellcheck disable=SC2016  # matching the literal source text
if grep -q 'teardown \$b: left disarmed' "$CL_DRILL" &&
   ! grep -q 'left armed' <<<"$CL_DRILL_CODE"; then
  ok "drill: teardown asserts the box was left disarmed"
else
  fail "drill: teardown asserts the box was left disarmed" \
       "the vacuous 'left armed' check is still in the source"
fi

# A failing control must report what the BOX said. `command refused` was the
# drill's own guess, and it was wrong for five runs: nothing was refusing.
if grep -q 'no reason in the response' "$CL_DRILL" &&
   ! grep -q 'command refused' <<<"$CL_DRILL_CODE"; then
  ok "drill: a failing control reports the reason the box gave"
else
  fail "drill: a failing control reports the reason the box gave" \
       "the drill still narrates its own diagnosis instead of reading the response"
fi


# ---------------------------------------------------------------------------
# Nothing may point at a test file that is not there.
#
# kimi-bot caught this on #40 by hand: after the page walk was lifted out,
# the collector suite still called test/stale.js "the browser side of this" and the test
# .gitignore still explained a playwright-core install, both describing files
# that had just left the tree. Nobody was wrong -- there was simply no check,
# so a reader had to notice. This PR puts those files back, which makes both
# comments true again, and asserts it so the next move re-breaks the build
# instead of shipping directions to a file that is gone.
#
# Same failure mode, in the same directory, as the "read-only" drill header
# that outlived the browser walk it described.
# ---------------------------------------------------------------------------
echo
echo "== docs point at files that exist"

CL_REFS="$(grep -rhoE 'test/[a-z][a-z-]*\.js' \
             "$CL_HERE"/*.sh "$CL_HERE"/floor/*.sh "$CL_FLOOR/README.md" "$CL_ROOT/drill"/*.sh \
             "$CL_ROOT/.github/workflows"/*.yml 2>/dev/null | sort -u)"

# A grep that finds nothing would make every assertion below vacuous.
CL_NREFS="$(printf '%s' "$CL_REFS" | grep -c . || true)"
if [ "${CL_NREFS:-0}" -ge 4 ]; then
  ok "docs: found the js references to check (${CL_NREFS})"
else
  fail "docs: found the js references to check" "only ${CL_NREFS:-0}; the grep stopped matching, so the check below proves nothing"
fi

CL_DANGLING=""
for CL_REF in $CL_REFS; do
  [ -f "$CL_FLOOR/$CL_REF" ] || CL_DANGLING="$CL_DANGLING $CL_REF"
done
if [ -z "$CL_DANGLING" ]; then
  ok "docs: every referenced test file exists"
else
  fail "docs: every referenced test file exists" "dangling:$CL_DANGLING"
fi

# The .gitignore explains WHY node_modules is ignored. If the page half ever
# leaves again, that explanation goes with it.
if grep -q 'playwright-core' "$CL_HERE/.gitignore"; then
  if [ -f "$CL_HERE/browser.js" ]; then
    ok "docs: .gitignore explains playwright only while the page half is here"
  else
    fail "docs: .gitignore explains playwright only while the page half is here" \
         "no browser.js, but .gitignore still describes installing playwright-core"
  fi
else
  ok "docs: .gitignore makes no claim about playwright"
fi

# CI and the drill install playwright-core from the repository root. Ignore
# that generated dependency tree there (and at every future depth), not only
# beneath fleet-floor/test.
if grep -Fqx 'node_modules/' "$CL_ROOT/.gitignore"; then
  ok "docs: root .gitignore names node_modules"
else
  fail "docs: root .gitignore names node_modules" \
       "node_modules/ is not ignored repository-wide"
fi

# Checking the tracked set catches the actual failure: an ignored dependency
# tree that was force-added. Prove the listing is non-empty first so running
# this test outside a checkout cannot turn the absence of evidence into green.
CL_TRACKED="$(git -C "$CL_ROOT" ls-files 2>/dev/null || true)"
if [ -n "$CL_TRACKED" ]; then
  ok "docs: found tracked paths to check for node_modules"
  CL_TRACKED_NODE_MODULES="$(printf '%s\n' "$CL_TRACKED" | grep -E '(^|/)node_modules/' || true)"
  if [ -z "$CL_TRACKED_NODE_MODULES" ]; then
    ok "docs: no tracked path is under node_modules"
  else
    fail "docs: no tracked path is under node_modules" \
         "tracked dependency paths: $CL_TRACKED_NODE_MODULES"
  fi
else
  fail "docs: found tracked paths to check for node_modules" \
       "git ls-files returned nothing; the tracked-path check would be vacuous"
fi

# ---------------------------------------------------------------------------
# crew init: a fresh operator definition, never an overwrite (#76)
# ---------------------------------------------------------------------------
echo
echo "== crew init"

CL_INIT_DIR="$CL_TMP/init-fleet"
CL_SHARED_BEFORE="$(
  find "$CL_ROOT/shared" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
CL_RC=0
XDG_CONFIG_HOME="$CL_TMP/no-implicit-config" "$CL_ROOT/cli/crew" init "$CL_INIT_DIR" \
  >"$CL_TMP/init-out" 2>&1 || CL_RC=$?
t "crew init: fresh scaffold exits 0" 0 "$CL_RC"
for CL_INIT_FILE in fleet.roster fleet.conf repos.txt notify-repos.txt doctrine.conf; do
  if [ -f "$CL_INIT_DIR/$CL_INIT_FILE" ]; then
    ok "crew init: scaffolds $CL_INIT_FILE"
  else
    fail "crew init: scaffolds $CL_INIT_FILE" "missing from $CL_INIT_DIR"
  fi
done
if [ -d "$CL_INIT_DIR/agents" ]; then
  ok "crew init: scaffolds optional agents directory"
else
  fail "crew init: scaffolds optional agents directory" "missing agents/"
fi

CL_ROSTER_NAMES="$(grep -vE '^[[:space:]]*(#|$)' "$CL_INIT_DIR/fleet.roster" | awk '{print $1}')"
CL_REPORTED_NAMES="$(sed -n 's/^  \([^ ]*\) — by hand:.*/\1/p' "$CL_TMP/init-out")"
t "crew init: names every static login obligation" "$CL_ROSTER_NAMES" "$CL_REPORTED_NAMES"
if grep -q 'definition only; not a live auth check' "$CL_TMP/init-out"; then
  ok "crew init: labels the roster reading as static"
else
  fail "crew init: labels the roster reading as static" "$(cat "$CL_TMP/init-out")"
fi

CL_INIT_HASH_BEFORE="$(
  find "$CL_INIT_DIR" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
CL_RC=0
XDG_CONFIG_HOME="$CL_TMP/no-implicit-config" "$CL_ROOT/cli/crew" init "$CL_INIT_DIR" \
  >"$CL_TMP/init-again-out" 2>&1 || CL_RC=$?
CL_INIT_HASH_AFTER="$(
  find "$CL_INIT_DIR" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
if [ "$CL_RC" -ne 0 ] && grep -q 'refusing to overwrite' "$CL_TMP/init-again-out"; then
  ok "crew init: second run refuses loudly"
else
  fail "crew init: second run refuses loudly" "rc=$CL_RC $(cat "$CL_TMP/init-again-out")"
fi
t "crew init: refusal preserves every generated byte" "$CL_INIT_HASH_BEFORE" "$CL_INIT_HASH_AFTER"
CL_SHARED_AFTER="$(
  find "$CL_ROOT/shared" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
t "crew init: writes nothing under shared" "$CL_SHARED_BEFORE" "$CL_SHARED_AFTER"

# --- operator agent profiles: one config dir, one answer (#75) --------------
# A vendor CLI is configuration, so an operator adds one beside the fleet
# definition — and every reader (`crew profiles`, `crew new`, the hire
# transport, the console) must resolve it to the SAME file, operator winning
# a name clash. The must-fail #75 names: a profile resolvable by cli/crew but
# not the console (or vice versa), and a profile that lists but dies at hire.
echo
echo "== operator agent profiles (one config dir, one answer)"

CL_OPCONF="$CL_TMP/opconf"
mkdir -p "$CL_OPCONF/agents" "$CL_OPCONF/roles"
cp "$CL_CREW_ROSTER" "$CL_OPCONF/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CL_OPCONF/fleet.conf"
printf 'heavy-duty/crew\n' >"$CL_OPCONF/repos.txt"
printf '# vendorx — operator-only fixture vendor\nAGENT_LOGIN_HINT="vendorx auth login"\nbot_cli_probe() { return 0; }\nbot_cli_present() { return 0; }\n' \
  >"$CL_OPCONF/agents/vendorx.conf"
printf '# claude — operator override of a shipped name\nAGENT_LOGIN_HINT="operator claude hint"\nbot_cli_probe() { return 0; }\nbot_cli_present() { return 0; }\n' \
  >"$CL_OPCONF/agents/claude.conf"
printf 'TIMEOUT_BUILD=4321\n' >"$CL_OPCONF/roles/builder.conf"

CL_RC=0
CREW_CONFIG_DIR="$CL_OPCONF" "$CL_ROOT/cli/crew" profiles >"$CL_TMP/prof-out" 2>&1 || CL_RC=$?
t "crew profiles: exits 0 with an operator config dir" 0 "$CL_RC"
if grep -qE '^  vendorx .*\[operator\]' "$CL_TMP/prof-out"; then
  ok "crew profiles: an operator-only vendor lists, marked operator"
else
  fail "crew profiles: an operator-only vendor lists, marked operator" "$(cat "$CL_TMP/prof-out")"
fi
if grep -qE '^  claude .*operator override.*\[operator\]' "$CL_TMP/prof-out"; then
  ok "crew profiles: a same-name clash shows the operator's line"
else
  fail "crew profiles: a same-name clash shows the operator's line" "$(grep '^  claude' "$CL_TMP/prof-out")"
fi
CL_GROK_PROFILE="$(grep -E '^  grok ' "$CL_TMP/prof-out")"
if [ -n "$CL_GROK_PROFILE" ] && grep -qv '\[operator\]' <<<"$CL_GROK_PROFILE"; then
  ok "crew profiles: a shipped-only name still resolves shipped"
else
  fail "crew profiles: a shipped-only name still resolves shipped" "$(grep '^  grok' "$CL_TMP/prof-out")"
fi

# Fallback: with no operator config dir, the listing is byte-for-byte
# today's — no fixture vendor, no [operator] marker anywhere.
CL_RC=0
(cd "$CL_TMP" && env -u CREW_CONFIG_DIR XDG_CONFIG_HOME="$CL_TMP/no-such-xdg" \
  "$CL_ROOT/cli/crew" profiles) \
  >"$CL_TMP/prof-none" 2>&1 || CL_RC=$?
t "crew profiles: fallback exits 0 with no operator config dir" 0 "$CL_RC"
if grep -qE 'vendorx|\[operator\]' "$CL_TMP/prof-none"; then
  fail "crew profiles: fallback output is unchanged from today" "$(cat "$CL_TMP/prof-none")"
else
  ok "crew profiles: fallback output is unchanged from today"
fi

# crew new sizes a box with an operator-only vendor, and the login hint it
# prints is the operator profile's — resolution, not the shipped set.
printf 'cli-vendorx vendorx builder\n' >>"$CL_OPCONF/fleet.roster"
CL_RC=0
PATH="$CL_TMP/bin:$PATH" FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
CREW_CONFIG_DIR="$CL_OPCONF" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" new cli-vendorx \
  </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
t "crew new: an operator-only vendor passes profile validation" 0 "$CL_RC"
if grep -q 'vendorx auth login' "$CL_TMP/crew-out"; then
  ok "crew new: login hint comes from the operator profile"
else
  fail "crew new: login hint comes from the operator profile" "$(cat "$CL_TMP/crew-out")"
fi

# The transport at hire: stub-box records every invocation, so the calls file
# is the staging order — the seed reset must precede the profile put, and the
# put must land in the seed dir install.sh validates against.
CL_RC=0
PATH="$CL_TMP/bin:$PATH" FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
FLOOR_CALLS="$CL_TMP/hire-calls" CREW_CONFIG_DIR="$CL_OPCONF" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" hire cli-hired --force \
  </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
t "crew hire: succeeds with an operator config dir carrying profiles" 0 "$CL_RC"
if grep -q 'duty/.crew-seed-agents/vendorx.conf' "$CL_TMP/hire-calls" 2>/dev/null; then
  ok "crew hire: operator profiles ride the pre-install transport"
else
  fail "crew hire: operator profiles ride the pre-install transport" \
       "no seed-dir put in the box calls"
fi
if grep -q 'duty/.crew-example-repos.txt' "$CL_TMP/hire-calls" 2>/dev/null; then
  ok "crew hire: shipped repos example rides the pre-install transport"
else
  fail "crew hire: shipped repos example rides the pre-install transport" \
       "no shipped repos-example put in the box calls"
fi
if grep -q 'duty/.crew-example-notify-repos.txt' "$CL_TMP/hire-calls" 2>/dev/null; then
  ok "crew hire: shipped notify example rides the pre-install transport"
else
  fail "crew hire: shipped notify example rides the pre-install transport" \
       "no shipped notify-example put in the box calls"
fi
if awk '/rm -rf ~\/duty\/.crew-seed-agents/{r=NR} /duty\/.crew-seed-agents\/vendorx.conf/{p=NR} END{exit !(r && p && r<p)}' \
     "$CL_TMP/hire-calls" 2>/dev/null; then
  ok "crew hire: the seed reset precedes the profile staging"
else
  fail "crew hire: the seed reset precedes the profile staging" \
       "a stale seed could resurrect a deleted profile"
fi

# The console's reading must be the SAME answer. Importing floor.roster runs
# the resolution at its module level without starting the server, so the
# resolved values themselves are asserted — not a grep for wiring.
CL_FLOOR_ANS="$(cd "$CL_FLOOR/server" && CREW_CONFIG_DIR="$CL_OPCONF" \
  env -u CREW_FLOOR_ROSTER python3 - <<'PY' 2>&1
import sys
sys.path.insert(0, ".")
from floor import roster
print(roster.ROSTER)
print(roster.agent_conf_path("vendorx"))
print(roster.agent_conf_path("claude"))
print(roster.agent_conf_path("grok"))
print(roster.role_conf_path("builder"))
print(roster.role_conf_path("reviewer"))
PY
)"
t "floor: roster resolves from the config dir" \
  "$CL_OPCONF/fleet.roster" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 1p)"
t "floor: an operator-only vendor resolves to the operator file" \
  "$CL_OPCONF/agents/vendorx.conf" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 2p)"
t "floor: a same-name clash resolves to the operator copy" \
  "$CL_OPCONF/agents/claude.conf" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 3p)"
t "floor: a shipped-only name falls back to the shipped set" \
  "$CL_ROOT/shared/conf/agents/grok.conf" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 4p)"
t "floor: an operator role profile wins over the shipped profile" \
  "$CL_OPCONF/roles/builder.conf" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 5p)"
t "floor: a shipped-only role falls back to the shipped set" \
  "$CL_ROOT/shared/conf/roles/reviewer.conf" "$(printf '%s\n' "$CL_FLOOR_ANS" | sed -n 6p)"

# Refusal parity: an explicit but invalid CREW_CONFIG_DIR is an error for the
# console exactly as it is for the CLI — serving a fleet the CLI refuses is
# the split-brain this suite already guards against for the roster.
CL_RC=0
(cd "$CL_FLOOR/server" && CREW_CONFIG_DIR="$CL_TMP/nonexistent-config" \
  env -u CREW_FLOOR_ROSTER python3 floor.py) >"$CL_TMP/floor-bad" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'fleet.roster is required' "$CL_TMP/floor-bad"; then
  ok "floor: an invalid CREW_CONFIG_DIR is refused like the CLI refuses it"
else
  fail "floor: an invalid CREW_CONFIG_DIR is refused like the CLI refuses it" \
       "rc=$CL_RC $(cat "$CL_TMP/floor-bad")"
fi

# --- the console refuses under the examples fallback (#216 / #244) ----------
# The console is the ninth verb of #216's rule. Its read path is itself an act
# — a long-lived HTTP service on 0.0.0.0 with a generated password — and every
# button on the page reaches POST /api/command, where `resume` arms a box's
# cron and `message` starts a model session against whatever roster the
# fallback resolved. The browser gets no banner, so refusal is the whole fix.
#
# The fixture must reproduce the REPORTED environment exactly: HOME with no
# .config/crew, XDG unset, CREW_CONFIG_DIR unset, and a $PWD carrying no
# fleet.roster. Get one wrong and resolution lands on an operator directory,
# CONFIG_IS_OPERATOR is 1, and every assertion below is vacuous.
echo
echo "== crew floor under the examples fallback (#244)"

CL_FB_HOME="$CL_TMP/fb-home"
CL_FB_PWD="$CL_TMP/fb-pwd"
mkdir -p "$CL_FB_HOME" "$CL_FB_PWD"

# cl_fb CMD... — run CMD from the unconfigured host.
cl_fb() {
  (cd "$CL_FB_PWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
     -u CREW_FLOOR_ROSTER HOME="$CL_FB_HOME" PATH="$CL_TMP/bin:$PATH" \
     "$@" </dev/null)
}
cl_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; }; return 1; }

# cl_refuses LABEL PORT CMD... — CMD must exit non-zero, name the fallback
# directory and `crew init`, and bind nothing.
#
# Run in the BACKGROUND rather than read from a foreground exit status, because
# a foreground run cannot tell a refusal from a server: by the time the status
# is read the port is free either way. Here a process still alive during the
# wait window, or a bound port, is one that served — the bug wearing a message.
#
# Every call site still wraps its command in `timeout`, and that is not
# belt-and-braces: `kill $!` reaches the job this shell started, which for a
# regressed refusal is not always the python3 that ended up holding the port.
# The first must-fail run of these cases left five collectors alive on 8880-8884
# and the NEXT run reported "it served instead of refusing" for a tree that
# refuses correctly. A leaked server poisons the machine, so the cap belongs
# inside the process being tested, not around this shell's idea of it.
cl_refuses() {
  local label="$1" port="$2"; shift 2
  local pid rc alive=0 bound=0 out="$CL_TMP/fb-refuse.out"
  if cl_listening "$port"; then
    fail "$label" "port $port was already in use before the case started"
    return
  fi
  "$@" >"$out" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    cl_listening "$port" && { bound=1; break; }
    sleep 0.3
  done
  if kill -0 "$pid" 2>/dev/null; then alive=1; kill "$pid" 2>/dev/null; fi
  wait "$pid" 2>/dev/null; rc=$?
  if [ "$alive" -eq 1 ] || [ "$bound" -eq 1 ]; then
    fail "$label" "it served instead of refusing (alive=$alive bound=$bound)"
  elif [ "$rc" -eq 0 ]; then
    fail "$label" "exited 0: $(cat "$out")"
  elif ! grep -q 'refuses under the shipped example fleet definition' "$out"; then
    fail "$label" "no refusal in the output: $(cat "$out")"
  elif ! grep -q "$CL_ROOT/examples" "$out"; then
    fail "$label" "the refusal does not name the fallback directory: $(cat "$out")"
  elif ! grep -q 'crew init' "$out"; then
    fail "$label" "the refusal does not say what to do instead: $(cat "$out")"
  else
    ok "$label"
  fi
}

# The fixture proves itself first — the banner only an unconfigured host prints.
CL_FB_PROOF="$(cl_fb "$CL_ROOT/cli/crew" status 2>&1)"
case "$CL_FB_PROOF" in
  *"NO operator fleet definition"*) CL_R1=fallback ;;
  *) CL_R1=OPERATOR ;;
esac
t "floor fallback: the fixture really reaches the fallback" fallback "$CL_R1"

cl_refuses "floor fallback: crew floor refuses and binds nothing" 8880 \
  cl_fb timeout 6 "$CL_ROOT/cli/crew" floor --port 8880
cl_refuses "floor fallback: floor.py refuses the same way, run directly" 8881 \
  cl_fb env CREW_FLOOR_PORT=8881 CREW_FLOOR_PASS=x timeout 6 python3 "$CL_FLOOR/server/floor.py"

# The refusal is a WORLD fault: `crew floor` under the fallback exits 1, and
# floor.py matches it, so a caller of either reads the same status. Both are
# bounded by `timeout` — these run in the foreground, and a regressed refusal
# serves forever rather than returning a status to compare.
# Their own ports, too: reusing one a cl_refuses case touched would let an
# "address already in use" traceback stand in for the refusal and report 1 for
# the wrong reason.
CL_RC=0
cl_fb timeout 10 "$CL_ROOT/cli/crew" floor --port 8887 >"$CL_TMP/fb-cli.out" 2>&1 || CL_RC=$?
CL_RC2=0
cl_fb env CREW_FLOOR_PORT=8888 CREW_FLOOR_PASS=x timeout 10 python3 "$CL_FLOOR/server/floor.py" \
  >"$CL_TMP/fb-py.out" 2>&1 || CL_RC2=$?
t "floor fallback: the refusal is a world fault (exit 1)" 1 "$CL_RC"
t "floor fallback: both processes exit the same way" "$CL_RC" "$CL_RC2"

# A roster is not a fleet definition. Both spellings of the override must
# leave the refusal standing, or "but the operator passed a roster" quietly
# reopens the whole path.
cl_refuses "floor fallback: --roster does not lift the refusal" 8882 \
  cl_fb timeout 6 "$CL_ROOT/cli/crew" floor --port 8882 --roster "$CL_HERE/fixtures/roster.txt"
cl_refuses "floor fallback: CREW_FLOOR_ROSTER does not lift the refusal" 8883 \
  cl_fb env CREW_FLOOR_ROSTER="$CL_HERE/fixtures/roster.txt" \
    timeout 6 "$CL_ROOT/cli/crew" floor --port 8883
cl_refuses "floor fallback: floor.py refuses with CREW_FLOOR_ROSTER set" 8884 \
  cl_fb env CREW_FLOOR_ROSTER="$CL_HERE/fixtures/roster.txt" CREW_FLOOR_PORT=8884 \
    CREW_FLOOR_PASS=x timeout 6 python3 "$CL_FLOOR/server/floor.py"

# The invocation fault is still diagnosed first: a malformed `crew floor` on an
# unconfigured host exits 2, because the operator asked wrong before the world
# could answer. This is what pins the call site AFTER the option loop.
CL_RC=0
cl_fb timeout 10 "$CL_ROOT/cli/crew" floor --port >"$CL_TMP/fb-usage.out" 2>&1 || CL_RC=$?
t "floor fallback: a missing option value is still an invocation fault (2)" 2 "$CL_RC"

# ...and the other half of the call site's position, which no behaviour can
# reach without breaking the host's python3: the config answer must come
# before the python3 / index.html / roster preconditions, so an unconfigured
# host is told what is actually wrong instead of that a build is missing.
CL_FLOOR_FN="$(sed -n '/^cmd_floor()/,/^}/p' "$CL_ROOT/cli/crew")"
CL_LOOP_LINE="$(printf '%s\n' "$CL_FLOOR_FN" | grep -n '^  done$' | head -1 | cut -d: -f1)"
CL_GATE_LINE="$(printf '%s\n' "$CL_FLOOR_FN" | grep -n 'require_operator_config "crew floor"' | cut -d: -f1)"
CL_PY_LINE="$(printf '%s\n' "$CL_FLOOR_FN" | grep -n 'command -v python3' | cut -d: -f1)"
if [ -n "$CL_LOOP_LINE" ] && [ -n "$CL_GATE_LINE" ] && [ -n "$CL_PY_LINE" ] &&
   [ "$CL_LOOP_LINE" -lt "$CL_GATE_LINE" ] && [ "$CL_GATE_LINE" -lt "$CL_PY_LINE" ]; then
  ok "floor fallback: the refusal sits after the option loop and before the preconditions"
else
  fail "floor fallback: the refusal sits after the option loop and before the preconditions" \
       "loop=${CL_LOOP_LINE:-missing} gate=${CL_GATE_LINE:-missing} python3=${CL_PY_LINE:-missing}"
fi

# THE REGRESSION THAT MATTERS MORE THAN THE BUG: a configured host must behave
# exactly as before. A fix that makes real operators' consoles refuse is a
# fleet outage; the bug it replaces is a console nobody should have had.
CL_RC=0
PATH="$CL_TMP/bin:$PATH" CREW_CONFIG_DIR="$CL_OPCONF" \
  env -u CREW_FLOOR_ROSTER timeout 4 "$CL_ROOT/cli/crew" floor --local --port 8885 \
  </dev/null >"$CL_TMP/op-floor.out" 2>&1 || CL_RC=$?
if grep -q 'refuses under the shipped example' "$CL_TMP/op-floor.out"; then
  fail "floor: an operator config dir is not refused" "$(cat "$CL_TMP/op-floor.out")"
elif grep -q 'crew floor — fleet console' "$CL_TMP/op-floor.out"; then
  ok "floor: an operator config dir is not refused"
else
  fail "floor: an operator config dir is not refused" \
       "no startup banner: rc=$CL_RC $(cat "$CL_TMP/op-floor.out")"
fi
CL_RC=0
PATH="$CL_TMP/bin:$PATH" CREW_CONFIG_DIR="$CL_OPCONF" \
  "$CL_ROOT/cli/crew" floor --help </dev/null >"$CL_TMP/op-help.out" 2>&1 || CL_RC=$?
t "floor: --help still exits 0 with an operator config dir" 0 "$CL_RC"

# $PWD discovery is an operator definition too — the third resolution hop, and
# the one a developer running crew from a config directory relies on. Both
# processes must agree it is one: the CLI passes the refusal, and the floor.py
# it execs resolves the same directory and serves.
CL_RC=0
(cd "$CL_OPCONF" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
   -u CREW_FLOOR_ROSTER HOME="$CL_FB_HOME" PATH="$CL_TMP/bin:$PATH" \
   timeout 4 "$CL_ROOT/cli/crew" floor --local --port 8886 </dev/null) \
   >"$CL_TMP/pwd-floor.out" 2>&1 || CL_RC=$?
if grep -q 'refuses under the shipped example' "$CL_TMP/pwd-floor.out"; then
  fail "floor: \$PWD discovery still counts as an operator definition" \
       "$(cat "$CL_TMP/pwd-floor.out")"
elif grep -q 'serving fleet-floor on' "$CL_TMP/pwd-floor.out"; then
  ok "floor: \$PWD discovery still counts as an operator definition"
else
  fail "floor: \$PWD discovery still counts as an operator definition" \
       "the server never came up: rc=$CL_RC $(cat "$CL_TMP/pwd-floor.out")"
fi

# Validation parity: floor.py's completeness check ran only for operator
# definitions, so the LEAST trusted directory got the LEAST verification.
# Both directions are asserted, because the property is that the check does
# not care who wrote the directory — and an incomplete definition must report
# incomplete rather than reach the refusal, whichever it is.
CL_FBROOT="$CL_TMP/fb-root"
mkdir -p "$CL_FBROOT/fleet-floor/server"
cp "$CL_FLOOR/server/floor.py" "$CL_FBROOT/fleet-floor/server/floor.py"
cp -R "$CL_FLOOR/server/floor" "$CL_FBROOT/fleet-floor/server/floor"
cp -R "$CL_ROOT/examples" "$CL_FBROOT/examples"
rm -f "$CL_FBROOT/examples/repos.txt"
CL_RC=0
cl_fb env CREW_FLOOR_PASS=x timeout 10 python3 "$CL_FBROOT/fleet-floor/server/floor.py" \
  >"$CL_TMP/fb-incomplete.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'is incomplete; missing: repos.txt' "$CL_TMP/fb-incomplete.out"; then
  ok "floor: an incomplete FALLBACK definition reports incomplete, not refused"
else
  fail "floor: an incomplete FALLBACK definition reports incomplete, not refused" \
       "rc=$CL_RC $(cat "$CL_TMP/fb-incomplete.out")"
fi
CL_OP_INCOMPLETE="$CL_TMP/op-incomplete"
mkdir -p "$CL_OP_INCOMPLETE"
cp "$CL_CREW_ROSTER" "$CL_OP_INCOMPLETE/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CL_OP_INCOMPLETE/fleet.conf"
CL_RC=0
(cd "$CL_FLOOR/server" && CREW_CONFIG_DIR="$CL_OP_INCOMPLETE" \
  env -u CREW_FLOOR_ROSTER CREW_FLOOR_PASS=x timeout 10 python3 floor.py) \
  >"$CL_TMP/op-incomplete.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'is incomplete; missing: repos.txt' "$CL_TMP/op-incomplete.out"; then
  ok "floor: an incomplete OPERATOR definition reports identically"
else
  fail "floor: an incomplete OPERATOR definition reports identically" \
       "rc=$CL_RC $(cat "$CL_TMP/op-incomplete.out")"
fi

# EVERY REFUSAL PRECEDES EVERY CONFIGURATION PARSE, and it takes two competing
# inputs to see it. The collector parses six CREW_FLOOR_* timeouts at module
# level and an int() of a bad one raises, so a tree that resolves the fleet
# definition too late answers an unconfigured host with a ValueError traceback
# from a timeout it should never have reached. One invalid input cannot catch
# that — with only a bad CREW_CONFIG_DIR the refusal fires whatever the order
# is, and with only a bad timeout there is nothing for it to race.
#
# Before #508 the order was a line number: fleet_config_dir() at floor.py:116,
# the int(os.environ...) block at :175. The package has to arrange it, and did
# not: floor.server reaches floor.ping through floor.actions before floor.roster
# is named, so ping's parses ran first and this exact command changed its answer
# between 394bdad and 6eeb311.
#
# TWO LINES CARRY THE ORDER, and neither is in floor.py. Importing any floor.*
# name runs floor/__init__.py first, so the compatibility block's own import
# order is the outer carrier — floor.roster ahead of floor.ping — and roster.py's
# import of floor.ping at the seam below its resolution is the inner one.
# floor.py arranges nothing; that is measured below, not assumed.
#
# Drawn from BOTH parsing modules on purpose: CREW_FLOOR_PROBE_TIMEOUT and
# CREW_FLOOR_PING_INTERVAL are floor.ping's, CREW_FLOOR_ACTION_TIMEOUT is
# floor.actions', so the assertion is the invariant and not one variable's
# import position.
#
# EVERY ROW BELOW WAS DRIVEN AGAINST EVERY MUTATION, and each names the tree
# it was applied to, because two of them are inert alone and only red in
# combination — a table that omits the base is not re-derivable:
#
#   mutation                                  applied to      PROBE PING ACTION
#   ---------------------------------------------------------------------------
#   A  floor.py's `import floor.roster`       unmutated        ok   ok   ok
#      deleted
#   B  roster.py's ping import hoisted        unmutated        RED  RED  ok
#      to the top of the file
#   C  __init__.py's block reordered, any     unmutated        RED  RED  ok
#      module ahead of floor.roster
#   E  actions.py's own ACTION_TIMEOUT_S      unmutated        ok   ok   ok
#      parse hoisted above its roster import
#   E  the same hoist                         on top of C,     RED  RED  RED
#                                             actions first
#
# Read the two `ok` rows, they are the point:
#
# A is inert — which is why floor.py no longer carries that line. `from
# floor.server import main` runs __init__.py, and its block, on the way in, so
# deleting a roster import from floor.py changes nothing at all. C reds where
# A does not, and that is the whole reason the guard lives in __init__.py.
#
# E is inert ALONE and reds only on top of C. With floor.roster imported first
# by the block, actions.py's internal order cannot be reached in time to
# matter; hoist floor.actions ahead of floor.roster in the block AND hoist the
# parse inside actions.py, and the actions row finally reds. So that row is
# not a third copy of the ping rows — it is the guard for a reordering inside
# actions.py, and it needs both halves to fire. C alone never reds it,
# whichever module is hoisted: ping, units, fleet, actions and server were
# each driven to the front of the block and all five give RED RED ok.
for CL_VAR in CREW_FLOOR_PROBE_TIMEOUT CREW_FLOOR_PING_INTERVAL CREW_FLOOR_ACTION_TIMEOUT; do
  CL_LABEL="floor: the fleet-definition refusal beats \$$CL_VAR parsing"
  CL_RC=0
  (cd "$CL_FLOOR/server" && CREW_CONFIG_DIR="$CL_TMP/definitely-missing" \
    env -u CREW_FLOOR_ROSTER "$CL_VAR=bad" CREW_FLOOR_PASS=x timeout 10 python3 floor.py) \
    >"$CL_TMP/order-$CL_VAR.out" 2>&1 || CL_RC=$?
  if [ "$CL_RC" -eq 0 ]; then
    fail "$CL_LABEL" "exited 0 with no fleet definition at all"
  elif grep -q 'invalid literal for int' "$CL_TMP/order-$CL_VAR.out"; then
    fail "$CL_LABEL" "the timeout parsed first: $(cat "$CL_TMP/order-$CL_VAR.out")"
  elif grep -q "is not a fleet definition" "$CL_TMP/order-$CL_VAR.out"; then
    ok "$CL_LABEL"
  else
    fail "$CL_LABEL" "neither answer: rc=$CL_RC $(cat "$CL_TMP/order-$CL_VAR.out")"
  fi
done

# ...and the row that keeps the three above honest. They would all pass on a
# tree that stopped parsing those timeouts at import, which is a different
# change wearing the same green. With the definition resolving cleanly, the
# bad timeout must still raise, from the module that owns it.
CL_RC=0
cl_fb env CREW_FLOOR_PROBE_TIMEOUT=bad CREW_FLOOR_PASS=x timeout 10 \
  python3 "$CL_FLOOR/server/floor.py" >"$CL_TMP/order-still-parses.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'invalid literal for int' "$CL_TMP/order-still-parses.out" &&
   grep -q 'floor/ping.py' "$CL_TMP/order-still-parses.out"; then
  ok "floor: past the refusal, an invalid timeout still raises where it is parsed"
else
  fail "floor: past the refusal, an invalid timeout still raises where it is parsed" \
       "rc=$CL_RC $(cat "$CL_TMP/order-still-parses.out")"
fi

# --- operator-config real-host rehearsal contract (#82) -------------------
# CI has no real boxes, so it cannot honestly run the drill's hardware cases.
# It can and must keep the harness from becoming vacuous: operator mode is an
# executable assertion, crew init owns fixture construction, every case uses
# crew upgrade, the default all-roles rehearsal invokes it, and teardown names
# the state it restored.
CL_CONFIG_DRILL="$CL_ROOT/drill/rehearsal-config.sh"
CL_RC=0
(
  cd "$CL_ROOT/examples"
  XDG_CONFIG_HOME="$CL_TMP/no-such-xdg" \
    env -u CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG=1 "$CL_ROOT/cli/crew" profiles
) >"$CL_TMP/operator-mode.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] &&
   grep -q 'CONFIG_IS_OPERATOR=0' "$CL_TMP/operator-mode.out"; then
  ok "config drill: operator-mode assertion fails against examples fallback"
else
  fail "config drill: operator-mode assertion fails against examples fallback" \
       "rc=$CL_RC $(cat "$CL_TMP/operator-mode.out")"
fi

# shellcheck disable=SC2016  # matching literal variables in the drill source
if grep -q '"\$CREW" init "\$CONFIG"' "$CL_CONFIG_DRILL"; then
  ok "config drill: fixture is built by crew init"
else
  fail "config drill: fixture is built by crew init" "fixture construction bypasses crew init"
fi

CL_UPGRADES="$(grep -cE '^[[:space:]]*upgrade_operator( |$)' "$CL_CONFIG_DRILL" || true)"
if [ "${CL_UPGRADES:-0}" -ge 6 ]; then
  ok "config drill: registry cases run through crew upgrade (${CL_UPGRADES})"
else
  fail "config drill: registry cases run through crew upgrade" \
       "only ${CL_UPGRADES:-0} upgrade paths found"
fi

if grep -q '~[/]crew' "$CL_CONFIG_DRILL"; then
  fail "config drill: no case reads the retired box-side crew checkout" \
       "$(grep -n '~[/]crew' "$CL_CONFIG_DRILL")"
else
  ok "config drill: no case reads the retired box-side crew checkout"
fi
if grep -q 'put_registry.*examples/repos.txt' "$CL_CONFIG_DRILL"; then
  ok "config drill: shipped-example migration uploads its host fixture"
else
  fail "config drill: shipped-example migration uploads its host fixture" \
       "the fixture neither comes from the host nor names an unexpected box checkout"
fi

# shellcheck disable=SC2016  # matching the literal handoff in the source
if grep -q 'rehearsal-config.sh.*--box "\$CONFIG_BOX"' "$CL_ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all: operator-config drill runs by default on an installed box"
else
  fail "rehearsal-all: operator-config drill runs by default on an installed box" \
       "the hardware rehearsal is still a separate, easy-to-skip errand"
fi

CL_RC=0
"$CL_CONFIG_DRILL" --box production-member >"$CL_TMP/config-target.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q "refusing non-drill box" "$CL_TMP/config-target.out"; then
  ok "config drill: refuses a non-drill target before looking for box"
else
  fail "config drill: refuses a non-drill target before looking for box" \
       "rc=$CL_RC $(cat "$CL_TMP/config-target.out")"
fi

# An EXIT trap must use exit, not return, to override an otherwise-green body.
# Pin both the shell behavior and the drill's choice so teardown honesty cannot
# regress into a warning followed by an `ok config` summary.
CL_RC=0
bash -c 'cleanup(){ trap - EXIT; exit 9; }; trap cleanup EXIT; exit 0' || CL_RC=$?
t "config drill: an EXIT-trap exit overrides a green body" 9 "$CL_RC"
# shellcheck disable=SC2016  # matching the literal final-status variable
if grep -q 'exit "\$final_rc"' "$CL_CONFIG_DRILL"; then
  ok "config drill: restore failure controls the final drill status"
else
  fail "config drill: restore failure controls the final drill status" \
       "cleanup does not explicitly exit with its computed result"
fi

# The variables cleanup reads must only be assigned after the combined raw
# receipt has passed exact validation.
# shellcheck disable=SC2016  # matching literal variables in the drill source
CL_VALIDATE_LINE="$(grep -n '^case "\$REPOS_RAW:\$PROVENANCE_RAW"' "$CL_CONFIG_DRILL" | cut -d: -f1)"
# shellcheck disable=SC2016  # matching literal variables in the drill source
CL_ARM_LINE="$(grep -n '^REPOS_WAS="\$REPOS_RAW"' "$CL_CONFIG_DRILL" | cut -d: -f1)"
if [ -n "$CL_VALIDATE_LINE" ] && [ -n "$CL_ARM_LINE" ] &&
   [ "$CL_VALIDATE_LINE" -lt "$CL_ARM_LINE" ]; then
  ok "config drill: cleanup is armed only after both backup receipts validate"
else
  fail "config drill: cleanup is armed only after both backup receipts validate" \
       "validation=${CL_VALIDATE_LINE:-missing} assignment=${CL_ARM_LINE:-missing}"
fi

# shellcheck disable=SC2016  # the backup variables expand in the drill, not here
if grep -q 'restored .* repos.txt and registry provenance to their pre-drill state' "$CL_CONFIG_DRILL" &&
   grep -q 'mv ~/\$BACKUP_TAG.repos ~/duty/repos.txt' "$CL_CONFIG_DRILL" &&
   grep -q 'mv ~/\$BACKUP_TAG.provenance ~/duty/.repos.txt.crew-provenance' "$CL_CONFIG_DRILL"; then
  ok "config drill: teardown restores both registry bytes and provenance and says so"
else
  fail "config drill: teardown restores both registry bytes and provenance and says so" \
       "a real box can leave the drill with altered containment state"
fi

rm -rf "$CL_TMP"

if [ -n "${CL_STANDALONE:-}" ]; then
  # The header's "runnable standalone" sentence, asserted (#664): a helper
  # run.sh defines, called here and missing from the standalone block, was
  # recorded by command_not_found_handle the moment it was called.
  if [ -s "$CL_NOT_FOUND" ]; then
    fail "cli: every helper this file calls is defined in its standalone block" \
         "not found: $(sort -u "$CL_NOT_FOUND" | tr '\n' ' ')— bash fleet-floor/test/cli.sh by hand loses every case that calls them"
  else
    ok "cli: every helper this file calls is defined in its standalone block"
  fi
  rm -f "$CL_NOT_FOUND"
  echo
  echo "== cli summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi
