# Duty-engine rehearsal — runbook for a fresh box and a fresh session

You are validating the shared duty engine on a real host, on a box that has
never run it. Read `shared/README.md` first (architecture + provenance), then
run the phases below IN ORDER. Everything before "Phase 2" needs NO
credentials — that is the point: the engine must behave correctly, loudly, and
harmlessly on a creds-free box.

The engine passes static verification in CI before it ever reaches a box.
Assume bugs anyway: a rehearsal exists because a real host answers questions no
fixture can. Anything you find is a finding, reported per Phase 3 — never
silently worked around.

> **Automated form.** `drill/rehearsal.sh` (run on the box HOST from a crew
> checkout) executes everything below mechanically — phase 1 always, phase 2
> automatically once the operator has logged the drill box in — printing
> ok/FAIL per check. This document remains the explainer for what each check
> means, and the manual path when no host is at hand.
>
> *Provenance, not an instruction: this runbook was written to validate the
> engine's original rollout on `heavy-duty/crew#16`, which merged long ago. A
> round today drills a ref you choose and reports where Phase 3 says — nothing
> in this document routes findings to that pull request or to any other fixed
> one.*

## Running a round

`drill/rehearsal.sh` drills ONE role on ONE box. `drill/rehearsal-all.sh` runs
all three in sequence and adds the legs that are the round's rather than a
role's. Prefer the latter for a release round; the former when you are chasing
one loop.

**One box, one role.** `--role triage|builder|reviewer` (default `reviewer`)
selects both the installed role and the box (`crew-drill-<role>`). The fleet
deploys single-role boxes (`fleet.roster`) and `duty.sh` gates every module on
`has_role`, so a single box carrying all three would exercise a composite path
nobody runs — and would hide the class of defect that let a reviewer box
quietly run triage sweeps for an entire rehearsal (`heavy-duty/crew#28`).

The three boxes may share ONE GitHub identity. That is safe **only** because
`repos.txt` is the scope for every module and each role gets its own sandbox:
disjoint registries, disjoint work. Under the previous org-wide review sweep
all three would have raced for the same verdicts.

That shared box identity must differ from the **host's** GitHub identity for
the `builder` and `reviewer` roles. GitHub does not let an owner fork its own
repository into itself, request a pull-request author as reviewer, or let that
author submit a review on the same pull request. Phase 2 therefore fails those
two roles before minting a fixture when the identities match. `triage` needs
neither a fork nor a review counterparty and remains valid with matching
identities.

`--agent <name>` (default `claude`) selects the runtime; the available agents
are the profiles under `shared/conf/agents/`. Pass it consistently —
`drill/rehearsal.sh --agent grok` derives the `grok-box` template, installer
agent, assertions, auth probe, and login hint from the grok profile, and
`rehearsal-all.sh` passes the same agent to the app phase so both readers probe
the vendor the boxes were actually installed as.

**Which boxes a drill looks at — never `fleet.roster`.** `crew hire`'s registry
guard keys on roster *membership*, so a drill box listed in the tracked
`fleet.roster` counts as a fleet member to every safety check — which is how
three leftover drill boxes came to be armed against the production registry
(`heavy-duty/crew#51`). So `drill/rehearsal-app.sh` takes its own:

```sh
drill/rehearsal-app.sh --drill-roles "triage builder reviewer"  # generated
drill/rehearsal-app.sh --roster ~/mine.roster.local             # hand-written
```

`--drill-roles` builds the list from the `crew-drill-<role>` convention
`rehearsal.sh` already owns, so it cannot drift from the boxes the drill
actually uses; prefer it. `--roster` is for anything else, and `*.roster.local`
is gitignored so such a file has a home. Both feed the SAME path to all three
readers — the collector (`CREW_FLOOR_ROSTER`), the `crew status` it compares
against (`CREW_ROSTER`), and its own counts. `rehearsal-all.sh` passes
`--drill-roles` for the roles whose drill actually reached a box, and announces
any narrowing rather than quietly covering less.

A round is real infrastructure — boxes and public sandbox repositories on the
operator's own host and account. What it creates, when reuse is legitimate and
what reuse costs phase 1, and what teardown will and will not delete, is
[`drills/README.md`](../../drills/README.md)'s round-lifecycle section; it is
not repeated here.

Every opt-out below is an **operator-requested exclusion**: the round still
records the leg, naming the flag as the reason it did not run. A run carrying
any of them does not cover that leg's contract.

| flag | drops |
|---|---|
| `--no-app` | the `app`, `browser` and `app-armed` legs |
| `--no-config-drill` | the operator-registry `config` leg |
| `--no-install-drill` | Section A, the `installer` leg |
| `--no-resume-drill` | the builder `resume` leg |
| `--no-attention-drill` | the builder `attention` leg |
| `--no-attention-audit-drill` | the triage `attention-audit` leg |
| `--no-hygiene-drill` | the worktree `hygiene` leg |
| `--no-breaker-drill` | the terminal-failure `breaker` leg |
| `--no-notify-drill` | the operator-notification `notify` leg |
| `--no-fleet-drill` | the fleet-lifecycle `fleet` leg |
| `--keep` | teardown: boxes and sandboxes are retained deliberately |

## Phase 0 — acquire the exact tree, then run static checks

```sh
git clone https://github.com/heavy-duty/crew ~/crew-host
cd ~/crew-host
drill/rehearsal.sh
```

The default invocation fetches `main` from
`https://github.com/heavy-duty/crew.git` on the host, creates a Git bundle,
and streams that bundle into the box. The box needs no GitHub credentials and
receives a real `.git` tree at the exact reported SHA. To rehearse against a
fork or any other tree, pass `--remote <git-url>` or set `CREW_DRILL_REMOTE`
rather than editing the clone above. Override acquisition explicitly when
needed:

```sh
drill/rehearsal.sh --remote <git-url> --ref <git-ref>
drill/rehearsal.sh --tree "$PWD"     # bundle this checkout's exact HEAD
```

`rehearsal-all.sh` resolves `--ref` to one commit ONCE for the whole round and
hands that commit to each role, so a branch moving mid-round cannot split one
record across three trees. The resolved commit is printed with the summary as
`drilled source:`; a release round should be drilled at a ref that cannot move
under it.

Phase 0 aborts before any fixture or installer check if the remote/ref cannot
resolve, if a supplied tree is not a Git checkout, or if `shared/install.sh`
or `shared/test/run.sh` is absent. It never continues from a stale `~/crew`.
Once acquired, these are the static checks run inside the box:

```sh
shared/test/run.sh                   # must end: failed 0
command -v shellcheck && shellcheck -x shared/bin/*.sh shared/lib/*.sh \
  shared/install.sh cli/crew shared/conf/fleet.defaults.conf examples/fleet.conf \
  shared/conf/agents/*.conf shared/conf/roles/*.conf
```

## Phase 1 — pre-auth engine validation (no logins anywhere)

Install as the default claude reviewer. The agent CLI may be absent in this
phase: its profile's auth probe then returns non-zero, which is the expected
unauthenticated result, and no session can launch:

```sh
shared/install.sh --agent claude --role reviewer
```

Verify, and record the output of each check:

1. `cat ~/duty/VERSION` — `crew@<sha>` matching `git rev-parse --short HEAD`.
2. `cat ~/duty/conf/instance.conf` — `BOT_AGENT=claude`, and `BOT_ROLES`
   equal to the `--role` under test (or the agent selected with `--agent`).
3. `crontab -l` — no duty tick line. The rehearsal never arms cron.
4. After each explicit `~/duty/bin/tick.sh`, `~/duty/duty.log` gains evidence:
   `duty run start` → a WARN that the login cannot be resolved →
   `duty run end`. EVERY invoked tick must produce lines; silence after
   invocation is a finding (that is the tick evidence contract).
5. `~/duty/boot-check.log` — one boot block, and the drill reads what that
   block SAID, not merely that it exists: the gate writes `cli probe: ok` or
   `cli probe: FAILED` from the drilled agent's own probe, and `FAILED` is
   CORRECT here. `~/duty/.boot-id` must NOT exist (marker only on verified
   auth). A box that stopped answering and a box with a clean boot log both
   read as an empty block, so the read's own exit status is checked before its
   contents.
6. Lock behavior: run `~/duty/bin/duty.sh` by hand twice —
   idle: it runs; concurrently with itself or a tick: the second prints
   "a tick already holds …" and exits 199.
7. Idempotence: rerun `shared/install.sh` **with the same
   `--agent`/`--role`** — it must keep the instance config and remain
   disarmed. `shared/install.sh --agent claude --role nosuchrole` must
   refuse.

   > Standing fleet installs resolve agent/role from the host-staged
   > `~/duty/fleet.roster` by box
   > name. This drill box is off-roster and is therefore reinstalled with its
   > explicit `--agent`/`--role`; a borrowed gh login cannot widen its role.

Repeat an explicit tick if needed. Expected steady state: three evidence lines
per tick, no growth in error variety, no session logs in `~/duty/logs/`, and
no board writes anywhere.
If the box is already authenticated when phase 1 begins, the rehearsal prints
three explicit `skip` rows for the unauthenticated WARN, boot-marker, and
no-session assertions. The summary counts those skips. A shorter authenticated
run is therefore visible as reduced coverage, never silently greener.

## Phase 2 — authenticated ticks (operator required)

STOP until the operator has decided the identity (one box per identity is
a fleet invariant). For the default claude runtime this includes the singleton
triage identity as well as builder/reviewer identities: never borrow any live
identity until its other box's cron is DISARMED. The same rule applies to every
agent. A throwaway test identity reuses Phase 1's explicit instance.conf;
login no longer selects a role. The operator performs `gh auth login` and the selected
agent profile's `AGENT_LOGIN_HINT`; you never handle credentials.

Authentication creates two independent hazards. First, another live box must
not run the same identity. Second, a normal engine registry points at production
repositories, so a drill tick can make legitimate-looking production writes.
The automated rehearsal therefore saves `repos.txt`, points it at nothing
before the first authenticated tick, replaces it with the sandbox alone before
phase 2, verifies that narrowing fail-closed, and restores the original on exit
or interruption.

**The operator's own account is a supported box identity.** Narrowing
`repos.txt` bounds review, build, triage and hygiene — every module that reads
`REPOS_FILE` — and since crew#66 it bounds the `attention` wake too, whose query
is cross-repo while its action is not. So a parked `attention` demand in some
other repository is not a reason to refuse a round, and the drill does not clear
it, does not ask for it to be cleared, and does not want a second identity whose
only qualification is carrying no work. Before the first authenticated tick the
rehearsal **records** those demands as a census row (`attention census: N
demand(s) parked outside <sandbox>`, then one `census:` line each).

The census's window is the wake's own, deliberately: the single unpaginated
`per_page=100` page of `/issues?filter=assigned` that `duty_attention` itself
reads, and no wider. The assertion below holds the engine to a record it
derives from exactly that page, so a demand past it is one no correct engine
can have seen, and recording it would red a correct round. For the same reason
the census is taken **after** the sandbox's own drill demand is minted: that
endpoint answers newest first, so minting an issue displaces the oldest demand
off the page the tick will fetch. The label it asks for is the box's own
effective `LABEL_ATTENTION` and not the literal `attention`, because an
operator `fleet.conf` can move that name and the wake would then be fetching a
different set from the census — the `MARK_PICKUP` the pickup assertion counts
is read from the same call and deliberately does *not* take such an override,
because the loader restores the six board marks over any operator file.

After the attention tick the rehearsal **asserts** the bound, per demand that
census recorded: the engine's own
suppressed report names it (`attention: outside repos.txt` in `duty.log`, or the
`~/duty/.suppressed-attention-scope` set that same call leaves behind), no
`SESSION START kind=attention` names a repository other than the sandbox, and
the demand drew no new `📌 picked up` comment across the tick. Any miss is a
`FAIL` row and the round stops there rather than ticking again — which is the
independent verification the old refusal claimed to be, made real, and on the
one fixture the drill could never mint for itself. An identity carrying no
outside demand reports `0` and asserts nothing, exactly as before.

Those `duty.log` reads are bounded by a line count **and** the generation it
was counted against, because `tick.sh` rotates `duty.log` to `duty.log.1` at
5 MiB before a run appends to it — a threshold a reused drill box reaches. When
the file moved under the round, the slice spans the tail of the rotated
generation and all of the new one; when the generation the census counted is on
neither file, the round stops on that fact rather than grading an absence in a
log it could not bound. A generation is identified by its inode **and** a
checksum of the lines the census counted, because an inode is a slot and not an
identity: the kernel re-issues it to the next file created, so a box that
rotated twice, was rebuilt, or had its log truncated in place would otherwise
present a brand-new `duty.log` wearing the counted generation's number and the
slice would read past the end of it. Those all land on `lost`, and the round
stops.

A read that **fails** is a third answer again, and neither of the other two. A
`duty.log` that is there and will not open — a rebuilt box, a mount that went
away, a file some other pass left unreadable — is not a log of length zero and
not a generation that is gone: it is a file nothing can be concluded from, and
one that cannot be ruled out as the counted generation either. The census
refuses to be taken on it, and a log that stops reading mid-round reds the
bounding row and stops there. That distinction is what keeps the negative
assertions honest: "no attention session was launched outside the sandbox" and
"the box could not be read" are the same empty slice, and only one of them is
evidence. An unreadable `duty.log.1` beside a generation the census identified
by reading it costs the round nothing, because that file is not where this
round's lines are.

The rehearsal deliberately does **not** arm cron. Every drill tick is explicit;
the old scheduled-boundary check was not worth creating an autonomous agent
that could outlive the invoking shell. On every exit the cleanup path removes
any duty tick left by an older run and restores the registry. If the shell or
box is in doubt, `box down <box>` is the reliable stop: `pkill` routed through
`box exec` is unprivileged and may be unable to signal an already-running
session.

The loops below are gated on `has_role`, so each box proves only its own.
`drill/rehearsal-all.sh` covers all three; a single `--role` run leaves the
other two loops **unproven, not passing** — read the per-role summaries, not
just the driver's final line.

| role | fixture the drill creates | what must happen |
|---|---|---|
| triage | an open issue carrying **no** queue label (a "stray") | a ruling comment, and the issue lands in exactly one of ready/claimed/blocked/epic; a re-tick adds no second ruling |
| builder | an issue labelled `ready` and **unassigned** | a `build/*` PR authored by the identity, referencing the issue; the issue leaves `ready`; a re-tick opens no duplicate |
| reviewer | a PR with the identity as requested reviewer | `🔎 reviewing head <sha>` before a verdict pinned to that head, dedup on re-tick, a re-request queuing a real re-review with the auto-approval off, re-request auto-approve with it on, and the one-shot gates |

> The builder fixture must be **unassigned**. `ready` + assigned is
> deliberately not pickable — an assignee means mid-claim, and counting
> those launched sessions with nothing to do. An assigned fixture makes the
> builder correctly ignore it, and the drill would then blame the engine
> for the fixture's mistake.

1. First authenticated tick: boot gate passes, `~/duty/.boot-id` appears,
   the login-resolution WARN disappears, review sweep logs
   `review: no outstanding review requests anywhere` (if true).
2. Attention drill: have the operator assign a test issue to the identity
   and add the `attention` label. Next tick: pickup session launches
   (`SESSION START kind=attention`), posts `📌 picked up`, REMOVES the
   label, then acts. Verify the session log in `~/duty/logs/`, and that
   the next tick logs `attention: none`. What that wake DISPATCHED, rather
   than merely acknowledged, is the `attention` leg below.
3. Review drill: a scratch PR in a sandbox repo with a review request to
   the identity. Expect in order: candidate in the sweep log; the
   `🔎 reviewing head <full-sha>` comment posted exactly once (via
   post-once.sh) and before the verdict by GitHub's `created_at` and
   `submitted_at` timestamps; a verdict submitted via submit-verdict.sh pinned
   to that head; next tick adds no second announce and no second verdict. (It logs
   no `already covers head` skip either — `requested_reviewers` self-clears
   on submit, so a reviewed PR is not a candidate at all.)
4. Re-request rule, auto-approval OFF: append `AUTO_APPROVE_REREQUEST=0` to
   the box's `instance.conf` and re-request at the UNCHANGED head. Next
   tick must queue a **real** re-review — the verdict count grows — and it
   must NOT be the supersede path (no `re-request rule` in the body). The
   flag disables the auto-APPROVAL and nothing else (#151); it is not a
   switch for consulting the re-request. Remove the line afterwards.
5. Re-request drill: re-request review at the UNCHANGED head. Next tick
   must auto-approve through the gate (`--supersede-own`), log it, and the
   tick after must be quiet again.
6. Gate abuse: run `~/duty/bin/submit-verdict.sh` by hand with the same
   args as the landed verdict — must exit 0 "already present" WITHOUT a
   second review appearing on the PR. A short SHA must be refused.
7. Timeout: nothing to force here, but confirm every SESSION END line
   carries rc= and dur=.
8. Teardown: `repos.txt` is restored to its pre-drill contents and
   `crontab -l` contains no duty tick.

## The legs

A **leg** is an independently runnable part of a round with its own verdict in
the summary. `drill/rehearsal-all.sh` declares them in one list, and the round
checks its own record against that list before printing it: a leg declared
without a wired result, or a result naming no declared leg, is itself a red
row. So the record answers "did this leg run?" without anyone diffing the tree
against it.

The declared legs are: `hygiene`, `breaker`, `resume`, `attention`,
`attention-audit`, `notify`, `installer`, `config`, `app`, `browser`,
`app-armed`, `fleet`, `teardown`. Each has an entry below, headed by its row name —
that heading IS the leg's name, and CI diffs the set of them against the
harness's own declaration in both directions, so this runbook cannot fall a
release behind the harness again without a red check.

The `triage`, `builder` and `reviewer` rows beside them are round
*participants*, not legs: they carry a whole role's phase-2 verdict, and the
per-role summaries above are where you read them.

Every leg's row is one of exactly three readings, and the round prints the
reading as well as the detail:

- **executed** — `ok` or `FAIL`. The leg ran and reached a verdict.
- **not executed, with a named reason** — `skip` (an operator flag),
  `SKIPPED` (a prerequisite the round itself failed to produce), or
  `INCOMPLETE` (a blocker discovered on this host). A named exclusion is
  evidence.
- **not executed, reason missing** — a defect in the harness, and it reds the
  round.

Each entry below states what the leg needs, what it produces, and what a
failure means. None of them is an implementation description; read the script
named in the heading for that.

### hygiene — `drill/rehearsal-hygiene.sh`

Worktree preservation: a dirty merged worktree is pushed to a remote `wip/`
ref and recorded upstream BEFORE the janitor's forced removal, and a
preservation that fails retains the worktree and reports it once.

- **Needs** a box that reached phase 2, and a remote the box can push the
  preserved ref to. It runs after the role-specific phase-2 block, in every
  role.
- **Produces** the `hygiene` row: `ok (preservation + refusal)`, `FAIL`,
  `INCOMPLETE (no role reached a box)` or `INCOMPLETE (phase 2 skipped)`, or
  `skip (--no-hygiene-drill)`.
- **A failure means** the janitor can delete an agent's uncommitted work with
  no recoverable copy and no upstream record of where it went — the one
  destructive act the engine performs unattended.

### breaker — `drill/rehearsal-breaker.sh`

The terminal-failure lane breaker: dispatch stays live below the installed
threshold, the lane trips once at it, following ticks skip the stopped lane,
exactly one operator alert is emitted while stopped, and a later tick recovers
without hand intervention.

- **Needs** phase 2, and an agent profile that defines both
  `bot_session_terminal` and `bot_session_acted`. It reads
  `SESSION_TERMINAL_THRESHOLD` off the installed config rather than carrying
  its own number, so an engine change moves the assertion with the engine. It
  reads the lane's label the same way — the box's own effective
  `LABEL_ATTENTION`, not the literal `attention` — because that is the name
  `duty_attention` fetches, and a lane armed under any other one is unarmed.
- **Produces** the `breaker` row: `ok (trip + single alert + recovery)`,
  `FAIL`, `INCOMPLETE (<agent> profile missing bot_session_terminal)` or
  another named blocker, or `skip (--no-breaker-drill)`.
- **A failure means** a vendor outage either burns the whole quota re-launching
  doomed sessions, or alerts the operator repeatedly, or never recovers.

A profile that declares no terminal classifier is a **skip with a name**, not a
failed assertion: the breaker has nothing to trip on such a profile, and the
round says which profile and which hook rather than reporting an absence.

**The leg grades only what it confirmed.** Two things it asks the box for can
succeed while delivering nothing, and both put red rows against a working
engine when they are taken at their word:

- Labelling the fixture issue. A label request against a **closed** issue
  returns success and arms nothing, because `duty_attention` only considers
  open ones. The leg therefore re-reads the issue after arming and asserts it
  is open and carries the label; a fixture an earlier leg closed is reopened
  first, and a re-read that does not hold reds the arming row and prints what
  it read (`state=… labels=…`) so the operator lands on the harness rather
  than on the engine.
- Firing a tick. A tick refused by a lock the previous run still holds logs one
  line and exits immediately, so a leg firing them back to back spends its
  whole budget in seconds and grades slices describing ticks that never
  executed. Those slices are not lane evidence in either direction.

  The leg therefore reads `tick.sh`'s own evidence contract — exactly one line
  per boundary, `duty run start`, `tick skipped:` or `tick FAILED:` — and
  grades a slice only when it carries the **positive** mark. Absence of the
  lock-skip line is not evidence that a tick ran: a `box exec` that never
  landed leaves an empty slice, which reads the same way. The box reads that
  bound the slice are graded too, because a failed `wc -l` would otherwise make
  the slice the whole log and the leg would grade a previous tick's lines.

  A held lock is waited out and re-fired within a bound. The rest are reported
  once, against the tick rather than against the lane:

  | reading | row |
  | --- | --- |
  | every try inside the bound refused | `INCOMPLETE (<what> never ran: N ticks refused by a held lock)` |
  | the tick wrote no evidence line | `INCOMPLETE (<what> never ran: the tick wrote no evidence line (tick.sh rc N))` |
  | the tick logged `FAILED` | `INCOMPLETE (<what> never ran: the tick logged FAILED (tick.sh rc N))` |
  | the log could not be measured or read back | `INCOMPLETE (<what> never ran: the box's duty.log could not be measured / read back)` |

### resume — `drill/rehearsal-resume.sh`

The builder resume lane: a settled check conclusion wakes a parked builder, an
unrendered round-signal marker warns and wakes on the next tick, and
consecutive unchanged zero-action attempts stop the lane.

- **Needs** `builder` in `--roles`, and that box's phase 2. It reads the
  installed zero-action threshold out of the box's own `duty-builder.sh`.
- **Produces** the `resume` row: `ok (wake + zero-action stop)`, `FAIL`,
  `INCOMPLETE (builder role omitted)`, `INCOMPLETE (builder phase 2 never
  reached the leg)`, `INCOMPLETE (leg skipped: <reason>)`, or
  `skip (--no-resume-drill)`.
- **A failure means** builder PRs park forever waiting for a wake that never
  comes, or a builder that can do nothing loops on the same head indefinitely.

The leg writes its own verdict rather than riding the builder role's exit code,
which also covers every other builder assertion and can classify neither
outcome of this one.

### attention — `drill/rehearsal-attention.sh`

The attention wake's two behaviours that an acknowledgement cannot show:
dispatch WITHOUT code — a wake on a claim with no open PR records the next
build step, unassigns itself and swaps `claimed` to `ready` while creating no
branch, commit or PR — and the timed-out pickup report, one ⏱️ comment naming a
stable log link, planted beside the immutable run log, with one operator alert.

- **Needs** `builder` in `--roles` and that box's phase 2. It files its own
  fixture, whose demand asks for build work; the round's role-level wake
  fixture forbids opening PRs and so cannot tell a correct dispatch from mere
  obedience to a prompt.
- **Produces** the `attention` row: `ok (dispatch without code + timeout
  report)`, `FAIL`, the same three `INCOMPLETE` shapes as `resume`, or
  `skip (--no-attention-drill)`.
- **A failure means** an operator's `attention` either does work it was told
  not to do, or times out leaving nothing an operator can follow to the log.

### attention-audit — `drill/rehearsal-attention-audit.sh`

The triage-only hygiene-slot board audit: it reports BOTH malformed shapes —
`attention` on a pull request, and `attention` on an unassigned issue — it
never repairs them, and it alerts on transition only (🚨 when the malformed set
becomes non-empty, ✅ when it clears, silence in between).

- **Needs** `triage` in `--roles` and that box's phase 2. Its two fixtures are
  invisible to the wake's own `filter=assigned` query, by construction: neither
  can wake a session, so the leg cannot go green on a board the wake was
  quietly clearing behind it.
- **Produces** the `attention-audit` row: `ok (both shapes reported, not
  repaired, alerts on transition)`, `FAIL`, `INCOMPLETE (triage role omitted)`,
  `INCOMPLETE (triage phase 2 never reached the leg)`, `INCOMPLETE (leg
  skipped: <reason>)`, or `skip (--no-attention-audit-drill)`.
- **A failure means** a misplaced `attention` — the incident this audit exists
  for — is either invisible to the operator, or worse, silently "repaired" by
  a sweep that is not allowed to move labels.

### notify — `drill/rehearsal-notify.sh`

The operator's watch set is `repos.txt` ∪ `notify-repos.txt`, asserted in BOTH
directions on one notify run, with the WORK set left untouched: `repos.txt` is
re-read after `notify-repos.txt` is written and the round aborts if it moved.

- **Needs** a reachable operator channel on the host, and phase 2. It runs
  inside every role's phase 2, so its verdict is the ROUND's, folded across the
  roles that wrote one — not any single role's.
- **Produces** the `notify` row: `ok (repos.txt + notify-repos.txt union)`,
  `FAIL`, `INCOMPLETE (leg skipped: operator channel unreachable: <channel>
  — union UNPROVEN)`, `INCOMPLETE (no role reached a box — union UNPROVEN)`,
  or `skip (--no-notify-drill)`.
- **A failure means** half the operator's watch set goes silent. The regression
  this leg exists for is invisible by construction — its only evidence is a
  notification that did not arrive — and asserting the `notify-repos.txt` half
  alone passes the exact bug that dropped the work list.

### installer — `drill/install-drill.sh`

Section A: the observations a CI harness cannot make because they need a real
box — switch skew, hire/skip from a git-less install, no box-side crew
repository, full-uninstall refusal, and engine survival after the console is
removed. It also builds a real offline artifact and installs it, measures what
every tree it installs actually holds (`drill/install-payload.sh`), and proves
the engine outlives its console across a real cron boundary
(`drill/install-survival.sh`).

- **Needs** a box the role rehearsal already installed — it borrows one and
  gives it back unchanged, so its hires are version events and never identity
  events. The payload measurement needs the real installs and the real unpack
  this driver performs; it reads both the excluded roots and the size bound out
  of the tree under drill rather than carrying its own copy of either.
- **Produces** the `installer` row: `ok (Section A record emitted)`, `FAIL`,
  `SKIPPED (blocked by role install: no installed drill box)`, or
  `skip (--no-install-drill)`.
- **A failure means** either a real-host install path is broken in a way the
  offline suites cannot see, or the installed tree has grown past its budget —
  a regression that is silent per box and per `crew upgrade`.

Step 9's survival wait is measured from the moment the console removal
RETURNED, not from the pre-removal read: a cron boundary striking while the
uninstall runs writes a line that proves nothing.

### config — `drill/rehearsal-config.sh`

Operator-registry convergence against one REAL box: the fixture is built with
`crew init`, `CONFIG_IS_OPERATOR=1` is asserted, and real `crew upgrade` calls
are driven through the divergence veto, both no-provenance migration outcomes,
ordinary convergence, examples-fallback non-convergence, and incomplete-trio
refusal.

- **Needs** one installed drill box — the same box Section A used, on purpose,
  since a leg that named its own role would re-role it and the engine would
  warn `ROLES CHANGED` and install anyway. It backs up both `repos.txt` and its
  provenance record before the first mutation.
- **Produces** the `config` row: `ok (operator mode + registry contract)`,
  `FAIL`, `SKIPPED (blocked by role install: no installed drill box)`, or
  `skip (--no-config-drill)`; and a restoration receipt, printed on
  EXIT/INT/TERM.
- **A failure means** an operator's registry can diverge, migrate wrongly, or
  be overwritten by a convergence that should have refused. A `--no-config-drill`
  run does not cover the operator registry contract at all.

### app — `drill/rehearsal-app.sh`

The fleet console against the real boxes on this host: the collector is started
against the round's own roster, `crew status` is read against the same list,
and every box's floor view is classified against its CLI line. The seven
operator surfaces the `0.1.2` wave shipped are asserted here
(`drill/rehearsal-app-surfaces.sh`), each taking its subject as an argument so
the same assertions can be driven red in CI without a host.

- **Needs** at least one role whose drill reached a box, so there is a
  generated member to compare. Read-only by default; the narrowed control block
  is opt-in (`--app-allow-control`) and touches only named boxes.
- **Produces** the `app` row: `ok (agreement compared; collector + page)`,
  `ok (agreement could-not-compare; armed comparison follows)` when an
  `--app-roster` pass will supply the reading instead,
  `INCOMPLETE (agreement could-not-compare: no armed, ticking, clock-skewed
  box)`, `FAIL`, `SKIPPED (generated pass blocked by role install: no installed
  drill box)`, or `skip (--no-app)`.
- **A failure means** the console and the CLI disagree about the same fleet —
  the surface an operator actually looks at to decide the fleet is healthy is
  lying to them.

A round's own drill boxes are freshly created and not armed, so the agreement
reading a drill can reach is bounded by what those boxes are. That is what the
`app-armed` leg below is for.

### browser — the read-only page walk

The page halves of the console's surfaces, read off a rendered floor
(`fleet-floor/test/browser.js`, with `drill/rehearsal-page-read.js` reading the
`0.1.2` page surfaces). An API-only pass is the wrong verdict: the payload can
carry a version and a verdict the page drops.

- **Needs** `playwright-core` *and* a browser — `playwright-core` deliberately
  ships without one. The drill probes the usual Chrome/Chromium paths and skips
  with a named reason if it finds none; `PW_CHROME=/path/to/chrome` overrides.
  Screenshots land in `.drill-shots/` — `--app-shots <dir>` through
  `rehearsal-all.sh`, `--shots <dir>` when running `rehearsal-app.sh` directly
  — and outlive the run. To watch it drive: `FLOOR_TEST_HEADED=1`, optionally
  with `FLOOR_TEST_SLOWMO=250`.
- **Produces** the `browser` row: `ok (read-only browser walk executed)`,
  `FAIL (browser walk executed and failed)`, `INCOMPLETE (not executed:
  playwright-core not installed …)` or `INCOMPLETE (not executed: no browser
  found …)`, `SKIPPED (generated pass blocked by role install …)`, or
  `skip (--no-app)`.
- **A failure means** the rendered page disagrees with the payload behind it —
  a surface that reads correct over the API and wrong to the human.

The walk is read-only ALWAYS, even under `--app-allow-control`: it picks its
targets by screen position and its `wake-silent` click is fleet-wide, so it
cannot be bound to `--app-boxes` and is never the thing that exercises a
control.

### app-armed — the named-roster comparison

A second, comparison-only agreement pass over a roster the operator names, and
never a replacement for the generated pass above. It is the reading that needs
a box the round did not create: armed, ticking, and far enough along to be
clock-comparable.

- **Needs** `--app-roster <path>` naming a roster with such a member. It runs
  `--no-browser`: repeating the walk would spend a second one and could mutate
  the member this pass exists only to read. It remains readable even when no
  role reached a generated member, so a role-install failure cannot silently
  suppress independent evidence.
- **Produces** the `app-armed` row: `ok (agreement compared; named roster, no
  additional boxes)`, `INCOMPLETE (agreement could-not-compare: no armed,
  ticking, clock-skewed box)`, `FAIL`, `skip (not requested: no --app-roster;
  requires an armed member)`, or `skip (--no-app)`.
- **A failure means** the console misreads a box that is genuinely working —
  the case the drill's own fresh boxes cannot present.

### fleet — `drill/rehearsal-fleet.sh`

The three fleet-lifecycle verbs — `crew restart --all`, `crew down`,
`crew reset --cut --all` — plus a restore and a canary-first `crew upgrade`,
driven over the round's own roster with **a per-box outcome for every member**.
It is role-independent: what `--all`, a per-box outcome and a busy-skip need is
a roster, which a round has by the end of phase 2 whatever roles it ran, and
which the single-box `config` leg deliberately does not carry.

It runs **last of the independent phases, immediately before teardown**, and
that ordering is load-bearing. This is the only leg that stops boxes, cuts
snapshots and rolls one back; running it earlier would hand the app phase a
fleet that is half down.

- **Needs** at least one role to have reached a box, and **two** for the
  busy-box readings: one box is held busy by a real `flock` on the real duty
  lock — the same path a duty tick takes and the one `drain_probe()` reads — so
  the skip is exercised rather than assumed. It builds its own operator trio
  with a real `crew init` and `CREW_EXPECT_OPERATOR_CONFIG=1`, and it refuses
  any target that is not a `crew-drill-*` box.
- **Produces** the `fleet` row: `ok (per-box outcomes on restart/down/cut +
  restore and canary-first upgrade)`, `INCOMPLETE (leg skipped a reading: …)`,
  `INCOMPLETE (the leg reached no case — per-box outcomes UNPROVEN)`,
  `FAIL (…)`, `SKIPPED (blocked by role install: no installed drill box)`, or
  `skip (--no-fleet-drill)`.
- **Every verdict is read from per-box OUTPUT and none from an exit code.** The
  three verbs return one number for a whole roster: three boxes cycled and three
  boxes skipped are distinguishable in the text and not in the rc. The
  classifiers are in `drill/fleet-lifecycle.sh`, and the fixture suite executes
  them rather than grepping the leg's source.
- **A failure means** a lifecycle verb does not do across a roster what a single
  operator reading suggested it did — a box it never named, a busy box it
  cycled anyway, a refusal that reported a percentage and not what to clear, or
  a restore that quietly landed on `bootstrapped` instead of `armed`.
- **What it does NOT claim.** The fleet-identity half: seven real boxes with
  weeks of accreted state, real `gh` credentials and real vendor logins. A
  restore on a box hired ninety minutes ago proves the restore *path*; it does
  not prove a production reviewer comes back without a re-login. That reading
  is the operator's, on the release candidate's own gate.

### teardown — `drill/teardown.sh`

A green round removes what it created: the `crew-drill-<role>` boxes and the
`<host-gh-identity>/crew-drill-<role>` sandbox repositories, and nothing else
on the host, ever. It names every target with its creation date, asks once, and
is idempotent.

- **Needs** the whole round's verdict, so it runs after every other leg. It
  needs a `gh` identity, a `box` CLI, and readable `box list --json` to
  *inspect*; a class it cannot inspect is not a class it can report clean.
- **Produces** the `teardown` row: `ok (boxes and sandbox repos removed)`,
  `INCOMPLETE (part of the round could NOT be inspected — it may still stand)`,
  `FAIL (the round PASSED — this is cleanup, not the drill)`,
  `kept (round not green — boxes LEFT STANDING to inspect)`, or
  `keep (--keep: boxes and sandbox repos RETAINED)`.
- **A failure means** either the host is not clean and nobody knows which half,
  or — the `FAIL` row — the round itself passed and only the cleanup broke. The
  two are deliberately different rows.

A round that did not pass keeps its boxes, and so does `INCOMPLETE`: a failed
leg is exactly the case where you need the box standing to find out why. The
run prints the teardown command when anything remains. `drills/README.md`
carries teardown's refusal rules and its exit-status table in full.

## When a leg cannot run

Every declared leg reaches the record in one of the three readings above, and
a round is expected to carry some not-executed rows — several legs need a
prerequisite a given host does not have. What is NOT acceptable is a leg
missing from the record, or one whose absence carries no reason.

Read the round's `## declared leg states:` block first, before the detailed
verdicts: it is generated from the same rows, so the two cannot disagree, and
it is where a leg that never ran is visible without anyone comparing the tree
against the record.

Legs that a round on a bare host commonly cannot reach, and what each is
waiting for:

| leg | blocker | what supplies it |
|---|---|---|
| `notify` | the operator channel is unreachable from the host | operator credentials for the channel; without them the union is UNPROVEN, not passing |
| `breaker` | the drilled agent profile declares no `bot_session_terminal` | a profile that classifies terminal vendor output; `shared/conf/agents/` says which do |
| `breaker` | every tick it fired was refused by a lock a previous run still holds | a box whose duty lock is free — `~/duty/duty.log` names the holder, and a lock outliving its owner is its own defect |
| `browser` | `playwright-core` absent, or no browser found | `npm i --no-save playwright-core`, and Chrome/Chromium or `PW_CHROME` |
| `app-armed` | no `--app-roster`, or no armed, ticking member on it | a roster naming a real armed box — a drill's own fresh boxes are not one |
| `resume`, `attention` | the builder role was not in `--roles`, or its phase 2 never ran | a builder box that reaches phase 2 |
| `attention-audit` | the triage role was not in `--roles`, or its phase 2 never ran | a triage box that reaches phase 2 |
| `installer`, `config`, `app` | no role install produced a box to borrow | a role drill that reaches an installed box |
| `fleet` | fewer than two roles reached a box, or nothing was refused, so a reading could not be taken | a round drilling at least two roles; the busy-box and refusal readings are INCOMPLETE, never passing, when they could not be taken |

The record, not this table, is what a release is evidenced on: a round writes
its own reasons, and `drills/<version>.md` keeps them. If a leg has never
executed at any head, that is a finding about the harness and belongs on the
board as its own issue — a leg that has never run is not a harness, it is a
script that compiles.

### What the `0.1.2` wave added

This runbook was a release behind its harness, and this section is the catch-up
census. Measured against the tree at the tag rather than from the pull requests
that landed there:

```sh
git diff --name-status 0.1.1 0.1.2 -- drill/
```

Fifteen files arrived under `drill/`. Seven of them are legs with a row of
their own that did not exist at `0.1.1` — `hygiene`, `breaker`, `resume`,
`attention`, `attention-audit`, `notify` and `teardown`. Four more are blocks
inside legs that already existed: the installed-payload measurement and step
9's survival predicate under `installer`, the seven operator surfaces under
`app`, and the boot-check assertions in phase 1. The page reader the browser
walk uses arrived with them. The remaining files are sourced helpers with no
leg of their own — the verdict recorder, the fixture loaders and the
review-ordering predicate — and are documented through the legs that call them.

The `browser` and `app-armed` rows are NOT `0.1.2`'s: both were added in the
`0.1.3` window, when the round's record began enumerating declared legs rather
than only executed ones. They are documented above as part of the harness this
runbook now describes, which is the harness after this window's drill repairs
and not the one the tag shipped.

## Phase 3 — report

A round's findings go where the round says. `rehearsal-all.sh` and
`rehearsal.sh` derive the report target from the ref the operator actually
drilled: a round drilled at a pull ref names that pull request in its exit
footer, and a round drilled at a branch, a tag, a bare commit or a local tree
has no pull request to name and prints no routing instruction at all. Where the
footer names nothing, the surface is yours to choose — the issue the round is
evidencing, the release issue for a release round, or the discussion the work
came from. No instruction is better than a wrong one, and a runbook that
printed a literal number would be the same defect in prose.

Report: which phases ran, every deviation from the expectations above (with the
`~/duty/duty.log` and session-log excerpts), and what you changed. Fixes carry
the finding as provenance. If all of Phase 1 and 2 pass, say so explicitly —
and say which legs did NOT execute and why, because a record that lists no
failures reads as "nothing broke". The round's own `## declared leg states:`
block is the list to copy.

For a release round, the record is a file: `drills/<version>.md`, one per
version, and `drills/README.md` states what it must contain and what the
`drill-recorded` guard requires of it.
