;;; user-init.el --- Body of dotspacemacs/user-init -*- lexical-binding: t -*-
;;
;; Loaded by dotspacemacs/user-init in ../init.el.
;; Runs before layer/package configuration. Use only for things that must be
;; set before packages load — most user code belongs in user-config.el.

;; GUI Emacs on macOS doesn't inherit the shell PATH, so external tools
;; like vmd, pandoc, rg etc. installed via Homebrew aren't found.
(when (memq window-system '(mac ns))
  (dolist (p '("/opt/homebrew/bin" "/opt/homebrew/sbin" "/usr/local/bin"))
    (when (file-directory-p p)
      (add-to-list 'exec-path p)
      (setenv "PATH" (concat p ":" (getenv "PATH"))))))

(provide 'user-init)
;;; user-init.el ends here
