;;; claude-collab-test.el --- ERT suite for claude-collab -*- lexical-binding: t -*-
;;
;; Runs via (claude-collab-run-tests) — the MCP tool
;; `claude-collab-run-tests' wraps this so Claude can drive the suite
;; autonomously via eval-elisp. Returns a plist
;; (:passed N :failed N :failures (...)) for parseable output.

(require 'ert)
(require 'cl-lib)

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
Routes through `mcp-server-security-safe-eval' so the advice fires."
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
