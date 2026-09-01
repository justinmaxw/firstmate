---
name: catch-up
description: >-
  Pull kunchenguid's upstream changes into every forked or locally patched tool this fleet depends on - firstmate, quota-axi, baby-menu, the npm axi tools, and no-mistakes - while preserving our own local changes.
  Use when the captain invokes /catch-up, asks to update the open source tools, asks to pull in kunchenguid's changes, or asks how far behind upstream we are.
user-invocable: true
metadata:
  internal: true
---

# catch-up

Bring our forked and patched copies of kunchenguid's tools up to date without losing our work.

Two rules govern everything below.

**Our patches are the only copy.**
`projects/quota-axi` and `projects/baby-menu` have no fork on GitHub - their `origin` points straight at kunchenguid, and our commits exist only on local `main`.
Never push them, never force, never reset hard, never discard.
A refusal from any guard is a stop-and-investigate result.

**Some of these tools are live under running agents.**
`quota-axi`'s global command is an npm symlink into `projects/quota-axi`, so a rebuild swaps the binary for every home at once.
`no-mistakes update` resets its shared daemon.
Those steps need a quiet window; nothing else does.

## The target map

Re-derive this at every run rather than trusting the table; the shapes change.

| target | location | shape | our changes | how upstream arrives | live-shared |
| --- | --- | --- | --- | --- | --- |
| firstmate | this checkout | true fork | on `main` | `upstream` remote | only via `/updatefirstmate` |
| quota-axi | `projects/quota-axi` | patched clone, no fork | ahead of `origin/main` | `origin` **is** kunchenguid | **yes** - npm-linked global |
| baby-menu | `projects/baby-menu` | patched clone, no fork | ahead of `origin/main` | `origin` **is** kunchenguid | no |
| gh-axi, lavish-axi, chrome-devtools-axi, tasks-axi | npm global | clean install | none | `npm update -g` | **yes** |
| no-mistakes | `~/.no-mistakes` | managed install, not a git repo | none | `no-mistakes update` | **yes** - shared daemon |

Confirm the npm link before assuming it:
`ls -l "$(dirname "$(command -v node)")/quota-axi"` resolves to the versioned `lib/node_modules/quota-axi` entry, which is itself a symlink straight into `projects/quota-axi`.
If that chain is broken, quota-axi is no longer live-shared and drops out of the quiet window.

### The two clones firstmate cannot refresh or rebuild on its own

quota-axi and baby-menu are registered `local-only` in `data/projects.md` and their `origin` is upstream itself.
For a clone shaped that way, firstmate has no sanctioned automatic path to fetch upstream state, and none to rebuild the live checkout after a landing.
`bin/fm-fleet-sync.sh` cannot serve either purpose: it returns `skipped: local-only project` before it ever fetches, for any project registered `local-only`, so it is not a viable recon path for these two clones.
Do not engineer around this with a new script or a scout dispatch.
Where this skill needs a `projects/` command firstmate cannot otherwise run, it names that command and asks the captain for approval in the moment.
Those points are enumerated, not counted: Phase 0's two fetches (`projects/quota-axi` and `projects/baby-menu`), Phase 2 step 2's quota-axi rebuild, and Rollback's reset and its follow-up rebuild.
Each one names its literal command, asks fresh for that specific run, grants no standing authority, and never carries over to another command, another clone, or a future run.

## Phase 0 - Recon

Moves no branch and lands no commit anywhere.
Safe at any time, with any amount of work running.
Never skip it.

Start with the part that needs no approval:

```
git -C . fetch upstream --quiet
git rev-list --count main..upstream/main
npm outdated -g --depth=0
no-mistakes doctor
```

Use `no-mistakes doctor`, not `no-mistakes --version`.
Both are read-only, but `--version` prints only the installed version and suppresses the `A new version of no-mistakes is available: vX -> vY` banner, so it cannot tell you whether no-mistakes is behind at all - and a run that reports "nothing behind" on that basis would silently skip Phase 2 step 4.

Then refresh the two patched clones.
Present these two commands to the captain verbatim and wait for approval before running either one:

```
git -C projects/quota-axi fetch origin --quiet
git -C projects/baby-menu fetch origin --quiet
```

On approval, run exactly those two commands and nothing else.
Invoking `/catch-up` is not that approval.
The approval is given in the moment, for this run, for these two commands only; it grants no standing authority, and it never carries over to another command, another clone, or a future run.
Every run asks again.
Without it there is no fresh `origin/main` for either clone, so say so and report their counts as stale rather than guessing.

With origin refreshed, read each clone:

```
git -C projects/quota-axi status -sb
git -C projects/baby-menu status -sb
```

For each patched clone, capture the definitive list of what is ours:

```
git -C projects/<name> log --oneline origin/main..main
```

That list is the acceptance criteria for the merge.
Every commit in it names a behavior that must still work afterward.
Write it into the brief; do not make the worker rediscover it.

Also list any anchor left by an earlier run:

```
git -C projects/<name> tag --list 'catch-up/pre-*'
```

Report each surviving anchor to the captain and ask whether that run's landing is confirmed good and the tag is safe to drop.
Nothing deletes an anchor without that confirmation given in the moment.
Carry the answer into the Phase 1 brief: name the exact tag the crewmate may delete, or say that none may be.

`npm outdated -g` also lists `quota-axi` because of the link - that entry is informational only, never act on it directly (see Phase 2 step 3).

Firstmate's `main..upstream/main` count is an upper bound, not the real backlog: a prior upstream import that was squash-merged carries none of upstream's ancestry even though its content already landed, so every commit it absorbed is counted again - this repo's own `c26e400` ("merge current upstream firstmate into the captain's fork") is exactly that, a single-parent commit.
Skim `git log --oneline upstream/main..main` and report what is genuinely new rather than trusting the raw number, and expect the first merge after a flattened import to be a full re-import rather than a routine one.
Repairing that history is separate work on `main` and out of scope for this skill.

Report a plain table to the captain: target, commits behind, commits ours, and whether it is live-shared.
If nothing is behind anywhere, say so and stop - there is no Phase 1.

## Phase 1 - Merge work (runs hot, no freeze needed)

Every merge happens in an isolated worktree, so live agents are unaffected.
Dispatch these in parallel; they have no dependency on each other.

### quota-axi and baby-menu - delivery mode `local-only`

One crewmate each.
The brief must require:

1. Assert the worktree is not the primary clone.
2. Before merging anything, set the rollback anchor on local `main`: `git tag catch-up/pre-$(date +%y%m%d) main`.
   If Phase 0 reported a surviving prior-run anchor and the captain confirmed in that moment that it is good and safe to drop, delete exactly that tag first with `git tag -d <tag>`; otherwise leave every existing anchor alone.
   Never delete an anchor the captain has not confirmed - a prior anchor is the last known-good tip of a repo whose commits have no remote copy, and a run reaching this point proves nothing about whether the previous run's landing was actually good.
   If the create collides with a same-day tag the captain did not confirm, stop and ask rather than deleting it.
   Name `main` explicitly.
   A fresh spawn worktree's own HEAD is `origin/<default>` - the spawn path hard-resets it there - so a bare `git tag` would anchor upstream's tip and none of our commits, and the rollback below would then destroy the only copy of the patches.
   The worktree resolves the shared `main` ref regardless of where its own HEAD sits, so naming it anchors local `main`'s real tip.
   The crewmate creates this tag itself, inside its own worktree - firstmate never runs a tag or any other write command under `projects/<name>`.
   That is timing-equivalent to anchoring before dispatch: the crewmate's worktree shares one repository and one ref store with `projects/<name>`, so the tag lands on the identical pre-catch-up tip of local `main`.
   The tag is local and cheap, and it is the entire rollback story for a repo whose work has no remote copy.
3. Branch from local `main` as `fm/<task-id>`: `git switch -c fm/<task-id> main`, again naming `main` explicitly for the same reason.
   A bare `git switch -c` would branch from `origin/main` and silently drop our commits out of the merge.
   Name the dispatched task `<name>-catch-up-<yymmdd>` so that branch reads as `fm/<name>-catch-up-<yymmdd>`; the landing step below looks up `fm/<task-id>` and nothing else, so the two must agree.
4. `git merge origin/main` - a merge, never a rebase.
   Rebase rewrites our only copy of our commits; merge preserves them.
5. Resolve conflicts by keeping our behavior and adopting upstream's structure.
   When upstream restructured a file our patch lives in, port the patch onto the new structure rather than reverting either side.
6. Build, test, and lint on the project's own scripts.
   For quota-axi that is `pnpm run build && vitest run` (identical to `pnpm test`) plus `pnpm run lint`.
7. Prove each commit from the Phase 0 "ours" list still works, naming the evidence per item.
   For quota-axi that means the local providers we added still report - exercise the real CLI, not just unit tests.
8. Stop on a clean ready branch.
   Do not push.
   Do not touch the live `dist/`.

Firstmate lands it later with `bin/fm-merge-local.sh` - never a raw git merge around that guard.
That script derives the branch as `fm/<task-id>` from the task id alone and errors out if no such branch exists, which is why step 3 cannot pick any other name.
It fast-forwards the project's default branch to that branch; it requires the project checkout to already be on its default branch and clean, and it refuses (rather than forcing) a branch that is not a clean fast-forward.

### firstmate - delivery mode `no-mistakes`

One crewmate.
Same worktree assertion.
Require `firstmate-coding-guidelines` before editing, since this is shared tracked material.

1. Branch from `main` as `fm/<task-id>`, with the task named `firstmate-catch-up-<yymmdd>`.
2. `git merge upstream/main`, then immediately record the exact commit that was merged: `git rev-parse upstream/main` before the merge, or read the merge commit's second parent after it.
   Report that SHA back with the ready branch and put it in the run's intent, because Phase 3's verification needs a pinned value.
   `upstream/main` is a local remote-tracking ref that any intervening fetch - a concurrent run, `/updatefirstmate`, a pipeline step - can advance while this pipeline is running, so checking against the live ref later would fail on a perfectly intact merge.
3. Our changes are whatever `git log --oneline upstream/main..main` lists - typically the crewmate/scout adapters we added, plus any local fixes and docs.
4. Conflicts in `AGENTS.md`, `bin/`, and `.agents/skills/` are the common case.
   Upstream restructures contracts often; take upstream's structure and re-attach our additions to it rather than re-asserting our old text wholesale.
5. Run the no-mistakes pipeline through a green PR.
   Launch it normally, without `--skip=rebase`: skipping a protective pipeline step up front, to head off something that has not actually happened, trades a real safeguard for a guess.
   Phase 3 step 2 verifies the upstream merge survived the pipeline and defines the recovery if it did not, which is the only moment that check matters, and the skip belongs to that abandon-and-restart path alone - never to the first attempt.

A large merge (dozens of upstream commits) is normal here and is not a reason to split the work.
Splitting an upstream merge into partial merges creates a half-merged tree that is harder to reason about than one big conflict pass.

## Phase 2 - Quiet window

Only the live-shared targets need this.
It is short - land, rebuild, update, smoke test.

### Entry gate

All of these must hold before touching anything in this phase:

- No live crewmate anywhere, checked across the main home and every registered secondmate home in `data/secondmates.md`, with one exclusion.
  Check each home's task records, not just this one's.
  The exclusion is this run's own Phase 1 workers - the quota-axi, baby-menu, and firstmate crewmates - and it applies to a worker only once it is confirmed done on a clean ready branch, reconciled against its current state the same way you would check any worker, not merely inferred from the absence of a wake.
  A confirmed-done Phase 1 worker is expected to still be here: Cleanup deliberately keeps it alive until Phase 2 has landed and smoke-tested its work, so its presence is not a disturbance.
  A Phase 1 worker that has not reported done blocks the gate exactly like a foreign worker, because landing a half-resolved merge would fast-forward local `main` onto it and, for quota-axi, ship that broken build to every home.
  Every other worker anywhere blocks the gate and must be absent.
  Do not re-tighten this into "no crewmate at all" - that gate can never open on a run that had work to do.
- No no-mistakes validation run in flight anywhere, with one exclusion.
  A daemon reset mid-run strands a branch in custody.
  The exclusion is this run's own firstmate landing PR once it has reached checks-passed: green-but-unmerged, it does not block entry to this phase, so Phase 2 can proceed while Phase 3 waits on the captain.
  Without that exclusion this gate would never open, since Phase 1 always ends with a green firstmate PR that Phase 3 has not merged yet, and the two phases are deliberately independent.
  This is the general entry gate and it is the more permissive of the two rules about that PR; step 4's `no-mistakes update` check below is narrower and still treats the same green-but-unmerged PR as in flight.
  Do not conflate them: passing this gate says nothing about whether step 4 may run.
- Away mode off (`state/.afk` absent).
  Do not do this unattended.
- The captain is not mid-review in a Lavish session that a `lavish-axi` update would disturb.

If the gate does not hold, stop and tell the captain exactly which home is busy and which worker it is.
Do not kill anything to force the gate - Phase 1's work is already banked on ready branches and waits fine.

### Order - smallest blast radius first, smoke test between each

1. **baby-menu** - land with `bin/fm-merge-local.sh`.
   Nothing else depends on it.
   (This one does not actually need the gate; it can also land at the end of Phase 1.)
2. **quota-axi** - land with `bin/fm-merge-local.sh`, then rebuild the clone.
   The landing leaves `dist/` stale, and the primary clone's `dist/` is what the global symlink resolves to, so the rebuild has to happen there and nowhere else - a crewmate worktree's `dist/` is not what the global command reads, which is why the Phase 1 brief tells the crewmate to leave the live `dist/` alone.
   Present the rebuild command to the captain verbatim - `pnpm run build`, run in `projects/quota-axi` - and wait for approval.
   On approval run exactly that one command and nothing else.
   Invoking `/catch-up` is not that approval.
   It is given in the moment, for this run, for that one command; it grants no standing authority, and it never carries over to another command, another clone, or a future run.
   Every run asks again.
   Then immediately smoke the *global* command: `quota-axi` must return real data.
   The npm link means a broken build breaks dispatch for every home.
   Do not proceed until it answers.
3. **npm axi tools** - `npm update -g gh-axi lavish-axi chrome-devtools-axi tasks-axi`.
   Smoke each one (for example `gh-axi repo view`, `tasks-axi list`, and a bare invocation of `lavish-axi` and `chrome-devtools-axi` to confirm each binary still responds) before moving on.
   Never `npm update -g quota-axi` - that would replace our patched clone with the registry copy and destroy our only copy.
4. **no-mistakes** - before running anything here, confirm there is no active no-mistakes background monitor on this run's own firstmate landing PR, for example with `no-mistakes axi status` for that task.
   **A green-but-unmerged PR still under background monitoring counts as in flight for this check**, even though its own synchronous gate run already returned checks-passed - that is exactly the case this check exists to catch, because `no-mistakes update` resets the shared daemon and would strand the branch Phase 3 still needs.
   This is a check on one command, not an ordering rule: Phase 3 is never gated on Phase 2.
   If the monitor is clear, run `no-mistakes update`, then confirm the daemon came back and `no-mistakes --version` reports the new release.
   If the monitor is still active, skip this step for this run and finish the other three normally.
   That is the expected outcome on an ordinary run, not a fault: Phase 1 ends with a green firstmate PR, Phase 3 waits on the captain, and monitoring is simply still on.
   Tell the captain plainly that the no-mistakes tool update was deferred and why; it runs on a later `/catch-up` once that PR has landed.

Release the gate and tell the captain what moved.

## Phase 3 - firstmate landing

Separate from Phase 2 and not gated by it.

1. Captain approves the PR merge (standing `yolo` does not cover this - it changes every home's instructions).
2. Before merging, confirm the PR head still carries the upstream merge.
   The pipeline runs a `rebase` gate agent, and a rebase that linearizes this branch would drop the merge commit before the PR is merged, at which point step 3's `--merge` preserves nothing.
   The check is one ancestry test against the SHA Phase 1 recorded: `git merge-base --is-ancestor <recorded-upstream-sha> <pr-head>` must succeed.
   Use the recorded SHA, never the live `upstream/main` ref, which may have moved since the merge.
   Read `<pr-head>` as `branch_sync.pipeline.pushed_head` from `no-mistakes axi status` for that task - the commit the PR actually points at - and fetch it first if it is not present locally.
   Never test the local `fm/<task-id>` ref: the pipeline-pushed head can be ahead of or different from it, which is the whole reason `no-mistakes axi sync` exists, so a linearization that lives only on the pushed head would pass a check run against the stale local ref.
   Do not test the PR head's own parent count: the pipeline commits its gate fixes on top of the branch, so the head is normally a single-parent fix commit even when the merge is intact deeper in the history.
   If the ancestry test passes, the structure is intact - go to step 3.
   If it fails, the branch lost its merge commit somewhere in the pipeline.
   That branch is abandoned, not repaired - a commit that no longer exists cannot be recovered by re-running anything on the same branch, and `--skip=rebase` on an already-linearized branch is inert.
   Stop, do not merge, abandon the branch and its PR, have the firstmate worker re-branch fresh from local `main`, redo `git merge upstream/main` (recording the newly merged SHA as in Phase 1 step 2), and start an entirely new pipeline run for that fresh branch with `no-mistakes axi run --skip=rebase --intent ...` (`--skip` takes comma-separated pipeline steps; `--intent` is required to start a run).
   Never a bare re-run or a fix attempt on the branch that already lost the merge.
   Re-check this step on the new PR head before merging.
3. Merge with an explicit non-squash method: `bin/fm-pr-merge.sh <id> <pr url> -- --merge`.
   This PR's content is a real `git merge upstream/main`, and `bin/fm-pr-merge.sh` squashes on GitHub when the caller names no method, which would flatten that merge and drop `upstream/main` from `main`'s ancestry - leaving the next catch-up run's behind-count wrong and its merge re-applying commits we already have.
   That flag is for this landing PR only; it says nothing about how other PRs in this repo should merge.
4. Run `/updatefirstmate`.
   That path fast-forwards this home and every secondmate home, skips any home that is not a clean fast-forward, never touches gitignored operational dirs, and nudges each updated home to re-read its instructions.
   It is safe with secondmates running, which is why we use it instead of hand-rolling the propagation.
5. Re-read `AGENTS.md` in this session and restart supervision - `bin/` changed underneath the running session.
6. Report any home `/updatefirstmate` skipped; a skipped home is still on the old instructions.

## Rollback

- Patched clone: abandon the unmerged branch, or undo a landing with `git -C projects/<name> reset --hard catch-up/pre-<date>`.
  That reset is a `projects/` write, so it runs the same way as the other named points: present that literal command to the captain and wait for approval before running it.
  Invoking `/catch-up` is not that approval; it is given in the moment, for this run, for that one command, grants no standing authority, and never carries over to another command, another clone, or a future run.
  `main` was never touched until `fm-merge-local.sh` ran, and the tag anchors it if it was.
  This is the one sanctioned exception to the never-reset-hard rule above, and it is narrow: the target is always the `catch-up/pre-<date>` tag Phase 1 dropped as the rollback anchor, which by construction already contains every one of our commits.
  It is only ever used to undo a landing that tag anchors.
  Never reset without that tag as the target, never as a bare force-reset, and never as a way to discard work - the never-push, never-force, never-discard rule stands in full otherwise.
- npm tool: `npm install -g <tool>@<previous version>` from the `Current` column captured in Phase 0.
  Capture it - that column is the rollback record.
  This bullet covers `gh-axi`, `lavish-axi`, `chrome-devtools-axi`, and `tasks-axi` only.
  quota-axi is not an npm tool for rollback purposes even though `npm outdated -g` lists it: `npm install -g quota-axi@<version>` would replace the symlink into `projects/quota-axi` with the registry copy and destroy our only copy of the patches, exactly as `npm update -g quota-axi` would.
  Roll quota-axi back through the `catch-up/pre-<date>` tag above, then rebuild the clone with `pnpm run build` in `projects/quota-axi` - never through npm.
  That rebuild is its own named approval point: present the literal command, wait for approval in the moment for this run, and take no standing authority from it.
- no-mistakes: reinstall the prior release; the update is not reversible in place.
- firstmate: revert the merge PR, then `/updatefirstmate` again to propagate the revert.

Keep the Phase 0 output until the whole run is verified.
It is the only record of where everything started.

## Cleanup

Tear down the Phase 1 crewmates only after their work is landed and smoke-tested.
Leave the `catch-up/pre-*` tags in place; firstmate never removes them.
An anchor is dropped only by a later run's Phase 1 crewmate, and only after that run's Phase 0 asked the captain and got confirmation that this landing was good and the tag is safe to drop.
Absent that confirmation the anchor stays, which is the point: it is the last known-good tip of a repo with no remote copy.
Append the "ours" commit lists to nothing - they are re-derivable, and stale copies rot.
