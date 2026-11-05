#!/usr/bin/env python3
"""Regression for #44: one slow box must not serialize a fleet-wide action."""

import itertools
import os
import sys
import threading
import time


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
# The module UNDER TEST, not the package: do_command reads `run`, `read_roster`
# and `box_states` as its own globals, so the stubs below have to land there.
# Rebinding them on the package would leave the real ones in place and this
# regression would drive a real `box` (#508).
from floor import actions as floor            # noqa: E402  (sys.path first)
from floor import ping                        # noqa: E402  (log lives here)
REAL_LOG = ping.log
floor.log = lambda _message: None

BOXES = ["box-a", "box-b", "box-c"]


class Fleet:
    def __init__(self):
        self.refreshes = 0

    def get(self):
        # Offline and ARMED — the silent box wake-silent exists to act on.
        # Both flags are spelled out because do_command reads them to decide
        # whether a box can be woken at all: a disarmed box has no commented
        # crontab line to restore, and is skipped (#189).
        return {"units": [{"box": name, "state": "offline",
                           "paused": False, "disarmed": False}
                          for name in BOXES]}

    def request_refresh(self):
        self.refreshes += 1


def exercise(action, states, failures=()):
    active = 0
    peak = 0
    lock = threading.Lock()

    floor.read_roster = lambda: [
        {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
    ]
    if isinstance(states, str):
        states = {name: states for name in BOXES}
    floor.box_states = lambda: states

    def slow_run(argv, _timeout, _stdin_data=None):
        nonlocal active, peak
        name = argv[2]
        with lock:
            active += 1
            peak = max(peak, active)
        # Finish in reverse roster order. The API must still report roster order.
        time.sleep({"box-a": 0.15, "box-b": 0.10, "box-c": 0.05}[name])
        with lock:
            active -= 1
        if name in failures:
            return 1, "", "fixture failure"
        return 0, "ok", ""

    floor.run = slow_run
    fleet = Fleet()
    status, payload = floor.do_command(fleet, {"action": action})

    # A not-created box (state None) is inventory drift, excluded from the
    # verdict — only a box that was there and refused makes the action 500 (#77).
    expected_status = 500 if failures else 200
    assert status == expected_status, (action, status, payload)
    assert peak == len(BOXES), (action, "peak concurrency", peak)
    assert [result["box"] for result in payload["results"]] == BOXES, payload
    # `is False` (a refusal), not falsy — an absent box carries `ok:None` and
    # must not be counted a failure here, matching the strict client filter.
    assert [
        result["box"] for result in payload["results"] if result["ok"] is False
    ] == list(failures), payload
    assert fleet.refreshes == 1, (action, "refreshes", fleet.refreshes)


exercise("start-all", "stopped")
exercise("stop-all", "running", failures=("box-b",))
exercise("wake-silent", "running")


# Precomputed and real results share one ordered list. Only box-c needs work,
# while box-a is absent and box-b is already running. Nothing refused, so the
# absent box does not make the action fail: 200, box-a carries ok:None (#77).
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
]
floor.box_states = lambda: {"box-a": None, "box-b": "running", "box-c": "stopped"}
floor.run = lambda _argv, _timeout, _stdin_data=None: (0, "started", "")
mixed_fleet = Fleet()
status, payload = floor.do_command(mixed_fleet, {"action": "start-all"})
assert status == 200, (status, payload)
assert [result["box"] for result in payload["results"]] == BOXES, payload
assert [result["ok"] for result in payload["results"]] == [None, True, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "already running", "started"
], payload


# An absent box must not MASK a real refusal: box-a is not created, box-b was
# there and refused, box-c started. The action is 500 (a box refused), box-a
# still travels as ok:None and box-b as the named failure (#77).
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
]
floor.box_states = lambda: {"box-a": None, "box-b": "stopped", "box-c": "stopped"}
floor.run = lambda argv, _timeout, _stdin_data=None: (
    (1, "", "refused") if argv[2] == "box-b" else (0, "started", "")
)
drift_and_refusal = Fleet()
status, payload = floor.do_command(drift_and_refusal, {"action": "start-all"})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == BOXES, payload
assert [result["ok"] for result in payload["results"]] == [None, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "refused", "started"
], payload


# A growing roster must not create one host subprocess per member. Results
# remain in roster order even though only eight calls may run at once.
MANY_BOXES = ["box-%02d" % n for n in range(19)]
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in MANY_BOXES
]
floor.box_states = lambda: {name: "stopped" for name in MANY_BOXES}
many_active = 0
many_peak = 0
many_lock = threading.Lock()


def bounded_run(argv, _timeout, _stdin_data=None):
    global many_active, many_peak
    with many_lock:
        many_active += 1
        many_peak = max(many_peak, many_active)
    time.sleep(0.03)
    with many_lock:
        many_active -= 1
    return 0, argv[2], ""


floor.run = bounded_run
many_fleet = Fleet()
status, payload = floor.do_command(many_fleet, {"action": "start-all"})
assert status == 200, (status, payload)
assert many_peak == floor.ACTION_WORKERS == 8, ("action worker peak", many_peak)
assert [result["box"] for result in payload["results"]] == MANY_BOXES, payload

# --- #44's actual scenario: a wedged box must not cost the fleet N timeouts --
#
# #68 made the per-box work concurrent and the fixture above proves the
# concurrency — but every stub up to here DISCARDS the timeout it is handed,
# so nothing asserted the property #44 was filed about: a box that never
# answers is capped at ACTION_TIMEOUT_S, and its healthy siblings return on
# time regardless. On incus 6.0.4 the hang is the COMMON case, not the rare
# one — danmt's real-host probe measured rc=124 after the full 150s, refuting
# "a dead agent makes box exec fail fast".
#
# What is under test is that the FAN-OUT preserves the per-box cap, not that
# subprocess honours timeouts. So the stub simulates run()'s timeout contract
# — sleep to the deadline, then (124, "", "timed out after Ns") — and the real
# run() is not involved. Injecting a small ACTION_TIMEOUT_S keeps it fast:
# one() binds its default from the module global each time do_command runs, so
# setting it here is what the fan-out actually uses.
TIMEOUT_S = 0.3
REAL_ACTION_TIMEOUT_S = floor.ACTION_TIMEOUT_S
floor.ACTION_TIMEOUT_S = TIMEOUT_S

seen_timeouts = []
wedged_boxes = set()


def wedging_run(argv, timeout, _stdin_data=None):
    seen_timeouts.append(timeout)
    name = argv[2]
    if name in wedged_boxes:
        # Sleep the INJECTED deadline, never the one passed in. If the cap
        # regresses, `timeout` is the fleet's real 120s and sleeping it would
        # HANG this suite instead of failing it — and a hanging test is worse
        # than a failing one: it burns the job's whole timeout and reports
        # nothing useful. Measured while writing this, on the exact regression
        # below (one() defaulted to 999): sleeping the passed timeout hung past
        # two minutes; sleeping the injected one fails in 0.3s, on the `out`
        # text, before the seen_timeouts assertion is even reached.
        time.sleep(TIMEOUT_S)               # it never answers
        return 124, "", "timed out after %ss" % timeout
    return 0, "started", ""


def timed_action(boxes, wedged, states):
    """Run start-all over `boxes` with `wedged` hung, returning (elapsed, payload)."""
    global wedged_boxes
    wedged_boxes = set(wedged)
    del seen_timeouts[:]
    floor.read_roster = lambda: [
        {"box": name, "agent": "claude", "room": "builder"} for name in boxes
    ]
    floor.box_states = lambda: states
    floor.run = wedging_run
    started = time.monotonic()
    status, payload = floor.do_command(Fleet(), {"action": "start-all"})
    return time.monotonic() - started, status, payload


# The whole roster wedged — the #44 shape exactly. Serialized this costs
# len(BOXES) timeouts; concurrent it costs one. The roster is sized to
# ACTION_WORKERS so the bound also pins the POOL: a max_workers lowered below
# the roster puts a wedged box in a later batch and the action is back to
# N/pool timeouts, which is regression path 1 in #79 and leaves every other
# assertion in this file green.
ALL_WEDGED = ["wedge-%d" % n for n in range(floor.ACTION_WORKERS)]
elapsed, status, payload = timed_action(
    ALL_WEDGED, ALL_WEDGED, {name: "stopped" for name in ALL_WEDGED})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == ALL_WEDGED, payload
assert all(result["ok"] is False for result in payload["results"]), payload
assert all(
    result["out"] == "timed out after %ss" % TIMEOUT_S
    for result in payload["results"]
), payload
# Generously bounded: serialized would be 8 x 0.3 = 2.4s, so 3x one timeout
# discriminates by a factor of 2.6 while tolerating a slow, loaded runner.
assert elapsed < TIMEOUT_S * 3, ("wedged fleet paid more than one timeout", elapsed)

# One wedged box among healthy ones: the timeout is attributed to THAT box and
# the others still carry their real results.
MIXED = ["fast-a", "hung-b", "fast-c"]
elapsed, status, payload = timed_action(
    MIXED, ["hung-b"], {name: "stopped" for name in MIXED})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == MIXED, payload
assert [result["ok"] for result in payload["results"]] == [True, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "started", "timed out after %ss" % TIMEOUT_S, "started"
], payload
assert elapsed < TIMEOUT_S * 3, ("one wedged box serialized the fleet", elapsed)

# Every call got the fleet's cap. This is regression path 2 in #79: someone
# changes one()'s default, or a future caller passes a per-action timeout, and
# the cap silently stops applying to the fan-out — with every assertion above
# still green, because they only observe the CONTRACT the stub honours.
assert set(seen_timeouts) == {TIMEOUT_S}, ("uncapped call", seen_timeouts)

# The mixed done/one path WITH concurrency in play — precomputed results and
# real work in one ordered list, one of the real ones wedged. It was exercised
# once above with an instant stub, so the interleaving was covered for ordering
# and never with a box that does not answer.
DRIFT = ["absent-a", "running-b", "hung-c", "fast-d"]
elapsed, status, payload = timed_action(
    DRIFT, ["hung-c"],
    {"absent-a": None, "running-b": "running", "hung-c": "stopped", "fast-d": "stopped"})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == DRIFT, payload
assert [result["ok"] for result in payload["results"]] == [None, True, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "already running", "timed out after %ss" % TIMEOUT_S, "started"
], payload
assert elapsed < TIMEOUT_S * 3, ("precomputed results serialized behind a hang", elapsed)

floor.ACTION_TIMEOUT_S = REAL_ACTION_TIMEOUT_S


# --- #487: a lever that could not act must not report that it did ------------
#
# Driven here as well as through the HTTP suite because the fixture fleet
# reaches only ONE of restart's two stop paths with a failure: stub-box's
# `incus <box> -- stop --force` answers, so a FAILED force stop has no fixture
# at all, and the graceful half needs a box the ping tier has not measured to
# take the gentle verdict (floor/actions.sh drives exactly that, against #486's
# hanging `down` arm). What is under test is the same on both paths and is a
# property of the CODE rather than of any host: the start is conditioned on the
# stop's own result, and on neither path is it conditioned on anything else.
class RestartFleet(Fleet):
    """A fleet whose wedge verdict is fixed, so the path under test is chosen."""

    def __init__(self, unreachable):
        Fleet.__init__(self)
        self.unreachable = unreachable

    def box_unreachable(self, _name):
        return self.unreachable


def restart(box, unreachable, mode, refuses=None, state="running"):
    """One restart. `refuses` is the argv fragment the host rejects, or None.

    Its `calls` are asserted in EXACT order, unlike wake-silent's (#604): one
    box's restart runs its verbs one after another on one thread, stop before
    start, and that sequence is the behaviour under test. Order there is the
    contract; across a fleet fan-out it is only scheduling.

    `state` is what `box list` says about the box, because the graceful path
    now reads it: `box down` is not idempotent, so a box already stopped is one
    the verb must not be fired at (round 1, claude-bot).
    """
    calls = []
    floor.read_roster = lambda: [{"box": box, "agent": "claude", "room": "builder"}]
    floor.box_states = lambda: ({} if state is None else {box: state})

    def recording_run(argv, _timeout, _stdin_data=None):
        line = " ".join(argv)
        calls.append(line)
        if refuses and refuses in line:
            # run()'s timeout contract, which is how a graceful stop fails
            # against a guest that cannot schedule its own shutdown.
            return 124, "", "timed out after 8s"
        return 0, "done", ""

    floor.run = recording_run
    status, payload = floor.do_command(
        RestartFleet(unreachable), {"action": "restart", "box": box, "mode": mode})
    return calls, status, payload


# The force path with the stop refused. Asserted on the CALL LIST and not on
# the reply: "it reported a failure" is equally true of a restart that failed,
# started the box anyway, and said so afterwards — which is the defect.
calls, status, payload = restart("wedge-a", True, "force", refuses="stop --force")
assert status == 500, (status, payload)
assert calls == ["box incus wedge-a -- stop --force"], calls
assert [r["step"] for r in payload["results"]] == ["force-stop", "start"], payload
assert [r["ok"] for r in payload["results"]] == [False, None], payload
assert payload["results"][1]["out"] == (
    "not started: the force-stop step failed"), payload
# AND NOTHING MORE THAN THAT. The row used to append "so the box was left as it
# was", a claim about the guest on the one path where the guest's state is what
# is unknown — a timed-out stop has asked for a shutdown that may be in flight
# (round 1, codex-bot and claude-bot). The equality above already excludes it
# here; this line NAMES it, so the rule survives an equality that is later
# loosened. Its load-bearing twin is in test/floor/actions.sh, where the
# matching assertion is a substring and the claim really can come back under it.
assert "left as it was" not in payload["results"][1]["out"], payload

# The same path with the stop accepted. Without this pair the assertion above
# is satisfied by a restart that has stopped starting boxes altogether.
calls, status, payload = restart("wedge-b", True, "force")
assert status == 200, (status, payload)
assert calls == ["box incus wedge-b -- stop --force", "box start wedge-b"], calls
assert [r["ok"] for r in payload["results"]] == [True, True], payload

# ...and both again on the graceful path, which is the one an operator meets on
# a box whose heartbeat is merely unmeasured.
calls, status, payload = restart("gentle-c", False, "graceful", refuses="box down")
assert status == 500, (status, payload)
assert calls == ["box down gentle-c"], calls
assert [r["step"] for r in payload["results"]] == ["down", "start"], payload
assert [r["ok"] for r in payload["results"]] == [False, None], payload
assert payload["results"][1]["out"] == (
    "not started: the down step failed"), payload
assert "left as it was" not in payload["results"][1]["out"], payload

calls, status, payload = restart("gentle-d", False, "graceful")
assert status == 200, (status, payload)
assert calls == ["box down gentle-d", "box start gentle-d"], calls

# NOTHING TO STOP IS NOT A FAILED STOP (round 1, claude-bot). `box down` is not
# idempotent on the single-box path — it is `incus stop <inst>` bare, and box's
# `stop:STOPPED -> ""` guard is reached only by `box down all` — so a restart
# against an already-stopped box got a non-zero stop, and the conditional above
# then swallowed the start that used to run. `ac-restart` is the one ACCESS
# control state does not dim, so this is reachable from a console that has just
# promised the operator "it is stopped and started again".
#
# The verb is not fired at a box already in the target state. `refuses` is set
# to the stop anyway, so this asserts the shortcut rather than a host that
# happened to be forgiving: if `box down` were fired here it would fail, and
# the start would vanish with it.
calls, status, payload = restart(
    "already-e", False, "graceful", refuses="box down", state="stopped")
assert status == 200, (status, payload)
assert calls == ["box start already-e"], calls
assert [r["step"] for r in payload["results"]] == ["down", "start"], payload
assert [r["ok"] for r in payload["results"]] == [True, True], payload
# Reported, not silently dropped: the reply still has both steps, and the stop
# row says which of the two things happened to it.
assert payload["results"][0]["out"] == "already stopped", payload

# The FORCE path does not acquire the shortcut. A stopped box has no published
# ping, so `box_unreachable()` is false and the force verdict is unreachable
# from a stopped box in production — but the two conditions are independent in
# the code, and a force stop that started skipping boxes on a stale `box list`
# would be #486's silent-escalation ruling failing open in the other direction.
calls, status, payload = restart("force-f", True, "force", state="stopped")
assert calls == ["box incus force-f -- stop --force", "box start force-f"], calls


# `wake-silent` against the state it was sending its wake into. All four boxes
# are silent and wakeable; they differ only in what the ping tier says about
# them, which is the whole of the routing under test.
class WakeFleet(Fleet):
    def __init__(self, units):
        Fleet.__init__(self)
        self.units = units

    def get(self):
        return {"units": self.units}


def silent(box, ping=None):
    return {"box": box, "state": "offline", "paused": False, "disarmed": False,
            "ping": ping}


WAKE_UNITS = [
    silent("wake-stopped"),
    # No heartbeat at all: unmeasured is not wedged, so it is still woken.
    silent("wake-unmeasured"),
    silent("wake-wedged", ping={"ok": False, "fails": 3, "wedged": True}),
    # Answering the ping and silent in the evidence tier — the ordinary wake.
    silent("wake-answering", ping={"ok": True, "fails": 0, "wedged": False}),
]
wake_calls = []


def wake_run(argv, _timeout, _stdin_data=None):
    wake_calls.append(" ".join(argv[:3]))
    return 0, "done", ""


floor.read_roster = lambda: [
    {"box": u["box"], "agent": "claude", "room": "builder"} for u in WAKE_UNITS
]
floor.box_states = lambda: {"wake-stopped": "stopped", "wake-unmeasured": "running",
                            "wake-wedged": "running", "wake-answering": "running"}
floor.run = wake_run
status, payload = floor.do_command(WakeFleet(WAKE_UNITS), {"action": "wake-silent"})
# The decisive one: nothing at all is fired at the wedged box. A reply that
# merely NAMES it is what the timed-out row already did.
assert not any("wake-wedged" in call for call in wake_calls), wake_calls
# The calls run on the action's threads, so they land in any order; the
# REPLY's order is the stable one, asserted below. The call log is judged by
# one rule no interleaving can change (#604): the decisive assertion above,
# kept standalone and untouched, and exactly one verb per woken box, the verb
# its state calls for.
WAKE_EXPECTED = ["box start wake-stopped", "box exec wake-unmeasured",
                 "box exec wake-answering"]


def wake_calls_ok(calls):
    return (not any("wake-wedged" in call for call in calls)
            and sorted(calls) == sorted(WAKE_EXPECTED))


assert wake_calls_ok(wake_calls), wake_calls
# Proved order-free by feeding it every order of the three calls, not by
# re-running and getting lucky; and still precise — each of these must fail.
for order in itertools.permutations(WAKE_EXPECTED):
    assert wake_calls_ok(list(order)), order
for wrong in (WAKE_EXPECTED + ["box exec wake-wedged"],
              ["box start wake-stopped", "box start wake-unmeasured", "box exec wake-answering"],
              ["box exec wake-stopped", "box exec wake-unmeasured", "box exec wake-answering"],
              WAKE_EXPECTED[:2]):
    assert not wake_calls_ok(wrong), wrong
assert [r["box"] for r in payload["results"]] == [u["box"] for u in WAKE_UNITS], payload
assert [r["step"] for r in payload["results"]] == [
    "start", "resume", "escalate", "resume"], payload
# A box it could not wake is a refusal, not drift: `ok: None` would report the
# whole action 200 with the incident in the detail nobody reads (#487 D4).
assert [r["ok"] for r in payload["results"]] == [True, True, False, True], payload
assert status == 500, (status, payload)
assert payload["results"][2]["out"].startswith("wedged — not woken"), payload

# A BOX THAT LEFT THE HOST WHILE WEDGED draws no row at all (round 1,
# claude-bot). `fleet.get()`'s units are a snapshot up to a poll old while
# `box_states()` is read fresh, so the wedge verdict outlives the box; an
# `escalate` row here would name a restart lever for a box there is nothing to
# restart, where before this PR the same box dropped out silently. Same units,
# same ping, and only the host's inventory differs.
gone_calls = []
floor.run = lambda argv, _t, _s=None: (gone_calls.append(" ".join(argv[:3])),
                                       (0, "done", ""))[1]
floor.box_states = lambda: {"wake-stopped": "stopped", "wake-unmeasured": "running",
                            "wake-answering": "running"}   # wake-wedged has gone
status, payload = floor.do_command(WakeFleet(WAKE_UNITS), {"action": "wake-silent"})
assert not any("wake-wedged" in call for call in gone_calls), gone_calls
assert [r["box"] for r in payload["results"]] == [
    "wake-stopped", "wake-unmeasured", "wake-answering"], payload
assert status == 200, (status, payload)

# log() is called by those workers. A deliberately slow stream makes
# overlapping writes deterministic: the old print(message, flush=True) path
# enters write concurrently and emits the newline as a second write.
class SlowStream:
    def __init__(self):
        self.active = 0
        self.peak = 0
        self.writes = []
        self.lock = threading.Lock()

    def write(self, text):
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
        time.sleep(0.003)
        self.writes.append(text)
        with self.lock:
            self.active -= 1

    def flush(self):
        return None


stream = SlowStream()
# ping's `sys`, because that is the module log() resolves the stream through.
real_stdout = ping.sys.stdout
ping.sys.stdout = stream
threads = [
    threading.Thread(target=REAL_LOG, args=("box-%02d complete" % n,))
    for n in range(24)
]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
ping.sys.stdout = real_stdout
assert stream.peak == 1, ("overlapping log writes", stream.peak)
assert len(stream.writes) == len(threads), ("torn log writes", stream.writes)
assert all(line.endswith(" complete\n") for line in stream.writes), stream.writes

# #766 — claims. A second action on a box one is already changing is refused
# 409 busy and fires nothing; a fleet action leaves a held box alone; the
# registry the page polls names the action and its step while it runs.
from floor.inflight import INFLIGHT  # noqa: E402
CLAIM_CALLS = []
CLAIM_GATE = threading.Event()


def gated_run(argv, _timeout, _stdin_data=None):
    CLAIM_CALLS.append(" ".join(argv[:3]))
    if argv[1] == "down" and argv[2] == "box-a":
        CLAIM_GATE.wait(5)
    return 0, "done", ""


floor.read_roster = lambda: [{"box": n, "agent": "claude", "room": "builder"} for n in BOXES]
floor.box_states = lambda: {n: "running" for n in BOXES}
floor.run = gated_run
# The host's pause marker is a file under the config dir — the shipped
# examples, here. Never written by a suite: kept in memory.
MARKERS = {}
floor._paused_marker = lambda name, on: MARKERS.__setitem__(name, on)
floor._paused_marker_set = lambda name: MARKERS.get(name, False)


class ClaimFleet(Fleet):
    def box_unreachable(self, _box):
        return False


cf = ClaimFleet()
first = {}
t1 = threading.Thread(target=lambda: first.update(
    r=floor.do_command(cf, {"action": "restart", "box": "box-a", "mode": "graceful"}, actor="op1")))
t1.start()
for _ in range(200):
    if INFLIGHT.snapshot()["boxes"].get("box-a", {}).get("step") == "down":
        break
    time.sleep(0.01)
snap = INFLIGHT.snapshot()
assert snap["boxes"]["box-a"]["action"] == "restart", snap
assert snap["boxes"]["box-a"]["step"] == "down", snap
assert snap["boxes"]["box-a"]["actor"] == "op1", snap
# The second operator's restart, and a power-off, on the held box: refused.
code, reply = floor.do_command(cf, {"action": "restart", "box": "box-a", "mode": "graceful"}, actor="op2")
assert code == 409 and reply["busy"] and reply["refused"], (code, reply)
assert "restart (down)" in reply["error"] and "by op1" in reply["error"], reply
code, reply = floor.do_command(cf, {"action": "power-off", "box": "box-a"}, actor="op2")
assert code == 409 and reply["busy"], (code, reply)
# Another box is not held by it.
code, reply = floor.do_command(cf, {"action": "pause", "box": "box-b"}, actor="op2")
assert code == 200, (code, reply)
# A fleet action meanwhile: it runs, and leaves the held box alone, named.
code, reply = floor.do_command(cf, {"action": "stop-all"}, actor="op2")
rows = {r["box"]: r for r in reply["results"]}
assert rows["box-a"]["ok"] is None and rows["box-a"]["step"] == "busy", rows
assert rows["box-b"]["ok"] and rows["box-c"]["ok"], rows
CLAIM_GATE.set()
t1.join(5)
assert first["r"][0] == 200, first
# Fired exactly once at box-a: the first restart's down and start, nothing else.
assert [c for c in CLAIM_CALLS if c.endswith("box-a")] == ["box down box-a", "box start box-a"], CLAIM_CALLS
assert INFLIGHT.snapshot() == {"boxes": {}, "fleet": None}, INFLIGHT.snapshot()

# Two fleet actions at once: the second is refused and fires nothing.
FLEET_GATE = threading.Event()
FLEET_CALLS = []


def fleet_gated(argv, _timeout, _stdin_data=None):
    FLEET_CALLS.append(" ".join(argv[:3]))
    FLEET_GATE.wait(5)
    return 0, "done", ""


floor.run = fleet_gated
floor.box_states = lambda: {n: "stopped" for n in BOXES}
held = {}
t2 = threading.Thread(target=lambda: held.update(r=floor.do_command(cf, {"action": "start-all"}, actor="op1")))
t2.start()
for _ in range(200):
    f = INFLIGHT.snapshot()
    if f["fleet"] and f["fleet"]["total"] == 3 and len(f["boxes"]) == 3:
        break
    time.sleep(0.01)
f = INFLIGHT.snapshot()["fleet"]
assert f["action"] == "start-all" and f["total"] == 3 and f["done"] == 0, f
code, reply = floor.do_command(cf, {"action": "stop-all"}, actor="op2")
assert code == 409 and reply["busy"] and "start-all" in reply["error"], (code, reply)
# A box the fleet action is on right now is held for it, too.
code, reply = floor.do_command(cf, {"action": "power-off", "box": "box-c"}, actor="op2")
assert code == 409, (code, reply)
FLEET_GATE.set()
t2.join(5)
assert held["r"][0] == 200, held
assert sorted(FLEET_CALLS) == ["box start box-a", "box start box-b", "box start box-c"], FLEET_CALLS
assert INFLIGHT.snapshot() == {"boxes": {}, "fleet": None}, INFLIGHT.snapshot()

# Round 11: wake-silent lifts a box's pause marker only inside that box's own
# claimed call — a box another action holds, and that it leaves alone, keeps
# its pause.
MARKERS.clear(); MARKERS.update({"box-a": True, "box-b": True})
floor.box_states = lambda: {n: "stopped" for n in BOXES}
WAKE_CALLS = []


def wake_run(argv, _t, _s=None):
    WAKE_CALLS.append(" ".join(argv[:3]) + (" " + argv[-1].strip().split("\n")[0] if argv[1] == "exec" else ""))
    return 0, "floor-ready" if argv[-1] == floor.READY_SH else "done", ""


floor.run = wake_run
ok_a, _ = INFLIGHT.claim_box("box-a", "pause", "op1")
assert ok_a
code, reply = floor.do_command(Fleet(), {"action": "wake-silent"}, actor="op2")
rows = {r["box"]: r for r in reply["results"]}
assert rows["box-a"]["step"] == "busy", rows
assert MARKERS["box-a"] is True, ("a held box lost its pause marker", MARKERS)
assert MARKERS["box-b"] is False, ("the woken box keeps its marker", MARKERS)
# Round 12: the paused, stopped box was started AND resumed — its crontab back
# on — and only then un-marked; the unpaused one was only started.
b_calls = [c for c in WAKE_CALLS if "box-b" in c]
assert b_calls[0] == "box start box-b" and any("echo floor-ready" in c for c in b_calls) \
    and any("crontab" in c for c in b_calls), WAKE_CALLS
assert [c for c in WAKE_CALLS if "box-c" in c] == ["box start box-c"], WAKE_CALLS
INFLIGHT.release_box("box-a")
# Round 13: a wake that could not resume the box puts its pause back — the
# marker was lifted first (so the host tick cannot stop the box mid-wake),
# and a box this action did not wake is paused again.
MARKERS.clear(); MARKERS.update({"box-b": True})
floor.run = lambda argv, _t, _s=None: ((1, "", "crontab write failed") if "crontab" in argv[-1]
                                       else (0, "floor-ready" if argv[-1] == floor.READY_SH else "done", ""))
code, reply = floor.do_command(Fleet(), {"action": "wake-silent"}, actor="op2")
rows = {r["box"]: r for r in reply["results"]}
assert rows["box-b"]["ok"] is False, rows
assert MARKERS["box-b"] is True, ("a box the wake could not resume lost its pause", MARKERS)
# ...and a message (which does not claim) never blanks a holder's step.
INFLIGHT.claim_box("box-c", "restart", "op1")
INFLIGHT.step("box-c", "down", "restart")
INFLIGHT.step("box-c", "", "message")
assert INFLIGHT.snapshot()["boxes"]["box-c"]["step"] == "down", INFLIGHT.snapshot()
INFLIGHT.release_box("box-c")

# Nothing above wrote into the shipped tree (round 11: a real pause marker
# once landed under examples/store/ and was committed).
assert not os.path.exists(os.path.join(os.path.dirname(HERE), "..", "examples", "store")), "a suite wrote into examples/"

print("concurrent fleet actions: ok")
