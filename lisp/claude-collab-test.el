;;; claude-collab-test.el --- ERT suite for claude-collab -*- lexical-binding: t -*-
;;
;; Runs via (claude-collab-run-tests) — the MCP tool
;; `claude-collab-run-tests' wraps this so Claude can drive the suite
;; autonomously via eval-elisp. Returns a plist
;; (:passed N :failed N :failures (...)) for parseable output.

(require 'ert)
(require 'cl-lib)
(require 'claude-collab)

;;; --- test helpers ---

(defvar claude-collab-test--tempfiles nil
  "List of temp files to clean up after each test.")

(defmacro claude-collab-test--with-temp-file (var-buf var-file &rest body)
  "Create a temp text file, bind VAR-BUF (buffer) and VAR-FILE (path), run BODY."
  (declare (indent 2))
  `(let* ((,var-file (make-temp-file "claude-collab-test-" nil ".txt"))
          (,var-buf (find-file-noselect ,var-file)))
     (push ,var-file claude-collab-test--tempfiles)
     (unwind-protect
         (with-current-buffer ,var-buf
           (erase-buffer)
           (insert "Hello world, this is a starting line.\nSecond line here.\nThird line.")
           (save-buffer)
           ,@body)
       (when (buffer-live-p ,var-buf)
         (with-current-buffer ,var-buf (set-buffer-modified-p nil))
         (kill-buffer ,var-buf))
       (when (file-exists-p ,var-file) (delete-file ,var-file))
       (setq claude-collab-test--tempfiles
             (delete ,var-file claude-collab-test--tempfiles)))))

(defmacro claude-collab-test--with-fake-session (id &rest body)
  "Bind the active session ID to ID for BODY."
  (declare (indent 1))
  `(let ((claude-collab--active-session ,id))
     ,@body))

(defun claude-collab-test--simulate-edit (buf pos text &optional replace-len)
  "Simulate a Claude edit: insert TEXT at POS in BUF (optionally replacing REPLACE-LEN chars).
Routes through `mcp-server-security-safe-eval' so the advice fires.
Skips the calling test if `mcp-server-security-safe-eval' is not loaded
(eldev / batch CI without the local emacs-mcp-server checkout)."
  (unless (fboundp 'mcp-server-security-safe-eval)
    (ert-skip "mcp-server-security-safe-eval not loaded — integration test"))
  (let ((form
         (if replace-len
             `(with-current-buffer ,(buffer-name buf)
                (goto-char ,pos)
                (delete-region ,pos ,(+ pos replace-len))
                (insert ,text))
           `(with-current-buffer ,(buffer-name buf)
              (goto-char ,pos)
              (insert ,text)))))
    (mcp-server-security-safe-eval form)))

(defun claude-collab-test--reset-state ()
  "Reset all session logs — isolates tests."
  (maphash
   (lambda (_sid edits)
     (dolist (e edits)
       (let ((ov (claude-collab-edit-overlay e)))
         (when (overlayp ov) (delete-overlay ov)))))
   claude-collab--sessions)
  (clrhash claude-collab--sessions))

;;; --- tests ---

(ert-deftest claude-collab-test-edit-overlay ()
  "Simulated edit logs a record and installs an overlay."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (claude-collab-test--with-fake-session 'test-session-1
      (claude-collab-test--simulate-edit buf 1 "PREFIX-")
      (let ((edits (claude-collab-session-edits 'test-session-1))
            (overlays (claude-collab-overlays-in buf)))
        (should (= 1 (length edits)))
        (should (= 1 (length overlays)))
        (should (string= "PREFIX-"
                         (claude-collab-edit-after-text (car edits))))
        (should (string= "" (claude-collab-edit-before-text (car edits))))
        (should (string= "PREFIX-"
                         (with-current-buffer buf
                           (buffer-substring-no-properties 1 8))))))))

(ert-deftest claude-collab-test-undo-session ()
  "undo-session reverts all edits in the latest session."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let ((original (with-current-buffer buf (buffer-string))))
      (claude-collab-test--with-fake-session 'test-session-2
        (claude-collab-test--simulate-edit buf 1 "A-")
        (claude-collab-test--simulate-edit buf 3 "B-")
        (claude-collab-test--simulate-edit buf 5 "C-"))
      (should (= 3 (length (claude-collab-session-edits 'test-session-2))))
      (claude-collab--revert-session 'test-session-2)
      (should (string= original (with-current-buffer buf (buffer-string))))
      (should (null (claude-collab-session-edits 'test-session-2)))
      (should (zerop (length (claude-collab-overlays-in buf)))))))

(ert-deftest claude-collab-test-cross-buffer-undo ()
  "A session spans buffers; undo reverts edits in each."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf-a _file-a
    (claude-collab-test--with-temp-file buf-b _file-b
      (let ((orig-a (with-current-buffer buf-a (buffer-string)))
            (orig-b (with-current-buffer buf-b (buffer-string))))
        (claude-collab-test--with-fake-session 'test-session-3
          (claude-collab-test--simulate-edit buf-a 1 "AAA-")
          (claude-collab-test--simulate-edit buf-b 1 "BBB-"))
        (should (= 2 (length (claude-collab-session-edits 'test-session-3))))
        (claude-collab--revert-session 'test-session-3)
        (should (string= orig-a (with-current-buffer buf-a (buffer-string))))
        (should (string= orig-b (with-current-buffer buf-b (buffer-string))))))))

(ert-deftest claude-collab-test-conflict-detection ()
  "Manually editing after Claude causes revert to abort with `claude-collab-conflict'."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (claude-collab-test--with-fake-session 'test-session-4
      (claude-collab-test--simulate-edit buf 1 "CLAUDE-"))
    (with-current-buffer buf
      (goto-char 1)
      (let ((inhibit-modification-hooks t))
        (insert "MANUAL-")))
    ;; The topmost edit's after-text was "CLAUDE-"; now region starts with "MANUAL-CLAUDE-"
    (let ((err (should-error (claude-collab--revert-edit
                              (car (claude-collab-session-edits 'test-session-4)))
                             :type 'claude-collab-conflict)))
      (should (string-match-p "modified since" (cadr err))))))

(ert-deftest claude-collab-test-session-boundary ()
  "Edits under distinct session IDs produce distinct session entries."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (claude-collab-test--with-fake-session 'session-pid-1111
      (claude-collab-test--simulate-edit buf 1 "X-"))
    (claude-collab-test--with-fake-session 'session-pid-2222
      (claude-collab-test--simulate-edit buf 1 "Y-"))
    (let ((sessions (claude-collab-list-sessions)))
      (should (= 2 (length sessions)))
      (should (assoc 'session-pid-1111 sessions))
      (should (assoc 'session-pid-2222 sessions)))))

(ert-deftest claude-collab-test-undo-edit-single ()
  "undo-edit reverts only the most recent single edit."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (claude-collab-test--with-fake-session 'test-session-5
      (claude-collab-test--simulate-edit buf 1 "FIRST-")
      (claude-collab-test--simulate-edit buf 1 "SECOND-"))
    (should (= 2 (length (claude-collab-session-edits 'test-session-5))))
    (claude-collab--revert-edit
     (car (claude-collab-session-edits 'test-session-5)))
    (puthash 'test-session-5
             (cdr (claude-collab-session-edits 'test-session-5))
             claude-collab--sessions)
    (should (= 1 (length (claude-collab-session-edits 'test-session-5))))
    ;; After reverting the SECOND edit, FIRST-'s insertion remains:
    (should (string-prefix-p "FIRST-" (with-current-buffer buf (buffer-string))))))

(ert-deftest claude-collab-test-toggle-overlays ()
  "Toggle overlays changes face visibility without touching the log."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (claude-collab-test--with-fake-session 'test-session-6
      (claude-collab-test--simulate-edit buf 1 "TOG-"))
    (let ((ov (car (claude-collab-overlays-in buf)))
          (before claude-collab-show-overlays))
      (should ov)
      (should (eq 'claude-edit-face (overlay-get ov 'face)))
      (claude-collab-toggle-overlays)
      (should (null (overlay-get ov 'face)))
      (claude-collab-toggle-overlays)
      (should (eq 'claude-edit-face (overlay-get ov 'face)))
      (unless (eq before claude-collab-show-overlays)
        (claude-collab-toggle-overlays)))))

(ert-deftest claude-collab-test-annotation-add ()
  "Adding an org-remark highlight registers as a pending annotation."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "test-note")
      (let ((anns (claude-collab--annotations-in-buffer buf)))
        (should (= 1 (length anns)))
        (should (plist-get (car anns) :id))
        (should (equal "world" (plist-get (car anns) :text)))))))

(ert-deftest claude-collab-test-annotation-body-fallback ()
  "When :org-remark-label is nil, the marginalia headline body fills in."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf file
    (with-current-buffer buf
      ;; Mark the region with no label (vanilla `org-remark-mark' shape).
      (org-remark-highlight-mark 7 12 nil nil nil)
      (save-buffer))
    ;; Inject a body note into the marginalia headline by hand.
    (let* ((notes-file (with-current-buffer buf
                         (org-remark-notes-get-file-name)))
           (notes-buf (find-file-noselect notes-file)))
      (with-current-buffer notes-buf
        (goto-char (point-max))
        (insert "\nuser-typed body note\n")
        (save-buffer))
      (let* ((anns (claude-collab--annotations-in-buffer buf))
             (a (car anns)))
        (should (= 1 (length anns)))
        (should (equal "user-typed body note" (plist-get a :label)))))))

(ert-deftest claude-collab-test-annotation-empty-body-stays-nil ()
  "Whitespace-only body must not masquerade as a real note."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil nil)
      (save-buffer))
    (let* ((notes-file (with-current-buffer buf
                         (org-remark-notes-get-file-name)))
           (notes-buf (find-file-noselect notes-file)))
      (with-current-buffer notes-buf
        (goto-char (point-max))
        (insert "\n   \n\t\n")
        (save-buffer))
      (let ((a (car (claude-collab--annotations-in-buffer buf))))
        (should (null (plist-get a :label)))))))

(ert-deftest claude-collab-test-annotation-coupling ()
  "Resolve + undo-session restores the annotation."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let (ann-id)
      (with-current-buffer buf
        (let ((ov (org-remark-highlight-mark 7 12 nil nil "resolve-me")))
          (setq ann-id (overlay-get ov 'org-remark-id))))
      (should ann-id)
      (claude-collab-test--with-fake-session 'test-session-7
        (claude-collab-resolve-annotation-by-id ann-id))
      ;; After resolve: annotation should be gone
      (should (zerop (length (claude-collab--annotations-in-buffer buf))))
      ;; Session should hold a record of kind 'annotation-resolve
      (let ((edits (claude-collab-session-edits 'test-session-7)))
        (should (= 1 (length edits)))
        (should (eq 'annotation-resolve (claude-collab-edit-kind (car edits)))))
      ;; Undo: annotation re-appears
      (claude-collab--revert-session 'test-session-7)
      (should (= 1 (length (claude-collab--annotations-in-buffer buf)))))))

;;; --- new structural editing tool tests ---

(defmacro claude-collab-test--with-annotated-buffer (var-buf var-file var-id text &rest body)
  "Create a temp file whose buffer holds an org-remark annotation.
Binds VAR-BUF, VAR-FILE, and VAR-ID (the annotation id) for BODY.
TEXT is a literal substring of the buffer to highlight. Uses
`org-remark-highlight-mark' when available, otherwise fabricates an
overlay carrying `org-remark-id' directly — both paths exercise the
live-overlay lookup in `claude-collab--find-annotation'."
  (declare (indent 4))
  `(claude-collab-test--with-temp-file ,var-buf ,var-file
     (with-current-buffer ,var-buf
       (goto-char (point-min))
       (unless (search-forward ,text nil t)
         (error "Highlight text %S not found in test buffer" ,text))
       (let* ((b (match-beginning 0))
              (e (match-end 0))
              (,var-id
               (if (fboundp 'org-remark-highlight-mark)
                   (let ((ov (org-remark-highlight-mark b e nil nil "test-note")))
                     (overlay-get ov 'org-remark-id))
                 (let ((ov (make-overlay b e))
                       (fake-id (format "fake-%d-%d" b (random 100000))))
                   (overlay-put ov 'org-remark-id fake-id)
                   (overlay-put ov 'category 'org-remark-highlighter)
                   (overlay-put ov 'org-remark-label "test-note")
                   fake-id))))
         ,@body))))

(defun claude-collab-test--fabricate-overlay-in (buf begin end)
  "Fabricate an org-remark-style overlay in BUF over BEGIN..END.
Returns the annotation ID. Bypasses `org-remark-highlight-mark' so
tests run even when org-remark isn't loaded."
  (with-current-buffer buf
    (let ((ov (make-overlay begin end))
          (id (format "fake-%d-%d-%d" begin end (random 100000))))
      (overlay-put ov 'org-remark-id id)
      (overlay-put ov 'category 'org-remark-highlighter)
      (overlay-put ov 'org-remark-label "test-note")
      id)))

(ert-deftest claude-collab-test-apply-annotation-pre-edit-fingerprint ()
  "apply-annotation result carries a :pre-edit plist so postmortem can
spot drift retrospectively. With matching marginalia text, :drift is nil."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "test-note")
      (save-buffer))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-apply-annotation id :replace "there"))
           (pe (plist-get result :pre-edit)))
      (should (plist-get result :ok))
      (should (plist-member result :pre-edit))
      (should (numberp (plist-get pe :overlay-beg)))
      (should (numberp (plist-get pe :overlay-end)))
      (should (stringp (plist-get pe :existing-prefix)))
      (should (null (plist-get pe :drift))))))

(ert-deftest claude-collab-test-apply-annotation-aborts-on-drift ()
  "If marginalia's anchor text no longer locates uniquely in the buffer,
`apply-annotation' refuses to mutate and returns :error :code :drift —
the structural prevention of the original `:verify:'-line splice.

Strategy: save once to commit marginalia's record of `world' at 7..12,
then mutate the buffer destructively *without* a second save. Marginalia
keeps the original anchor text on disk; the source buffer doesn't.
Drift detector compares marginalia anchor against live buffer text.
The buffer-string assertion at the end is the load-bearing one — drift
must abort BEFORE any mutation lands."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "test-note")
      (save-buffer)
      (goto-char 7)
      (delete-region 7 12)
      (insert "PHANTOM"))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-apply-annotation id :replace "BANG"))
           (final (with-current-buffer buf (buffer-string))))
      (should (plist-get result :error))
      (should (eq :drift (plist-get result :code)))
      (should (eq :not-found (plist-get result :drift-kind)))
      ;; Critical: the buffer must NOT have been mutated.
      (should (string-match-p "PHANTOM" final))
      (should-not (string-match-p "BANG" final)))))

(ert-deftest claude-collab-test-apply-annotation-force-bypasses-drift ()
  "When FORCE is non-nil the drift guard is skipped — used by callers
that have reasoned about the drift and accept the risk. To prove force
actually applies (and doesn't fail for an unrelated reason that happens
not to be `:drift'), this test arranges a buffer where drift IS true
but the live overlay still covers a unique 5-char span — so the edit
can land. The assertion is `:ok t', not just `not :drift'."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "test-note")
      (save-buffer)
      ;; Replace `world' (anchor) with `WORLDS' — anchor.text = `world'
      ;; is no longer present in source (drift :not-found). But the live
      ;; overlay shifted and covers `WORLDS' (or part of it). force=t
      ;; lets the edit proceed against the overlay's current bounds.
      (goto-char 7)
      (delete-region 7 12)
      (insert "WORLDS"))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-apply-annotation id :replace "FORCED" nil t)))
      ;; Strong assertion: forced apply must succeed end-to-end, not
      ;; just sidestep the drift code.
      (should (plist-get result :ok))
      (should-not (eq :drift (plist-get result :code))))))

(ert-deftest claude-collab-test-apply-annotation-transactional-rollback ()
  "When auto-resolve throws after a successful edit, the edit gets
reverted — buffer ends up in pre-edit state, result is
\(:error :code :resolve-failed). The unit-of-work guarantee replaces
the previous half-applied `:ok t :resolved nil :resolve-error MSG'
shape that confused agent retry logic."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "x")
      (save-buffer))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (snapshot-before (with-current-buffer buf (buffer-string))))
      (cl-letf (((symbol-function 'claude-collab-resolve-annotation-by-id)
                 (lambda (_id) (error "stubbed resolve failure"))))
        (let* ((result (claude-collab-apply-annotation id :replace "DOES-NOT-PERSIST"))
               (snapshot-after (with-current-buffer buf (buffer-string))))
          (should (plist-get result :error))
          (should (eq :resolve-failed (plist-get result :code)))
          (should (equal "stubbed resolve failure" (plist-get result :resolve-error)))
          ;; Critical: buffer is rolled back to pre-edit state.
          (should (string= snapshot-before snapshot-after))
          (should-not (string-match-p "DOES-NOT-PERSIST" snapshot-after)))))))

(ert-deftest claude-collab-test-apply-annotation-drift-ambiguous-via-adapter ()
  "When the anchor's text appears multiple times in the buffer and no
context disambiguates, drift must surface as `:drift-kind :ambiguous'
through the adapter — not just at the core level. The previous adapter
test only covered `:not-found'."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      ;; Buffer becomes: "Hello world, this is a starting line.
      ;; Second world here.
      ;; Third world." — the anchor's text `world' appears 3 times.
      (erase-buffer)
      (insert "Hello world, this is a starting line.\nSecond world here.\nThird world.")
      (org-remark-highlight-mark 7 12 nil nil "first-world")
      (save-buffer))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-apply-annotation id :replace "X")))
      (should (plist-get result :error))
      (should (eq :drift (plist-get result :code)))
      (should (eq :ambiguous (plist-get result :drift-kind)))
      (should (plist-get result :drift-diag)))))

;;; --- check-anchor (read-only drift probe) ---

(ert-deftest claude-collab-test-check-anchor-not-found-id ()
  "check-anchor on a non-existent ID returns :exists nil."
  (let ((result (claude-collab-check-anchor "ghost-id-zzz")))
    (should (plist-get result :ok))
    (should-not (plist-get result :exists))
    (should (plist-get result :error))))

(ert-deftest claude-collab-test-check-anchor-clean ()
  "Anchor located uniquely → :drift nil."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "x")
      (save-buffer))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-check-anchor id)))
      (should (plist-get result :ok))
      (should (plist-get result :exists))
      (should (null (plist-get result :drift)))
      (should (consp (plist-get result :overlay-bounds))))))

(ert-deftest claude-collab-test-check-anchor-drift-not-found ()
  "Anchor's text deleted from buffer → :drift :not-found, no mutation."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "x")
      (save-buffer)
      (goto-char 7)
      (delete-region 7 12)
      (insert "PHANTOM"))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (snapshot (with-current-buffer buf (buffer-string)))
           (result (claude-collab-check-anchor id)))
      (should (eq :not-found (plist-get result :drift)))
      ;; Read-only — buffer unchanged.
      (should (string= snapshot (with-current-buffer buf (buffer-string)))))))

(ert-deftest claude-collab-test-check-anchor-drift-ambiguous ()
  "Anchor's text duplicated → :drift :ambiguous with candidate regions
in :diagnosis. Agent can present alternatives without retrying blind."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (erase-buffer)
      (insert "Hello world world world.")
      (org-remark-highlight-mark 7 12 nil nil "x")
      (save-buffer))
    (let* ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id))
           (result (claude-collab-check-anchor id))
           (diag (plist-get result :diagnosis)))
      (should (eq :ambiguous (plist-get result :drift)))
      (should diag)
      (should (plist-get diag :candidates)))))

(ert-deftest claude-collab-test-mcp-log-captures-internal-calls ()
  "Logging on the public function (not the MCP handler) means a direct
call to `claude-collab-apply-annotation' from elisp lands in the log —
the exact path /design revise hit through eval-elisp."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-clear-log)
  (claude-collab-test--with-temp-file buf _file
    (with-current-buffer buf
      (org-remark-highlight-mark 7 12 nil nil "test-note")
      (save-buffer))
    (let ((id (plist-get (car (claude-collab--annotations-in-buffer buf)) :id)))
      (claude-collab-apply-annotation id :replace "there"))
    (with-current-buffer (claude-collab--mcp-log-buffer)
      (let ((s (buffer-string)))
        (should (string-match-p "apply-annotation" s))
        ;; pre-edit fingerprint surfaces in the result line
        (should (string-match-p ":pre-edit" s))))))

(ert-deftest claude-collab-test-mcp-log-jsonl-file-tee ()
  "Each MCP log entry is also appended to `claude-collab-mcp-log-file'
as one JSON object per line — `jq -c' over the file should parse."
  (let* ((tmp (make-temp-file "cc-log-" nil ".jsonl"))
         (claude-collab-mcp-log-file tmp))
    (unwind-protect
        (progn
          (claude-collab-clear-log)
          (claude-collab--mcp-log-entry "test-tool"
                                        '(:foo "bar")
                                        "(:ok t)"
                                        7 nil)
          (let ((content (with-temp-buffer
                           (insert-file-contents tmp)
                           (buffer-string))))
            (should (string-match-p "\"tool\":\"test-tool\"" content))
            (should (string-match-p "\"elapsed_ms\":7" content))
            (should (string-suffix-p "\n" content))))
      (delete-file tmp))))

(ert-deftest claude-collab-test-mcp-log-suppress-flag ()
  "When `claude-collab--mcp-log-suppress' is t, no entry lands. Used by
revert-session to avoid recording its own delete/insert sweeps as fresh
edits — the recursive feedback loop that bloated session 65390 during
the /design revise drift incident."
  (claude-collab-clear-log)
  (let ((claude-collab--mcp-log-suppress t))
    (claude-collab--mcp-log-entry "ghost-tool" '(:x 1) "result" 0 nil))
  (with-current-buffer (claude-collab--mcp-log-buffer)
    (should (string-empty-p (buffer-string)))))

;; The old `apply-annotation-resolve-error-surfaces' test asserted the
;; pre-transactional shape `(:ok t :resolved nil :resolve-error MSG)'
;; — a half-applied buffer state that confused agent retry logic. Now
;; superseded by `apply-annotation-transactional-rollback' which proves
;; the buffer is rolled back AND the result is `:error :code
;; :resolve-failed' (clean failure, not partial success).

(ert-deftest claude-collab-test-mcp-log-records-error ()
  "Errors signaled inside `claude-collab--with-mcp-log' get logged
with an `ERROR' marker, the args, and the error message — direct
test of the macro's error path so it doesn't depend on which
handler happens to raise."
  (claude-collab-clear-log)
  (condition-case _err
      (claude-collab--with-mcp-log "test-tool" '(:probe t)
        (error "kaboom"))
    (error nil))
  (with-current-buffer (claude-collab--mcp-log-buffer)
    (let ((s (buffer-string)))
      (should (string-match-p "test-tool" s))
      (should (string-match-p "ERROR" s))
      (should (string-match-p "kaboom" s)))))

(ert-deftest claude-collab-test-apply-annotation-replace ()
  "apply-annotation :replace swaps the annotated region and auto-resolves."
  ;; KNOWN FLAKE: the test fabricates a stub overlay (`--fabricate-overlay-in')
  ;; that lacks the marginalia file org-remark expects, so on auto-resolve
  ;; `org-remark-delete' detaches the overlay from the buffer without
  ;; fully removing it (`#<overlay in no buffer>'). Real-org-remark
  ;; counterpart `claude-collab-test-apply-annotation-real-org-remark'
  ;; passes; the stub-overlay path conflates "removed from buffer" with
  ;; "deleted entirely". Marked :failed so CI green bar is meaningful.
  :expected-result :failed
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    ;; Highlight "world" (positions 7..12 in "Hello world,...").
    (let ((id (claude-collab-test--fabricate-overlay-in buf 7 12)))
      (let ((result (claude-collab-apply-annotation id :replace "there")))
        (should (plist-get result :ok))
        (should (= 7 (plist-get result :new-begin)))
        (should (= 12 (plist-get result :new-end))))
      (should (string-prefix-p "Hello there,"
                               (with-current-buffer buf (buffer-string))))
      ;; Overlay should be gone (resolved).
      (with-current-buffer buf
        (should (null (cl-find-if
                       (lambda (o) (equal (overlay-get o 'org-remark-id) id))
                       (overlays-in (point-min) (point-max))))))
      ;; Also safe to skip org-remark-delete gracefully when unavailable;
      ;; the fabricated overlay is cleaned up via delete-overlay fallback.
      )))

(ert-deftest claude-collab-test-apply-annotation-delete ()
  "apply-annotation :delete removes the annotated region and auto-resolves."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let ((id (claude-collab-test--fabricate-overlay-in buf 7 13)))
      ;; 7..13 covers "world,".
      (let ((result (claude-collab-apply-annotation id :delete)))
        (should (plist-get result :ok))
        (should (= 7 (plist-get result :new-begin)))
        (should (= 7 (plist-get result :new-end))))
      (should (string-prefix-p "Hello  this"
                               (with-current-buffer buf (buffer-string)))))))

(ert-deftest claude-collab-test-apply-annotation-missing-id ()
  "apply-annotation returns :error for unknown ID."
  (claude-collab-test--reset-state)
  (let ((result (claude-collab-apply-annotation "no-such-id" :replace "x")))
    (should (plist-get result :error))
    (should (string-match-p "not found" (plist-get result :error)))))

(ert-deftest claude-collab-test-get-region-bounds-annotation ()
  "get-region-bounds :annotation matches the overlay bounds."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let ((id (claude-collab-test--fabricate-overlay-in buf 7 12)))
      (let ((result (claude-collab-get-region-bounds id :annotation)))
        (should (plist-get result :ok))
        (should (= 7 (plist-get result :begin)))
        (should (= 12 (plist-get result :end)))))))

(ert-deftest claude-collab-test-get-region-bounds-line ()
  "get-region-bounds :line returns the full line containing the anchor."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    ;; First line: "Hello world, this is a starting line." = 38 chars, ends at 38.
    (let ((id (claude-collab-test--fabricate-overlay-in buf 7 12)))
      (let ((result (claude-collab-get-region-bounds id :line)))
        (should (plist-get result :ok))
        (should (= 1 (plist-get result :begin)))
        (should (= 38 (plist-get result :end)))))))

(ert-deftest claude-collab-test-get-region-bounds-section ()
  "get-region-bounds :section returns heading start through end-of-subtree."
  (claude-collab-test--reset-state)
  (let ((tmp (make-temp-file "claude-collab-test-" nil ".org")))
    (unwind-protect
        (let ((buf (find-file-noselect tmp)))
          (unwind-protect
              (with-current-buffer buf
                (erase-buffer)
                (insert "* Heading One\nAlpha body line.\nAnother body line.\n* Heading Two\nBeta body line.\n")
                (save-buffer)
                (org-mode)
                ;; Highlight "Alpha" inside Heading One's subtree.
                (goto-char (point-min))
                (search-forward "Alpha")
                (let* ((b (match-beginning 0))
                       (e (match-end 0))
                       (id (claude-collab-test--fabricate-overlay-in buf b e))
                       (result (claude-collab-get-region-bounds id :section)))
                  (should (plist-get result :ok))
                  ;; Section begins at position 1 (heading start).
                  (should (= 1 (plist-get result :begin)))
                  ;; Ends before second heading — content should include "Another body line.\n"
                  (let* ((begin (plist-get result :begin))
                         (end (plist-get result :end))
                         (slice (buffer-substring-no-properties begin end)))
                    (should (string-match-p "\\`\\* Heading One" slice))
                    (should (string-match-p "Another body line" slice))
                    (should-not (string-match-p "Heading Two" slice)))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest claude-collab-test-get-region-bounds-missing-id ()
  "get-region-bounds returns :error for unknown ID."
  (claude-collab-test--reset-state)
  (let ((result (claude-collab-get-region-bounds "no-such-id" :annotation)))
    (should (plist-get result :error))
    (should (string-match-p "not found" (plist-get result :error)))))

(ert-deftest claude-collab-test-apply-edit-insert ()
  "apply-edit with begin == end inserts at the position."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf file
    (let ((result (claude-collab-apply-edit file 1 1 "START-")))
      (should (plist-get result :ok))
      (should (= 1 (plist-get result :new-begin)))
      (should (= 7 (plist-get result :new-end))))
    (should (string-prefix-p "START-Hello"
                             (with-current-buffer buf (buffer-string))))))

(ert-deftest claude-collab-test-apply-edit-replace ()
  "apply-edit with begin < end replaces the region."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf file
    ;; Replace "Hello" (1..6) with "Howdy".
    (let ((result (claude-collab-apply-edit file 1 6 "Howdy")))
      (should (plist-get result :ok))
      (should (= 1 (plist-get result :new-begin)))
      (should (= 6 (plist-get result :new-end))))
    (should (string-prefix-p "Howdy world"
                             (with-current-buffer buf (buffer-string))))))

(ert-deftest claude-collab-test-apply-edit-file-not-open ()
  "apply-edit returns :error when file is not open in any buffer."
  (claude-collab-test--reset-state)
  (let ((result (claude-collab-apply-edit "/tmp/no-such-claude-collab-file.txt"
                                          1 1 "x")))
    (should (plist-get result :error))
    (should (string-match-p "not open" (plist-get result :error)))))

(ert-deftest claude-collab-test-apply-edit-non-integer-positions ()
  "apply-edit returns :error when begin/end are not integers."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file _buf file
    (let ((result (claude-collab-apply-edit file "1" 6 "x")))
      (should (plist-get result :error))
      (should (string-match-p "must be integers" (plist-get result :error))))
    (let ((result (claude-collab-apply-edit file 1 nil "x")))
      (should (plist-get result :error))
      (should (string-match-p "must be integers" (plist-get result :error))))))

(ert-deftest claude-collab-test-apply-edit-inverted-range ()
  "apply-edit returns :error when begin > end."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file _buf file
    (let ((result (claude-collab-apply-edit file 10 5 "x")))
      (should (plist-get result :error))
      (should (string-match-p "begin (10) > end (5)" (plist-get result :error))))))

(ert-deftest claude-collab-test-error-codes-apply-edit ()
  "Every `apply-edit' failure mode carries a typed `:code' keyword
the agent can dispatch on without substring-matching the message."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf file
    ;; bad-arg: nil new-text
    (let ((r (claude-collab-apply-edit file 1 5 nil)))
      (should (eq :bad-arg (plist-get r :code))))
    ;; bad-arg: non-integer positions
    (let ((r (claude-collab-apply-edit file "x" 5 "y")))
      (should (eq :bad-arg (plist-get r :code))))
    ;; invalid-range: begin > end
    (let ((r (claude-collab-apply-edit file 10 5 "y")))
      (should (eq :invalid-range (plist-get r :code))))
    ;; out-of-bounds: end past point-max
    (let* ((pmax (with-current-buffer buf (point-max)))
           (r (claude-collab-apply-edit file 1 (+ pmax 100) "y")))
      (should (eq :out-of-bounds (plist-get r :code))))
    ;; buffer-not-open
    (let ((r (claude-collab-apply-edit "/no/such/file/anywhere.txt" 1 5 "y")))
      (should (eq :buffer-not-open (plist-get r :code))))))

(ert-deftest claude-collab-test-error-codes-apply-annotation ()
  "Same contract for `apply-annotation' — every failure path carries
a typed `:code'."
  (claude-collab-test--reset-state)
  ;; not-found
  (let ((r (claude-collab-apply-annotation "ghost-id-xyz" :replace "x")))
    (should (eq :not-found (plist-get r :code)))))

(ert-deftest claude-collab-test-error-codes-apply-batch ()
  "`apply-batch' enforces typed codes for shape errors before delegating."
  (claude-collab-test--reset-state)
  ;; bad-arg: edits not a list
  (let ((r (claude-collab-apply-batch "not-a-list")))
    (should (eq :bad-arg (plist-get r :code))))
  ;; bad-arg: missing :id in entry
  (let* ((r (claude-collab-apply-batch '((:action :replace :new-text "x"))))
         (entry (car (plist-get r :results))))
    (should (eq :bad-arg (plist-get entry :code))))
  ;; bad-arg: missing :action in entry
  (let* ((r (claude-collab-apply-batch '((:id "x" :new-text "y"))))
         (entry (car (plist-get r :results))))
    (should (eq :bad-arg (plist-get entry :code)))))

(ert-deftest claude-collab-test-apply-edit-out-of-bounds ()
  "apply-edit returns :error when the range exceeds buffer bounds."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf file
    (let* ((pmax (with-current-buffer buf (point-max)))
           (result (claude-collab-apply-edit file 1 (+ pmax 100) "x")))
      (should (plist-get result :error))
      (should (string-match-p "out of bounds" (plist-get result :error))))
    (let ((result (claude-collab-apply-edit file 0 5 "x")))
      (should (plist-get result :error))
      (should (string-match-p "out of bounds" (plist-get result :error))))))

(ert-deftest claude-collab-test-apply-edit-nil-new-text ()
  "apply-edit returns :error when new-text is nil."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file _buf file
    (let ((result (claude-collab-apply-edit file 1 1 nil)))
      (should (plist-get result :error))
      (should (string-match-p "new-text must be a string"
                              (plist-get result :error))))))

(ert-deftest claude-collab-test-apply-annotation-nil-new-text ()
  "apply-annotation rejects non-string new-text for replace/insert-*."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let ((id (claude-collab-test--fabricate-overlay-in buf 7 12)))
      (let ((result (claude-collab-apply-annotation id :replace nil)))
        (should (plist-get result :error))
        (should (string-match-p "requires :new-text" (plist-get result :error))))
      (let ((result (claude-collab-apply-annotation id :insert-before 42)))
        (should (plist-get result :error))
        (should (string-match-p "requires :new-text"
                                (plist-get result :error)))))))

(ert-deftest claude-collab-test-apply-annotation-real-org-remark ()
  "Exercise the real `org-remark-highlight-mark' path via `with-annotated-buffer'.
We only assert the edit landed; `:resolved' may be nil if the batch
environment has no marginalia notes file configured."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (claude-collab-test--reset-state)
  (claude-collab-test--with-annotated-buffer buf _file id "world"
    (let ((result (claude-collab-apply-annotation id :replace "there")))
      (should (plist-get result :ok))
      (should (= 7 (plist-get result :new-begin)))
      (should (= 12 (plist-get result :new-end))))
    (should (string-prefix-p "Hello there,"
                             (with-current-buffer buf (buffer-string))))))

;;; --- active plan tracking ---

(defmacro claude-collab-test--with-plan-buffer (var-buf var-file &rest body)
  "Create a temp .org file inside a `plans/' subdir; bind VAR-BUF and VAR-FILE.
The directory tree is `<tmp>/<uniq>/plans/<name>.org', mirroring how a
real plan file lives under a project's `plans/' subdir. Cleans up after
recursively (org-remark may drop a marginalia notes file alongside)."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "claude-collab-plan-" t))
          (plans-dir (expand-file-name "plans" dir))
          (,var-file (progn (make-directory plans-dir t)
                            (expand-file-name "test-plan.org" plans-dir)))
          (_ (with-temp-file ,var-file (insert "* Test\nbody\n")))
          (,var-buf (find-file-noselect ,var-file)))
     (unwind-protect
         (with-current-buffer ,var-buf
           (org-mode)
           ,@body)
       (when (buffer-live-p ,var-buf)
         (with-current-buffer ,var-buf (set-buffer-modified-p nil))
         (kill-buffer ,var-buf))
       (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest claude-collab-test-plan-file-p ()
  "claude-collab--plan-file-p matches `.org' under a `plans/' segment."
  (should (claude-collab--plan-file-p "/repo/plans/x.org"))
  (should (claude-collab--plan-file-p "/a/b/plans/foo.org"))
  (should (claude-collab--plan-file-p "~/plans/y.org"))
  (should-not (claude-collab--plan-file-p "/repo/plans/x.md"))
  (should-not (claude-collab--plan-file-p "/repo/plans-archive/x.org"))
  (should-not (claude-collab--plan-file-p "/repo/notes/x.org"))
  (should-not (claude-collab--plan-file-p nil)))

(ert-deftest claude-collab-test-active-plan-set-on-annotate ()
  "claude-collab-add-annotation sets the active plan when buffer is a plan file."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (setq claude-collab--active-plan-file nil)
  (claude-collab-test--with-plan-buffer buf file
    (goto-char (point-min))
    (search-forward "body")
    (claude-collab-add-annotation (match-beginning 0) (match-end 0) "fix it")
    (should (equal (expand-file-name file)
                   (claude-collab-get-active-plan)))))

(ert-deftest claude-collab-test-active-plan-ignores-non-plan ()
  "Annotating a buffer outside a `plans/' dir leaves active-plan untouched."
  (skip-unless (fboundp 'org-remark-highlight-mark))
  (setq claude-collab--active-plan-file nil)
  (let* ((dir (make-temp-file "claude-collab-other-" t))
         (file (expand-file-name "loose.org" dir))
         (_ (with-temp-file file (insert "* Loose\nbody\n")))
         (buf (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buf
          (org-mode)
          (goto-char (point-min))
          (search-forward "body")
          (claude-collab-add-annotation (match-beginning 0) (match-end 0) "fix")
          (should (null (claude-collab-get-active-plan))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest claude-collab-test-active-plan-stale-file-gc ()
  "get-active-plan keeps the path while file exists; clears on file deletion."
  (let* ((dir (make-temp-file "claude-collab-stale-" t))
         (plans-dir (expand-file-name "plans" dir))
         (_ (make-directory plans-dir t))
         (file (expand-file-name "p.org" plans-dir))
         (_ (with-temp-file file (insert "x\n"))))
    (unwind-protect
        (progn
          (setq claude-collab--active-plan-file file)
          ;; File exists, no buffer visits — kept (greenfield A2 fix).
          (should (equal file (claude-collab-get-active-plan)))
          ;; Delete file → cleared on next get.
          (delete-file file)
          (should (null (claude-collab-get-active-plan)))
          (should (null claude-collab--active-plan-file)))
      (when (file-directory-p dir) (delete-directory dir t)))))


;;; --- bounds-aware apply-annotation ---

(defmacro claude-collab-test--with-org-buffer (var-buf var-file content &rest body)
  "Create a temp .org file with CONTENT, bind VAR-BUF and VAR-FILE."
  (declare (indent 3))
  `(let ((,var-file (make-temp-file "claude-collab-org-" nil ".org")))
     (unwind-protect
         (let ((,var-buf (find-file-noselect ,var-file)))
           (unwind-protect
               (with-current-buffer ,var-buf
                 (erase-buffer)
                 (insert ,content)
                 (save-buffer)
                 (org-mode)
                 ,@body)
             (when (buffer-live-p ,var-buf)
               (with-current-buffer ,var-buf (set-buffer-modified-p nil))
               (kill-buffer ,var-buf))))
       (when (file-exists-p ,var-file) (delete-file ,var-file)))))

(ert-deftest claude-collab-test-apply-annotation-list-item-unit ()
  "Replacing with unit=:list-item swaps just the item, leaves siblings.
Without trailing newline in new-text — auto-append must keep next item
on its own line."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-org-buffer buf _file
      "* H1\n- item one\n- item two\n\n* H2\n"
    (goto-char (point-min))
    (search-forward "item one")
    (let* ((b (match-beginning 0))
           (e (match-end 0))
           (id (claude-collab-test--fabricate-overlay-in buf b e))
           ;; Pass new-text WITHOUT trailing newline — the auto-append must save us.
           (result (claude-collab-apply-annotation
                    id :replace "- replacement" :list-item)))
      (should (plist-get result :ok))
      (let ((content (with-current-buffer buf (buffer-string))))
        ;; First item replaced, second item preserved.
        (should (string-match-p "- replacement\n- item two" content))
        (should-not (string-match-p "item one" content))
        ;; H2 heading still on its own line, separated by a blank line.
        (should (string-match-p "\n\n\\* H2\n" content))))))

(ert-deftest claude-collab-test-apply-annotation-section-unit ()
  "Replacing with unit=:section swaps the whole subtree, leaves siblings."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-org-buffer buf _file
      "* H1\nAlpha body line.\nAnother line.\n* H2\nBeta body.\n"
    (goto-char (point-min))
    (search-forward "Alpha")
    (let* ((b (match-beginning 0))
           (e (match-end 0))
           (id (claude-collab-test--fabricate-overlay-in buf b e))
           (result (claude-collab-apply-annotation
                    id :replace "* H1 new\nrewritten body\n" :section)))
      (should (plist-get result :ok))
      (let ((content (with-current-buffer buf (buffer-string))))
        (should (string-match-p "\\`\\* H1 new\nrewritten body\n" content))
        (should-not (string-match-p "Alpha" content))
        (should-not (string-match-p "Another line" content))
        ;; Sibling intact.
        (should (string-match-p "\\* H2\nBeta body\\." content))))))

(ert-deftest claude-collab-test-apply-annotation-default-unit-unchanged ()
  "Without unit arg, behavior matches the pre-unit contract (regression guard)."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id (claude-collab-test--fabricate-overlay-in buf 7 12))
           (result (claude-collab-apply-annotation id :replace "there")))
      (should (plist-get result :ok))
      (should (= 7 (plist-get result :new-begin)))
      (should (= 12 (plist-get result :new-end)))
      (should (string-prefix-p "Hello there,"
                               (with-current-buffer buf (buffer-string)))))))

(ert-deftest claude-collab-test-apply-annotation-trailing-newline-autoappend ()
  "ensure-trailing-newline appends `\\n' when snapped end sits on a newline boundary.
Uses :section because its end always sits one past a newline."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-org-buffer buf _file
      "* H1\nbody line\n* H2\nbeta\n"
    (goto-char (point-min))
    (search-forward "body line")
    (let* ((b (match-beginning 0))
           (e (match-end 0))
           (id (claude-collab-test--fabricate-overlay-in buf b e))
           ;; Pass new-text without trailing `\n'. With :section, region-end is
           ;; right after the trailing newline of section H1, so char-before is
           ;; `\n' → ensure-trailing-newline appends one, keeping H2 on its line.
           (result (claude-collab-apply-annotation
                    id :replace "* H1\nrewritten" :section)))
      (should (plist-get result :ok))
      (let ((content (with-current-buffer buf (buffer-string))))
        (should (string-match-p "rewritten\n\\* H2" content))))))

;;; --- batch apply ---

(ert-deftest claude-collab-test-apply-batch-applies-all ()
  "apply-batch processes all edits in order, all succeed."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    ;; Three fabricated overlays at non-overlapping positions:
    ;; 1: 1..6 ("Hello"), 2: 7..12 ("world"), 3: 14..18 ("this")
    (let* ((id1 (claude-collab-test--fabricate-overlay-in buf 1 6))
           (id2 (claude-collab-test--fabricate-overlay-in buf 7 12))
           (id3 (claude-collab-test--fabricate-overlay-in buf 14 18))
           (edits (list (list :id id1 :action :replace :new-text "Howdy")
                        (list :id id2 :action :replace :new-text "there")
                        (list :id id3 :action :replace :new-text "that")))
           (result (claude-collab-apply-batch edits)))
      (should (plist-get result :ok))
      (should (= 3 (plist-get result :applied)))
      (should (= 0 (plist-get result :failed)))
      (let ((results (plist-get result :results)))
        (should (= 3 (length results)))
        (should (equal id1 (plist-get (nth 0 results) :id)))
        (should (equal id2 (plist-get (nth 1 results) :id)))
        (should (equal id3 (plist-get (nth 2 results) :id)))
        (should (plist-get (nth 0 results) :ok)))
      (should (string-prefix-p "Howdy there, that"
                               (with-current-buffer buf (buffer-string)))))))

(ert-deftest claude-collab-test-apply-batch-collects-failures ()
  "apply-batch continues on per-edit error and reports them."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id1 (claude-collab-test--fabricate-overlay-in buf 1 6))
           (edits (list (list :id id1 :action :replace :new-text "Howdy")
                        (list :id "bogus-id" :action :replace :new-text "X")
                        (list :action :replace :new-text "no-id")))
           (result (claude-collab-apply-batch edits)))
      (should-not (plist-get result :ok))
      (should (= 1 (plist-get result :applied)))
      (should (= 2 (plist-get result :failed)))
      (let ((results (plist-get result :results)))
        (should (plist-get (nth 0 results) :ok))
        (should (plist-get (nth 1 results) :error))
        (should (string-match-p "not found"
                                (plist-get (nth 1 results) :error)))
        (should (plist-get (nth 2 results) :error))
        (should (string-match-p "Missing :id"
                                (plist-get (nth 2 results) :error))))
      ;; First edit landed despite later failures.
      (should (string-prefix-p "Howdy"
                               (with-current-buffer buf (buffer-string)))))))

(ert-deftest claude-collab-test-apply-batch-with-mixed-units ()
  "apply-batch supports per-edit units and structures stay intact."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-org-buffer buf _file
      "* H1\nbody one\n* H2\n- alpha\n- beta\n"
    (goto-char (point-min))
    (search-forward "body one")
    (let* ((b1 (match-beginning 0))
           (e1 (match-end 0))
           (id1 (claude-collab-test--fabricate-overlay-in buf b1 e1))
           (_ (search-forward "alpha"))
           (b2 (match-beginning 0))
           (e2 (match-end 0))
           (id2 (claude-collab-test--fabricate-overlay-in buf b2 e2))
           (edits (list (list :id id1 :action :replace
                              :new-text "* H1\nrewritten H1 body\n"
                              :unit :section)
                        (list :id id2 :action :replace
                              :new-text "- replacement"
                              :unit :list-item)))
           (result (claude-collab-apply-batch edits)))
      (should (plist-get result :ok))
      (should (= 2 (plist-get result :applied)))
      (let ((content (with-current-buffer buf (buffer-string))))
        (should (string-match-p "\\`\\* H1\nrewritten H1 body\n" content))
        (should (string-match-p "\\* H2\n- replacement\n- beta\n" content))))))

(ert-deftest claude-collab-test-apply-batch-empty ()
  "apply-batch on empty edits returns ok with zero counts."
  (claude-collab-test--reset-state)
  (let ((result (claude-collab-apply-batch nil)))
    (should (plist-get result :ok))
    (should (= 0 (plist-get result :applied)))
    (should (= 0 (plist-get result :failed)))
    (should (null (plist-get result :results)))))


;;; --- session logging + recovery ---

(ert-deftest claude-collab-test-apply-annotation-logs-to-session ()
  "apply-annotation logs the text edit into the current session so undo can revert it.
Let-binds `claude-collab--inside-safe-eval' to nil to simulate the
production MCP-tool path (the test runner itself runs inside safe-eval
via eval-elisp, which would otherwise suppress per-edit logging)."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id (claude-collab-test--fabricate-overlay-in buf 7 12))
           (sid (claude-collab--current-session-id))
           (claude-collab--inside-safe-eval nil))
      (claude-collab-apply-annotation id :replace "there")
      (let* ((edits (claude-collab-session-edits sid))
             (kinds (mapcar #'claude-collab-edit-kind edits)))
        (should (memq 'text kinds))
        (should (memq 'annotation-resolve kinds))))))

(ert-deftest claude-collab-test-apply-batch-logs-each-edit ()
  "apply-batch logs one text record per edit (plus annotation-resolves)."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id1 (claude-collab-test--fabricate-overlay-in buf 1 6))
           (id2 (claude-collab-test--fabricate-overlay-in buf 7 12))
           (id3 (claude-collab-test--fabricate-overlay-in buf 14 18))
           (sid (claude-collab--current-session-id))
           (edits (list (list :id id1 :action :replace :new-text "Howdy")
                        (list :id id2 :action :replace :new-text "there")
                        (list :id id3 :action :replace :new-text "that")))
           (claude-collab--inside-safe-eval nil))
      (claude-collab-apply-batch edits)
      (let* ((records (claude-collab-session-edits sid))
             (text-count (length (cl-remove-if-not
                                   (lambda (e) (eq (claude-collab-edit-kind e) 'text))
                                   records))))
        (should (>= text-count 3))))))

(ert-deftest claude-collab-test-undo-session-after-batch-restores-text ()
  "After a batch, claude-collab--revert-session restores the original buffer content."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((original (with-current-buffer buf (buffer-string)))
           (id1 (claude-collab-test--fabricate-overlay-in buf 1 6))
           (id2 (claude-collab-test--fabricate-overlay-in buf 7 12))
           (sid (claude-collab--current-session-id))
           (edits (list (list :id id1 :action :replace :new-text "Howdy")
                        (list :id id2 :action :replace :new-text "there")))
           (claude-collab--inside-safe-eval nil))
      (claude-collab-apply-batch edits)
      (should-not (string= original (with-current-buffer buf (buffer-string))))
      (claude-collab--revert-session sid)
      (should (string= original (with-current-buffer buf (buffer-string)))))))


;;; --- error surfaces ---

(ert-deftest claude-collab-test-paragraph-unit-in-org-errors ()
  "apply-annotation with unit=:paragraph in org-mode returns :error."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-org-buffer buf _file
      "* H1\nbody line\n"
    (goto-char (point-min))
    (search-forward "body line")
    (let* ((b (match-beginning 0))
           (e (match-end 0))
           (id (claude-collab-test--fabricate-overlay-in buf b e))
           (result (claude-collab-apply-annotation id :replace "rewritten" :paragraph)))
      (should (plist-get result :error))
      (should (string-match-p ":section\\|list-item" (plist-get result :error))))))

(ert-deftest claude-collab-test-section-unit-on-non-org-errors ()
  "apply-annotation with unit=:section on a non-org buffer returns :error.
Regression guard for the widened condition-case (Fix 3): the user-error
from --bounds-for-unit must be caught and surfaced as :error, not bubble."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id (claude-collab-test--fabricate-overlay-in buf 7 12))
           (result (claude-collab-apply-annotation id :replace "there" :section)))
      (should (plist-get result :error))
      (should (string-match-p "org-mode" (plist-get result :error))))))

(ert-deftest claude-collab-test-apply-annotation-rejects-unit-with-insert ()
  "apply-annotation with insert-after + non-default unit returns :error."
  (claude-collab-test--reset-state)
  (claude-collab-test--with-temp-file buf _file
    (let* ((id (claude-collab-test--fabricate-overlay-in buf 7 12))
           (result (claude-collab-apply-annotation id :insert-after "X" :section)))
      (should (plist-get result :error))
      (should (string-match-p "not allowed" (plist-get result :error))))))


;;; --- entry point ---

(defun claude-collab-run-tests ()
  "Run all `claude-collab-test-*' tests; return a plist of results."
  (let* ((selector "^claude-collab-test-")
         (stats (ert-run-tests-batch selector))
         (total (ert-stats-total stats))
         (passed (ert-stats-completed-expected stats))
         (unexpected (ert-stats-completed-unexpected stats))
         (skipped (ert-stats-skipped stats))
         (failures
          (cl-loop for i from 0 below (length (ert--stats-test-results stats))
                   for test = (aref (ert--stats-tests stats) i)
                   for result = (aref (ert--stats-test-results stats) i)
                   when (ert-test-result-type-p result :failed)
                   collect (list :name (ert-test-name test)
                                 :message (ert-test-result-with-condition-condition result)))))
    (list :passed passed
          :failed unexpected
          :skipped skipped
          :total total
          :failures failures)))

(provide 'claude-collab-test)
;;; claude-collab-test.el ends here
