# Org ↔ Monday Sync — Architecture Research

**Status:** Exploratory / parked
**Date:** 2026-04-23
**Related code:** `lisp/monday-docs-sync.el` (current one-way push, ~1200 LOC Elisp)

## Context

Today we have a one-way org → Monday docs sync implemented entirely in Elisp
(`monday-docs-sync.el`). It parses org, renders PlantUML/Excalidraw, and pushes
Monday doc blocks via GraphQL. It stores no baseline of Monday's state, so it
can't detect remote changes or do a real merge.

**Goal:** make the sync bidirectional, testable, faster to iterate on, and
capable of handling Monday API complexity (30+ column types, rich doc blocks,
rate-limited GraphQL).

## The initial idea we started with — and why it was wrong

First instinct: rewrite the sync logic in TypeScript using Monday's official
SDK (`@mondaydotcomorg/api`), call it from Elisp as a CLI. Motivated by:
- Testability (Elisp is hard to test)
- Dev speed (TS tooling, debugger, types)
- Monday API complexity (typed SDK instead of raw GraphQL)

**The reframe that matters:** this is a *language* rewrite, not an
*architecture* change. The actual problem isn't the language — it's that
there's no baseline state, so three-way merge is impossible regardless of
implementation language.

## Key findings on Monday's TS SDK

- **`@mondaydotcomorg/api`** (v14 as of April 2026) is the official server-side
  TS client. Typed wrapper around `graphql-request` with codegen from Monday's
  schema.
- **`monday-sdk-js`** server half is unloved but not formally removed.
- SDK is **thin** — it gives typed reads and GraphQL plumbing. It does NOT
  solve: doc diffing, column-value coercion (writes still hand-craft per-type
  JSON), rate budgeting, or doc-block change detection.
- **Hard gap in Monday's API:** no doc-block-level webhooks, no reliable
  doc-block `updated_at`. Docs must be poll-and-hash-diff.
- **Boards have** webhooks (`change_column_value`, `create_item`, etc.) +
  `activity_logs`. Event-driven sync possible on the board side.
- New-ish: `create_doc_blocks` bulk mutation (up to 25 blocks/call).
- `monday-mirror` (internal) chose raw GraphQL over the SDK — worth checking
  `~/Development/monday-mirror/packages/cli` before committing either way.

## Alternative sync architectures considered

### Promising

**1. SQLite-as-intermediate (the magit-forge pattern) — the likely winner.**
- Both sides materialize into a local `monday-sync.db`.
- Org→DB (parser, already have it), Monday→DB (GraphQL poll + webhooks).
- Reconcile via SQL diff against stored `updated_at` / content hash baseline.
- Emacs 29+ has built-in `sqlite.el` — no external binary needed on day one.
- Can extract the fetcher to any language later without touching the data
  model. Language choice becomes independent of architecture.

**2. Git-as-sync-bus (Logseq/dendron pattern).**
- Daemon writes Monday state as JSON-per-item to a repo, org files live
  alongside, git handles history and conflicts.
- Free merge UI, works offline.
- Downside: ugly JSON diffs, webhook latency (~minutes).

**3. Three-layer mu4e pattern.**
- Monday API → local canonical JSON cache → SQLite index → org views.
- Cleanly separates fetch / reconcile / present.
- Worth stealing conceptually even without full adoption.

### Dead ends

- Pandoc / markdown intermediate — lossy on properties, drawers, links.
- Monday → Notion → org — two lossy hops, one-way in places.
- CRDT/Automerge — Monday API isn't operation-shaped; overhead without payoff.
- Logseq/Obsidian as intermediate — third source of truth.
- Zapier / Make / n8n — no org connector, brittle.
- syncthing / unison / rclone — sync bytes, not semantic models.

## Prior art (verified April 2026)

- **No `org-monday` package exists.** MELPA, GitHub, Emacs wiki all empty.
  Only `github.com/zachpodbielniak/monday-emacs` (April 2026, 1 commit) — a
  TUI client, not a sync engine. Greenfield.
- **org-trello** — dormant since 2021. Don't use as a reference for recency,
  but `orgtrello-controller.el` still worth reading for bidirectional Elisp
  sync patterns.
- **org-jira** — maintenance mode, active (last commit Feb 2026). Good model
  for "pull-heavy, sync-down-then-sync-up" flow that sidesteps true
  bidirectional merges.
- **org-caldav** — active (Feb 2026). Uses an MD5 state file as last-known-sync
  baseline. This is exactly the three-way-merge pattern our current
  implementation is missing.
- **magit/forge** — very active (April 2026, v0.6.4). Most successful
  Emacs ↔ REST SaaS sync in the wild. Deep dive below.

## magit-forge architecture — the core teaching

### Data model
- **`closql`** maps EIEIO classes → SQLite tables. One class per table, one
  row per object. DB class `forge-database`, schema version 15.
- Core tables: `repository`, `issue`, `pullreq`, `discussion`, `*-post`
  (comments), plus join tables (`issue-label`, `issue-assignee`, etc.) with
  cascading FK deletes.
- IDs are opaque base64 derived from GitHub's global node IDs — **stable
  across re-pulls**. This is the whole trick that makes incremental sync work.

### Pull path
- User-invoked only (`forge-pull`). **No webhooks.**
- **One giant GraphQL query** per repo covering issues + PRs + discussions +
  comments + labels + milestones, ordered `UPDATED_AT DESC`.
- Incrementality via per-collection `*-until` watermarks on the repo row
  (`issues-until`, `pullreqs-until`, `discussions-until`). Walker pages
  backward, stops at watermark, bumps watermark in a single transaction.
- Partial fetches never half-write (transaction-per-pull).

### Write-back path
- **Pessimistic: mutate remote first, then refetch.** `C-c C-c` on a comment
  runs the GraphQL mutation, then `forge--pull-topic` refetches authoritative
  state and redraws.
- DB is **never updated from user-typed text** — it's pure cache of server
  state.
- Edit buffer is an ephemeral draft persisted to `.git/magit/posts/` for crash
  recovery.

### Conflict handling
- **Essentially none.** Because the DB only mirrors server responses, local
  drift is structurally impossible.
- No ETag, no precondition check. Last-writer-wins at GitHub's end.
- Works for forge because comments are small and short-lived.

### Presentation
- Materialized on demand via `closql-reload`.
- Manual `forge-refresh-buffer` call at ~25 sites after mutations. No
  reactivity, no observer pattern. Simple and debuggable.

### Schema migrations
- Linear migration ladder in `forge-db.el`. Backs up sqlite file before each
  upgrade. Each step: raw `emacsql` DDL + data fixups + version bump.

### Rate limits
- GraphQL alias batching (50 notifications per request).
- On 404, errorback shrinks query and retries.

## What transfers to Monday

**Steal directly:**
- closql + single sqlite file as the spine.
- Server-derived IDs as primary keys (Monday item IDs are globally unique).
- Per-collection `updated_at` watermarks for incremental pulls.
- Pessimistic write-back: mutate → refetch → redraw.
- Transaction-per-pull, backup-before-migrate.
- Manual buffer refresh.

**Must adapt:**
- **Docs are trees, not comment lists.** Model
  `doc_block(doc, position, type, content, parent_block)` with stable block
  IDs. Don't flatten to markdown the way forge flattens comments.
- **Column values are heterogeneous** (30+ types). One row per
  `(item_id, column_id)` with type discriminator and JSON `value`; dispatch
  renderers on type. No forge analog.
- **Conflict stakes higher.** Org buffers aren't ephemeral drafts — they're
  long-lived working files. Forge's "just refetch after mutation" won't fly.
  Minimum: check remote `updated_at` against stored baseline before pushing;
  refuse or three-way-merge if it moved.
- **Deletes are real.** Monday items/blocks can be hard-deleted. Periodic
  full-list reconcile, or subscribe to `delete_pulse`/`delete_update`
  webhooks. Forge's "ignore and rely on state fields" doesn't translate.
- **Add webhooks for boards.** Monday has item/column webhook events (just
  not doc-block ones). Hybrid: webhooks for board freshness, poll-diff for
  docs.
- **Complexity budget, not request count.** Size batches by predicted
  GraphQL complexity, not count. Instrument the response header.

**Doesn't translate:**
- Forge's draft-file-in-gitdir resume flow (org buffers *are* the draft).
- Notification-rebuild-per-pull (too much data for Monday activity feeds).
- Git-worktree assumption (our "repo" is a board or a doc).

## Hard-won lessons from cousin packages

- **Store the remote's state hash, not just its ID.** Without a baseline,
  you can't tell who changed what. Current impl's biggest gap.
- **Never auto-resolve conflicts.** org-trello tried, users hated it.
  Surface conflicts as org TODOs or a dedicated buffer.
- **Rate limits bite late.** Monday's complexity budget is generous until
  you fetch 50-block docs in a loop. Batch with GraphQL aliases.
- **Attachments are where every sync tool dies.** Keep PlantUML/Excalidraw
  file-addressed, never inline-base64 into the DB.
- **Bidirectional from day one is a trap.** org-jira shipped pull-only for
  two years before adding push. Ship pull-only next, *then* merge.

## Recommended next step when we pick this up

1. Add an SQLite state store to the current Elisp implementation
   (`monday-sync.db`), backed by Emacs's built-in `sqlite.el`. This is the
   minimum-viable change that fixes the baseline gap.
2. Sketch a schema in forge-db.el style:
   - `board`, `item`, `column_value`, `update` (comments), `doc`, `doc_block`
   - Cascade FKs, server-derived IDs as PKs, `updated_at` watermark per
     parent row.
3. Add a pull-only sync path first (Monday → DB → org). Do NOT add push-back
   until pull is solid.
4. Only then revisit whether to extract the fetcher to TS. If the Elisp
   SQLite-backed pull works well, the extraction may not be worth the
   complexity.

## Open questions

- Do we want webhook-driven freshness on boards, or is polling enough?
- Attachments strategy — file paths in DB only, never content?
- Do we care about Monday docs *comments* (no public API) vs item updates
  (full API)?
- Is there value in a richer query layer (e.g., treating the DB as a
  queryable view of Monday state, independent of org sync)?

## References

- Local: `lisp/monday-docs-sync.el`
- Local: `~/Development/monday-mirror/packages/cli` — Monday GraphQL usage
  in production, uses raw GraphQL rather than the SDK
- Forge source (if installed):
  `~/.emacs.d/elpa/*/forge-*/forge-{db,core,client,github,post,topic}.el`
- Forge manual: https://magit.vc/manual/forge/
- Monday official TS SDK: https://github.com/mondaycom/monday-graphql-api
- Monday API docs: https://developer.monday.com/api-reference/
- org-caldav (baseline-file pattern): https://github.com/dengste/org-caldav
- org-jira (pull-heavy pattern): https://github.com/ahungry/org-jira
