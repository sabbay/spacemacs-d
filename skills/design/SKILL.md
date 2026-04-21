---
name: design
description: Use this skill whenever the user wants to author, revise, or list an org-mode design/plan document. Triggers on /design, and on phrases like "design X", "plan X", "sketch a plan for X", "write a design doc for X". Produces a structured org-mode file with a PlantUML architecture diagram, and supports an annotation-driven revision loop via claude-collab. Use this skill even when the user doesn't explicitly say "design" — if they're proposing to plan, outline, or architect anything non-trivial, this is the right tool. It replaces the generic plan-writing flow for users working in Emacs.
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

Fill in the skeleton below based on what you know about the topic. The section headings are required; content inside each is your judgment call. Aim for terse prose — the user will iterate via annotations, and dense first drafts waste their edit budget.

```org
#+TITLE: <topic>
#+DATE: <YYYY-MM-DD>
#+STARTUP: showall inlineimages

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
     :files: <comma-separated files this step touches>
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
- Each Step heading MUST have a `:files:` org property even if the list is short; it's the one piece of structure that pays off during implementation.
- If a section genuinely has no content (e.g., no open questions yet), write `- <none for now>` rather than deleting the section — keep the skeleton stable.

If the Write tool fails (directory not writable, disk full, etc.), report the failure path and error to the user and stop — do not proceed to Open in Emacs.

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
   - Free-form prose → interpret as an instruction and apply your best edit.
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

## Style notes

- Keep first drafts terse. The annotate-revise loop is where content matures; over-writing upfront wastes the user's edit budget.
- Do not auto-render the PlantUML block yourself. `claude-collab-auto-render-diagrams-mode` renders on file open (added to `org-mode-hook` globally). The user can also `C-c C-c` on any block for a forced re-render.
- Never prefix the slug with the date — the filename does that separately. `2026-04-21-rewrite-auth.org`, not `2026-04-21-2026-04-21-rewrite-auth.org`.
- If the user invokes `/design` with a topic that clearly describes an existing plan ("continue the auth redesign"), still default to Author mode and let the collision handling kick in. Don't try to guess that they meant Revise — wrong guesses are worse than a deterministic rule.
