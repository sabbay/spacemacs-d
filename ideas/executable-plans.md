# Executable Plans — close the plan → execute → reflect loop

**Status:** Idea / parked
**Date:** 2026-04-23
**Related code:** `skills/design/SKILL.md`, `lisp/claude-collab.el` (CLARIFY nav, annotations)

## Context

Today `/design` writes structured org plans with Steps, Properties, Tests, Open
questions. Once written, plans are **dead documents** — execution happens by the
user retyping intent ("now implement Step 3"). The plan's structured metadata
(Step properties, :tests:, :verify:, :changed:) isn't used to drive anything.

Plans also don't learn from their own execution: when a Step surfaces a
surprise, when a Risk materialises, when an Open question gets answered in
chat — none of that flows back into the plan or into memory.

## The idea

Make plans **executable workspaces**, not documents.

Three mechanics:

1. **Execute a Step from the buffer.** `SPC o c x` on a Step heading invokes
   Claude with that Step's full context as input: goal, properties, :tests:
   expectations, :verify: checks, files in :changed:, and the Approach section
   of the plan for framing. Edits go through the existing annotation/review
   flow. When the Step's tests pass, auto-mark DONE. This turns the plan from
   a *spec* into a *runbook*.

2. **Git → plan feedback.** `post-commit` hook (via claude-collab or a git
   hook) scans commit messages for `Step-N` or `plans/xxx.org#Step-N`
   references. On match: mark the Step DONE, append commit SHA + files to the
   Step's `:changed:` property, and if the commit message surfaces a surprise
   (grep for "turns out", "actually", "had to"), file a new bullet under Risks
   or Open questions. The plan becomes the auditable history of the feature.

3. **End-of-plan distillation.** When all Steps are DONE and all Open questions
   closed, a subagent reads the plan + git history for the feature and
   produces: (a) a short retrospective at the plan's tail (what surprised us,
   what we'd do differently), (b) 1-3 memory entries if any lessons are
   transferable (e.g. "this codebase's test runner swallows stderr — always
   check exit code separately"), (c) a one-line summary for Monday sync.

## Why this matters

- Plans today incur full design cost but only pay back on the one-shot
  implementation they spawn. Making them executable + reflective compounds:
  each finished plan feeds memory that improves the next plan's authoring.
- The CLARIFY loop + annotations are a review-time HITL flow. Adding
  execute-from-buffer extends HITL to the *act* itself, not just review.
- Git as the feedback channel is free — you already commit. The plan just
  starts listening.

## Open questions / tensions

- **Step-scoped Claude context vs. full repo context.** Executing a Step
  should focus Claude on *just* that Step's domain, but some Steps depend
  on state established by earlier Steps. Do we feed prior Steps' summaries,
  or re-read relevant files, or just trust the plan's Approach section?
- **Trigger for "Step done"**: tests passing, or explicit user mark? Automatic
  green-test DONE is tempting but fragile (flaky tests, missing coverage).
  Start with user-mark, add auto-DONE later with opt-in.
- **`:tests:` contract**: the skill today says Steps *should* have tests
  expressed as shell-runnable commands. Not all Steps are testable this way
  (prose-only, config changes). Need a fallback :verify: convention.
- **Retrospective prompt quality**: distilling a 20-commit feature into 3
  memories is hard. Risk of noisy/redundant memories. Start manual-triggered,
  let user curate; automate once the signal is clear.

## Sketch of minimal v1

1. Add `claude-collab-execute-step-at-point` — reads Step heading + its
   subtree, builds a prompt, sends via Claude Code CLI with the plan file as
   working context.
2. Add a git `post-commit` shell hook (installed by an opt-in command) that
   appends SHA+files to Step `:changed:` on match.
3. Distillation: manual for now. `/design retrospect` subcommand scoped to a
   plan file.

All three are additive — existing `/design` and CLARIFY flows keep working
unchanged.

## Dependencies / prerequisites

- Stable CLARIFY workflow (✅ just shipped the menu/HUD).
- `claude-collab-apply-*` is robust enough to be the primary edit channel for
  automated Steps (✅ bounds validation + conflict detection already there).
- The Agent SDK review-before-apply hooks would amplify this — Step execution
  could pause at every tool call for approval. Not required for v1, but
  natural next step.
