---
name: spec-delivery
description: >-
  Agent-only procedure for spec-driven feature delivery.
  Use before intaking a new feature request, before dispatching a spec investigation, before asking the captain to approve a spec, and before turning an approved spec into ship tasks.
  Owns the six intake questions, the routing, the approval step, and when each enforcement command runs.
user-invocable: false
metadata:
  internal: true
---

# spec-delivery

Load this before any of these four moments:

- a new feature request arrives, before you answer it;
- you are about to dispatch the investigation that produces its spec;
- you are about to ask the captain to approve a spec;
- an approved spec is about to become ship tasks.

A bug fix, an operational chore, a follow-up correction inside an already accepted contract, and a question are not feature requests; route those the ordinary way in `AGENTS.md` section 7.
The signal is new product or client-facing behavior that does not yet exist.
If it is genuinely ambiguous, ask one concise question rather than forcing a spec onto a two-line fix.

[`docs/spec-workflow.md`](../../../docs/spec-workflow.md) owns the workflow narrative and the spec template.
`bin/fm-spec.sh` and `bin/fm-metrics.sh` own their exact commands, flags, and file formats in their headers.
Do not restate any of that here; this skill owns only the procedure and the order.

## 1. Intake

Ask the captain all six questions from `docs/spec-workflow.md` Section A in ONE message, not as a conversation.
The whole point is to replace open-ended idea iteration, so a drip of follow-ups reintroduces exactly the failure being fixed.

Carry the answers verbatim into the spec-scout brief.
They are the captain's words about the client's pain, and paraphrasing them is where "what good looks like" starts to blur.

## 2. Route and dispatch the spec scout

Route by the nature of the work against each registered second mate scope, exactly as `AGENTS.md` section 7 requires.
Client feature work belongs to that client's second mate; `local-only` work stays in the main home.

Dispatch a scout, not a ship.
Its deliverable is a completed spec at `data/<id>/report.md`, and a spec is not authorization to change code.
Spec drafting is ambiguous design work, so resolve model and effort accordingly at intake rather than defaulting low.

Propose the tier in the brief - FULL for a feature, LIGHT for a small fix - and say the captain may override it.

## 3. Approval

Run `bin/fm-spec.sh check <spec>` BEFORE the captain sees it.
An incomplete spec is firstmate's problem to send back to the scout, not the captain's to discover.
Relay the failures to the same scout and re-check.

Then relay the spec to the captain with the open questions and your recommended default for each, following `AGENTS.md` section 9: outcomes and one clear decision, not mechanics.
Use `lavish-axi` only when several options genuinely benefit from a visual surface.

No ship task starts before the captain says approved.
Approval of a spec is approval of that spec's acceptance criteria, and nothing wider.
Redlines go back to the same scout; do not open a second investigation for them.

An unresolved decision surfaced by the spec follows `decision-hold-lifecycle` like any other.

## 4. Build

Single-task feature: promote the existing scout with `bin/fm-promote.sh` rather than creating a duplicate task.
Multi-task: decompose per the spec's section 12, and serialize only for a true dependency - `AGENTS.md` section 7 owns that judgement.

Scaffold each ship brief with `bin/fm-brief.sh --spec <spec>`, adding `--spec-ac` when the spec's section 12 gives that task a subset of the criteria.
That flag is what turns the spec into the worker's contract: it carries the criteria verbatim and pins `bin/fm-spec.sh scope` and `bin/fm-spec.sh ac` into the definition of done.
Writing the criteria into a brief by hand instead leaves the enforcement out, which is the whole failure this path exists to prevent.

The acceptance criteria in the brief are also the bound on standing `yolo` authority for that task, exactly as `ask-user-authority` uses accepted task criteria.
This is the payoff for writing them down: autonomy can be judged against something on disk.

## 5. Verify and record

The worker runs `bin/fm-spec.sh scope` and `bin/fm-spec.sh ac` before reporting done, and the task's own validation run repeats them.
Do not add a review step on top of that; `AGENTS.md` section 7 forbids it and `docs/spec-workflow.md` Section D explains why the checks are mechanical instead.

After the task lands and is cleaned up, append its metrics row with `bin/fm-metrics.sh append`.
Record what actually happened, including the escalations you had to raise: that histogram is the input to deciding which interruptions to automate away next, so a flattering row is a wasted row.
If a follow-up fix for the same feature lands within 48h, correct the row with `bin/fm-metrics.sh rework`.

Only the main home reads the fleet-wide numbers, and only with `bin/fm-metrics.sh summarize`.
