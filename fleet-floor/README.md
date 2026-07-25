# Fleet Floor

A pixel god-view of the `heavy-duty/crew` fleet. Each **server room** is a box,
each **robot** is the agent on that box, each **rack** is a repo it touches, and
the **office whiteboard** is triage. It's a single self-contained HTML file —
no build step required to view, no external assets, no network.

> **Status: prototype on a simulated feed.** The floor is wired to the real
> roster (`fleet.roster`) and the real duty-marker vocabulary, but the telemetry
> is generated client-side. Wiring the live feed is gated on the shared duty
> engine (PR #16) landing — see [Telemetry contract](#telemetry-contract).

## Run it

```sh
open fleet-floor/index.html      # or just double-click it
```

`index.html` is committed pre-built. To regenerate it from `src/`:

```sh
fleet-floor/build.sh
```

## What you see

A **two-row facility that scrolls horizontally** (wheel / drag / arrow keys, or
click a bot in the rail). It grows by adding columns — the roster today is the
**Operator** room (mission control — you), a **Lounge** commons, **7 bot
quarters** from `fleet.roster`, and a **Vacant** room showing where the next
hire lands. Each bot stays in its own quarters.

- **Every room is a UI card in the vendor's colour** — the agent's colour lives
  in the room's *frame*, not soaked across the floor, so the interiors stay
  neutral and the fleet still reads as one system. A faint role-coloured rail
  under the back wall marks the role.
- **Rooms are strongly themed by role** — a reviewer room looks nothing like a
  builder one:
  - **builder** — a *workshop*: fabricator bay, running conveyor, tool pegboard,
    an overhead crane lifting a girder, a workbench, pallets, hazard striping (`kind=build`)
  - **reviewer** — a *clinical lab*: a wall of diff screens, an inspection desk
    with a magnifier lamp, a green/red verdict light, checklists, filing
    cabinets, document stacks (`kind=review`)
  - **triage** — a *dispatch room*: the kanban board, a radar, a call
    switchboard, a map console and phones; the physical board lives here
  - non-bot rooms: an **Operator** mission-control command center and a **Lounge**
    commons
- **Workload at a glance = the queue tray.** Beside each bot's workstation is a
  tray of tickets: **stack height is how much work is queued**, and each ticket
  is **coloured by repo** — so you see both *how busy* a bot is and *which repos*
  have pending work, without a rack per repo (which wouldn't scale). The count
  badge and the rail chip (`… · q4`) show the exact number.
- **The computer is where they work.** The workstation monitor shows the current
  task; the tray shows what's pending. Decorative server racks stay for the
  server-room feel, decoupled from repo count.
- **Triage is a call.** A holographic call-panel pops up beside the bot — it
  never leaves its quarters (`kind=triage`).
- **Each vendor is a different creature**, not just a recolor: claude a sleek
  humanoid android (visor band, chest core), codex an 8-legged spider,
  grok a floating astronaut (bubble helmet, jetpack), kimi a hovering
  companion drone (screen-face, ear antennae).
- **A box goes cron-silent** → its robot **powers down**: it goes grey (lights
  off), a red **"!"** appears over it, and a red **alarm beacon** flashes in the
  room. Silence across a `tick.sh` boundary *is* the disconnect signal.
- **Bottom ticker** streams `SESSION START/END kind=… rc=… dur=… outcome=…`.
- **Double-click a robot** to open its inspector and message the agent (below).

## Metaphor → data

| On the floor          | In the fleet                                            |
|-----------------------|---------------------------------------------------------|
| Quarters (a room)     | a box (isolated VM)                                     |
| Robot (its silhouette)| the agent / vendor on that box                          |
| Queue-tray height     | how much work is pending for that bot                   |
| Ticket colour         | which repo a pending item is on                         |
| Room frame colour     | the agent / vendor on that box                          |
| Room contents / theme | the bot's role (workshop / lab / dispatch)              |
| Operator room         | you — mission control                                   |
| Triage call-panel     | `kind=triage` (bots call in; they don't walk anywhere)  |
| Build / review anim   | `SESSION START kind=build\|review`                       |
| Robot greys out + "!"  | a missed `tick.sh` boundary (cron silent)              |
| Chest / antenna color | duty state; body color = agent vendor                   |
| Vacant room           | an open slot — the layout scales by adding columns      |

## Telemetry contract

The floor consumes what the duty engine **already emits** — one evidence line
per `tick.sh` boundary and `SESSION START/END` markers in `duty.log`. Nothing
new is asked of the model; the only addition is a status emitter at the tail of
the tick.

### Per-box status

Each tick, a box publishes a small status object:

```json
{
  "box": "claude-builder",
  "agent": "claude",
  "role": "builder",
  "version": "crew@<sha>",
  "tick_at": "2026-07-25T14:32:05Z",
  "session": { "kind": "build", "key": "incubator#41", "started": "14:31:59" },
  "last_end": { "kind": "review", "rc": 0, "dur": 72, "outcome": "approved" },
  "queue": [
    { "repo": "cast", "kind": "review", "key": "cast#41" },
    { "repo": "rig",  "kind": "build",  "key": "rig#12" }
  ]
}
```

The `queue` is the pending work the box has detected but not yet handled — the
same set the duty modules already compute each tick (ready issues to build, open
PRs to review, triage signals). The floor renders it directly: **tray height =
`queue.length`, ticket colour = each item's `repo`.** That's what makes workload
legible at a glance without a rack per repo.

**Disconnected is derived, not reported:** if `tick_at` is older than two tick
boundaries (> ~10 min) the box is dead — the same rule the engine uses, where
silence across a boundary means precisely "cron is dead."

### Transport: collector endpoint, box always initiates

A box has **no inbound path** — that isolation is load-bearing for the fleet's
containment story, so telemetry can't be pushed *into* a box and a prompt can't
open a socket *to* one. The collector works only because the box initiates every
connection:

```
box  --POST /report------------>  collector  <--SSE/poll--  webapp
box  --GET  /prompts (long-poll)->  collector
```

The collector holds state; it never reaches into a box.

### Messaging an agent (async pull)

"Double-click to prompt the agent" cannot be synchronous. The message is written
to the collector's prompt queue and the box **drains it on its next tick** (≤ 5
min), which requires one new duty module on the engine side:

- `drain operator prompts` — pull queued messages for this box, start a session
  of the box's role kind, ack back to the collector.

Messaging a disconnected box is refused: no tick, nothing to drain the channel.

## Layout

```
fleet-floor/
  index.html      self-contained, viewable directly (committed pre-built)
  build.sh        concatenates src/ -> index.html
  src/
    style.css     tokens, HUD, single dark "ops-room" theme
    body.html     DOM shell
    app.js        pixel renderer + mock telemetry engine
```

## Not built yet

- The `tick.sh` status emitter and the collector service.
- The `drain operator prompts` duty module.
- Reading live rack activity (which PR/issue) off the GitHub API.

These attach once the shared engine (PR #16) is in place.
