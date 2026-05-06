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

;;; claude-collab-core-test.el ends here
