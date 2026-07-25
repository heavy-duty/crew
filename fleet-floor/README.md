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

A 3×3 facility: **7 quarters** from `fleet.roster` (one per box), plus an
**Operator** room (mission control — the human watching the fleet) and a
**Lounge** commons. Each bot stays in its own quarters.

- **Every quarters shows the full repo wall.** All agents have access to every
  repo, so all six (`ceremony · cast · box · rig · incubator · crew`) appear as
  colour-coded server racks in every room. The rack the bot is currently working
  lights up in the duty-state colour.
- **Robots** are coloured by agent (claude amber · codex teal · grok violet ·
  kimi pink) with per-vendor silhouettes. Role drives what they do at their
  workstation:
  - **builder** — hammers, throws sparks (`kind=build`)
  - **reviewer** — scans with a magnifier (`kind=review`)
  - **triage** — **calls it in.** A holographic call-panel pops up beside the bot;
    it never leaves its quarters (`kind=triage`). `claude-triage`'s quarters is
    the one with the physical kanban board.
  - **idle** — wanders its own room between ticks
- **A box goes cron-silent** → its robot topples with X-eyes and the log prints
  `⚠ no evidence line — cron silent`. Silence *is* the disconnect signal.
- **Bottom ticker** streams `SESSION START/END kind=… rc=… dur=… outcome=…` in
  the real marker vocabulary.
- **Double-click a robot** to open its inspector and message the agent (below).

## Metaphor → data

| On the floor         | In the fleet                                             |
|----------------------|----------------------------------------------------------|
| Quarters (a room)    | a box (isolated VM)                                      |
| Robot                | the agent on that box                                    |
| The six racks        | the repos — every box has all of them                    |
| A rack lit up        | the repo the bot is working right now                    |
| Operator room        | you — mission control                                    |
| Triage call-panel    | `kind=triage` (bots call in; they don't walk anywhere)   |
| Build / review anim  | `SESSION START kind=build\|review`                        |
| Idle wander          | the gap between ticks                                     |
| Robot topples        | a missed `tick.sh` boundary (cron silent)                |
| Antenna / chest color| duty state; body color = agent vendor                    |

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
  "repos": ["incubator", "ceremony", "box"]
}
```

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
