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
Exactly two commands in this whole skill run under a concrete captain approval given in the moment - the fetch pair in Phase 0 and the rebuild in Phase 2 step 2 - and nothing else in this skill runs that way.

## Phase 0 - Recon

Moves no branch and lands no commit anywhere.
Safe at any time, with any amount of work running.
Never skip it.

Start with the part that needs no approval:

```
git -C . fetch upstream --quiet
git rev-list --count main..upstream/main
npm outdated -g --depth=0
no-mistakes --version
```

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

`npm outdated -g` also lists `quota-axi` because of the link - that entry is informational only, never act on it directly (see Phase 2 step 3).

Report a plain table to the captain: target, commits behind, commits ours, and whether it is live-shared.
If nothing is behind anywhere, say so and stop - there is no Phase 1.

## Phase 1 - Merge work (runs hot, no freeze needed)

Every merge happens in an isolated worktree, so live agents are unaffected.
Dispatch these in parallel; they have no dependency on each other.

### quota-axi and baby-menu - delivery mode `local-only`

One crewmate each.
The brief must require:

1. Assert the worktree is not the primary clone.
2. Before merging anything, drop the rollback anchor on local `main`: `git tag catch-up/pre-$(date +%y%m%d) main`.
   Name `main` explicitly.
   A fresh spawn worktree's own HEAD is `origin/<default>` - the spawn path hard-resets it there - so a bare `git tag` would anchor upstream's tip and none of our commits, and the rollback below would then destroy the only copy of the patches.
   The worktree resolves the shared `main` ref regardless of where its own HEAD sits, so naming it anchors local `main`'s real tip.
   The crewmate creates this tag itself, inside its own worktree - firstmate never runs a tag or any other write command under `projects/<name>`.
   That is timing-equivalent to anchoring before dispatch: the crewmate's worktree shares one repository and one ref store with `projects/<name>`, so the tag lands on the identical pre-catch-up tip of local `main`.
   In the same step, delete any surviving `catch-up/pre-*` tag from an earlier run with `git tag -d <tag>`, including one from earlier the same day - reaching this point proves that run landed and no longer needs its anchor, and a same-day leftover would otherwise make this run's `git tag` fail.
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
2. `git merge upstream/main`.
3. Our changes are whatever `git log --oneline upstream/main..main` lists - typically the crewmate/scout adapters we added, plus any local fixes and docs.
4. Conflicts in `AGENTS.md`, `bin/`, and `.agents/skills/` are the common case.
   Upstream restructures contracts often; take upstream's structure and re-attach our additions to it rather than re-asserting our old text wholesale.
5. Run the no-mistakes pipeline through a green PR.

A large merge (dozens of upstream commits) is normal here and is not a reason to split the work.
Splitting an upstream merge into partial merges creates a half-merged tree that is harder to reason about than one big conflict pass.

## Phase 2 - Quiet window

Only the live-shared targets need this.
It is short - land, rebuild, update, smoke test.

### Entry gate

All of these must hold before touching anything in this phase:

- No live crewmate in **any** home - the main home and every registered secondmate home in `data/secondmates.md`.
  Check each home's task records, not just this one's.
- No no-mistakes validation run in flight anywhere.
  A daemon reset mid-run strands a branch in custody.
- Away mode off (`state/.afk` absent).
  Do not do this unattended.
- The captain is not mid-review in a Lavish session that a `lavish-axi` update would disturb.

If the gate does not hold, stop and tell the captain exactly which home is busy.
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
4. **no-mistakes** - `no-mistakes update`, then confirm the daemon came back and `no-mistakes --version` reports the new release.

Release the gate and tell the captain what moved.

## Phase 3 - firstmate landing

Separate from Phase 2 and not gated by it.

1. Captain approves the PR merge (standing `yolo` does not cover this - it changes every home's instructions).
2. Merge with an explicit non-squash method: `bin/fm-pr-merge.sh <id> <pr url> -- --merge`.
   This PR's content is a real `git merge upstream/main`, and `bin/fm-pr-merge.sh` squashes on GitHub when the caller names no method, which would flatten that merge and drop `upstream/main` from `main`'s ancestry - leaving the next catch-up run's behind-count wrong and its merge re-applying commits we already have.
   That flag is for this landing PR only; it says nothing about how other PRs in this repo should merge.
3. Run `/updatefirstmate`.
   That path fast-forwards this home and every secondmate home, skips any home that is not a clean fast-forward, never touches gitignored operational dirs, and nudges each updated home to re-read its instructions.
   It is safe with secondmates running, which is why we use it instead of hand-rolling the propagation.
4. Re-read `AGENTS.md` in this session and restart supervision - `bin/` changed underneath the running session.
5. Report any home `/updatefirstmate` skipped; a skipped home is still on the old instructions.

## Rollback

- Patched clone: `git -C projects/<name> reset --hard catch-up/pre-<date>`, or simply abandon the unmerged branch.
  `main` was never touched until `fm-merge-local.sh` ran, and the tag anchors it if it was.
  This is the one sanctioned exception to the never-reset-hard rule above, and it is narrow: the target is always the `catch-up/pre-<date>` tag Phase 1 dropped as the rollback anchor, which by construction already contains every one of our commits.
  It is only ever used to undo a landing that tag anchors.
  Never reset without that tag as the target, never as a bare force-reset, and never as a way to discard work - the never-push, never-force, never-discard rule stands in full otherwise.
- npm tool: `npm install -g <tool>@<previous version>` from the `Current` column captured in Phase 0.
  Capture it - that column is the rollback record.
  This bullet covers `gh-axi`, `lavish-axi`, `chrome-devtools-axi`, and `tasks-axi` only.
  quota-axi is not an npm tool for rollback purposes even though `npm outdated -g` lists it: `npm install -g quota-axi@<version>` would replace the symlink into `projects/quota-axi` with the registry copy and destroy our only copy of the patches, exactly as `npm update -g quota-axi` would.
  Roll quota-axi back through the `catch-up/pre-<date>` tag above, then rebuild through Phase 2 step 2's approval-gated `pnpm run build` - never through npm.
- no-mistakes: reinstall the prior release; the update is not reversible in place.
- firstmate: revert the merge PR, then `/updatefirstmate` again to propagate the revert.

Keep the Phase 0 output until the whole run is verified.
It is the only record of where everything started.

## Cleanup

Tear down the Phase 1 crewmates only after their work is landed and smoke-tested.
Leave the `catch-up/pre-*` tags in place; firstmate never removes them.
The next catch-up run's Phase 1 crewmate deletes this anchor as its first action, at the moment it creates its own, so the anchor survives every step of this run and is cleared only once a later run starts from a landed tree.
Append the "ours" commit lists to nothing - they are re-derivable, and stale copies rot.
