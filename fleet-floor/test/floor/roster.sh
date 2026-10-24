# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/roster.sh — the suite for fleet-floor/server/floor/roster.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
#
# Subject: where the fleet is DEFINED and what boxes exist — read_roster's
# answer, and box_states' strict one.
#
# The module's resolution half — fleet_config_dir, agent_conf_path and the
# refusals — is covered in ../cli.sh, against that suite's own operator
# fixture. It did not move here: it would have dragged the fixture with it,
# and this split is a relocation (#508 D5).

t "fleet: every roster box present"  44 "$(body GET /api/fleet | jqf "len(d['units'])")"

# ABSENCE MUST BE MEASURED BEFORE IT CAN HIDE A CONSOLE. `box list` failing
# makes every box read absent — the ambiguity box_states' docstring is about —
# and the grid filter would then turn a broken inventory into an empty floor
# claiming nobody was ever hired. That is hiding on SILENCE, the one thing
# #204's discriminator rule forbids. Called directly rather than through a
# collector: the branch returns before it probes anything, so a fifth server
# would cost CI a minute to assert what one import asserts here.
FF_INV="$(python3 - "$FLOOR/server" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from floor.units import build_unit
unit = {"box": "ff-x", "agent": "claude", "room": "builder"}
asked = build_unit(dict(unit), None, "", 0, inventory_ok=True)
silent = build_unit(dict(unit), None, "", 0, inventory_ok=False)
print("%s|%s|%s" % (asked["hired"], silent["hired"],
                    "named" if "inventory" in silent["note"] else silent["note"]))
PY
)"
t "hired: a measured absence hides the console, an unreadable inventory does not" \
  "no|unknown|named" "$FF_INV"

# ===========================================================================
# The roster as a layer the console can edit (#764)
#
# A collector of its own over a SCRATCH roster: the fixture roster every
# other suite reads is a tracked file, and a save here must never land in it.
# The operator definition is the suite's own ($CREW_CONFIG_DIR), so the
# write is an operator's write and the journal lands beside it.
echo
echo "== roster editing (#764)"
RS_PORT=$((PORT + 5))
RS_ROSTER="$TMP/roster-edit.txt"
RS_STATE="$TMP/roster-state"; mkdir -p "$RS_STATE"
RS_JOURNAL="$CREW_CONFIG_DIR/.roster-journal.log"
# Box names of its own (`rs-*`): the shared stub answers any name from the
# fixture state, and a second collector watching `ff-idle` would deliver that
# box's carried limit event to the shared alert channel a second time.
printf '# the fleet, one line per box\n#   <box-name> <agent> <role> [<from-box>/<snapshot>]\n\nrs-working    claude  builder\nrs-idle       claude  reviewer\nrs-stopped    codex   triage  rs-working/armed\n' >"$RS_ROSTER"
printf 'rs-working running working\nrs-idle running idle\nrs-stopped stopped idle\n' >"$TMP/roster-fixture.txt"
FLOOR_FIXTURE="$TMP/roster-fixture.txt" FLOOR_STATE="$RS_STATE" \
CREW_FLOOR_ROSTER="$RS_ROSTER" CREW_FLOOR_STORE="$TMP/roster-store.sqlite" \
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$RS_PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=2 CREW_FLOOR_PING_INTERVAL=0 \
CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
  python3 "$FLOOR/server/floor.py" >"$TMP/roster-server.log" 2>&1 &
SRV6=$!
rs_api() {  # rs_api METHOD PATH [BODY] -> "<status>\n<body>"
  if [ -n "${3:-}" ]; then
    curl -s -u "$USER:$PASSWD" -X "$1" -H 'Content-Type: application/json' -d "$3" -w '\n%{http_code}' "http://127.0.0.1:$RS_PORT$2"
  else
    curl -s -u "$USER:$PASSWD" -X "$1" -w '\n%{http_code}' "http://127.0.0.1:$RS_PORT$2"
  fi
}
rs_status() { rs_api "$@" | tail -1; }
rs_body() { rs_api "$@" | sed '$d'; }
rs_units() { rs_body GET /api/fleet | jqf "len(d['units'])"; }
for _ in $(seq 1 80); do
  [ "$(rs_units 2>/dev/null)" = 3 ] && break
  kill -0 "$SRV6" 2>/dev/null || { echo "roster collector died:"; cat "$TMP/roster-server.log"; break; }
  sleep 0.5
done
t "roster: the editor opens on the file as it is on disk" "3 rs-working,rs-idle,rs-stopped" \
  "$(rs_body GET /api/roster | jqf "str(len(d['members']))+' '+','.join(m['box'] for m in d['members'])")"
t "roster: the fourth column rides with its line" "rs-working/armed" \
  "$(rs_body GET /api/roster | jqf "[m for m in d['members'] if m['box']=='rs-stopped'][0]['from']")"
t "roster: the names a line may use are the profiles" "yes yes" \
  "$(rs_body GET /api/roster | jqf "('yes' if 'claude' in d['agents'] else 'no')+' '+('yes' if 'builder' in d['roles'] else 'no')")"
t "roster: the path is the file a save writes" "$RS_ROSTER" "$(rs_body GET /api/roster | jqf "d['path']")"
RS_SET='{"action":"roster-set","members":[{"box":"rs-working","agent":"claude","roles":["builder"],"from":""},{"box":"rs-idle","agent":"codex","roles":["reviewer","triage"],"from":""},{"box":"rs-new","agent":"grok","roles":["reviewer"],"from":"rs-working/armed"}]}'
RS_SAVE="$(rs_api POST /api/command "$RS_SET")"
t "roster-set: a valid roster lands" 200 "$(printf '%s\n' "$RS_SAVE" | tail -1)"
t "roster-set: the file reads as written, aligned, fourth column kept" \
  "rs-working claude builder|rs-idle codex reviewer,triage|rs-new grok reviewer rs-working/armed" \
  "$(grep -v '^#' "$RS_ROSTER" | awk 'NF' | tr -s ' ' | paste -sd'|' -)"
t "roster-set: the header comments are kept word for word" 2 "$(grep -c '^#' "$RS_ROSTER")"
t "roster-set: the deltas come back" "rs-new|rs-stopped|rs-idle" \
  "$(printf '%s\n' "$RS_SAVE" | sed '$d' | jqf "','.join(d['roster']['added'])+'|'+','.join(d['roster']['removed'])+'|'+','.join(d['roster']['changed'])" 2>/dev/null || true)"
t "roster-set: the write is journalled with its actor and state" 1 \
  "$(grep -c "^[0-9T:Z-]* roster set actor=$USER members=rs-working:claude:builder,rs-idle:codex:reviewer,triage,rs-new:grok:reviewer@rs-working/armed added=rs-new removed=rs-stopped changed=rs-idle$" "$RS_JOURNAL")"
# The same roster saved again is no change, and says so.
t "roster-set: saving the same roster again reports no delta" "||" \
  "$(rs_body POST /api/command "$RS_SET" | jqf "','.join(d['roster']['added'])+'|'+','.join(d['roster']['removed'])+'|'+','.join(d['roster']['changed'])" 2>/dev/null || true)"
# ...and the collector reads it at the next poll: the new line is a unit, the
# removed one is gone, and a line with no box yet is said as the target fleet.
for _ in $(seq 1 40); do
  [ "$(rs_body GET /api/fleet | jqf "','.join(sorted(u['box'] for u in d['units']))")" = "rs-idle,rs-new,rs-working" ] && break
  sleep 0.5
done
t "roster-set: the fleet follows the roster at the next poll" "rs-idle,rs-new,rs-working" \
  "$(rs_body GET /api/fleet | jqf "','.join(sorted(u['box'] for u in d['units']))")"
t "roster-set: an unknown agent is refused with its line" "400 box rs-new: unknown agent 'nobody'" \
  "$(rs_api POST /api/command '{"action":"roster-set","members":[{"box":"rs-new","agent":"nobody","roles":["builder"]}]}' | python3 -c "
import sys,json
lines=sys.stdin.read().splitlines(); d=json.loads(lines[0]); print(lines[-1], d['error'][:len(\"box rs-new: unknown agent 'nobody'\")])")"
t "roster-set: an unknown role is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[{"box":"rs-new","agent":"claude","roles":["janitor"]}]}')"
t "roster-set: a name outside incus alphabet is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[{"box":"Bad_Name","agent":"claude","roles":["builder"]}]}')"
t "roster-set: a box named twice is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[{"box":"rs-a","agent":"claude","roles":["builder"]},{"box":"rs-a","agent":"codex","roles":["reviewer"]}]}')"
t "roster-set: a line with no role is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[{"box":"rs-a","agent":"claude","roles":[]}]}')"
t "roster-set: a malformed from is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[{"box":"rs-a","agent":"claude","roles":["builder"],"from":"../x"}]}')"
t "roster-set: an empty roster is refused" 400 "$(rs_status POST /api/command '{"action":"roster-set","members":[]}')"
t "roster-set: a refusal says refused and moves nothing" "true 3" \
  "$(rs_body POST /api/command '{"action":"roster-set","members":[]}' | jqf "str(d['refused']).lower()") $(grep -vc '^#' "$RS_ROSTER" | tr -d ' ')"
t "roster: the shipped example roster is never edited from the console" "refused" \
  "$(cd / && env -u CREW_CONFIG_DIR XDG_CONFIG_HOME="$TMP/xdg-empty" python3 -c "
import sys
sys.path.insert(0, '$FLOOR/server')
from floor import roster
r, e = roster.roster_set([{'box': 'x', 'agent': 'claude', 'roles': ['builder']}])
print('refused' if r is None and 'shipped example' in e else (r, e))
")"
kill "$SRV6" 2>/dev/null
