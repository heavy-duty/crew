# Drill records

Per-release evidence for crew's duty-engine rehearsal. **One file per
version**, named for the version exactly as `VERSION` carries it:

    drills/<version>.md

So `0.1.0` is recorded in `drills/0.1.0.md`, and `0.1.0-rc1` in
`drills/0.1.0-rc1.md`. They are different files, which is the whole point: the
filesystem does the whole-version comparison, so a record for a candidate can
never be mistaken for evidence for the final.

The directory is `drills/`, not `.drills/` — a dot-directory is invisible to
any glob without `dotglob`, which is how the fleet's siblings shipped releases
with records a sweep could not see.

**This directory is the record, not the instrument.** The instrument is
[`drill/rehearsal.sh`](../drill/rehearsal.sh) and its companions
(`rehearsal-all.sh`, `rehearsal-app.sh`, `rehearsal-config.sh`,
`rehearsal-safety.sh`): they install the engine in a drill box on a real host
and exercise the duty lifecycle end to end. crew does not reach into another
repo's harness to decide whether crew may ship — a cross-repo lookup that fails
silently degrades to "pass". The gate reads a file in this repo, and nothing
else.

## What the gate requires

The `drill-recorded` guard (heavy-duty/ceremony's action, pinned through
`.github/workflows/release.yml`) runs on every PR. On a `-dev` tree it asserts
nothing — a development tree has no release to evidence. On a bare `VERSION` — a
release ceremony tree — it requires `drills/<version>.md` to exist and to hold
at least one non-whitespace character. An empty file, or one of only spaces and
tabs, is not a record.

The guard requires a **record**, not a passing result. A maintainer waiver is a
legitimate outcome of a release — but it is written in that version's file, so
that skipping the drill is a deliberate, reviewable commit rather than a
silence. **A failed drill is still a valid record**: the gate wants evidence,
not success.

Every declared leg must appear in the round summary as either executed or not
executed with a named reason. The declared-leg inventory in
`drill/rehearsal-all.sh` is checked against the detailed summary at runtime;
adding a leg without wiring one result, or wiring a result without declaring
the leg, makes the mismatch a red record row. An operator-requested exclusion
names its flag, while a discovered blocker names the missing prerequisite. A
leg must never be absent from the record. The selected triage, builder and
reviewer rows describe round participants rather than independently runnable
legs, so they remain in the detailed summary outside this inventory.

## The rc ladder

**A release candidate carries its own drill record.** The ladder is
[`.ceremony/RELEASES.md`](../.ceremony/RELEASES.md)'s, adopted here and not
varied from: `X.Y.Z-dev` → `X.Y.Z-rc1` → `X.Y.Z-rc2-dev` → `X.Y.Z-rc2` → … →
`X.Y.Z`. Each candidate is a tag-only cut whose ceremony PR changes `VERSION`
to the bare `X.Y.Z-rcN` and adds `drills/X.Y.Z-rcN.md`, leaving `CHANGELOG.md`
and every fragment untouched; the doors publish it with `--prerelease` and the
merge door re-arms `main` as `X.Y.Z-rc(N+1)-dev`. One file per version is the
rule stated at the top of this file, and it is what makes the ladder cost
nothing to gate: `drills/0.9.0-rc1.md` and `drills/0.9.0.md` are different
paths, so `drill-recorded` asks the same question of a candidate that it asks
of a final and needs no rc-specific case.

**What the ladder buys is downstream.** A long window otherwise re-drills at
every rebase, because the drilled tree moves under the record. Drill the
candidate once, publish it as a tag, and the final's evidence anchors to an
immutable published ref instead of to a tree that has since changed.

**What it does not buy, stated so this is not read as more than it is:**
`drill-recorded` gates the rc PR, so `drills/X.Y.Z-rc1.md` must exist and hold a
record before the merge that creates the `X.Y.Z-rc1` tag. The ladder does not
move that gate one commit earlier or later.

**What the gate demands before that merge is the RECORD, not the ROUND**, and
this paragraph used to conflate the two — it read *"the first rc round still
drills a mutable candidate"*, which is a true premise with a false inference
hanging off it. The premise is the one stated at the top of this file: *"The
guard requires a **record**, not a passing result."* So a candidate's record can
say what the tree is and what reading it is owed, and the round runs **after the
merge, against the published `X.Y.Z-rcN` tag**, its readings appended to the
same file before the promotion. Three things make the tag the right ref rather
than merely an allowed one:

- **The candidate is what the fleet can install.** The readings that gate a
  promotion — a fleet upgraded to the candidate, a soak on a box running it —
  cannot be taken before the tag exists, so ordering the drill ahead of the
  merge splits one operator sitting into two across it.
- **The tag pins what a branch cannot.** Since heavy-duty/crew#490 the round
  resolves its ref to one commit and puts that SHA on the record either way; the
  tag is what stops that SHA moving afterwards, which is this ladder's whole
  downstream claim one paragraph up.
- **The append is unobstructed.** The merge door re-arms `main` as
  `X.Y.Z-rc(N+1)-dev`, and `drill-recorded` asserts nothing on a `-dev` tree, so
  writing the round's readings into the record later is not gated at all.

**Name the candidate's ref when the round is run.** `drill/rehearsal-all.sh`
defaults to `INSTALL_REF="${CREW_DRILL_REF:-main}"`, and `main` is the re-armed
`X.Y.Z-rc(N+1)-dev` from the moment the cut lands — so a bare invocation after
the merge drills a tree that is *not* the candidate, and says so only in the
summary's `## drilled source:` line. Pass `--ref X.Y.Z-rcN`. A tag resolves
through the same phase-0 path a branch does and lands on the record as the
resolved SHA.

(heavy-duty/crew#490 closed `2026-08-26`; this paragraph previously deferred to
it as an open problem. What survives of that deferral is the sentence above —
the record is committed against a tree that is not yet tagged — which is a fact
about the ordering rather than a defect awaiting a fix. Corrected under
heavy-duty/crew#659's `0.1.3-rc1` cut, the first candidate this ladder ran.)

### The stamps-only test

The ladder's claim is that **the drilled tree and the shipped tree differ by no
executable byte**. That claim is checkable, so it is checked rather than
asserted: at a final release tree, the diff from the last `X.Y.Z-rcN` tag to
`HEAD` must touch **stamps only**.

A stamp is release furniture — the four paths a ceremony PR is allowed to move,
and no others:

| stamp | what moves it |
| --- | --- |
| `VERSION` | the rc cut, the re-arm, and the final cut |
| `CHANGELOG.md` | the final's assembled section |
| `changelog.d/**` | the fragments that section consumed |
| `drills/**` | the version's own record |

Anything else in that diff means work landed between the candidate and the
final, so the tree that ships is not the tree that was drilled and **the ladder
has not been followed**. Two ways forward, both ordinary: cut `X.Y.Z-rc(N+1)` at
the tree that actually ships and drill *that*, so the final rides a candidate it
does not differ from; or take the non-stamp change back out of this release
window. Neither is an exception to the gate — the first satisfies it and the
second removes what it objected to.

**Drilling the final itself is not a third way out of that refusal**, and this
section said it was. Once a candidate is published and in the final's own
history it stays the anchor, so writing a fresh `drills/X.Y.Z.md` adds a stamp
and removes neither the anchor nor the stray path. Drilling only the final is
what an **un-laddered** window does, and there the guard is vacuous because no
candidate sits above the final to compare it against — a different shape of
window, not a remedy for this one. The ladder stays available and never
required (heavy-duty/crew#506 D5); what is not available is starting it and
then stepping off it.

**The test is deliberately stricter than the sentence it enforces.** "No
executable byte" would let a documentation-only merge through; the stamp set
refuses it. The asymmetry is the reason: a false red costs one author a
re-read and is answered by cutting the next candidate, while a false green
ships a final whose evidence describes a tree nobody ran. A guard that is
looser than its claim is the claim wearing a green check.

`.github/stamps-only.py` is that guard, run on every PR from
[`.github/workflows/release-guards.yml`](../.github/workflows/release-guards.yml)
beside the ceremony gates. It is vacuous on a `-dev` tree, on an rc tree — an
`rc2` exists precisely *because* something changed, so there is nothing for it
to assert — and on a final whose window cut no candidate. Its contract tests
are `.github/stamps-only.test.sh`.

**Which candidate was last is read from two sources, and neither is trusted
alone.** The anchor is the highest-numbered of the `drills/X.Y.Z-rcN.md`
records in the shipped tree *and* the `X.Y.Z-rcN` tags reachable from `HEAD`,
because each source fails open where the other holds:

- The records are **deletable by the diff under examination**. A record lives
  in `drills/`, a stamp path, so removing it in the final commit is admitted by
  the stamp set — and a records-only anchor would drop with it, reporting a
  window that laddered nothing while engine code sat in the diff.
- The tags **cannot tell a tag never fetched from a tag never cut**, so a
  tags-only anchor would read a shallow clone as an un-laddered release.

So the guard refuses in both directions. A record whose tag cannot be resolved
is a **refusal and never a pass** — "I found nothing" and "I could not look"
are different answers here for the same reason they are in teardown's exit
table below — and a candidate that is published and in this final's own history
but carries **no record in the shipped tree** is refused too. The retention
matters because the record is the only thing that says *what* was drilled: a tag
that has lost its record has lost its evidence, and un-publishing is not what
deleting a file does.

That check reads **every** reachable candidate and not only the one the final is
measured against. The ladder is `rc1 → rc2 → … → X.Y.Z`, so a window with more
than one rung is the ordinary case, and each rung's record is the only
description of the tree that rung ran. Deleting a record *below* the anchor
cannot move the anchor — the highest number is unchanged when a lower one leaves
— so it is not a way past the stamps-only test; what it destroys is the
evidence, which is the thing the ladder exists to keep. **Restoring the record
is the only thing that answers this refusal**, and it is recoverable exactly,
because the record is in the candidate's own tree: `git checkout X.Y.Z-rcN --
drills/X.Y.Z-rcN.md`. Cutting the next candidate does *not* answer it — that
tag stays reachable and stays recordless, and the guard refuses again.

The guard asks the candidate's tree for that record before offering the
checkout, rather than promising it. A candidate that published with **no record
at all** — which `drill-recorded` gates the rc PR precisely to prevent, so it
takes a hand edit to reach — has nothing to check out, and there the refusal
says to *write* `drills/X.Y.Z-rcN.md`: a record written late is still the only
description of that tree, and the gate takes a waiver honestly stated.

**And what retention asks for is the tag's own spelling, not its number.**
`drill-recorded` computes the record's path as `drills/$ver.md` from the version
being cut, so a candidate published as `0.9.0-rc1` carries `drills/0.9.0-rc1.md`
and nothing else can stand in for it. A final that *renames* that record to
`drills/0.9.0-rc01.md` has deleted the published evidence — the rename lives
inside `drills/`, so the stamp set admits it, and a check keyed on the number
would see candidate 1 still recorded and pass. It is the deletion above wearing
a rename, and it is refused as one, naming both the record that is required and
the file that stands in for it.

**One number, one spelling.** `version_is_rc` at the pin is
`X.Y.Z-rc[0-9]+`, which accepts a zero-padded number, and `version_next_dev`
re-arms `0.9.0-rc01` as `0.9.0-rc2-dev`. So `0.9.0-rc01` is a candidate the
release doors publish, and the guard reads the number only to *order* the
ladder: every tag it resolves and every record it names is the spelling that is
actually on disk. Where one number is spelled two ways in one ladder — two
records, or two tags both in the final's history — the guard says so and stops,
because an arbitrary anchor is a measurement against a tree nobody declared. The
one place two spellings of a number are not ambiguous but simply wrong is
retention, just above: a published candidate's record is spelled exactly as its
tag, so the other spelling is not a second candidate to disambiguate — it is the
record renamed.

**The digits are ASCII, because the doors' digits are ASCII.** `X.Y.Z-rc[0-9]+`
above is the literal spelling at the pin — `lib/version.sh`, `lib/tag-classify.sh`
and `drill/lib/candidate.sh` at `heavy-duty/ceremony@0.7.6` all write it that
way — and the guard writes it that way too rather than the Unicode-wide `\d` a
regex reaches for by default. This is the same rule as *one number, one
spelling*, one level down: a candidate is what the release doors would
**classify, tag and publish**, so a version or tag they would refuse is not a
rung of anybody's ladder here either. It is worth stating because the failure is
silent in both directions — such a spelling would read as a candidate that was
never cut, and a stray record under one would out-rank a genuine candidate and
gate a release that has nothing to do with it.

The same question is asked one step earlier, of the string itself: **`VERSION`
is consumed the way the doors consume it.** `lib/version.sh` at the pin reads a
file-backed version with `tr -d '[:space:]'` — every whitespace character
deleted, not just the ends trimmed — precisely so a stray space cannot make
`0.7.0` look unlike `0.7.0`. Every gate that decides whether a tree ships goes
through that one reader, so a `VERSION` of `0. 9.0` is the final `0.9.0` to
`drill-recorded` and to both release doors. A guard that merely trimmed the ends
would call the same tree unclassifiable and pass it in silence, whatever its
diff contained. And the deletion is byte-oriented, as `tr` is: a `VERSION`
carrying a non-breaking space is *not* normalized at the door, so it is not
normalized here either. Wider is not safer — it is a second dialect, which is
the thing this whole section refuses.

**A shallow clone is a "could not look" wherever it touches this guard**, and
that includes ancestry. A `--depth 1` checkout that *has* fetched the tags can
resolve `X.Y.Z-rcN` and still answer no to `merge-base --is-ancestor`, because
the join is below the graft: the no is about the clone and not about the tree.
Refusing there would print the guard's loudest sentence — that what ships only
resembles what was drilled — over a clone that simply cannot see. So it exits
`2` and names the fix (`actions/checkout` with `fetch-depth: 0`), which is the
same answer it gives when a record's tag cannot be resolved at all. CI fetches
full history, so this is a local-clone corner; keeping the two answers apart is
the point.

A candidate tagged on a line the final does not descend from is **not** the
anchor. It drilled a different lineage, and reading it would red a window it
has nothing to say about — while a candidate the final *does* descend from is
exactly the one whose record cannot be allowed to vanish.

## Which legs run where — the offline contract and the host's round

Two kinds of leg, and the split is the whole reason a pull request's CI is
short (crew#756):

- **Offline, on every pull request**, through `ci-shell`'s matrix: the
  drill's contract tests — `shared/test/drill.sh` (orchestration, source
  acquisition, the record's shape, every row's grading through the real
  `wait_for`), `shared/test/install-drill.sh` (the installer's dry run and
  interlock) and `shared/test/drill-teardown.sh` (the refusal set and
  idempotence). They need no box, no credential and no network, and a
  harness change that misgrades a row is caught here before it costs a
  round on a host.
- **On the host, on a candidate**: `drill/rehearsal-all.sh --ref X.Y.Z-rcN`,
  the real-host round the ladder above gates a promotion on — boxes minted
  through Incus, sandbox repositories, sessions bought from the vendor. It is
  run by the operator against a published tag and its readings are appended
  to that candidate's record. It does not run on pull requests, and nothing
  in CI pretends to be it.
- **The floor's browser walk** (`ci-floor.yml`) sits between: on every pull
  request that moves `fleet-floor/`, weekly on `main`, and by hand on a
  candidate — `gh workflow run ci-floor.yml --ref X.Y.Z-rcN` — with the run
  named in the candidate's record. The floor's no-browser half runs in
  `ci-shell`'s matrix on every engine change, because `cli.sh` lives there.

Every row the host's round grades with a budget takes it from the box's own
installed `TIMEOUT_<KIND>` through `wait_for_lane` (crew#750); a literal
budget on a graded row is a defect `shared/test/drill.sh` pins against.

## Adapting the drill to the window

**A release window's drill is adapted to what that window shipped, and the
release issue carries the audit that says so.** At release-init, triage adds one
row for every surface shipped by the fragments in `changelog.d/` on `main` when
the release issue is minted, naming the issue and surface and assigning exactly
one disposition.
Every fragment contributes at least one row; a fragment that ships more than
one surface contributes a row for each:

- **`drilled`** — an existing leg reads the surface; name the assertion.
- **`new leg`** — the window needs another leg; name the issue minted for it.
- **`not a drill surface`** — no real-host assertion belongs in this drill;
  state why. An empty reason leaves the audit incomplete.

Those three dispositions are exhaustive. `Partly drilled` is not a fourth: it
means a fragment shipped separate surfaces that need separate rows.

The audit is a table in the release issue, not another repository file. Triage
owns it because release-init already reads the window membership, and completes
it then so every required leg can land before the operator runs the round. A
leg that lands after the drill round changes the candidate the record describes
and forces a re-drill.

### Worked example: `0.1.2`

This is a worked example at snapshot
`07bb0f3473d1a35a39fdf8d9ab93ac7d99ec3d74`, not `0.1.2`'s audit of record.
Its fragment names are exactly the 42 fragments returned by
`git ls-tree -r --name-only 07bb0f3473d1a35a39fdf8d9ab93ac7d99ec3d74 -- changelog.d/`,
excluding `changelog.d/README.md`. Triage re-derives the audit of record at
release-init against the actual cut. The owed `425.md`, `427.md`, `440.md`,
and `441.md` fragments are absent at this snapshot and therefore have no rows
below. A disposition records the decision at audit time, so a `new leg` row
keeps the issue it caused even when that issue has since landed.

| Fragment | Surface | Disposition and evidence |
| --- | --- | --- |
| `139.md` | Fix rounds return to draft | **`new leg`** — #418 |
| `168.md` | Dirty worktrees preserve tracked and untracked work on a remote `wip/` ref before removal | **`new leg`** — #422 |
| `168.md` | Preservation writes an upstream recovery comment naming the remote, ref and contents | **`new leg`** — #422 |
| `168.md` | A failed preservation push or record retains the worktree | **`new leg`** — #422 |
| `168.md` | Removal logs the recovery remote, ref and fetch command | **`new leg`** — #422 |
| `168.md` | Preservation records every file and retains unreadable worktrees | **`new leg`** — #422 |
| `168.md` | Index-only content remains reachable below the `wip/` tip | **`new leg`** — #422 |
| `168.md` | Staged-only work reverted in the tree can be preserved and released | **`new leg`** — #422 |
| `190.md` | Floor integrity verdict | **`new leg`** — #420 |
| `190.md` | Browser walk checks `gh ✓` only for armed, ticking boxes and reports when none qualify | **`drilled`** — `render: the fixture offers an armed, ticking box...`, `render: healthy boxes show gh ✓...`, and the no-candidate report in `fleet-floor/test/browser.js` read it. |
| `204.md` | Consoles only for deployed boxes | **`new leg`** — #420 |
| `210.md` | Tagged release publishes the scp-able installer asset | **`not a drill surface`** — the asset exists only after the tag; #210 owns its post-merge verification. The installed tree is covered by #421. |
| `210.md` | Tagged release publishes and verifies the installer checksum | **`not a drill surface`** — the checksum exists only after the tag and belongs to #210's post-merge verification. |
| `217.md` | Teardown names, confirms and removes round boxes and sandboxes, and a clean rerun is a no-op | **`drilled`** — the `teardown` summary row and `teardown: nothing to do` assertion read it. |
| `217.md` | Teardown refuses non-drill names, roster members and an all-or-nothing set containing either | **`drilled`** — `drill/teardown.sh`'s name, roster and `teardown: REFUSING — nothing was deleted` assertions read it. |
| `217.md` | Sandbox deletion requires the host GitHub identity | **`drilled`** — `drill/teardown.sh`'s owner-identity refusal reads it. |
| `217.md` | Inspection failures report `INCOMPLETE` rather than a clean host | **`drilled`** — the `teardown: INCOMPLETE` summary row and per-probe diagnostics read it. |
| `217.md` | Duplicate teardown targets are deleted once | **`drilled`** — `drill/teardown.sh`'s deduplicated target assertions read it. |
| `217.md` | Green rounds auto-teardown while `--keep`, failed rounds and phase-1-only rounds retain their fixtures | **`drilled`** — the `teardown` summary rows in `rehearsal-all.sh` read each outcome. |
| `217.md` | An incomplete teardown reds the rehearsal summary | **`drilled`** — the `INCOMPLETE teardown` summary assertion reads it. |
| `217.md` | Existing boxes are refused unless `--reuse` is explicit | **`drilled`** — the existing-box refusal and reuse/pre-auth-skip assertions read it. |
| `218.md` | `crew up --dry-run` | **`new leg`** — #420 |
| `240.md` | Boot-check probe verdict | **`new leg`** — #427 |
| `301.md` | Attention pickup comment and acknowledgement | **`drilled`** — the pickup-comment and `attention`-removal assertions in `rehearsal.sh` read it. |
| `301.md` | Attention dispatch and timed-out pickup reporting | **`new leg`** — #440 |
| `303.md` | Hygiene reporting of malformed `attention` | **`new leg`** — #441 |
| `308.md` | Unknown `crew status` probe | **`new leg`** — #420 |
| `312.md` | Disarmed versus silent floor states | **`new leg`** — #420 |
| `316.md` | Operator notifications cover every work repository | **`new leg`** — #423 |
| `316.md` | `notify-repos.txt` adds handoff targets without replacing the work registry | **`new leg`** — #423 |
| `319.md` | An unrendered round-signal marker is diagnosed and resumed on the next tick | **`new leg`** — #419 |
| `319.md` | Resume rereads ready-PR comments before deciding a correct signal is absent | **`new leg`** — #419 |
| `323.md` | The release-tree floor CLI fixture accepts the already-hired skip | **`not a drill surface`** — this changes the repository's `ci-floor` suite, not installed real-host behavior. |
| `323.md` | The release-tree floor CLI failure names the expected box | **`not a drill surface`** — this is a CI fixture diagnostic, not installed behavior. |
| `341.md` | A newly hired box waits a cron boundary for a post-removal tick | **`drilled`** — `step 9: positive engine/cron/tick survival observation` reads it. |
| `341.md` | Step 9 diagnoses the missing engine, cron or tick and names what it read | **`drilled`** — the same step-9 failure assertions read each component and its observed value. |
| `345.md` | `no build duty` cause | **`new leg`** — #420 |
| `347.md` | Serving crew version in the floor | **`new leg`** — #420 |
| `350.md` | `.ceremony/RELEASES.md` joins the vendored mirror | **`not a drill surface`** — this is repository doctrine mirrored and checked in CI, not installed real-host behavior. |
| `350.md` | Ceremony workflow and action pins move to `0.6.0` | **`not a drill surface`** — GitHub Actions consumes these pins; a drill box does not. |
| `350.md` | `changelog-armed` requires a final issue citation | **`not a drill surface`** — the repository release guard enforces this in CI. |
| `350.md` | Issue sweeps report collision, window-member and starved-`post-merge` conditions | **`not a drill surface`** — GitHub Actions runs these board sweeps, not the installed duty drill. |
| `350.md` | `blocker:unrequested` waits while head checks are pending or failing | **`not a drill surface`** — the repository labels workflow owns this state. |
| `350.md` | `blocker:unrequested` waits for a stable head and verdict | **`not a drill surface`** — the repository labels workflow owns this state. |
| `358.md` | `post-merge` in the queue-label set | **`new leg`** — #417 |
| `359.md` | Quiet post-session triage state | **`new leg`** — #417 |
| `363.md` | Resume prompt quotes the current parked-resume sentence | **`not a drill surface`** — this is a repository prompt/doctrine comparison in CI. |
| `363.md` | Doctrine quotation comparison ignores wrapping-only differences | **`not a drill surface`** — this is a repository fixture guard. |
| `363.md` | `shared-ci` runs when `.ceremony/**` changes | **`not a drill surface`** — this is a GitHub Actions trigger. |
| `365.md` | Installed payload roots and size | **`new leg`** — #421 |
| `384.md` | Check conclusion joins the resume fingerprint and wakes a parked builder | **`new leg`** — #419 |
| `384.md` | Green ready PRs with no current-head signal resume on the next tick | **`new leg`** — #419 |
| `384.md` | Green signalled drafts with no panel request resume for the builder-owned flip | **`new leg`** — #419 |
| `388.md` | Terminal failures trip a lane, suppress dispatch, alert once and recover automatically | **`new leg`** — #424 |
| `388.md` | Agent profiles classify terminal quota output and expose whether a session acted | **`new leg`** — #424 |
| `398.md` | Ceremony workflow and action pins move to `0.6.2` | **`not a drill surface`** — GitHub Actions consumes these dependency pins. |
| `398.md` | Vendored doctrine declares rounds answered before pending-check settlement | **`not a drill surface`** — this is mirrored prose, not installed behavior. |
| `398.md` | Vendored release doctrine advances windows past `post-merge` members | **`not a drill surface`** — this is mirrored triage doctrine, not installed behavior. |
| `402.md` | Pending-check round signal and request gate | **`new leg`** — #418 |
| `403.md` | Zero-action resume stop | **`new leg`** — #419 |
| `405.md` | Development dependency and manifest hygiene | **`not a drill surface`** — repository development furniture is not shipped into the installed tree. |
| `406.md` | Attributed-doctrine quotation guard | **`not a drill surface`** — this is a repository fixture guard, not installed behavior. |
| `407.md` | Phase-0 tracked-tree staging | **`drilled`** — `fixture tests green` runs from the staged tree before the live legs. |
| `408.md` | Reused-box post-removal tick | **`drilled`** — `step 9: positive engine/cron/tick survival observation` reads it. |
| `411.md` | Existing-box membership remains correct under load | **`drilled`** — the install leg's `crew hire` / `crew up` assertions read it. |
| `411.md` | Roster membership remains correct under load | **`drilled`** — teardown's roster-member refusal assertion reads it. |
| `411.md` | Drill-sandbox membership remains correct under load | **`drilled`** — teardown's sandbox refusal assertion reads it. |
| `411.md` | Cron membership remains correct under load | **`drilled`** — the install leg's engine/cron survival assertion reads it. |
| `417.md` | `post-merge` triage invariant | **`drilled`** — `triage: post-merge drew no comment`, `kept its single label`, and `launched no session` read it. |
| `418.md` | A completed non-approving round returns the builder PR to draft | **`drilled`** — `builder: changes-requested round returns PR to draft` reads it. |
| `418.md` | A pending-head fix round signals immediately, withholds requests, then requests after settlement | **`drilled`** — `builder: round answer is signalled while head check is pending`, `panel request withheld while head check is pending`, and `panel request issued after head settles` read it. |
| `419.md` | A settled check conclusion wakes a parked builder | **`drilled`** — `resume: first tick after green resumes the parked PR` reads it. |
| `419.md` | An unrendered signal marker warns and wakes on the next tick | **`drilled`** — `resume: unrendered marker warns with its comment and wakes next tick` reads it. |
| `419.md` | Consecutive unchanged zero-action attempts stop the resume lane | **`drilled`** — `resume: unchanged head stops after the installed zero-action threshold` reads it. |
| `420.md` | Floor API names the serving host's crew version | **`drilled`** — `floor: the API names the serving host's own crew version` and the canvas-header assertion read it. |
| `420.md` | Each engine integrity verdict is the box's own valid answer | **`drilled`** — `floor: every hired box's integrity verdict is the box's own answer` and `every integrity verdict is one of the three words the tile renders` read it. |
| `420.md` | Undeployed roster boxes are counted but not drawn | **`drilled`** — `floor: the not-deployed boxes are counted but not drawn` reads it. |
| `420.md` | A floor with nothing hired names the repair verb | **`drilled`** — `floor: a roster box that is not deployed is counted and names its repair verb` reads it. |
| `420.md` | Deliberately disarmed boxes remain distinct from silent boxes | **`drilled`** — the `floor:` disarmed/silent state assertions read it. |
| `420.md` | `crew up --dry-run` reports its plan without changing the fleet | **`drilled`** — the `crew up --dry-run` no-change and plan assertions read it. |
| `420.md` | An unanswered engine probe reports `unknown` | **`drilled`** — the `crew status` unknown-probe assertion reads it. |
| `420.md` | `no build duty` names its cause and live count | **`drilled`** — the `no build duty` cause/count assertions read it. |
| `421.md` | First install, upgrade and offline artifact exclude every non-shipped root and stay under budget | **`drilled`** — the three `payload:` measurements read exclusions and size for all three channels. |
| `421.md` | Drill records measured size and reads exclusions and budget from shipped sources | **`drilled`** — the `payload:` source-parity and measurement assertions read it. |
| `422.md` | Dirty merged worktrees are pushed and recorded before removal | **`drilled`** — `hygiene: wip tip carries all three dirty-work shapes`, `upstream record names...`, and `confirmed push precedes forced removal` read it. |
| `422.md` | Failed preservation retains the worktree and reports it once | **`drilled`** — `hygiene: failed push keeps... reported once` reads it. |
| `423.md` | The operator watch set is `repos.txt` union `notify-repos.txt` and both halves notify on one tick | **`drilled`** — `notify: the watch set swept is exactly the two sandboxes` and `both halves of the union reached the operator on one tick` read it. |
| `423.md` | `--no-notify-drill` opts out of the notifier leg | **`drilled`** — `notify: union over repos.txt and notify-repos.txt (--no-notify-drill)` reads it. |
| `423.md` | Writing `notify-repos.txt` leaves `repos.txt` unchanged | **`drilled`** — `notify: repos.txt unchanged — the union widened the watch set and not the work set` reads it. |
| `423.md` | Teardown removes the per-role notify sandbox | **`drilled`** — the notifier-sandbox cleanup assertion reads it. |
| `423.md` | Teardown reds when either repository registry cannot be restored | **`drilled`** — `notify: teardown restored both registries to their pre-drill contents` reads it. |
| `423.md` | A missing pre-drill registry backup reds rather than vouching for unknown contents | **`drilled`** — the `notify: the pre-drill repos.txt backup is gone` refusal reads it. |
| `423.md` | The notifier refuses to choose a second sandbox when the pre-drill work registry is unreadable | **`drilled`** — `notify: the host's pre-drill registries can be read before the notify half is chosen` reads it. |
| `423.md` | The handoff fixture is tracked from creation and closed reliably | **`drilled`** — the handoff-fixture staging and teardown-close assertions read it. |
| `423.md` | An unreachable operator chat skips the notifier leg | **`drilled`** — `notify: union over repos.txt and notify-repos.txt (operator channel unreachable...)` reads it. |
| `423.md` | Teardown removes notifier and hygiene temporary files | **`drilled`** — the notifier and hygiene teardown assertions read it. |
| `424.md` | Terminal dispatches remain live below the installed threshold and trip once at it | **`drilled`** — `breaker: terminal dispatch ... remains below installed threshold` and `lane trips once at installed threshold` read it. |
| `424.md` | Ticks after the trip skip the stopped lane | **`drilled`** — `breaker: following ticks skip the stopped lane` reads it. |
| `424.md` | The stopped lane emits exactly one operator alert | **`drilled`** — `breaker: <kind> operator alert emitted exactly once while stopped` reads it. |
| `424.md` | Restoring the real CLI recovers dispatch without hand intervention | **`drilled`** — `breaker: later tick recovers and launches a session` and the state/fixture teardown assertions read it. |
| `435.md` | Resume leg's independent summary verdict | **`drilled`** — the resume verdict file and `rehearsal_worst_verdict` feed the `resume` summary row independently of the builder exit. |

## The drill

crew asserts the **duty lifecycle** — that the engine, installed on a real box,
runs its roles correctly. box asserts the isolation contract, rig asserts
convergence, cast asserts promotion; crew asserts that a fleet of agents does
triage, build and review the way the doctrine says. The legs
(`drill/rehearsal.sh`, run per role by `rehearsal-all.sh`):

- **Phase 1, creds-free.** Install the engine into a drill box as the selected
  agent in each role, and verify every behavior that needs no credentials —
  a box comes up disarmed and reports so.
- **Phase 2, authenticated** (runs when the box's `gh` and agent CLIs are
  logged in — the operator logs the box in between runs; the harness never
  touches credentials). It mints its own GitHub fixtures under the host
  identity and verifies the attention wake, the review round through both
  one-shot gates, head dedup, the re-request auto-approve, and gate abuse.
- **One box per role**, not one box carrying all three: `fleet.roster` deploys
  single-role members and `duty.sh` gates every module on `has_role`, so a
  composite box would exercise a path nobody runs.
- **The console** (`fleet-floor`) is part of the rehearsal, not a separate
  errand: it is what an operator looks at to decide the fleet is healthy.
- **Operator-config convergence** — the registry contract exercised against a
  real installed box.

Within a run, fixtures and the drill box are left in place for inspection; the
box is always left disarmed and its pre-drill repo registry restored. What
happens to them *between* runs is the lifecycle below. Companion prose:
[`shared/docs/rehearsal.md`](../shared/docs/rehearsal.md).

## The round's lifecycle — create, reuse, teardown

A round is real infrastructure, and it is the operator's machine and the
operator's GitHub account that carry it.

**A round creates**, per role in `--roles` (all three by default):

- a **box** on the host, `crew-drill-<role>`, at 2 CPU / 4 GiB / 20 GiB;
- a **public sandbox repository**, `<host-gh-identity>/crew-drill-<role>`,
  which the round then fills with issues, PRs and review traffic;
- for the builder role, a **public fork of that sandbox** under the box's
  GitHub identity. Phase 2 creates it before the first tick and resolves its
  actual fork-network name, including GitHub's numeric suffix when the
  conventional name is already occupied.

**A green round tears itself down.** `rehearsal-all.sh` runs
[`drill/teardown.sh`](../drill/teardown.sh) when every leg passed, removing
both. Nothing else on the host is touched, ever:

    drill/teardown.sh [--roles "triage builder reviewer"] [--role <role>]
                      [--box <name>] [--sandbox <owner/repo>]
                      [--dry-run] [--yes]

It names every box and repository with its creation date and asks once
(`CREW_YES=1` or `--yes` for an unattended run), and it is idempotent — a
second run over a clean host reports nothing to do and exits zero. A name is
deletable only when it is **exactly** one of the drill's own names *and* is
named by no roster on this host: a roster member is refused even when its name
matches the drill pattern, and a name that merely starts with `crew-drill` is
not a drill box. A sandbox repository has the same two gates — the `<repo>`
half must be a drill name *and* the owner must be this host's `gh` identity,
since a round's sandboxes are always `<host-gh-identity>/crew-drill-<role>`.
The builder fork carries the same two gates in its own ownership domain: its
name must be `crew-drill-builder` or GitHub's numeric-suffixed form, and its
owner must equal the identity read from `crew-drill-builder`. Teardown deletes
the fork through that box before removing the credential-bearing box, then
deletes the host-owned sandboxes.
Every target is validated before any is deleted, so a command carrying one bad
name removes nothing at all, and naming the same target twice deletes it once.

**"I found nothing" and "I could not look" are different answers**, and the
exit status is where teardown keeps them apart:

| exit | meaning |
| --- | --- |
| `0` | every class it was asked to clear was **inspected**, and whatever existed is gone. Only this means a clean host. |
| `1` | **refused** — a name outside the deletable set — or a deletion failed. |
| `2` | **INCOMPLETE** — a class could not be inspected at all, so what it holds is unknown and may still be standing. |

A run is INCOMPLETE when there is no `gh` identity to address the sandbox
repositories with, when there is no `box` CLI, when `box list --json` cannot
be read or parsed (no `jq` counts), or when a **single repository lookup**
does not answer. That last one is the same distinction at the other grain: an
identity that resolves says the API can be *asked*, not that it *answered*, so
a lookup that fails for anything other than a measured `HTTP 404` names its own
repository as uninspected rather than being counted absent. It says which class
or repository and why, it still deletes everything it *could* see — that half
of the host really is clean — and it does not report the round as done.
`rehearsal-all.sh` gives it its own `INCOMPLETE teardown` summary row rather
than `ok`, so a green round can never end with a cleanup line claiming more
than was measured.

One caveat worth knowing rather than discovering: GitHub answers `404` for a
private repository the token cannot see, so a measured absence is really
"absent *to this identity*". That is the API's shape, and it is the safe
direction — a repository this identity cannot see is not one it can delete.

A custom `--box` name is the operator's own and teardown will refuse it; the
rehearsal's reuse refusal says so rather than printing a teardown command that
cannot work.

**A round that did not pass keeps its boxes**, and so does `--keep`. A failed
leg is the case where you need the box standing to find out why, so the run
says the boxes are still there and prints the teardown command. `INCOMPLETE`
— phase 2 never ran — counts as not passing here for the same reason.

**Reuse is opt-in, and it weakens phase 1.** A rehearsal whose target box
already exists **refuses**, naming the box, its creation date, and the two ways
forward: tear it down, or pass `--reuse`. Reuse is legitimate when the operator
means it, but a box that is already `gh`-authenticated cannot prove the
creds-free half of phase 1 — the login WARN, the absent `.boot-id` marker and
the un-spawned sessions all SKIP. That is what happened to the `0.1.0` round
(#116), which is why the refusal is the default and why `--reuse` writes itself
into the run's output, at the point of reuse and again in the summary. **A
record of a reused round says so**, by carrying that line.

Deleting a box does not revoke the GitHub identity it logged into. Identity
lifecycle is a separate concern from drill fixtures, and teardown does not
touch it.

## What a record should contain

What ran, on what host, the pinned candidate ref, the numbers, and what failed.
Below is the *shape*, in a file named `drills/9.9.9.md` — a version that can
never collide with a real release. **No drill has been recorded here yet**;
this log starts empty rather than reconstructing runs from memory, since an
invented number is worse than no number.

```markdown
# Release drill — 9.9.9 — 2026-01-01

Run ID: drill-2026-01-01-a. Host: bare Debian 13 cloud image, box + rig
installed, 4 vCPU / 8 GB. Candidate ref: crew@1a2b3c4.

| Leg | Result |
| --- | --- |
| phase 1 — creds-free install, reviewer role, box disarmed | PASS |
| phase 2 — attention wake | PASS |
| phase 2 — review round through both one-shot gates | PASS |
| head dedup / re-request auto-approve | PASS |
| gate abuse refused | PASS |
| fleet-floor console (read-only) | PASS |
| operator-config convergence | clean, no changes |

Failed: nothing this run.
```

State what failed. A record with no failures listed reads as "nothing broke",
so if a leg was not run, say that instead of omitting it.
