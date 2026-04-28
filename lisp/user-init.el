;;; user-init.el --- Body of dotspacemacs/user-init -*- lexical-binding: t -*-
;;
;; Loaded by dotspacemacs/user-init in ../init.el.
;; Runs before layer/package configuration. Use only for things that must be
;; set before packages load — most user code belongs in user-config.el.

;; First-aid PATH fix. Runs before layer packages load, so any eager
;; `executable-find' a layer does at its own load time (e.g.
;; claude-code-ide) still finds claude/axcli/plantuml. The thorough
;; login-shell import via `exec-path-from-shell' happens later in
;; user-config.el, once ELPA packages are on `load-path'.
(dolist (p '("~/.axcli/bin" "~/.local/bin"
             "/opt/homebrew/bin" "/opt/homebrew/sbin" "/usr/local/bin"))
  (let ((d (expand-file-name p)))
    (when (file-directory-p d)
      (add-to-list 'exec-path d)
      (setenv "PATH" (concat d ":" (getenv "PATH"))))))

;; Tell lsp-mode to use plists instead of hash tables for JSON-RPC payloads.
;; ~3x faster deserialization on Apple Silicon — large LSP responses
;; (workspace/symbol, big completion lists) feel noticeably snappier.
;; Must be set BEFORE lsp-mode loads — the choice is baked in at byte-comp
;; time of lsp-protocol.el. If you flip this and lsp acts weird, run
;; `M-x emacs-lisp-native-compile-and-load' on lsp-protocol.el or just
;; rebuild the lsp-mode package.
(setenv "LSP_USE_PLISTS" "true")

(provide 'user-init)
;;; user-init.el ends here
