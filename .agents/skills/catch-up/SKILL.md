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

## Phase 0 - Recon

Read-only.
Safe at any time, with any amount of work running.
Never skip it.

```
git -C . fetch upstream --quiet
git rev-list --count main..upstream/main
git -C projects/quota-axi fetch origin --quiet
git -C projects/quota-axi status -sb
git -C projects/baby-menu fetch origin --quiet
git -C projects/baby-menu status -sb
npm outdated -g --depth=0
no-mistakes --version
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

Before dispatching each patched clone, drop a rollback anchor on local `main`:

```
git -C projects/<name> tag catch-up/pre-$(date +%y%m%d)
```

The tag is local and cheap, and it is the entire rollback story for a repo whose work has no remote copy.

### quota-axi and baby-menu - delivery mode `local-only`

One crewmate each.
The brief must require:

1. Assert the worktree is not the primary clone.
2. Branch from local `main` as `fm/<name>-catch-up-<yymmdd>`.
3. `git merge origin/main` - a merge, never a rebase.
   Rebase rewrites our only copy of our commits; merge preserves them.
4. Resolve conflicts by keeping our behavior and adopting upstream's structure.
   When upstream restructured a file our patch lives in, port the patch onto the new structure rather than reverting either side.
5. Build, test, and lint on the project's own scripts.
   For quota-axi that is `pnpm run build && vitest run` (identical to `pnpm test`) plus `pnpm run lint`.
6. Prove each commit from the Phase 0 "ours" list still works, naming the evidence per item.
   For quota-axi that means the local providers we added still report - exercise the real CLI, not just unit tests.
7. Stop on a clean ready branch.
   Do not push.
   Do not touch the live `dist/`.

Firstmate lands it later with `bin/fm-merge-local.sh` - never a raw git merge around that guard.
That script fast-forwards the project's default branch to the crewmate's `fm/<id>` branch; it requires the project checkout to already be on its default branch and clean, and it refuses (rather than forcing) a branch that is not a clean fast-forward.

### firstmate - delivery mode `no-mistakes`

One crewmate.
Same worktree assertion.
Require `firstmate-coding-guidelines` before editing, since this is shared tracked material.

1. Branch from `main` as `fm/firstmate-catch-up-<yymmdd>`.
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
2. **quota-axi** - land with `bin/fm-merge-local.sh`, then rebuild in the clone (`npm run build`), then immediately smoke the *global* command: `quota-axi` must return real data.
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
2. Merge with `bin/fm-pr-merge.sh`.
3. Run `/updatefirstmate`.
   That path fast-forwards this home and every secondmate home, skips any home that is not a clean fast-forward, never touches gitignored operational dirs, and nudges each updated home to re-read its instructions.
   It is safe with secondmates running, which is why we use it instead of hand-rolling the propagation.
4. Re-read `AGENTS.md` in this session and restart supervision - `bin/` changed underneath the running session.
5. Report any home `/updatefirstmate` skipped; a skipped home is still on the old instructions.

## Rollback

- Patched clone: `git -C projects/<name> reset --hard catch-up/pre-<date>` on the *branch*, or simply abandon the unmerged branch.
  `main` was never touched until `fm-merge-local.sh` ran, and the tag anchors it if it was.
- npm tool: `npm install -g <tool>@<previous version>` from the `Current` column captured in Phase 0.
  Capture it - that column is the rollback record.
- no-mistakes: reinstall the prior release; the update is not reversible in place.
- firstmate: revert the merge PR, then `/updatefirstmate` again to propagate the revert.

Keep the Phase 0 output until the whole run is verified.
It is the only record of where everything started.

## Cleanup

Tear down the Phase 1 crewmates only after their work is landed and smoke-tested.
Drop the `catch-up/pre-*` tags once the captain confirms the new state is good.
Append the "ours" commit lists to nothing - they are re-derivable, and stale copies rot.
