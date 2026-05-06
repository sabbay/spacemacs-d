;;; claude-collab-core.el --- Pure core for claude-collab -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; Side-effect-free domain logic for `claude-collab'. Every function in
;; this file takes data and returns data — no `with-current-buffer', no
;; `find-file-noselect', no `overlay-*', no `save-buffer', no `message'.
;; The point isn't dogma; it's that bugs in domain logic should be
;; reproducible from a string and a struct, in batch mode, without
;; needing an interactive Emacs session or a marginalia file on disk.
;;
;; The adapter (`claude-collab.el') is the bridge: it reads buffer
;; state, calls into here, writes the result back. If a function takes
;; or returns a buffer/overlay/marker, it stays in the adapter.

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'seq)
(require 'subr-x)


;;; String utilities

(defun claude-collab-core--common-prefix-length (a b)
  "Length of the common leading substring of strings A and B."
  (let ((i 0) (cap (min (length a) (length b))))
    (while (and (< i cap) (eq (aref a i) (aref b i)))
      (cl-incf i))
    i))

(defun claude-collab-core--common-suffix-length (a b)
  "Length of the common trailing substring of strings A and B."
  (let ((i 0) (la (length a)) (lb (length b))
        (cap (min (length a) (length b))))
    (while (and (< i cap)
                (eq (aref a (- la 1 i))
                    (aref b (- lb 1 i))))
      (cl-incf i))
    i))


;;; Argument normalization

(defun claude-collab-core-normalize-action (action)
  "Normalize ACTION (symbol, keyword, or string) to a keyword."
  (cond
   ((keywordp action) action)
   ((symbolp action) (intern (concat ":" (symbol-name action))))
   ((stringp action)
    (intern (if (string-prefix-p ":" action) action (concat ":" action))))
   (t (error "Invalid action: %S" action))))

(defun claude-collab-core-normalize-unit (unit)
  "Normalize UNIT (symbol, keyword, string, or nil) to a keyword.
Defaults to :annotation when UNIT is nil or an empty string."
  (cond
   ((null unit) :annotation)
   ((keywordp unit) unit)
   ((symbolp unit) (intern (concat ":" (symbol-name unit))))
   ((stringp unit)
    (if (string-empty-p unit)
        :annotation
      (intern (if (string-prefix-p ":" unit) unit (concat ":" unit)))))
   (t (error "Invalid unit: %S" unit))))


;;; Edit-record argument lookup

(defun claude-collab-core-batch-edit-arg (edit key)
  "Look up KEY in EDIT, accepting plist, alist with symbol keys, or alist
with string keys (depending on JSON parser of the MCP transport)."
  (cond
   ((plist-member edit key) (plist-get edit key))
   (t
    (let ((sym (intern (substring (symbol-name key) 1))))
      (or (alist-get sym edit)
          (alist-get (symbol-name sym) edit nil nil #'equal))))))


;;; Serialization

(defun claude-collab-core-prin1 (sexp)
  "Serialize SEXP as a `prin1' string with no length/depth caps.
The default Spacemacs profile sets `print-length' and `print-level' to
10, which truncates plists with more than 10 elements (each annotation
plist has 12, so the trailing `:label' silently becomes `...'). MCP
clients eat the printed sexp as text — truncation there is a real bug,
not a debugger nicety. Every site in claude-collab that emits a
result over the wire or to a log goes through this function."
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-newlines t))
    (prin1-to-string sexp)))


(provide 'claude-collab-core)

;;; claude-collab-core.el ends here
