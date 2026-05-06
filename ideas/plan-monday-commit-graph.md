# Plan + Monday + Commits — unified work graph

**Status:** Idea / parked
**Date:** 2026-04-23
**Related code:** `lisp/monday-docs-sync.el` (one-way push today),
`skills/design/SKILL.md`, `ideas/org-monday-sync-architecture.md` (deeper
sync architecture research)

## Context

Three separate tracking surfaces exist for the same work:
- **Monday.com**: feature cards, sprints, assignments, status columns
- **Org plans** (`plans/*.org`): design docs with Steps, CLARIFYs, Open
  questions
- **Git**: commits, branches, PRs — the actual implementation

They don't talk to each other:
- Monday docs sync is one-way push (org → Monday) — see existing
  `monday-docs-sync.el`.
- Plans don't know which Monday card they serve.
- Commits don't update plan Step status.
- Monday doesn't know when a plan is drafted against one of its cards.

Result: three sources of truth, constant manual status-update tax, and
no mechanism for the AI to understand *what* you're actually working on
unless you re-explain it every session.

## The idea

Thread all three through a shared identity: the **Monday card ID**.

Concrete mechanics:

1. **`/design @CARD-123`** — authoring flow accepts a Monday reference.
   The skill pulls the card (title, description, acceptance criteria,
   comments) as seed context for the plan. Plan frontmatter gets
   `:monday: CARD-123`, plan filename includes the slug.

2. **Monday → org index.** A pull-mode sync dumps "my current sprint +
   assigned to me" into `~/.spacemacs.d/plans/INDEX.org` — a flat org
   file listing in-flight cards with their status, updated daily. This
   becomes the user's "what's on my plate" dashboard, bidirectionally
   linked to any existing plan files.

3. **Commit → plan → Monday.** Branch named `CARD-123-foo` or commit
   message mentioning `CARD-123`: post-commit hook finds the matching
   plan, marks Steps DONE if referenced, and updates Monday card status
   (Backlog → In Progress → Done) when the plan's overall state
   changes.

4. **Plan → Monday status updates.** When a plan enters "all Steps DONE,
   all CLARIFYs resolved", push a comment to the Monday card with the
   plan's distilled retrospective (see `executable-plans.md` idea #5 —
   end-of-plan distillation). The card's activity feed becomes the
   status update.

5. **Pre-populate `/design` context from Monday.** When drafting a plan
   for a known card, the AI sees the card's full history: previous
   comments, linked cards, attached files, assignee's last update. No
   need for the user to paste context — the graph is queryable.

## Why this matters

- Status updates are a tax. Removing it (or having it auto-generated
  from truth) is a large weekly time saving.
- The AI gets contextual grounding it can't get otherwise. "What am I
  working on?" becomes a *queryable* question, not a conversation
  re-orientation.
- Org plans today are orphan files; naming conventions carry the only
  thread to Monday. Formalising the link makes plans first-class
  artifacts in the PM flow.

## Design sketch

### Schema additions

Every plan file gets frontmatter:
```org
#+PROPERTY: monday_card CARD-123
#+PROPERTY: monday_board BOARD-456
#+PROPERTY: status in-progress
```

Git branches follow: `<card-id>-<short-slug>` (e.g. `MON-2401-rate-limiter`).

Commits reference card in message: `[MON-2401] implement Step 3`.

### Data flow

```
Monday API  ─────→  ~/.spacemacs.d/plans/INDEX.org  (pull, nightly)
    ▲                       │
    │                       │ user clicks a card
    │                       ▼
    │               /design @MON-2401  ──→  plan file with :monday: MON-2401
    │                                              │
    │                                              │ user works, commits
    │                                              ▼
    └───── card status update ← post-commit hook ──┘
           + retrospective
```

### Bidirectional sync — the hard part

Parked in `ideas/org-monday-sync-architecture.md` already. Summary:
true bidirectional org ↔ Monday doc sync needs a persisted baseline so
three-way merge can detect remote changes. That's a separate,
substantial project. **This idea does not require that.** Status column
updates and activity-feed comments are a much simpler surface — single
direction, write-only to Monday, via GraphQL mutations the existing
`monday-docs-sync.el` already knows how to make.

### Scope boundary

This idea intentionally stops at the *coordination* layer:
- Status column updates
- Activity feed comments (retrospective, daily summary)
- Card-metadata → plan-context injection

It does **not** try to sync the plan's body to a Monday doc
bidirectionally. That's the separate parked project. Status+comments is
an 80/20 win.

## Open questions / tensions

- **Which Monday column becomes "status"?** Boards differ. Need a
  per-board or per-user config saying "this column is the lifecycle."
- **What counts as "all Steps DONE"?** If Steps are optional (see
  executable-plans.md), the DONE signal is user-driven — safe. If
  auto-DONE from tests, the auto-push could fire on flaky tests.
- **Conflict policy**: user moves card manually to "Done" in Monday
  while plan has open CLARIFYs. Do we warn? Reconcile silently?
  Start with warn-only.
- **Comment spam**: every commit triggers a card activity. Batch daily,
  or only at state transitions (Backlog→WIP, WIP→Review, Review→Done).
- **Offline work**: branch/commit while offline, sync on next pull.
  Idempotency of status writes matters.

## Minimal v1

1. Add `:monday:` property reader in `monday-docs-sync.el` — if set,
   use as the card ID.
2. Nightly pull: "my assigned cards" → INDEX.org. Use existing GraphQL
   auth.
3. `/design @CARD-ID` subcommand: pull card body, prepend to plan seed
   context.
4. Status-column update on plan state transition: single mutation.
5. No git-hook integration yet — manual "update card from plan" command
   first. Once reliable, wire the hook.

Total: maybe 1-2 days of work on top of `monday-docs-sync.el`.

## Dependencies

- `monday-docs-sync.el` is the foundation (✅).
- Monday API token is configured (assumed ✅).
- Plan files use consistent frontmatter (✅ via skill).
- Executable-plans idea (`executable-plans.md`) strengthens the
  "plan DONE → card DONE" trigger — the two ideas compound.
