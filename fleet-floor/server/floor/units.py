"""duty.log and one probe -> the record the page renders."""

import base64
import math
import re
import time
from datetime import datetime, timezone

from floor import SILENT_AFTER_S
from floor.ping import STUCK_AFTER_S, probe_box

# --------------------------------------------------------------------------
# duty.log -> telemetry  (#38)
# --------------------------------------------------------------------------

# THESE PATTERNS STAY with the store in place (#758). The store holds the
# box's duty.log LINES (floor/store.py, `duty_log`), not a second opinion
# about them: a unit served from the store for a box that does not answer is
# derived by running these same functions over the stored lines, and the live
# path keeps parsing the probe exactly as before. One parser, two sources —
# retiring the regexes would have meant a second parser in SQL that could
# disagree with this one about what a line says.
TS = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
# The `timeout=` group is what STUCK is measured against (#610): the session
# states its own ceiling on the record, so the floor never keeps a second copy
# of the timeout table and never reads the box's role confs from the host.
#
# Optional, and it SCANS for the token rather than assuming it follows `key=`,
# which is the rule session.sh:645-663 states for this line and RE_END's late
# fields alike: the head of the pattern is anchored and everything after it is
# read wherever it sits, so a field inserted between two others breaks no
# deployed floor. `key=(\S+)` therefore still ends the anchored part, exactly
# as it did before this group existed. Absent — every line written before
# #538 put `timeout=` on this record — the group matches nothing and the
# reader falls back to STUCK_AFTER_S, which is what an un-upgraded box gets.
RE_START = re.compile(TS + r" SESSION START kind=(\S+) key=(\S+)"
                      r"(?:.*? timeout=(\d+)s(?=\s|$))?"
                      r"(?:.*? log=(\S+)(?=\s|$))?")
RE_END = re.compile(TS + r" SESSION END kind=(\S+) key=(\S+) rc=(\d+|-) dur=(\d+s|-) outcome=(\S+)"
                    r"(?: acted=(yes|no|unknown) reply_tail=(\S*))?")
RE_SKIP = re.compile(TS + r" SESSION SKIP kind=(\S+) key=(\S+) reason=(\S+)")
# The terminal breaker announcing its own recovery. `_session_terminal_gate`
# spends one vendor probe per tick on a tripped lane, and on success deletes
# the state file and writes this line (shared/lib/common/breaker.sh:44-49).
# It is the only recovery evidence a lane gets when the probe succeeds but the
# tick had nothing left to dispatch — no START and no END follow it — so a
# reader that watched only sessions would keep a cleared breaker on screen
# until the next tick found work (#611 round 3).
RE_BREAKER_OK = re.compile(TS + r" session breaker: kind=(\S+) recovered")
# `SESSION_ORPHAN_OUTCOME` (shared/lib/common/ledger.sh:118). Held as a word
# here for the same reason `TERMINAL` is: the BOX states the verdict and the
# host reads it off `outcome=`. That is the boundary #611 draws — no host-side
# copy of a vendor's banner, no second classifier — and this is the reading
# side of it, not a second copy of it.
_ORPHAN_OUTCOME = "ORPHANED"
# peak_rss= is read by its own pattern rather than by another optional group on
# RE_END, and the reason is what RE_END already survived: the engine appends
# new fields past reply_tail (tier=, and started= on a reconstructed terminal),
# so a group that assumed a position would break the moment the next one lands.
# This one matches the token wherever it sits and matches nothing when it is
# absent — which is every line written before #473, and every session the
# engine could not measure. `peak_rss=-` is the reconstructed terminal's "owed
# and lost with the box": it is deliberately not a digit, so it reads as no
# figure here without a second case.
RE_PEAK = re.compile(r" peak_rss=(\d+)(?:\s|$)")
RE_ANY_TS = re.compile("^" + TS + r" ")
# #483 D1 — the box vitals record. This page and `crew status` render the SAME
# line out of the SAME duty.log by the SAME selection rule (the newest line
# with this prefix); probe.sh carries it here verbatim and `crew status` greps
# for it directly. Two readers with private probes disagree in front of an
# operator, which is the defect this console exists to end, so neither of them
# measures anything — the tick measured it once and both quote it.
#
# NOT anchored on a leading timestamp, unlike every pattern above it: tick.sh
# writes this record with its own `ts=` field and no leading stamp, because it
# is emitted OUTSIDE the lock and before the dispatch, so it is deliberately
# not one of the `$JOB tick …` evidence shapes that log's contract is about.
# The prefix is still required: a `::vitals` carrying anything else is a box
# answering a question nobody asked, and it renders as nothing.
RE_VITALS = re.compile(r"^VITALS (ts=\S+.*)$")

# Wake lines the duty modules already write. The queue shown on the floor is
# derived from these — it is real detected work, not a placeholder list. Each
# pattern yields (repo, key) pairs for the most recent completed tick.
RE_QUEUE = [
    re.compile(TS + r" attention: (\S+?)#(\d+) — launching pickup session"),
    re.compile(TS + r" review: (\S+?)#(\d+) head moved during dedup"),
]
RE_REVIEW_BATCH = re.compile(TS + r" review: (\S+) needs verdicts on: (.+)$")
RE_BUILD_DUTY = re.compile(TS + r" (\S+): build duty \(ready unclaimed=(\d+), whole rounds owed=(\d+)\)")
RE_TRIAGE = re.compile(TS + r" (\S+): signals:(\S+) launching triage session")
# The tick-wide batch has no repository. Its trailing "one mention session"
# clause is the structural discriminator; the leading word is deliberately
# not treated as a magic repository name because a real repo may be `fleet`.
RE_MENTION_BATCH = re.compile(
    TS + r" \S+: (\d+) unread mention\(s\) — launching one mention session$"
)
RE_MENTION = re.compile(
    TS + r" (\S+): (\d+) unread mention(?:\(s\))?(?: — launching mention session)?$"
)
RE_RESUME = re.compile(TS + r" (\S+): resume duty")
_SESSION_ACTIVE_AFTER_S = 21600
# The guest spool's default retention bound. The probe carries event timestamps
# but not the guest's environment override, so the floor uses the engine's
# shipped bound and, below, also requires stopping severity and no newer
# SUCCESSFUL box session. An old line left behind in an otherwise quiet spool
# must never latch LIMITED for the life of the box.
_LIMIT_EVENT_TTL_S = 86400


def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def parse_probe(text):
    """Split the probe's `::key value` record from its delimited sections.

    Four section kinds. The log, limit and tick-health sections are the
    cadence record every poll reads. `::filestart <name>` … `::fileend` is
    the full-mode record (#758, `PROBE_FULL=1`): one section per state file
    and one for duty.log, collected under `meta["file-sections"]` by name and
    never read as keys — a ledger line or a log line that happens to begin
    with `::` is data. `meta["open-section"]` names a section that was never
    closed, which is what a record cut off mid-file looks like; the store
    refuses such a record rather than landing half a box.
    """
    meta, loglines, limitlines, healthlines = {}, [], [], []
    files, open_file = {}, None
    in_log, in_limits, in_health = False, False, False
    for line in text.splitlines():
        if open_file is not None:
            if line == "::fileend":
                open_file = None
            else:
                files[open_file].append(line)
            continue
        if line == "::limitstart":
            in_limits = True
            continue
        if line == "::limitend":
            in_limits = False
            continue
        if line == "::logstart":
            in_log = True
            continue
        if line == "::logend":
            in_log = False
            continue
        if line == "::tickhealthstart":
            in_health = True
            continue
        if line == "::tickhealthend":
            in_health = False
            continue
        if in_limits:
            limitlines.append(line)
        elif in_log:
            loglines.append(line)
        elif in_health:
            healthlines.append(line)
        elif line.startswith("::filestart "):
            open_file = line[len("::filestart "):].strip()
            files.setdefault(open_file, [])
        elif line.startswith("::"):
            k, _, v = line[2:].partition(" ")
            meta[k] = v.strip()
    meta["limit-events"] = limitlines
    meta["tick-health"] = healthlines
    meta["file-sections"] = files
    meta["open-section"] = (open_file if open_file is not None
                            else "log" if in_log
                            else "limits" if in_limits
                            else "tick-health" if in_health else None)
    return meta, loglines


def parse_tick_health(lines):
    """The shared shell derivation's bounded report -> floor JSON."""
    report = None
    kinds = []
    for line in lines or []:
        parts = line.split()
        if not parts:
            continue
        fields = {}
        for token in parts[1:]:
            key, sep, value = token.partition("=")
            if sep and value:
                fields[key] = value
        try:
            window = int(fields["window_s"])
            if window <= 0:
                continue
            if parts[0] == "TICK_HEALTH":
                age = fields.get("last_tick_age_s", "-")
                report = {
                    "window": window,
                    "last_tick_age": None if age == "-" else max(0, int(age)),
                    "ticks": max(0, int(fields["ticks"])),
                    "busy": max(0, int(fields["busy"])),
                    "kinds": kinds,
                }
            elif parts[0] == "TICK_HEALTH_KIND":
                holds = {}
                if fields.get("holds") not in (None, "-"):
                    for item in fields["holds"].split(","):
                        reason, sep, count = item.rpartition(":")
                        if sep and reason:
                            holds[reason] = max(0, int(count))
                kinds.append({
                    "kind": fields["kind"], "window": window,
                    "skips": max(0, int(fields["skips"])), "holds": holds,
                    "outcome": None if fields.get("outcome") == "-" else fields.get("outcome"),
                    "streak": max(0, int(fields.get("streak", "0"))),
                })
        except (KeyError, TypeError, ValueError):
            continue
    if report is not None:
        report["kinds"] = [item for item in kinds if item["window"] == report["window"]]
    return report


def last_tick_block(loglines):
    """Lines of the most recent `duty run start` block — the current work set."""
    start = None
    for i in range(len(loglines) - 1, -1, -1):
        if " duty run start" in loglines[i]:
            start = i
            break
    return loglines[start:] if start is not None else loglines[-40:]


def derive_queue(loglines):
    """Work the last tick actually detected, as {repo,key} chips."""
    q, seen = [], set()

    def add(repo, key):
        k = (repo, str(key))
        if k not in seen:
            seen.add(k)
            q.append({"repo": repo, "key": str(key)})

    for line in last_tick_block(loglines):
        for rx in RE_QUEUE:
            m = rx.search(line)
            if m:
                add(m.group(2), m.group(3))
        m = RE_REVIEW_BATCH.search(line)
        if m:
            for num in re.findall(r"#?(\d+)", m.group(3)):
                add(m.group(2), num)
        m = RE_BUILD_DUTY.search(line)
        if m:
            ready, owed = int(m.group(3)), int(m.group(4))
            for n in range(ready):
                add(m.group(2), "ready %d" % (n + 1))
            for n in range(owed):
                add(m.group(2), "round %d" % (n + 1))
        m = RE_TRIAGE.search(line)
        if m:
            add(m.group(2), m.group(3))
        m = RE_MENTION_BATCH.search(line)
        if m:
            add(None, "%s mentions" % m.group(2))
        m = RE_MENTION.search(line)
        if m:
            add(m.group(2), "%s mention" % m.group(3))
        m = RE_RESUME.search(line)
        if m:
            add(m.group(2), "resume")
    return q


def derive_sessions(loglines, now, clock_offset=0, sessionlogs=None):
    """Finished sessions (newest first) and the open one, if any."""
    done, opens = [], []
    for line in loglines:
        m = RE_END.search(line)
        if m:
            try:
                reply = base64.b64decode(m.group(8) or "", validate=True).decode("utf-8", "replace")
            except (ValueError, TypeError):
                reply = ""
            peak = RE_PEAK.search(line)
            rc = int(m.group(4)) if m.group(4).isdigit() else None
            dur = int(m.group(5)[:-1]) if m.group(5).endswith("s") else None
            # Pair by identity rather than merely taking the last START. A
            # reconstructed terminal has no START, and an interleaved lane's
            # START must never make that row open somebody else's transcript.
            opened = None
            for index in range(len(opens) - 1, -1, -1):
                if opens[index]["kind"] == m.group(2) and opens[index]["key"] == m.group(3):
                    opened = opens.pop(index)
                    break
            log = opened.get("log") if opened else None
            unavailable = None
            if not opened:
                unavailable = "start-aged-out"
            elif not log:
                unavailable = "log-unavailable"
            elif sessionlogs is not None and log not in sessionlogs:
                log = None
                unavailable = "log-reaped"
            done.append({
                "ts": parse_ts(m.group(1)) + clock_offset, "kind": m.group(2), "key": m.group(3),
                "rc": rc, "dur": dur, "out": m.group(6),
                "acted": m.group(7) or "unknown", "reply": reply,
                "log": log, "log_unavailable": unavailable,
                # KiB, or None where the engine recorded no figure — the page
                # renders the difference rather than showing a zero nobody
                # measured (#473 D2).
                "peak": int(peak.group(1)) if peak else None,
            })
            continue
        m = RE_START.search(line)
        if m:
            opens.append({"ts": parse_ts(m.group(1)) + clock_offset,
                          "kind": m.group(2), "key": m.group(3),
                          # The lane's own ceiling, or None on a line that
                          # carried no `timeout=` token (#610).
                          "timeout": int(m.group(4)) if m.group(4) else None,
                          # The endpoint accepts a basename, never this path.
                          "log": m.group(5).rsplit("/", 1)[-1] if m.group(5) else None})

    done.sort(key=lambda s: s["ts"], reverse=True)
    for s in done:
        s["ago"] = max(0, int((now - s["ts"]) / 60))
    cur = None
    if opens:
        o = opens[-1]
        # A START with no END that predates the silence rule is a crashed or
        # killed session, not a running one — the box would have logged the END.
        if now - o["ts"] < _SESSION_ACTIVE_AFTER_S:
            cur = {"key": o["key"], "kind": o["kind"], "start": int(o["ts"]),
                   "timeout": o["timeout"]}
    return done, cur


def derive_limited(loglines, floor_events, now, clock_offset=0, event_lane="engine"):
    """Newest per-lane engine evidence -> the current LIMITED record, if any.

    TWO evidence families, and they answer recovery differently because the
    engine gives them different answers (#611 round 3).

    · THE LOG FAMILY — a TERMINAL end, and a `terminal-breaker`/`budget` SKIP
      — is state the BOX holds and the box itself clears. `run_session`
      deletes the lane's breaker file on a non-TERMINAL end: "any success,
      timeout, transient failure, or unclassified failure resets the count"
      (shared/lib/common/breaker.sh:71-81, called after every SESSION END at
      session.sh:819) — with ONE documented exception, `ORPHANED`, handled
      below. The gates run BEFORE the start line —
      budget, then terminal, then `SESSION START` (session.sh:624-663) — so a
      start newer than a SKIP is the engine saying both gates admitted that
      lane. And the terminal gate clears on a successful vendor probe and says
      so out loud: `session breaker: kind=… recovered` (breaker.sh:44-49).
      Any of those three, newer than the limit evidence on the SAME lane,
      means the box has already let go of it. Latching past them is the floor
      keeping a state the engine has cleared, which is the thing #611's fourth
      criterion forbids.

    · THE EVENT FAMILY — a durable `floor_events` error — is not box state and
      no box line retracts it. It ages out with the guest spool's TTL, or a
      COMPLETED SUCCESSFUL session acknowledges it: a lane that was dispatched
      and failed proves nothing about the condition the event reported. That
      is round 2's rule and it is kept exactly.

    Newest-per-lane, and ties break on log order rather than on the second,
    because a SKIP and a START can share a timestamp and only their order
    says which one the engine wrote last.
    """
    limits, recoveries = {}, {}
    newest_success = 0

    # Newest-per-lane, both of them, where `at` is (timestamp, log order).
    def note_recovery(lane, at):
        if at > recoveries.get(lane, (0, -1)):
            recoveries[lane] = at

    def note_limit(lane, at, reason, reset=""):
        if at > limits.get(lane, {}).get("at", (0, -1)):
            limits[lane] = {"at": at, "lane": lane, "reason": reason, "reset": reset}

    for index, line in enumerate(loglines):
        # One pattern at a time and out on the first hit: these four records
        # are mutually exclusive, and duty.log is the longest thing this
        # module reads.
        ended = RE_END.search(line)
        if ended:
            lane, at = ended.group(2), (parse_ts(ended.group(1)) + clock_offset, index)
            outcome = ended.group(6)
            if outcome == _ORPHAN_OUTCOME:
                # THE exception to "a non-TERMINAL end cleared this lane", and
                # the only one: `run_session` did not write this record.
                # `session_reconcile_orphans` did, for a session that died with
                # the box, and it passes `terminal=yes` to the same counter an
                # observed TERMINAL feeds (ledger.sh:333-339) — "a box that
                # kills itself on every review session has a dead review lane,
                # whether the vendor said so or the kernel did". So this line
                # takes the counting path, never the `rm -f`, and reading it as
                # recovery clears LIMITED on the one record that TRIPPED the
                # breaker (#611 round 4).
                #
                # Neither evidence nor recovery, which is narrower than "not
                # recovery" on purpose: `ORPHANED` says the box died, not that
                # a vendor refused, so whether it should raise LIMITED on its
                # own is triage's question and not this reader's. Dropped
                # before `newest_success` too — an orphan acknowledges no
                # durable event either.
                continue
            if outcome != "TERMINAL":
                # Recovery for the lane at ANY rc — the breaker file is gone
                # either way, including on the MEMORY outcome, where
                # `run_session` leaves `terminal=no` (session.sh:747-752).
                # Only rc=0 acknowledges a durable event, so the two families
                # read this one line for two different things.
                note_recovery(lane, at)
                if ended.group(4) == "0":
                    newest_success = max(newest_success, at[0])
                continue
            reset = ""
            try:
                reset = base64.b64decode(
                    ended.group(8) or "", validate=True
                ).decode("utf-8", "replace")
            except (ValueError, TypeError):
                pass
            note_limit(lane, at, "terminal", reset)
            continue
        started = RE_START.search(line)
        if started:
            note_recovery(started.group(2),
                          (parse_ts(started.group(1)) + clock_offset, index))
            continue
        resumed = RE_BREAKER_OK.search(line)
        if resumed:
            note_recovery(resumed.group(2),
                          (parse_ts(resumed.group(1)) + clock_offset, index))
            continue
        # A SKIP for any other reason is an ordinary duty decision — nothing
        # was refused by an operating limit — so it is neither evidence nor
        # recovery.
        skipped = RE_SKIP.search(line)
        if skipped and skipped.group(4) in ("terminal-breaker", "budget"):
            note_limit(skipped.group(2),
                       (parse_ts(skipped.group(1)) + clock_offset, index),
                       skipped.group(4))
    candidates = [item for lane, item in limits.items()
                  if recoveries.get(lane, (0, -1)) <= item["at"]]
    for event in floor_events:
        event_ts = parse_ts(event["timestamp"]) + clock_offset
        # Warnings remain durable console evidence, but they do not say a lane
        # stopped. Errors age out with the guest spool's shipped TTL, and a
        # completed successful session acknowledges the older event.
        if (event.get("severity") != "error"
                or not 0 <= now - event_ts <= _LIMIT_EVENT_TTL_S
                or newest_success > event_ts):
            continue
        # `-1` is "no log position", not position zero. A durable event is not
        # a line in duty.log, so it has no order to compare — and `0` is a
        # VALID log index, which would let an event tie exactly with the first
        # line of the file and be settled by insertion luck. The sentinel makes
        # a same-second log record win deterministically, which is the right
        # way round: that record names a lane and a reason off the engine's own
        # line, where the event's position says nothing at all (#611).
        candidates.append({
            "at": (event_ts, -1), "lane": event_lane,
            "reason": event["name"], "reset": "", "event": event["id"],
        })
    if not candidates:
        return None
    # THE WHOLE TUPLE, and the same one the per-lane rule above compares.
    # Selecting on `at[0]` alone honoured the log-order tie-break within a lane
    # and dropped it between lanes, so two lanes stopped in the same second
    # published whichever `limits` happened to be keyed first — `max` keeps its
    # first-seen item on a tie — rather than the later record. One rule for
    # both choices, or the docstring above is not describing this function
    # (#611, successor round 1).
    latest = max(candidates, key=lambda item: item["at"])
    result = {
        "state": "limited", "reason": latest["reason"],
        "age": max(0, int(now - latest["at"][0])), "lane": latest["lane"],
    }
    if latest.get("reset"):
        result["reset"] = latest["reset"]
    if latest.get("event"):
        result["event"] = latest["event"]
    return result


# The engine's kill grace, from shared/lib/common/operating-limits.sh:18
# (`session_kill_grace_seconds`). A session at its ceiling has not failed yet:
# `timeout` sends its signal and waits this long before SIGKILL, so a lock
# still held one second past the ceiling is a session being killed on
# schedule, not a wedge.
#
# Held here as a constant rather than read off the box, and that is NOT the
# host-side copy of the timeout table this issue exists to refuse. The
# difference is what varies: the ceilings are per-lane, per-role and edited in
# `shared/conf/roles/*.conf` on the box, so a host-side copy drifts on the
# first role edit — which is why they are read off the wire. This is one
# engine-wide constant with no per-box value and no field on any record to
# read it from, so there is nothing here to drift AGAINST. If it ever moves,
# it moves in one place there and one place here.
SESSION_KILL_GRACE_S = 60


def stuck_verdict(held, cur):
    """Is this duty run wedged? -> (the `lock` record, the note or "").

    THE one stuck decision (#610). Both tiers call it — the 60s evidence poll
    in `build_unit` and the 10s ping overlay in `fleet.py` — because two
    comparisons in two files is how the badge and the note come to disagree,
    and they already had: `fleet.py` re-compared `held > STUCK_AFTER_S` and
    spelled its own copy of the sentence.

    Two clauses, and neither is the other's optimisation:

    · PAST THE CEILING — a session is in flight and the lock has outlived the
      ceiling that session declared on its own `SESSION START`, plus the kill
      grace. This is the wedge the rule was written for: a `timeout` that
      should have fired and did not. It is measured against the lane's own
      number, so a `build` entitled to 3600s is not called stuck at minute 10
      for doing what it was dispatched to do.

    · NOTHING IN FLIGHT — the lock is held and no session is running at all.
      A duty run stalled BETWEEN dispatches has no ceiling to exceed, so the
      first clause can never catch it; STUCK_AFTER_S is its bound, and that
      is the one meaning of `CREW_FLOOR_STUCK_AFTER` this change keeps intact.

    STUCK_AFTER_S is also the fallback for a `SESSION START` carrying no
    `timeout=` token — every line written by an engine older than #538. An
    un-upgraded box is graded, and worded, exactly as it is today.
    """
    lock = {"held": None, "stuck": False, "ceiling": None, "bound": None}
    if not isinstance(held, int) or held < 0:
        # No usable age, and the record says so rather than publishing the
        # unusable number. The site this replaced guarded with
        # `held is not None and held >= 0` and left `unit_defaults`' None
        # standing, so filling the field here would be a change to the served
        # record that #610 never meant to make — and `rehearsal-app.sh`
        # truthiness-tests `u['lock']['held']`, which a box with a
        # future-dated `.duty.lock.since` would newly reach.
        return lock, ""
    lock["held"] = held
    ceiling = cur.get("timeout") if cur else None
    if isinstance(ceiling, int) and ceiling > 0:
        # The knob is deliberately NOT consulted here. It bounds a run with no
        # session to speak for it; capping a declared ceiling with it would
        # re-introduce the very false alarm this replaces, silently, on the
        # boxes whose operator had raised it.
        lock["ceiling"] = ceiling
        lock["bound"] = ceiling + SESSION_KILL_GRACE_S
    else:
        lock["bound"] = STUCK_AFTER_S
    if held <= lock["bound"]:
        return lock, ""
    lock["stuck"] = True
    if lock["ceiling"] is not None:
        # Name the bound, not only the age: an operator who can see 62m and
        # not the 60m it passed cannot tell a wedge from a raised threshold.
        note = ("STUCK — duty run has held the lock for %s, past the %s "
                "session's %s ceiling" % (fmt_dur(held), cur["kind"],
                                          fmt_dur(ceiling)))
    elif cur:
        # In flight, ceiling unknown. Today's sentence to the byte: there is
        # no bound to name that the box has told us about, and inventing one
        # from the host's idea of this lane is the second source of truth the
        # whole change refuses.
        note = "STUCK — duty run has held the lock for %s" % fmt_dur(held)
    else:
        note = ("STUCK — duty run has held the lock for %s with no session in "
                "flight, past %s" % (fmt_dur(held), fmt_dur(STUCK_AFTER_S)))
    return lock, note


def _vitals_finding(raw):
    """`name:k=v,k=v` -> `name: k=v, k=v`.

    The rendered sentence IS the record, and that is deliberate. `crew status`
    prints this same string from the same token, so the two readers cannot
    disagree about a finding by wording it differently — the alternative is
    each reader owning a phrase-book, which is how one console says
    "swap inactive" and the other says "swap unused" about one line.
    """
    name, _, detail = raw.partition(":")
    if not detail:
        return name
    # A plain replace, not a split-and-rejoin that drops empties: `crew status`
    # does this with `${detail//,/, }` and cannot drop them, and a rule that only
    # one of the two readers applies is a rule they can disagree under.
    return "%s: %s" % (name, detail.replace(",", ", "))


def _vitals_series(raw):
    """`<stamp>@<pct>,…` -> the backfilled disk series, oldest first (#483 D5).

    A point whose percentage is not a number is DROPPED rather than coerced:
    boot-check.log is decades of `gh auth status` output with a df line in it,
    and a series that guesses at a malformed reading is worse than a shorter
    one. The stamp is whatever the boot gate wrote — `date -Is`, offset and
    all — and is not re-normalised here for the same reason the probe does not
    re-normalise it.
    """
    out = []
    for point in raw.split(","):
        stamp, sep, pct = point.rpartition("@")
        if not sep or not stamp or not pct.isdigit():
            continue
        out.append({"ts": stamp, "pct": int(pct)})
    return out


def parse_vitals(record):
    """One box vitals record -> the dict the page renders (#483 D1).

    The line arrives from probe.sh verbatim; nothing is measured here and
    nothing is re-derived. `crew status` greps the same record out of the same
    file by the same rule, so the two readers are quoting one emission rather
    than agreeing by convention.

    Values are carried as the STRINGS the record spelled them with, not
    coerced to numbers. The probe measured them and this is a transport; a
    reader that re-formats `load1=0.00` into `0.0` has introduced a way for
    two consoles to print different things about one measurement. The one
    exception is the disk series' percentage, which the page draws as a trend
    and cannot draw from text.

    D6 travels with the record: a field the box could not read is absent from
    the line and therefore absent from this dict. Callers must ask with `.get`
    and render nothing — never a zero nobody measured.

    Returns None for an empty, absent or unrecognised record, which is every
    box running an engine older than the probe.
    """
    m = RE_VITALS.match((record or "").strip())
    if not m:
        return None
    fields, findings, series = {}, [], []
    for token in m.group(1).split():
        key, sep, val = token.partition("=")
        # A bare token is not a field. `finding=` with nothing after it is not
        # a finding either — an empty value is the shape of a field the box
        # could not read, and D6 says that is an ABSENCE.
        if not sep or not val:
            continue
        if key == "finding":
            findings.append(_vitals_finding(val))
        elif key == "disk_series":
            series = _vitals_series(val)
        else:
            fields[key] = val
    return {"ts": fields.pop("ts", ""), "fields": fields,
            "series": series, "findings": findings}


def spark_24h(sessions, now):
    """22 buckets of session activity, matching the console's sparkline."""
    buckets = [0.0] * 22
    span = 24 * 3600.0
    for s in sessions:
        age = now - s["ts"]
        if 0 <= age < span:
            idx = 21 - int(age / span * 22)
            buckets[min(21, max(0, idx))] += 1
    peak = max(buckets) or 1.0
    return [round(0.06 + 0.94 * (b / peak), 3) for b in buckets]


def unit_defaults():
    """Every key a unit record carries, at its "nothing known yet" value.

    ONE definition, because there are two producers — build_unit below and the
    poller's probe-error path — and they used to spell the same dict out by
    hand. They drifted the moment a key was added: the error path shipped
    without `disarmed`, so a single box that threw during its probe made
    `wake-silent` raise KeyError for the WHOLE fleet, and the poll log with it.
    (It was also already missing `agent_actual`.)

    A hand-copied second skeleton is the same defect this PR is about — two
    readers holding private copies of one fact — one layer down. Adding the
    missing key would have fixed today's instance and left the next one.
    """
    return {
        "state": "offline", "engine": "", "integrity": "", "gh": "unknown", "vendor": "unknown",
        "queue": [], "sessions": [], "cur": None, "spark": [0.0] * 22,
        "up": {"h": 0, "m": 0}, "repo": "", "repos": [], "logs": [],
        "longest": 0, "avg": 0, "success": 0, "today": 0,
        "paused": False, "disarmed": False,
        "cron": {"ok": False, "last": None, "age": None},
        # Signed host-minus-box delta and its conservative sampling uncertainty,
        # in seconds. None means the probe did not return a usable box clock.
        "clock_delta": None,
        "clock_uncertainty": None,
        # `ceiling` is the in-flight session's own declared timeout and `bound`
        # the number `held` was actually compared against — ceiling plus the
        # kill grace, or STUCK_AFTER_S where no session declared one (#610).
        # Served, not merely used: the page names the bound it was judged
        # against, because an age alone cannot distinguish a wedge from a
        # threshold somebody raised.
        "lock": {"held": None, "stuck": False, "ceiling": None, "bound": None},
        "suppression": {"active": False, "age": None, "kind": "", "key": ""},
        "floor_events": [],
        "limit_dropped": None,
        "authfail": [], "ping": None,
        "note": "", "agent_actual": "",
        # WHERE the record came from (#758): "live" once a probe answered,
        # "stored" when the box did not answer and the host's store had a
        # reading, "" when neither. A stored unit also carries `stored_at`
        # (the last ok pull) and `cost_24h`; a live one carries neither, so
        # a reader cannot mistake an old reading for a fresh one.
        "source": "",
        # The box vitals record (#483), or None where the log carries none —
        # a box on an engine older than the probe, and every box for the first
        # tick after it lands. None and not an empty dict, for the reason
        # every other absence on this record is spelled the way it is: a
        # renderer must be able to tell "no record" from "a record that
        # measured nothing", and `{}` collapses them.
        "vitals": None,
        "tick_health": None,
        # HIRED — "yes" / "no" / "unknown", and never an inference from the
        # engine string. The page draws a console for what is DEPLOYED rather
        # than for what the roster DECLARES (#204), and that filter needs a
        # positive fact to fire on: `engine == ""` is true of a box that was
        # never created, a box that is down, a box that did not answer, and a
        # box that answered and has no engine — four different situations with
        # two different answers. Inferring the filter from silence is the #308
        # defect one reader over, so the collector — which already ranks those
        # four apart with its own early returns — publishes the verdict and the
        # page never re-derives it.
        #
        # "unknown" is the default because the two producers that never reach a
        # probe (a stopped box, and build_unit's exception path in the poller)
        # must land on the answer that KEEPS the console: a box whose hired
        # state cannot be measured is exactly the hired-and-gone-dark box this
        # page exists to show.
        "hired": "unknown",
    }


def _overlay_stored(u, store, now):
    """A box that did not answer, read from the store (#758).

    Only ADDS: the state and the note the early returns decided stay as they
    are — a stopped box is still "stopped — crew up starts it", an unreachable
    one still says why — and the record gains what the host remembers: the
    sessions, queue, spark and counts the same derivations produce over the
    stored lines, `source: "stored"` and `stored_at` so no reader takes the
    reading for live, and the 24h cost. Nothing stored: the unit is exactly
    what it was.
    """
    try:
        stored = store.stored_unit(u["box"], now)
    except Exception as e:                                  # noqa: BLE001
        u["note"] = "%s · store unreadable: %s" % (u["note"], e) if u["note"] else str(e)
        return u
    if stored:
        u.update(stored)
    return u


def build_unit(unit, state, agent_conf, now, inventory_ok=True, store=None):
    """Roster entry + live probe -> the record the page renders.

    `inventory_ok` is whether `box list` ANSWERED. It matters only where state
    is None, which that one call is the sole evidence for: a failed listing
    makes every box look absent, and #204's grid filter would then read a
    broken inventory as a fleet nobody ever hired and draw an empty floor.
    Absence has to be measured before it can hide anything.

    `store` is the host's store module (floor.store), or None for a caller
    that only wants the parse (#758). With it, every probe runs in full mode
    and its record is ingested after the parse, a probe that fails records a
    failed pull, and a box that cannot be asked — stopped, unreachable — is
    served from what the store holds, marked `source: "stored"`.
    """
    u = dict(unit)
    u.update(unit_defaults())

    if state is None:
        if not inventory_ok:
            # `box list` could not be asked, so this box's absence is silence
            # rather than evidence, and `hired` stays "unknown" — the console
            # is kept and says why. Hiding here would be the exact inference
            # the verdict exists to refuse, on the one signal whose job is
            # noticing that something stopped answering.
            u["note"] = "box inventory unreadable — cannot tell what exists"
            return u
        # No box exists, so nothing was ever hired into it. This is a MEASURED
        # "no", not a fallback: `box list` answered and this name was not in it.
        u["hired"] = "no"
        u["note"] = "not created — crew new %s" % unit["box"]
        return u
    if state == "stopped":
        # Keeps "unknown": the box exists and nobody can ask it anything while
        # it is down. Hiring is not undone by `crew down`.
        u["note"] = "stopped — crew up starts it"
        if store is not None:
            try:
                store.note_state(unit["box"], "stopped")
            except Exception:                               # noqa: BLE001
                pass
            return _overlay_stored(u, store, now)
        return u

    # Bracket this box's own probe. The fleet's batch timestamp predates an
    # unbounded queue/transport delay and therefore cannot measure clock skew.
    # `::now` is sampled somewhere inside this interval; its distance from the
    # midpoint is bounded by half the interval, plus its one-second precision.
    probe_env = None
    if store is not None:
        try:
            probe_env = store.probe_env(unit["box"])
        except Exception:                                   # noqa: BLE001
            probe_env = {"PROBE_FULL": "1"}
    probe_started = time.time()
    # The two-argument call is kept for a caller without a store: the suites
    # stand a `lambda unit, agent_conf` in for probe_box, and a keyword they
    # never knew is a TypeError on every one of them.
    raw, err = (probe_box(unit, agent_conf, env=probe_env) if probe_env
                else probe_box(unit, agent_conf))
    probe_finished = time.time()
    if raw is None:
        # Also "unknown", and this is the one that matters most: a box that
        # stopped answering is the hired-and-gone-dark case, and dropping its
        # console would hide the failure the floor is for.
        u["note"] = "unreachable: %s" % err
        if store is not None:
            # A failed probe is a failed pull, and the rows already stored
            # stay exactly where they are: that is the reading served below.
            try:
                store.failed_pull(unit["box"], "unreachable: %s" % err, "unreachable")
            except Exception:                               # noqa: BLE001
                pass
            return _overlay_stored(u, store, now)
        return u

    meta, loglines = parse_probe(raw)
    u["source"] = "live"
    if store is not None:
        # Landed BEFORE the parse decides anything, in one transaction per
        # box; a record the exec cut off is refused there and reported here.
        try:
            res = store.ingest_record(unit["box"], raw, unit.get("agent"), unit.get("room"))
            if not res["ok"]:
                u["note"] = "store: pull failed — %s" % res["note"]
        except Exception as e:                              # noqa: BLE001
            u["note"] = "store: %s" % e
    u["engine"] = meta.get("engine", "")
    # The engine stamp's provenance, in #159's vocabulary: current, modified,
    # unverified, absent. Carried, never re-derived and never smoothed — the box
    # holds the files, so the box is the only thing that can hash them, and a
    # collector that turned an answer it did not like into a friendlier one
    # would be the "consistent, wrong data" failure described further down.
    # Empty means the box did not answer: an engine too old to ship the tool
    # still answers `unverified` (probe.sh's fallback), so "" is a probe that
    # could not run at all, and the page renders nothing rather than a verdict.
    u["integrity"] = meta.get("integrity", "")
    u["gh"] = meta.get("gh", "unknown")
    u["vendor"] = meta.get("vendor", "unknown")
    u["paused"] = meta.get("paused", "0") != "0"
    # DISARMED — no live `tick.sh` line in the crontab at all, which is a
    # different fact from "armed and not ticking" and needs a different action.
    # probe.sh has always emitted ::cron; nothing consumed it except a note on
    # the one path where a box has no log history whatsoever, so a box with
    # ticks behind it and cron since removed fell straight through to SILENT.
    #
    # `paused` is the same fact with a cause attached — the console's own Pause
    # comments the line out — so a paused box is BOTH, and `paused` wins the
    # note because "the operator did this, here is how to undo it" is the more
    # useful sentence. Kept as separate wire values rather than one tri-state:
    # a caller that means "can this box tick at all" must not have to know that
    # `paused` implies `disarmed`.
    u["disarmed"] = meta.get("cron", "0") == "0"
    # Both services, same shape. gh and the agent CLI fail independently and
    # are fixed by different commands, so they are never merged into one
    # "auth is bad" flag — the operator needs to know WHICH login to redo.
    # `nofail` means the box found no rejection; whether that amounts to
    # `flowing` depends on the engine having actually RUN recently, and that
    # threshold is SILENT_AFTER_S — the same one the SILENT rule uses, derived
    # once from TICK_S. The box deliberately ships ::tickage rather than a
    # verdict so this number exists in exactly one place.
    try:
        tick_age = int(meta.get("tickage") or -1)
    except (TypeError, ValueError):
        tick_age = -1
    fresh = 0 <= tick_age < SILENT_AFTER_S
    # WAITING — no tick has ever been observed, so there is no age to compare
    # against any threshold. `stale` is the wrong word here and it is wrong in
    # a costly direction: it means "we used to hear from this box and no longer
    # do", which is why the page renders it amber `~`. A box hired sixty seconds
    # ago has not stopped ticking; nobody has heard from it AT ALL. Telling an
    # operator their minute-old hire is stale, on a row whose every other column
    # says it is fine, is the same conflation #221 and #224 fix at the two
    # neighbouring call sites (#265).
    #
    # Not `unknown`: that value is reserved for a box with no engine, and
    # rehearsal-app.sh asserts no HIRED box ever reports it, on the grounds that
    # it leaves the operator nothing to act on. A never-ticked box is actionable
    # — the action is to wait one tick boundary — so it gets its own word.
    never_ticked = tick_age < 0
    for svc in ("gh", "vendor"):
        fail = meta.get("authfail-%s" % svc, "")
        if fail:
            u["authfail"].append("%s: %s" % (svc, fail))
        if u[svc] == "nofail":
            if never_ticked:
                u[svc] = "waiting"
            else:
                u[svc] = "flowing" if fresh else "stale"

    # A duty run is in flight and has held the lock this long. Absent means no
    # run is in flight — the common case between ticks, and not a fault.
    #
    # Only READ here. The verdict is decided below, once the log has been
    # parsed: what the age has to be measured against is the ceiling of the
    # session actually running, and nothing knows that until `derive_sessions`
    # has run (#610).
    try:
        held = int(meta["lockheld"])
    except (KeyError, ValueError, TypeError):
        held = None
    suppression = meta.get("suppression", "").split()
    if len(suppression) == 3:
        try:
            suppression_age = int(suppression[0])
        except ValueError:
            suppression_age = -1
        if suppression_age >= 0:
            u["suppression"] = {
                "active": True, "age": suppression_age,
                "kind": suppression[1], "key": suppression[2],
            }
    try:
        u["limit_dropped"] = max(0, int(meta["limitdropped"]))
    except (KeyError, TypeError, ValueError):
        u["limit_dropped"] = None
    for raw_event in meta.get("limit-events", []):
        fields = raw_event.split("\t", 7)
        if len(fields) != 8:
            continue
        event_id, timestamp, severity, name, measured, limit, subject, cause = fields
        if (not re.fullmatch(r"\d+-\d+-\d+", event_id)
                or not parse_ts(timestamp)
                or severity not in ("warn", "error")
                or not name or not measured.isdigit() or not limit.isdigit()
                or not subject or not cause):
            continue
        u["floor_events"].append({
            "id": event_id, "timestamp": timestamp, "severity": severity,
            "name": name, "measured": int(measured), "limit": int(limit),
            "subject": subject, "cause": cause,
        })
    u["repos"] = [r for r in meta.get("repos", "").split() if r]
    u["logs"] = [f for f in meta.get("sessionlogs", "").split() if f]
    try:
        up = int(meta.get("uptime") or 0)
        u["up"] = {"h": up // 3600, "m": (up % 3600) // 60}
    except ValueError:
        pass

    # The box ANSWERED — every "cannot tell" path returned above — so its
    # engine stamp is now evidence rather than silence, and this is the only
    # place the empty string is allowed to mean "not hired".
    u["hired"] = "yes" if u["engine"] else "no"
    if not u["engine"]:
        u["note"] = "not hired — crew hire %s" % unit["box"]

    # The roster DECLARES an agent; the box knows what it actually is. Those are
    # two different facts and were never compared, so a roster that named the
    # wrong agent made this page probe with the wrong vendor profile and report
    # the box auth-unhealthy — while every cross-reader assertion stayed green,
    # because `crew status` reads the same wrong column. Consistent, wrong data
    # is worse than an obvious error, and it is what let a generated drill
    # roster pin every box to "claude" without anything noticing.
    #
    # Ranked below "not hired" (no engine means no instance.conf to disagree
    # with) and above cron/paused/SILENT: a wrong profile invalidates the vendor
    # reading itself, so it is the thing to say first.
    u["agent_actual"] = meta.get("agent", "")
    if u["agent_actual"] and u["agent_actual"] != unit.get("agent"):
        u["note"] = u["note"] or (
            "roster says %s, box is installed as %s — the vendor probe is running "
            "the wrong profile" % (unit.get("agent"), u["agent_actual"]))

    # Cron liveness: probe.sh computes tick_age inside the box, where both
    # operands use the same clock. Log timestamps are still useful for ordering,
    # but must be translated onto the host timeline before the page ages them.
    last_ts = 0.0
    for line in reversed(loglines):
        m = RE_ANY_TS.match(line)
        if m:
            last_ts = parse_ts(m.group(1))
            break
    if last_ts and tick_age >= 0:
        u["cron"] = {
            "ok": tick_age < SILENT_AFTER_S and not u["paused"],
            "last": datetime.fromtimestamp(now - tick_age, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "age": tick_age,
        }
    elif meta.get("cron", "0") == "0":
        u["note"] = u["note"] or "no cron armed — crew hire %s" % unit["box"]

    # Session timestamps can still be translated from the tick-age evidence
    # when the box clock is missing or the wall-clock bracket is unusable. In
    # particular, a host clock step can reverse the bracket; its midpoint is
    # then not a bound on the guest sample and must never be published as skew
    # evidence.
    clock_offset = (now - (last_ts + tick_age)) if last_ts and tick_age >= 0 else 0
    guest_now = parse_ts(meta.get("now", ""))
    if guest_now and probe_finished >= probe_started:
        probe_midpoint = (probe_started + probe_finished) / 2
        clock_offset = probe_midpoint - guest_now
        u["clock_delta"] = round(clock_offset)
        u["clock_uncertainty"] = max(
            1, math.ceil((probe_finished - probe_started) / 2 + 1)
        )
    sessions, cur = derive_sessions(
        loglines, now, clock_offset,
        set(u["logs"]) if "sessionlogs" in meta else None,
    )
    limited = derive_limited(loglines, u["floor_events"], now, clock_offset,
                             unit.get("room", "engine"))
    if limited is not None:
        # Deliberately absent, rather than false, where no current evidence
        # exists or the box predates these records.
        u["limited"] = limited
    u["queue"] = derive_queue(loglines)
    # Not measured here and not measured by probe.sh either — the tick
    # measured it, both readers quote it (#483 D1). None on a box whose engine
    # predates the probe, and the page then draws no section rather than a
    # hardware reading nobody took.
    u["vitals"] = parse_vitals(meta.get("vitals", ""))
    u["tick_health"] = parse_tick_health(meta.get("tick-health", []))
    u["cur"] = cur
    # Both facts are in hand at last: the lock's age off the probe, and the
    # ceiling of the session holding it off duty.log. One function decides
    # (#610), and `stuck_note` is carried to the state ladder below rather
    # than written there, so the ping tier publishes the identical sentence.
    u["lock"], stuck_note = stuck_verdict(held, cur)
    u["sessions"] = [{k: s[k] for k in
                      ("ago", "kind", "key", "rc", "dur", "out", "acted", "reply", "peak",
                       "log", "log_unavailable")}
                     for s in sessions[:11]]
    u["spark"] = spark_24h(sessions, now)
    repo_fallback = ("crew" if u["queue"]
                     else (u["repos"][0] if u["repos"] else ""))
    u["repo"] = next((item["repo"] for item in u["queue"] if item["repo"]),
                     repo_fallback)

    if sessions:
        durs = [s["dur"] for s in sessions if s["dur"] is not None]
        ok = sum(1 for s in sessions if s["rc"] == 0)
        u["longest"] = max(durs) if durs else 0
        u["avg"] = round(sum(durs) / len(durs)) if durs else 0
        u["success"] = round(100 * ok / len(sessions))
        u["today"] = sum(1 for s in sessions if now - s["ts"] < 86400)

    # The state the floor colours by. Order matters: a paused or silent box is
    # reported SILENT even if a stale session line suggests work, because the
    # thing that would have ended that session is exactly what is not running.
    if u["paused"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "paused by operator — resume from the console"
    elif u["disarmed"]:
        # Disarmed OUTSIDE the console: `crew hire` before it arms, a box
        # disarmed by hand, and every drill box by design (drill/rehearsal.sh
        # disarms before any tick and aborts the run if it cannot). Ranked above
        # SILENT because it is the more specific claim and the actionable one:
        # SILENT says "this box should be ticking and is not", which is a real
        # alarm, and it must not be spent on a box nobody armed. Resume cannot
        # fix this — there is no commented line to uncomment — so the note names
        # the command that can.
        u["state"] = "offline"
        u["note"] = u["note"] or "disarmed — no cron line; crew hire %s arms it" % unit["box"]
    elif last_ts and u["cron"]["age"] is None:
        u["state"] = "offline"
        u["note"] = u["note"] or "tick age unknown — waiting for a valid probe"
    elif last_ts and not u["cron"]["ok"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "SILENT — no tick for %s" % fmt_dur(u["cron"]["age"])
    elif u["authfail"]:
        # Ticking, answering, and unable to do any work — the engine tried and
        # was rejected. Not "offline": the box is fine and every control still
        # works, which is exactly why this needs saying out loud rather than
        # being inferred from a queue that quietly stopped moving.
        u["state"] = "idle"
        u["note"] = "AUTH BLOCKED — %s" % "; ".join(u["authfail"])
    elif u["lock"]["stuck"]:
        # Still "working": the box is alive, cron is ticking, and a session
        # genuinely is running — every one of those is true and none of them is
        # the point. The note OVERRIDES rather than defers, because a run stuck
        # past the bound it was entitled to is the most important thing about
        # this box, and the notes it would defer to describe a healthy one.
        u["state"] = "working"
        u["note"] = stuck_note
    elif limited:
        u["state"] = "idle"
        u["note"] = "LIMITED — %s lane, %s for %s" % (
            limited["lane"], limited["reason"], fmt_dur(limited["age"])
        )
        if limited.get("reset"):
            u["note"] += " — %s" % limited["reset"]
    elif cur:
        u["state"] = "working"
    elif u["suppression"]["active"]:
        subject = u["suppression"]["key"].rsplit("@", 1)[0]
        u["state"] = "suppressed"
        u["note"] = "for %s — %s resume breaker at %s" % (
            fmt_dur(u["suppression"]["age"]),
            u["suppression"]["kind"], subject,
        )
    else:
        u["state"] = "idle"

    return u


def fmt_dur(s):
    if s is None:
        return "—"
    h, m = s // 3600, (s % 3600) // 60
    return "%dh %02dm" % (h, m) if h else ("%dm" % m if m else "%ds" % s)
