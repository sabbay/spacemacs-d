# /design Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a user-level `design` skill at `~/.claude/skills/design/` that authors org-mode plan artifacts, revises them through `claude-collab` annotations, and lists them via a `status` subcommand.

**Architecture:** Single `SKILL.md` file that dispatches on the first argument to one of three modes: author (default), `revise`, or `status`. The skill composes three existing systems — `ob-plantuml` for rendered diagrams, `claude-collab-auto-render-diagrams-mode` for inline rendering on open, and `claude-collab` annotations via org-remark for the revise loop. No elisp changes needed.

**Tech Stack:** Markdown SKILL.md + frontmatter (skill-creator format), Bash shell-outs for filesystem/git probing, `mcp__emacs__eval-elisp` for opening files, `claude-collab` MCP tools (`claude-collab-list-annotations`, `claude-collab-resolve-annotation`) for the revise loop.

---

## Context

The spec lives at `/Users/michalsz/.spacemacs.d/plans/2026-04-21-design-skill.org`. Read it before starting. The spec's original Step 1 ("auto-enable annotation mode on plans/\*.org") was dropped after discovering `org-remark-global-tracking-mode` is already on globally in `claude-collab.el:376`.

The skill directory structure follows standard Claude Code skill layout:

```
~/.claude/skills/design/
├── SKILL.md        (the skill itself — one file)
└── evals/
    └── evals.json  (test prompts for skill-creator review loop)
```

No `scripts/`, `references/`, or `assets/` directories are needed — the skill is short enough to live in SKILL.md alone.

---

### Task 1: Scaffold skill directory and write the complete SKILL.md

**Files:**
- Create: `~/.claude/skills/design/SKILL.md`

- [ ] **Step 1: Create the skill directory**

Run:
```bash
mkdir -p ~/.claude/skills/design/evals
ls -la ~/.claude/skills/design/
```
Expected: directory exists and contains `evals/` subdirectory, no errors.

- [ ] **Step 2: Write the full SKILL.md**

Write the file exactly as below to `~/.claude/skills/design/SKILL.md`. The full content is given in one block because the sections are cohesive and split-writing would break cross-references:

````markdown
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

- If it is exactly `revise`, dispatch to **Revise mode**. Any remaining args are an optional file path.
- If it is exactly `status`, dispatch to **Status mode**. No further args.
- Otherwise, treat the entire argument string as the plan topic and dispatch to **Author mode**.
- If the argument is empty or whitespace, prompt the user once: "What are you designing?" Wait for their reply, then use that as the topic in Author mode.

## Author mode

### Preflight

Before writing anything, verify `plantuml` is available:

```bash
which plantuml
```

If the command exits non-zero, abort immediately and tell the user:

> "PlantUML not found. Install with `brew install plantuml` (or your package manager's equivalent) and re-run /design. A plan without a rendered architecture diagram misses the point of this skill, so halting loud is intentional."

Do not proceed to the write step. A plan with a broken diagram defeats the purpose.

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
- Filename: `<date>-<slug>.org`.
- Full path: `<target-directory>/<filename>`.

### Collision handling

If the file already exists at that path, do NOT overwrite. Instead:

1. Skip the write step.
2. Still perform the "Open in Emacs" step below.
3. In your chat report, say: "Continuing existing plan at `<relative-path>`. Opened in Emacs."

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
3. Else, fall back to the most recently modified `.org` file in the current scope's plans directory (same logic as Author mode: repo-local if in a git repo, else `~/plans/`):
   ```bash
   ls -t <target-dir>/*.org 2>/dev/null | head -1
   ```
4. If none of the above yields a path, abort with: "No plan found to revise. Run `/design <topic>` to create one, or pass an explicit path."

### List pending annotations

Call the `claude-collab-list-annotations` MCP tool with the resolved file path. Each returned annotation has fields:

- `:id` — opaque identifier used to resolve it later
- `:text` — the highlighted region's text
- `:label` — the user's note (the edit instruction)
- `:line` — line number in the file
- `:section` — the enclosing org heading (if the MCP provides it; otherwise parse the nearest heading above `:line` yourself)

If there are no pending annotations, stop with: "No pending annotations in `<path>`."

### Apply each annotation

For each annotation, in file order:

1. Read the `:label` as the user's edit intent. Common patterns:
   - "skip" / "drop" → delete the annotated step or section.
   - "combine with next" / "merge 5 and 6" → merge items.
   - "expand" / "more detail" → rewrite with more specificity.
   - "reword: X" → replace the text with X.
   - Free-form prose → interpret as an instruction and apply your best edit.
2. Make the edit using the `Edit` tool directly on the file on disk. Do NOT go through `mcp__emacs__eval-elisp` for the edit — direct file writes are simpler, and claude-collab's auto-revert keeps Emacs in sync.
3. Call the `claude-collab-resolve-annotation` MCP tool with `:id`.

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
````

- [ ] **Step 3: Verify the file is well-formed**

Run:
```bash
head -5 ~/.claude/skills/design/SKILL.md
wc -l ~/.claude/skills/design/SKILL.md
```
Expected: first five lines show the YAML frontmatter (`---`, `name: design`, `description: ...`, `---`, blank or header). Line count around 200.

- [ ] **Step 4: Reload plugins so Claude Code picks up the new skill**

Tell the user to run `/reload-plugins` in their Claude Code session, or (if this plan is being executed by a subagent that can't send slash commands on the user's behalf) note in the final status that `/reload-plugins` is required before the skill becomes invocable.

- [ ] **Step 5: Commit**

```bash
git -C ~/.spacemacs.d status   # sanity check: expect no changes here
cd ~/.claude/skills/design && ls -la
```

The skill lives outside the `~/.spacemacs.d` repo, so there's nothing to commit in that repo for this task. If `~/.claude/skills/` is itself a git repo (check with `git -C ~/.claude/skills status`), commit there:

```bash
git -C ~/.claude/skills add design/SKILL.md
git -C ~/.claude/skills commit -m "Add /design skill: org-mode plan authoring + revise/status"
```

If `~/.claude/skills/` is not a git repo, skip the commit — note the fact in your task completion message so the user can decide whether to track it.

---

### Task 2: Write skill-creator evals

**Files:**
- Create: `~/.claude/skills/design/evals/evals.json`

- [ ] **Step 1: Write the evals file**

Write the exact content below to `~/.claude/skills/design/evals/evals.json`:

```json
{
  "skill_name": "design",
  "evals": [
    {
      "id": 1,
      "prompt": "ok I've been putting off dark mode in the settings panel for three sprints now and my designer is starting to send me passive-aggressive slack messages. can you /design a plan for adding dark mode support? we've got a theme context already but it's light-only, and the settings UI has like 40 components that need to be audited",
      "expected_output": "An org-mode plan file under ./plans/YYYY-MM-DD-<slug>.org (or ~/plans/ if not in a repo). File contains the required sections (Goal, Approach, Architecture with PlantUML :file arch.png src block, Steps with :files: properties and [ ] checkboxes, Risks, Open questions). Chat reports the path and how to annotate.",
      "files": []
    },
    {
      "id": 2,
      "prompt": "/design",
      "expected_output": "Claude asks exactly one clarifying question: 'What are you designing?' and waits for the user's reply before writing anything. Does not guess a topic.",
      "files": []
    },
    {
      "id": 3,
      "prompt": "/design status",
      "expected_output": "Claude enumerates .org plan files under the current scope (./plans/ if in a repo, else ~/plans/). For each, reports a bullet line with the filename, pending annotation count via claude-collab-list-annotations, and a relative mtime. If no plans exist, reports that cleanly.",
      "files": []
    }
  ]
}
```

The `revise` subcommand is deliberately not covered by an automated eval — it requires a pre-annotated input file, which skill-creator's eval runner doesn't stage cleanly. Revise is verified manually in Task 3.

- [ ] **Step 2: Commit (if applicable)**

Same logic as Task 1 Step 5: commit in `~/.claude/skills/` if it's a git repo, else note the file was written and skip.

---

### Task 3: Manual smoke test and revise-mode verification

This task is verification, not implementation. Run it in a fresh Claude Code session after `/reload-plugins`.

**Files:**
- Smoke-test artifact will appear at: `<repo-or-home>/plans/<date>-<some-slug>.org`

- [ ] **Step 1: Smoke-test Author mode with a topic**

In a Claude Code session inside any git repo (e.g. `~/.spacemacs.d`), invoke:

```
/design test run — ignore this plan
```

Expected:
- Claude runs the preflight, finds `plantuml`, resolves target to `./plans/`, writes `./plans/<today>-test-run-ignore-this-plan.org`, opens it in Emacs.
- Opening the file in Emacs triggers `claude-collab-auto-render-diagrams-mode` which renders `<slug>-arch.png` inline within ~1.5s.
- Chat reports the relative path.

If any of those steps fail, fix the SKILL.md instructions (not the underlying infra) and commit the fix, then re-run.

- [ ] **Step 2: Smoke-test Author mode without a topic**

```
/design
```

Expected: Claude asks "What are you designing?" and does nothing else. It does NOT write a placeholder file or guess a topic.

- [ ] **Step 3: Smoke-test Revise mode**

In Emacs, open the test plan from Step 1. Select any line of prose and run `SPC o c c`, entering an annotation like "expand this section". Then in the Claude Code session, invoke:

```
/design revise
```

Expected:
- Claude detects the buffer file via `mcp__emacs__eval-elisp`.
- Claude calls `claude-collab-list-annotations`, finds the one pending annotation.
- Claude edits the file to expand the section.
- Claude calls `claude-collab-resolve-annotation` with the annotation ID.
- Chat reports a single bullet summarizing the change.
- In Emacs, the annotation overlay disappears after auto-revert.

- [ ] **Step 4: Smoke-test Status mode**

```
/design status
```

Expected: bullet list of every `.org` file in `./plans/`, with annotation counts (0 for fully-resolved files, 1+ for files with pending annotations). Sorted most-recent first.

- [ ] **Step 5: Clean up test artifact**

```bash
rm <repo-or-home>/plans/<today>-test-run-ignore-this-plan.org
```

---

### Task 4: Run skill-creator review loop

This task is iteration, not up-front implementation. It's a pointer to the skill-creator workflow — run it once Tasks 1–3 are done and the skill is invocable.

- [ ] **Step 1: Invoke skill-creator on the drafted skill**

In a Claude Code session, run:
```
/skill-creator:skill-creator improve the design skill I just drafted at ~/.claude/skills/design/. Evals are in evals/evals.json. Run the eval loop and help me iterate.
```

- [ ] **Step 2: Work through the review cycle**

Let skill-creator spawn with-skill and without-skill subagents on the three evals, review the HTML viewer, read feedback, and propose SKILL.md edits. Accept or reject each proposed edit based on whether it matches the spec's intent.

Stop when:
- Two consecutive iterations produce no meaningful changes, or
- All three evals pass qualitatively and you're satisfied with the output format.

- [ ] **Step 3: Optionally run description optimization**

Once content is stable, skill-creator offers to optimize the `description:` frontmatter for trigger accuracy. Run it if triggering ever feels wrong in regular use, otherwise skip — the description was written with "pushy" triggers in mind and should work out of the box.

---

## Self-review

**Spec coverage check:**
- Author mode with topic arg → Task 1 (SKILL.md Author section), Task 3 Step 1.
- Author mode prompt-back on empty arg → Task 1 (Dispatch section), Task 3 Step 2.
- Revise subcommand via claude-collab annotations → Task 1 (Revise section), Task 3 Step 3.
- Status subcommand → Task 1 (Status section), Task 3 Step 4.
- Git-repo detection for file location → Task 1 (Resolve target directory in Author mode; Resolve scope in Status mode).
- PlantUML preflight → Task 1 (Preflight section).
- Collision = continue existing → Task 1 (Collision handling).
- Open in Emacs via MCP → Task 1 (Open in Emacs section).
- Two or three evals → Task 2.

Dropped from the original spec:
- "Auto-enable claude-collab annotations for plans/\*.org" — redundant with `org-remark-global-tracking-mode` which is already globally on.

**Type/name consistency check:**
- MCP tool names used: `mcp__emacs__eval-elisp`, `claude-collab-list-annotations`, `claude-collab-resolve-annotation`. These match the emacs MCP server's registered tool names per `lisp/claude-collab.el:495–512`.
- Annotation field names used: `:id`, `:text`, `:label`, `:line`, `:section`. The first three map to real fields in the `claude-collab-edit` struct per `lisp/claude-collab.el`. `:line` and `:section` are derived; the SKILL.md notes explicitly that `:section` may need to be computed by the skill if not provided.
- Filename pattern `<date>-<slug>.org` is consistent across Author mode, Status mode enumeration, and the evals' `expected_output`.

**Placeholder scan:** No TBDs, no "add appropriate error handling," no "similar to Task N." All code blocks contain their full content.
