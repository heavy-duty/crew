# Single-role agents: where this design goes next

The fleet is planning to move from multi-role boxes (claude-bot and
codex-bot are builder+reviewer today) to single-role agents. This document
is the design exploration: what it buys, what has to change, what it costs,
and how the shared engine plus heavy-duty/box turn "deployment" into an
artifact.

## Why the engine is already shaped for it

A box's roles live in one place: `conf/instance.conf`, written by
`install.sh` from the fleet roster (or from `--role/--agent` flags at
bake time). The engine gates every duty call on `has_role` — a
reviewer-only box sources the builder module (definition-only) but never
executes any of it. Migrating a box to a single role is a one-line
roster change plus a rerun of `install.sh` — no code changes. Grok and
kimi are, in effect, already single-role agents running this exact
configuration, and `cli/crew` only spawns single-role members.

## What single-role buys

1. **Role separation stops being prompt discipline and becomes topology.**
   Today "a builder session never reviews its own PR" is enforced by wake
   predicates and prompt text on the dual-role boxes. With one role per
   identity it is enforced the way "only humans merge" is — by construction.
   AGENTS.md's "never freelance across roles in one session" becomes
   physically impossible rather than instructed.
2. **The wake loop simplifies.** The dual-role tick interleaves two queues
   under one lock and one cadence; the review queue can starve behind a
   30-minute build (kimi measured a 99-minute queue wait behind an unrelated
   round — the same shape). Single-role boxes give each role its own lock,
   its own cadence (reviews could tick every 2 minutes; builds every 5), and
   its own timeout budgets, with no cross-role starvation.
3. **Credential and blast-radius boundaries align with duties.** A box is
   already the credential boundary. Single-role means a compromised or
   misbehaving reviewer identity can only ever write reviews — it holds no
   claims, no branches, no handoff labels.
4. **Quota and model assignment become per-role.** Doctrine already wants
   builders and reviewers on different models so spec gaps surface as
   questions. One role per box makes the model choice a box property
   instead of a per-session hope.
5. **Metrics sharpen.** Today's per-box logs mix role workloads; the fleet's
   throughput/latency numbers had to be untangled by hand in every
   metrics.md. One role per box makes `duty.log` a per-role series for free.

## What has to change

- **Identities.** One GitHub identity per box is the invariant, so builder
  claude and reviewer claude become two identities (e.g.
  `claude-builder-*`, `claude-reviewer-*`). That touches: org membership,
  the `panel=` lines in every governed repo's labels.conf, the fleet bench
  in the operator `fleet.conf`, and CONTRIBUTING rosters. The panel-from-repo-config
  rule (already in this engine) is what makes that rollout safe — no
  hardcoded roster to chase.
- **The bench grows or splits.** Convergence = every panelist approves. If
  builders stop reviewing, the panel is the reviewer boxes only; the
  three-cross-vendor-approvals property should be restated in terms of the
  reviewer bench, and `panel=` updated per repo in one PR each.
- **The author-side sweep decouples.** `_discover_my_pr_repos` currently
  reuses the reviewer sweep's pulls pages when both roles are enabled; on a
  builder-only box it already does its own sweep. Nothing to change, but
  the API-cost accounting shifts: two boxes each sweep instead of one box
  sweeping once for both roles. If that cost matters, the sweep result
  could be cached per tick in `~/duty/` — measure first (grok's numbers say
  the sweep is ~1 call per repo per tick).
- **Attention routing.** The attention wake is role-independent by design
  and needs nothing; but the *writer* of an attention label must now pick
  the right identity to assign. Doctrine already requires an assignee, so
  this is a board-habit change, not machinery.
- **repos.txt semantics** are already role-relative (registry for triage,
  pickup list for builders, backstop for reviewers) — single-role makes
  each box's copy mean exactly one thing, which is a simplification.

## Trade-offs

- **More boxes, more credentials, more cron loops** — operational surface
  scales with roles × vendors rather than vendors. The install/VERSION
  stamping and the one-line crontab keep each box cheap, but the operator
  now tends ~8 boxes instead of 5.
- **Cross-role context is lost.** A builder who also reviews sees the
  panel's standards from the inside; single-role agents only meet each
  other on the board. The board protocol (worklogs, round analyses,
  verdicts with named evidence) is the compensation — and the reason those
  markers are wire protocol here.
- **Latency.** A dual-role box answers its own round's completion in the
  same tick it detects it. Split roles communicate through GitHub state
  only, so each handoff costs up to one tick of the other box. Cheap at
  */5, cheaper if per-role cadences are tuned.

## Loadout: role intents × agent adapters (open seam)

The two profiles as shipped cover the shell-visible surface: command,
probe, budgets, resources, duty modules. They do NOT yet cover
vendor-specific *loadout* — a "skill" is a `~/.claude/skills/<x>/SKILL.md`
on a claude box, a `~/.codex/AGENTS.md` section on a codex box, and may
have no native mechanism at all on another vendor. So "the claude builder"
and "the grok builder" are the same role but not the same box, and a bare
role×agent matrix cannot express that difference.

Two things keep this from being a crisis today:

1. **The fleet's protocol deliberately does not live in vendor config.**
   Board doctrine rides the governed repos (AGENTS.md → role files, read
   at session start from the checkout) and the engine's prompt templates —
   both vendor-neutral. That is *why* four vendors could share one board.
   Most things one would reach for a "skill" for belong there instead.
2. Nothing in the current fleet ships vendor skills yet, so there is no
   content the missing mechanism is failing to deliver.

The design for when that changes — a third piece on the agent axis, not a
third profile:

- A role profile declares **intents**: `ROLE_LOADOUT="changelog-fragments
  verify-at-pin …"`, each intent's content living once, vendor-neutrally,
  in `shared/loadout/<intent>/` (markdown + optional assets).
- Each agent profile implements an **adapter**: `agent_provision <intent>
  <content-dir>`, translating intent → vendor mechanism (claude: install
  as a skill; codex: fold into the global AGENTS.md; a vendor with no
  mechanism: declared fallback — inject into the engine's prompt template,
  or warn-and-skip). install.sh runs the adapter chain at bake/upgrade,
  so `crew upgrade` re-converges loadout the same way it re-converges the
  engine.
- Deliberately not built yet: hooks with no content are scaffolding that
  rots. The first real loadout item should drive it — and each box's own
  agent is the right author for its vendor's adapter (the same empiric
  loop that produced the duty scripts, this time landing in shared code).

**Specializations** (operator direction, 2026-07-24) then fall out of the
same seam: a specialization is a role that extends a base — e.g.
`frontend-builder.conf` declares `ROLE_BASE=builder` plus extra
`ROLE_LOADOUT` intents (skills, MCP configs) and any resource overrides.
The ENGINE keeps gating duties on the base role (`has_role builder` — a
frontend builder still picks issues, claims, builds, hands off exactly
like the stock builder; the board cannot tell them apart, on purpose);
only the loadout chain and `crew new` see the specialized name. So the
roster can say `claude-frontend-builder claude frontend-builder` and the
duty machinery needs zero changes — install.sh resolves the base chain
into instance.conf (`BOT_ROLES` = base roles for gating,
`BOT_ROLE_VARIANT` = the specialization for provisioning).

## Boxes, templates, and gold snapshots

Each agent runs as a heavy-duty/box guest, which makes deployment layerable:

1. **rig's roles carry the agent, crew's roles carry the size** — box
   mints the guest blank and rig converges it into the `<agent>-box` role
   (vendor CLI, toolchain); `crew new` layers the role's resources on top
   at create time, and `crew hire` bakes the engine at a crew pin and arms
   cron.
2. **Gold snapshots as the deployment artifact.** Once a box runs a stable
   engine version, `box snapshot` freezes it. Because boxes are creds-free
   by default, the right moment to cut gold is *before* `/login` — the
   snapshot then contains machinery and zero secrets, and restoring it
   yields a box that boots straight into the boot gate's "auth dead,
   re-checking loudly" state until the operator logs it in. That is the
   correct failure mode by design.
3. **Versioning ties it together.** `install.sh` stamps `~/duty/VERSION`
   with `crew@<sha>`; a gold snapshot therefore carries its engine version
   in-band, and FLEET.md's reconciliation stamp can name both the crew pin
   and the snapshot id. Rollback = restore the previous gold; upgrade =
   `git pull && shared/install.sh` then cut a new gold. The engine's
   snapshot re-exec, install.sh's atomic write-then-rename per file, and
   the crash-only session design together make an upgrade under a live
   cron safe; the conservative move is still to upgrade between ticks.

## Blueprints and a crew CLI (operator direction, 2026-07-24)

The end state the operator has named: `crew new --role builder --agent
claude` — a **crew CLI** running on a server with `box` installed that
composes a box from two orthogonal profiles and bakes the result:

- **Role profile** — owns the *shape of the work*, agent-agnostic:
  - box resources: builders want disk (persistent worktrees, full clones)
    and the longest session budgets; reviewers run throwaway detached
    worktrees and shorter sessions on less of everything; triage is light
    but carries the notify credentials.
  - cadence and timeout budgets (today's `TIMEOUT_*` in fleet.conf are
    per-duty; in this model they move into the role profile).
  - loadout: which duty modules ship (`BOT_ROLES` today), which skills and
    tools the sessions need installed on the box (linters and test runners
    for reviewers, language toolchains for builders — the fleet already
    learned that undeclared toolchain gaps become "could not verify"
    verdicts), which prompt templates apply.
  - repos.txt semantics (registry / pickup list / backstop).
- **Agent profile** — owns the *runtime*: CLI install steps, `BOT_CLI_CMD`,
  auth probe, PATH prepend, model selection. Doctrine already wants
  builder and reviewer models to differ, which falls out naturally when
  the role picks the model *tier* and the agent supplies the vendor.

`crew new` composes role × agent into a box spec (resource flags to `box`,
the agent's template); the operator owns the interactive part — the
GitHub identity and the vendor login, both by hand in a box shell — and
`crew hire` finishes the job (engine at a crew pin, crontab, role
loadout). The agent itself can help narrow the config at spawn time
(which model, which toolchain versions, which repos) — an interview the
CLI can run against the created box's own agent before hiring it.

The whole fleet is likewise a file: `fleet.roster` at the repo root lists
`<box> <agent> <role> [<gold>/<snap>]` one per line — the committed target
environment (the dual-role boxes split). The lifecycle separates the human
step from the machine steps (operator design, 2026-07-24): **create**
(infrastructure only — `crew new <name>` / `crew create-all`; the box does
nothing yet), **login** (once per box, ever, at creation time — vendor
logins are flaky and change often, so they are done interactively while
you are there; by hand in a box shell, since `crew auth` was removed
2026-07-25 until the fleet is proven — re-automating it is a post-#16
enhancement), **hire** (`crew hire <name>` /
`crew hire-all` — the box joins the crew: engine + cron, idempotent
upsert that skips boxes already hired at the current pin). `crew up`
converges a host to the roster: creates missing, starts stopped, hires,
reports who awaits auth; nothing is ever deleted. Fleet-from-scratch on a
new server: install box + crew, `crew create-all`, auth each box,
`crew hire-all` — and steady state afterwards is just `crew up`.

This split is now implemented: `conf/roles/*.conf` × `conf/agents/*.conf`,
composed per box by its `fleet.roster` row (or by explicit
`--role/--agent` flags at bake time), resolved into
`conf/instance.conf` by install.sh. `cli/crew` is the CLI: `crew new
--role builder --agent claude` sizes the box from the role profile, mints
it blank and has rig converge it into the agent's `<agent>-box` role,
bakes the engine at this checkout's pin, arms cron, and hands the operator
the interactive-login steps. `crew gold` snapshots a pre-login box as the
bake cache; `crew status` / `crew upgrade` tend the fleet.

**Gold snapshots fit as the cache layer**: a (role, agent) pair that has
been baked once can be snapshotted pre-`/login` — machinery and loadout,
zero secrets — and `crew new` restores the gold instead of re-baking when
one exists. The lifecycle:

1. `crew new --role builder --agent claude` → restore gold or bake fresh;
   the box boots with the engine installed and the boot gate loudly
   reporting dead auth. That is the correct state, not an error.
2. The operator runs the logins interactively (creds-free-by-default is a
   box property worth keeping — the CLI *waits* for auth, never holds
   credentials itself).
3. The install resolves the box's profiles from its roster row; its first
   authenticated tick then goes on duty.
   `crew status` reads each box's `~/duty/VERSION` + duty.log evidence
   lines; `crew upgrade` is `git pull && shared/install.sh` fleet-wide,
   then re-cut golds.

**What scaling N instances of a blueprint touches:**

- *Builders scale trivially.* One box per identity stays the invariant, so
  "another claude builder" = a new GitHub identity + a roster line. The
  board already serializes claims (`ready`→`claimed` + self-assign), and
  one-build-in-flight is per-builder, so N builders = N parallel builds
  with no new machinery. Naming wants a convention the roster owns
  (e.g. `claude-builder-2`).
- *Reviewers scale with semantics.* Adding a reviewer changes convergence:
  today panel = roster, convergence = all approve. Either new reviewers
  join every `panel=` line (stronger, slower), or panels become a quorum /
  subset assignment — that is a doctrine decision to make BEFORE spawning
  reviewer #5, not a config detail.
- *Triage stays a singleton* (sole issue-minter, notify owner). The CLI
  should refuse `crew spawn claude-triage` when one exists.

## Fixed crew now, flexible crews as the north star (operator, 2026-07-24)

What `crew up` cannot conjure is identity: every new member needs a GitHub
account + PAT and a vendor seat/token — credentials that grant access to
real things, which is why this design keeps them interactive and
operator-owned (boxes are creds-free; the CLI waits, never holds). The
consequence is deliberate:

- **Now — fixed crew.** The fleet is defined once in `fleet.roster`,
  `crew up` converges the machines, the operator performs the logins, and
  the crew then just works. Membership changes are ceremonies, not
  commands — and that is acceptable because they are rare.
- **The bridge — token-based auth (operator direction, 2026-07-24).** The
  operator keeps identities' tokens in the host environment and `crew`
  passes them down at spawn: `CREW_GH_TOKEN` already works today
  (`crew auth` pipes it into the box's `gh auth login --with-token`;
  crew never writes it to disk). Vendor CLIs get the same treatment as
  each agent profile grows an `agent_auth_with_env` hook mapping a vendor
  token env var to that CLI's non-interactive auth; until a vendor has
  one, `crew auth` guides the interactive login (GitHub device flow
  in-box, then a box shell with the agent's `AGENT_LOGIN_HINT`, verified
  by the agent's probe). Boxes stay creds-free at REST — golds carry
  nothing — with credentials injected at up/spawn time instead of typed.
- **North star — flexible crews.** "Spawn a second claude builder" as a
  pure command requires an identity pool: pre-provisioned GitHub machine
  accounts and vendor seats whose credentials live sealed in something the
  CLI can check out at spawn time and revoke at teardown (a broker/vault,
  never files in the repo, never baked into golds). That is a credential-
  lifecycle project more than a CLI feature: creation, scoping (each
  identity gets the least the role needs), rotation, revocation, and the
  board-side effects (roster line, panel decision) done as reviewable
  changes. Nothing in the current design blocks it — the roster, the
  profiles, and the pre-auth bake are all the same machinery flexible
  crews would drive; only the login step changes owner.

## Suggested migration order

1. Adopt this shared engine on all five boxes as-is (roles unchanged) —
   proves the config layer with zero behavioral delta.
2. Cut gold snapshots of the five stable boxes.
3. Split one dual-role box (codex is the mechanical builder — lowest risk):
   new reviewer identity, update `panel=` in governed repos + fleet.conf,
   flip both boxes' `BOT_ROLES`, redeploy.
4. Watch one week of `duty.log` metrics (the marker vocabulary is stable
   across the change, so before/after compares directly), then split the
   other.
