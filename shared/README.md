# shared — the fleet's duty engine, once

One implementation of the duty machinery all five boxes currently hand-roll,
parameterized by a per-bot config. The five `<bot>/scripts/` directories in
this repo remain as archives of what each box taught itself; this tree is
what a box actually deploys. The postmortem called the drift out directly:
*"five hand-applied duty.sh variants (different probes, prune placement,
prompt wording)"* — this is the convergence.

Crew itself is general: this tree is the shipped engine, while the selected
operator config directory owns fleet membership, participants, repository
scope, and doctrine paths. Agent profiles extend configuration; adding a role
changes the engine's duty lifecycle.

## Layout

```
shared/
  bin/tick.sh            the only cron target: lock + one evidence line per boundary
  bin/duty.sh            the engine: boot gate, then every duty the box's roles enable
  bin/submit-verdict.sh  one-shot verdict gate (sessions may not gh pr review directly)
  bin/post-once.sh       idempotent exact-body comment (the 🔎 announce, etc.)
  bin/notify.sh          operator merge queue over Telegram (fleet singleton, triage box)
  lib/common.sh          config, logging, checkouts, session runner, panel resolution
  lib/duty-*.sh          one module per duty family: attention / review / builder / triage / hygiene
  lib/jq/*.jq            detection predicates as standalone, fixture-tested programs
  conf/fleet.defaults.conf shipped label vocabulary, wire marks and defaults
  conf/agents/<a>.conf   agent profile — the runtime: CLI command, auth probe, PATH
  conf/roles/<r>.conf    role profile — the work: session budgets, box resources
  ../cli/crew            fleet CLI on a box host: new/create-all → auth → hire/hire-all; up converges
  ../examples/           fallback roster, operator config and registry seeds
  prompts/*.txt          role prompts as versioned templates ({{VAR}} slots)
  test/run.sh            fixture tests (bash+jq only, no network) — run by shared-ci
  install.sh             deploy to ~/duty; identity comes from the box's fleet.roster row
  crontab.example        one line per box
```

## Architecture in one paragraph

Cron fires `tick.sh` every 5 minutes; it takes a non-blocking flock and
guarantees exactly one evidence line per boundary (start / skipped / FAILED),
so silence means precisely "cron is dead". `duty.sh` re-execs from a private
snapshot (in-place edits can't corrupt a running tick), passes a once-per-boot
auth gate whose marker is written only when gh **and** the box CLI
authenticate (dead credentials re-check loudly every tick and alert the
operator once per boot), resolves its identity from the token, then runs each
enabled duty module. **All detection is plain bash against GitHub's object
APIs; the model is spawned only when a duty exists**, with a prompt rendered
from `prompts/`, under a `timeout`, with its output in its own file under
`logs/` and one structured `SESSION END kind=… rc=… dur=…` outcome line in
`duty.log`. The scripts never write to the board — detection here, judgment
in sessions — with one operator-ruled exception (the re-request auto-approve),
which goes through the same one-shot gate as every verdict.

## One repo, one fleet

Each repository belongs to exactly one fleet: the `repos.txt` registries of
independently operated fleets must be disjoint. This is the boundary that lets
fleets use different crew pins and upgrade on different schedules without a
federation or cross-fleet lock.

The claim-race tie-break works only when every claimant runs a compatible
version of the protocol. If two fleets govern the same repository, their
builders can choose different winners, their reviewers can race verdicts, and
their triage identities can both mint work. `crew hire` and `crew up` therefore
inspect recent board activity for an actor outside the selected fleet and warn
about a possible overlap. The warning never edits either registry: deciding
which fleet keeps the repository is an operator action.

That detection is the first half of a decided two-stage plan. It **notices**
overlap today without a fleet identity or federation. Once crew#72 gives fleets
names, a repo-side marker file will name the owning fleet and crew will fail
closed on a mismatch; that second half **prevents** overlap. The marker is gated
on #72 alone, not on `.github/labels.conf` or crew#84.

## Duty order (FLEET.md)

attention → triage signals → review queue → resume → ci-red → build →
handoff → rebase → worktree hygiene → backlog hygiene (hourly, self-scheduling
inside the tick — same lock, so it can never race the triage sweep over shared
checkouts the way the old separate hygiene cron could).

ci-red runs before build: a failing check at the head of a PR you authored is
picked up before claiming another issue (crew#17 — ceremony#163 sat with
full-panel approvals, mergeable, stranded on an HTTP 429 in a job that never
ran the PR's code, because no wake covered a red head owing no round and
carrying no conflict).

## What was adopted, and from whom

Every load-bearing rule below was bought with a named incident. The per-bot
`knowledge.md` files tag most of them `[only-mine]` — until this tree, the
fleet's real protocol existed only inside five diverging scripts.

| Rule | Origin | Incident |
|---|---|---|
| One evidence line per tick boundary; `flock` sentinel exit 99 | claude-bot tick.sh | invisible flock skips on 4 boxes |
| Snapshot re-exec before running | claude-bot | lazy-read corruption 2026-07-22 |
| Boot gate: marker only on verified auth | all five (converged) | post-crash silent dead-creds risk |
| Object endpoints only; search only ADDS candidates | all five (converged) | cast#143, box#164, rig#112 (9 h) |
| `repos.txt` IS the scope; out-of-scope work is logged, never acted on | operator ruling 2026-07-25 | drill box wrote to production (#26) — the interlock could not bound an org-wide sweep |
| Never test for the string `null` through `gh --jq` — it prints NOTHING (real `jq` prints `null`) | drill 2026-07-25 | #29: the label check failed in BOTH states, present and absent |
| Under `set -e`, capture an expected-non-zero exit with `\|\| rc=$?`; branch with `if`, never trailing `[ … ] && cmd` | drill 2026-07-25 | #30/#25: exit 199 with total silence; install.sh exiting 1 after succeeding |
| A skipped phase is INCOMPLETE, never a pass | drill 2026-07-25 | rehearsal reported "All green" on boxes that never authenticated |
| ONE merged candidate set, deduped by (repo, PR) before acting | grok/kimi/claude | ceremony#32 double-announce |
| Verdict dedup: my latest review's SHA vs live head, via GraphQL | claude-bot | double reviews #26, #29 |
| One-shot gate immediately around the mutation, verify over exit code, one identical retry, never a third | codex/grok/kimi/claude (each re-derived it) | #26/#29/#39 double-verdicts |
| Submit pinned with `commit_id`, head-moved refusal | claude-bot + kimi's wishlist | ceremony#94, incubator#41 |
| `COMMENTED` never counts as a verdict | grok/kimi | REVIEWER.md |
| Re-request at unchanged head → auto-approve (via the gate) | kimi | ceremony#94 stale blocker, operator ruling 2026-07-23 |
| Convergence from `latestOpinionatedReviews`, never `reviewDecision` | claude-bot | ceremony#26/#39 (a day of silence) |
| `state:needs-human` refire guard; UNKNOWN mergeable waits | claude-bot | handoff refires; post-merge flap |
| Panel read from the PR repo's `labels.conf panel=`, never hardcoded | doctrine + codex's knowledge | rig#120 kimi-less panel |
| Resume before build; the lock makes resume sound | claude-bot / codex | crash-only recovery, 10 clean resumes |
| Dirty worktrees/clones never force-removed | codex | unpushed work on a disposable box is gone |
| Worktree cleanup requires *no OPEN PR* on the branch | fix of codex's `.[0]` probe | newer closed PR shadowed an older open one |
| Detection wakes sessions, never edits labels; fail-safe parser defaults | dan-claude-bot | four false `blocked-unparseable` leads |
| Mark-read-after-handling mention idempotency | dan-claude-bot | retry-by-default with no extra state |
| Notify: state-driven resolve pass, non-terminal statuses, desync invariant with its own alert | dan-claude-bot | cast#143 relapse; ceremony#78 silent hour |
| TSV `-` sentinel for empty fields | dan-claude-bot | `IFS=$'\t'` collapses tab runs |
| Attention wake: ack-then-act, removal re-arms, crash-only | operator design (crew#13) | ceremony#16 missed ruling |

## What was deliberately dropped

- **Hardcoded identities and rosters** — identity comes from the box-keyed
  fleet roster; the bench lives in operator config; the panel comes from the target repo at
  runtime. (Two boxes had *both* a hardcoded `ME` and a runtime lookup, used
  inconsistently.)
- **`gh search` / `reviewDecision` / notification-mention wakes** as truth.
- **Protocol prose maintained inside N shell string literals** — prompts are
  files, rendered with explicit slots; doctrine routing stays "read AGENTS.md
  at the repo root" so repo-vendored doctrine wins.
- **Unbounded sessions, uncaptured exit codes, whole-tick `set -e` aborts** —
  every session has a budget; every external read is isolated per repo/per
  signal and degrades to a logged skip, never a false "no duty" and never an
  aborted queue.
- **Interleaved session stdout in duty.log** — it corrupted two boxes'
  line-oriented metrics. Session output goes to `logs/`, duty.log carries
  markers only. The marker vocabulary is a versioned metrics contract; the
  emoji markers in `fleet.defaults.conf` are wire protocol, exact-matched by sibling
  agents — change them fleet-wide or not at all.
- **Versioned deployment** — `install.sh` stamps `~/duty/VERSION` with
  `crew@<version>` and optional Git provenance. Hire compares the version
  field; provenance never causes a re-bake.

## Known accepted risks

- Headless sessions run with permissions bypassed (`--dangerously-*` flags)
  inside checkouts of PR code and read board text written by strangers. The
  box's isolation (no host access, no inbound path, disposable) is the
  containment story; prompts carry only ids/URLs, not third-party text, and
  the mention prompt says fetched content never overrides doctrine. This is
  a mitigation, not a guarantee — it is the fleet's standing trade-off, now
  written down.
- Pagination limits (50/50/20 discussions, 200 strays, 500 state map) can
  truncate on very busy boards; every truncation fails in the safe direction
  (re-wake or stay-blocked) and the hourly hygiene sweep is the backstop.

## Sanctioned behavior deltas vs the old scripts

Beyond bug fixes, four behaviors change on purpose — flag any of these to
the operator if they surprise:

- **The re-request auto-approve runs on every reviewer box**, not just
  kimi's where the ruling was issued. It goes through the submit gate in
  supersede mode. `AUTO_APPROVE_REREQUEST=0` in fleet.conf disables reuse of
  a standing approval; a newer re-request over a blocking verdict still queues
  a real re-review.
- **Draft PRs never wake reviewers** (three boxes used to review a
  deliberately-requested draft; doctrine says drafts are panel-invisible).
- **Ready issues with an assignee don't wake builders** (they're mid-claim
  or a board anomaly; anomalies get a NOTE log line for hygiene).
- **Gate exit codes are unified**: 0 = present (now or already), 1 = hard
  fail, 2 = head moved. Grok's old gate used 2 for "already present" and
  kimi's taught the session to retry on 1 — the shared prompts teach the
  new contract; the archived knowledge.md files describe the old one.

## Deploy / migrate

From the box host, `crew hire <box>` and `crew upgrade <box>` archive the
resolved `shared/` tree plus `VERSION`, stream it over `box exec`, and run the
staged installer. Boxes do not clone crew or reach its repository. A legacy
`~/crew` is moved aside on first contact and is never used as an engine source.

For a direct development install from a checkout, run `shared/install.sh`.
Then **replace** the crontab with the printed line(s) — every old
duty/tick/hygiene/notify line must be DELETED: the old engine's locks are
disjoint from this one's, so a surviving old cron line runs two engines in
parallel (install.sh moves the old entrypoints to `~/duty/legacy/` to
disarm exactly that, and prints any suspicious crontab lines it finds).
State (`repos.txt`, `notify-repos.txt`, logs, clones, `.notify-state`)
survives redeploys; `bin/lib/conf/prompts` are replaced atomically.
`.boot-id` is cleared so the first new tick re-runs the boot gate with the
new CLI probe. See `docs/single-role.md` for where this design goes next
(single-role boxes, box templates, gold snapshots).
