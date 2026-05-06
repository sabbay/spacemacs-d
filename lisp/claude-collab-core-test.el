;;; claude-collab-core-test.el --- ERT suite for claude-collab-core -*- lexical-binding: t -*-

;; Pure ERT suite for `claude-collab-core'. Runs in a clean Emacs
;; (eldev / batch CI) without buffers, files, or any UI dependency.
;; If a test in this file needs `with-temp-buffer' or any Emacs state
;; outside the core values, it belongs in `claude-collab-test.el'
;; (the integration suite) instead.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-collab-core)


;;; --- string utilities ---

(ert-deftest claude-collab-core-test-common-prefix-length-empty ()
  (should (= 0 (claude-collab-core--common-prefix-length "" "")))
  (should (= 0 (claude-collab-core--common-prefix-length "abc" "")))
  (should (= 0 (claude-collab-core--common-prefix-length "" "xyz"))))

(ert-deftest claude-collab-core-test-common-prefix-length-shared ()
  (should (= 3 (claude-collab-core--common-prefix-length "hello" "help")))
  (should (= 5 (claude-collab-core--common-prefix-length "hello" "hello")))
  (should (= 0 (claude-collab-core--common-prefix-length "abc" "xyz"))))

(ert-deftest claude-collab-core-test-common-suffix-length ()
  (should (= 0 (claude-collab-core--common-suffix-length "" "")))
  (should (= 3 (claude-collab-core--common-suffix-length "abcxyz" "ttxyz")))
  (should (= 0 (claude-collab-core--common-suffix-length "abc" "xyz")))
  (should (= 5 (claude-collab-core--common-suffix-length "hello" "hello"))))


;;; --- argument normalization ---

(ert-deftest claude-collab-core-test-normalize-action ()
  (should (eq :replace (claude-collab-core-normalize-action :replace)))
  (should (eq :replace (claude-collab-core-normalize-action 'replace)))
  (should (eq :replace (claude-collab-core-normalize-action "replace")))
  (should (eq :replace (claude-collab-core-normalize-action ":replace")))
  (should-error (claude-collab-core-normalize-action 42)))

(ert-deftest claude-collab-core-test-normalize-unit-default ()
  (should (eq :annotation (claude-collab-core-normalize-unit nil)))
  (should (eq :annotation (claude-collab-core-normalize-unit "")))
  (should (eq :annotation (claude-collab-core-normalize-unit :annotation))))

(ert-deftest claude-collab-core-test-normalize-unit-variants ()
  (should (eq :line (claude-collab-core-normalize-unit "line")))
  (should (eq :section (claude-collab-core-normalize-unit 'section)))
  (should-error (claude-collab-core-normalize-unit 99)))


;;; --- batch edit arg lookup ---

(ert-deftest claude-collab-core-test-batch-edit-arg-plist ()
  (should (equal "abc"
                 (claude-collab-core-batch-edit-arg
                  '(:id "abc" :action :replace) :id))))

(ert-deftest claude-collab-core-test-batch-edit-arg-symbol-alist ()
  (should (equal "abc"
                 (claude-collab-core-batch-edit-arg
                  '((id . "abc") (action . replace)) :id))))

(ert-deftest claude-collab-core-test-batch-edit-arg-string-alist ()
  ;; The MCP wire layer sometimes hands us alist-with-string-keys
  ;; depending on which JSON parser materialized it.
  (should (equal "abc"
                 (claude-collab-core-batch-edit-arg
                  '(("id" . "abc") ("action" . "replace")) :id))))

(ert-deftest claude-collab-core-test-batch-edit-arg-missing ()
  (should (null (claude-collab-core-batch-edit-arg '(:id "x") :missing))))


;;; --- prin1 with caps disabled ---

(ert-deftest claude-collab-core-test-prin1-no-truncation ()
  ;; Spacemacs sets print-length=10. A 12-element plist would lose
  ;; its tail under naive `(format \"%S\" …)'. Core-prin1 must show
  ;; everything regardless of ambient caps.
  (let ((print-length 10)
        (print-level 5)
        (long-plist '(:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8)))
    (let ((result (claude-collab-core-prin1 long-plist)))
      (should-not (string-match-p "\\.\\.\\." result))
      (should (string-match-p ":h 8" result)))))

(ert-deftest claude-collab-core-test-prin1-roundtrip ()
  (let* ((data '(:id "x" :nested (:a (:b (:c (:d 4)))) :tail "ok"))
         (printed (claude-collab-core-prin1 data))
         (parsed (read printed)))
    (should (equal data parsed))))

;;; --- anchor location ---

(defun claude-collab-core-test--anchor (text &optional before after)
  "Helper: build a cc-anchor with optional context."
  (claude-collab-core-anchor-create
   :text text
   :context-before (or before "")
   :context-after  (or after "")))

(ert-deftest claude-collab-core-test-locate-anchor-unique-match ()
  "A text that appears once resolves to a single region."
  (let* ((source "Hello, world! Goodbye.")
         (anchor (claude-collab-core-test--anchor "world"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :ok (car result)))
    (let ((region (cadr result)))
      (should (= 7 (claude-collab-core-region-begin region)))
      (should (= 12 (claude-collab-core-region-end region))))))

(ert-deftest claude-collab-core-test-locate-anchor-not-found ()
  "Missing text returns :error :not-found with no candidates."
  (let* ((source "Hello, world!")
         (anchor (claude-collab-core-test--anchor "absent"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (equal '(:error :not-found nil) result))))

(ert-deftest claude-collab-core-test-locate-anchor-ambiguous-no-context ()
  "Multiple text matches with no context return :error :ambiguous
listing every occurrence."
  (let* ((source "abc abc abc")
         (anchor (claude-collab-core-test--anchor "abc"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :error (car result)))
    (should (eq :ambiguous (cadr result)))
    (should (= 3 (length (caddr result))))
    (should (equal '(0 4 8)
                   (mapcar #'claude-collab-core-region-begin (caddr result))))))

(ert-deftest claude-collab-core-test-locate-anchor-context-disambiguates ()
  "Two text occurrences, only one with matching context = unique resolution.
This is the load-bearing case — the original drift bug existed because
no equivalent disambiguation existed."
  (let* ((source "left abc right; left abc wrong")
         (anchor (claude-collab-core-test--anchor "abc" "left " " right"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :ok (car result)))
    (should (= 5 (claude-collab-core-region-begin (cadr result))))))

(ert-deftest claude-collab-core-test-locate-anchor-at-bof ()
  "Anchor at the start of the source — empty context-before is fine."
  (let* ((source "FIRST then second")
         (anchor (claude-collab-core-test--anchor "FIRST" "" " then"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :ok (car result)))
    (should (= 0 (claude-collab-core-region-begin (cadr result))))))

(ert-deftest claude-collab-core-test-locate-anchor-at-eof ()
  "Anchor at the very end — empty context-after is fine."
  (let* ((source "alpha beta GAMMA")
         (anchor (claude-collab-core-test--anchor "GAMMA" "beta " ""))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :ok (car result)))
    (should (= 11 (claude-collab-core-region-begin (cadr result))))))

(ert-deftest claude-collab-core-test-locate-anchor-multiline-text ()
  "Anchor whose text spans newlines locates correctly."
  (let* ((source "line one\nline two\nline three")
         (anchor (claude-collab-core-test--anchor "one\nline" "line " " two"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (eq :ok (car result)))
    (should (= 5 (claude-collab-core-region-begin (cadr result))))))

(ert-deftest claude-collab-core-test-locate-anchor-context-shifted ()
  "When context doesn't match anywhere, ambiguous text falls through
to the ambiguous error (still reports all text occurrences for triage)."
  (let* ((source "left abc one; left abc two")
         (anchor (claude-collab-core-test--anchor "abc" "WRONG-CTX " " right"))
         (result (claude-collab-core-locate-anchor source anchor)))
    ;; Both occurrences fail the context filter, so the filtered list is
    ;; empty — still classified ambiguous since multiple text occurrences
    ;; exist (the agent should see the candidates list to pick one).
    (should (eq :error (car result)))
    (should (eq :ambiguous (cadr result)))))

(ert-deftest claude-collab-core-test-locate-anchor-empty-source ()
  "Empty source string = not found."
  (let* ((source "")
         (anchor (claude-collab-core-test--anchor "x"))
         (result (claude-collab-core-locate-anchor source anchor)))
    (should (equal '(:error :not-found nil) result))))


;;; --- drift detection ---

(ert-deftest claude-collab-core-test-detect-drift-clean ()
  "Anchor located uniquely → :clean."
  (let* ((source "the quick brown fox")
         (anchor (claude-collab-core-test--anchor "brown")))
    (should (eq :clean (claude-collab-core-detect-drift source anchor)))))

(ert-deftest claude-collab-core-test-detect-drift-not-found ()
  "Anchor's text deleted → :drifted :reason :not-found."
  (let* ((source "the quick brown fox")
         (anchor (claude-collab-core-test--anchor "missing"))
         (result (claude-collab-core-detect-drift source anchor)))
    (should (eq :drifted (car result)))
    (should (eq :not-found (plist-get (cdr result) :reason)))))

(ert-deftest claude-collab-core-test-detect-drift-ambiguous ()
  "Anchor's text duplicated and no context → :drifted :reason :ambiguous,
with candidates included in :diagnosis."
  (let* ((source "go go go")
         (anchor (claude-collab-core-test--anchor "go"))
         (result (claude-collab-core-detect-drift source anchor)))
    (should (eq :drifted (car result)))
    (should (eq :ambiguous (plist-get (cdr result) :reason)))
    (let ((candidates (plist-get (plist-get (cdr result) :diagnosis) :candidates)))
      (should (= 3 (length candidates))))))


;;; --- marginalia bridge ---

(ert-deftest claude-collab-core-test-anchor-from-marginalia-text-only ()
  "Marginalia plist with only :text yields anchor with empty context."
  (let* ((plist '(:id "abc" :text "hello world" :begin 7 :end 18))
         (anchor (claude-collab-core-anchor-from-marginalia plist)))
    (should (equal "hello world" (claude-collab-core-anchor-text anchor)))
    (should (equal "" (claude-collab-core-anchor-context-before anchor)))
    (should (equal "" (claude-collab-core-anchor-context-after anchor)))))

(ert-deftest claude-collab-core-test-anchor-from-marginalia-with-context ()
  "Optional :context-before / :context-after are picked up when present."
  (let* ((plist '(:text "x" :context-before "AAA" :context-after "BBB"))
         (anchor (claude-collab-core-anchor-from-marginalia plist)))
    (should (equal "AAA" (claude-collab-core-anchor-context-before anchor)))
    (should (equal "BBB" (claude-collab-core-anchor-context-after anchor)))))

(ert-deftest claude-collab-core-test-anchor-from-marginalia-roundtrip ()
  "Anchor → plist → anchor is structurally equivalent (text + context)."
  (let* ((original (claude-collab-core-anchor-create
                    :text "v" :context-before "L" :context-after "R"))
         (plist (list :text (claude-collab-core-anchor-text original)
                      :context-before (claude-collab-core-anchor-context-before original)
                      :context-after (claude-collab-core-anchor-context-after original)))
         (round (claude-collab-core-anchor-from-marginalia plist)))
    (should (equal (claude-collab-core-anchor-text original)
                   (claude-collab-core-anchor-text round)))
    (should (equal (claude-collab-core-anchor-context-before original)
                   (claude-collab-core-anchor-context-before round)))))

;;; claude-collab-core-test.el ends here
