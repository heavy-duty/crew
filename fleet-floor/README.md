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

- **7 server rooms** laid out from `fleet.roster`: the three `claude-*` boxes on
  the left, `codex-*` under the office, `grok-reviewer` / `kimi-reviewer` right.
- **Robots** colored by agent (claude amber · codex teal · grok violet · kimi
  pink). Role drives the animation:
  - **builder** — hammers a rack, throws sparks (`kind=build`)
  - **reviewer** — runs a scan line down a rack (`kind=review`)
  - **triage** — walks to the office whiteboard (`kind=triage`)
  - **idle** — wanders its room between ticks
- **Racks** are the repos each box works; the active one glows in the state color.
- **A box goes cron-silent** → its robot topples with X-eyes and the log prints
  `⚠ no evidence line — cron silent`. Silence *is* the disconnect signal.
- **Bottom ticker** streams `SESSION START/END kind=… rc=… dur=… outcome=…` in
  the real marker vocabulary.
- **Double-click a robot** to open its inspector and message the agent (below).

## Metaphor → data

| On the floor        | In the fleet                                             |
|---------------------|----------------------------------------------------------|
| Server room         | a box (isolated VM)                                      |
| Robot               | the agent on that box                                    |
| Rack                | a repo the box touches                                   |
| Office whiteboard   | triage                                                   |
| Build / review anim | `SESSION START kind=build\|review`                        |
| Walk to the office  | `kind=triage`                                            |
| Idle wander         | the gap between ticks                                     |
| Robot topples       | a missed `tick.sh` boundary (cron silent)                |
| Antenna / chip color| duty state; body color = agent vendor                    |

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
