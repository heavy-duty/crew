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
# Prose EVERYWHERE a roster can carry it — a header, a note between members,
# a commented-out parked member, a trailing remark — because a save must keep
# every line of it where it was (#763 round 3).
cat >"$RS_ROSTER" <<'EOF'
# the fleet, one line per box
#   <box-name> <agent> <role> [<from-box>/<snapshot>]

rs-working    claude  builder
# the reviewer pair
rs-idle       claude  reviewer
# rs-parked     grok    reviewer   (parked until its login lands)
rs-stopped    codex   triage  rs-working/armed

# nothing below this line is a member
EOF
RS_PROSE_BEFORE="$(grep '^#\|^$' "$RS_ROSTER")"
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
# Every save names the roster it edits: the etag GET /api/roster answered.
rs_etag() { rs_body GET /api/roster | jqf "d['etag']"; }
rs_set() {  # rs_set MEMBERS_JSON [ETAG] -> "<body>\n<status>"
  rs_api POST /api/command "{\"action\":\"roster-set\",\"etag\":\"${2:-$(rs_etag)}\",\"members\":$1}"
}
rs_set_status() { rs_set "$@" | tail -1; }
rs_set_body() { rs_set "$@" | sed '$d'; }
t "roster: the editor opens with the file's etag" 16 "$(rs_etag | tr -d '\n' | wc -c | tr -d ' ')"
RS_MEMBERS='[{"box":"rs-working","agent":"claude","roles":["builder"],"from":""},{"box":"rs-idle","agent":"codex","roles":["reviewer","triage"],"from":""},{"box":"rs-new","agent":"grok","roles":["reviewer"],"from":"rs-working/armed"}]'
RS_SAVE="$(rs_set "$RS_MEMBERS")"
t "roster-set: a valid roster lands" 200 "$(printf '%s\n' "$RS_SAVE" | tail -1)"
t "roster-set: the file reads as written, aligned, fourth column kept, two roles in one column" \
  "rs-working claude builder|rs-idle codex reviewer,triage|rs-new grok reviewer rs-working/armed" \
  "$(grep -v '^#' "$RS_ROSTER" | awk 'NF' | tr -s ' ' | paste -sd'|' -)"
# Every comment and blank line is where it was — the header, the note between
# the two members, the parked line, the trailing remark — and the new member
# landed after the last one, ahead of the trailing prose.
t "roster-set: every comment and blank line is kept, in order" "$RS_PROSE_BEFORE" "$(grep '^#\|^$' "$RS_ROSTER")"
t "roster-set: a commented-out parked member survives the save" 1 "$(grep -c '^# rs-parked ' "$RS_ROSTER")"
t "roster-set: a new member lands where the last one stood, before the trailing note" "rs-idle|#|rs-new||#" \
  "$(awk '/^rs-idle/{p=1} p{print}' "$RS_ROSTER" | cut -d' ' -f1 | paste -sd'|' -)"
t "roster-set: the deltas come back" "rs-new|rs-stopped|rs-idle" \
  "$(printf '%s\n' "$RS_SAVE" | sed '$d' | jqf "','.join(d['roster']['added'])+'|'+','.join(d['roster']['removed'])+'|'+','.join(d['roster']['changed'])" 2>/dev/null || true)"
t "roster-set: the answer carries the new etag, so the editor can keep going" "$(rs_etag)" \
  "$(printf '%s\n' "$RS_SAVE" | sed '$d' | jqf "d['roster']['etag']" 2>/dev/null || true)"
t "roster-set: the write is journalled with its actor and state" 1 \
  "$(grep -c "^[0-9T:Z-]* roster set actor=$USER members=rs-working:claude:builder,rs-idle:codex:reviewer,triage,rs-new:grok:reviewer@rs-working/armed added=rs-new removed=rs-stopped changed=rs-idle$" "$RS_JOURNAL")"
# The same roster saved again is no change, and says so.
t "roster-set: saving the same roster again reports no delta" "||" \
  "$(rs_set_body "$RS_MEMBERS" | jqf "','.join(d['roster']['added'])+'|'+','.join(d['roster']['removed'])+'|'+','.join(d['roster']['changed'])" 2>/dev/null || true)"
# ...and the collector reads it at the next poll: the new line is a unit, the
# removed one is gone, and a line with no box yet is said as the target fleet.
for _ in $(seq 1 40); do
  [ "$(rs_body GET /api/fleet | jqf "','.join(sorted(u['box'] for u in d['units']))")" = "rs-idle,rs-new,rs-working" ] && break
  sleep 0.5
done
t "roster-set: the fleet follows the roster at the next poll" "rs-idle,rs-new,rs-working" \
  "$(rs_body GET /api/fleet | jqf "','.join(sorted(u['box'] for u in d['units']))")"
# A save without the etag, or with a stale one, is refused 409 and moves
# nothing (#763 round 3): the file is rewritten whole from the browser's
# copy, so a line added by hand or from another tab in between must never
# be dropped — nor journalled as a removal.
t "roster-set: a save that names no etag is refused 409" 409 \
  "$(rs_status POST /api/command "{\"action\":\"roster-set\",\"members\":$RS_MEMBERS}")"
RS_STALE="$(rs_etag)"
printf 'rs-hand        kimi    reviewer\n' >>"$RS_ROSTER"
RS_JOURNAL_N="$(wc -l <"$RS_JOURNAL")"
t "roster-set: a save over a file edited since the editor opened is refused 409" 409 "$(rs_set_status "$RS_MEMBERS" "$RS_STALE")"
t "roster-set: the refusal says what to do" 1 "$(rs_set_body "$RS_MEMBERS" "$RS_STALE" | jqf "d['error']" | grep -c 'changed on disk since the editor opened it.*reopen the roster')"
t "roster-set: the hand edit is still in the file" 1 "$(grep -c '^rs-hand ' "$RS_ROSTER")"
t "roster-set: nothing was journalled for the refusal" "$RS_JOURNAL_N" "$(wc -l <"$RS_JOURNAL")"
# A fresh read carries the hand-written line, and a save that keeps it lands.
RS_MEMBERS4="${RS_MEMBERS%]*},{\"box\":\"rs-hand\",\"agent\":\"kimi\",\"roles\":[\"reviewer\"],\"from\":\"\"}]"
t "roster-set: reopened, the hand edit is a member and the save lands" 200 "$(rs_set_status "$RS_MEMBERS4")"
# A NEW line may not name a box the host already has off the roster: that
# line would make `crew up` hire a gold source or a scratch box past the
# off-roster guard (#763 round 3). rs-stopped exists on this host (the stub's
# fixture) and left the roster above.
RS_ADOPT="${RS_MEMBERS4%]*},{\"box\":\"rs-stopped\",\"agent\":\"codex\",\"roles\":[\"triage\"],\"from\":\"\"}]"
t "roster-set: a new line naming an existing off-roster box is refused" "400 1" \
  "$(rs_set_status "$RS_ADOPT") $(rs_set_body "$RS_ADOPT" | jqf "d['error']" | grep -c 'box rs-stopped already exists on this host and is not on the roster')"
# ...and a hand edit that lands WHILE the save is being checked — during the
# `box list` a new name costs — is caught on the bytes the rewrite reads, not
# only on the etag the editor opened with (#763 round 4: that window was the
# list's whole timeout, and the edit was rewritten away and journalled as a
# removal). The stub lands the edit from inside its own `list`.
# The hook is one-shot and the fleet's poll asks the same `box list`, so the
# etag is read BEFORE it is armed: a poll that takes the edit first leaves the
# save stale on the editor's etag, refused by the first check rather than the
# one pinned here, and that try is undone and run again. Only a save that
# lands (200) is the bug; it can no longer come from the poll (a poll taking
# the edit before the etag read made one, 1 run in 40 under #626's load).
RS_FRESH="${RS_MEMBERS4%]*},{\"box\":\"rs-fresh\",\"agent\":\"claude\",\"roles\":[\"builder\"],\"from\":\"\"}]"
RS_JOURNAL_N="$(wc -l <"$RS_JOURNAL")"
for _ in 1 2 3 4 5; do
  RS_LATE_ETAG="$(rs_etag)"
  rm -f "$RS_STATE/on-list.ran"
  printf '#!/usr/bin/env bash\nprintf "rs-late        kimi    reviewer\\n" >>"%s"\n' "$RS_ROSTER" >"$RS_STATE/on-list"
  RS_LATE="$(rs_set "$RS_FRESH" "$RS_LATE_ETAG")"
  grep -q 'since the editor opened it' <<<"$RS_LATE" || break
  sed -i '/^rs-late /d' "$RS_ROSTER"
done
rm -f "$RS_STATE/on-list"
t "roster-set: a hand edit landing during the box list is caught before the write" "ran 409" \
  "$([ -f "$RS_STATE/on-list.ran" ] && echo ran || echo not-run) $(printf '%s\n' "$RS_LATE" | tail -1)"
t "roster-set: the late edit is still in the file and nothing was journalled" "1 $RS_JOURNAL_N" \
  "$(grep -c '^rs-late ' "$RS_ROSTER") $(wc -l <"$RS_JOURNAL")"
t "roster-set: the refusal names the moment" 1 \
  "$(printf '%s\n' "$RS_LATE" | sed '$d' | jqf "d['error']" | grep -c 'while the save was being checked')"
sed -i '/^rs-late /d' "$RS_ROSTER"; rm -f "$RS_STATE/on-list.ran"
# The editor saves a line's roles in the order the LINE was written — the box
# sources them in that order and the last one's figures win — appends a newly
# ticked one, drops an unticked one, and keeps one it cannot show (#763 round
# 4: checkbox order re-wrote `triage,builder` as `builder,triage` on any save).
# The function is read out of app.js itself, so the pin is on the shipped code.
t "roster: each row carries the order its line was written in, and the save reads it" "1 1" \
  "$(grep -c '<tr class="rosrow" data-room=' "$FLOOR/src/app.js") $(grep -c 'roles:rosterRoles((tr.dataset.room' "$FLOOR/src/app.js")"
if command -v node >/dev/null 2>&1; then
  RS_ORDER="$(node -e "$(sed -n '/^function rosterRoles(/,/^}/p' "$FLOOR/src/app.js")
var o=['builder','reviewer','triage'];
console.log([rosterRoles(['triage','builder'],o,['builder','triage']).join(','),
  rosterRoles(['triage','builder'],o,['builder','reviewer','triage']).join(','),
  rosterRoles(['triage','builder'],o,['triage']).join(','),
  rosterRoles(['janitor','builder'],o,['builder']).join(','),
  rosterRoles([],o,['reviewer']).join(',')].join('|'));")"
  t "roster: the editor keeps the written role order, appends a new one, keeps one it cannot show" \
    "triage,builder|triage,builder,reviewer|triage|janitor,builder|reviewer" "$RS_ORDER"
else
  skip "roster: the written role order" "node is not installed"
fi
# The roles a line may name are the SHIPPED profiles — what the CLI's
# validate_profiles accepts — never an operator roles/ file (#763 round 3).
mkdir -p "$CREW_CONFIG_DIR/roles"; printf 'BOX_CPU=1\n' >"$CREW_CONFIG_DIR/roles/janitor.conf"
t "roster: an operator roles/ file is not a name a line may carry" "no 400" \
  "$(rs_body GET /api/roster | jqf "'yes' if 'janitor' in d['roles'] else 'no'") $(rs_set_status '[{"box":"rs-new","agent":"claude","roles":["janitor"]}]')"
rm -rf "$CREW_CONFIG_DIR/roles"
t "roster-set: an unknown agent is refused with its line" "400 box rs-new: unknown agent 'nobody'" \
  "$(rs_set '[{"box":"rs-new","agent":"nobody","roles":["builder"]}]' | python3 -c "
import sys,json
lines=sys.stdin.read().splitlines(); d=json.loads(lines[0]); print(lines[-1], d['error'][:len(\"box rs-new: unknown agent 'nobody'\")])")"
t "roster-set: an unknown role is refused" 400 "$(rs_set_status '[{"box":"rs-new","agent":"claude","roles":["janitor"]}]')"
t "roster-set: a name outside incus alphabet is refused" 400 "$(rs_set_status '[{"box":"Bad_Name","agent":"claude","roles":["builder"]}]')"
t "roster-set: a box named twice is refused" 400 "$(rs_set_status '[{"box":"rs-a","agent":"claude","roles":["builder"]},{"box":"rs-a","agent":"codex","roles":["reviewer"]}]')"
t "roster-set: a line with no role is refused" 400 "$(rs_set_status '[{"box":"rs-a","agent":"claude","roles":[]}]')"
t "roster-set: a malformed from is refused" 400 "$(rs_set_status '[{"box":"rs-a","agent":"claude","roles":["builder"],"from":"../x"}]')"
t "roster-set: an empty roster is refused" 400 "$(rs_set_status '[]')"
t "roster-set: a refusal says refused and moves nothing" "true 4" \
  "$(rs_set_body '[]' | jqf "str(d['refused']).lower()") $(grep -vc '^#\|^$' "$RS_ROSTER" | tr -d ' ')"
# A roster kept as a symlink stays one, keeps its mode, and the target carries
# the write (#763 round 3: os.replace on the link swapped it for a 0664 copy).
mv "$RS_ROSTER" "$RS_ROSTER.real" && ln -s "$RS_ROSTER.real" "$RS_ROSTER" && chmod 600 "$RS_ROSTER.real"
t "roster-set: a symlinked roster is written through the link" "200 link 600 1" \
  "$(rs_set_status "$RS_MEMBERS") $([ -L "$RS_ROSTER" ] && echo link || echo file) $(stat -c %a "$RS_ROSTER.real") $(grep -c '^rs-new ' "$RS_ROSTER.real")"
t "roster: the shipped example roster is never edited from the console" "refused" \
  "$(cd / && env -u CREW_CONFIG_DIR XDG_CONFIG_HOME="$TMP/xdg-empty" python3 -c "
import sys
sys.path.insert(0, '$FLOOR/server')
from floor import roster
r, e = roster.roster_set([{'box': 'x', 'agent': 'claude', 'roles': ['builder']}], 'me', 'whatever')
print('refused' if r is None and 'shipped example' in e else (r, e))
")"
kill "$SRV6" 2>/dev/null
