# Spec-driven delivery workflow

Audience: agent runtime.

This doc defines the spec-driven path for delivering new features, plus the metrics logging convention that measures how it performs.
On any new feature request, delivery follows the five steps in Section B: six-question intake, a spec scout, captain approval of the spec, the build, and AC-mapped verification.

The point is not the document.
Today a rough feature idea gets iterated in chat until it converges, so "what good looks like" only ever exists in that chat.
Everything downstream inherits the fog, including how much standing autonomy firstmate can safely hold, because standing autonomy is defined against accepted task criteria that are currently nowhere on disk.
Writing the criteria down is what makes them enforceable, and Section D is where they stop being advice.

Two agent-facing surfaces make this fire rather than sit here.
[`.agents/skills/spec-delivery/SKILL.md`](../.agents/skills/spec-delivery/SKILL.md) is the procedure firstmate loads at intake, and `bin/fm-spec.sh` is the mechanical enforcement.
Section F holds the `data/captain-shared.md` lines that turn the convention on for a home and its second mates.

## Section A - Intake: the six questions

On any new feature request, the first mate asks the captain these six questions in one message.
The answers go into the spec-scout brief.
This replaces open-ended idea iteration.

1. What problem, for whom? (The client's pain, not the feature's name.)
2. What does "done" look like - describe the demo you'd show the client.
3. What must NOT change?
4. Constraints the code can't see: deadlines, client politics, mandated/forbidden tech, polish level.
5. What would make you reject the PR?
6. What is explicitly out of scope?

## Section B - The workflow

1. **Intake.**
   The captain answers the six questions in one message.
2. **Spec scout.**
   Route to the client's second mate; dispatch a scout whose deliverable is a completed spec (template in Section C) as its report at `data/<id>/report.md`.
   Spec drafting counts as ambiguous investigation/design work - use the strongest configured model and effort per the dispatch rules.
3. **Approval.**
   Run `bin/fm-spec.sh check <spec>` first, so an incomplete spec never reaches the captain.
   The first mate then relays the spec plus open questions with recommended defaults (use `lavish-axi` when several options benefit from a visual surface).
   NO ship task starts before the captain says "approved."
   Redlines go back to the same scout.
4. **Build.**
   Single-task feature: promote the scout with `bin/fm-promote.sh`.
   Multi-task: decompose per template section 12.
   Each ship brief's acceptance-criteria block is that task's ACs from the spec, verbatim; `bin/fm-brief.sh --spec` writes them and pins the two enforcement commands into the worker's definition of done.
   Allowed files per task are the union of spec sections 3 and 12, plus the tests section 8 already maps and the spec file itself; files in section 9 are off-limits and win over all of it.
5. **Verify.**
   Every AC gets a test named for it (e.g. `test_ac_3_...`).
   The client's existing suite stays green.
   PR description is an AC checkbox table plus diffstat plus one line confirming no out-of-scope files changed.

## Section C - The spec template

Two tiers.
FULL for features.
LIGHT is sections 1, 3, 7, 9 only, for small fixes.
The second mate proposes the tier at intake; the captain can override.

A few parts of this template are read by `bin/fm-spec.sh` and therefore have an exact shape: the tier line, the section headings, the `AC-<n>` ids, the `Answer:` marker in section 10, the backtick-quoted paths in sections 3, 9, and 12, and the section 8 table rows.
That script's header is the single owner of those conventions; do not restate them here.

```markdown
# Spec: <feature name>          ID: <client>-<seq>    Tier: FULL
Status: DRAFT -> CAPTAIN-APPROVED -> IN-BUILD -> VERIFIED

## 1. Problem statement                       [captain]
One paragraph: who hurts, what happens today, why now.

## 2. User-facing behavior                    [captain sketches -> scout makes precise]
Concrete before/after. UI: every state incl. empty/error/loading.
API: example request/response pairs.

## 3. Existing-system touchpoints             [scout]
Files/modules/services touched, with paths in backticks. Current behavior
of each. Client conventions that constrain design (framework, patterns,
test setup, CI commands). Tests named in section 8 need not be repeated
here.

## 4. Interfaces & contracts                  [scout]
New/changed signatures, routes, events, schemas - exact and
copy-pasteable. Backward-compatibility notes.

## 5. Data model                              [scout]
Schema changes, migrations (forward AND rollback), volume assumptions.

## 6. Edge cases & failure behavior           [scout drafts; captain adds business edges]
Enumerated: input extremes, concurrency, partial failure, permissions.
Expected behavior for each.

## 7. Acceptance criteria                     [scout drafts; captain approves]
AC-1 ... AC-n. Each is one testable Given/When/Then statement.
Untestable wishes go to section 10 until sharpened. These become the
crewmate briefs' acceptance criteria verbatim and bound yolo authority.

## 8. Test plan                               [scout]
Table: AC-id -> test name/location -> type (unit/integration/e2e) ->
new/existing. Plus the client's existing suite command that must
stay green.

## 9. Out of scope                            [captain]
Explicit non-goals, with paths in backticks.

## 10. Open questions                         [scout asks; captain answers]
Question, why it blocks, scout's recommended default, and the captain's
`Answer:`. Unanswered = not approvable.

## 11. Risk & rollout                         [scout]
Blast radius if wrong. Feature flag? Migration order? Anything
client-visible mid-rollout.

## 12. Task decomposition                     [second mate, after approval]
Ordered ship tasks; per task: spec sections implemented, ACs owned,
files it may touch in backticks. Parallelize only truly independent tasks.
```

## Section D - Verification rules

The scope and mapping checks here are mechanical, not editorial.
`AGENTS.md` section 7 forbids holding work outside its selected delivery path for a manual clean verdict and forbids stacking serial manual reviews, so this workflow adds no reviewer role, human or agent.
What it adds is two commands with exit codes:

- `bin/fm-spec.sh scope <spec>` compares the branch's changed files against the union of sections 3 and 12, and against section 9.
  A test path section 8 already maps to a criterion counts as declared, as does the spec file itself when it lives in the repo it governs, so a spec never has to name the same path twice; `bin/fm-spec.sh`'s header owns that rule.
  Requiring the repetition would be bookkeeping authors forget, and each forgotten one would be a false escalation: `ac` demanding a test that `scope` then rejects, with no in-scope way out for the worker.
- `bin/fm-spec.sh ac <spec>` checks that every acceptance criterion maps to a test that actually exists where section 8 says it does.

Both run in the worker before it reports done, and again inside the task's own validation run.
Both fail loudly, naming every offending path or criterion.
An AC without a mapped passing test blocks the PR, unless the spec marks that AC `manual-check` with a stated reason.
The captain's own read of the PR stays exactly what it always was.

Honest limits, kept in front of the reader on purpose:

- Agents can write weak tests that trivially pass.
  `ac` proves a mapped test exists; it cannot prove the test is strong.
  The AC table makes the captain's PR review fast; it does not replace it.
- "Each criterion is a single testable statement" is not mechanically decidable.
  `check` enforces only what a machine can see, and the captain's approval remains the judgement that a criterion is genuinely testable.
- Open item: verify on one real task that a brief instruction can control the PR body under the full validation path.
  If the pipeline owns the PR body, put the AC table in a PR comment instead.

## Section E - Metrics log

The captain's time is the scarce resource and nothing currently measures where it goes.
This log exists to answer one question: which interruptions should be automated away next.
That makes the escalation-type histogram the number that matters, not the row count.

- File: `data/metrics.csv` (private, gitignored, never committed).
- Header: `date,project,task_id,kind,dispatched,pr_opened,merged,captain_msgs,escalations,escalation_types,rework_48h`
- One row per completed ship task, appended at teardown with `bin/fm-metrics.sh append`.
  Scouts optional.
- `escalation_types`: semicolon-joined from decision, blocker, credential, merge, destructive, other.
- `rework_48h`: 1 if a follow-up fix for the same feature lands within 48h of merge, else 0.
  It is only knowable after the fact, so correct it retroactively with `bin/fm-metrics.sh rework <task-id>`.

Reads and writes are deliberately asymmetric, because the fleet is four homes and a per-home number reported as a fleet number is a wrong number that looks right.

- **Every home appends to its own file only.**
  The main home and each second mate write `data/metrics.csv` under their own `FM_HOME`, never another home's.
  That keeps writes local and needs no cross-home locking.
- **The main home's `bin/fm-metrics.sh summarize` is the only fleet-level read.**
  It reads this home's file plus every registered second mate home's file, resolved from `data/secondmates.md`, and reports both the fleet total and the per-home split.
- **A second mate home whose file is missing is reported as "no rows".**
  It is never silently skipped and never counted as zero work, because those mean different things.
  A remote second mate's file lives on another host and is reported as not readable from here, for the same reason.

Weekly review: the captain asks for a metrics summary, and the first mate runs `bin/fm-metrics.sh summarize` in the main home.
`bin/fm-metrics.sh`'s header owns the exact flags and validation.

## Section F - Turning it on

These lines activate the convention for a home and its second mates.
They belong in `data/captain-shared.md`, the main-authoritative shared captain-preference file that propagates read-only into second mate homes at the next session-start sync.

That file is private state, not tracked material, and creating or updating it is owned by the [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) skill's inherited-local-material contract, including its header requirements and its inspect-then-update discipline.
It is currently absent in the main home, so firstmate performs that step through that skill after this document lands, which is what makes the lines below point at something real.

```
- Feature delivery: for any new feature request, follow docs/spec-workflow.md -
  six-question intake, spec scout, my approval on the spec before any ship task.
- Metrics: on every ship-task teardown, append one row with bin/fm-metrics.sh
  per docs/spec-workflow.md Section E.
- Escalations: when I approve an escalation unchanged, propose a standing rule
  for this file so that class stops reaching me.
```
