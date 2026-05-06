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


;;; Content-addressed anchors
;;
;; The annotation system today identifies a highlighted region by its
;; byte position in the source buffer (`:org-remark-beg' /
;; `:org-remark-end' in marginalia.org). Byte positions drift the
;; moment any edit lands earlier in the buffer — that's the structural
;; cause of the /design revise drift incident, where multiple
;; `apply-annotation' calls in sequence saw the second/third edit land
;; inside `:verify:' lines instead of the CLARIFY blocks they were
;; anchored to.
;;
;; Idiom borrowed from `bookmark.el' (`front-context-string' /
;; `rear-context-string' — battle-tested 30 years): an anchor is
;; identified by its text + the N characters immediately before and
;; after. Locating an anchor in a fresh source string is then a string
;; search, not a position lookup. Byte positions are derived state,
;; recomputed each time we want to apply an edit.
;;
;; The algorithm here is strict-match: text exact + context exact.
;; Fuzzy fallback (Levenshtein-scored candidates) is intentionally
;; deferred — strict matching catches the drift class structurally,
;; and "the source no longer contains exactly this text in exactly
;; this surrounding" is a clean diagnostic that an agent can act on.

(cl-defstruct (claude-collab-core-anchor
               (:constructor claude-collab-core-anchor-create)
               (:copier nil))
  "Content-addressed handle on a region within a source document.

Slots:
- TEXT             the highlighted span (string)
- CONTEXT-BEFORE   N characters immediately before TEXT in the
                   source-at-marking-time (string, may be empty when
                   the anchor sits at the start of the document)
- CONTEXT-AFTER    N characters immediately after TEXT (string, may be
                   empty at end of document)
- OCCURRENCE       1-based ordinal for non-unique TEXTs; the strict
                   match algorithm doesn't use this today, but it is
                   reserved for the fallback path (`text+occurrence'
                   with no context, used when context is unavailable)"
  text
  (context-before "")
  (context-after "")
  (occurrence 1))

(cl-defstruct (claude-collab-core-region
               (:constructor claude-collab-core-region-create)
               (:copier nil))
  "Half-open buffer-position pair, derived state.

Slots:
- BEGIN  inclusive 0-indexed byte offset into the source string
- END    exclusive offset (so END - BEGIN == length of the region)

These are *not* identity. They are produced by `locate-anchor' from
the current source and the (stable) anchor; they should be recomputed
on every edit boundary, never cached past a buffer mutation."
  begin end)


;;; Anchor location

(defun claude-collab-core--find-all-occurrences (source text)
  "Return a list of 0-indexed positions where TEXT begins in SOURCE.
Empty TEXT yields nil — we don't index zero-length needles."
  (when (and (stringp source) (stringp text) (not (string-empty-p text)))
    (let ((positions nil)
          (pos 0)
          found)
      (while (setq found (string-search text source pos))
        (push found positions)
        (setq pos (1+ found)))
      (nreverse positions))))

(defun claude-collab-core--context-matches-p
    (source position text-len context-before context-after)
  "Non-nil if SOURCE has CONTEXT-BEFORE immediately before POSITION and
CONTEXT-AFTER immediately after POSITION+TEXT-LEN. Empty context strings
are treated as wildcards (always match)."
  (let ((cb-len (length context-before))
        (ca-len (length context-after))
        (src-len (length source)))
    (and
     ;; Context-before matches, or is empty.
     (or (zerop cb-len)
         (and (>= position cb-len)
              (string= (substring source (- position cb-len) position)
                       context-before)))
     ;; Context-after matches, or is empty.
     (or (zerop ca-len)
         (let ((after-start (+ position text-len))
               (after-end (+ position text-len ca-len)))
           (and (<= after-end src-len)
                (string= (substring source after-start after-end)
                         context-after)))))))

(defun claude-collab-core-locate-anchor (source anchor)
  "Locate ANCHOR within SOURCE.

Returns one of:

  (:ok REGION)
    Single match: TEXT occurs in SOURCE and the surrounding context
    (or absence of context if both context strings are empty) matches.

  (:error :not-found POSITIONS)
    TEXT does not occur in SOURCE at all. POSITIONS is nil.

  (:error :ambiguous REGIONS)
    TEXT occurs more than once after applying the context filter; the
    anchor cannot be uniquely resolved. REGIONS lists every plain-text
    occurrence so callers can present alternatives.

When ANCHOR has empty CONTEXT-BEFORE *and* empty CONTEXT-AFTER, the
disambiguation step is a no-op — multiple text matches will always
return `:ambiguous'. Populating context is the caller's job at marking
time."
  (let* ((text (claude-collab-core-anchor-text anchor))
         (ctx-before (or (claude-collab-core-anchor-context-before anchor) ""))
         (ctx-after (or (claude-collab-core-anchor-context-after anchor) ""))
         (text-len (length text))
         (occurrences (claude-collab-core--find-all-occurrences source text))
         (filtered
          (cl-remove-if-not
           (lambda (pos)
             (claude-collab-core--context-matches-p
              source pos text-len ctx-before ctx-after))
           occurrences)))
    (cond
     ((null occurrences)
      (list :error :not-found nil))
     ((= 1 (length filtered))
      (list :ok
            (claude-collab-core-region-create
             :begin (car filtered)
             :end (+ (car filtered) text-len))))
     (t
      (list :error :ambiguous
            (mapcar (lambda (pos)
                      (claude-collab-core-region-create
                       :begin pos
                       :end (+ pos text-len)))
                    occurrences))))))


;;; Drift detection (precondition for safe apply)

(defun claude-collab-core-detect-drift (source anchor)
  "Return :clean if ANCHOR resolves to a unique region in SOURCE,
otherwise return (:drifted :reason KIND :diagnosis PLIST).

KIND is one of:
- :not-found     the anchor's text doesn't appear in SOURCE
- :ambiguous     the anchor's text appears more than once and context
                 (if any) doesn't disambiguate

This is the canonical guard. Adapter code should call this *before*
mutating; if it returns `:drifted', the buffer state has changed since
the annotation was created and applying an edit on stored byte
positions would corrupt the file (the original drift bug)."
  (pcase (claude-collab-core-locate-anchor source anchor)
    (`(:ok ,_) :clean)
    (`(:error :not-found ,_)
     (list :drifted :reason :not-found :diagnosis nil))
    (`(:error :ambiguous ,candidates)
     (list :drifted
           :reason :ambiguous
           :diagnosis (list :candidates candidates)))))


;;; Marginalia bridge

(defun claude-collab-core-anchor-from-marginalia (plist)
  "Build a `claude-collab-core-anchor' from a marginalia annotation PLIST.

PLIST is the shape returned by `claude-collab--annotations-in-buffer':
   (:id ID :file F :begin B :end E :text T :label L)

Only the `:text' field is required (it becomes the anchor's text).
Optional `:context-before' and `:context-after' keys, if present, are
copied through; otherwise the anchor gets empty-string context (text-
only matching, with `:ambiguous' returned if the text isn't unique).

Marginalia today does not store context — adapter code is expected to
either populate context at annotation creation time (richer marginalia
schema, future commit) or accept text-only matching for legacy
annotations."
  (claude-collab-core-anchor-create
   :text           (or (plist-get plist :text) "")
   :context-before (or (plist-get plist :context-before) "")
   :context-after  (or (plist-get plist :context-after) "")
   :occurrence     (or (plist-get plist :occurrence) 1)))


(provide 'claude-collab-core)

;;; claude-collab-core.el ends here
