# The release cut — a ticket to a deployed version, and where a person rules

The walk this engine was re-enabled for (#753, #762): a team member files a
ticket, and a version carrying the fix boots on production, with the operator
touching nothing but the rulings that are theirs and the one approval. This
runbook follows one ticket through every door on
heavy-duty/la-familia-site, names the evidence each step leaves, and marks
the three places a person decides. The site's own files are named where the
step is the site's; crew's are named where it is the engine's.

The one rule the whole chain rests on: **the engine opens doors and never
walks through the last one.** The release pull request is cut by the
engine; it is merged by a person, through the repository's own door.

## The doors, in order

| # | Step | Who | Where it happens | What it leaves |
|---|------|-----|------------------|----------------|
| 1 | The ticket | a team member | the admin's four doors (`apps/admin/lib/tickets.mjs`) | a ticket row, `abierto` |
| 2 | *Llevar a GitHub* | a team member | the admin | an issue in the site repository, `needs-triage` + `scope:site` or `scope:deploy`, linked both ways |
| 3 | Triage | the triage member | `duty-triage.sh`, a `triage` session | the issue's spec and acceptance criteria, `ready` (or `blocked`, or a question to the reporter) |
| 4 | **The window** | **the operator** | the release epic's `## Members` (RELEASES.md) | the ruling that this issue is in the next release — or that it is not |
| 5 | Claim and build | a builder member | `duty-builder.sh`, a `build` session; worktree under `~/duty/trees/` | a draft PR with a worklog, then the round-answered signal and ready-for-review |
| 6 | Review | the panel (`.github/labels.conf` `panel=`), sized by risk (#761) | `duty-review.sh`, `review` sessions | approvals or a round; the builder's `resume` session answers the round |
| 7 | **The merge** | **a person** (`FLEET_HUMAN`) | GitHub | the PR merged to `main`; the issue closed; the ticket flips to `hecho` within the avisos tick's 15 minutes |
| 8 | The cut | the triage member | `duty-release.sh`, a `release` session | one PR labelled `release`: `apps/site/VERSION`, the assembled `CHANGELOG.md` section, the consumed fragments, `apps/site/drills/X.Y.Z.md` |
| 9 | **The approval** | **a team member** | the admin's *Publicar versión*, with the authenticator code | `release-approve.yml` waits for CI on the bound head, merges the release PR, dispatches `build-images.yml` and `release.yml` |
| 10 | The release | the site's workflows | `release.yml` (ceremony `0.7.11`, track `apps/site`, prefix `site-`) | the tag `site-X.Y.Z`, the GitHub release, `:stable` re-tagged, `deploy.yml` on production, the release mail |
| 11 | The record | the admin | the ticket | `hecho`, naming the version |

Three rows are bold. Those are the person's, and the engine is built so that
it cannot take them: it mints no window membership (RELEASES.md: "release
membership is a decision, never a sweep default"), it merges nothing
(`FLEET_HUMAN` is the only identity that merges), and it never approves a
release — the cut session's prompt ends at "STOP", and `_release_after`
only reads the pull request back.

## Step 8 in detail — what the engine decides, and what the session does

The cut runs in the triage box's tick, after the hygiene sweep and before
the reaper, for every track in `RELEASE_TRACKS` (fleet.conf):

```
RELEASE_TRACKS="heavy-duty/la-familia-site:apps/site:site- heavy-duty/la-familia-site:apps/admin:admin-:hold"
```

The shell half reads the main clone and the board and refuses, with the
reason on `duty.log`, unless every row holds:

| Read | Refusal line (`no release duty: <repo> <prefix>@<path> — …`) |
|------|------------------------------------------------------------------|
| the track's rule | `held by RELEASE_TRACKS (rule hold); the operator cuts` |
| the engine's own open cut | `the engine's own release PR is open and current; the approval is a person's` |
| any other open `release` PR for the track | `release PR #N by <who> (<branch>) is already open` |
| `<path>/VERSION` on main | `VERSION on main is not armed (no -dev suffix); nothing to stamp` |
| the last `site-X.Y.Z` tag | `no release tag under the prefix yet; the first cut is the operator's` |
| commits since the tag touching the track (the re-arm excluded) | `main carries nothing for the track since site-X.Y.Z` |
| `<path>/changelog.d/` on main (final versions only) | `N merge(s) since site-X.Y.Z but no fragment in changelog.d; a release publishes prose` |
| the seen-ledger `.seen-release`, keyed by the TRACK'S tree | `the track at <sha> was already cut or refused; only new merges on the track make a new cut` |
| `.release-tried-<track>` | `N session(s) ended without a pull request for the track at <sha>; refused until the track moves` |
| main's last commit age against `RELEASE_QUIET_S` | `main moved Ns ago, under the 900s quiet window; due in Ms` |
| every check run and the commit status at main's head | `CI at <sha> is still running` / `is red` / `is unknown` — a stale run is red; no run on a repository with workflows is still running |
| the ceremony pin in `.github/workflows/release.yml` | `names no ceremony pin` |

A cut that waits for the quiet window writes `~/duty/.release-due-<track>`;
the host tick reads it from the store (`wake_release_reasons`) and starts
the box when it is due, so a wave of merges yields one cut, after the wave,
even if the box had gone to sleep. Any other refusal clears that wait. Every
piece of the cut's memory is per track — the site's and the admin's cuts,
waits and refusals never share a file — and a refusal is remembered by the
track's tree, so an off-track merge re-opens nothing.

Only when every row holds does the engine buy a `release` session
(`TIMEOUT_RELEASE`, `BUDGET_*_RELEASE`, top tier). The session is handed the
facts — the version, the last tag, the merges, the fragments, the ceremony
pin, the branch — and does the half that needs a toolchain and judgment:

1. branch `release/site-X.Y.Z` in its own worktree from `origin/main`;
2. `apps/site/VERSION` → `X.Y.Z`;
3. for a final version, ceremony's own `bin/changelog-assemble` at the
   consumer's pin (`0.7.11`, checked out under `~/duty/work/.ceremony-0.7.11`),
   with `--changelog apps/site/CHANGELOG.md --dir apps/site/changelog.d`, then
   `--check`; a candidate (`-rcN`) is tag-only and assembles nothing;
4. `apps/site/drills/X.Y.Z.md`, as `apps/site/drills/README.md` defines the
   record: the candidate pinned, what the session exercised in the box
   (the tree's install, build, guards and tests, with results), the waiver
   where the README allows one, and **OWED TO THE APPROVER** for every step
   the box cannot walk (the staging deploy, the browser walk). A record
   that says less and is true is the record;
5. one pull request against `main`, labelled `release`, from the bot's fork;
6. stop.

What the session leaves on the box: `.release-cut-<track>` (`<pr> <branch>
<main sha>`) and a row in `.seen-release`, both carried to the store and
back across a reset (#761). The ledger row is earned by the pull request
existing, read back from the board: a session that died before
`gh pr create` leaves the track uncut and the next tick cuts it again, up
to `RELEASE_MAX_TRIES` times; then the track state is refused and said, so
a session that cannot open its pull request (a missing label, an assembler
refusal, a leftover fork branch) never spends the lane's whole budget.

## When the cut is wrong

- **Stale** — main moved past the cut on the track (another PR merged
  after it): the next tick withdraws it (`gh pr close --delete-branch`, with
  a comment saying why) and cuts the new head on the tick after — but only
  when every commit on it is the engine's; a cut somebody pushed to is held
  and said, never closed. Nothing is force-pushed onto an open release PR,
  ever.
- **Refused** — a person closed the PR without merging: the track's tree
  stays in `.seen-release` and is never cut again. Only a new merge ON THE
  TRACK makes a new cut; an off-track merge changes nothing. To cut the same
  tree anyway, the operator cuts by hand, or removes the row from the ledger.
- **Held** — `:hold` on the track keeps it declared (the admin's line on the
  site, whose releases a person cuts) and buys nothing.
- **The pin moved** — the session assembles at whatever pin the consumer's
  `release.yml` names; crew's own doctrine mirror (`.ceremony/`) is pinned
  separately, at the same `0.7.11` since 0.1.4, and the release suite
  refuses any older pin surviving in this tree.

## What the operator reads

- `crew status <box>`: the triage box's last sessions, with `why=release#…`
  on a cut the host tick woke for.
- `duty.log` on the box, or the store's copy: every refusal row above,
  every `release: … cutting …` and `… opened …` line.
- The pull request itself, which is the only product: its body names the
  version, the merges, the fragments, and the drill record or waiver with
  the owed steps, and its diff is what the approver reads before pressing
  *Publicar versión*.

## The seven-day run (#753's gate)

The promotion gate is operator-owned and reads this chain end to end on the
live site: one ticket walked through all eleven rows, with the approval
pressed by a team member, and the store's figures for the week written into
the candidate's `drills/` record. Nothing in this engine claims that run.
