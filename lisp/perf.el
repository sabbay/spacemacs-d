;;; perf.el --- Startup + steady-state performance tweaks -*- lexical-binding: t -*-
;;
;; Loaded from user-config.el. Spacemacs already handles two of the big
;; classics: it bumps `gc-cons-threshold' to `most-positive-fixnum' for
;; the duration of init and resets it via `dotspacemacs-gc-cons', and it
;; sets `read-process-output-max' via `dotspacemacs-read-process-output-max'.
;; Don't redo those here — see ../init.el.

;; ----- Garbage Collector Magic Hack -----
;; Raises gc-cons-threshold while you're typing/working and lowers it on
;; idle, so GC runs during pauses instead of mid-keystroke. Strictly
;; better than a static threshold for interactive use; takes precedence
;; over the static `dotspacemacs-gc-cons' value once enabled.
(use-package gcmh
  :demand t
  :diminish gcmh-mode
  :config
  (setq gcmh-idle-delay 'auto       ; tune delay based on observed GC cost
        gcmh-auto-idle-delay-factor 10
        gcmh-high-cons-threshold (* 128 1024 1024)) ; 128MB while active
  (gcmh-mode 1))

;; ----- Font cache stutter -----
;; Compaction of the font cache on GC is a known source of brief freezes
;; in buffers with mixed unicode (emoji, CJK, math symbols). The cache
;; is small enough that not compacting it is a non-issue.
(setq inhibit-compacting-font-caches t)

;; ----- Long-line handling -----
;; `bidi-paragraph-direction' set to LTR skips the bidirectional
;; reordering pass on every redisplay. `bidi-inhibit-bpa' disables
;; bracket-pair resolution which is the slowest part of the bidi
;; algorithm. Both are safe for English/code; flip back to default if
;; you start editing RTL text.
(setq-default bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)

;; `so-long' detects pathologically long lines (minified JS, log dumps)
;; and switches the buffer to a stripped-down mode that disables the
;; expensive minor modes (font-lock, line numbers, etc.). Built into
;; Emacs since 27.
(when (fboundp 'global-so-long-mode)
  (global-so-long-mode 1))

;; ----- macOS NS-port frame tweaks -----
;; `ns-use-native-fullscreen' nil disables the slow Lion-style fullscreen
;; animation and the separate Space; old-style fullscreen is just a
;; resize, with much faster redisplay. Toggle fullscreen with `M-RET' /
;; `SPC w F'.
;;
;; `frame-resize-pixelwise' avoids an extra layout pass when macOS
;; resizes by pixel (which it does for every drag on Retina displays).
(when (eq window-system 'ns)
  (setq ns-use-native-fullscreen nil)
  (setq frame-resize-pixelwise t))

;; ----- Native compilation warnings -----
;; AOT compilation of packages emits a warnings buffer for every
;; deprecation in upstream code. Useful once, noisy forever.
(when (boundp 'native-comp-async-report-warnings-errors)
  (setq native-comp-async-report-warnings-errors 'silent))

;; ----- LSP tuning -----
;; `lsp-log-io' is the big one — when t, every JSON-RPC frame is
;; appended to a buffer that grows without bound and slows the whole
;; client. `lsp-idle-delay' controls how often lsp recomputes things
;; like document symbols; 0.5s is a good balance.
(with-eval-after-load 'lsp-mode
  (setq lsp-log-io nil
        lsp-idle-delay 0.5
        lsp-completion-provider :capf
        ;; lsp-mode prints "[lsp-mode] ..." progress messages on every
        ;; project file analysis — they spam the echo area and force
        ;; mode-line redraws.
        lsp-progress-spinner-type 'progress-bar
        lsp-enable-file-watchers nil          ; macOS handles this fine; the watcher is expensive on big trees
        lsp-file-watch-threshold 5000))

(with-eval-after-load 'lsp-ui
  ;; Sideline updates on every cursor move and triggers redisplay
  ;; churn. Keep doc-frame (used by K binding) but turn off the parts
  ;; that fire constantly.
  (setq lsp-ui-sideline-enable nil
        lsp-ui-sideline-show-diagnostics nil
        lsp-ui-sideline-show-hover nil
        lsp-ui-sideline-show-code-actions nil))

;; ----- recentf / savehist throttling -----
;; Both write their state to disk; doing it on every change produces
;; constant tiny fsyncs. Auto-save every 5 minutes via timer instead.
(with-eval-after-load 'recentf
  (setq recentf-auto-cleanup 300            ; was 'mode (every load)
        recentf-max-saved-items 200))

(with-eval-after-load 'savehist
  (setq savehist-autosave-interval 300))    ; was 60s

(provide 'perf)
;;; perf.el ends here
