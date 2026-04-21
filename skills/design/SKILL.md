---
name: design
description: Use this skill whenever the user wants to plan, design, outline, or architect anything non-trivial — this is the user's default planning flow. Triggers on /design, on phrases like "design X", "plan X", "sketch a plan for X", "write a design doc for X", and any request to think through an implementation before coding. Three subcommands — /design <topic> (author), /design revise (apply claude-collab annotations and resolve clarifications), /design status (list plans). Produces a structured org-mode file with a PlantUML architecture diagram, supports an annotation-driven revision loop via claude-collab in Emacs. This is the preferred planning flow — the user works in Emacs and has chosen it over generic markdown-spec workflows.
---

# /design — Org-mode plan authoring

Three subcommands dispatched on the first argument:

- `/design <topic>` — author a new plan (default mode)
- `/design revise [file]` — apply claude-collab annotations to an existing plan
- `/design status` — list plans under the current scope with annotation counts

Plan artifacts live in `./plans/` when the current working directory is inside a git repo, else `~/plans/`.

## Dispatch

Read the first whitespace-delimited word of the argument string.

- If it is exactly `revise`, dispatch to **Revise mode**. Any remaining args are an optional file path. If the remaining args don't resolve to an existing file path, treat them as absent and rely on the buffer/mtime fallbacks in Revise mode.
- If it is exactly `status`, dispatch to **Status mode**. No further args.
- Otherwise, treat the entire argument string as the plan topic and dispatch to **Author mode**.
- If the argument is empty or whitespace, prompt the user once: "What are you designing?" Wait for their reply, then use that as the topic in Author mode.

## Author mode

### Resolve target directory

```bash
git rev-parse --show-toplevel 2>/dev/null
```

- If the command succeeds (exit 0), target directory is `<stdout>/plans/`.
- Otherwise, target directory is `$HOME/plans/`.
- Create the directory if missing: `mkdir -p <target>`.

### Build filename

- Compute the date: today's date in `YYYY-MM-DD` format.
- Slugify the topic:
  - Lowercase.
  - Replace any run of non-`[a-z0-9]+` characters with a single `-`.
  - Strip leading and trailing `-`.
  - Truncate to ≤60 characters on a word boundary if possible.
- If the slug is empty after sanitization (e.g., topic was non-Latin-only), use `untitled` and mention this in the chat report.
- Filename: `<date>-<slug>.org`.
- Full path: `<target-directory>/<filename>`.

### Collision handling

If the file already exists at that path, do NOT overwrite. Instead:

1. Skip both the "Write the template" and "Open in Emacs" blocks below.
2. Instead, call `mcp__emacs__eval-elisp` with `(find-file "<absolute-path>")` directly.
3. In your chat report, say: "Continuing existing plan at `<relative-path>`. Opened in Emacs." ("Relative path" means relative to the repo root if inside a git repo, otherwise relative to `$HOME`.)

This treats same-day same-topic invocations as "resume" rather than clobber.

### Write the template

Fill in the skeleton below. Section headings are required; content is your judgment. Keep Goal and Approach ≤150 words each, Steps descriptions ≤2 paragraphs, and Risks bullets ≤1 sentence each — the revise loop is where content matures, so dense first drafts waste the user's edit budget.

```org
#+TITLE: <topic>
#+DATE: <YYYY-MM-DD>
#+STARTUP: showall inlineimages
#+TODO: TODO CLARIFY(c) | DONE RESOLVED(r)

* Goal
  <1–2 paragraphs: what this builds and why now.>

* Approach
  <2–3 paragraphs: the "why this way," key constraints, relationship
  to existing components.>

* Architecture
  #+begin_src plantuml :file <slug>-arch.png
  @startuml
  <components and flow using actor / component / database primitives.
  Focus on the main interaction path, not every edge case.>
  @enduml
  #+end_src

* Steps
  1. [ ] <First concrete step>
     :PROPERTIES:
     :files:  <comma-separated files this step touches>
     :tests:  <comma-separated test files or names — empty if no test applies>
     :verify: <observable that confirms the step worked — e.g. "pytest path::name passes", "curl :8080/health returns 200", "diff output is empty">
     :END:
     <One short paragraph: what the step does and why.>

  2. [ ] <Second step>
     ...

* Risks
  - <Risk — why it matters, mitigation>

* Open questions
  - [ ] <Question that needs a human call>
```

Required rules when filling the template:

- The PlantUML block MUST have a `:file <slug>-arch.png` header argument. Without it, `claude-collab-auto-render-diagrams-mode` skips the block and the diagram won't appear inline.
- The `#+STARTUP: showall inlineimages` line is mandatory — it ensures rendered PNGs display the next time the file is opened.
- The `#+TODO: TODO CLARIFY(c) | DONE RESOLVED(r)` line is mandatory — it colorizes the `CLARIFY` keyword used for Step-level clarifications (see "Clarifications" below). Without it, `CLARIFY` is rendered as plain text and the visual signal is lost.
- Each Step heading MUST have `:files:`, `:tests:`, and `:verify:` org properties. `:files:` names files the step touches; `:tests:` names the test(s) that cover the step (empty string if no test applies — e.g., a pure docs change); `:verify:` is the concrete observable that proves the step worked. These aren't for mandating red/green TDD — they're so execution has a concrete pass/fail signal per step. A step with no verifiable outcome can't be trusted as done.
- If a section genuinely has no content (e.g., no open questions yet), write `- <none for now>` rather than deleting the section — keep the skeleton stable.

If the Write tool fails (directory not writable, disk full, etc.), report the failure path and error to the user and stop — do not proceed to Open in Emacs.

### Clarifications (CLARIFY convention)

When drafting, you will hit assumptions that aren't stated in the user's input. Do not silently guess — silent guesses hide decisions nobody made and ship as invisible bugs. Instead, surface each assumption as a visible clarification marker and keep drafting around it.

Two granularities:

**Inline (prose-level)** — for single-assumption questions that sit inside a paragraph or Step description:

```org
We retry on =[CLARIFY: what counts as a transient failure?]= responses.
```

Use verbatim markup (`=…=`) — every org theme colorizes it distinctly, so the marker stays visible during normal scanning without hiding the surrounding prose.

**Heading (Step-level)** — for Steps you can't responsibly design without more input:

```org
** CLARIFY Step 5: Caching layer
   :PROPERTIES:
   :files:  <TBD — depends on backend choice>
   :tests:  <TBD — depends on backend choice>
   :verify: Decision captured in Approach; matching Open questions bullet ticked.
   :END:
   Blocked on: which cache backend (Redis, Memcached, in-process)?
```

The `CLARIFY` TODO keyword renders in org's TODO-face color. Use this when the ambiguity affects the whole Step's shape, not just a single sentence. CLARIFY-heading Steps still require the three properties — use stub values that name what's blocked (e.g. `<TBD — depends on backend choice>`) until the decision lands. This keeps the "every Step has properties" invariant programmatically checkable and makes the blocker obvious at a glance.

**Mirror to Open questions** — every CLARIFY marker you add MUST have a matching unchecked bullet in `* Open questions`, with an org internal link back to the location:

```org
* Open questions
  - [ ] [[*Step 5 Caching layer][Step 5]]: which cache backend?
  - [ ] [[*Step 3 Rate limiting handler][Step 3]]: what counts as transient?
  - [ ] Initial numeric tier values (free / standard / enterprise)?
```

The relationship is **markers ⊆ Open questions**: every inline or heading CLARIFY marker mirrors to a bullet, but Open questions may contain additional bullets that have no inline counterpart. Use free-standing bullets (no internal link) when the question is broad enough that no single prose location would naturally hold it — e.g., cross-cutting numeric values, policy decisions that span multiple Steps, or questions that are genuinely "outside the draft". When a free-standing bullet could reasonably be pinned to one location, prefer an inline/heading CLARIFY with a mirror — in-context visibility is more useful than a bare list.

Open questions is the authoritative checklist — when all its bullets are checked, the plan is clarification-free. Inline markers and CLARIFY keywords are for in-context visibility; Open questions is for completeness auditing.

**When NOT to CLARIFY:**
- The answer is obvious from surrounding context (e.g., "returns JSON" in a plan where every other endpoint returns JSON).
- The answer is low-stakes and reversible (file naming, variable naming — pick one, move on; the user can rename).
- The question has no meaningful disagreement axis — a CLARIFY is worth the user's attention, and noise dilutes the signal of real ones.

### Self-review

Before opening in Emacs, do a two-way coverage scan on the draft. The aim is to catch both under-building (something in Goal isn't addressed by any Step) and over-building (a Step doesn't trace back to Goal). One-way scans miss scope creep.

**Scan 1 — Goal → Steps:** For each requirement or outcome stated in Goal or Approach, identify which Step implements it. If a requirement has no Step, either add the Step or file a `- [ ] [[target][label]]: <question>` bullet in Open questions with a matching CLARIFY inline/heading marker. Don't leave requirements dangling.

**Scan 2 — Steps → Goal:** For each Step, name which Goal/Approach bullet it serves. If a Step doesn't map to anything in Goal/Approach, either hoist its motivation into Approach (if the scope genuinely grew) or delete the Step (it's scope creep).

Fix any gaps inline. No separate review report — correct the draft before opening it.

### Open in Emacs

Call the `mcp__emacs__eval-elisp` MCP tool with:

```elisp
(find-file "<absolute-path-to-the-org-file>")
```

If the MCP server is unavailable or the call errors, continue — the file on disk is still the primary artifact. Note the failure in your chat report.

### Report back

One short chat message:

> "Wrote `<relative-path>`. Opened in Emacs. Annotate with `SPC o c c` on a selected region, then `/design revise` to apply annotations. `SPC o c l` lists pending annotations in the buffer."

## Revise mode

Revise mode handles two input channels, both feeding into the same edit machinery:

1. **Annotation-driven (Emacs)** — user highlights text, adds a claude-collab annotation via `SPC o c c`, runs `/design revise` to apply. Primary flow.
2. **Conversational (chat)** — user answers a CLARIFY question in chat without opening Emacs ("For Step 3, transient = 5xx or 429 without Retry-After"). Treat as a CLARIFY resolution and apply via the same buffer-edit tools so the live Emacs buffer updates even though the trigger was a chat message.

Annotation-driven and conversational flows share the three-step resolve (see "Resolving CLARIFY markers" below) — only the input channel differs.

### Determine target file

In priority order:

1. If the user passed an explicit path as the second argument, use it. Expand `~` if present.
2. Else, call `mcp__emacs__eval-elisp` with:
   ```elisp
   (with-current-buffer (window-buffer (selected-window))
     buffer-file-name)
   ```
   If the returned path is an `.org` file whose directory path contains `/plans/` as a component, use it.

   If the result is `nil`, empty, or the string "nil", fall through to step 3 (most-recent-plan fallback). Also note that `mcp__emacs__eval-elisp` returns printed sexp output — a filename comes back wrapped in quotes (e.g. `"/path/to/file.org"`). Strip the surrounding quotes before using the path.

   Caveat: in a daemonized Emacs with no attached frame, `(selected-window)` may pick an arbitrary buffer. If step 2 returns a path that clearly isn't a plan file (not under a `plans/` directory, or not .org), treat it as unusable and fall through to step 3.
3. Else, fall back to the most recently modified `.org` file in the current scope's plans directory (same logic as Author mode: repo-local if in a git repo, else `~/plans/`):
   ```bash
   ls -t <target-dir>/*.org 2>/dev/null | head -1
   ```
4. If none of the above yields a path, abort with: "No plan found to revise. Run `/design <topic>` to create one, or pass an explicit path."

### List pending annotations

Call the `claude-collab-list-annotations` MCP tool with the resolved file path. The tool returns a printed sexp (a list of plists — Claude reads it by eye). Each annotation plist has:

- `:id` — opaque identifier used to resolve it later
- `:file` — absolute path of the annotated file
- `:begin` / `:end` — buffer positions (integers) of the highlighted region
- `:text` — the highlighted region's text
- `:label` — the user's note (the edit instruction)

Neither a line number nor an enclosing heading is provided. Derive them yourself from `:begin`:
- Line number: read the file, count newlines up to `:begin`, or use Grep to locate `:text`.
- Enclosing section: find the nearest `*` / `**` org heading above `:begin`.

If there are no pending annotations, stop with: "No pending annotations in `<path>`."

### Apply each annotation

For each annotation, in file order:

1. Read the `:label` as the user's edit intent. Common patterns:
   - "skip" / "drop" → delete the annotated step or section.
   - "combine with next" / "merge 5 and 6" → merge items.
   - "expand" / "more detail" → rewrite with more specificity.
   - "reword: X" → replace the text with X.
   - Free-form prose → interpret as an instruction and apply the smallest edit that satisfies it. Prefer replacing only the annotated region; widen scope (via `claude-collab-get-region-bounds`) only when the instruction plainly reaches beyond the highlight.
2. Edit the **live Emacs buffer**, NOT the file on disk. Two reasons: (a) the user may have unsaved changes in the buffer, and a disk edit would either clobber them or lose the update when Emacs flags divergence; (b) annotation `:begin`/`:end` from `claude-collab-list-annotations` are buffer positions at save time — they drift as the buffer mutates, so always resolve the live overlay before editing.

   Three MCP tools cover the edit patterns:

   - `claude-collab-apply-annotation` — edits scoped to the annotation itself. Use when the user's intent lives within the highlighted region (reword, delete, insert adjacent).
   - `claude-collab-get-region-bounds` + `claude-collab-apply-edit` — edits scoped to a structural unit that contains the annotation (section, list-item, paragraph, line). Use when the intent reaches beyond the highlight.

   Concrete flows:

   - **Reword** ("reword: X"): one call to `claude-collab-apply-annotation` with `:id <id> :action replace :new-text "X"`. Auto-resolves on success — no separate resolve call.
   - **Skip / drop a step**: `claude-collab-get-region-bounds` with `:id <id> :unit list-item` to get `(:begin B :end E)`, then `claude-collab-apply-edit` with `:file <path> :begin B :end E :new-text ""`. Then call `claude-collab-resolve-annotation` with `:id` — the get-region-bounds + apply-edit path does not auto-resolve.
   - **Expand a section**: `claude-collab-get-region-bounds` with `:unit section`, then `claude-collab-apply-edit` with the rewritten section text as `:new-text`. Call `claude-collab-resolve-annotation` afterwards.
   - **Insert a new step after this one**: `claude-collab-get-region-bounds` with `:unit list-item` to get `(:begin B :end E)`, then `claude-collab-apply-edit` with `:begin E :end E :new-text "<new step text>"`. Call `claude-collab-resolve-annotation` afterwards.
   - **Merge with next** ("combine with next"): two `claude-collab-get-region-bounds` passes if the next item is annotated too; otherwise use `:unit list-item` on the current annotation to get its end, splice in the next item's text, and delete the next item's range. Then resolve both annotations.

   `claude-collab-apply-annotation` auto-resolves the annotation on success, so no separate `claude-collab-resolve-annotation` call is needed. When using the `get-region-bounds` + `apply-edit` path, always follow up with an explicit `claude-collab-resolve-annotation` call — otherwise the annotation keeps showing as pending.

3. After the edit lands, the annotation should be resolved (auto via `apply-annotation`, or explicitly via `claude-collab-resolve-annotation`).

### Resolving CLARIFY markers

A CLARIFY marker (inline `=[CLARIFY: …]=` or heading `CLARIFY` keyword) is resolved when the user supplies the answer. Resolution is distinct from a generic edit instruction — it replaces the question with an answer rather than modifying surrounding text.

**Detect a CLARIFY resolution:**

- **Annotation channel**: the annotation overlaps a `=[CLARIFY: …]=` span or sits on a heading whose TODO keyword is `CLARIFY`. The annotation `:label:` is the user's answer.
- **Chat channel**: the user's message identifies a clarification and provides an answer. Examples: *"resolve the rate-limit question with 5xx or 429 without Retry-After"*, *"for Step 3, transient means ..."*, or a declarative answer that clearly maps to exactly one open CLARIFY.

**The three-step resolve** (applies to either channel):

1. **Replace the marker:**
   - Inline `=[CLARIFY: question]=` → rewrite as resolved prose drawn from the answer. Annotation channel: `claude-collab-apply-annotation` with `:action replace :new-text "<resolved prose>"` (auto-resolves). Chat channel: `claude-collab-get-region-bounds` + `claude-collab-apply-edit`.
   - Heading with `CLARIFY` keyword → rewrite the Step body to incorporate the answer, then cycle the heading keyword off (remove `CLARIFY`, leave the heading plain) via `claude-collab-apply-edit` on the heading line.

2. **Tick the matching Open questions bullet:** locate the `- [ ]` bullet whose internal link target matches the resolved marker (by heading target for Step-level, or by question text for inline). Change `- [ ]` to `- [X]`.

3. **Resolve the annotation** (annotation channel only, and only when the first step didn't auto-resolve): call `claude-collab-resolve-annotation` with the `:id`.

### Edge cases

- **Partial resolution** — user supplied answers for 2 of 5 pending clarifications. Resolve those two; leave the rest untouched. Report: *"Resolved 2 clarifications. 3 still pending in Open questions."*
- **Ambiguous match** — user's answer could resolve multiple CLARIFY markers (two "rate limiting" questions, say). Do not guess. Ask: *"Which CLARIFY did you mean — Step 3 (transient failure definition) or Step 7 (client-side backoff)?"* Resolve only after disambiguation.
- **Underspecified answer** — the user's answer introduces a new hole ("retry on errors" — which errors?). Replace the original CLARIFY with the partial resolution, and append a follow-up `=[CLARIFY: which errors qualify?]=` in the same spot. Mirror the new question to Open questions (new unchecked bullet). Report: *"Resolved partially; follow-up clarification added at <location>."* Never silently downgrade to a weaker assumption — that's the exact failure mode CLARIFY is designed to prevent.
- **No matching CLARIFY** — user's chat message looks like a resolution but no matching CLARIFY exists (misremembered, or already resolved in a prior session). Ask for clarification: *"I don't see an open CLARIFY matching that — did you mean <closest candidate>, or are you asking me to edit something else?"* Never edit silently based on a guess.
- **Wrong direction / undo** — if the user realizes a prior resolution was wrong, they edit the org file directly (or create a new annotation with a correcting instruction). There is no "undo resolution" command — the plan is plain org text, not a state machine, and the annotation history isn't a rollback log.

### Report back

Chat message: a bullet list, one line per annotation handled:

```
- `<section>` / "<highlighted-text-truncated-to-40-chars>" → <what you changed>
```

Example:

```
- Steps / "First step: rewrite the auth middleware…" → Expanded into two sub-steps per your note
- Risks / "Token leakage in logs" → Merged into the Approach section as you requested
```

## Status mode

### Resolve scope

Same logic as Author mode:

```bash
git rev-parse --show-toplevel 2>/dev/null
```

- If success, scope is `<repo-root>/plans/`.
- Else, scope is `$HOME/plans/`.

If the directory doesn't exist, report: "No plans directory found at `<path>`." and stop.

### Enumerate plans

```bash
ls -t <scope>/*.org 2>/dev/null
```

If the glob returns nothing, report: "No plans in `<scope>`." and stop.

### Count annotations per plan

For each file, call `claude-collab-list-annotations` with the file path to get the pending count. If the MCP call errors for any file, report `?` as the count and continue.

### Report back

One bullet per plan, sorted most-recently-modified first:

```
- `plans/<basename>` — <N> pending (<relative-mtime>)
```

Use a short relative time like "2h ago", "3d ago", "just now". If the count is zero, still list the plan (it's completed or untouched — user wants to see it).

## Examples

Three end-to-end traces. Use these as patterns to match against when you're unsure how a flow should play out.

### Example 1 — Author mode (new plan with CLARIFY markers)

**User:** `/design rate limiter for our public REST API`

**Resolution:** topic = `rate limiter for our public REST API` → slug = `rate-limiter-for-our-public-rest-api` → filename = `2026-04-21-rate-limiter-for-our-public-rest-api.org`. Repo root detected, so target = `<repo>/plans/`.

**Draft written** (abbreviated — showing just the CLARIFY-relevant pieces):

```org
#+TITLE: rate limiter for our public REST API
#+DATE: 2026-04-21
#+STARTUP: showall inlineimages
#+TODO: TODO CLARIFY(c) | DONE RESOLVED(r)

* Approach
  Token bucket in Redis, keyed by API credential. Tiers
  (free/standard/enterprise) refresh via TTL. We fail open on
  =[CLARIFY: reuse the existing shared Redis cluster, or provision
  a dedicated one?]= Redis unavailability to avoid blocking the API.

* Steps
  3. [ ] Gateway middleware
     :PROPERTIES:
     :files:  gateway/middleware/ratelimit.go
     :tests:  gateway/middleware/ratelimit_test.go
     :verify: 429 returned with RateLimit-* headers for over-quota keys
     :END:
     Reads bucket, decrements, emits RFC 9331 headers, returns 429 on
     rejection.

* Open questions
  - [ ] [[*Approach][Approach]]: reuse shared Redis cluster or
    provision a new one?
  - [ ] Initial numeric tier values (free/standard/enterprise req/sec)?
  - [ ] Unauthenticated-endpoint keying (per-IP, per-ASN, per-route)?
```

One inline CLARIFY mirrored to Open questions (linked), two free-standing Open-questions bullets for cross-cutting decisions that don't pin to one prose location — consistent with the `markers ⊆ Open questions` rule.

**Chat report:** *"Wrote `plans/2026-04-21-rate-limiter-for-our-public-rest-api.org`. Opened in Emacs. 3 Open questions (1 mirrored CLARIFY, 2 cross-cutting). Annotate with `SPC o c c` on a selected region, then `/design revise` to apply annotations."*

### Example 2 — Conversational CLARIFY resolution

**Context:** Example 1's plan is open in Emacs. User has read it and knows one answer.

**User (chat, not annotation):** *"For the Redis question — reuse the shared cluster. We already pay for it and latency is fine."*

**Claude's steps:**
1. Read the currently-open plan (via `mcp__emacs__eval-elisp` → `buffer-file-name`).
2. Grep for `[CLARIFY:` markers + matching text. One match: the inline marker in Approach.
3. Replace via `claude-collab-apply-edit` with resolved prose: *"We fail open on shared-Redis-cluster unavailability to avoid blocking the API."*
4. Find the matching Open questions bullet (internal link target: `*Approach`) and tick it `- [X]`.
5. No annotation to resolve — this was chat-channel.

**Chat report:** *"Resolved 1 clarification in Approach (Redis cluster reuse). 2 Open questions still pending."*

### Example 3 — Annotation-driven CLARIFY resolution

**Context:** User is in Emacs, selects `=[CLARIFY: reuse the existing shared Redis cluster, or provision a dedicated one?]=`, hits `SPC o c c`, types in the annotation label: *"Reuse shared cluster — already provisioned, latency OK"*. Runs `/design revise`.

**Claude's steps:**
1. `claude-collab-list-annotations` returns one pending annotation on the CLARIFY span.
2. Detect: annotation overlaps `=[CLARIFY: …]=` → treat label as resolution, not a generic edit.
3. `claude-collab-apply-annotation` with `:action replace :new-text "shared-Redis-cluster"` (auto-resolves annotation on success).
4. Prose now reads: *"We fail open on shared-Redis-cluster unavailability..."*.
5. Find matching Open questions bullet, tick it.

**Chat report:**
```
- Approach / "reuse the existing shared Redis cluster..." → Resolved: reuse shared cluster. Ticked matching Open questions bullet.
```

Note: when the label reads like an *edit instruction* ("reword to emphasize latency") rather than an *answer* ("reuse shared cluster"), you're back in the normal reword/skip/expand patterns from "Apply each annotation" — not a CLARIFY resolution. The shape of the label tells you which path to take.

## Style notes

- Keep first drafts terse. The annotate-revise loop is where content matures; over-writing upfront wastes the user's edit budget.
- Do not auto-render the PlantUML block yourself. `claude-collab-auto-render-diagrams-mode` renders on file open (added to `org-mode-hook` globally). The user can also `C-c C-c` on any block for a forced re-render.
- Never prefix the slug with the date — the filename does that separately. `2026-04-21-rewrite-auth.org`, not `2026-04-21-2026-04-21-rewrite-auth.org`.
- If the user invokes `/design` with a topic that clearly describes an existing plan ("continue the auth redesign"), still default to Author mode and let the collision handling kick in. Don't try to guess that they meant Revise — wrong guesses are worse than a deterministic rule.
