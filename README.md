# Spacemacs configuration

My Spacemacs dotfile, custom elisp, and assets — kept in one self-contained
git repo so a new machine is one `git clone` + Spacemacs install away from
my full setup.

## Layout

```
~/.spacemacs.d/
├── init.el                          # the dotfile (layer list, init settings, themes)
├── lisp/
│   ├── user-init.el                 # body of dotspacemacs/user-init (PATH setup)
│   └── user-config.el               # body of dotspacemacs/user-config (everything else)
└── assets/
    └── markdown-preview-header.html # mermaid + MathJax + CSS for the xwidget preview
```

`init.el`'s `dotspacemacs/user-init` and `dotspacemacs/user-config` are
one-line loaders that `(load ...)` the matching files under `lisp/`. Edit
the helper files directly — the dotfile only needs to change for layer or
init-setting changes.

## Bootstrap on a new machine

```sh
# 1. Install Emacs (macOS example)
brew install --cask emacs

# 2. Install Spacemacs into the canonical location
git clone https://github.com/syl20bnr/spacemacs ~/.emacs.d

# 3. Clone this repo into ~/.spacemacs.d/
git clone <this-repo-url> ~/.spacemacs.d

# 4. Make sure no stale ~/.spacemacs is in the way
[ -e ~/.spacemacs ] && mv ~/.spacemacs ~/.spacemacs.bak

# 5. Launch Emacs — Spacemacs will install all packages declared in init.el
emacs
```

External tooling that the customizations expect to find on `PATH`:

- `rg` (ripgrep) — used by helm-grep
- `pandoc` — markdown live preview
- `plantuml` (provides `plantuml.jar`) — org-babel PlantUML blocks
- Homebrew at `/opt/homebrew` (Apple Silicon) — `lisp/user-init.el` adds the
  Homebrew bin dirs to `exec-path`

On macOS:

```sh
brew install ripgrep pandoc plantuml
```
