# Claude instructions for this repo

This is a Spacemacs configuration with custom Emacs Lisp under `lisp/`.

## Always consult llms.txt first

Before editing, debugging, or answering questions about Emacs, Org Mode, or any elisp in this repo, **read `llms.txt` at the repo root**. It points to the canonical info manuals (shipped with the installed Emacs 30.2) and explains how to dump any node or docstring via `emacs --batch`.

Prefer the local info manuals over web searches — they describe the exact API of the Emacs version actually running here, and catch version drift that web pages miss.

## When doc-backed reasoning matters

For anything involving buffer modification hooks, the `org-element` cache, async processes, text properties vs. overlays, or Babel/export internals: **quote the relevant info node before proposing a fix**. These areas have subtle documented rules and silent failure modes; inference from reading code alone is unreliable.

## Style

- Terse responses. The user reads diffs.
- No emojis unless asked.
- Don't invent abstractions or add defensive scaffolding beyond what the task needs.
- Display/theme changes must work in both solarized-light and solarized-dark.
