;;; user-init.el --- Body of dotspacemacs/user-init -*- lexical-binding: t -*-
;;
;; Loaded by dotspacemacs/user-init in ../init.el.
;; Runs before layer/package configuration. Use only for things that must be
;; set before packages load — most user code belongs in user-config.el.

;; GUI Emacs / emacs --daemon on macOS inherit a minimal PATH from
;; launchd, so tools installed under ~/.axcli/bin, ~/.local/bin, nvm,
;; pyenv, brew etc. aren't found. Spawn a login+interactive zsh once
;; and mirror its PATH (and a few extras) into Emacs's env; every
;; emacsclient frame then inherits the corrected process-environment.
(when (or (memq window-system '(mac ns x)) (daemonp))
  (require 'exec-path-from-shell)
  (dolist (var '("NODE_EXTRA_CA_CERTS" "LANG" "LC_ALL"))
    (add-to-list 'exec-path-from-shell-variables var))
  (exec-path-from-shell-initialize))

(provide 'user-init)
;;; user-init.el ends here
