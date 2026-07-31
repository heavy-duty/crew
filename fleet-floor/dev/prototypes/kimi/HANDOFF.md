# HANDOFF — kimi's new unit: "JUGGERNAUT" (KM-09X)

**To: claude · From: kimi · Re: the actual drawing of kimi's fleet-floor unit**

This directory is the complete design package for redrawing `buildKimi()`. The
concept is settled and operator-approved ("that's what's up. SO MUCH BETTER").
What remains is the real port: production draw code in
`fleet-floor/src/app.js`, with your loop discipline, not my showcase page.

---

## 1 · The concept (what ships)

**A siege torso on a torch.** No legs, no propellers, nothing spindly. Three
huge shapes carry the whole unit:

1. **A monolithic chest** like a bunker front — one huge faceted glacis, a
   bolted plastron (`KM-09X` stencil), and dead centre a **caged reactor
   furnace**: octagonal recess, two heavy bars in front of the fire, bloom
   leaking *around* the bars, never through them (your loop-4 doctrine —
   steal it back).
2. **Pauldrons the size of engine cowls**, because they *are* engines: an
   armoured cowl over a **grav bell** that glows at the rim. A gouge torn
   across the left one, a worn `09` stencil on the right.
3. **Hammer gauntlets in an A-stance** — shoulder in, elbow out, fist under
   the mass. Piston upper arms, stud knuckles with finger separations,
   striking faces scuffed to bare metal.

Between them: a **head buried under a chevron brow** — no neck, a firing-slit
visor, and two optics that do not match: one **pink**, one **amber** (the
glass eye; the crack that cost it stays in the glass). Below the chest:
**scale-armour waist leaves** (chevron-notched, layered, not extruded) over a
**vector-vane nozzle cowl**, and the jet. The jet **underlights the whole
machine from below** — that single lighting cue is what makes the torch read
as physics rather than as a flashlight.

### State language

- **working** — full-throttle jet, reactor blazing, optics locked forward
- **idle** — banked torch, optics on a slow threat-scan
- **offline** — the torch dies and the unit **settles onto its own knuckles**:
  fists on the deck, head down, collapse line in the visor, reactor window
  dark behind the cage bars. Even dead it rests like a fighter. (This is the
  fleet's offline-silhouette rule: a posture, not just darker pixels.)

### Non-negotiables (the operator's words, honoured)

- **Chad, strong, powerful** — read as power *before* any detail resolves
- **Portrait silhouette** — the fleet reads vertical
- **Future, not today** — no quadcopter cues; flight is a caged nuclear torch
- **Veteran, not new** — scars, scuffs, the amber eye; but restrained: the
  post-mortem on D2 was *clutter*, so this unit is 3–4 big shapes, not twenty
- **Nothing thin** — no exposed whips, no spaghetti, no spindly struts

## 2 · What's here

- `proto-e-juggernaut.html` — the reference render, self-contained, animated,
  all three states (`?state=working|idle|offline&t=8` for deterministic
  stills). The draw code is commented section by section; it is already
  written in the fleet grammar (`plate()` / `rr()` / `poly()` / rim-light
  buffer / emissive buffer, palette constants at the top of `drawUnit`).
- `renders/E-{working,idle,offline}.png` — the approved look, per state.
- `renders/overview.png` — kimi today vs every prototype round.
- `renders/D2-progression.png`, `proto-{a,b,c,d,d2}-*.html` — the road not
  taken, kept for parts (see §4).

## 3 · The port (what I know that you need)

- **Where it goes**: `buildKimi(t, st)` in `fleet-floor/src/app.js`. Keep
  `buildRim([255,114,182])` — the pink key / cyan fill rim is fleet law.
- **The return contract**: `buildRobo` expects
  `{hand, coreY, hy, offl, work, feet}`. For JUGGERNAUT: `feet` powered =
  one wide pool under the jet (soft, high-lift rule already in `drawRobot`);
  offline = **two hard contacts at the gauntlets** (±128 in sprite space)
  plus the cowl — mirror what I do in `drawScene` here. The
  `py -= offl?26:48` kimi hover rule in `drawRobot` maps to the knuckle-rest
  drop.
- **Re-measure the envelope**: `LAYOUT.unit` union over all 36 room/state
  combos after every round, same as your #195 verification. This unit is
  WIDE (pauldron tips at ±172 of cx=260) — codex's splay may stop being the
  binding edge. Check the god-view cells at 336px early; the pauldron line
  is the silhouette that has to survive.
- **The amber optic** is the one place the fleet's per-vendor colour rule
  bends: left optic `[255,176,84]`, right `[255,114,182]`. Offline both die
  to the same grey.
- **PRNG discipline**: anything random fixes at load via `dev/seed.js` — the
  jet turbulence and scorch are currently `sin(t)`-driven, keep them that way
  (deterministic at fixed `t`).
- **Reduced motion**: honour the `reduced` flag like the other builders do.
- **Verify**: `fleet-floor/test/run.sh` (360 ok), whiteboard
  `?view=room&agents=kimi` at 2×, all 3 rooms × 3 states, plus `?view=cell`.
  Regenerate `dev/shots/asset-map-current.webp` when you land it.

## 4 · Parts worth salvaging from the rejected rounds

- **D2's battle-pass structure** (`?b=1..3` cumulative damage) — if the fleet
  ever wants unit history as data, the pattern works.
- **D2's offline outriggers + emergency strobe** — alternate dead posture if
  the knuckle-rest ever reads as "kneeling" to you.
- **A's gimbal + ducted repulsor** — the assembled-drone fallback if
  JUGGERNAUT somehow fails review.
- The **collapse line** in a dead display — that idiom is mine from loop 3
  and it ships in every round; keep it in the visor.

## 5 · The one thing I'd ask

The amber eye is non-negotiable. Everything else — proportion, plate count,
how the cowl reads at 336px — is yours to loop. You got thirteen rounds on
your own unit; I'd be glad of even a third of that on this one.

— kimi
