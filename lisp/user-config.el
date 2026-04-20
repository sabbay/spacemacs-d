;;; user-config.el --- Body of dotspacemacs/user-config -*- lexical-binding: t -*-
;;
;; Loaded by dotspacemacs/user-config in ../init.el at the very end of
;; Spacemacs startup, after layer configuration.

;; Soft-wrap long lines everywhere: prose files, code, logs, shell output.
;; Wraps at word boundaries, doesn't modify the file. C-a/C-e respect
;; visual lines. Toggle per-buffer with `SPC t l' or `M-x visual-line-mode'.
(global-visual-line-mode 1)

;; Make K (hover) show the nice popup instead of a split buffer
(setq lsp-ui-doc-enable t
      lsp-ui-doc-show-with-cursor t
      lsp-ui-doc-delay 0.5
      lsp-ui-doc-show-with-mouse t
      lsp-ui-doc-position 'at-point)
(with-eval-after-load 'lsp-ui
  (define-key evil-normal-state-map (kbd "K") #'lsp-ui-doc-glance))

;; Show 3 lines of context in rg-based searches
(setq helm-grep-ag-command "rg --color=always --smart-case --no-heading --line-number -C 3 %s %s %s")

;; Reveal in Finder: SPC b f
(use-package reveal-in-osx-finder
  :commands (reveal-in-osx-finder))
(spacemacs/set-leader-keys "bf" 'reveal-in-osx-finder)

;; ----- Org-mode: inline PlantUML diagrams + TODO tracking -----
;; ob-plantuml ships with org. It runs PlantUML on #+begin_src plantuml
;; blocks and writes the result to :file; org's inline-image overlays
;; render it right under the source block — no preview buffer needed.
;; brew install plantuml  (provides plantuml(1) and plantuml.jar)
(with-eval-after-load 'org
  ;; Point babel at the brew-installed jar. Update the path if brew
  ;; upgrades the version (brew symlinks a per-version dir under Cellar).
  (let* ((cellar "/opt/homebrew/Cellar/plantuml")
         (latest (when (file-directory-p cellar)
                   (car (sort (directory-files cellar t "\\`[0-9]")
                              #'string-greaterp))))
         (jar    (when latest (expand-file-name "libexec/plantuml.jar" latest))))
    (when (and jar (file-exists-p jar))
      (setq org-plantuml-jar-path jar
            plantuml-jar-path jar
            plantuml-default-exec-mode 'jar)))

  ;; Languages we execute in babel blocks. PlantUML + dot cover every
  ;; diagram shape; typescript + shell + emacs-lisp are for literate
  ;; scaffolding.
  (org-babel-do-load-languages
   'org-babel-load-languages
   (append org-babel-load-languages
           '((plantuml . t)
             (dot . t)
             (shell . t)
             (emacs-lisp . t))))
  ;; Don't prompt on every C-c C-c — plantuml/dot blocks are safe.
  ;; Flip back to `t' or a predicate if you want stricter trust.
  (setq org-confirm-babel-evaluate nil)
  ;; Always show images inline; re-render after each C-c C-c.
  (setq org-startup-with-inline-images t
        org-image-actual-width '(700))
  (add-hook 'org-babel-after-execute-hook #'org-redisplay-inline-images)
  ;; Refactor-plan lives here — keep it in the agenda so TODOs show up.
  (add-to-list 'org-agenda-files
               (expand-file-name
                "~/Development/promptdecor/docs/code-health/ABSTRACTION_REFACTOR_PLAN.org")
               t))

;; ----- Image popup for org-mode (SVG / PNG / JPG in a floating frame) -----
;; Press `C-c C-x v' (or `, v' via Spacemacs leader) with point on an inline
;; image, a file: link, or a RESULTS link to open the image in a new frame
;; running `image-mode'. That gives you native zoom / scroll / rotate:
;;   + / -   zoom in / out          r       rotate 90°
;;   =       fit to window          s +/-   scale
;;   SPC DEL page down/up           0       reset
;;   arrows  scroll                 q       close popup frame

(defvar-local my/image-popup-frame nil
  "The frame hosting the current image popup, if any.")

(defun my/org-image-popup--file-at-point ()
  "Return an absolute path to the image file at point, or nil."
  (let* ((path
          (or
           ;; 1. Org link at point (works on inline image overlays because
           ;;    the overlay hides the [[file:...]] text but point still
           ;;    lands within the link syntax).
           (let ((ctx (org-element-context)))
             (and (eq (org-element-type ctx) 'link)
                  (member (org-element-property :type ctx) '("file" "excalidraw"))
                  (org-element-property :path ctx)))
           ;; 2. Fallback: scan the current line for [[file:...]]
           (save-excursion
             (beginning-of-line)
             (when (re-search-forward
                    "\\[\\[\\(?:file\\|excalidraw\\):\\([^]\n]+\\)\\]"
                    (line-end-position) t)
               (match-string-no-properties 1)))))
         (abs (when path
                (expand-file-name
                 path
                 (when buffer-file-name
                   (file-name-directory buffer-file-name))))))
    (when (and abs
               (file-exists-p abs)
               (string-match-p
                "\\.\\(svgz?\\|png\\|jpe?g\\|gif\\|webp\\|bmp\\|tiff?\\)\\'"
                abs))
      abs)))

(defun my/image-popup-close ()
  "Close the image popup frame. Does not kill the underlying buffer."
  (interactive)
  (let ((frame my/image-popup-frame))
    (when (frame-live-p frame)
      (delete-frame frame))))

(defun my/image-popup-open (abs-path)
  "Open ABS-PATH in a new, floating frame running `image-mode'.

Bypasses `switch-to-buffer' entirely (helm-mode advises that and would
pop up a buffer picker instead of switching). We set the window buffer
directly on the new frame's selected window."
  (let* ((buf (find-file-noselect abs-path))
         (w (display-pixel-width))
         (h (display-pixel-height))
         (frame (make-frame
                 `((name . ,(concat "  "
                                    (file-name-nondirectory abs-path)
                                    "   [ + / - zoom · = fit · r rotate · q close ]"))
                   (width . 160)
                   (height . 50)
                   (left . ,(/ w 12))
                   (top  . ,(/ h 12))
                   (unsplittable . t))))
         ;; On NS Emacs 30.2, `frame-root-window' of a freshly-made frame
         ;; can return a non-live internal window; `frame-selected-window'
         ;; is the live leaf we can actually `set-window-buffer' on.
         (win (frame-selected-window frame)))
    ;; Install the buffer without going through switch-to-buffer —
    ;; that avoids helm-mode / ido-mode advice hijacking.
    (set-window-buffer win buf)
    (set-frame-selected-window frame win)
    (with-current-buffer buf
      (unless (derived-mode-p 'image-mode) (image-mode))
      (when (fboundp 'image-transform-fit-to-window)
        (ignore-errors (image-transform-fit-to-window)))
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map image-mode-map)
        (define-key map (kbd "q") #'my/image-popup-close)
        (define-key map (kbd "=")
                    (lambda () (interactive)
                      (when (fboundp 'image-transform-fit-to-window)
                        (image-transform-fit-to-window))))
        (use-local-map map))
      (setq-local my/image-popup-frame frame))
    (select-frame-set-input-focus frame)))

(defun my/org-image-popup-at-point ()
  "Open the image under point in a floating frame for zoom/scroll/rotate.
Works on inline image overlays, file: links, and RESULTS links below
babel source blocks."
  (interactive)
  (let ((abs (my/org-image-popup--file-at-point)))
    (unless abs
      (user-error "No image file at point"))
    (my/image-popup-open abs)))

(defun my/org-open-image-as-popup ()
  "`org-open-at-point-functions' hook: popup image links instead of opening
externally. Return non-nil when we handled the link."
  (let ((ctx (org-element-context)))
    (when (and (eq (org-element-type ctx) 'link)
               (member (org-element-property :type ctx) '("file" "excalidraw")))
      (let* ((path (org-element-property :path ctx))
             (abs (when path
                    (expand-file-name
                     path
                     (when buffer-file-name
                       (file-name-directory buffer-file-name))))))
        (when (and abs
                   (file-exists-p abs)
                   (string-match-p
                    "\\.\\(svgz?\\|png\\|jpe?g\\|gif\\|webp\\|bmp\\|tiff?\\)\\'"
                    abs))
          (my/image-popup-open abs)
          t)))))

(with-eval-after-load 'org
  ;; RET follows links (was off by default); C-c C-o also works.
  (setq org-return-follows-link t)
  ;; Image links route through the popup instead of opening externally.
  (add-hook 'org-open-at-point-functions #'my/org-open-image-as-popup)
  (define-key org-mode-map (kbd "C-c C-x v") #'my/org-image-popup-at-point)
  (when (fboundp 'spacemacs/set-leader-keys-for-major-mode)
    (spacemacs/set-leader-keys-for-major-mode
      'org-mode "v" #'my/org-image-popup-at-point)))

;; Markdown: nice in-buffer previews via xwidget-webkit
(with-eval-after-load 'markdown-mode
  (setq markdown-fontify-code-blocks-natively t
        markdown-hide-urls nil
        markdown-header-scaling t
        markdown-enable-math t
        markdown-asymmetric-header t
        markdown-display-remote-images t
        markdown-max-image-size '(800 . 800)))
(add-hook 'markdown-mode-hook #'markdown-toggle-inline-images)

;; ----- xwidget-webkit-powered markdown preview -----
;; Pandoc renders the buffer to self-contained HTML that includes mermaid.js
;; + MathJax + GitHub-ish CSS. xwidget-webkit embeds a real WebKit view
;; inside Emacs, so JS (mermaid, math) actually executes.
;;
;; The header HTML/JS/CSS lives in ../assets/markdown-preview-header.html —
;; edit it as a normal source file (not as an Elisp string).

(defvar my/markdown-preview-header-file
  (expand-file-name "assets/markdown-preview-header.html" dotspacemacs-directory)
  "Path to the pandoc header-include used by the markdown preview.")

(setq markdown-command
      (format (concat "pandoc --from=gfm+sourcepos --to=html5 --standalone --mathjax "
                      "--highlight-style=pygments --include-in-header=%s")
              (shell-quote-argument my/markdown-preview-header-file)))

(defun my/markdown-live-preview-window-xwidget (file)
  "A `markdown-live-preview-window-function' backed by xwidget-webkit.
Navigates the shared xwidget-webkit session to FILE and wires
`revert-buffer' so subsequent saves reload the same view."
  (unless (featurep 'xwidget-internal)
    (error "This Emacs was not built with xwidget-webkit support"))
  (require 'xwidget)
  (let ((url (concat "file://" (expand-file-name file))))
    (xwidget-webkit-browse-url url)
    (let ((buf (xwidget-buffer (xwidget-webkit-current-session))))
      (with-current-buffer buf
        (setq-local my/markdown-preview-url url)
        (setq-local revert-buffer-function
                    (lambda (&rest _)
                      (xwidget-webkit-browse-url my/markdown-preview-url))))
      buf)))

(with-eval-after-load 'markdown-mode
  (setq markdown-live-preview-window-function
        #'my/markdown-live-preview-window-xwidget))

;; Vim-style navigation inside xwidget-webkit preview
(defvar my/xwidget-scroll-step 5
  "Number of lines j/k scrolls in xwidget-webkit buffers.")

(defun my/xwidget-scroll-down (&optional n)
  "Scroll xwidget content down N*`my/xwidget-scroll-step' lines."
  (interactive "p")
  (xwidget-webkit-scroll-up-line (* (or n 1) my/xwidget-scroll-step)))

(defun my/xwidget-scroll-up (&optional n)
  "Scroll xwidget content up N*`my/xwidget-scroll-step' lines."
  (interactive "p")
  (xwidget-webkit-scroll-down-line (* (or n 1) my/xwidget-scroll-step)))

(with-eval-after-load 'xwidget
  (evil-set-initial-state 'xwidget-webkit-mode 'normal)
  (evil-define-key 'normal xwidget-webkit-mode-map
    (kbd "j")    #'my/xwidget-scroll-down
    (kbd "k")    #'my/xwidget-scroll-up
    (kbd "C-d")  #'xwidget-webkit-scroll-up
    (kbd "C-u")  #'xwidget-webkit-scroll-down
    (kbd "h")    #'xwidget-webkit-scroll-backward
    (kbd "l")    #'xwidget-webkit-scroll-forward
    (kbd "g g")  #'xwidget-webkit-scroll-top
    (kbd "G")    #'xwidget-webkit-scroll-bottom
    (kbd "H")    #'xwidget-webkit-back
    (kbd "L")    #'xwidget-webkit-forward
    (kbd "r")    #'xwidget-webkit-reload
    (kbd "+")    #'xwidget-webkit-zoom-in
    (kbd "-")    #'xwidget-webkit-zoom-out
    (kbd "/")    #'xwidget-webkit-isearch-mode
    (kbd "q")    #'quit-window))

;; ----- cursor sync: markdown buffer <-> xwidget preview -----
;; Pandoc's +sourcepos extension tags HTML elements with data-pos attributes
;; pointing at their source lines. When point moves in the markdown buffer,
;; we ask the xwidget to scrollIntoView() the element covering that line.

(defvar-local my/markdown-preview-sync-timer nil)

(defun my/markdown-preview-sync-cursor ()
  "Scroll xwidget-webkit preview to the source line under point."
  (when (and (featurep 'xwidget-internal)
             (bound-and-true-p markdown-live-preview-mode))
    (when (timerp my/markdown-preview-sync-timer)
      (cancel-timer my/markdown-preview-sync-timer))
    (let ((line (line-number-at-pos)))
      (setq my/markdown-preview-sync-timer
            (run-with-idle-timer
             0.08 nil
             (lambda (l)
               (let ((session (ignore-errors (xwidget-webkit-current-session))))
                 (when session
                   (xwidget-webkit-execute-script
                    session
                    (format "window.scrollToLine && window.scrollToLine(%d);" l)))))
             line)))))

(define-minor-mode my/markdown-preview-cursor-sync-mode
  "Sync the xwidget-webkit markdown preview with point in the source."
  :lighter " md-sync"
  (if my/markdown-preview-cursor-sync-mode
      (add-hook 'post-command-hook #'my/markdown-preview-sync-cursor nil t)
    (remove-hook 'post-command-hook #'my/markdown-preview-sync-cursor t)))

(add-hook 'markdown-live-preview-mode-hook
          (lambda ()
            (my/markdown-preview-cursor-sync-mode
             (if markdown-live-preview-mode 1 -1))))

;; Auto-switch between solarized-light and solarized-dark based on macOS appearance
(defun my/apply-theme-for-appearance (appearance)
  "Load solarized-light or solarized-dark based on macOS APPEARANCE."
  (let ((theme (pcase appearance
                 ('light 'solarized-light)
                 ('dark 'solarized-dark))))
    (when (and theme (not (eq theme spacemacs--cur-theme)))
      (spacemacs/load-theme theme))))

(when (boundp 'ns-system-appearance-change-functions)
  ;; React to future appearance changes
  (add-hook 'ns-system-appearance-change-functions #'my/apply-theme-for-appearance)
  ;; Apply the correct theme at startup based on current appearance
  (when (boundp 'ns-system-appearance)
    (my/apply-theme-for-appearance ns-system-appearance)))

;; ----- org-excalidraw: insert + edit Excalidraw diagrams in Org files -----
;; `M-x org-excalidraw-create-drawing' inserts a link to a new .excalidraw
;; file under `org-excalidraw-directory' and opens it in the browser
;; (excalidraw.com). Saving the file in-browser writes back to disk; the
;; package then shells out to `excalidraw_export' to render an SVG that Org
;; displays inline.
;;
;; Requires the CLI:  npm install -g excalidraw_export
;; (Timmmm/excalidraw_export — provides the `excalidraw_export' binary).
(use-package org-excalidraw
  :after org
  :demand t
  :init
  (setq org-excalidraw-directory (expand-file-name "~/org/excalidraw"))
  :config
  (unless (file-directory-p org-excalidraw-directory)
    (make-directory org-excalidraw-directory t))
  ;; Starts the filenotify watcher on `org-excalidraw-directory'. Without
  ;; this, saves in the Excalidraw editor never trigger SVG generation
  ;; and the inline image stays stale/broken.
  (org-excalidraw-initialize)
  ;; Org 9.8 replaced `:image-data-fun' with `:preview' for inline display.
  ;; The package only registers the old parameter, so previews never render.
  ;; Custom previewer caps height (Org's `org-image-actual-width' caps width
  ;; only — tall/narrow Excalidraw drawings would otherwise dominate the buffer).
  (defvar my/excalidraw-preview-max-height 300
    "Max pixel height for inline Excalidraw previews. Width scales proportionally.")
  (defun my/excalidraw-preview (ov path _link)
    (when (display-graphic-p)
      (require 'image)
      (when (file-exists-p path)
        (let ((image (create-image path nil nil
                                   :max-height my/excalidraw-preview-max-height
                                   :ascent 'center)))
          (image-flush image)
          (overlay-put ov 'display image)
          (overlay-put ov 'face 'default)
          (overlay-put ov 'keymap image-map)
          t))))
  (org-link-set-parameters "excalidraw" :preview #'my/excalidraw-preview)
  ;; The upstream handler writes the SVG but never refreshes Org buffers,
  ;; so the inline preview stays stale until you toggle images manually.
  (defun my/org-excalidraw-refresh-after-export (event)
    (when (and (string-equal (cadr event) "renamed")
               (string-suffix-p ".excalidraw" (cadddr event)))
      (run-at-time
       0.1 nil
       (lambda ()
         (clear-image-cache (concat (cadddr event) ".svg"))
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (derived-mode-p 'org-mode)
               (org-link-preview nil (point-min) (point-max)))))))))
  (advice-add 'org-excalidraw--handle-file-change
              :after #'my/org-excalidraw-refresh-after-export))
;; The package shells `open <file>' on macOS, which uses the OS file
;; association. Set Excalidraw (installed as a Chrome PWA from
;; https://excalidraw.com) as the default app for .excalidraw files via
;; Finder → Get Info → Open With → Change All. The PWA's file_handlers
;; manifest auto-loads the file when launched.

(with-eval-after-load 'org
  (when (fboundp 'spacemacs/set-leader-keys-for-major-mode)
    (spacemacs/set-leader-keys-for-major-mode
      'org-mode
      "ix" #'org-excalidraw-create-drawing
      "id" #'my/org-excalidraw-describe-all
      ;; Toggle link previews (inline images) in current section.
      "Ti" #'org-link-preview
      "TI" #'my/org-toggle-buffer-link-previews)))

(defun my/org-toggle-buffer-link-previews ()
  "Toggle inline link previews for the whole buffer."
  (interactive)
  (if org-link-preview-overlays
      (org-link-preview-clear (point-min) (point-max))
    (org-link-preview nil (point-min) (point-max))))

;; ----- Auto-describe Excalidraw drawings via `claude -p' ----------------
;; `M-x my/org-excalidraw-describe-all' (or SPC m i d in org-mode) walks
;; every excalidraw: link in the buffer, asks Claude to describe each
;; drawing asynchronously, and inserts a `#+caption:' line above the
;; link. Links that already have a `#+caption:' immediately above are
;; skipped, so re-running the command only fills in new ones.

(defun my/org-excalidraw-describe-all ()
  "Asynchronously generate `#+caption:' descriptions for every excalidraw link."
  (interactive)
  (unless (executable-find "claude")
    (user-error "`claude' CLI not found on PATH"))
  (let ((buf (current-buffer))
        (started 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[excalidraw:\\([^]\n]+\\)\\]" nil t)
        (let ((path (match-string-no-properties 1))
              (line-start (line-beginning-position))
              (already-captioned
               (save-excursion
                 (forward-line -1)
                 (looking-at-p "^[ \t]*#\\+caption:"))))
          (unless already-captioned
            ;; Marker survives buffer edits from earlier sibling jobs.
            (my/org-excalidraw--describe-one buf path (copy-marker line-start))
            (cl-incf started)))))
    (message "Started %d Claude description job(s)" started)))

(defun my/org-excalidraw--describe-one (buf path line-marker)
  "Run `claude -p' on PATH; insert `#+caption:' at LINE-MARKER in BUF."
  (let* ((output (generate-new-buffer
                  (format " *claude-excalidraw-%s*" (file-name-base path))))
         (prompt (format
                  "Read the Excalidraw SVG at %s and write ONE concise sentence describing what the diagram depicts. Output only that sentence — no preamble, no quotes, no markdown."
                  path)))
    (make-process
     :name (format "claude-excalidraw-%s" (file-name-base path))
     :buffer output
     ;; `--add-dir' grants Claude read access to the SVG's directory.
     ;; `--output-format json' gives a clean parseable result with no TUI noise.
     :command (list "claude" "--add-dir" (file-name-directory path)
                    "--output-format" "json" "-p" prompt)
     :sentinel
     (lambda (proc event)
       (when (memq (process-status proc) '(exit signal))
         (let ((raw (with-current-buffer (process-buffer proc)
                      (buffer-string))))
           (kill-buffer (process-buffer proc))
           (cond
            ((not (zerop (process-exit-status proc)))
             (message "claude failed for %s: %s"
                      (file-name-nondirectory path) (string-trim raw)))
            ((not (buffer-live-p buf)) nil)
            (t
             (condition-case err
                 (let* ((json (with-temp-buffer
                                (insert raw)
                                (goto-char (point-min))
                                (json-parse-buffer :object-type 'alist)))
                        (desc (string-trim (or (alist-get 'result json) "")))
                        (sid (or (alist-get 'session_id json) "")))
                   (if (string-empty-p desc)
                       (message "claude returned empty for %s"
                                (file-name-nondirectory path))
                     (with-current-buffer buf
                       (save-excursion
                         (goto-char line-marker)
                         (insert (format "# claude-session: %s\n#+caption: %s\n"
                                         sid desc)))
                       (message "Described %s" (file-name-nondirectory path)))))
               (error
                (message "claude JSON parse failed for %s: %s"
                         (file-name-nondirectory path)
                         (error-message-string err))))))))))))

;; ----- Forge: SPC g h prefix for GitHub PR/issue browsing -----
;; Register unconditionally — forge commands are autoloaded, so invoking
;; one triggers forge to load. Gating on `with-eval-after-load 'forge'
;; would create a chicken-and-egg: the bindings would never appear until
;; forge was already loaded some other way.
(spacemacs/declare-prefix "gh" "github/forge")
(spacemacs/set-leader-keys
  "ghp" 'forge-list-pullreqs
  "ghi" 'forge-list-issues
  "ghf" 'forge-pull
  "ghv" 'forge-visit-pullreq
  "gha" 'forge-add-repository)

;; ----- which-key: pop up faster after any prefix key -----
;; Default Spacemacs delay is 0.4s. Dropping to 0.2s makes it feel like a
;; persistent cheat sheet. The secondary delay (for follow-up prefixes after
;; the first popup) is 0 so drilling into nested menus is instant.
(with-eval-after-load 'which-key
  (setq which-key-idle-delay 0.2
        which-key-idle-secondary-delay 0.0
        which-key-max-description-length 40
        which-key-show-early-on-C-h t))

;; ----- Persistent magit cheat sheet in a bottom side window -----
;; which-key only shows after you start a prefix. This panel is always
;; visible whenever any magit/forge buffer is on screen, so there's a
;; stable reference for the most common keys without triggering a menu.

(defconst my/magit-cheatsheet-buffer-name " *magit-cheatsheet*")

(defconst my/magit-cheatsheet-text
  "\
Navigate          Stage/Commit       Remote            Branches & Logs    Forge (PRs/Issues)
 n  p  next/prev    s  stage            F  pull menu       b  branch menu     @          forge menu
 M-n M-p sibling    u  unstage          P  push menu       l  log menu        SPC g h p  list PRs
 TAB  fold          S  stage all        f  fetch menu      L  refs log        SPC g h i  list issues
 1..4  level        U  unstage all      r  rebase menu     o  other menu      SPC g h f  forge-pull
 RET  visit         c  commit menu      m  merge menu      V  revert menu     (on PR) RET open
 g    refresh       k  discard          x  reset menu      z  stash menu      ,C  checkout PR
 ?    dispatch      e    diff menu      Y  cherry-pick     t  tag menu        ,s  set state
 q    quit/bury     w    apply patch    !    git shell     T  topic menu      ,r  review request")

(defun my/magit-cheatsheet--get-buffer ()
  (or (get-buffer my/magit-cheatsheet-buffer-name)
      (with-current-buffer (get-buffer-create my/magit-cheatsheet-buffer-name)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert my/magit-cheatsheet-text))
        (setq-local mode-line-format nil
                    cursor-type nil
                    buffer-read-only t
                    truncate-lines t)
        (current-buffer))))

(defun my/magit-cheatsheet--in-magit-p ()
  "Non-nil when the selected window's buffer is a magit/forge mode."
  (with-current-buffer (window-buffer (selected-window))
    (derived-mode-p 'magit-mode 'forge-topic-mode 'forge-post-mode)))

(defun my/magit-cheatsheet--sync (&rest _)
  "Show cheat sheet iff the currently-focused buffer is a magit/forge one."
  (let ((visible (get-buffer-window my/magit-cheatsheet-buffer-name))
        (wanted (my/magit-cheatsheet--in-magit-p)))
    (cond
     ((and wanted (not visible))
      (display-buffer-in-side-window
       (my/magit-cheatsheet--get-buffer)
       '((side . bottom)
         (slot . 1)
         (window-height . 11)
         (preserve-size . (nil . t))
         (no-other-window . t)
         (no-delete-other-windows . t))))
     ((and (not wanted) visible)
      (delete-window visible)))))

(add-hook 'window-configuration-change-hook #'my/magit-cheatsheet--sync)
(add-hook 'window-buffer-change-functions
          (lambda (_frame) (my/magit-cheatsheet--sync)))

(provide 'user-config)
;;; user-config.el ends here
