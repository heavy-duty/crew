# Host maintenance — the three scheduled jobs, the host's own login, and the ordering rule

Every box carries a five-minute cron line for its own duty tick
(`shared/crontab.example`). Until now nothing on the **host** side had an
equivalent: `crew up`, `crew upgrade`, `crew restart` and `crew reset` were all
verbs somebody had to remember to run, and the consequence was measured — the
`2026-08-28` fleet sweep found `claude-builder` at 91% of its disk and
`grok-reviewer` with no session in nine days. Neither is a fault anything
reports, and both were found because a host crash prompted somebody to look.

`shared/host-crontab.example` is the schedule. This is what it does, how to
read it afterwards, what is deliberately **not** in it, and the one rule that
keeps the reset useful.

## What is scheduled

| when | job | what it does |
|---|---|---|
| every 5 min | `crew tick` | reads each board once, starts members for their work, stops idle boxes (#759) |
| daily, 04:10 | `crew restart --all` | drains and cycles every roster box that is running; a stopped or paused box is left as it is |
| Sunday, 05:10 | `crew reset --all` | every box back to its `armed` checkpoint, its memory drained first and written back under the duty lock (#761) |

Install it on the box **host** with `crontab -e`, copying
`shared/host-crontab.example`. There is no installer for this; the real-host
drill is operator-attended by construction and is not scheduled.

**The host needs its own `gh` login.** The tick reads every registered board
with the host's `gh`, never a box's. Log in once on the host (`gh auth login`,
as the operator or a read-only identity) before the first tick. A host whose
`gh` is dead or rate-limited says so on every tick and neither wakes nor
stops a box: the tick refuses to read blindness as a quiet fleet, so a dead
credential costs wakes, never a mid-session stop.

The daily cycle is also the fleet's only routine liveness signal.
`grok-reviewer` ran no session at all between `2026-08-19` and `2026-08-28`,
and nothing on the board or the floor reported it.

## The weekly reset — scheduled again since `0.1.4` (#761)

Three rules the reset keeps since the `0.1.4` review, each the host tick's
own rule applied to the one verb that could undo it:

- **A paused box is left alone under `--all`**, exactly as the daily
  restart leaves it: the restored disk's cron is live, and nothing but
  `crew resume` starts a paused box. `crew reset <box>` by name restores it,
  writes its memory back, pauses its crontab again and stops it.
- **The cap holds.** A box restored while `FLEET_MAX_RUNNING` other boxes
  are running goes back down once its memory is written; the host tick
  starts it when there is work for it.
- **The first tick waits for the memory.** `crew reset --cut` leaves
  `~/duty/.memory-pending` inside the checkpoint, so a box restored from it
  boots with the marker and `duty.sh` skips every tick (under its own lock)
  until the host's write-back lifts it in the same locked step that unpacks
  the archive. The box's own `*/5` cron can therefore never run a session
  with no ledgers ahead of the write-back, and the write-back never lands
  over what such a session wrote. The wait is bounded by
  `MEMORY_PENDING_GRACE_S` (1800 s of uptime): past it the box runs
  without its memory and says so once in `duty.log`. A write-back that
  fails is a failed reset (rc 1), said by name in the job log; a store that
  simply holds nothing for the box (its first reset) lifts the marker and
  is said as that. Checkpoints cut before `0.1.4` carry no marker: re-cut
  them once (`crew reset --cut <box>`) to get the guarantee.

`crew reset --all` is the second line, weekly on Sunday at 05:10. #678 had
deferred it to this window because a restore wiped two things nothing could
rebuild — `duty.log` and the engine's ledgers. The store (#758) now holds both:
a reset **drains the box to the store first** (and refuses a box whose drain
fails), restores the disk, starts the box, and **writes the member's memory
back** — every state file and ledger the store holds for it — before the first
tick, so the box makes no refusal it had already made. The paragraphs below
record what the deferral measured and remain true of the disk; the store is
what answers them.

The reset restores each roster box to its `armed` checkpoint, which is a
whole-VM snapshot restore with **no carve-out for `$DUTY_DIR`**. Most of what
lives under there survives being lost, and that was measured rather than
assumed — the `.seen-*` signal ledgers are cost-only and self-healing, mentions
are made idempotent GitHub-side by marking the thread read, and declines are
re-read from the board. Two things are not reconstructible:

- **`duty.log`.** The fleet's only record of its own sessions — every
  `SESSION END` line, with the `tier=`, token and `cost_usd=` fields #469 put
  on it — lives inside the wiped directory. A weekly restore leaves the fleet
  holding at most seven days of its own history, in the very release window
  that ships telemetry into that file.
- **The resume breaker, cleared with no push.** A lane is suppressed after
  three commitless dispatches at one head, and #314's invariant — written after
  the #311 flood — is that **only a push clears it**. A snapshot restore clears
  it anyway. Every correctly-suppressed lane would re-arm each Sunday and buy
  itself three more dispatches before it re-suppressed.

Neither side of that is wrong alone. The schedule is right about disk and
liveness; the breaker is right about floods. What nobody had written down is
that one of them is a durability assumption the other violates.

**What returns it: #328, the collector.** Once the evidence is durable off-box
a restore costs nothing that matters, and the weekly line comes back as part of
that flow rather than as a hand edit to the crontab.

### Both verbs, not one — the argument the return is made from

This reasoning is why the reset comes back rather than being written off, so it
is kept rather than deleted with the line. A reset that discards everything
looks like it subsumes a restart that discards very little. It does not, and
the two differ on both axes that matter (@danmt, `2026-08-29`):

- **Price.** The restart is cheap and reversible. The reset is heavy and, by
  the interlock below, refusable.
- **Period.** The restart clears what accumulates hour to hour — leaked
  `duty-snapshot.*`, week-old guest state — six days before the reset would.

Both halves still hold. The deferral does not dispute either one; it says the
reset's **period** currently collides with a durability assumption, and #328
removes the collision rather than the argument.

### What the deferral costs, and the reading to take before `0.1.4`

This is real and currently unowned, so it is stated rather than left to be
discovered. **The weekly reset had become the fleet's de-facto garbage
collector** — the daily restart clears `/tmp` and week-old guest state, and the
reset is what returned a box to a known size rather than merely to a smaller
one. Deferring it leaves that job to nothing.

**What this costs is narrower than it was a week ago, and the difference is
worth stating because the schedule was argued from the wider version.** The
detached review worktrees are **no longer part of it**: **#606** closed
`2026-09-02`, and `shared/bin/duty.sh` now calls
`reclaim_detached_review_worktrees` on every tick, above the boot gate. Clean
detached worktrees are removed; dirty ones are moved to `kept-<name>-<head>`
rather than left on the path the next review needs
(`shared/lib/duty-review.sh`). The reviewer box that carried `review-256/` plus
a second full copy of the tree, and the `2026-08-28` sweep that found
`claude-builder` at 91% of its disk, are **historical**: they are why the
schedule was written, and both predate that reclaimer. Read them as the
provenance of this file, not as a description of a box today.

**What no tick reclaims, and what a hand reset therefore still buys.** Two
residues, and both are deliberate rather than gaps:

- **`kept-*` preserved trees.** A dirty detached worktree is moved aside
  instead of removed, and a tree already named `kept-*` is never moved again.
  That is the point — it is somebody's uncommitted work — and it also means
  nothing on a schedule will ever reclaim it.
- **A build worktree the engine declined to force.** `_wt_release`
  (`shared/lib/duty-builder.sh`) removes a done branch's worktree, but where
  the clean removal refuses and the upstream record does not post, it keeps the
  worktree on purpose until the record lands. The work is safe; the disk is
  spent.

Both are bounded by how much unfinished work a box has actually left behind,
not by how long the box has been up — which is why this is a cost to **measure**
rather than one to predict from the calendar, and why the reading below is a
command rather than a schedule.

**The reading an operator should take between now and `0.1.4`, and it is a
command that already ships rather than a new habit.** A `--cut` reclaims first,
then measures each box's **root** filesystem, then **refuses** any box still
over `CREW_RESET_CUT_MAX_USED_PCT` (default `80`) — naming what is large on it,
biggest first, rather than only the percentage:

```
crew reset --cut --all
```

Run it after any `crew upgrade` (the ordering rule below already asks for that)
and read the refusals as the disk report. A refusal there is the early warning
this deferral costs you: it says a box crossed 80% and names what is holding
it. To look at one box directly, without cutting anything:

```
box exec <box> -- bash -lc 'df -Pk /'
```

If a box really has filled, the repair is a **hand** `crew reset <box>`. The
verb is unchanged and available, and the ordering rule below applies to it
exactly as it applied to Sunday's job. @danmt has accepted this cost with that
repair in reach; the fleet has run roughly a month without a reset.

## No `flock` and no redirect in the cron line

The line carries neither, and this is a charter rather than a preference. It is
`shared/crontab.example`'s rule, and that file did not invent it either — it
was written because **five hand-edited variants of the on-box line had
drifted**, and because a skipped tick that wrote nothing made a wedged bot
indistinguishable from a healthy quiet one.

So all the locking, all the logging and all the evidence lines live **inside
the verb**. What the cron line contains is the verb and its arguments. Nothing
about a host is allowed to live in a crontab entry, because a crontab entry is
the one file nobody diffs.

## Reading the evidence

Both verbs write to the host job log:

```
~/.local/state/crew/host-maintenance.log
```

(`$XDG_STATE_HOME/crew/…` when that is set; `CREW_HOST_STATE_DIR` moves the log
and the lock together, which is what a host running two fleet definitions
wants.)

The contract is `shared/bin/tick.sh`'s, adopted rather than reinvented — one
line per boundary, with the run's own per-box output in between:

```
<ts> restart run start
  claude-builder: restarted; /tmp filesystem free 812340 → 4210088 KiB (delta +3397748 KiB)
  grok-reviewer: SKIPPED busy — duty lock held for 12m
<ts> restart run end: some boxes SKIPPED busy (exit 3)
```

A run that did nothing writes those lines too. **Silence in this log at a
boundary therefore means exactly one thing: cron itself is dead.** That is the
property the on-box side already has, and it is the reason the log exists at
all rather than a redirect in the crontab.

### The exit status

A cron mail has nothing but the number to read:

| status | meaning |
|---|---|
| `0` | every selected box was acted on |
| `1` | a box **FAILED**, or was **REFUSED** — the per-box line says which, and names the repair |
| `2` | the invocation was rejected; nothing was attempted |
| `3` | no failure, but a box was **SKIPPED busy** — its duty lock was held |
| `4` | nothing was attempted: no box was selected, or another host job held the lock |

`3` is not a problem to fix. A box with a duty lock held is a box doing work,
and the job leaves it alone by design; the next night's run takes it.

### A skipped box, and a skipped run

These are different facts and the log keeps them apart.

- **A skipped box** (`3`) — that one box was busy. Named in the per-box line
  and again in the `skipped:` summary, never silently omitted.
- **A skipped run** (`4`) — the whole job did not start, because the other job
  held the host maintenance lock. The line names the holder and how long it has
  been running.

Both verbs share one non-blocking host lock, so a reset and the daily restart
can never overlap. That guarantee is the **lock's** and never the schedule's,
which is exactly why it survives this change: with only one job scheduled the
contention that remains is a hand-run `crew reset` landing on 04:10, and the
lock is taken on every invocation, including yours at the keyboard.

## The reset refuses, and that is the feature

This section is unchanged by the deferral. It describes the **verb**, which
still runs on demand — and it is also what has to stay true before the weekly
line can come back on `0.1.4`.

A restore to a checkpoint cut **before** the last `crew upgrade` is a silent
engine downgrade of the whole fleet, with nothing red anywhere — and on a
schedule it would be that every week, which is the shape `0.1.4` restores.
Every verb that installs an engine — `crew hire`, `crew up`, `crew upgrade` —
marks the checkpoint stale before installing, and the reset refuses any box
whose mark is set:

```
  claude-builder: REFUSED — its armed checkpoint was cut at crew@0.1.2 and the
  box was upgraded to crew@0.1.3 since; restoring it would silently downgrade
  the engine. Repair with: crew reset --cut claude-builder
```

**A refused box is a correct outcome of the reset, not a failure to be tuned
away.** There is no `--force` on this path and there must never be one;
there is no fallback to `bootstrapped` or `pristine`, which would return a
creds-free, unhired box; and nothing retries. The repair is a fresh checkpoint,
by hand, on a box you have looked at.

> ### The ordering rule
>
> **After any `crew upgrade`, re-cut before the next reset.**
>
> ```
> crew upgrade --all      # marks every armed checkpoint stale
> crew reset --cut --all  # takes fresh ones at the new engine
> ```
>
> Skip it and the next reset refuses every box it marked, exits `1`, and
> restores nothing — safely, loudly, and having done none of the reclaiming you
> wanted. The fleet is not damaged; it is simply not maintained until you
> re-cut.
>
> **The rule is unchanged by the deferral, only re-anchored.** It used to be
> read against Sunday's job, which named the deadline for you; now "the next
> reset" is the next one **you** run. Nothing schedules it, so nothing will
> remind you — which makes re-cutting part of the upgrade rather than a thing
> that happens before a deadline.

A cut has its own refusals for its own reasons — a box that is stopped, not
logged in, not hired, or still over `CREW_RESET_CUT_MAX_USED_PCT` of its disk
after the on-demand reaper has run. `crew help reset` has all of them. Re-cut
attended, read what it says, and repair what it names before you reset.

## The host tick — `crew tick` (#759)

A board the host cannot read holds every idle stop for that tick — a blind
tick must not read a dead board as a quiet fleet. A board unreadable for
`TICK_BLIND_TICKS` ticks running (3) is a repository the host cannot read at
all — renamed, private to this login, gone — and is set aside instead: said
on every tick, and no longer holding the fleet up. Fix the registry or the
host's login; the count clears on the first readable tick.

The host's cron runs `crew tick` every five minutes (`shared/host-crontab.example`).
A tick reads each registered board once — issues, pull requests, discussions —
and, for every roster member, compares the board to what that member last saw.
A member's box is started only when the board moved **and** the move names
work its roles own (a ready issue nobody holds for a builder, a review request
for a reviewer, anything at all for triage, an `attention` demand for anyone)
**and** the store's memory of that member does not already answer it: an item
its seen-ledgers hold at that timestamp, a lane whose breaker is tripped, a
lane whose session budget is spent. Each refusal is logged by name
(`veto <reason>:<why>`), so a wake that is missing is never silent.

At most `FLEET_MAX_RUNNING` boxes run at once; a member with work past the cap
is `held`, by name, and re-evaluated next tick. A running box that bought no
session for `IDLE_TICKS_BEFORE_STOP` consecutive ticks is drained to the store
(`crew drain`) and stopped. A started box is handed its reason in
`~/duty/.wake-reason` and ticked at once; every `SESSION END` that tick
writes carries it as `why=`.

A wake launches the box's own `tick.sh` in the background and returns at
once, so a wake that starts an hour-long build never holds the host's lock
across the next five-minute boundaries, the daily restart or the weekly
reset. Before an idle box is stopped its duty lock is probed: a box whose own
cron started a session since its idle counter was written is busy, and busy
is never stopped. Triage's coarse "the board moved" reason is set aside once
the box was woken for it `IDLE_TICKS_BEFORE_STOP` times and bought nothing;
a precise reason (an attention demand, a ready issue, a review request, a
due wait or cut) never is. A breaker tripped in the store's copy vetoes a
lane only while the box runs: a stopped box is started for the work and its
own gate — the one thing that can clear the breaker — decides.

`crew pause <box>` keeps a member off: the host tick never starts it, a paused
box that is running is drained and stopped on the next tick and never counts
toward `FLEET_MAX_RUNNING`, and its own cron is commented while it runs. The
floor's pause button writes the same host marker, so the button and the verb
pause the same way. `crew resume <box>` undoes all of it; a box resumed while
it was stopped gets its cron back live when the tick starts it. `crew tick
--dry-run` prints every decision and changes nothing.
