# Fleet Floor

A live-ops view of the `heavy-duty/crew` fleet. Two levels in one self-contained,
dependency-free `index.html` — no build tools, no network, no external assets:

- **God-view floor** — the fleet as a **conference call**: a vertically
  scrolling grid, one **webcam tile per box**. Each unit faces the camera in
  close-up over a static, defocused backdrop in its role's colour (builder /
  reviewer / triage), under an AR overlay of the facts an operator scans for:
  state, uptime, **idle time over the last 24h**, queue depth, signal, a
  **heartbeat trace** that flatlines with the box, the open session's timer and
  a live **caption** naming the work item being handled. Up top: live counts,
  **state/role filters**, and fleet **time metrics**; along the bottom:
  **active operations**, and a **fleet activity** stream. The portrait in each
  tile is a **deterministic still** — built once per (unit, state, size) at a
  per-unit canonical time, on a supersampled sprite pass so every vendor lands
  at the same effective resolution — animated at composite time by a sub-pixel
  bob in the sprite's own rhythm, with a rare **glitch grammar** (displaced
  slices, chroma splits, block smears) carrying the webcam fiction. Motion is
  continuous; lag is performed, never rendered by accident (#226).
- **Agent console** — click any unit to zoom into its full room. The robot is
  framed by an operator console: identity, vitals (box health, uptime, cron, repo),
  work queue, **access** links, a live **current-session** timer, **time metrics**,
  and **session history** — plus a message box and Pause / Restart / Power controls.

The four vendors render as distinct units — **claude** an armored humanoid,
**codex** a 6-legged spider, **grok** a floating astronaut, **kimi** a hovering
screen-face drone — each with idle / working / offline states.

## Run it

Two modes, and the page picks between them itself at load.

### LIVE — the real fleet, on `IP:PORT`

```sh
crew floor                       # → http://<host-ip>:8420/, prints the password
crew floor --port 9000 --user dan --pass hunter2
crew floor --local               # loopback only
```

Run it **on the box host**, over an **operator fleet definition**. It serves the
page and polls every roster box every 60s, and the badge turns green **LIVE**.

The grid draws what is **deployed**, not what is **declared** (#204). A roster
written ahead of provisioning is a full floor of boxes that do not exist, and a
never-hired console is indistinguishable at a glance from a hired box that has
gone dark — so a box that has not been created, or that answered and reported no
engine, is **counted but not drawn**, and the floor starts empty and fills as
boxes are hired. A **stopped** or **unreachable** box keeps its console: its
hired state cannot be measured while it is in that state, and the one that went
dark is what the page is for. The collector decides this and publishes it as
`hired: yes | no | unknown`; the page never infers it from an empty engine
string, which is true of all four situations and right about only two. Nothing
is filtered out of `/api/fleet`, so `crew status` and the drill's floor-vs-CLI
agreement check still see every roster member.
Because the page can power-cycle boxes and start sessions, HTTP Basic auth is
mandatory — without `--pass` one is generated and printed once at startup.

For the same reason the console refuses under the shipped `examples/` fallback
(#244): those buttons resume cron and start model sessions, so a definition
nobody wrote does not get one. `crew init` scaffolds one, `CREW_CONFIG_DIR`
selects it, and `crew status` inspects a host that has neither. `--roster`
selects a roster file rather than a fleet, so it does not lift the refusal.
Both doors are the same: `crew floor` and `python3 fleet-floor/server/floor.py`
refuse identically.

### DEMO — no host, no fleet

```sh
open fleet-floor/index.html      # or double-click it
```

Opened from disk there is no collector to talk to, so the page stays on the
placeholder fleet, badged **DEMO DATA**, with the operator actions shown but
disabled. This is what the prototype always was, and it still works with no
network and no dependencies.

`index.html` is committed pre-built. To regenerate it from `src/`:

```sh
fleet-floor/build.sh             # concatenates src/{style.css,body.html,app.js}
```

## How live mode works (#38 / #39)

Both issues proposed a box-initiated collector — the box POSTs telemetry and
long-polls for commands — because the boxes have **no inbound network path**.
That is true of the network and beside the point: the operator host already
holds a control channel into every box, **`box exec`**, which is how `crew
status`, `crew hire` and `crew upgrade` have always worked. So the direction is
inverted, and nothing runs box-side at all:

```
host  --box exec-->  box     read duty evidence      (#38 telemetry)
host  --box exec-->  box     fire operator action    (#39 control)
```

### Three tiers, not one poll

The evidence poll used to answer every health question at one cadence, and one
of them over the network. They are now separated by what they cost:

| tier | how | network | cadence |
|---|---|---|---|
| **ping** | `box exec <box> -- true` | none | 10s |
| **evidence** | `probe.sh` — duty.log, cron, uptime, repos, lock age | none | 60s |
| **credentials** | markers the duty engine writes | **none** | read with evidence |

**The ping is an exec, not a socket.** A listening port is answered by the
guest *kernel*, so it stays green through a userspace that can no longer fork;
an exec needs the incus agent, a fork, an exec and a disk read, and fails
exactly when the box is wedged. It runs on its own thread with its own lock —
sharing the poll lock would queue every ping behind a 45s probe and the fast
tier would run at the slow tier's cadence — and is overlaid onto the snapshot
at read time, so it is never served up to a minute stale. Three consecutive
misses declare a box unreachable; one dropped ping is scheduler noise.

**The wedge verdict is the collector's, and it is served.** `CREW_FLOOR_PING_FAILS`
moves that three, so anything that re-derives "unreachable" from the miss count
is holding a number the operator may have changed. `fleet.wedged()` decides it
once — the page paints `UNREACHABLE` from it, restart escalates to a force stop
on it, `wake-silent` routes that box out of the wake set on it, and
`ping.wedged` carries it to the console beside the evidence. A stale
heartbeat is *unmeasured*, not unreachable, and takes the graceful path: the
cost of being wrong there is a killed session.

**And the console confirms the mode it then asks for.** One rule read at two
times is still two answers: the page confirms from a snapshot up to one poll
old, and the collector re-reads the ping map when the POST lands. So a restart
carries `mode` — `graceful` or `force`, whichever the confirmation named — as
the operator's *authorisation*, not as an instruction. The collector decides
for itself as before, compares, and **refuses `409` having fired nothing** if
the box moved in between. A request naming no mode means `graceful`, a bare
restart's meaning before all this, so nothing can escalate without having shown
a human the word.

**Credentials are reported, never polled.** `gh auth status` inside every box
on every poll was ~7,000 api.github.com requests a day to re-derive a fact
that changes when a token expires, and at ~450ms it was the slowest thing in a
probe whose every other read is local. The duty engine already calls GitHub
every tick, so it learns for free: `gh_identity` is the same `gh api user` the
tick was making to resolve `$ME`, but its rejection is now recorded instead of
swallowed by `|| true`. That is a stronger claim than `gh auth status`, which
only proves the token authenticates against `GET /` — a token with the wrong
scopes passes it happily.

Vendor credentials are read from the local store by the agent profile's
`bot_cli_present`, which answers **one boolean**: can this box work, or not.
It returns three values — 0 yes, 1 definitely not, 2 cannot tell locally — and
only 1 raises an alert, because a false "your token is dead" at 3am costs more
than a missed one.

| agent | credential store | boolean derived from |
|---|---|---|
| claude | `~/.claude/.credentials.json` | `refreshTokenExpiresAt` vs now |
| kimi | `$KIMI_CODE_HOME/credentials/kimi-code.json` | `exp` of the refresh JWT vs now |
| codex | `${CODEX_HOME}/auth.json`, *or the desktop keyring* | presence — refresh token is opaque |
| grok | `$GROK_HOME/auth.json` (a map of issuer::client slots) | presence — refresh token is opaque |

**No expiry date is tracked anywhere.** An earlier cut counted down to the day
each credential died, and it was the flaky half of an otherwise stable idea:
four providers express expiry four different ways — epoch millis, a JWT claim,
an ISO string, a response header — and two of the four cannot answer locally
at all. Finding the credential is comparatively stable, so what survives is
the boolean every provider agrees on.

The trap that remains is *which* credential is tested. Every one of these
files also carries a short-lived ACCESS token expiry the CLI refreshes
silently, on the order of hours; testing that would report a working box as
logged out several times a day. Only the refresh credential answers "must a
human log in again", and where it is opaque the profile falls back to presence
and says so with `2` — codex can hold its credential in the desktop keyring
and grok can authenticate from `XAI_API_KEY`, so a missing `auth.json` there
is not a logout. `bot_cli_probe`, which may use the network, stays for the
boot gate and `crew hire`, where a human is present and one round-trip buys
certainty.

**The stuck lock.** `duty.sh` has always written `.duty.lock.since` and nothing
ever read it. A session hung on a vendor call keeps cron ticking, so duty.log
stays fresh, SILENT is satisfied, and the box renders green while doing
nothing. It is now reported as **STUCK** past two tick boundaries — roughly 20
minutes before `run_session`'s own timeout resolves it.

- **Telemetry** — [`server/probe.sh`](server/probe.sh) is piped into each box and
  reads what the duty engine already writes: `duty/VERSION`, `duty.log` (the
  `SESSION START/END` lines and each tick's wake reasons), `repos.txt`, cron,
  uptime, `gh auth status` and the agent profile's own `bot_cli_probe`. The
  queue chips are the work the **last tick actually detected**, not a
  placeholder list. A box is **SILENT** when it has not logged a line for two
  tick boundaries — the same death rule the engine uses.
- **Control** — every action is applied by the host: pause/resume comment and
  restore the box's crontab line — and a box with no armed `tick.sh` line
  answers **`nothing to pause`** at 200, because an action with nothing to do
  is not a refusal (#188) — power/restart are `box down`/`box start`, with
  one exception: **force stop** is `box incus <box> -- stop --force`, its own
  action and never an escalation from a graceful one, and **restart** takes
  that same path *only* where the box has stopped answering the heartbeat, so
  a guest that cannot schedule its own shutdown can still be stopped (#486).
  **A lever that could not act reports that, and skips the step it cannot
  reach** — a restart whose stop failed does not go on to start the box, and
  `wake-silent` sends no resume down a channel that is not answering: it names
  the wedged box for a restart instead, that escalation being the operator's
  to fire and not a fleet-wide button's to take (#487). *Nothing to stop* is
  not a failed stop, so a restart against a box that is already stopped starts
  it without firing `box down` — which errors on a stopped instance, and would
  otherwise take the start down with it.
  A message starts a real one-shot session of that box's own vendor CLI, logged
  to `duty/logs/` and marked in `duty.log` like any other session. The prompt
  travels as **stdin bytes** and is read from a file inside the box, so it never
  enters a shell command line.
- **Nothing is installed in a box**, no box egress is needed, and a box that is
  stopped or wedged fails its probe and is reported — rather than silently
  queueing commands nobody drains.

The collector is [`server/floor.py`](server/floor.py) — Python **stdlib only**,
no build step, no dependencies.

| route | method | purpose |
|---|---|---|
| `/` | GET | the page |
| `/api/fleet` | GET | latest telemetry snapshot |
| `/api/roster` | GET | the fleet's definition as it is on disk: members, the agent and role profiles a line may name, the path (#764) |
| `/api/command` | POST | `message`, `pause`, `resume`, `restart`, `power-on/off`, `force-stop`, `start-all`, `stop-all`, `wake-silent`, `registry-set`, `registry-override`, `registry-inherit`, `roster-set` |
| `/api/logs` | GET | tail `duty.log` or one session log |
| `/healthz` | GET | liveness |

**Two things the page still cannot do.** "Open box terminal" copies `box shell
<name>` for you — a browser cannot attach a shell. And a box that is not running
cannot be messaged; the request is refused rather than queued.

### The roster is editable (#764)

`fleet.roster` is the fleet — one line per box: name, agent, role(s), and the
gold box/snapshot it is minted from — and **Roster** (beside **Registries**)
edits it the way the registries are edited: an overlay painted from the file
as it is on disk right now, one row per box (add, remove, save), each row's
standing read off the poll (hired, not created, new). A save is validated
whole before anything moves — box names in incus's alphabet, agents and roles
that exist as profiles, no duplicates, `from` as `<box>/<snapshot>` — refused
with the line and the reason, written atomically with the file's header
comments kept, and journalled in `.roster-journal.log` (who, the state the
write applied, the deltas). It is refused under the shipped examples fallback,
as every writer is.

Saving writes the definition and nothing else. A new line becomes a box when
the operator runs `crew up` on the host (it creates, starts and hires every
roster box; the login is the operator's, by hand). A removed line's box is
left alone: the console stops watching it and the host tick stops waking it,
and nothing is ever deleted. The collector reads the roster on every poll, so
the edit is live at the next one.

## Tests

```sh
fleet-floor/test/run.sh                 # collector + box-side + CLI + page, no fleet needed
                                        #   (it builds its own operator definition under $TMP)
fleet-floor/test/run.sh --no-browser    # everything except the page
drill/rehearsal-app.sh                  # the same, against this host's REAL boxes
drill/rehearsal-all.sh                  # three roles, then the app
```

Two halves, because neither can do the other's job:

- **`fleet-floor/test/run.sh`** drives the collector against a stub `box` CLI
  (`test/stub-box`, shaped by `test/fixtures/fleet.txt`). That is the only way
  to reach the states that matter and that no real host has on demand: a
  **wedged** box whose `box exec` never returns, an **unreachable** one, one
  whose cron went **silent**, one **paused**, one **hired seconds ago with no
  sessions**, one **not created at all**, and one whose `duty.log` is
  **corrupt** or contains **markup**. A fleet of healthy boxes would pass a
  badly broken renderer.
- **`drill/rehearsal-app.sh`** proves what the stub cannot fake: that `box
  exec` into a real box yields the evidence the floor claims to read, that the
  floor and `crew status` **agree** about every box (they share `probe.sh`'s
  sources, so a disagreement means one is lying to an operator), and — with
  `--allow-control --boxes <name>` — that pause/resume really moves the box's
  crontab. That block **arms the tick line itself** before exercising the
  verbs and disarms it again on every exit path: every drill box is disarmed
  for its whole run (`rehearsal.sh` disarms before any tick), so without the
  arm the verbs act on nothing and prove only that the transport is reachable.
  It is **read-only by default**; a drill that quietly power-cycles a
  working fleet member is worse than no drill. It also runs the page walk in
  read-only mode and **proves** it stayed read-only, by putting a logging
  wrapper ahead of the real `box` on `PATH` and checking that not one mutating
  call was made. That assertion lives here rather than in CI because it is
  about not mutating a *real* fleet, and this is the only place there is one —
  in CI it cost a second full walk to make a weaker claim.

`test/boxside.sh` is what stops the rest being circular: every other collector
assertion runs against `stub-box`, which *imitates* what `probe.sh` emits, so a
real bug in `probe.sh`, in the operator-message script or in `PAUSE_SH`/
`RESUME_SH` would sail straight through. None of them needs a box to run, so
all are executed for real and their output fed to the actual parser —
including the message script's quoting, which must deliver an operator's
prompt as **one argv element, byte-identical**, metacharacters and all, and
the two control scripts against a `crontab(1)` stand-in the test controls:
armed, disarmed, no crontab at all, and a write that is refused.

The page half (`test/browser.js`) needs `playwright-core` and a Chrome —
`npm i --no-save playwright-core`, and `PW_CHROME` to point at one. It asserts the
things a screenshot cannot: that a control targeted the box the operator was
looking at, that hostile log text stayed text, that a down box states its
reason, that the log viewer is not a blockable popup. `test/stale.js` kills
the collector under a live page and checks the page admits it rather than
serving a frozen fleet that looks calm; `test/churn.js` and
`test/transition.js` cover the other two ways what is on screen stops being
true — the box leaves the roster, or goes down — while someone is standing in
its console. When the driver or browser is missing these **skip loudly** — a
silently-skipped UI test reads exactly like a passing one — and in CI they do
not skip at all: `FLOOR_TEST_REQUIRE_BROWSER=1` makes a missing browser a
failure, because on the merge gate a skip and a pass are indistinguishable.

The walk runs against two very different fleets, so it is told which it is
looking at. `FLOOR_TEST_FIXTURE=1` (set by `test/run.sh`, **never** by the
drill) says the fleet is `fixtures/roster.txt`, whose contents are guaranteed:
a box with hostile log text, a box inside its first session, several offline.
There the walk *demands* those boxes and fails loudly if it cannot reach one,
because the checks that depend on them would otherwise vanish in silence. A
real fleet has no such boxes and, when healthy, nothing offline at all — so
without the flag the walk asserts only what any fleet must satisfy. `cli.sh`
asserts both halves: `run.sh` sets it, the drill does not.

## Files

```
fleet-floor/
  index.html        # built, self-contained — this is what runs
  build.sh          # sh concatenator, no deps
  src/style.css     # command-center + cinematic-room styles
  src/body.html     # DOM: canvas, fleet bar, ops bar, agent rails, console
  src/app.js        # canvas render engine (robots/rooms/states), floor, console,
                    #   the live/demo switch, and the demo feed
  server/floor.py   # the collector: serves the page, polls the fleet, applies actions
  server/probe.sh   # read-only duty evidence reader, run inside a box via box exec
  test/run.sh       # collector + box-side + CLI + page, against a stub box CLI
  test/floor/       # collector assertions, one suite per server/floor/ module
  test/boxside.sh   # runs probe.sh and the message script FOR REAL
  test/cli.sh       # `crew floor` arguments, the auth decision, the #244 refusal
  test/stub-box     # fake `box`, driven by test/fixtures/fleet.txt
  test/browser.js   # playwright-core walk of the real page
  test/stale.js     # kills the collector, checks the page says so
  test/churn.js     # removes a box from the roster under an open console
  test/transition.js# takes a box down under an open console
  test/hired.js     # the empty floor, and the first box hired into it (#204)
```
