# Verifying the .spacemacs → .spacemacs.d/ migration

Handoff document. A Claude Desktop session with **Computer Use** enabled
should follow the checklist below to verify that splitting `~/.spacemacs`
into this repo didn't break anything. Each task says what success looks
like and what to do on failure.

## What changed

`~/.spacemacs` (~1200 lines) was split into this repo:

- `init.el` — slim Spacemacs dotfile (layers, init settings, themes).
  `dotspacemacs/user-init` and `dotspacemacs/user-config` are one-line
  loaders that `(load ...)` the files under `lisp/`.
- `lisp/user-init.el` — macOS Homebrew PATH injection.
- `lisp/user-config.el` — all custom code (LSP UI, helm/rg flags,
  reveal-in-osx-finder, org+plantuml, image-popup framework, markdown
  xwidget-webkit preview, cursor-sync minor-mode, macOS appearance theme
  switcher).
- `assets/markdown-preview-header.html` — was previously a giant inline
  HTML/JS/CSS string regenerated each startup; now an on-disk source file.

The original `~/.spacemacs` is preserved at `~/.spacemacs.bak`. Spacemacs
prefers `~/.spacemacs` over `~/.spacemacs.d/init.el` when both exist, so
moving it aside is what makes this repo go live.

## Prerequisites (do BEFORE handing the task to Claude Desktop)

1. Pro or Max Anthropic plan.
2. Latest Claude Desktop installed and running.
3. **Settings → General** (under "Desktop app") → toggle **Computer use** on.
4. On macOS, grant **Accessibility** and **Screen Recording** when prompted.

Then in the Code tab of Claude Desktop, point a session at this folder
(`~/.spacemacs.d/`) and tell it to run the checklist below.

## Verification tasks

Run in order. Stop and report back the moment something fails — don't
attempt fixes; that's a job for a fresh planning session.

### 1. Cold-start Emacs

Quit any running Emacs (Cmd-Q in the Emacs menu, or `pkill -x Emacs` in a
terminal). Launch `Emacs.app` (Spotlight or `open -a Emacs` in a terminal).
Wait for the Spacemacs splash screen to finish loading (10–30 s on first
boot of the day).

- **Success:** the Spacemacs welcome buffer renders with no error popups.
  The mode-line is populated. The theme is solarized (light or dark
  matching macOS appearance), not the default off-white.
- **Failure:** a "Spacemacs error" buffer with a backtrace, or the theme
  is wrong. Capture the contents of the `*Messages*` buffer
  (`M-x view-echo-area-messages`) and report back.

### 2. Custom defuns are loaded from the new location

`M-x describe-function RET my/org-image-popup-at-point RET`.

- **Success:** the help buffer shows the docstring; the top line reads
  *"my/org-image-popup-at-point is an interactive Lisp closure ... Defined
  in `~/.spacemacs.d/lisp/user-config.el`"* (or similar). The path is the
  important bit — it must be the new helper file, not the old `.spacemacs`.

### 3. Image popup in org-mode

Open `~/Development/promptdecor/docs/code-health/ABSTRACTION_REFACTOR_PLAN.org`
(or any other `.org` file in `~/Development/` containing an inline image or
`[[file:…image…]]` link). With point on the image or link, press the
leader sequence `, v` (comma, then v) — or run
`M-x my/org-image-popup-at-point`.

- **Success:** a new floating frame opens running `image-mode` and shows
  the image. Press `q` in that frame to close it.

### 4. Markdown live preview (xwidget-webkit)

Open any `.md` file (e.g. `~/.spacemacs.d/README.md` or this file).
`M-x markdown-live-preview-mode`.

- **Success:** a side window opens hosting an xwidget-webkit view that
  renders the markdown — headers, code blocks, etc. Move point in the
  source buffer; the preview should auto-scroll to the matching line
  (cursor-sync minor mode is active when `md-sync` shows in the
  mode-line).
- **Known non-failure:** if Emacs reports *"This Emacs was not built with
  xwidget-webkit support"*, that's a build issue with the Emacs binary,
  not the config. Note it and move on — this would have broken the same
  way before the migration.

### 5. macOS appearance theme switching

System Settings → Appearance → toggle Light ↔ Dark.

- **Success:** Emacs's solarized theme switches in the same direction
  within ~1 s.

### 6. PATH inheritance in GUI Emacs

`M-:` (eval-expression) → `(executable-find "rg")` → RET.

- **Success:** echoes a path like `/opt/homebrew/bin/rg`. Not `nil`.

## If something breaks

Single-command rollback in a terminal:

```sh
mv ~/.spacemacs.bak ~/.spacemacs
```

Spacemacs ignores `~/.spacemacs.d/init.el` whenever `~/.spacemacs` exists,
so restarting Emacs immediately puts you back on the pre-migration config.
Capture the failing-run `*Messages*` buffer first so we can fix the
migration before re-applying it.

## If all tests pass

Reply confirming all six checks passed. The migration is verified end-to-end
and `~/.spacemacs.d/` is the live source of truth for this machine. The
`.spacemacs.bak` safety net can stay or be deleted at your discretion.
After confirmation, this `VERIFY-MIGRATION.md` file has done its job and
can also be deleted (it's a one-shot doc, not part of the running config).
