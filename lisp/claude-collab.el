;;; claude-collab.el --- Annotations + session-scoped undo for Claude edits -*- lexical-binding: t -*-
;;
;; Collaboration layer over `claude-code-ide' + `emacs-mcp-server':
;;
;;  - Session-scoped undo. Every Claude elisp call passes through
;;    `mcp-server-security-safe-eval'. An :around advice captures buffer
;;    edits via before-change hooks and logs them per session (keyed by
;;    cli-pid from `claude-code-ide-mcp-session' when available,
;;    `default-session' as fallback). Each edit gets an overlay with
;;    `claude-edit-face' so Claude's changes are visually distinct.
;;  - Annotations via `org-remark'. Local-only sidecar notes file.
;;  - MCP tools so Claude can list/resolve annotations and run the
;;    ERT test suite autonomously.
;;  - `SPC o c' keymap exposes undo-session / accept / toggle-overlays
;;    plus annotation navigation.

;;; Code:

(require 'cl-lib)

(cl-defstruct claude-collab-edit
  session-id buffer buffer-name begin end
  before-text after-text timestamp overlay
  kind annotation-data)

(defvar claude-collab--sessions (make-hash-table :test 'equal)
  "Hash table: session-id -> list of `claude-collab-edit' (newest first).")

(defvar claude-collab--active-session nil
  "Session ID bound during an advised MCP eval; nil outside.")

(defvar claude-collab-show-overlays t
  "When non-nil, Claude-edit overlays render with `claude-edit-face'.")

(defvar claude-collab-max-sessions 50
  "Maximum number of sessions to retain. Oldest sessions are evicted
past this limit to bound memory growth over long Emacs sessions.")

(defface claude-edit-face
  '((((background light)) :background "#fff3b8" :extend nil)
    (((background dark))  :background "#3a3520" :extend nil))
  "Face for regions edited by Claude via MCP.")

(define-error 'claude-collab-conflict "Claude edit conflict")


;;; Session ID resolution

(defun claude-collab--current-session-id ()
  "Resolve the active session ID; prefer claude-code-ide cli-pid."
  (or claude-collab--active-session
      (ignore-errors
        (when (and (boundp 'claude-code-ide-mcp--sessions)
                   (hash-table-p claude-code-ide-mcp--sessions)
                   (fboundp 'claude-code-ide-mcp-session-p))
          (when-let* ((session (cl-find-if
                                (lambda (s)
                                  (and (claude-code-ide-mcp-session-p s)
                                       (claude-code-ide-mcp-session-cli-pid s)))
                                (hash-table-values
                                 claude-code-ide-mcp--sessions))))
            (claude-code-ide-mcp-session-cli-pid session))))
      'default-session))

(defun claude-collab--buffer-trackable-p (buf)
  "Non-nil if BUF is a real buffer we should track edits in.
Excludes hidden buffers and `org-remark's marginalia notes file —
those are an implementation detail of the annotation layer, not
user-visible prose Claude would edit deliberately."
  (and (buffer-live-p buf)
       (let ((name (buffer-name buf)))
         (and (not (string-prefix-p " " name))
              (not (string-match-p "marginalia\\.org" name))))))

(defun claude-collab--common-prefix-length (a b)
  "Length of the common leading substring of strings A and B."
  (let ((i 0) (cap (min (length a) (length b))))
    (while (and (< i cap) (eq (aref a i) (aref b i)))
      (cl-incf i))
    i))

(defun claude-collab--common-suffix-length (a b)
  "Length of the common trailing substring of strings A and B."
  (let ((i 0) (la (length a)) (lb (length b))
        (cap (min (length a) (length b))))
    (while (and (< i cap)
                (eq (aref a (- la 1 i))
                    (aref b (- lb 1 i))))
      (cl-incf i))
    i))

(defun claude-collab--file-buffers ()
  "Live, file-backed buffers — the universe we track annotations in."
  (cl-remove-if-not (lambda (b)
                      (and (buffer-live-p b) (buffer-file-name b)))
                    (buffer-list)))


;;; Edit logging + MCP advice

(defun claude-collab--log-edit (buf beg end before-text &optional kind annotation-data)
  "Create and store an edit record, installing an overlay. Return the record."
  (with-current-buffer buf
    (let* ((session-id (claude-collab--current-session-id))
           (annotation-kind (eq kind 'annotation-resolve))
           (after-text (if annotation-kind "" (buffer-substring-no-properties beg end)))
           (ov (unless annotation-kind (make-overlay beg end buf nil t)))
           (rec (make-claude-collab-edit
                 :session-id session-id
                 :buffer buf
                 :buffer-name (buffer-name buf)
                 :begin (if (markerp beg) beg (copy-marker beg nil))
                 :end (if (markerp end) end (copy-marker end t))
                 :before-text before-text
                 :after-text after-text
                 :timestamp (float-time)
                 :overlay ov
                 :kind (or kind 'text)
                 :annotation-data annotation-data)))
      (when ov
        (overlay-put ov 'face (and claude-collab-show-overlays 'claude-edit-face))
        (overlay-put ov 'claude-collab-edit rec)
        (overlay-put ov 'priority 100)
        (with-current-buffer buf
          (unless (bound-and-true-p claude-collab-diff-popup-mode)
            (claude-collab-diff-popup-mode 1))))
      (push rec (gethash session-id claude-collab--sessions))
      (claude-collab--evict-oldest-if-needed)
      rec)))

(defun claude-collab--evict-oldest-if-needed ()
  "Enforce `claude-collab-max-sessions' by evicting the oldest session.
Deletes the evicted session's overlays as well so buffers don't
accumulate reachable state across long Emacs runs."
  (when (> (hash-table-count claude-collab--sessions)
           claude-collab-max-sessions)
    (let ((oldest-id nil)
          (oldest-ts most-positive-fixnum))
      (maphash
       (lambda (sid edits)
         (when-let* ((tail (last edits))
                     (ts (claude-collab-edit-timestamp (car tail))))
           (when (< ts oldest-ts)
             (setq oldest-id sid oldest-ts ts))))
       claude-collab--sessions)
      (when oldest-id
        (dolist (e (gethash oldest-id claude-collab--sessions))
          (let ((ov (claude-collab-edit-overlay e)))
            (when (overlayp ov) (delete-overlay ov))))
        (remhash oldest-id claude-collab--sessions)))))

(defun claude-collab--record-advice (orig-fn form)
  "Around-advice for `mcp-server-security-safe-eval': log buffer edits.
Produces ONE edit record per buffer touched, spanning the union of
changes. Diff-based (snapshot before first change, diff after eval)
instead of per-change recording, so a `replace-match' or similar
doesn't fragment into dozens of character-level overlays."
  (let* ((session-id (claude-collab--current-session-id))
         (snapshots (make-hash-table :test 'eq))
         (before-hook
          (lambda (_beg _end)
            (let ((buf (current-buffer)))
              (when (and (claude-collab--buffer-trackable-p buf)
                         (not (gethash buf snapshots)))
                (puthash buf
                         (buffer-substring-no-properties (point-min) (point-max))
                         snapshots)))))
         (result nil))
    (let ((claude-collab--active-session session-id))
      (unwind-protect
          (progn
            (add-hook 'before-change-functions before-hook)
            (setq result (funcall orig-fn form)))
        (remove-hook 'before-change-functions before-hook)))
    (maphash
     (lambda (buf before)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((after (buffer-substring-no-properties (point-min) (point-max))))
             (unless (string= before after)
               (let* ((pre (claude-collab--common-prefix-length before after))
                      (suf (claude-collab--common-suffix-length
                            (substring before pre)
                            (substring after pre)))
                      (before-diff (substring before pre
                                              (max pre (- (length before) suf))))
                      (after-diff (substring after pre
                                             (max pre (- (length after) suf))))
                      (beg (1+ pre))
                      (end (+ beg (length after-diff))))
                 (claude-collab--log-edit buf beg end before-diff 'text)))))))
     snapshots)
    result))

(with-eval-after-load 'mcp-server-security
  (advice-add 'mcp-server-security-safe-eval
              :around #'claude-collab--record-advice))


;;; Inspection / session queries

(defun claude-collab-list-sessions ()
  "Return alist of (session-id . edit-count)."
  (let (result)
    (maphash (lambda (sid edits) (push (cons sid (length edits)) result))
             claude-collab--sessions)
    result))

(defun claude-collab-session-edits (session-id)
  "Return list of edits for SESSION-ID."
  (gethash session-id claude-collab--sessions))

(defun claude-collab-overlays-in (buf)
  "List Claude-edit overlays in BUF."
  (with-current-buffer buf
    (cl-loop for ov in (overlays-in (point-min) (point-max))
             when (overlay-get ov 'claude-collab-edit)
             collect ov)))

(defun claude-collab--latest-session-id ()
  "Return the session ID of the most recently-modified session."
  (let ((best nil) (best-time 0))
    (maphash
     (lambda (sid edits)
       (when edits
         (let ((ts (claude-collab-edit-timestamp (car edits))))
           (when (> ts best-time)
             (setq best sid best-time ts)))))
     claude-collab--sessions)
    best))

(defun claude-collab--all-session-ids ()
  "Return list of non-empty session IDs."
  (cl-remove-if (lambda (id) (null (gethash id claude-collab--sessions)))
                (hash-table-keys claude-collab--sessions)))


;;; Revert / accept

(defun claude-collab--revert-edit (edit)
  "Revert EDIT. Signal `claude-collab-conflict' if region changed."
  (let ((buf (claude-collab-edit-buffer edit))
        (beg (claude-collab-edit-begin edit))
        (end (claude-collab-edit-end edit))
        (before (claude-collab-edit-before-text edit))
        (after (claude-collab-edit-after-text edit))
        (ov (claude-collab-edit-overlay edit))
        (kind (claude-collab-edit-kind edit)))
    (cond
     ((eq kind 'annotation-resolve)
      (claude-collab--unresolve-annotation edit))
     (t
      (unless (buffer-live-p buf)
        (signal 'claude-collab-conflict
                (list (format "buffer %s killed"
                              (claude-collab-edit-buffer-name edit)))))
      (with-current-buffer buf
        (let ((current (buffer-substring-no-properties beg end)))
          (unless (string= current after)
            (signal 'claude-collab-conflict
                    (list (format "region at %s:%d modified since edit"
                                  (buffer-name buf) (marker-position beg)))))
          (let ((inhibit-modification-hooks t))
            (delete-region beg end)
            (goto-char beg)
            (insert before))))))
    (when (overlayp ov) (delete-overlay ov))))

(defun claude-collab--revert-session (session-id)
  "Revert every edit in SESSION-ID, LIFO. Abort on conflict."
  (let ((edits (gethash session-id claude-collab--sessions))
        (reverted 0)
        (conflict nil))
    (cl-block revert
      (dolist (e edits)
        (condition-case err
            (progn (claude-collab--revert-edit e) (cl-incf reverted))
          (claude-collab-conflict
           (setq conflict (cons e err))
           (cl-return-from revert nil)))))
    (cond
     (conflict
      (message "Aborted: conflict at edit %d of %d in session %s"
               (1+ reverted) (length edits) session-id)
      (claude-collab--offer-ediff (car conflict)))
     (t
      (remhash session-id claude-collab--sessions)
      (message "Reverted %d edit(s) from session %s" reverted session-id)))
    (list :reverted reverted :conflict (and conflict t) :total (length edits))))

(defun claude-collab--offer-ediff (edit)
  "Open `ediff-buffers' between Claude's version and current buffer state."
  (let ((buf (claude-collab-edit-buffer edit)))
    (when (buffer-live-p buf)
      (let ((claude-buf (get-buffer-create "*claude-edit: claude's version*"))
            (live-buf  (get-buffer-create "*claude-edit: current state*")))
        (with-current-buffer claude-buf
          (erase-buffer) (insert (claude-collab-edit-after-text edit)))
        (with-current-buffer live-buf
          (erase-buffer)
          (insert (with-current-buffer buf
                    (buffer-substring-no-properties
                     (claude-collab-edit-begin edit)
                     (claude-collab-edit-end edit)))))
        (ediff-buffers claude-buf live-buf)))))

(defun claude-collab-undo-session ()
  "Revert every edit in the most recent Claude session."
  (interactive)
  (let ((sid (claude-collab--latest-session-id)))
    (unless sid (user-error "No Claude sessions to undo"))
    (claude-collab--revert-session sid)))

(defun claude-collab-undo-edit ()
  "Revert the single most-recent Claude edit."
  (interactive)
  (let* ((sid (claude-collab--latest-session-id))
         (edits (and sid (gethash sid claude-collab--sessions))))
    (unless edits (user-error "No Claude edits to undo"))
    (condition-case err
        (progn
          (claude-collab--revert-edit (car edits))
          (if (cdr edits)
              (puthash sid (cdr edits) claude-collab--sessions)
            (remhash sid claude-collab--sessions))
          (message "Reverted last Claude edit"))
      (claude-collab-conflict
       (claude-collab--offer-ediff (car edits))
       (message "Aborted: %s" (cadr err))))))

(defun claude-collab-pick-session ()
  "Pick a session to revert via completing-read."
  (interactive)
  (let* ((pairs (mapcar (lambda (id)
                          (cons (format "%s (%d edits)" id
                                        (length (gethash id claude-collab--sessions)))
                                id))
                        (claude-collab--all-session-ids)))
         (choice (completing-read "Revert session: " pairs nil t)))
    (when choice
      (claude-collab--revert-session (cdr (assoc choice pairs))))))

(defun claude-collab-accept-session ()
  "Accept the most recent session: drop log entries, clear overlays."
  (interactive)
  (let ((sid (claude-collab--latest-session-id)))
    (unless sid (user-error "No Claude sessions to accept"))
    (dolist (e (gethash sid claude-collab--sessions))
      (let ((ov (claude-collab-edit-overlay e)))
        (when (overlayp ov) (delete-overlay ov))))
    (remhash sid claude-collab--sessions)
    (message "Accepted session %s" sid)))

(defun claude-collab-toggle-overlays ()
  "Toggle visibility of Claude-edit overlays."
  (interactive)
  (setq claude-collab-show-overlays (not claude-collab-show-overlays))
  (maphash
   (lambda (_sid edits)
     (dolist (e edits)
       (let ((ov (claude-collab-edit-overlay e)))
         (when (overlayp ov)
           (overlay-put ov 'face
                        (and claude-collab-show-overlays 'claude-edit-face))))))
   claude-collab--sessions)
  (message "Claude overlays %s" (if claude-collab-show-overlays "on" "off")))


;;; Annotations via org-remark

;; Eager-load org-remark so `org-remark-global-tracking-mode' is on before
;; the user opens their first annotated file. A lazy `with-eval-after-load'
;; meant that after an Emacs restart, opening an annotated .org file
;; rendered no highlights until org-remark was incidentally required.
(when (require 'org-remark nil t)
  (org-remark-global-tracking-mode 1))

(defun claude-collab--annotation-overlay-p (ov)
  "Non-nil if OV is an org-remark annotation overlay."
  (or (overlay-get ov 'org-remark-id)
      (eq (overlay-get ov 'category) 'org-remark-highlighter)))

(defun claude-collab--annotations-in-buffer (buf)
  "Return list of annotation plists in BUF.
Reads via `org-remark-highlights-get' from the notes buffer so the
label round-trips across save/reload — overlay props don't."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and (buffer-file-name)
                 (fboundp 'org-remark-highlights-get)
                 (fboundp 'org-remark-notes-get-file-name))
        (let* ((notes-file (org-remark-notes-get-file-name))
               (notes-buf (and notes-file
                               (file-exists-p notes-file)
                               (find-file-noselect notes-file))))
          (when notes-buf
            (mapcar (lambda (h)
                      (let ((loc (plist-get h :location)))
                        (list :id (plist-get h :id)
                              :file (buffer-file-name)
                              :begin (car loc)
                              :end (cdr loc)
                              :text (plist-get (plist-get h :props) :original-text)
                              :label (plist-get h :label))))
                    (org-remark-highlights-get notes-buf))))))))

(defun claude-collab-pending-annotations (file)
  "Return pending annotations for FILE as a list of plists."
  (when (and file (file-exists-p file))
    (claude-collab--annotations-in-buffer (find-file-noselect file))))

(defun claude-collab--all-annotations ()
  "Return all pending annotations across tracked buffers."
  (cl-mapcan #'claude-collab--annotations-in-buffer (claude-collab--file-buffers)))

(defun claude-collab--find-annotation (id)
  "Return (buf . overlay) for annotation ID, or nil."
  (cl-some
   (lambda (buf)
     (when-let* ((ov (cl-find-if
                       (lambda (o)
                         (and (claude-collab--annotation-overlay-p o)
                              (equal (overlay-get o 'org-remark-id) id)))
                       (with-current-buffer buf
                         (overlays-in (point-min) (point-max))))))
       (cons buf ov)))
   (claude-collab--file-buffers)))

(defun claude-collab-resolve-annotation-by-id (id)
  "Remove annotation ID and log a session-scoped record for undo-coupling."
  (let ((found (claude-collab--find-annotation id)))
    (unless found (error "Annotation %s not found" id))
    (let* ((buf (car found))
           (ov (cdr found))
           (beg (overlay-start ov))
           (end (overlay-end ov))
           (label (overlay-get ov 'org-remark-label))
           (file (buffer-file-name buf))
           (data (list :id id :file file :begin beg :end end :label label
                       :text (with-current-buffer buf
                               (buffer-substring-no-properties beg end)))))
      (claude-collab--log-edit buf beg end "" 'annotation-resolve data)
      (with-current-buffer buf
        (save-excursion
          (goto-char beg)
          (if (fboundp 'org-remark-delete)
              (ignore-errors (org-remark-delete beg))
            (delete-overlay ov))))
      data)))

(defun claude-collab--unresolve-annotation (edit)
  "Re-apply an annotation that was resolved as part of an undone session."
  (let* ((data (claude-collab-edit-annotation-data edit))
         (file (plist-get data :file))
         (beg (plist-get data :begin))
         (end (plist-get data :end))
         (label (plist-get data :label)))
    (when (and file (file-exists-p file))
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (when (fboundp 'org-remark-highlight-mark)
            (org-remark-highlight-mark beg end nil nil label)))))))


;;; MCP tool registrations

(defun claude-collab--mcp-list-annotations (args)
  "MCP handler: list pending annotations. ARGS may contain :file."
  (let* ((file (alist-get 'file args))
         (anns (if file
                   (claude-collab-pending-annotations (expand-file-name file))
                 (claude-collab--all-annotations))))
    (format "%S" anns)))

(defun claude-collab--mcp-resolve-annotation (args)
  "MCP handler: resolve annotation by ID. ARGS must contain :id."
  (let ((id (alist-get 'id args)))
    (unless id (error "Missing required arg: id"))
    (let ((data (claude-collab-resolve-annotation-by-id id)))
      (format "Resolved annotation %s: %S" id data))))

(defun claude-collab--mcp-run-tests (_args)
  "MCP handler: run the ERT suite; return pass/fail plist."
  (let ((test-file (expand-file-name "~/.spacemacs.d/lisp/claude-collab-test.el")))
    (when (file-exists-p test-file)
      (load-file test-file)))
  (if (not (fboundp 'claude-collab-run-tests))
      "ERROR: claude-collab-test not loaded (file missing?)"
    (format "%S" (claude-collab-run-tests))))

(with-eval-after-load 'mcp-server-tools
  (when (fboundp 'mcp-server-register-tool)
    (mcp-server-register-tool
     (make-mcp-server-tool
      :name "claude-collab-list-annotations"
      :title "List Pending Annotations"
      :description "List pending org-remark annotations in current project. Optional :file arg limits scan to one file."
      :input-schema '((type . "object")
                      (properties . ((file . ((type . "string")
                                               (description . "Optional file path.")))))
                      (required . []))
      :function #'claude-collab--mcp-list-annotations))
    (mcp-server-register-tool
     (make-mcp-server-tool
      :name "claude-collab-resolve-annotation"
      :title "Resolve Annotation"
      :description "Resolve an annotation by ID. Logged in current session so undo re-opens."
      :input-schema '((type . "object")
                      (properties . ((id . ((type . "string")
                                             (description . "Annotation ID")))))
                      (required . ("id")))
      :function #'claude-collab--mcp-resolve-annotation))
    (mcp-server-register-tool
     (make-mcp-server-tool
      :name "claude-collab-run-tests"
      :title "Run claude-collab Test Suite"
      :description "Run ERT tests for claude-collab. Returns plist (:passed N :failed N :failures ...)."
      :input-schema '((type . "object"))
      :function #'claude-collab--mcp-run-tests))))

;; Trigger mcp-server-tools load so the registrations fire at startup.
(require 'mcp-server-tools nil t)


;;; Annotation popup at point

(defface claude-collab-popup-face
  '((t :inherit tooltip :height 160))
  "Face for the annotation popup content — slightly larger than body text.")

(defconst claude-collab--popup-buffer " *claude-collab-annotation*")

(defvar-local claude-collab--popup-current-id nil
  "ID of the annotation whose popup is currently displayed in this buffer.")

(defun claude-collab--annotation-id-at-point ()
  "Return the `org-remark-id' of the annotation overlay at point, or nil."
  (cl-some (lambda (ov)
             (and (claude-collab--annotation-overlay-p ov)
                  (overlay-get ov 'org-remark-id)))
           (overlays-at (point))))

(defun claude-collab--annotation-label-for-id (id)
  "Look up the label for annotation ID in the current buffer."
  (when id
    (plist-get
     (cl-find id (claude-collab--annotations-in-buffer (current-buffer))
              :key (lambda (a) (plist-get a :id))
              :test #'string=)
     :label)))

(defun claude-collab--update-annotation-popup ()
  "Post-command hook: show popup while point is on an annotation, hide otherwise."
  (condition-case nil
      (let ((id (claude-collab--annotation-id-at-point)))
        (cond
         ((null id)
          (when claude-collab--popup-current-id
            (when (and (require 'posframe nil t) (fboundp 'posframe-hide))
              (posframe-hide claude-collab--popup-buffer))
            (setq claude-collab--popup-current-id nil)))
         ((equal id claude-collab--popup-current-id)
          nil)
         (t
          (when-let ((label (claude-collab--annotation-label-for-id id)))
            (when (and (require 'posframe nil t) (posframe-workable-p))
              (posframe-show
               claude-collab--popup-buffer
               :string (propertize (format " 💬 %s " label) 'face 'claude-collab-popup-face)
               :position (point)
               :background-color (face-background 'tooltip nil t)
               :foreground-color (face-foreground 'tooltip nil t)
               :internal-border-width 1
               :internal-border-color (face-foreground 'shadow nil t)
               :accept-focus nil
               :max-width 70)
              (setq claude-collab--popup-current-id id))))))
    (error nil)))

(define-minor-mode claude-collab-annotation-popup-mode
  "Show a posframe popup with annotation text while point rests on a highlight."
  :lighter " cc-pop"
  (if claude-collab-annotation-popup-mode
      (add-hook 'post-command-hook
                #'claude-collab--update-annotation-popup nil t)
    (remove-hook 'post-command-hook
                 #'claude-collab--update-annotation-popup t)
    (when (and (require 'posframe nil t) (fboundp 'posframe-hide))
      (posframe-hide claude-collab--popup-buffer))
    (setq claude-collab--popup-current-id nil)))

(add-hook 'org-remark-mode-hook #'claude-collab-annotation-popup-mode)


;;; Diff popup at Claude-edit overlay
;;
;; Small edits → posframe card with real unified-diff hunks (diff -u).
;; Big edits   → bottom side-window in `diff-mode', same data in a
;;               scrollable, copy-pasteable buffer. Threshold governed
;;               by `claude-collab-diff-popup-escalate-threshold'.
;; Posframe wraps long lines via buffer-local `word-wrap'.

(defface claude-collab-diff-header-face
  '((t :inherit tooltip :weight bold))
  "Face for the diff-card header line.")

(defconst claude-collab--diff-popup-buffer " *claude-collab-diff*")
(defconst claude-collab--diff-panel-buffer "*claude-collab: diff*")

(defcustom claude-collab-diff-popup-max-lines 14
  "Cap on total diff lines in the posframe card; excess is elided."
  :type 'integer)

(defcustom claude-collab-diff-popup-escalate-threshold 8
  "If either side of the diff exceeds this many lines, skip the posframe
card and open a `diff-mode' side-window instead."
  :type 'integer)

(defvar-local claude-collab--diff-popup-current-edit nil
  "The `claude-collab-edit' whose diff display is currently shown, or nil.")

(defun claude-collab--edit-at-point ()
  "Return the `claude-collab-edit' struct for the overlay at point, else nil."
  (cl-some (lambda (ov) (overlay-get ov 'claude-collab-edit))
           (overlays-at (point))))

(defun claude-collab--edit-position-in-session (edit)
  "Return (INDEX . TOTAL) for EDIT within its session, 1-indexed chronological."
  (let* ((sid (claude-collab-edit-session-id edit))
         (chronological (reverse (gethash sid claude-collab--sessions)))
         (total (length chronological))
         (idx (1+ (or (cl-position edit chronological :test #'eq) 0))))
    (cons idx total)))

(defun claude-collab--diff-summary (edit)
  "One-line summary describing the scale of EDIT."
  (cond
   ((eq (claude-collab-edit-kind edit) 'annotation-resolve)
    "resolved annotation")
   (t
    (let* ((before (or (claude-collab-edit-before-text edit) ""))
           (after  (or (claude-collab-edit-after-text edit) ""))
           (bl (length (split-string before "\n")))
           (al (length (split-string after "\n"))))
      (format "−%d  +%d lines" bl al)))))

(defun claude-collab--edit-is-big-p (edit)
  "Non-nil when EDIT's diff should escalate to the side-window."
  (let* ((before (or (claude-collab-edit-before-text edit) ""))
         (after  (or (claude-collab-edit-after-text edit) ""))
         (bl (length (split-string before "\n")))
         (al (length (split-string after "\n"))))
    (> (max bl al) claude-collab-diff-popup-escalate-threshold)))

(defun claude-collab--compute-unified-diff (before after)
  "Return `diff -u' output between BEFORE and AFTER, header lines stripped.
On diff failure or exit 2+, falls back to a naive two-section dump."
  (let* ((file-a (make-temp-file "cc-before-"))
         (file-b (make-temp-file "cc-after-"))
         (coding-system-for-write 'utf-8)
         (coding-system-for-read  'utf-8))
    (unwind-protect
        (progn
          (write-region (or before "") nil file-a nil 'silent)
          (write-region (or after  "") nil file-b nil 'silent)
          (with-temp-buffer
            (let ((exit (call-process (or (bound-and-true-p diff-command) "diff")
                                      nil t nil
                                      "-u" file-a file-b)))
              (cond
               ((memq exit '(0 1))
                (goto-char (point-min))
                (if (re-search-forward "^@@" nil t)
                    (progn (beginning-of-line)
                           (buffer-substring (point) (point-max)))
                  ""))
               (t
                (format "(diff exit %d)\n- %s\n+ %s" exit
                        (or before "") (or after "")))))))
      (ignore-errors (delete-file file-a))
      (ignore-errors (delete-file file-b)))))

(defface claude-collab-track-removed-face
  '((((background light))
     :foreground "#b4232c" :strike-through t :background "#fde8ea")
    (((background dark))
     :foreground "#ff8a8a" :strike-through t :background "#3a1a1f"))
  "Face for deleted text in the track-changes diff view (Google-Docs style).")

(defface claude-collab-track-added-face
  '((((background light))
     :foreground "#116329" :underline t :background "#e6f4ea" :weight bold)
    (((background dark))
     :foreground "#7ee787" :underline t :background "#1a2b1d" :weight bold))
  "Face for inserted text in the track-changes diff view (Google-Docs style).")

(defun claude-collab--compute-word-diff (before after)
  "Return `git diff --no-index --word-diff=plain' body between BEFORE and AFTER.
Git's word-diff wraps removed spans as [-…-] and added spans as {+…+} inline,
which is what we want for a Google-Docs track-changes-style render."
  (let* ((file-a (make-temp-file "cc-word-before-"))
         (file-b (make-temp-file "cc-word-after-"))
         (coding-system-for-write 'utf-8)
         (coding-system-for-read  'utf-8))
    (unwind-protect
        (progn
          (write-region (or before "") nil file-a nil 'silent)
          (write-region (or after  "") nil file-b nil 'silent)
          (with-temp-buffer
            ;; --unified=9999 forces the whole file into one hunk so the
            ;; surrounding context isn't elided — we want the full fused text.
            (call-process "git" nil t nil
                          "diff" "--no-index" "--no-color"
                          "--word-diff=plain"
                          "--unified=9999"
                          file-a file-b)
            (goto-char (point-min))
            (if (re-search-forward "^@@.*@@\n" nil t)
                (buffer-substring (point) (point-max))
              "")))
      (ignore-errors (delete-file file-a))
      (ignore-errors (delete-file file-b)))))

(defun claude-collab--fontify-word-diff (diff-str)
  "Turn [-x-] / {+x+} markers in DIFF-STR into faced spans, strip leading +/-."
  (with-temp-buffer
    (insert diff-str)
    ;; Strip the leading " "/"+"/"-" column git diff prefixes onto every line.
    ;; With word-diff, these are redundant with the inline markers and just
    ;; add noise to prose.
    (goto-char (point-min))
    (while (not (eobp))
      (when (looking-at "^[ +-]")
        (delete-char 1))
      (forward-line 1))
    ;; [- removed -]  →  strikethrough red
    (goto-char (point-min))
    (while (re-search-forward "\\[-\\(\\(?:.\\|\n\\)*?\\)-\\]" nil t)
      (let ((removed (match-string 1)))
        (replace-match
         (propertize removed 'face 'claude-collab-track-removed-face)
         t t)))
    ;; {+ added +}  →  underline green
    (goto-char (point-min))
    (while (re-search-forward "{\\+\\(\\(?:.\\|\n\\)*?\\)\\+}" nil t)
      (let ((added (match-string 1)))
        (replace-match
         (propertize added 'face 'claude-collab-track-added-face)
         t t)))
    (buffer-string)))

(defun claude-collab--colorize-unified-diff (diff-str)
  "Apply diff-mode faces per line to DIFF-STR."
  (mapconcat
   (lambda (line)
     (cond
      ((string-prefix-p "@@" line)
       (propertize line 'face 'diff-hunk-header))
      ((string-prefix-p "+" line)
       (propertize line 'face 'diff-added))
      ((string-prefix-p "-" line)
       (propertize line 'face 'diff-removed))
      (t (propertize line 'face 'diff-context))))
   (split-string diff-str "\n")
   "\n"))

(defun claude-collab--elide-diff-lines (str max-lines)
  "Cap STR to MAX-LINES, eliding the middle with a `… N more …' marker."
  (let ((lines (split-string str "\n" t)))
    (if (<= (length lines) max-lines)
        str
      (let* ((keep (/ max-lines 2))
             (head (cl-subseq lines 0 keep))
             (tail (cl-subseq lines (- (length lines) keep)))
             (dropped (- (length lines) (* 2 keep))))
        (concat (mapconcat #'identity head "\n")
                "\n"
                (propertize (format "  … %d more lines …" dropped)
                            'face 'shadow)
                "\n"
                (mapconcat #'identity tail "\n")
                "\n")))))

(defun claude-collab--format-diff-card (edit)
  "Build the propertized string shown in the diff posframe for EDIT.
Same track-changes rendering as the side-window panel: strikethrough for
deletions, underline for insertions, fused over the surrounding context."
  (let* ((pos (claude-collab--edit-position-in-session edit))
         (header (propertize
                  (format " Claude edit · %d/%d · %s \n"
                          (car pos) (cdr pos)
                          (claude-collab--diff-summary edit))
                  'face 'claude-collab-diff-header-face))
         (wd (claude-collab--compute-word-diff
              (claude-collab-edit-before-text edit)
              (claude-collab-edit-after-text edit)))
         (body (if (string-empty-p wd)
                   "(no differences)"
                 (claude-collab--fontify-word-diff wd))))
    (concat header body)))

(defun claude-collab--popup-buffer-setup ()
  "Configure posframe buffer for word wrap; safe to call repeatedly."
  (when-let ((buf (get-buffer claude-collab--diff-popup-buffer)))
    (with-current-buffer buf
      (setq-local word-wrap t
                  truncate-lines nil))))

(defun claude-collab--show-diff-card (edit)
  "Show posframe diff card for EDIT."
  (when (and (require 'posframe nil t) (posframe-workable-p))
    (posframe-show
     claude-collab--diff-popup-buffer
     :string (claude-collab--format-diff-card edit)
     :position (marker-position (claude-collab-edit-end edit))
     :poshandler #'posframe-poshandler-point-bottom-left-corner
     :background-color (face-background 'tooltip nil t)
     :internal-border-width 1
     :internal-border-color (face-foreground 'shadow nil t)
     :accept-focus nil
     :max-width 100)
    (claude-collab--popup-buffer-setup)))

(defun claude-collab--hide-diff-card ()
  "Hide the posframe card if currently shown."
  (when (and (require 'posframe nil t) (fboundp 'posframe-hide))
    (posframe-hide claude-collab--diff-popup-buffer)))

(defun claude-collab--show-diff-panel (edit)
  "Open or update the side-window panel with a track-changes view of EDIT.
Deletions show as red strikethrough, insertions as green underline, all
fused inline over the surrounding context — Google-Docs-suggesting style."
  (let* ((buf (get-buffer-create claude-collab--diff-panel-buffer))
         (pos (claude-collab--edit-position-in-session edit))
         (source-name (claude-collab-edit-buffer-name edit))
         (word-diff (claude-collab--compute-word-diff
                     (claude-collab-edit-before-text edit)
                     (claude-collab-edit-after-text edit)))
         (body (if (string-empty-p word-diff)
                   "(no differences)"
                 (claude-collab--fontify-word-diff word-diff))))
    (with-current-buffer buf
      ;; Drop any lingering diff-mode / read-only state from older renders.
      (when (derived-mode-p 'diff-mode) (fundamental-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format " Claude edit %d/%d  ·  %s  ·  %s \n"
                         (car pos) (cdr pos) source-name
                         (claude-collab--diff-summary edit))
                 'face 'claude-collab-diff-header-face))
        (insert (propertize
                 (concat "  "
                         (propertize "removed" 'face 'claude-collab-track-removed-face)
                         "   "
                         (propertize "added" 'face 'claude-collab-track-added-face)
                         "\n\n")
                 'face 'shadow))
        (insert body))
      (goto-char (point-min))
      (setq-local truncate-lines nil
                  word-wrap t)
      (visual-line-mode 1)
      (setq-local buffer-read-only t))
    (display-buffer
     buf
     '((display-buffer-in-side-window)
       (side . bottom)
       (window-height . 0.35)
       (dedicated . t)))))

(defun claude-collab--hide-diff-panel ()
  "Close the side-window panel if present."
  (when-let ((buf (get-buffer claude-collab--diff-panel-buffer)))
    (dolist (win (get-buffer-window-list buf nil t))
      (when (window-live-p win)
        (ignore-errors (delete-window win))))))

(defun claude-collab-show-edit-diff-full ()
  "Explicitly open the side-window diff panel for the edit at point.
Handy when you want the full view of a small edit that would normally
only render as a posframe card."
  (interactive)
  (let ((edit (claude-collab--edit-at-point)))
    (unless edit (user-error "No Claude edit at point"))
    (claude-collab--hide-diff-card)
    (claude-collab--show-diff-panel edit)
    (setq claude-collab--diff-popup-current-edit edit)))

(defun claude-collab--update-diff-popup ()
  "Post-command hook: card for small edits, side-window for big ones."
  (condition-case nil
      (let ((edit (and claude-collab-show-overlays
                       (claude-collab--edit-at-point))))
        (cond
         ((null edit)
          (when claude-collab--diff-popup-current-edit
            (claude-collab--hide-diff-card)
            (claude-collab--hide-diff-panel)
            (setq claude-collab--diff-popup-current-edit nil)))
         ((eq edit claude-collab--diff-popup-current-edit)
          nil)
         ((claude-collab--edit-is-big-p edit)
          (claude-collab--hide-diff-card)
          (claude-collab--show-diff-panel edit)
          (setq claude-collab--diff-popup-current-edit edit))
         (t
          (claude-collab--hide-diff-panel)
          (claude-collab--show-diff-card edit)
          (setq claude-collab--diff-popup-current-edit edit))))
    (error nil)))

(define-minor-mode claude-collab-diff-popup-mode
  "Show a posframe / side-window with the diff of the Claude edit at point."
  :lighter " cc-diff"
  (if claude-collab-diff-popup-mode
      (add-hook 'post-command-hook #'claude-collab--update-diff-popup nil t)
    (remove-hook 'post-command-hook #'claude-collab--update-diff-popup t)
    (claude-collab--hide-diff-card)
    (claude-collab--hide-diff-panel)
    (setq claude-collab--diff-popup-current-edit nil)))


;;; Auto-render diagram src blocks on idle

(defcustom claude-collab-auto-render-diagrams-languages
  '("plantuml" "dot" "ditaa" "mermaid")
  "Babel languages whose `:file' src blocks get auto-rendered."
  :type '(repeat string))

(defcustom claude-collab-auto-render-idle-delay 1.5
  "Seconds of idle time before re-rendering changed diagram blocks."
  :type 'number)

(defvar-local claude-collab--auto-render-timer nil)
(defvar-local claude-collab--auto-render-hashes nil
  "Alist `((BEG . HASH) …)' of blocks already rendered for their current body.")
(defvar claude-collab--auto-render-running nil
  "Non-nil while a render pass is in progress; suppresses re-scheduling.")

(defun claude-collab--auto-render-now (&optional target-buffer)
  "Execute every whitelisted diagram block whose body changed since last render.
Optional TARGET-BUFFER defaults to the current buffer."
  (let ((buf (or target-buffer (current-buffer))))
    (when (and (buffer-live-p buf)
               (not claude-collab--auto-render-running))
      (with-current-buffer buf
        (when (derived-mode-p 'org-mode)
          (let ((claude-collab--auto-render-running t)
                (org-confirm-babel-evaluate nil)
                (any-rendered nil))
            (save-excursion
              (org-babel-map-src-blocks nil
                (when (member lang claude-collab-auto-render-diagrams-languages)
                  (let* ((params (nth 2 (org-babel-get-src-block-info 'light)))
                         (target (cdr (assq :file params)))
                         (current-hash (and target (md5 (or body ""))))
                         (last-hash (and target
                                         (alist-get beg-block
                                                    claude-collab--auto-render-hashes))))
                    (when (and target (not (equal current-hash last-hash)))
                      (ignore-errors (org-babel-execute-src-block))
                      (setf (alist-get beg-block
                                       claude-collab--auto-render-hashes)
                            current-hash)
                      (setq any-rendered t))))))
            (when any-rendered
              (org-display-inline-images nil t))))))))

(defun claude-collab--auto-render-schedule (&rest _)
  "`after-change-functions' hook: (re)start the idle timer."
  (unless claude-collab--auto-render-running
    (when (timerp claude-collab--auto-render-timer)
      (cancel-timer claude-collab--auto-render-timer))
    (let ((buf (current-buffer)))
      (setq claude-collab--auto-render-timer
            (run-with-idle-timer
             claude-collab-auto-render-idle-delay nil
             (lambda () (claude-collab--auto-render-now buf)))))))

(define-minor-mode claude-collab-auto-render-diagrams-mode
  "Auto-execute plantuml / dot / mermaid / ditaa blocks after a short idle.
Only blocks with a `:file' header and whose body has actually changed are
re-rendered.  Inline image previews refresh automatically."
  :lighter " cc-render"
  (if claude-collab-auto-render-diagrams-mode
      (progn
        (unless claude-collab--auto-render-hashes
          (setq claude-collab--auto-render-hashes nil))
        (add-hook 'after-change-functions
                  #'claude-collab--auto-render-schedule nil t)
        ;; Also render once on mode-entry so already-present blocks pick up.
        (claude-collab--auto-render-schedule))
    (remove-hook 'after-change-functions
                 #'claude-collab--auto-render-schedule t)
    (when (timerp claude-collab--auto-render-timer)
      (cancel-timer claude-collab--auto-render-timer)
      (setq claude-collab--auto-render-timer nil))))

;; Auto-enable in all org buffers. Users who don't want it can
;;   (remove-hook 'org-mode-hook #'claude-collab-auto-render-diagrams-mode)
(add-hook 'org-mode-hook #'claude-collab-auto-render-diagrams-mode)

;; --- Cap inline image height -----------------------------------------
;; `org-image-actual-width' caps width but org has no public max-height
;; setting in 9.8. A full-page PlantUML flow chart renders at ~1500px
;; tall and dominates the buffer. Inject `:max-height' into the image
;; object before `insert-image' via `:filter-return' advice.

(defcustom claude-collab-inline-image-max-height 520
  "Maximum pixel height for inline images in org buffers.
Set to nil to disable capping.  Applied via advice on
`org--create-inline-image' since org 9.8 has no public equivalent."
  :type '(choice (const :tag "No cap" nil) integer))

(defun claude-collab--cap-inline-image-height (img)
  "`:filter-return' advice: cap IMG's height at `claude-collab-inline-image-max-height'."
  (when (and img
             (consp img)
             (eq (car img) 'image)
             claude-collab-inline-image-max-height
             (not (plist-member (cdr img) :max-height)))
    (setcdr img (plist-put (cdr img) :max-height
                           claude-collab-inline-image-max-height)))
  img)

(with-eval-after-load 'org
  (advice-add 'org--create-inline-image :filter-return
              #'claude-collab--cap-inline-image-height))


(defun claude-collab-add-annotation (beg end note)
  "Annotate the selected region with NOTE.
Creates an `org-remark' highlight whose label is NOTE — the popup
and the `SPC o c l' listing both read from this label."
  (interactive
   (progn
     (unless (use-region-p)
       (user-error "Select a region first (evil visual mode or C-SPC + motion)"))
     (list (region-beginning)
           (region-end)
           (read-string "Annotation: "))))
  (unless (fboundp 'org-remark-highlight-mark)
    (user-error "org-remark not loaded"))
  (when (string-empty-p (string-trim note))
    (user-error "Empty annotation — aborted"))
  (org-remark-highlight-mark beg end nil nil note)
  (deactivate-mark)
  (message "Annotated \"%s\" → %s"
           (buffer-substring-no-properties beg end)
           note))


(defun claude-collab-list-annotations ()
  "Show a terse list of pending annotations in the current buffer.
Cleaner than `org-remark-open' for the common case of \"what am I
waiting on in this file\"."
  (interactive)
  (let ((anns (claude-collab--annotations-in-buffer (current-buffer)))
        (src-name (buffer-name)))
    (unless anns
      (user-error "No pending annotations in %s" src-name))
    (let ((buf (get-buffer-create "*claude-collab: annotations*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Pending annotations in %s  (%d)\n"
                          src-name (length anns)))
          (insert (make-string 60 ?─) "\n\n")
          (dolist (a anns)
            (insert (format "• \"%s\"\n    → %s\n\n"
                            (plist-get a :text)
                            (or (plist-get a :label) "(no note)")))))
        (goto-char (point-min))
        (setq-local buffer-read-only t))
      (display-buffer buf '((display-buffer-in-side-window)
                            (side . bottom)
                            (window-height . 0.3))))))


;;; Spacemacs leader keys (SPC o c prefix)

(when (fboundp 'spacemacs/declare-prefix)
  (spacemacs/declare-prefix "oc" "claude-collab")
  (spacemacs/set-leader-keys
    "occ" #'claude-collab-add-annotation
    "ocr" 'org-remark-remove
    "ocn" 'org-remark-next
    "ocp" 'org-remark-prev
    "ocl" #'claude-collab-list-annotations
    "ocu" #'claude-collab-undo-session
    "ocU" #'claude-collab-undo-edit
    "ocR" #'claude-collab-pick-session
    "oca" #'claude-collab-accept-session
    "och" #'claude-collab-toggle-overlays
    "ocd" #'claude-collab-diff-popup-mode
    "ocD" #'claude-collab-show-edit-diff-full))

(provide 'claude-collab)
;;; claude-collab.el ends here
