# Session Memory Distillation — compounding the harness's knowledge

**Status:** Idea / parked
**Date:** 2026-04-23
**Related:** Claude Code's built-in memory system (`~/.claude/projects/.../memory/`),
Agent SDK `Stop` / `SessionEnd` hooks, existing CLAUDE.md files

## Context

The harness has a persistent memory system (structured markdown files
under `~/.claude/projects/<project>/memory/` indexed by `MEMORY.md`).
Today it's populated **manually**: I only write memories when the user
asks, or when I notice something obviously save-worthy. Most sessions
end with no memory writes.

Result: the harness doesn't compound its knowledge. Every new session
starts roughly as naïve as the last — the same preferences are
re-discovered, the same surprises re-surface, the same project context
is re-established through conversation.

This is the largest latent win in the harness. Memory is the difference
between a smart colleague on their first day and one who's been here
six months.

## The idea

On every session end, a **distillation subagent** reads the session
transcript and extracts structured memory candidates. The user sees a
short list of proposed entries and confirms / edits / rejects each.
High-quality memories accumulate; low-quality ones get filtered at the
confirmation step.

Concretely:

1. **Trigger**: `SessionEnd` hook (Agent SDK) or a shell hook bound to
   Claude Code's `onStop` event. Also manually invocable via
   `/memory distill`.

2. **Extraction**: a small subagent reads the last session's transcript
   with a focused prompt: *"Identify memory-worthy moments. Categorise
   as user / feedback / project / reference per the existing type
   taxonomy. Output structured JSON."*

3. **Filtering**: the subagent applies a quality gate:
   - Skip if the fact is already in an existing memory (grep MEMORY.md).
   - Skip if the fact is trivially derivable from code / git / CLAUDE.md.
   - Skip if the fact is session-ephemeral (current task state).
   - Include if the fact is surprising, preference-revealing, or
     forward-relevant.

4. **Confirmation UI**: in Emacs, pop a `*memory candidates*` buffer
   with each proposal as a bullet — user presses `y` to save, `n` to
   skip, `e` to edit inline. Non-blocking; user can ignore the buffer
   and memories are just not saved.

5. **Weekly consolidation**: a lower-frequency pass that reads the
   accumulated memory files and looks for redundancy, contradictions,
   or memories that should be merged. Keeps the index from bloating.

## Why this matters

- **Flywheel effect**: each saved memory reduces the context rediscovery
  tax of the next session. Compounds over weeks/months.
- **Beats CLAUDE.md**: CLAUDE.md is static, written by the user, and
  usually out of date. Distilled memories are current, behavioural,
  and capture things CLAUDE.md can't (the *why* behind a correction).
- **No manual tax**: today's memory writes depend on my initiative and
  the user's patience. Automating the candidate-generation step removes
  the "should I save this?" decision from hot path.
- **Structured confidence**: the confirmation step keeps the user in
  the loop without forcing them to author anything.

## Design sketch

### Distillation prompt structure

```
You are a memory distiller. Read the session transcript below and
identify memory-worthy moments per the taxonomy:

- user: role, preferences, expertise, goals
- feedback: "don't do X" corrections OR "yes, exactly" confirmations
  (include the WHY the user gave, if stated)
- project: ongoing work, deadlines, decisions, stakeholders (absolute
  dates, not relative)
- reference: pointers to external systems (Linear, Grafana, etc.)

Skip:
- Code patterns derivable from reading the code
- Git history derivable from git log
- Session-ephemeral task state
- Anything already in <existing MEMORY.md>

Output JSON: [{type, name, description, body, reason_worth_saving}, ...]
```

### Confirmation buffer shape

```
Memory candidates — 2026-04-23 session · 4 proposed

  [ ] feedback · user prefers terse responses without trailing summaries
      Reason: said "stop summarizing what you just did at the end"
      [y save] [n skip] [e edit]

  [ ] project · monday-docs-sync is parked pending baseline-state design
      Reason: user said "the TS rewrite was wrong — this is an
      architecture problem, not a language problem"
      [y save] [n skip] [e edit]

  [ ] reference · observability MCP tools under dd_, grafana_, obsguard_
      prefixes (8+ tools connected)
      Reason: relevant for future observability queries
      [y save] [n skip] [e edit]

  [ ] user · works in Emacs + Spacemacs + evil; designs-before-coding
      via /design skill
      Reason: working style, informs how to frame plans and edits
      [y save] [n skip] [e edit]

RET on a row: expand detail. TAB: toggle all. C-c C-c: save selected.
```

### Integration with existing memory flow

The distillation writes using the same file structure as manual
memories (one file per memory, frontmatter + body). It updates MEMORY.md
with new pointers. Manual saves keep working unchanged — this is
additive.

## Open questions / tensions

- **Accuracy of the distiller**: extracting preferences from transcripts
  is fuzzy. The confirmation step is the safety net. Start with high
  recall (propose many) and let the user filter; if the user routinely
  rejects most, tighten the filter.
- **Session boundaries**: "session" is slippery — is it one `claude
  code` invocation, a day's worth of chats, a feature's worth? Start
  with per-invocation (natural hook point), allow `/memory distill`
  for larger windows.
- **Transcript storage**: Claude Code keeps transcripts at
  `~/.claude/projects/<encoded-cwd>/<session>.jsonl`. Distiller reads
  these directly — no extra infra.
- **Token cost**: running a subagent per session isn't free. Maybe ~5¢
  per session. Tolerable. Can gate on "session was substantive" — skip
  for short sessions.
- **Memory decay**: as the memory pool grows, older memories become
  noise. Weekly consolidation pass plus a "last-used" timestamp (incr
  when referenced during distillation) gives us a natural decay signal.
- **Feedback loop for the distiller**: if the user rejects a candidate,
  that's training data. Eventually the distiller learns what this user
  finds worth saving. Requires per-user tuning of the prompt or a local
  filter layer.

## Minimal v1

1. Shell hook on Claude Code session end (via `hooks` setting) invokes
   a Python/Node script that reads the session transcript and writes
   candidates to `~/.claude/projects/.../memory/_candidates.md`.
2. On next session start, if `_candidates.md` exists, I (the main
   assistant) mention "4 memory candidates pending review — run
   `/memory review` to see."
3. `/memory review` opens the file in Emacs with simple y/n/e bindings.
4. Approved entries become proper memory files; `_candidates.md` is
   cleared.

Total: ~4 hours of scripting + a small Emacs command.

## Dependencies

- Session transcripts exist and are readable (✅ Claude Code writes
  them).
- Hook infrastructure: Claude Code settings.json supports shell hooks
  on stop/end (✅).
- Existing memory system file layout (✅ established).
- Agent SDK would enable richer in-process distillation and immediate
  UI, but shell-hook + script is enough for v1.

## Relationship to other ideas

- **Executable plans** (`executable-plans.md`) has its own distillation
  step (end-of-plan retrospective) — that's scoped to one feature. This
  idea is cross-cutting: every session, regardless of whether it was
  about a plan.
- **Work graph** (`plan-monday-commit-graph.md`) produces structured
  activity data (commits → card transitions). Memory distillation
  operates on the unstructured transcript — complementary, not
  overlapping.
- **Ambient observability** (`ambient-observability.md`) *consumes*
  memory ("this service is known-flaky, don't trust its metrics") —
  good memories make ambient injection smarter.
