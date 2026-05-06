# monday-twin as Org-Context MCP for Agents

**Status:** Idea / high-priority / candidate for next /design
**Date:** 2026-04-23
**Related code:** ~/Development/monday-twin (full digital-twin service for Monday;
SQLite replica + CDC + approval-gated writes + actor attribution)
**Related ideas:** `plan-monday-commit-graph.md` (supersedes / subsumes large parts)

## Context

Prior research across Mem0, Letta, LangMem, Deep Agents, Graphiti, Cline,
Cursor, Anthropic's `memory_20250818` beta tool, Claude Code's auto-memory,
and every enterprise coding agent (Augment, Cody, Copilot, Tabnine, Windsurf,
Q Developer) converged on one conclusion: **Anthropic already ships the winning
memory pattern** (flat markdown + hierarchical loading + auto-memory at
`~/.claude/projects/<project>/memory/`). Reinventing a better semantic
memory is a losing game — every startup in that space is either hype-cycling
on adoption (OpenViking, Memori, Supermemory) or requires Neo4j-level ops
(Graphiti at Cursor scale).

**The open slot** the research surfaced: Anthropic owns the *memory* problem;
nobody owns the *context* problem. "What sprint is active?" "What am I
assigned to?" "Which Monday card does this git branch serve?" "What changed
on my boards since yesterday?" — no agent harness answers these today
because the data isn't available to them.

monday-twin already has this data, locally, queryable, and fresh.

## The idea

Wrap monday-twin in an **MCP server that exposes Monday org context as
agent-callable tools**. Every Claude session becomes org-aware at
near-zero cost: tools query a local SQLite replica instead of the rate-
limited Monday API; a hook injects current state (assigned cards, active
sprint, recent activity) into the session prompt automatically.

This turns monday-twin from *a sync service* into the **context backbone
for every agent the user runs**.

## Why this matters

- **Unique moat.** Can't be replicated by Mem0, Graphiti, Cursor, Anthropic,
  or anyone else — they don't have the user's Monday token or local twin.
- **Existing infrastructure reused, not rebuilt.** Approval gates, retry
  ladder, actor attribution, CDC stream — all shipped. We wrap, not build.
- **Closes the plan → Monday → commit loop** outlined in
  `plan-monday-commit-graph.md`. That idea had Monday as a backend; this
  idea makes Monday a *first-class agent surface*.
- **Compounds with existing harness.** claude-collab handles *how* to edit;
  monday-twin context tells agents *what the edits are for*, who cares,
  which card they serve.
- **Stays in a lane Anthropic won't enter.** Memory = Anthropic's. Org-
  specific context = yours. No conflict, no obsolescence risk.

## Design sketch

### Tools exposed (starter set)

| Tool | Answers |
|---|---|
| `monday_twin_assigned_to_me` | What am I working on this week / this sprint? |
| `monday_twin_current_sprint` | Active sprint: members, items, status rollup, blockers |
| `monday_twin_card_context(id)` | Full card — body, comments, activity, linked cards, owner, status, due date |
| `monday_twin_search(query)` | SQL-backed fuzzy search across items + columns |
| `monday_twin_card_for_branch(branch)` | Given `MON-2401-foo`, resolve to card + context |
| `monday_twin_recent_activity(hours)` | What changed on my boards since H hours ago? |
| `monday_twin_propose_update(id, …)` | Propose a write; routes through approval gate |
| `monday_twin_subscribe(topic)` | Stream CDC events for a board / sprint into the agent |

### Injection path

SessionStart hook (inspired by OpenViking's architecture, *validated* by
Claude Code's own hook system) calls a `monday_twin_session_context` tool
and injects ~300 tokens into the system prompt:
- Current sprint summary
- My top 3 in-progress cards (title + status + last update)
- Recent activity delta (last 24h)
- Any cards mentioning current repo / branch

Optionally also `UserPromptSubmit` for query-aware pulls if SessionStart's
static bundle proves insufficient.

### Architecture

```
Monday.com API
       │
       ▼
  monday-twin service  (existing — Bun / TypeScript / SQLite)
       │
  ┌────┴────┐
  │         │
  ▼         ▼
MCP server   CDC WebSocket
  │          (existing)
  ▼
Claude Code sessions
  │
  ▼
User (edits / reviews / approves)
```

The MCP server is a new `src/mcp/` module inside monday-twin. Same process,
shared DB connection — cheap to add, hot-reloadable.

## Open questions / tensions

- **Language**: MCP server TypeScript inside monday-twin (shares schema,
  simpler deploy) vs. a thin Python/Node wrapper outside (decouples
  lifecycles). Leaning toward in-repo TS.
- **Hook timing**: SessionStart only (cheap, static snapshot), UserPromptSubmit
  also (query-aware, richer), or both? OpenViking does both with 8s timeout
  on UPS.
- **Actor scoping**: every Claude-proposed write attributed as
  `claude-code:<session-id>`? `claude-code:<user>`? Single `claude-code`
  global? Monday-twin already handles actors — need to pick a convention.
- **Context budget**: how many tokens for SessionStart injection? The
  sweet spot between "valuable signal" and "every session starts with a
  wall of PM data" — probably 250–500 tokens, gated on relevance.
- **Privacy scope**: Monday contains sensitive data (customer names,
  deal values, PII in comments). Is injection always-on, or does the user
  opt-in per-repo? Default should be conservative.
- **Cross-project semantics**: SessionStart in a random repo — do we
  inject Monday context unconditionally, or only when a mapping exists
  (repo → board / card)? The latter is much cleaner.
- **Relationship to MCP tool count bloat**: Claude already has 100+ MCP
  tools available. Adding 8 more increases the "tool picker" cost. Which
  are essential for v1 vs. nice-to-have for later?
- **Write path UX**: when Claude proposes a Monday update, where does the
  user see the approval prompt? Monday-twin web UI? Emacs buffer?
  Notification? The claude-collab annotation flow pattern may adapt.

## Minimal v1

1. Add `src/mcp/` to monday-twin with an MCP server skeleton (stdio
   transport, one command-entry in `.mcp.json`).
2. Ship **three** tools, not eight: `assigned_to_me`, `current_sprint`,
   `card_for_branch`. These three answer 80% of "what should I be working
   on?" scenarios.
3. SessionStart hook that runs in <300ms and prints a bundle to stdout
   captured by Claude Code's hook convention.
4. No writes yet. Read-only validates the signal-to-noise; writes add
   operational complexity (approval UX, actor naming).
5. No CDC subscription in v1 — snapshot-per-session is enough to prove
   value.

**Rough effort**: 2-3 days. The hardest part is getting the SessionStart
bundle prompt shape right — iteration over a week of real use.

## Dependencies

- monday-twin is stable and running locally (✅).
- Claude Code's hook system supports SessionStart + env-var
  context (✅, official feature).
- MCP protocol stable (✅).
- Monday board → repo mapping convention (**needed** — see Open
  questions; probably a simple `.monday-twin.json` per repo mapping
  board + optional card filter).

## Relationship to other ideas

- **`plan-monday-commit-graph.md`** — This idea supersedes / subsumes
  most of it. The plan-Monday-commit graph becomes the *use case*;
  monday-twin MCP becomes the *mechanism*. The `/design @CARD-123`
  seeding flow, card-status writes on plan DONE, retrospective comments —
  all become concrete tool calls against the monday-twin MCP.
- **`ambient-observability.md`** — Parallel pattern. Observability MCP
  injects *service state* into sessions; monday-twin MCP injects *org
  state*. Same architecture (read-only snapshot at session start), same
  hook points. Could share a SessionStart coordinator that pulls from
  multiple context sources.
- **`executable-plans.md`** — Plans that know their Monday card can
  auto-update card status on Step DONE. monday-twin MCP is the write
  channel.
- **`session-memory-distillation.md`** — Sibling, not replacement.
  Memory (past) + context (present) are complementary. Memory stays
  Anthropic-native; context lives in monday-twin MCP.
