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

(ert-deftest claude-collab-test-apply-annotation-replace ()
  "apply-annotation :replace swaps the annotated region and auto-resolves."
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
