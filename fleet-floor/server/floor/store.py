"""The store on the host: one SQLite file per fleet (#758).

WHAT IT IS. `<CONFIG_DIR>/store/fleet.sqlite` — the host's copy of what every
box writes for itself: the evidence in `duty.log` (sessions, ticks, vitals,
the raw lines) and the member's memory under `$DUTY_DIR` (the seen/suppressed
ledgers, the breaker and budget state, the resume and decline markers, the
limit-event spool, the auth-fail markers). The box keeps writing its files
exactly as today; the store is the host's copy until 0.1.5 makes it the
source. One file per fleet, created on first use by whichever reader gets
there first (`crew up`, the floor's collector, the drain verb), with a
`meta(schema_version)` row so a later shape can migrate rather than guess.

WHY IT EXISTS. `crew status` reads a box over `box exec`, and the floor probes
every box on cadence; a box that is stopped is invisible to both, and a box
that boots empty re-derives every refusal its ledgers had already recorded.
With the pull below, a box stopped between polls loses nothing, `crew usage`
can answer cost per member and per pool with no box reachable, and both
readers can print a STORED reading — labelled as such, never as live — for
a box that does not answer.

HOW IT FILLS. probe.sh, run in full mode (`PROBE_FULL=1`, optionally
`PROBE_LOG_FROM=<n>` to ship duty.log from line n), adds one delimited
`::filestart <name>` … `::fileend` section per state file plus one for
duty.log, and `::logfrom`/`::logtotal` so the host knows which slice it got.
`ingest()` reads that record and lands every part of it in ONE transaction
per box: a record cut off mid-file (the box died, the exec timed out) rolls
back and is recorded as a failed pull, so the store is never half a box.
Idempotent by construction, on the self-attributing keys: a second ingest of
the same record inserts nothing, because every evidence table carries a
UNIQUE over the fields that identify one event, and the memory tables are
keyed by (box, file, id). The collector pulls on every poll and ships only
the tail — `boxes.log_lines` remembers how far duty.log had been read — and
a duty.log that shrank (tick.sh rotates it at 5 MB) is re-read from the top,
where the UNIQUE keys refuse what is already here.

HOW IT IS READ. `stored_unit()` rebuilds the SAME record units.build_unit
produces for a live box, by running units.py's own derivations
(derive_sessions, derive_queue, spark_24h) over the stored duty.log lines.
That is why units.py's regexes stay: the stored path and the live path share
one parser, and the store holds the lines rather than a second opinion about
them. `status_lines()` is the CLI's stored reading, `usage()` is the
`crew usage` report, and the `session_costs` view prices every session.

COST. `model-prices.conf` is PARSED, never sourced: `parse_rates()` reads the
`'vendor|model|in|out|cache_write|cache_read'` rows out of the text and
`connect()` renders them into the `rates` table on every connection, so a
query sees the operator's current prices and no shell ever runs for a number.
`session_costs` applies the same rule shared/conf/model-prices.conf's own
reader states: tokens × rates per million, NULL (never zero) where the model
is unpriced, where a required count is absent, or where a cache class is
recorded on the line but priced `-`.

SCHEMA (version 1):

  meta(key PK, value)
  boxes(name PK, agent, roles, pool, engine, integrity, last_seen,
        last_pull_ok, source_state, log_lines)
  sessions(box, ts_end, kind, key, rc, dur_s, outcome, acted, reply_tail,
           tier, peak_rss_kib, oom, log_bytes, left, started, sid, why,
           input_tokens, output_tokens, cache_creation_input_tokens,
           cache_read_input_tokens, model, pool, extra_json,
           UNIQUE(box, ts_end, kind, key))
      — one row per SESSION END line; every `k=v` token on the line lands
        in its column, any token this version does not name lands in
        extra_json, and an absent token is NULL (an absent field is not
        zero). `why` is the terminal classifier's reason where the engine
        records one.
  ticks(box, ts, event, line, UNIQUE(box, ts, line))
      — `run start`, `run end`, `skipped` (a tick that found the lock held),
        `session-skip` (a breaker or budget refusal) and `breaker` (a lane's
        recovery), each with the line that said so.
  vitals(box, ts, fields_json, UNIQUE(box, ts))
  limit_events(box, ts, line, UNIQUE(box, line))
  duty_log(box, ts, line, n, UNIQUE(box, ts, line))
      — the raw lines, for the transcript view; `ts` is '' on a line with no
        leading stamp, `n` the line's position when the pull knew it.
  ledger(box, name, id, ts, PRIMARY KEY(box, name, id))
      — one row per `<id> <iso-ts>` entry of every `.seen-*` and
        `.suppressed-*` file, keyed by the file's name.
  state_files(box, name, content, PRIMARY KEY(box, name))
      — the other dotfiles verbatim: `.builder-suppressed.*`,
        `.declined-build.*`, `.session-terminal.<kind>`,
        `.session-budget.<kind>`, `.resume-*`, `.limit-events`(+`.dropped`),
        `.auth-fail.*`, `.hygiene-last`, `.reaper-last`, `.review-owed`,
        `.duty.lock.since`. A full pull is authoritative about presence: a
        file the box no longer has (a cleared breaker) is removed here.
  pulls(box, at, ok, note)
  rates(vendor, model, in_rate, out_rate, cache_write_rate, cache_read_rate,
        PRIMARY KEY(vendor, model))  — rendered from model-prices.conf
  VIEW session_costs(session_rowid, box, ts_end, kind, key, pool, model,
                     vendor, dur_s, cost_usd)

0.1.5 BESIDE THESE. The primitives and typed edges the next window writes
are designed to sit next to the evidence above, not inside it, and this is
their shape so nothing here has to move:

  claims(box, repo, number, head, claimed_at, released_at, by_sid,
         PRIMARY KEY(box, repo, number, claimed_at))
      — a claim is a box holding a head on a thread; the SESSION END row
        that took or released it is reachable through `by_sid` = sessions.sid.
  rounds(repo, number, round_no, opened_at, closed_at, opened_by_sid,
         PRIMARY KEY(repo, number, round_no))
  verdicts(repo, number, round_no, box, verdict, at, by_sid,
           PRIMARY KEY(repo, number, round_no, box, at))
  states(repo, number, state, since, by_sid, PRIMARY KEY(repo, number, since))
      — the board state machine as the fleet observed it, one row per
        transition.
  handoffs(from_box, to_box, repo, number, at, by_sid,
           PRIMARY KEY(from_box, to_box, repo, number, at))
  edges(src_kind, src_id, rel, dst_kind, dst_id, at,
        PRIMARY KEY(src_kind, src_id, rel, dst_kind, dst_id))
      — the typed graph over all of the above: `src_kind`/`dst_kind` name a
        table here (session, claim, round, verdict, state, handoff, box),
        `rel` is the edge type (took, released, judged, moved, handed,
        ran-on), and every edge carries the time it was observed.

Each of those keys back to a `sessions.sid`, which 0.1.3 made self-attributing
on every SESSION END line, so a primitive always names the session that
produced it and the session always names the box, tier and pool it ran under.
Nothing writes these tables yet; `SCHEMA_VERSION` moves when they land.

Stdlib only (sqlite3, Python 3.11+): the crew CLI is bash and the host is not
guaranteed a package manager.

Run as a script for the CLI half (`crew drain`, `crew usage` and the stored
line in `crew status` call it):

  store.py init
  store.py ingest --box NAME [--agent A] [--roles R] [--pool P] < record
  store.py fail   --box NAME --note TEXT [--state stopped|unreachable]
  store.py status --box NAME [--brief]
  store.py usage  [--since 24h|7d|<n>h|<n>d] [--by member|pool|kind]
  store.py path
"""

import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from urllib.parse import unquote

SCHEMA_VERSION = 2

# --------------------------------------------------------------------------
# where
# --------------------------------------------------------------------------

def _here_on_path():
    """Make `floor.*` importable when this file runs as a script.

    `python3 fleet-floor/server/floor/store.py` puts floor/ itself first on
    sys.path, which hides the package; the server directory is what the
    package resolves from. Idempotent, and a no-op under the collector.
    """
    server = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if server not in sys.path:
        sys.path.insert(0, server)


def config_dir():
    """The fleet definition dir — the same resolution the floor and the CLI
    make (floor.roster), imported lazily so a script run resolves it too."""
    _here_on_path()
    from floor.roster import CONFIG_DIR  # noqa: E402
    return CONFIG_DIR


def crew_root():
    _here_on_path()
    from floor import CREW_ROOT  # noqa: E402
    return CREW_ROOT


def store_path():
    """`<CONFIG_DIR>/store/fleet.sqlite`, or CREW_FLOOR_STORE when a suite
    points the collector at a fixture store."""
    explicit = os.environ.get("CREW_FLOOR_STORE")
    if explicit:
        return explicit
    return os.path.join(config_dir(), "store", "fleet.sqlite")


def prices_path():
    """The operator's model-prices.conf: CREW_MODEL_PRICES, else the shipped
    shared/conf/model-prices.conf."""
    explicit = os.environ.get("CREW_MODEL_PRICES")
    if explicit:
        return explicit
    return os.path.join(crew_root(), "shared", "conf", "model-prices.conf")


# --------------------------------------------------------------------------
# schema
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS boxes (
  name TEXT PRIMARY KEY, agent TEXT, roles TEXT, pool TEXT, engine TEXT,
  integrity TEXT, last_seen TEXT, last_pull_ok TEXT, source_state TEXT,
  log_lines INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS sessions (
  box TEXT NOT NULL, ts_end TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
  rc INTEGER, dur_s INTEGER, outcome TEXT, acted TEXT, reply_tail TEXT,
  tier TEXT, peak_rss_kib INTEGER, oom INTEGER, log_bytes INTEGER, left INTEGER,
  started TEXT, sid TEXT, why TEXT,
  input_tokens INTEGER, output_tokens INTEGER,
  cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
  model TEXT, pool TEXT, extra_json TEXT,
  UNIQUE(box, ts_end, kind, key));
CREATE TABLE IF NOT EXISTS ticks (
  box TEXT NOT NULL, ts TEXT NOT NULL, event TEXT NOT NULL, line TEXT NOT NULL,
  UNIQUE(box, ts, line));
CREATE TABLE IF NOT EXISTS vitals (
  box TEXT NOT NULL, ts TEXT NOT NULL, fields_json TEXT NOT NULL,
  UNIQUE(box, ts));
CREATE TABLE IF NOT EXISTS limit_events (
  box TEXT NOT NULL, ts TEXT, line TEXT NOT NULL,
  UNIQUE(box, line));
-- Keyed by (box, ts, line): a line is one event. Two byte-identical lines
-- with NO timestamp (an untimestamped stderr line the tick echoed twice)
-- land once, by design — their position `n` is not in the key because a
-- plain cadence pull carries no position, and keying on it would land every
-- such pull's tail again.
CREATE TABLE IF NOT EXISTS duty_log (
  box TEXT NOT NULL, ts TEXT NOT NULL, line TEXT NOT NULL, n INTEGER,
  UNIQUE(box, ts, line));
CREATE TABLE IF NOT EXISTS ledger (
  box TEXT NOT NULL, name TEXT NOT NULL, id TEXT NOT NULL, ts TEXT NOT NULL,
  rest TEXT,
  PRIMARY KEY(box, name, id));
CREATE TABLE IF NOT EXISTS state_files (
  box TEXT NOT NULL, name TEXT NOT NULL, content TEXT NOT NULL,
  PRIMARY KEY(box, name));
CREATE TABLE IF NOT EXISTS pulls (
  box TEXT NOT NULL, at TEXT NOT NULL, ok INTEGER NOT NULL, note TEXT);
CREATE TABLE IF NOT EXISTS rates (
  vendor TEXT NOT NULL, model TEXT NOT NULL, in_rate REAL, out_rate REAL,
  cache_write_rate REAL, cache_read_rate REAL,
  PRIMARY KEY(vendor, model));
CREATE INDEX IF NOT EXISTS sessions_by_end ON sessions(ts_end);
CREATE INDEX IF NOT EXISTS duty_log_by_box ON duty_log(box, n);
CREATE INDEX IF NOT EXISTS pulls_by_box ON pulls(box, at);
CREATE VIEW IF NOT EXISTS session_costs AS
  SELECT s.rowid AS session_rowid, s.box, s.ts_end, s.kind, s.key, s.pool,
         s.model, b.agent AS vendor, s.dur_s,
         CASE
           WHEN r.model IS NULL THEN NULL
           WHEN r.in_rate IS NULL OR r.out_rate IS NULL THEN NULL
           WHEN s.input_tokens IS NULL OR s.output_tokens IS NULL THEN NULL
           WHEN s.cache_creation_input_tokens IS NOT NULL
                AND r.cache_write_rate IS NULL THEN NULL
           WHEN s.cache_read_input_tokens IS NOT NULL
                AND r.cache_read_rate IS NULL THEN NULL
           ELSE (s.input_tokens * r.in_rate + s.output_tokens * r.out_rate
                 + COALESCE(s.cache_creation_input_tokens, 0)
                   * COALESCE(r.cache_write_rate, 0)
                 + COALESCE(s.cache_read_input_tokens, 0)
                   * COALESCE(r.cache_read_rate, 0)) / 1000000.0
         END AS cost_usd
  FROM sessions s
  LEFT JOIN boxes b ON b.name = s.box
  LEFT JOIN rates r ON r.vendor = b.agent AND r.model = s.model;
"""


def now_iso(now=None):
    return datetime.fromtimestamp(now if now is not None else time.time(),
                                  timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _migrate(conn, have):
    """Bring a store at schema `have` to SCHEMA_VERSION, one step at a time.
    A store NEWER than this code is refused: guessing at a shape this code
    never saw is how a read becomes a corruption."""
    if have > SCHEMA_VERSION:
        raise SystemExit("store.py: the store is schema %d; this crew reads up to %d — upgrade crew"
                         % (have, SCHEMA_VERSION))
    if have < 2:
        # v2 (#763): ledger rows keep the whole line (`rest`), not id and ts
        # alone — a hygiene row's digest and epoch, a suppressed set's tail.
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(ledger)").fetchall()]
        if "rest" not in cols:
            conn.execute("ALTER TABLE ledger ADD COLUMN rest TEXT")
    conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                 (str(SCHEMA_VERSION),))


def connect(path=None, readonly=False):
    """Open the store. A WRITER creates it on first use, runs the schema and
    migrations, and refreshes the rates table. A READER opens it read-only and
    runs none of that — so the host tick, status and usage never queue behind
    an ingest's BEGIN IMMEDIATE, and a read never creates a store (#763)."""
    path = path or store_path()
    if readonly:
        if not os.path.exists(path):
            raise SystemExit("store.py: no store at %s (crew up creates it)" % path)
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=30,
                               isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=30000")
        row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
        have = int(row["value"]) if row and str(row["value"]).isdigit() else 0
        if have > SCHEMA_VERSION:
            raise SystemExit("store.py: the store is schema %d; this crew reads up to %d — upgrade crew"
                             % (have, SCHEMA_VERSION))
        return conn
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path, timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA)
    row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    have = int(row["value"]) if row and str(row["value"]).isdigit() else 0
    if row is None:
        conn.execute("INSERT INTO meta(key, value) VALUES('schema_version', ?)",
                     (str(SCHEMA_VERSION),))
    elif have != SCHEMA_VERSION:
        # One transaction: a migration a second writer interrupts is either
        # whole or not there, never a column without its version stamp.
        conn.execute("BEGIN IMMEDIATE")
        try:
            _migrate(conn, have)
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
    refresh_rates(conn)
    return conn


def init(path=None):
    """Create the store if absent. Returns its path."""
    path = path or store_path()
    connect(path).close()
    return path


# --------------------------------------------------------------------------
# prices — parsed textually, never sourced
# --------------------------------------------------------------------------

_RATE_ROW = re.compile(r"^\s*'([^'|]+)\|([^'|]+)\|([^'|]*)\|([^'|]*)\|([^'|]*)\|([^'|]*)'\s*$")


def _rate(text):
    text = text.strip()
    if text in ("", "-"):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_rates(text):
    """The MODEL_TOKEN_RATES rows of a model-prices.conf, as tuples
    (vendor, model, in, out, cache_write, cache_read) with `-` -> None.

    Only rows between `MODEL_TOKEN_RATES=(` and its `)` count; a comment is a
    comment. No shell runs: the file is an operator surface and reading one
    array out of it is not a reason to execute it.
    """
    rows, inside = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if not inside:
            if stripped.startswith("MODEL_TOKEN_RATES=("):
                inside = True
            continue
        if stripped.startswith(")"):
            break
        if stripped.startswith("#") or not stripped:
            continue
        m = _RATE_ROW.match(line)
        if not m:
            continue
        rows.append((m.group(1), m.group(2), _rate(m.group(3)), _rate(m.group(4)),
                     _rate(m.group(5)), _rate(m.group(6))))
    return rows


def refresh_rates(conn, path=None):
    try:
        with open(path or prices_path(), encoding="utf-8", errors="replace") as f:
            rows = parse_rates(f.read())
    except OSError:
        rows = []
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("DELETE FROM rates")
        conn.executemany("INSERT OR REPLACE INTO rates VALUES(?,?,?,?,?,?)", rows)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return len(rows)


# --------------------------------------------------------------------------
# the record
# --------------------------------------------------------------------------

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) (.*)$")
_STAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
_END_RE = re.compile(r"^SESSION END (.*)$")
_VITALS_RE = re.compile(r"^VITALS (ts=\S+.*)$")
_BREAKER_RE = re.compile(r"^session breaker: kind=\S+ recovered")

# The SESSION END fields this version names, by the token on the wire.
_INT_FIELDS = {"rc": "rc", "peak_rss": "peak_rss_kib", "oom": "oom",
               "log": "log_bytes", "left": "left",
               "input_tokens": "input_tokens", "output_tokens": "output_tokens",
               "cache_creation_input_tokens": "cache_creation_input_tokens",
               "cache_read_input_tokens": "cache_read_input_tokens"}
_TEXT_FIELDS = {"kind": "kind", "key": "key", "outcome": "outcome",
                "acted": "acted", "reply_tail": "reply_tail", "tier": "tier",
                "started": "started", "sid": "sid", "why": "why",
                "model": "model", "pool": "pool"}
SESSION_COLUMNS = ("box", "ts_end", "kind", "key", "rc", "dur_s", "outcome",
                   "acted", "reply_tail", "tier", "peak_rss_kib", "oom",
                   "log_bytes", "left", "started", "sid", "why", "input_tokens",
                   "output_tokens", "cache_creation_input_tokens",
                   "cache_read_input_tokens", "model", "pool", "extra_json")


def _int_or_none(value):
    """`-` and anything non-numeric is no figure. Absent is not zero."""
    if value is None:
        return None
    value = value.strip()
    if not value or value == "-" or not value.isdigit():
        return None
    return int(value)


def parse_session_end(line):
    """One `<ts> SESSION END k=v …` line -> a sessions row dict, or None.

    Tokens are read wherever they sit (fields are appended, never inserted),
    a `-` numeric is NULL, an absent token is NULL, and every token this
    version does not name goes to extra_json so nothing on the line is lost.
    """
    m = TS_RE.match(line)
    if not m:
        return None
    e = _END_RE.match(m.group(2))
    if not e:
        return None
    row = {c: None for c in SESSION_COLUMNS}
    row["ts_end"] = m.group(1)
    extra = {}
    for token in e.group(1).split(" "):
        if not token:
            continue
        key, sep, value = token.partition("=")
        if not sep:
            extra.setdefault("_bare", []).append(token)
            continue
        if key == "dur":
            row["dur_s"] = _int_or_none(value[:-1] if value.endswith("s") else value)
        elif key in _INT_FIELDS:
            row[_INT_FIELDS[key]] = _int_or_none(value)
        elif key == "model":
            # The engine writes `model=\(.model | @uri)` (session.sh); the
            # prices file names models plainly, so the join needs it decoded.
            row["model"] = unquote(value) if value else None
        elif key in _TEXT_FIELDS:
            row[_TEXT_FIELDS[key]] = value if value != "" else None
        else:
            extra[key] = value
    if not row["kind"] or not row["key"]:
        return None
    row["extra_json"] = json.dumps(extra, sort_keys=True) if extra else None
    return row


def classify_tick(text):
    """The tick event a duty.log body names, or None."""
    if text == "duty run start":
        return "run start"
    if text == "duty run end":
        return "run end"
    if re.search(r"(^|\s)tick skipped", text):
        return "skipped"
    if text.startswith("SESSION SKIP "):
        return "session-skip"
    if _BREAKER_RE.match(text):
        return "breaker"
    return None


def parse_vitals_fields(text):
    fields = {}
    for token in text.split():
        key, sep, value = token.partition("=")
        if sep and key:
            fields[key] = value
    return fields


def parse_record(text):
    """probe.sh's record -> (meta, loglines, files, complete).

    `files` maps each `::filestart <name>` section to its lines; `complete`
    is False when a section was opened and never closed or the record never
    reached `::logend` — the shape a pull cut off mid-file has, which the
    ingester refuses rather than landing half a box.
    """
    _here_on_path()
    from floor.units import parse_probe  # noqa: E402
    meta, loglines = parse_probe(text)
    files = meta.get("file-sections") or {}
    complete = (meta.get("open-section") is None
                and "::logend" in text.splitlines())
    return meta, loglines, files, complete


# --------------------------------------------------------------------------
# ingest
# --------------------------------------------------------------------------

def _upsert_box(conn, name, **fields):
    conn.execute("INSERT OR IGNORE INTO boxes(name) VALUES(?)", (name,))
    sets = {k: v for k, v in fields.items() if v is not None}
    if sets:
        conn.execute("UPDATE boxes SET %s WHERE name=?"
                     % ", ".join("%s=?" % k for k in sets),
                     tuple(sets.values()) + (name,))


def _ingest_lines(conn, box, lines, first_n=None):
    """Land duty.log lines: the raw line, and what each one is."""
    inserted = sessions = 0
    for i, raw in enumerate(lines):
        line = raw.replace("\x00", "")
        if not line.strip():
            continue
        n = (first_n + i) if first_n is not None else None
        m = TS_RE.match(line)
        ts, body = (m.group(1), m.group(2)) if m else ("", line)
        cur = conn.execute("INSERT OR IGNORE INTO duty_log(box, ts, line, n) VALUES(?,?,?,?)",
                           (box, ts, line, n))
        inserted += cur.rowcount
        if m:
            row = parse_session_end(line)
            if row is not None:
                row["box"] = box
                cur = conn.execute(
                    "INSERT OR IGNORE INTO sessions(%s) VALUES(%s)"
                    % (",".join(SESSION_COLUMNS), ",".join("?" * len(SESSION_COLUMNS))),
                    tuple(row[c] for c in SESSION_COLUMNS))
                sessions += cur.rowcount
                continue
            event = classify_tick(body)
            if event:
                conn.execute("INSERT OR IGNORE INTO ticks(box, ts, event, line) VALUES(?,?,?,?)",
                             (box, ts, event, line))
            continue
        v = _VITALS_RE.match(line)
        if v:
            fields = parse_vitals_fields(v.group(1))
            if fields.get("ts"):
                conn.execute("INSERT OR IGNORE INTO vitals(box, ts, fields_json) VALUES(?,?,?)",
                             (box, fields["ts"], json.dumps(fields, sort_keys=True)))
    return inserted, sessions


def _ingest_limit_events(conn, box, lines):
    for raw in lines:
        line = raw.replace("\x00", "").rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        ts = parts[1] if len(parts) > 1 and _STAMP_RE.match(parts[1]) else None
        conn.execute("INSERT OR IGNORE INTO limit_events(box, ts, line) VALUES(?,?,?)",
                     (box, ts, line))


def _is_ledger(name):
    return name.startswith(".seen-") or name.startswith(".suppressed-")


def _ingest_file(conn, box, name, lines, full=False):
    """One state file. A LEDGER lands row by row, the whole line kept (`id ts
    rest`); on a FULL pull the file is the truth, so rows the box no longer
    has leave the store too — a dropped `.seen-*` row or a cleared
    `.suppressed-*` report must not come back at the next reset (#763)."""
    content = "\n".join(lines) + ("\n" if lines else "")
    if _is_ledger(name):
        ids = []
        for raw in lines:
            parts = raw.split()
            if len(parts) >= 2:
                rest = " ".join(parts[2:])
                ids.append(parts[0])
                # The box's line REPLACES the stored one: field 2 is a
                # timestamp in a seen-ledger, but a digest in .seen-hygiene
                # and a state (OPEN/CLOSED) in .seen-graph, so ordering the
                # two by it kept an old digest and an OPEN over a CLOSED —
                # and a reset box swept, or re-fired, what it had already
                # acted on. Ledgers cross only on a full pull, and there the
                # file is the truth (#763 review).
                conn.execute(
                    "INSERT INTO ledger(box, name, id, ts, rest) VALUES(?,?,?,?,?) "
                    "ON CONFLICT(box, name, id) DO UPDATE SET ts=excluded.ts, rest=excluded.rest",
                    (box, name, parts[0], parts[1], rest))
        if full:
            if ids:
                conn.execute("DELETE FROM ledger WHERE box=? AND name=? AND id NOT IN (%s)"
                             % ",".join("?" * len(ids)), (box, name) + tuple(ids))
            else:
                conn.execute("DELETE FROM ledger WHERE box=? AND name=?", (box, name))
        return
    if name == ".limit-events":
        _ingest_limit_events(conn, box, lines)
    conn.execute("INSERT OR REPLACE INTO state_files(box, name, content) VALUES(?,?,?)",
                 (box, name, content))


def record_pull(conn, box, ok, note, now=None, state=None):
    """One pulls row. A failed pull repeats only when its note changes, so a
    box that stays down costs one row and not one per poll."""
    at = now_iso(now)
    if not ok:
        last = conn.execute("SELECT ok, note FROM pulls WHERE box=? ORDER BY rowid DESC LIMIT 1",
                            (box,)).fetchone()
        if last is not None and not last["ok"] and last["note"] == note:
            _upsert_box(conn, box, source_state=state)
            return
    conn.execute("INSERT INTO pulls(box, at, ok, note) VALUES(?,?,?,?)", (box, at, 1 if ok else 0, note))
    _upsert_box(conn, box, source_state=state)


def failed_pull(box, note, state="unreachable", path=None, now=None):
    """The collector's hook for a probe that did not answer: record it and
    leave every stored row where it is."""
    conn = connect(path)
    try:
        conn.execute("BEGIN IMMEDIATE")
        record_pull(conn, box, False, note, now, state)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def note_state(box, state, path=None):
    """What the inventory said about a box that was not probed (stopped,
    absent): kept on the row, no pulls entry."""
    conn = connect(path)
    try:
        conn.execute("BEGIN IMMEDIATE")
        _upsert_box(conn, box, source_state=state)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def ingest(conn, box, text, agent=None, roles=None, pool=None, now=None, state="running"):
    """Land one probe record for one box in one transaction.

    Returns a dict: ok, note, lines (duty.log lines newly inserted), sessions
    (newly inserted), files (sections landed). On a truncated record nothing
    is written but a failed pull, and ok is False.
    """
    meta, loglines, files, complete = parse_record(text)
    at = now_iso(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        if not complete:
            record_pull(conn, box, False, "truncated record", now, state)
            conn.execute("COMMIT")
            return {"ok": False, "note": "truncated record", "lines": 0, "sessions": 0, "files": 0}
        prev = conn.execute("SELECT log_lines FROM boxes WHERE name=?", (box,)).fetchone()
        prev_lines = int(prev["log_lines"]) if prev else 0
        log_lines = None
        if "duty.log" in files:
            # The whole file or its tail from `::logfrom`; a `logfrom` of 1
            # with fewer lines than we had is the rotated file, re-read from
            # the top, and the UNIQUE keys refuse what is already here.
            try:
                first = max(1, int(meta.get("logfrom") or 1))
            except ValueError:
                first = 1
            try:
                total = int(meta.get("logtotal") or (first - 1 + len(files["duty.log"])))
            except ValueError:
                total = first - 1 + len(files["duty.log"])
            inserted, sessions = _ingest_lines(conn, box, files["duty.log"], first)
            log_lines = total
        else:
            # A plain record: the newest 600 lines, position unknown. Landed
            # by content, so a second plain record of the same box inserts
            # nothing; the tail offset stays what it was.
            inserted, sessions = _ingest_lines(conn, box, loglines, None)
        landed = 0
        for name, lines in files.items():
            if name == "duty.log":
                continue
            if name == "duty.log.1":
                # The rotated log, shipped whole once per rotation: lines
                # written between the last pull and the rotation land by
                # content, and the UNIQUE keys refuse what is already here.
                # Its size+mtime mark is remembered so the next probe is told
                # (PROBE_LOG1_SEEN) and ships it again only when it changes —
                # not up to 5 MB on every poll until the next rotation.
                _ingest_lines(conn, box, lines, None)
                landed += 1
                if meta.get("log1mark"):
                    conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)",
                                 ("log1mark:%s" % box, meta["log1mark"]))
                continue
            _ingest_file(conn, box, name, lines, full="statefiles" in meta)
            landed += 1
        if "statefiles" in meta:
            # Full mode names every state file the box has, so one it no
            # longer has — a breaker that cleared, a ledger emptied — leaves
            # the store too.
            present = tuple(sorted(set(meta["statefiles"].split())))
            if present:
                conn.execute("DELETE FROM state_files WHERE box=? AND name NOT IN (%s)"
                             % ",".join("?" * len(present)), (box,) + present)
                conn.execute("DELETE FROM ledger WHERE box=? AND name NOT IN (%s)"
                             % ",".join("?" * len(present)), (box,) + present)
            else:
                conn.execute("DELETE FROM state_files WHERE box=?", (box,))
                conn.execute("DELETE FROM ledger WHERE box=?", (box,))
        if meta.get("limit-events") and "duty.log" not in files:
            _ingest_limit_events(conn, box, meta["limit-events"])
        if meta.get("vitals"):
            v = _VITALS_RE.match(meta["vitals"])
            if v:
                fields = parse_vitals_fields(v.group(1))
                if fields.get("ts"):
                    conn.execute("INSERT OR IGNORE INTO vitals(box, ts, fields_json) VALUES(?,?,?)",
                                 (box, fields["ts"], json.dumps(fields, sort_keys=True)))
        if pool is None:
            newest = conn.execute(
                "SELECT pool FROM sessions WHERE box=? AND pool IS NOT NULL "
                "ORDER BY ts_end DESC LIMIT 1", (box,)).fetchone()
            pool = newest["pool"] if newest else None
        _upsert_box(conn, box, agent=agent, roles=roles, pool=pool,
                    engine=meta.get("engine"), integrity=meta.get("integrity"),
                    last_seen=at, last_pull_ok=at, source_state=state,
                    log_lines=log_lines if log_lines is not None else prev_lines)
        note = "%d lines, %d sessions, %d files" % (inserted, sessions, landed)
        record_pull(conn, box, True, note, now, state)
        conn.execute("COMMIT")
        return {"ok": True, "note": note, "lines": inserted, "sessions": sessions, "files": landed}
    except Exception:
        conn.execute("ROLLBACK")
        raise


def ingest_record(box, text, agent=None, roles=None, pool=None, path=None, now=None,
                  state="running"):
    """ingest() on a fresh connection — the collector's per-probe call."""
    conn = connect(path)
    try:
        return ingest(conn, box, text, agent, roles, pool, now, state)
    finally:
        conn.close()


def next_log_line(box, path=None):
    """The `PROBE_LOG_FROM` for the next cadence pull of this box."""
    conn = connect(path)
    try:
        row = conn.execute("SELECT log_lines FROM boxes WHERE name=?", (box,)).fetchone()
        return (int(row["log_lines"]) + 1) if row else 1
    finally:
        conn.close()


def log1_seen(box, path=None):
    """The size+mtime mark of the rotated log last landed for this box."""
    conn = connect(path)
    try:
        row = conn.execute("SELECT value FROM meta WHERE key=?", ("log1mark:%s" % box,)).fetchone()
        return row["value"] if row else ""
    finally:
        conn.close()


def probe_env(box, path=None):
    """The environment that puts probe.sh in full mode for this box's next
    cadence pull: everything new since the last one, every state file, and
    the rotated log only when it is not the one already landed."""
    env = {"PROBE_FULL": "1", "PROBE_LOG_FROM": str(next_log_line(box, path))}
    seen = log1_seen(box, path)
    if seen:
        env["PROBE_LOG1_SEEN"] = seen
    return env


# --------------------------------------------------------------------------
# readers
# --------------------------------------------------------------------------

def _since_iso(since, now=None):
    """`24h`, `7d`, `<n>h`, `<n>d` -> the ISO stamp the window starts at."""
    m = re.fullmatch(r"(\d+)([hd])", since or "")
    if not m:
        raise ValueError("window must be <n>h or <n>d, e.g. 24h or 7d")
    seconds = int(m.group(1)) * (3600 if m.group(2) == "h" else 86400)
    return now_iso((now if now is not None else time.time()) - seconds)


def box_row(conn, box):
    row = conn.execute("SELECT * FROM boxes WHERE name=?", (box,)).fetchone()
    return dict(row) if row else None


def stored_lines(conn, box, limit=600):
    """The newest `limit` duty.log lines in file order — the same window
    probe.sh ships, so the stored unit is derived over what the live one is."""
    rows = conn.execute(
        "SELECT line FROM duty_log WHERE box=? ORDER BY rowid DESC LIMIT ?",
        (box, limit)).fetchall()
    return [r["line"] for r in reversed(rows)]


def last_session(conn, box):
    row = conn.execute(
        "SELECT * FROM sessions WHERE box=? ORDER BY ts_end DESC, rowid DESC LIMIT 1",
        (box,)).fetchone()
    return dict(row) if row else None


def window_cost(conn, since_iso, box=None):
    """(sessions, minutes, cost_usd or None, unpriced) over a window."""
    where, args = "ts_end >= ?", [since_iso]
    if box is not None:
        where += " AND box = ?"
        args.append(box)
    row = conn.execute(
        "SELECT COUNT(*) AS n, COALESCE(SUM(dur_s), 0) AS secs, SUM(cost_usd) AS cost, "
        "SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced "
        "FROM session_costs WHERE %s" % where, args).fetchone()
    return int(row["n"]), int(row["secs"]) // 60, row["cost"], int(row["unpriced"] or 0)


def last_pull(conn, box):
    row = conn.execute("SELECT at, ok, note FROM pulls WHERE box=? ORDER BY rowid DESC LIMIT 1",
                       (box,)).fetchone()
    return dict(row) if row else None


def fmt_ago(iso, now=None):
    try:
        then = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return "?"
    s = max(0, int((now if now is not None else time.time()) - then))
    h, m = s // 3600, (s % 3600) // 60
    if h >= 48:
        return "%dd ago" % (h // 24)
    return ("%dh %02dm ago" % (h, m)) if h else ("%dm ago" % m if m else "%ds ago" % s)


def fmt_usd(cost):
    if cost is None:
        return "—"
    return "$%.4f" % cost


def stored_reading(box, path=None, now=None):
    """Everything `crew status` and the floor say about a box from the store,
    or None when the store has never had an ok pull of it."""
    conn = connect(path)
    try:
        b = box_row(conn, box)
        if not b or not b.get("last_pull_ok"):
            return None
        sess = last_session(conn, box)
        pull = last_pull(conn, box)
        n, minutes, cost, unpriced = window_cost(conn, _since_iso("24h", now), box)
        return {"box": b, "session": sess, "pull": pull, "stored_at": b["last_pull_ok"],
                "window": {"since": "24h", "sessions": n, "minutes": minutes,
                           "cost_usd": cost, "unpriced": unpriced},
                "lines": stored_lines(conn, box)}
    finally:
        conn.close()


def status_lines(box, brief=False, path=None, now=None):
    """The CLI's stored reading, labelled `stored` on every line."""
    r = stored_reading(box, path, now)
    if r is None:
        return []
    s, pull, w = r["session"], r["pull"], r["window"]
    if s:
        last = "%s %s → %s, %s" % (s["kind"], s["key"], s["outcome"] or "?", fmt_ago(s["ts_end"], now))
    else:
        last = "no session on record"
    pulled = "pulled %s" % fmt_ago(r["stored_at"], now)
    if pull and not pull["ok"]:
        pulled += ", last pull FAILED (%s)" % pull["note"]
    cost = "24h %d session(s), %dm, %s" % (w["sessions"], w["minutes"], fmt_usd(w["cost_usd"]))
    if w["unpriced"]:
        cost += " (%d unpriced)" % w["unpriced"]
    if brief:
        return ["stored: %s · %s · %s" % (last, pulled, cost)]
    out = ["stored (%s, %s):" % (pulled, r["stored_at"]), "  last session: %s" % last]
    if s and (s["rc"] is not None or s["dur_s"] is not None):
        out[-1] += " (rc=%s, %s)" % (s["rc"] if s["rc"] is not None else "-",
                                     ("%ds" % s["dur_s"]) if s["dur_s"] is not None else "-")
    out.append("  %s" % cost)
    return out


def usage(conn, since="24h", by="member", now=None):
    """Sessions, minutes and cost per group over a window, from the store alone."""
    col = {"member": "box", "pool": "COALESCE(pool, '-')", "kind": "kind"}.get(by)
    if col is None:
        raise ValueError("--by must be member, pool or kind")
    rows = conn.execute(
        "SELECT %s AS grp, COUNT(*) AS n, COALESCE(SUM(dur_s), 0) AS secs, "
        "SUM(cost_usd) AS cost, SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced "
        "FROM session_costs WHERE ts_end >= ? GROUP BY grp ORDER BY grp" % col,
        (_since_iso(since, now),)).fetchall()
    return [{"group": r["grp"], "sessions": int(r["n"]), "minutes": int(r["secs"]) // 60,
             "cost_usd": r["cost"], "unpriced": int(r["unpriced"] or 0)} for r in rows]


def usage_table(rows, since, by):
    head = {"member": "MEMBER", "pool": "POOL", "kind": "KIND"}[by]
    fmt = "%-24s %9s %9s %12s %s"
    out = [fmt % (head, "SESSIONS", "MINUTES", "COST", "")]
    total_n = total_m = 0
    total_cost, any_cost, total_unpriced = 0.0, False, 0
    for r in rows:
        note = ("%d unpriced" % r["unpriced"]) if r["unpriced"] else ""
        out.append(fmt % (r["group"], r["sessions"], r["minutes"], fmt_usd(r["cost_usd"]), note))
        total_n += r["sessions"]
        total_m += r["minutes"]
        total_unpriced += r["unpriced"]
        if r["cost_usd"] is not None:
            total_cost += r["cost_usd"]
            any_cost = True
    out.append(fmt % ("total (%s)" % since, total_n, total_m,
                      fmt_usd(total_cost if any_cost else None),
                      ("%d unpriced" % total_unpriced) if total_unpriced else ""))
    return out


def stored_unit(box, now, path=None):
    """The floor's unit fields for a box that did not answer, from the store.

    Returns None when nothing was ever pulled. Otherwise the same session,
    queue, spark and count fields build_unit derives for a live box, derived
    by the same functions over the stored lines, plus `source`, `stored_at`
    and the 24h cost.
    """
    r = stored_reading(box, path, now)
    if r is None:
        return None
    _here_on_path()
    from floor.units import derive_queue, derive_sessions, spark_24h  # noqa: E402
    lines = r["lines"]
    sessions, cur = derive_sessions(lines, now, 0, None)
    out = {
        "source": "stored",
        "stored_at": r["stored_at"],
        "cost_24h": r["window"]["cost_usd"],
        # Not engine or integrity: those are claims about the box NOW, and a
        # box that does not answer can make none. The CLI's stored reading
        # names the last engine the store saw; the page keeps rendering an
        # off box as off.
        "queue": derive_queue(lines),
        "sessions": [{k: s[k] for k in
                      ("ago", "kind", "key", "rc", "dur", "out", "acted", "reply", "peak",
                       "log", "log_unavailable")} for s in sessions[:11]],
        "spark": spark_24h(sessions, now),
        "today": sum(1 for s in sessions if now - s["ts"] < 86400),
    }
    if sessions:
        durs = [s["dur"] for s in sessions if s["dur"] is not None]
        ok = sum(1 for s in sessions if s["rc"] == 0)
        out["longest"] = max(durs) if durs else 0
        out["avg"] = round(sum(durs) / len(durs)) if durs else 0
        out["success"] = round(100 * ok / len(sessions))
    return out


# --------------------------------------------------------------------------
# the script half
# --------------------------------------------------------------------------

def _arg(argv, flag, default=None):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
        raise SystemExit("store.py: %s needs a value" % flag)
    return default


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    verb = argv[0] if argv else ""
    if verb == "path":
        print(store_path())
        return 0
    if verb == "init":
        print(init())
        return 0
    if verb == "ingest":
        box = _arg(argv, "--box")
        if not box:
            raise SystemExit("store.py ingest: --box is required")
        text = sys.stdin.read()
        res = ingest_record(box, text, _arg(argv, "--agent"), _arg(argv, "--roles"),
                            _arg(argv, "--pool"), state=_arg(argv, "--state", "running"))
        print("%s: %s%s" % (box, "" if res["ok"] else "pull FAILED — ", res["note"]))
        return 0 if res["ok"] else 1
    if verb == "fail":
        box = _arg(argv, "--box")
        if not box:
            raise SystemExit("store.py fail: --box is required")
        failed_pull(box, _arg(argv, "--note", "did not answer"),
                    _arg(argv, "--state", "unreachable"))
        return 0
    if verb == "status":
        box = _arg(argv, "--box")
        if not box:
            raise SystemExit("store.py status: --box is required")
        lines = status_lines(box, brief="--brief" in argv)
        for line in lines:
            print(line)
        return 0 if lines else 1
    if verb == "usage":
        since = _arg(argv, "--since", "24h")
        by = _arg(argv, "--by", "member")
        conn = connect(readonly=True)
        try:
            rows = usage(conn, since, by)
        except ValueError as e:
            raise SystemExit("store.py usage: %s" % e)
        finally:
            conn.close()
        for line in usage_table(rows, since, by):
            print(line)
        return 0
    # The host tick's reads (#759): one state file, one ledger, one lane's
    # session count — each from the store alone, so a wake decision about a
    # box that is OFF costs no exec. Absent is an exit of 1 and no output.
    if verb == "state":
        box, name = _arg(argv, "--box"), _arg(argv, "--name")
        if not box or not name:
            raise SystemExit("store.py state: --box and --name are required")
        conn = connect(readonly=True)
        try:
            row = conn.execute("SELECT content FROM state_files WHERE box=? AND name=?",
                               (box, name)).fetchone()
        finally:
            conn.close()
        if row is None:
            return 1
        sys.stdout.write(row[0] if row[0].endswith("\n") or row[0] == "" else row[0] + "\n")
        return 0
    if verb == "states":
        box, prefix = _arg(argv, "--box"), _arg(argv, "--prefix", "")
        if not box:
            raise SystemExit("store.py states: --box is required")
        conn = connect(readonly=True)
        try:
            rows = conn.execute("SELECT name, content FROM state_files WHERE box=? ORDER BY name",
                                (box,)).fetchall()
        finally:
            conn.close()
        rows = [(n, c) for n, c in rows if n.startswith(prefix)]
        for name, content in rows:
            print("%s\t%s" % (name, (content or "").split("\n")[0]))
        return 0 if rows else 1
    if verb == "export":
        # The member's memory, as files (#761): every state file and every
        # ledger the store holds for the box, written under --dir with the
        # names the engine reads them by, so a reset box gets them back.
        box, out = _arg(argv, "--box"), _arg(argv, "--dir")
        if not box or not out:
            raise SystemExit("store.py export: --box and --dir are required")
        os.makedirs(out, exist_ok=True)
        conn = connect(readonly=True)
        try:
            files = conn.execute("SELECT name, content FROM state_files WHERE box=?", (box,)).fetchall()
            try:
                ledgers = conn.execute("SELECT name, id, ts, rest FROM ledger WHERE box=? ORDER BY name, id",
                                       (box,)).fetchall()
            except sqlite3.OperationalError as e:
                # A reader never migrates; a store still at schema 1 has no
                # `rest`. Said as that, not as a traceback: the next writer
                # (the collector's poll, `crew up`) brings it to this schema.
                raise SystemExit("store.py export: the store predates this schema (%s); "
                                 "a writer — the collector or `crew up` — migrates it first" % e)
        finally:
            conn.close()
        written = 0
        for name, content in files:
            if "/" in name or name in (".", ".."):
                continue
            with open(os.path.join(out, name), "w", encoding="utf-8") as f:
                f.write(content or "")
            written += 1
        by_name = {}
        for name, rid, ts, rest in ledgers:
            by_name.setdefault(name, []).append(("%s %s %s" % (rid, ts, rest or "")).rstrip())
        for name, lines in by_name.items():
            if "/" in name:
                continue
            with open(os.path.join(out, name), "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
            written += 1
        print("%s: %d file(s) exported to %s" % (box, written, out))
        return 0
    if verb == "peaks":
        # Observed peak memory per box (#761): the largest peak_rss the
        # kernel recorded for any session in the window, and how many
        # sessions reported one — the figure a role's BOX_MEMORY is sized by.
        since = _arg(argv, "--since", "7d")
        box = _arg(argv, "--box")
        conn = connect(readonly=True)
        try:
            cutoff = _since_iso(since)
            if box:
                rows = conn.execute("SELECT box, MAX(peak_rss_kib), COUNT(peak_rss_kib) FROM sessions "
                                    "WHERE box=? AND ts_end>=? GROUP BY box", (box, cutoff)).fetchall()
            else:
                rows = conn.execute("SELECT box, MAX(peak_rss_kib), COUNT(peak_rss_kib) FROM sessions "
                                    "WHERE ts_end>=? GROUP BY box ORDER BY box", (cutoff,)).fetchall()
        except ValueError as e:
            raise SystemExit("store.py peaks: %s" % e)
        finally:
            conn.close()
        for b, peak, n in rows:
            print("%s %s %d" % (b, "-" if peak is None else int(peak), n))
        return 0 if rows else 1
    if verb == "ledger":
        box, name = _arg(argv, "--box"), _arg(argv, "--name")
        if not box:
            raise SystemExit("store.py ledger: --box is required")
        conn = connect(readonly=True)
        try:
            if name:
                rows = conn.execute("SELECT id, ts FROM ledger WHERE box=? AND name=? ORDER BY id",
                                    (box, name)).fetchall()
            else:
                rows = conn.execute("SELECT id, ts FROM ledger WHERE box=? ORDER BY name, id",
                                    (box,)).fetchall()
        finally:
            conn.close()
        for rid, ts in rows:
            print("%s %s" % (rid, ts))
        return 0 if rows else 1
    if verb == "sessions-count":
        box, kind = _arg(argv, "--box"), _arg(argv, "--kind")
        since = _arg(argv, "--since", "24h")
        if not box:
            raise SystemExit("store.py sessions-count: --box is required")
        conn = connect(readonly=True)
        try:
            cutoff = _since_iso(since)
            if kind:
                n = conn.execute("SELECT COUNT(*) FROM sessions WHERE box=? AND kind=? AND ts_end>=?",
                                 (box, kind, cutoff)).fetchone()[0]
            else:
                n = conn.execute("SELECT COUNT(*) FROM sessions WHERE box=? AND ts_end>=?",
                                 (box, cutoff)).fetchone()[0]
        except ValueError as e:
            raise SystemExit("store.py sessions-count: %s" % e)
        finally:
            conn.close()
        print(n)
        return 0
    raise SystemExit("usage: store.py init | ingest --box NAME | fail --box NAME | "
                     "status --box NAME [--brief] | usage [--since W] [--by G] | path | "
                     "state --box NAME --name FILE | states --box NAME [--prefix P] | ledger --box NAME [--name FILE] | "
                     "sessions-count --box NAME [--kind K] [--since W] | export --box NAME --dir DIR | peaks [--box NAME] [--since W]")


if __name__ == "__main__":
    sys.exit(main())
