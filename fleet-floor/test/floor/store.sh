# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/store.sh — the suite for fleet-floor/server/floor/store.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2).
#
# Subject: the host's store (#758) — the schema, the pull that lands one probe
# record per box in one transaction, the idempotency that lets a second pull
# insert nothing, the cost view over a prices fixture, and the collector
# serving a box that stopped answering from what it had pulled.
#
# Two halves. The first drives store.py in-process against a fixture store and
# fixture records, including the REAL probe.sh in full mode over a scratch
# duty tree. The second boots its own collector (the shared one polls hourly)
# over a private fixture, pulls two stub boxes, takes one away, and asserts the
# unit the page then gets is the stored one, labelled as such.

echo "== store (#758)"

ST_TMP="$TMP/store"
mkdir -p "$ST_TMP"
export ST_SERVER="$FLOOR/server"

# A tiny prices fixture: one priced model, one with a `-` cache class, so the
# view's "recorded but unpriced class is no figure" rule has a row to fail on.
cat >"$ST_TMP/prices.conf" <<'EOF'
# fixture — not the shipped table
MODEL_TOKEN_RATES=(
  # a comment row the parser must skip: 'x|y|1|1|1|1'
  'claude|fix-model|2|10|1|0.5'
  'claude|fix-nocache|2|10|-|-'
)
not_a_row='claude|outside|1|1|1|1'
EOF

# Every SESSION END shape 0.1.3 emits, plus a token this version does not name.
ST_LOG="$ST_TMP/duty.log"
cat >"$ST_LOG" <<'EOF'
2026-10-20T09:00:00Z duty run start
VITALS ts=2026-10-20T09:00:00Z mem_free_kib=512000 disk_free_pct=41
2026-10-20T09:00:01Z SESSION START kind=build key=crew#1 timeout=7200s log=/h/duty/logs/a.log
2026-10-20T09:05:00Z SESSION END kind=build key=crew#1 rc=0 dur=290s outcome=ok
2026-10-20T09:05:01Z duty run end
2026-10-20T09:10:00Z duty tick skipped: previous run still holds the lock (held 12s)
2026-10-20T09:15:00Z SESSION END kind=review key=box#2 rc=1 dur=30s outcome=TERMINAL acted=no reply_tail=cmVzZXRzIGF0IDE4OjAwIFVUQw==
2026-10-20T09:16:00Z SESSION SKIP kind=review key=box#3 reason=terminal-breaker count=3
2026-10-20T09:20:00Z SESSION END kind=triage key=board rc=0 dur=64s outcome=ok acted=yes reply_tail= log=1200 left=0 tier=default peak_rss=3588324 oom=0 input_tokens=1000 output_tokens=100 cache_creation_input_tokens=10 cache_read_input_tokens=20 session_id=abc model=fix-model pool=pool-a sid=s-3
2026-10-20T09:25:00Z SESSION END kind=build key=crew#4 rc=- dur=- outcome=ORPHANED acted=unknown reply_tail= log=- left=- tier=unknown peak_rss=- started=2026-10-20T09:21:00Z sid=unknown
2026-10-20T09:30:00Z SESSION END kind=build key=crew#5 rc=137 dur=9s outcome=MEMORY acted=no reply_tail= log=3 left=1 tier=big oom=1 sid=s-5
2026-10-20T09:35:00Z SESSION END kind=review key=box#6 rc=1 dur=5s outcome=TERMINAL acted=no reply_tail= tier=default why=vendor-refused future=token input_tokens=5 output_tokens=5 model=vendor%2Ffix-nocache cache_read_input_tokens=1 sid=s-6
2026-10-20T09:36:00Z session breaker: kind=review recovered; dispatch resumed
not a stamped line
EOF

# st_record LOGFILE [FROM] — a full-mode record over the fixture log, with the
# state-file sections a hired box carries.
st_record() {
  local log="$1" from="${2:-1}" total
  total="$(awk 'END { print NR }' "$log")"
  [ "$from" -le $((total + 1)) ] || from=1
  printf '::engine crew@9.9.9 (fixture)\n::integrity current\n::agent claude\n::now 2026-10-20T10:00:00Z\n'
  printf '::tickhealthstart\n::tickhealthend\n::tickage 30\n::gh nofail\n::vendor nofail\n'
  printf '::suppression \n::limitdropped 0\n::limitstart\n::limitend\n::cron 1\n::paused 0\n'
  printf '::vitals VITALS ts=2026-10-20T09:00:00Z mem_free_kib=512000 disk_free_pct=41\n'
  echo '::logstart'; tail -n 600 "$log"; echo '::logend'
  printf '::statefiles .seen-build .suppressed-review .session-terminal.review .limit-events .review-owed\n'
  printf '::filestart .seen-build\ncrew#1 2026-10-01T00:00:00Z\ncrew#2 2026-10-02T00:00:00Z digest-9 1700000000\n::fileend\n'
  printf '::filestart .suppressed-review\n::not-a-key 2026-10-03T00:00:00Z\n::fileend\n'
  printf '::filestart .session-terminal.review\n3\ttripped\t12\tno\t0\t0\n::fileend\n'
  printf '::filestart .limit-events\n1700000000-11-1\t2026-10-20T09:00:00Z\twarn\tgithub_connection_nodes\t90\t100\theavy-duty/crew#482\tsays ::logend\n::fileend\n'
  printf '::filestart .review-owed\nowed\n::fileend\n'
  printf '::logfrom %s\n::logtotal %s\n' "$from" "$total"
  echo '::filestart duty.log'; tail -n +"$from" "$log"; echo '::fileend'
}
st_record "$ST_LOG" >"$ST_TMP/rec-full.txt"

# st_py STORE SCRIPT — store.py in-process against one fixture store.
st_py() {
  CREW_FLOOR_STORE="$1" CREW_MODEL_PRICES="$ST_TMP/prices.conf" \
  PYTHONPATH="$ST_SERVER" python3 -c "$2"
}

# --- the schema, once ---------------------------------------------------------
ST_A="$ST_TMP/a.sqlite"
t "store: created on first use, with a schema version row" "2 $ST_A" \
  "$(st_py "$ST_A" '
import os
from floor import store
p = store.init()
c = store.connect(p)
print(c.execute("SELECT value FROM meta WHERE key=\"schema_version\"").fetchone()[0], p)
')"
t "store: every table the issue names exists" \
  "boxes duty_log ledger limit_events meta pulls rates sessions state_files ticks vitals" \
  "$(st_py "$ST_A" '
from floor import store
c = store.connect()
print(" ".join(sorted(r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type=\"table\" AND name NOT LIKE \"sqlite_%\""))))
')"
t "store: the cost view exists" session_costs \
  "$(st_py "$ST_A" '
from floor import store
c = store.connect()
print(",".join(r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type=\"view\"")))
')"
t "store: path resolves under the fleet definition when nothing overrides it" \
  "$CREW_CONFIG_DIR/store/fleet.sqlite" \
  "$(env -u CREW_FLOOR_STORE PYTHONPATH="$ST_SERVER" python3 -c 'from floor import store; print(store.store_path())')"

# --- the record ---------------------------------------------------------------
t "parse: a state-file line beginning with :: is data, not a key" \
  "5 ['::not-a-key 2026-10-03T00:00:00Z'] False None" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_A" '
import os
from floor import store
meta, log, files, complete = store.parse_record(open(os.environ["ST_REC"]).read())
print(len([f for f in files if f != "duty.log"]), files[".suppressed-review"], "not-a-key" in meta, meta["open-section"])
')"
t "parse: a limit line that says ::logend inside its section stays inside it" \
  "True True" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_A" '
import os
from floor import store
meta, log, files, complete = store.parse_record(open(os.environ["ST_REC"]).read())
print(complete, any("says ::logend" in l for l in files[".limit-events"]))
')"
t "parse: a record cut off inside a file section is incomplete" "duty.log False" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_A" '
import os
from floor import store
text = open(os.environ["ST_REC"]).read()
cut = text[: text.rindex("::fileend") - 40]
meta, log, files, complete = store.parse_record(cut)
print(meta["open-section"], complete)
')"
t "parse: the SESSION END shapes — absent is NULL, - is NULL, unknown tokens keep" \
  "ok|0|290|None|None|None||TERMINAL|1|30|no|cmVzZXRzIGF0IDE4OjAwIFVUQw==||ok|3588324|1000|20|fix-model|pool-a|s-3|{\"session_id\": \"abc\"}|ORPHANED|None|None|None|2026-10-20T09:21:00Z|unknown|MEMORY|137|None|1|big|TERMINAL|vendor-refused|vendor/fix-nocache|1|{\"future\": \"token\"}" \
  "$(st_py "$ST_A" '
from floor import store
L = open("'"$ST_LOG"'").read().splitlines()
r = [store.parse_session_end(l) for l in L]
r = [x for x in r if x]
a, b, c, d, e, f = r
print("|".join(str(v) for v in [
  a["outcome"], a["rc"], a["dur_s"], a["acted"], a["peak_rss_kib"], a["input_tokens"], a["extra_json"] or "",
  b["outcome"], b["rc"], b["dur_s"], b["acted"], b["reply_tail"], b["extra_json"] or "",
  c["outcome"], c["peak_rss_kib"], c["input_tokens"], c["cache_read_input_tokens"], c["model"], c["pool"], c["sid"], c["extra_json"],
  d["outcome"], d["rc"], d["dur_s"], d["peak_rss_kib"], d["started"], d["sid"],
  e["outcome"], e["rc"], e["peak_rss_kib"], e["oom"], e["tier"],
  f["outcome"], f["why"], f["model"], f["cache_read_input_tokens"], f["extra_json"]]))
')"

# --- ingest: every row once, a second pull inserts nothing --------------------
ST_B="$ST_TMP/b.sqlite"
t "ingest: the whole record lands — lines, sessions, files" "True 14 lines, 6 sessions, 5 files" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_B" '
import os
from floor import store
r = store.ingest_record("alpha", open(os.environ["ST_REC"]).read(), "claude", "builder")
print(r["ok"], r["note"])
')"
t "ingest: exactly one sessions row per SESSION END line" "6 6" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(c.execute("SELECT COUNT(*) FROM sessions").fetchone()[0],
      c.execute("SELECT COUNT(DISTINCT ts_end||kind||key) FROM sessions").fetchone()[0])
')"
t "ingest: a second pull of the same record inserts nothing" "True 0 lines, 0 sessions, 5 files 6 14" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_B" '
import os
from floor import store
r = store.ingest_record("alpha", open(os.environ["ST_REC"]).read(), "claude", "builder")
c = store.connect()
print(r["ok"], r["note"], c.execute("SELECT COUNT(*) FROM sessions").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM duty_log").fetchone()[0])
')"
t "ingest: ticks, vitals and limit events are classified" \
  "breaker,run end,run start,session-skip,skipped 1 2026-10-20T09:00:00Z 1" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(",".join(r[0] for r in c.execute("SELECT DISTINCT event FROM ticks ORDER BY event")),
      c.execute("SELECT COUNT(*) FROM vitals").fetchone()[0],
      c.execute("SELECT ts FROM vitals").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM limit_events").fetchone()[0])
')"
t "ingest: the box row remembers the pull and how far the log was read" \
  "claude builder pool-a crew@9.9.9 (fixture) current running 14 1" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
b = store.box_row(c, "alpha")
print(b["agent"], b["roles"], b["pool"], b["engine"], b["integrity"], b["source_state"], b["log_lines"],
      c.execute("SELECT COUNT(*) FROM pulls WHERE ok=1").fetchone()[0] - 1)
')"
t "ingest: the next cadence pull asks for the tail only" "PROBE_FULL=1 PROBE_LOG_FROM=15" \
  "$(st_py "$ST_B" '
from floor import store
print(" ".join("%s=%s" % kv for kv in sorted(store.probe_env("alpha").items())))
')"

# --- ledger and state-file round trips ----------------------------------------
t "ledger: every entry of every seen/suppressed file, keyed by file and id" \
  ".seen-build/crew#1/2026-10-01T00:00:00Z .seen-build/crew#2/2026-10-02T00:00:00Z .suppressed-review/::not-a-key/2026-10-03T00:00:00Z" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(" ".join("%s/%s/%s" % (r["name"], r["id"], r["ts"]) for r in c.execute("SELECT * FROM ledger WHERE box=\"alpha\" ORDER BY name, id")))
')"
t "state files: content is byte-identical, tabs and all" \
  $'3\ttripped\t12\tno\t0\t0\n owed' \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(c.execute("SELECT content FROM state_files WHERE box=\"alpha\" AND name=\".session-terminal.review\"").fetchone()[0], end=" ")
print(c.execute("SELECT content FROM state_files WHERE box=\"alpha\" AND name=\".review-owed\"").fetchone()[0])
')"
# A later record: the ledger advanced on one id and regressed on another, the
# breaker cleared (its file is gone), the log grew by two lines.
{
  sed -e 's/crew#2 2026-10-02T00:00:00Z/crew#2 2026-10-05T00:00:00Z/' \
      -e 's/crew#1 2026-10-01T00:00:00Z/crew#1 2026-09-01T00:00:00Z/' \
      -e 's/^::statefiles .*/::statefiles .seen-build .suppressed-review .limit-events .review-owed/' \
      "$ST_TMP/rec-full.txt" \
    | awk 'BEGIN{skip=0} /^::filestart \.session-terminal\.review$/{skip=1} skip&&/^::fileend$/{skip=0; next} !skip'
} >"$ST_TMP/rec-later.txt"
# The box's line is the truth, forward or back: field 2 is a timestamp here
# but a digest in .seen-hygiene and a state in .seen-graph (#763 re-review).
t "ledger: a later full pull is the box's line, whichever way field 2 moved" \
  "crew#1/2026-09-01T00:00:00Z crew#2/2026-10-05T00:00:00Z" \
  "$(ST_REC="$ST_TMP/rec-later.txt" st_py "$ST_B" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read(), "claude", "builder")
c = store.connect()
print(" ".join("%s/%s" % (r["id"], r["ts"]) for r in c.execute("SELECT id, ts FROM ledger WHERE box=\"alpha\" AND name=\".seen-build\" ORDER BY id")))
')"
t "state files: a file the box no longer has leaves the store" \
  ".limit-events .review-owed" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(" ".join(r[0] for r in c.execute("SELECT name FROM state_files WHERE box=\"alpha\" ORDER BY name")))
')"

# --- the tail, the shrink, the cut --------------------------------------------
printf '2026-10-20T09:40:00Z duty run start\n2026-10-20T09:41:00Z SESSION END kind=build key=crew#7 rc=0 dur=10s outcome=ok acted=yes reply_tail= sid=s-7\n' >>"$ST_LOG"
st_record "$ST_LOG" 15 >"$ST_TMP/rec-tail.txt"
t "tail: a cadence pull from the remembered line lands only what is new" "True 2 lines, 1 sessions 16 7" \
  "$(ST_REC="$ST_TMP/rec-tail.txt" st_py "$ST_B" '
import os
from floor import store
r = store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
c = store.connect()
print(r["ok"], r["note"].rsplit(",", 1)[0], store.box_row(c, "alpha")["log_lines"],
      c.execute("SELECT COUNT(*) FROM sessions WHERE box=\"alpha\"").fetchone()[0])
')"
printf '2026-10-20T10:00:00Z duty run start\n2026-10-20T10:05:00Z SESSION END kind=build key=crew#7 rc=0 dur=10s outcome=ok acted=yes reply_tail= sid=s-7\n' >"$ST_TMP/rotated.log"
st_record "$ST_TMP/rotated.log" 18 >"$ST_TMP/rec-shrunk.txt"
t "shrink: a rotated log is asked from the top and re-ingested from line 1" "1 2" \
  "$(grep -E '^::logfrom|^::logtotal' "$ST_TMP/rec-shrunk.txt" | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "shrink: re-ingest lands the new lines, keeps the old rows, resets the count" "True 2 lines, 1 sessions 2 8 18" \
  "$(ST_REC="$ST_TMP/rec-shrunk.txt" st_py "$ST_B" '
import os
from floor import store
r = store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
c = store.connect()
print(r["ok"], r["note"].rsplit(",", 1)[0], store.box_row(c, "alpha")["log_lines"],
      c.execute("SELECT COUNT(*) FROM sessions WHERE box=\"alpha\"").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM duty_log WHERE box=\"alpha\"").fetchone()[0])
')"
t "cut: a record interrupted mid-file lands nothing and records a failed pull" \
  "False truncated record 0 0 0 truncated record" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_B" '
import os
from floor import store
text = open(os.environ["ST_REC"]).read()
r = store.ingest_record("beta", text[: text.rindex("::fileend") - 40], "codex", "reviewer")
c = store.connect()
print(r["ok"], r["note"], c.execute("SELECT COUNT(*) FROM sessions WHERE box=\"beta\"").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM duty_log WHERE box=\"beta\"").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM ledger WHERE box=\"beta\"").fetchone()[0],
      c.execute("SELECT note FROM pulls WHERE box=\"beta\" AND ok=0").fetchone()[0])
')"
t "cut: a record that never reached ::logend is refused the same way" "False 0" \
  "$(ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_B" '
import os
from floor import store
text = open(os.environ["ST_REC"]).read()
r = store.ingest_record("gamma", text[: text.index("::logend") - 10])
c = store.connect()
print(r["ok"], c.execute("SELECT COUNT(*) FROM duty_log WHERE box=\"gamma\"").fetchone()[0])
')"
t "cut: a box with no ok pull has no stored reading" "None" \
  "$(st_py "$ST_B" '
from floor import store
print(store.stored_reading("beta"))
')"
t "pulls: a box that stays down costs one failed row, not one per poll" "1 unreachable" \
  "$(st_py "$ST_B" '
from floor import store
for _ in range(3):
    store.failed_pull("alpha", "unreachable: timed out", "unreachable")
c = store.connect()
print(c.execute("SELECT COUNT(*) FROM pulls WHERE box=\"alpha\" AND ok=0").fetchone()[0],
      store.box_row(c, "alpha")["source_state"])
')"

# --- cost: parsed prices, never sourced ----------------------------------------
t "prices: the conf is parsed textually — rows in, comments and outsiders out" \
  "claude/fix-model/2.0/10.0/1.0/0.5 claude/fix-nocache/2.0/10.0/None/None" \
  "$(st_py "$ST_B" '
from floor import store
print(" ".join("/".join(str(x) for x in r) for r in store.parse_rates(open("'"$ST_TMP/prices.conf"'").read())))
')"
t "prices: the shipped model-prices.conf parses to its rows" "3 claude claude-sonnet-4-6 3.0 15.0 3.75 0.3" \
  "$(st_py "$ST_B" '
from floor import store
rows = store.parse_rates(open("'"$FLOOR/../shared/conf/model-prices.conf"'").read())
print(len(rows), " ".join(str(x) for x in rows[0]))
')"
# 1000*2 + 100*10 + 10*1 + 20*0.5 = 3020 per million.
t "cost: tokens times the model's rates, per million" "0.00302" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(c.execute("SELECT cost_usd FROM session_costs WHERE box=\"alpha\" AND key=\"board\"").fetchone()[0])
')"
t "cost: an unpriced model, an absent count and a - priced cache class are no figure" "None None None" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
q = lambda k: c.execute("SELECT cost_usd FROM session_costs WHERE box=\"alpha\" AND key=?", (k,)).fetchone()[0]
print(q("crew#1"), q("crew#5"), q("box#6"))
')"
t "cost: the window sums only what is priced and counts the rest" "8 6 0.00302 7" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
n, m, cost, un = store.window_cost(c, "2026-10-01T00:00:00Z", "alpha")
print(n, m, cost, un)
')"

# --- readers ---------------------------------------------------------------------
t "usage: per member, pool and kind, from the store alone" \
  "member:alpha/8/6/0.00302/7 pool:-/7/5/None/7 pool:pool-a/1/1/0.00302/0 kind:build/5/5/None/5 kind:review/2/0/None/2 kind:triage/1/1/0.00302/0" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
# 2026-10-22: a 7d window from here holds every fixture line.
now = __import__("calendar").timegm((2026, 10, 22, 0, 0, 0))
out = []
for by in ("member", "pool", "kind"):
    for r in store.usage(c, "7d", by, now):
        out.append("%s:%s/%d/%d/%s/%d" % (by, r["group"], r["sessions"], r["minutes"], r["cost_usd"], r["unpriced"]))
print(" ".join(out))
')"
t "usage: a window the sessions predate is empty, and the table still totals" \
  "total (24h) 0 0 —" \
  "$(st_py "$ST_B" '
from floor import store
c = store.connect()
print(" ".join(store.usage_table(store.usage(c, "24h", "member"), "24h", "member")[-1].split()))
')"
t "status: the stored reading is labelled stored and names the last session and pull" \
  "stored True True" \
  "$(st_py "$ST_B" '
from floor import store
full = store.status_lines("alpha")
brief = store.status_lines("alpha", brief=True)
print(full[0].split()[0], brief[0].startswith("stored: build crew#7 → ok,"), "pulled" in brief[0])
')"
t "status: nothing for a box the store never pulled" "0" \
  "$(st_py "$ST_B" '
from floor import store
print(len(store.status_lines("nobody")))
')"
t "stored unit: the same derivations the live path runs, marked stored" \
  "stored True crew#7 True 8" \
  "$(st_py "$ST_B" '
from floor import store
import calendar
now = calendar.timegm((2026, 10, 20, 12, 0, 0))
u = store.stored_unit("alpha", now)
print(u["source"], u["stored_at"].endswith("Z"), u["sessions"][0]["key"], len(u["spark"]) == 22, len(u["sessions"]))
')"

# --- the real probe.sh, in full mode, over a scratch tree -------------------------
ST_H="$ST_TMP/home"
mkdir -p "$ST_H/duty/logs"
echo "crew@9.9.9 (fixture)" >"$ST_H/duty/VERSION"
cp "$ST_LOG" "$ST_H/duty/duty.log"
printf 'crew#1 2026-10-01T00:00:00Z\n' >"$ST_H/duty/.seen-build"
printf '3\ttripped\t12\tno\t0\t0\n' >"$ST_H/duty/.session-terminal.review"
printf 'nonewline' >"$ST_H/duty/.review-owed"
HOME="$ST_H" DUTY_DIR="$ST_H/duty" PROBE_FULL=1 bash "$FLOOR/server/probe.sh" </dev/null >"$ST_TMP/real-full.txt" 2>"$ST_TMP/real-full.err"
t "probe.sh: full mode exits 0" 0 "$?"
HOME="$ST_H" DUTY_DIR="$ST_H/duty" bash "$FLOOR/server/probe.sh" </dev/null >"$ST_TMP/real-plain.txt" 2>/dev/null
t "probe.sh: without PROBE_FULL the record is what it always was — no new key, no section" "0" \
  "$(grep -cE '^::(statefiles|logfrom|logtotal|filestart|fileend)' "$ST_TMP/real-plain.txt")"
# Byte for byte, once the three clock-read keys (now, uptime, tickage) that
# differ between any two runs are set aside.
t "probe.sh: the cadence record is a prefix of the full one, byte for byte" "yes" \
  "$(cmp -s <(grep -vE '^::(now|uptime|tickage) ' "$ST_TMP/real-plain.txt") \
            <(head -n "$(wc -l <"$ST_TMP/real-plain.txt")" "$ST_TMP/real-full.txt" | grep -vE '^::(now|uptime|tickage) ') \
     && echo yes || echo no)"
t "probe.sh: full mode names the files and ships them" \
  ".seen-build .session-terminal.review .review-owed|1|16" \
  "$(printf '%s|%s|%s' "$(sed -n 's/^::statefiles //p' "$ST_TMP/real-full.txt")" \
      "$(sed -n 's/^::logfrom //p' "$ST_TMP/real-full.txt")" "$(sed -n 's/^::logtotal //p' "$ST_TMP/real-full.txt")")"
t "probe.sh: a file without a trailing newline still closes its own section" "nonewline ::fileend" \
  "$(awk '/^::filestart \.review-owed$/{f=1; next} /^::fileend$/&&f{print "::fileend"; exit} f{printf "%s ", $0}' "$ST_TMP/real-full.txt")"
t "probe.sh: PROBE_LOG_FROM ships the tail from that line" "15 16 2" \
  "$(HOME="$ST_H" DUTY_DIR="$ST_H/duty" PROBE_FULL=1 PROBE_LOG_FROM=15 bash "$FLOOR/server/probe.sh" </dev/null 2>/dev/null \
    | awk '/^::logfrom /{a=$2} /^::logtotal /{b=$2} /^::filestart duty.log$/{f=1; next} /^::fileend$/{f=0} f{n++} END{print a, b, n}')"
t "probe.sh: a PROBE_LOG_FROM past the file restarts from the top" "1" \
  "$(HOME="$ST_H" DUTY_DIR="$ST_H/duty" PROBE_FULL=1 PROBE_LOG_FROM=400 bash "$FLOOR/server/probe.sh" </dev/null 2>/dev/null | sed -n 's/^::logfrom //p')"
ST_C="$ST_TMP/c.sqlite"
t "probe.sh: the real record ingests, and the real parser still reads it live" \
  "True 16 lines, 7 sessions, 3 files 3 crew@9.9.9 (fixture)" \
  "$(ST_REC="$ST_TMP/real-full.txt" st_py "$ST_C" '
import os
from floor import store
from floor.units import parse_probe
text = open(os.environ["ST_REC"]).read()
r = store.ingest_record("real", text, "claude", "builder")
meta, lines = parse_probe(text)
print(r["ok"], r["note"], len([k for k in meta["file-sections"] if k != "duty.log"]), meta["engine"])
')"

# --- the collector: a stub box pulled, then gone ----------------------------------
#
# Its own collector, because the shared one polls hourly and this needs two
# polls either side of a box disappearing. A private fixture, state dir and
# store, so nothing another suite reads is touched.
echo "== store: the collector serves a box that stopped answering from the store"
ST_PORT=$((PORT + 4))
ST_STATE="$ST_TMP/state"; mkdir -p "$ST_STATE"
printf 'st-idle   running idle\nst-work   running working\nst-off    stopped idle\n' >"$ST_TMP/fixture.txt"
printf 'st-idle claude reviewer\nst-work claude builder\nst-off codex triage\n' >"$ST_TMP/roster.txt"
ST_STORE="$ST_TMP/collector.sqlite"
FLOOR_FIXTURE="$ST_TMP/fixture.txt" FLOOR_STATE="$ST_STATE" \
CREW_FLOOR_ROSTER="$ST_TMP/roster.txt" CREW_FLOOR_STORE="$ST_STORE" \
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$ST_PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3 CREW_FLOOR_PING_INTERVAL=0 \
CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
  python3 "$FLOOR/server/floor.py" >"$ST_TMP/server.log" 2>&1 &
SRV5=$!
st_api() { curl -s -u "$USER:$PASSWD" "http://127.0.0.1:$ST_PORT$1"; }
st_unit() { st_api /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1']
print(json.dumps(u[0]) if u else '{}')"; }
st_uf() { st_unit "$1" | python3 -c "import json,sys;u=json.load(sys.stdin);print($2)" 2>/dev/null; }
for _ in $(seq 1 80); do
  [ "$(st_uf st-idle "u.get('source')")" = "live" ] && break
  kill -0 "$SRV5" 2>/dev/null || { echo "store collector died:"; cat "$ST_TMP/server.log"; break; }
  sleep 0.5
done
t "collector: a probed box is served live, with no stored stamp" "live False" \
  "$(st_uf st-idle "u['source'] + ' ' + str('stored_at' in u)")"
t "collector: a stopped box nobody pulled is served as before — nothing stored" "offline  True" \
  "$(st_uf st-off "u['state'] + ' ' + u['source'] + ' ' + str('crew up' in u['note'])")"
t "collector: the poll pulled the stub box into the fixture store" "True 2 .session-terminal.review" \
  "$(st_py "$ST_STORE" '
from floor import store
c = store.connect()
print(c.execute("SELECT COUNT(*) FROM sessions WHERE box=\"st-idle\"").fetchone()[0] >= 1,
      c.execute("SELECT COUNT(*) FROM ledger WHERE box=\"st-idle\" AND name=\".seen-build\"").fetchone()[0],
      ",".join(r[0] for r in c.execute("SELECT name FROM state_files WHERE box=\"st-idle\"")))
')"
# Away it goes. The stub reads its scenario override on every call, so the
# next poll's exec fails exactly the way a dead guest's does.
echo unreachable >"$ST_STATE/st-idle.scenario"
for _ in $(seq 1 80); do
  [ "$(st_uf st-idle "u.get('source')")" = "stored" ] && break
  sleep 0.5
done
t "collector: the box that stopped answering is served from the store" "stored offline True" \
  "$(st_uf st-idle "u['source'] + ' ' + u['state'] + ' ' + str(u['note'].startswith('unreachable'))")"
t "collector: the stored unit carries its last session, its counts and the pull stamp" \
  "box#158 review approved True True" \
  "$(st_uf st-idle "u['sessions'][0]['key'] + ' ' + u['sessions'][0]['kind'] + ' ' + u['sessions'][0]['out'] + ' ' + str(u['today'] >= 1) + ' ' + str(u['stored_at'].endswith('Z'))")"
t "collector: the stored unit claims nothing live — no engine, no vitals, hired unknown" " None unknown" \
  "$(st_uf st-idle "u['engine'] + ' ' + str(u['vitals']) + ' ' + u['hired']")"
t "collector: the healthy neighbour is still live" live "$(st_uf st-work "u['source']")"
sleep 7
t "collector: the failed pull is recorded once, and the stored rows stay" "1 True" \
  "$(st_py "$ST_STORE" '
from floor import store
c = store.connect()
print(c.execute("SELECT COUNT(*) FROM pulls WHERE box=\"st-idle\" AND ok=0").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM sessions WHERE box=\"st-idle\"").fetchone()[0] >= 1)
')"
kill "$SRV5" 2>/dev/null

# ── #763 review: the store is the box's memory, not more than it ───────────
# A ledger row keeps its whole line; a full pull is the truth, so a row the
# box dropped leaves the store; a reader never creates a store and never runs
# the writer's schema; the rotated log lands by content.
ST_M="$ST_TMP/mem.sqlite"
st_py "$ST_M" 'from floor import store; store.init()' >/dev/null
ST_REC="$ST_TMP/rec-full.txt" st_py "$ST_M" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
' >/dev/null
t "ledger: a row keeps the whole line, not id and ts alone" "crew#2 2026-10-02T00:00:00Z digest-9 1700000000" \
  "$(st_py "$ST_M" '
from floor import store
c = store.connect(readonly=True)
r = c.execute("SELECT id, ts, rest FROM ledger WHERE box=\"alpha\" AND name=\".seen-build\" AND id=\"crew#2\"").fetchone()
print(r["id"], r["ts"], r["rest"])
')"
ST_EXP="$ST_TMP/export-mem"; rm -rf "$ST_EXP"
st_py "$ST_M" 'import sys; from floor import store; sys.argv=["store.py","export","--box","alpha","--dir","'"$ST_EXP"'"]; store.main(sys.argv[1:])' >/dev/null 2>&1 \
  || CREW_FLOOR_STORE="$ST_M" CREW_MODEL_PRICES="$ST_TMP/prices.conf" PYTHONPATH="$ST_SERVER" python3 "$ST_SERVER/floor/store.py" export --box alpha --dir "$ST_EXP" >/dev/null
t "export: the ledger file comes back with its whole lines" "crew#2 2026-10-02T00:00:00Z digest-9 1700000000" "$(grep '^crew#2 ' "$ST_EXP/.seen-build")"
# The box drops crew#1 and empties .suppressed-review; a full pull says so.
sed -e 's/^crew#1 2026-10-01T00:00:00Z$//' -e 's/^::not-a-key 2026-10-03T00:00:00Z$//' "$ST_TMP/rec-full.txt" >"$ST_TMP/rec-dropped.txt"
ST_REC="$ST_TMP/rec-dropped.txt" st_py "$ST_M" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
' >/dev/null
t "ledger: a full pull prunes the rows the box no longer has" "crew#2" \
  "$(st_py "$ST_M" '
from floor import store
c = store.connect(readonly=True)
print(",".join(r["id"] for r in c.execute("SELECT id FROM ledger WHERE box=\"alpha\" AND name=\".seen-build\" ORDER BY id")))
')"
t "ledger: an emptied ledger is empty in the store too" 0 \
  "$(st_py "$ST_M" '
from floor import store
c = store.connect(readonly=True)
print(c.execute("SELECT count(*) FROM ledger WHERE box=\"alpha\" AND name=\".suppressed-review\"").fetchone()[0])
')"
# Field 2 is not a timestamp everywhere: .seen-hygiene carries a digest,
# .seen-graph a state. The box's line replaces the stored one on a full pull,
# so a digest that sorts lower lands and OPEN gives way to CLOSED.
st_rec() { # NAME LINE — a minimal full record carrying one ledger line
  printf '::engine 9\n::logstart\n::logend\n::statefiles %s\n::filestart %s\n%s\n::fileend\n' "$1" "$1" "$2"
}
st_rec .seen-hygiene 'o/r 9876-100 x' >"$ST_TMP/rec-f2a.txt"; st_rec .seen-hygiene 'o/r 1234-100 y' >"$ST_TMP/rec-f2b.txt"
st_rec .seen-graph 'o/r#1#o/r#2 OPEN' >"$ST_TMP/rec-f2c.txt"; st_rec .seen-graph 'o/r#1#o/r#2 CLOSED' >"$ST_TMP/rec-f2d.txt"
ST_F2="$ST_TMP/f2.sqlite"
st_py "$ST_F2" 'from floor import store; store.init()' >/dev/null
st_f2_ingest() { # RECORD… — each a full pull, in order
  local f
  for f in "$@"; do
    ST_REC="$ST_TMP/$f.txt" st_py "$ST_F2" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
' >/dev/null
  done
}
# Each pair on its own: a full pull names every file the box has, so the graph
# records would (correctly) prune the hygiene ledger the box no longer ships.
st_f2_ingest rec-f2a rec-f2b
t "ledger: a hygiene digest that sorts lower still replaces the stored one" "1234-100 y" \
  "$(st_py "$ST_F2" '
from floor import store
c = store.connect(readonly=True)
r = c.execute("SELECT ts, rest FROM ledger WHERE box=\"alpha\" AND name=\".seen-hygiene\"").fetchone()
print(r["ts"], r["rest"])
')"
st_f2_ingest rec-f2c rec-f2d
t "ledger: an edge that closed is CLOSED in the store" CLOSED \
  "$(st_py "$ST_F2" '
from floor import store
c = store.connect(readonly=True)
print(c.execute("SELECT ts FROM ledger WHERE box=\"alpha\" AND name=\".seen-graph\"").fetchone()["ts"])
')"
# The rotated log crosses once per rotation: its mark is kept, handed to the
# next probe as PROBE_LOG1_SEEN, and the file is not re-landed on every poll.
printf '::engine 9\n::logstart\n::logend\n::statefiles\n::log1mark 4096.1700000000\n::filestart duty.log.1\n2026-10-01T00:00:00Z duty run start\n::fileend\n' >"$ST_TMP/rec-log1.txt"
ST_REC="$ST_TMP/rec-log1.txt" st_py "$ST_F2" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
' >/dev/null
t "log.1: the mark of the rotated log landed is remembered for the next probe" "4096.1700000000" \
  "$(st_py "$ST_F2" 'from floor import store; print(store.probe_env("alpha").get("PROBE_LOG1_SEEN", ""))')"
t "log.1: a box whose rotated log never crossed is asked for it whole" "" \
  "$(st_py "$ST_F2" 'from floor import store; print(store.probe_env("nobody").get("PROBE_LOG1_SEEN", ""))')"
t "reader: a read-only open never creates a store" "no-store absent" \
  "$(st_py "$ST_TMP/never.sqlite" '
import os
from floor import store
try:
    store.connect(readonly=True); print("opened")
except SystemExit as e:
    print("no-store", "present" if os.path.exists(os.environ["CREW_FLOOR_STORE"]) else "absent")
')"
t "reader: a read-only open runs no schema" "ro" \
  "$(st_py "$ST_M" '
from floor import store
c = store.connect(readonly=True)
try:
    c.execute("CREATE TABLE zz(x)"); print("rw")
except Exception:
    print("ro")
')"
t "tick: the real skip line classifies as skipped" "skipped skipped" \
  "$(st_py "$ST_M" '
from floor import store
print(store.classify_tick("duty tick skipped: previous run still holds the lock"), store.classify_tick("tick skipped: x"))
')"
# The rotated log: a full pull ships duty.log.1 whole and its rows land by content.
{ cat "$ST_TMP/rec-full.txt"; printf '::filestart duty.log.1\n2026-10-19T23:59:00Z SESSION END kind=build key=crew#0 rc=0 dur=10s outcome=ok\n::fileend\n'; } >"$ST_TMP/rec-rotated.txt"
ST_REC="$ST_TMP/rec-rotated.txt" st_py "$ST_M" '
import os
from floor import store
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
store.ingest_record("alpha", open(os.environ["ST_REC"]).read())
' >/dev/null
t "rotated: the rotated log session lands once" 1 \
  "$(st_py "$ST_M" '
from floor import store
c = store.connect(readonly=True)
print(c.execute("SELECT count(*) FROM sessions WHERE box=\"alpha\" AND key=\"crew#0\"").fetchone()[0])
')"
unset -f st_api st_unit st_uf st_py st_record
