;;; monday-docs-sync.el --- One-way sync of org files to Monday docs -*- lexical-binding: t; -*-

;; Push the current org buffer to a Monday doc identified by a
;; `#+MONDAY_DOC:' file-level keyword.  One-way (org → Monday).
;;
;; Pipeline (matches the plan steps):
;;   2. resolve the target doc from the `#+MONDAY_DOC:' URL
;;   3. walk the org AST into an intermediate block list
;;   4. map intermediate blocks → Monday GraphQL payloads
;;   5. force-render PlantUML / Excalidraw diagrams, gather PNGs/SVGs
;;   6. upload images, call `create_doc_block' / `delete_doc_block'
;;   7. orchestrator: `M-x monday-docs-sync' on the current buffer
;;
;; Plan: ~/Development/github-actions-shared/plans/2026-04-22-org-to-monday-docs-one-way-sync.org
;;
;; Open questions (see plan) that may require adjustments to the API
;; layer once verified against the live endpoint:
;;   - does Monday's image block accept SVG directly, or PNG only?
;;   - exact `create_doc_block' content-JSON schema per block type?
;; Both are isolated to `monday-docs-sync--content-for' and
;; `monday-docs-sync--upload-file' — adjust there without touching
;; parsing / mapping.

;;; Code:

(require 'org)
(require 'org-element)
(require 'json)
(require 'subr-x)

(declare-function plz "plz" (method url &rest args))
(declare-function spacemacs/set-leader-keys "spacemacs")
(declare-function spacemacs/declare-prefix "spacemacs")
(declare-function org-babel-execute-src-block "ob-core")

;; ---- Customization --------------------------------------------------

(defgroup monday-docs-sync nil
  "One-way sync of org files to Monday docs."
  :group 'org
  :prefix "monday-docs-sync-")

(defcustom monday-docs-sync-api-token nil
  "Monday.com API token.

When nil, falls back to the `MONDAY_API_TOKEN' environment variable —
the same variable used by the `monday-twin' project, so a single
credential serves both tools."
  :type '(choice (const :tag "Use $MONDAY_API_TOKEN" nil) string)
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-api-endpoint "https://api.monday.com/v2"
  "Main GraphQL endpoint for Monday (JSON body)."
  :type 'string
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-file-endpoint "https://api.monday.com/v2/file"
  "Multipart file-upload endpoint for Monday.

Monday's main GraphQL endpoint only accepts JSON; file uploads per the
GraphQL multipart request spec must go to a dedicated `/file' endpoint
or the server responds with \"Request body must be a JSON with query\"."
  :type 'string
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-readonly-notice
  "⚠️ Auto-synced from org — do not edit. Edits here will be overwritten on next sync."
  "Notice block prepended to every synced Monday doc."
  :type 'string
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-force-render t
  "When non-nil, re-render every diagram before sync.

Prevents shipping a stale PNG/SVG when the source block has been
edited but not yet re-executed."
  :type 'boolean
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-svg-to-png-command
  (when (executable-find "rsvg-convert") "rsvg-convert")
  "External command that converts SVG → PNG.

Invoked as `CMD -o OUT.png IN.svg'.  When nil, SVGs are uploaded as-is
and Monday is expected to handle them.  Install with
`brew install librsvg' to populate the default."
  :type '(choice (const :tag "Upload SVG as-is" nil) string)
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-upload-target nil
  "Cons cell (ITEM-ID . FILE-COLUMN-ID) where diagram images get hosted.

Monday has no \"upload an image to a doc\" API; images must live as
assets on some item's file column, and the doc then references the
returned asset URL.  Pick any item on a board with a file column and
set this variable to (\"<item-id>\" . \"<column-id>\").

When nil, image blocks are replaced in the synced doc with a text
placeholder noting the missing upload target — the rest of the sync
still completes."
  :type '(choice (const :tag "Skip images" nil)
                 (cons (string :tag "Item ID") (string :tag "File column ID")))
  :group 'monday-docs-sync)

(defcustom monday-docs-sync-max-blocks nil
  "Sync at most this many blocks (including the notice) from the org file.
Useful during development to avoid expensive deletes + full writes on
every iteration.  When nil, sync every block."
  :type '(choice (const :tag "Unlimited" nil) integer)
  :group 'monday-docs-sync)

;; ---- Token + endpoint helpers ---------------------------------------

(defun monday-docs-sync--token ()
  "Return the Monday API token, or signal a user error."
  (or monday-docs-sync-api-token
      (getenv "MONDAY_API_TOKEN")
      (user-error "No Monday API token: set `monday-docs-sync-api-token' or $MONDAY_API_TOKEN")))

;; ---- Step 2: target resolution --------------------------------------

(defun monday-docs-sync--doc-url-from-keyword ()
  "Return the `#+MONDAY_DOC:' keyword value in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+MONDAY_DOC:[ \t]*\\(.+\\)$" nil t)
      (string-trim (match-string-no-properties 1)))))

(defun monday-docs-sync--board-id-from-keyword ()
  "Return the numeric board id from the `#+MONDAY_BOARD:' keyword, or nil.
Accepts either a bare board id (e.g. \"18408375080\") or a full Monday
board URL — in both cases we extract the leading run of digits."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+MONDAY_BOARD:[ \t]*\\(.+\\)$" nil t)
      (let ((raw (match-string-no-properties 1)))
        (when (string-match "[0-9]+" raw)
          (match-string 0 raw))))))

(defun monday-docs-sync--doc-id-from-url (url)
  "Extract Monday doc ID from URL.

Accepts monday.com URLs of the forms
  https://<subdomain>.monday.com/docs/<id>
  https://<subdomain>.monday.com/docs/<id>?...
  https://<subdomain>.monday.com/docs/<id>#...

Signals a `user-error' on malformed input."
  (unless (and url (not (string-empty-p url)))
    (user-error "Empty Monday doc URL"))
  (if (string-match "monday\\.com/docs/\\([0-9]+\\)" url)
      (match-string 1 url)
    (user-error "Can't parse Monday doc ID from URL: %s" url)))

(defun monday-docs-sync--resolve-target ()
  "Return the target doc ID for the current buffer.  Signal on failure."
  (let ((url (monday-docs-sync--doc-url-from-keyword)))
    (unless url
      (user-error "Missing #+MONDAY_DOC: keyword in this buffer"))
    (monday-docs-sync--doc-id-from-url url)))

;; ---- Step 3: org AST → intermediate blocks --------------------------

;; Each intermediate block is an alist with a `:type' key:
;;
;;   (:type heading   :level N :text "..." :runs [...])
;;   (:type paragraph :runs [...])
;;   (:type code      :language "..." :text "...")
;;   (:type plantuml  :text "..." :file "/abs/path.png")
;;   (:type image     :path "/abs/path.{png,svg,jpg,...}")
;;
;; `:runs' is a vector of inline runs: (:text "..." :bold t :italic nil :code nil).

(defun monday-docs-sync--image-path-p (path)
  "Non-nil if PATH looks like an image or rendered diagram file."
  (and (stringp path)
       (string-match-p "\\.\\(png\\|jpe?g\\|gif\\|svg\\|webp\\|excalidraw\\)\\'"
                       (downcase path))))

(defun monday-docs-sync--inline-text (el)
  "Flatten inline EL's contents to a plain string."
  (substring-no-properties
   (mapconcat (lambda (c) (if (stringp c) c (monday-docs-sync--inline-text c)))
              (org-element-contents el) "")))

(defun monday-docs-sync--collect-inline (el)
  "Return a vector of inline runs for paragraph-like element EL."
  (let (runs)
    (org-element-map el '(plain-text bold italic code verbatim link)
      (lambda (child)
        (let ((type (org-element-type child)))
          (cond
           ((eq type 'plain-text)
            (push (list :text (substring-no-properties child)) runs))
           ((eq type 'bold)
            (push (list :text (monday-docs-sync--inline-text child) :bold t) runs))
           ((eq type 'italic)
            (push (list :text (monday-docs-sync--inline-text child) :italic t) runs))
           ((memq type '(code verbatim))
            (push (list :text (substring-no-properties
                               (or (org-element-property :value child) ""))
                        :code t)
                  runs))
           ((eq type 'link)
            (let ((desc (and (org-element-contents child)
                             (monday-docs-sync--inline-text child))))
              (push (list :text (or (and (not (string-empty-p (or desc "")))
                                         desc)
                                    (org-element-property :raw-link child))
                          :link (org-element-property :raw-link child))
                    runs))))))
      nil nil '(bold italic link))
    (vconcat (nreverse runs))))

(defun monday-docs-sync--image-link-path (link)
  "If LINK is a file/excalidraw link pointing at an image, return absolute path."
  (let ((type (org-element-property :type link))
        (path (org-element-property :path link)))
    (when (and path (member type '("file" "excalidraw"))
               (monday-docs-sync--image-path-p path))
      (expand-file-name path))))

(defun monday-docs-sync--paragraph-only-link (el)
  "Return a single image link element when EL is whitespace + one such link."
  (let ((contents (org-element-contents el))
        link extras)
    (dolist (c contents)
      (cond
       ((and (stringp c) (string-match-p "\\`[ \t\n]*\\'" c)) nil) ; whitespace only
       ((and (eq (org-element-type c) 'link)
             (monday-docs-sync--image-link-path c))
        (if link (setq extras t) (setq link c)))
       (t (setq extras t))))
    (and link (not extras) link)))

(defun monday-docs-sync--parse-buffer ()
  "Walk the current org buffer into a list of intermediate blocks."
  (let* ((tree (org-element-parse-buffer))
         (blocks '())
         ;; Collect every :file target emitted by a PlantUML src-block
         ;; so we can de-dup the `#+RESULTS: [[file:…]]' paragraph that
         ;; org-babel writes below each executed block.  Without this
         ;; filter, every diagram would upload twice.
         (diagram-files
          (let (acc)
            (org-element-map tree 'src-block
              (lambda (el)
                (when (equal (org-element-property :language el) "plantuml")
                  (let* ((params (org-element-property :parameters el))
                         (args (and params
                                    (org-babel-parse-header-arguments params)))
                         (file (cdr (assq :file args))))
                    (when file (push (expand-file-name file) acc))))))
            acc)))
    (org-element-map tree '(headline paragraph src-block)
      (lambda (el)
        (pcase (org-element-type el)
          (`headline
           (push (list :type 'heading
                       :level (org-element-property :level el)
                       :text (substring-no-properties
                              (org-element-property :raw-value el)))
                 blocks))
          (`src-block
           (let* ((lang (or (org-element-property :language el) ""))
                  (value (or (org-element-property :value el) ""))
                  (args (org-babel-parse-header-arguments
                         (org-element-property :parameters el)))
                  (file (cdr (assq :file args))))
             (cond
              ((string= lang "plantuml")
               (push (list :type 'plantuml
                           :text value
                           :file (and file (expand-file-name file)))
                     blocks))
              (t
               (push (list :type 'code :language lang :text value) blocks)))))
          (`paragraph
           (let* ((image-link (monday-docs-sync--paragraph-only-link el))
                  (path (and image-link
                             (monday-docs-sync--image-link-path image-link))))
             (cond
              ((and path (member path diagram-files))
               ;; Skip — this is the RESULTS echo of a PlantUML block
               ;; we've already captured above.
               nil)
              (image-link
               (push (list :type 'image :path path) blocks))
              (t
               (let ((runs (monday-docs-sync--collect-inline el)))
                 (when (> (length runs) 0)
                   (push (list :type 'paragraph :runs runs) blocks)))))))))
      nil nil '(property-drawer))
    (nreverse blocks)))

;; ---- Step 4: intermediate blocks → Monday GraphQL content -----------

(defun monday-docs-sync--runs-to-delta (runs)
  "Convert inline RUNS to Monday's delta-format content.

NOTE: the exact JSON shape for `normal_text' / `large_title' etc. is
the Monday-documented `deltaFormat'-style payload.  If the live API
rejects this shape, adjust here — parsing above is unaffected."
  (let ((ops (mapcar
              (lambda (run)
                (let* ((text (plist-get run :text))
                       (attrs (list)))
                  (when (plist-get run :bold)   (push (cons 'bold t) attrs))
                  (when (plist-get run :italic) (push (cons 'italic t) attrs))
                  (when (plist-get run :code)   (push (cons 'code t) attrs))
                  (when (plist-get run :link)
                    (push (cons 'link (plist-get run :link)) attrs))
                  (if attrs
                      (list (cons 'insert text) (cons 'attributes attrs))
                    (list (cons 'insert text)))))
              (append runs nil))))
    (list (cons 'alignment "left")
          (cons 'direction "ltr")
          (cons 'deltaFormat (vconcat ops)))))

(defun monday-docs-sync--heading-type (level)
  "Return the Monday doc block type for heading LEVEL."
  (pcase level
    (1 "large_title")
    (2 "medium_title")
    (_ "small_title")))

(defun monday-docs-sync--notice-block ()
  "Return the read-only notice as an intermediate block."
  (list :type 'paragraph
        :runs (vector (list :text monday-docs-sync-readonly-notice :italic t))))

(defun monday-docs-sync--block->monday (block)
  "Convert intermediate BLOCK to a plist of (:type TYPE :content ALIST).

Returns nil for blocks that can't be directly represented (e.g. images
before the asset has been uploaded — those are patched in by
`monday-docs-sync--run'.)"
  (pcase (plist-get block :type)
    (`heading
     (list :type (monday-docs-sync--heading-type (plist-get block :level))
           :content (monday-docs-sync--runs-to-delta
                     (vector (list :text (plist-get block :text))))))
    (`paragraph
     (list :type "normal_text"
           :content (monday-docs-sync--runs-to-delta (plist-get block :runs))))
    (`code
     ;; Monday's `code' block content only accepts deltaFormat; attaching
     ;; a `language' property triggers "unrecognized property".  Emit the
     ;; language as a leading annotation inside the delta so the info
     ;; isn't lost.
     (let* ((lang (plist-get block :language))
            (prefix (when (and lang (not (string-empty-p lang)))
                      (format "# %s\n" lang)))
            (text (concat prefix (plist-get block :text))))
       (list :type "code"
             :content (list (cons 'deltaFormat
                                  (vector (list (cons 'insert text))))))))
    ((or `plantuml `image)
     ;; Placeholder — actual payload built during `monday-docs-sync--run'
     ;; after the asset is uploaded (since we need the asset id).
     (list :type "image" :content nil :pending-upload block))))

;; ---- Step 5: diagram rendering --------------------------------------

(defun monday-docs-sync--png-fresh-p (png-path)
  "Return non-nil when PNG-PATH exists and is newer than the current buffer's file."
  (and png-path
       (file-readable-p png-path)
       (let ((org-file (buffer-file-name)))
         (or (null org-file)
             (time-less-p (file-attribute-modification-time (file-attributes org-file))
                          (file-attribute-modification-time (file-attributes png-path)))))))

(defun monday-docs-sync--collect-stale-plantuml ()
  "Return a list of (BODY . OUTFILE) for PlantUML blocks whose PNG is stale.

Fresh blocks (PNG newer than org file) are omitted, so repeat syncs
skip straight to the HTTP pipeline."
  (let (out)
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (el)
        (when (equal (org-element-property :language el) "plantuml")
          (let* ((params (org-element-property :parameters el))
                 (args (and params (org-babel-parse-header-arguments params)))
                 (file (cdr (assq :file args)))
                 (outfile (and file (expand-file-name file)))
                 (body (org-element-property :value el)))
            (when (and outfile body
                       (not (monday-docs-sync--png-fresh-p outfile)))
              (push (cons body outfile) out))))))
    (nreverse out)))

(defun monday-docs-sync--render-plantuml-async (body outfile on-done)
  "Render PlantUML BODY to OUTFILE asynchronously.

ON-DONE is called with (OK . ERR) — OK is t on success, nil on failure,
and ERR is a diagnostic string when OK is nil.  Uses `make-process',
so Emacs stays responsive during the render."
  (cond
   ((not (executable-find "plantuml"))
    (funcall on-done (cons nil "plantuml binary not in PATH")))
   (t
    (let* ((out-buf (generate-new-buffer " *monday-plantuml-out*"))
           (err-buf (generate-new-buffer " *monday-plantuml-err*"))
           (proc (make-process
                  :name "monday-docs-sync-plantuml"
                  :command '("plantuml" "-headless" "-tpng" "-p")
                  :buffer out-buf
                  :stderr err-buf
                  :connection-type 'pipe
                  :coding '(no-conversion . no-conversion)
                  :sentinel
                  (lambda (p _event)
                    (when (memq (process-status p) '(exit signal))
                      (let ((exit (process-exit-status p))
                            (err (with-current-buffer err-buf (buffer-string))))
                        (unwind-protect
                            (cond
                             ((zerop exit)
                              (condition-case werr
                                  (with-current-buffer out-buf
                                    (let ((coding-system-for-write 'no-conversion))
                                      (write-region (point-min) (point-max)
                                                    outfile nil :silent)))
                                (error (funcall on-done
                                                (cons nil (format "write failed: %s"
                                                                  (error-message-string werr))))
                                       (cl-return-from nil)))
                              (funcall on-done (cons t nil)))
                             (t
                              (funcall on-done
                                       (cons nil (format "exit %d: %s"
                                                         exit (string-trim err))))))
                          (when (buffer-live-p out-buf) (kill-buffer out-buf))
                          (when (buffer-live-p err-buf) (kill-buffer err-buf)))))))))
      (process-send-string proc body)
      (process-send-eof proc)))))

(defun monday-docs-sync--render-queue-async (queue on-done)
  "Drain QUEUE serially via async renders, then call ON-DONE.
QUEUE is a list of (BODY . OUTFILE) pairs."
  (cond
   ((null queue) (funcall on-done))
   (t
    (let* ((item (car queue))
           (outfile (cdr item)))
      (message "monday-docs-sync: rendering PlantUML → %s"
               (file-name-nondirectory outfile))
      (monday-docs-sync--render-plantuml-async
       (car item) outfile
       (lambda (result)
         (unless (car result)
           (message "monday-docs-sync: render failed for %s — %s"
                    outfile (cdr result)))
         (monday-docs-sync--render-queue-async (cdr queue) on-done)))))))

(defun monday-docs-sync--excalidraw-svg-for (excalidraw-path)
  "Return the SVG rendered alongside EXCALIDRAW-PATH, or nil."
  (let ((svg (concat (file-name-sans-extension excalidraw-path) ".svg")))
    (and (file-readable-p svg) svg)))

(defun monday-docs-sync--force-render-excalidraw (path)
  "Touch PATH so the `org-excalidraw' watcher re-renders the SVG.

Does not block on the re-render; if the SVG is out of date on upload,
we still ship what's on disk (the next sync will include the fresh
one).  Returns the expected SVG path."
  (when (file-exists-p path)
    (set-file-times path))
  (monday-docs-sync--excalidraw-svg-for path))

(defun monday-docs-sync--maybe-svg-to-png (path)
  "If PATH is an SVG and a converter is available, return a PNG path."
  (if (and (string-suffix-p ".svg" (downcase path))
           monday-docs-sync-svg-to-png-command)
      (let ((out (concat (file-name-sans-extension path) ".png")))
        (let ((rc (call-process monday-docs-sync-svg-to-png-command nil nil nil
                                "-o" out path)))
          (if (zerop rc)
              out
            (message "monday-docs-sync: SVG→PNG failed (rc=%d), uploading SVG as-is" rc)
            path)))
    path))

(defun monday-docs-sync--resolve-asset-path (block)
  "Return an absolute file path to upload for BLOCK, or nil."
  (pcase (plist-get block :type)
    (`plantuml
     (let ((file (plist-get block :file)))
       (and file (file-readable-p file) file)))
    (`image
     (let ((path (plist-get block :path)))
       (cond
        ((null path) nil)
        ((string-suffix-p ".excalidraw" (downcase path))
         (let ((svg (if monday-docs-sync-force-render
                        (monday-docs-sync--force-render-excalidraw path)
                      (monday-docs-sync--excalidraw-svg-for path))))
           (and svg (monday-docs-sync--maybe-svg-to-png svg))))
        ((file-readable-p path)
         (if (string-suffix-p ".svg" (downcase path))
             (monday-docs-sync--maybe-svg-to-png path)
           path)))))))

;; ---- Step 6: GraphQL / HTTP layer (async via plz :then) --------------

(defconst monday-docs-sync--create-mutation
  (concat "mutation($doc:ID!,$type:DocBlockContentType!,$content:JSON!,$after:String){"
          " create_doc_block(doc_id:$doc,type:$type,content:$content,after_block_id:$after){id}"
          "}"))

(defun monday-docs-sync--parse-response (raw on-success on-error response-key)
  "Parse RAW JSON body; invoke callbacks.

RESPONSE-KEY, when non-nil, is the data field to extract before
passing to ON-SUCCESS (e.g. for mutations).  Nil means pass the whole
`data' subtree."
  (condition-case parse-err
      (let* ((parsed (json-parse-string raw :object-type 'alist :array-type 'list))
             (errors (alist-get 'errors parsed))
             (data (alist-get 'data parsed)))
        (if errors
            (funcall on-error (format "%S" errors))
          (funcall on-success (if response-key (alist-get response-key data) data))))
    (error (funcall on-error (format "parse failed: %s" (error-message-string parse-err))))))

(defun monday-docs-sync--graphql-async (query variables on-success on-error)
  "POST GraphQL QUERY with VARIABLES; call ON-SUCCESS with parsed data.

ON-ERROR is called with a string when the server returns `errors' or
the HTTP call fails.  Always async (uses plz :then)."
  (require 'plz)
  (let ((token (monday-docs-sync--token))
        (body (json-encode
               (list (cons 'query query)
                     (cons 'variables (or variables (list)))))))
    (plz 'post monday-docs-sync-api-endpoint
      :headers `(("Authorization" . ,token)
                 ("Content-Type" . "application/json")
                 ("API-Version" . "2024-01"))
      :body body
      :as 'string
      :then (lambda (raw)
              (monday-docs-sync--parse-response raw on-success on-error nil))
      :else (lambda (err)
              (funcall on-error (format "HTTP: %S" err))))))

(defun monday-docs-sync--upload-file-async (path target on-success on-error)
  "Upload file at PATH to Monday as an asset; call ON-SUCCESS with its URL.

TARGET is a cons (ITEM-ID . FILE-COLUMN-ID) identifying where the asset
will be hosted.  When nil, ON-ERROR is invoked immediately.

Uses Monday's proprietary multipart scheme (`query=' + `variables[file]=@'
form fields — NOT the jaydenseric GraphQL multipart spec, which the
`/v2/file' endpoint rejects with \"Unsupported query\")."
  (cond
   ((not (executable-find "curl"))
    (funcall on-error "curl not in PATH"))
   ((null target)
    (funcall on-error "no upload target resolved"))
   (t
    (let* ((token (monday-docs-sync--token))
           (item-id (car target))
           (col-id (cdr target))
           ;; Monday's /v2/file accepts the query as a plain string (with
           ;; literal arguments inlined — no JSON variables envelope) and
           ;; the file bytes as `variables[file]'.
           (mutation
            (format "mutation($file: File!){add_file_to_column(item_id: %s, column_id: \"%s\", file: $file){id public_url url}}"
                    item-id col-id))
           (out-buf (generate-new-buffer " *monday-upload-out*"))
           (err-buf (generate-new-buffer " *monday-upload-err*"))
           (proc (make-process
                  :name "monday-docs-sync-upload"
                  :command (list "curl" "--silent" "--show-error" "--fail-with-body"
                                 "-X" "POST"
                                 "-H" (format "Authorization: %s" token)
                                 "-F" (format "query=%s" mutation)
                                 "-F" (format "variables[file]=@%s" path)
                                 monday-docs-sync-file-endpoint)
                  :buffer out-buf
                  :stderr err-buf
                  :connection-type 'pipe
                  :sentinel
                  (lambda (p _event)
                    (when (memq (process-status p) '(exit signal))
                      (let ((exit (process-exit-status p))
                            (out (with-current-buffer out-buf (buffer-string)))
                            (err (with-current-buffer err-buf (buffer-string))))
                        (unwind-protect
                            (cond
                             ((not (zerop exit))
                              (funcall on-error
                                       (format "curl exit %d | stderr=%s | body=%s"
                                               exit
                                               (string-trim err)
                                               (string-trim out))))
                             (t
                              (monday-docs-sync--parse-response
                               out
                               (lambda (add)
                                 (funcall on-success
                                          (or (alist-get 'public_url add)
                                              (alist-get 'url add))))
                               (lambda (msg) (funcall on-error (format "upload %s: %s" path msg)))
                               'add_file_to_column)))
                          (when (buffer-live-p out-buf) (kill-buffer out-buf))
                          (when (buffer-live-p err-buf) (kill-buffer err-buf)))))))))
      (ignore proc)))))

;; ---- Upload-target auto-discovery -----------------------------------

(defconst monday-docs-sync--host-item-name "📎 docs-sync assets"
  "Name of the item we (re)use on the target board as an asset host.
The emoji prefix makes it unambiguously tool-managed in the Monday UI.")

(defun monday-docs-sync--create-file-column-async (board-id on-success on-error)
  "Create a `file' column on BOARD-ID; call ON-SUCCESS with its id."
  (monday-docs-sync--graphql-async
   "mutation($b:ID!,$t:String!){create_column(board_id:$b,title:$t,column_type:file){id}}"
   (list (cons 'b board-id) (cons 't "Sync assets"))
   (lambda (data)
     (funcall on-success (alist-get 'id (alist-get 'create_column data))))
   on-error))

(defun monday-docs-sync--create-host-item-async (board-id on-success on-error)
  "Create the host item on BOARD-ID; call ON-SUCCESS with its id."
  (monday-docs-sync--graphql-async
   "mutation($b:ID!,$n:String!){create_item(board_id:$b,item_name:$n){id}}"
   (list (cons 'b board-id)
         (cons 'n monday-docs-sync--host-item-name))
   (lambda (data)
     (funcall on-success (alist-get 'id (alist-get 'create_item data))))
   on-error))

(defun monday-docs-sync--resolve-upload-target-async (board-id on-success on-error)
  "Resolve an upload target for BOARD-ID; call ON-SUCCESS with (item-id . col-id).

Finds or creates a file column + host item (named per
`monday-docs-sync--host-item-name') on the board.  Falls back to the
`monday-docs-sync-upload-target' defcustom when BOARD-ID is nil.
Invokes ON-ERROR if neither yields a usable target."
  (cond
   ((null board-id)
    (if monday-docs-sync-upload-target
        (funcall on-success monday-docs-sync-upload-target)
      (funcall on-error
               "no #+MONDAY_BOARD keyword, doc has no parent board, and monday-docs-sync-upload-target is unset")))
   (t
    (message "monday-docs-sync: resolving upload target on board %s…" board-id)
    (monday-docs-sync--graphql-async
     "query($id:[ID!]){boards(ids:$id){columns{id title type}items_page(limit:500){items{id name}}}}"
     (list (cons 'id (list board-id)))
     (lambda (data)
       (let* ((board (car (alist-get 'boards data))))
         (if (null board)
             (funcall on-error (format "board %s not found (wrong id or no access)" board-id))
           (let* ((columns (alist-get 'columns board))
                  (items (alist-get 'items (alist-get 'items_page board)))
                  (file-col (seq-find (lambda (c) (equal (alist-get 'type c) "file"))
                                      columns))
                  (host-item (seq-find
                              (lambda (i)
                                (equal (alist-get 'name i)
                                       monday-docs-sync--host-item-name))
                              items))
                  (ensure-item
                   (lambda (col-id)
                     (if host-item
                         (funcall on-success
                                  (cons (alist-get 'id host-item) col-id))
                       (monday-docs-sync--create-host-item-async
                        board-id
                        (lambda (item-id)
                          (message "monday-docs-sync: created host item %s on board %s"
                                   item-id board-id)
                          (funcall on-success (cons item-id col-id)))
                        on-error)))))
             (if file-col
                 (funcall ensure-item (alist-get 'id file-col))
               (monday-docs-sync--create-file-column-async
                board-id
                (lambda (col-id)
                  (message "monday-docs-sync: created file column %s on board %s"
                           col-id board-id)
                  (funcall ensure-item col-id))
                on-error))))))
     on-error))))

;; ---- Step 7: async orchestrator --------------------------------------

(defvar monday-docs-sync--in-flight nil
  "Non-nil when an async sync is currently running.
Prevents concurrent syncs that would race on the target doc.")

(defvar monday-docs-sync--abort nil
  "When non-nil, the running pipeline checks this at every step boundary
and bails out early.  Set by `monday-docs-sync-abort'.")

(defun monday-docs-sync--kill-processes ()
  "Kill any in-flight curl / plantuml subprocesses spawned by the sync."
  (dolist (p (process-list))
    (when (and (process-live-p p)
               (string-match-p "\\`monday-docs-sync-"
                               (or (process-name p) "")))
      (ignore-errors (delete-process p)))))

;;;###autoload
(defun monday-docs-sync-abort ()
  "Stop a running `monday-docs-sync' at the next step boundary.

Sets the abort flag, kills any in-flight curl/plantuml subprocesses,
and clears the in-flight marker so a new sync can start immediately."
  (interactive)
  (setq monday-docs-sync--abort t)
  (monday-docs-sync--kill-processes)
  (setq monday-docs-sync--in-flight nil)
  (message "monday-docs-sync: aborted"))

(defun monday-docs-sync--run-async (url-id blocks doc-url keyword-board-id)
  "Kick off an async sync pipeline.  Reports progress via `message'.

KEYWORD-BOARD-ID, when non-nil, is the id from the file's
`#+MONDAY_BOARD:' keyword and wins over the doc's parent board."
  (setq monday-docs-sync--in-flight t)
  (setq monday-docs-sync--abort nil)
  (let ((doc-id nil)           ; resolved later
        (board-id keyword-board-id)  ; may be overwritten by doc's parent board
        (upload-target nil)    ; resolved (item-id . col-id), or nil
        (last-id nil)          ; running cursor for after_block_id
        (written 1)            ; counts the notice block
        (images 0)
        (diagrams 0)
        (total-blocks (length blocks)))
    (cl-labels
        ((done-failure (msg)
           (setq monday-docs-sync--in-flight nil)
           (message "monday-docs-sync: failed — %s" msg))
         (done-success ()
           (setq monday-docs-sync--in-flight nil)
           (message "monday-docs-sync: done — wrote %d block(s), %d image(s), %d diagram(s) → %s"
                    written images diagrams doc-url))
         (step-lookup ()
           (message "monday-docs-sync: resolving doc id…")
           (monday-docs-sync--graphql-async
            "query($oids:[ID!]){docs(object_ids:$oids){id object_id}}"
            (list (cons 'oids (vector url-id)))
            (lambda (data)
              (let ((docs (alist-get 'docs data)))
                (if (null docs)
                    (done-failure (format "no doc for URL id %s (wrong URL or token lacks access)"
                                          url-id))
                  (setq doc-id (format "%s" (alist-get 'id (car docs))))
                  ;; Monday's trick: a board-doc shares its numeric id
                  ;; with the backing board.  So unless `#+MONDAY_BOARD:'
                  ;; explicitly overrides, reuse URL-ID as the board id
                  ;; for asset hosting.
                  (unless board-id (setq board-id url-id))
                  (step-resolve-target))))
            #'done-failure))
         (step-resolve-target ()
           (monday-docs-sync--resolve-upload-target-async
            board-id
            (lambda (target)
              (setq upload-target target)
              (message "monday-docs-sync: upload target → item %s, column %s"
                       (car target) (cdr target))
              (step-list-blocks))
            (lambda (msg)
              ;; No target available.  Keep going — image blocks will
              ;; become italic text placeholders.
              (message "monday-docs-sync: no upload target (%s); images will be placeholders"
                       msg)
              (step-list-blocks))))
         (step-list-blocks ()
           (message "monday-docs-sync: listing existing blocks…")
           (step-list-blocks-page 1 nil))
         (step-list-blocks-page (page accum)
           ;; Monday paginates docs.blocks (default limit ~25).  Walk
           ;; every page until we see a short one, then kick off deletes.
           (monday-docs-sync--graphql-async
            "query($id:[ID!],$p:Int,$l:Int){docs(ids:$id){blocks(page:$p,limit:$l){id type}}}"
            (list (cons 'id (list doc-id))
                  (cons 'p page)
                  (cons 'l 100))
            (lambda (data)
              (let* ((page-blocks (alist-get 'blocks (car (alist-get 'docs data))))
                     (all (append accum page-blocks)))
                (if (and page-blocks (= (length page-blocks) 100))
                    (step-list-blocks-page (1+ page) all)
                  (message "monday-docs-sync: attempting to delete %d existing block(s)…"
                           (length all))
                  (step-delete-next all 0 0))))
            #'done-failure))
         (step-delete-next (remaining deleted skipped)
           ;; Per-block failures are non-fatal: Monday has undeletable
           ;; structural block types (e.g. the doc root).  We log + skip,
           ;; then continue.  The new content still gets appended.
           (cond
            (monday-docs-sync--abort
             (setq monday-docs-sync--in-flight nil)
             (message "monday-docs-sync: aborted during delete phase (deleted %d, skipped %d)"
                      deleted skipped))
            ((null remaining)
             (when (> skipped 0)
               (message "monday-docs-sync: %d undeletable block(s) remain (Monday structural types)"
                        skipped))
             (message "monday-docs-sync: deleted %d block(s)" deleted)
             (step-create-notice))
            (t
             (let* ((b (car remaining))
                    (bid (alist-get 'id b))
                    (btype (alist-get 'type b)))
               (monday-docs-sync--graphql-async
                "mutation($id:String!){ delete_doc_block(block_id:$id){ id } }"
                (list (cons 'id bid))
                (lambda (_) (step-delete-next (cdr remaining) (1+ deleted) skipped))
                (lambda (msg)
                  (message "monday-docs-sync: can't delete block %s (type=%s) — %s"
                           bid (or btype "?") msg)
                  (step-delete-next (cdr remaining) deleted (1+ skipped))))))))
         (step-create-notice ()
           (message "monday-docs-sync: writing read-only notice…")
           (let ((notice (monday-docs-sync--block->monday
                          (monday-docs-sync--notice-block))))
             (monday-docs-sync--graphql-async
              monday-docs-sync--create-mutation
              (list (cons 'doc doc-id)
                    (cons 'type (plist-get notice :type))
                    (cons 'content (json-encode (plist-get notice :content)))
                    (cons 'after nil))
              (lambda (data)
                (setq last-id (alist-get 'id (alist-get 'create_doc_block data)))
                (step-next-block blocks 1))
              #'done-failure)))
         (step-next-block (remaining idx)
           (cond
            (monday-docs-sync--abort
             (setq monday-docs-sync--in-flight nil)
             (message "monday-docs-sync: aborted at block %d/%d" idx total-blocks))
            ((null remaining) (done-success))
            (t
             (message "monday-docs-sync: writing block %d/%d…" idx total-blocks)
             (let* ((block (car remaining))
                    (mapped (monday-docs-sync--block->monday block))
                    (pending (plist-get mapped :pending-upload)))
               (if pending
                   (step-upload-then-create pending (cdr remaining) (1+ idx))
                 (step-create-text mapped (cdr remaining) (1+ idx)))))))
         (step-create-text (mapped rest next-idx)
           (monday-docs-sync--graphql-async
            monday-docs-sync--create-mutation
            (list (cons 'doc doc-id)
                  (cons 'type (plist-get mapped :type))
                  (cons 'content (json-encode (plist-get mapped :content)))
                  (cons 'after last-id))
            (lambda (data)
              (setq last-id (alist-get 'id (alist-get 'create_doc_block data)))
              (setq written (1+ written))
              (step-next-block rest next-idx))
            #'done-failure))
         (step-upload-then-create (pending rest next-idx)
           (let ((path (monday-docs-sync--resolve-asset-path pending)))
             (cond
              ((null path)
               (message "monday-docs-sync: skipping image, no renderable asset")
               (step-next-block rest next-idx))
              (t
               (message "monday-docs-sync: uploading %s…" (file-name-nondirectory path))
               (monday-docs-sync--upload-file-async
                path upload-target
                (lambda (asset-url)
                  (when (eq (plist-get pending :type) 'plantuml)
                    (setq diagrams (1+ diagrams)))
                  (when (eq (plist-get pending :type) 'image)
                    (setq images (1+ images)))
                  (monday-docs-sync--graphql-async
                   monday-docs-sync--create-mutation
                   (list (cons 'doc doc-id)
                         (cons 'type "image")
                         (cons 'content (json-encode
                                         (list (cons 'publicUrl asset-url))))
                         (cons 'after last-id))
                   (lambda (data)
                     (setq last-id (alist-get 'id (alist-get 'create_doc_block data)))
                     (setq written (1+ written))
                     (step-next-block rest next-idx))
                   #'done-failure))
                (lambda (msg)
                  ;; Upload failed (or no target configured).  Fall back
                  ;; to a text placeholder so the doc structure stays
                  ;; aligned with the source org file.
                  (message "monday-docs-sync: upload failed (%s), inserting placeholder"
                           msg)
                  (monday-docs-sync--graphql-async
                   monday-docs-sync--create-mutation
                   (list (cons 'doc doc-id)
                         (cons 'type "normal_text")
                         (cons 'content
                               (json-encode
                                (list (cons 'alignment "left")
                                      (cons 'direction "ltr")
                                      (cons 'deltaFormat
                                            (vector (list (cons 'insert
                                                                (format "[image not synced: %s]"
                                                                        (file-name-nondirectory path)))
                                                          (cons 'attributes
                                                                (list (cons 'italic t)))))))))
                         (cons 'after last-id))
                   (lambda (data)
                     (setq last-id (alist-get 'id (alist-get 'create_doc_block data)))
                     (setq written (1+ written))
                     (step-next-block rest next-idx))
                   #'done-failure))))))))
      (step-lookup))))

;;;###autoload
(defun monday-docs-sync ()
  "Sync the current org buffer to the Monday doc in its `#+MONDAY_DOC:' keyword.

Whole-doc replace: deletes every existing block in the target doc,
prepends a read-only notice, then writes the converted blocks.  The
HTTP pipeline is truly async — each curl runs via
`make-process' + sentinel; Emacs never blocks.  Progress is reported
via `message'.

Diagrams are re-rendered on the main thread (when
`monday-docs-sync-force-render' is non-nil) before the pipeline kicks
off — org-babel isn't thread-safe."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org-mode buffer"))
  (when monday-docs-sync--in-flight
    (user-error "A monday-docs-sync is already running — wait for it to finish"))
  (let ((url-id (monday-docs-sync--resolve-target)))
    (monday-docs-sync--token)           ; fail early if missing
    (when (and monday-docs-sync-force-render (buffer-modified-p))
      (save-buffer))
    (let* ((stale (if monday-docs-sync-force-render
                      (monday-docs-sync--collect-stale-plantuml)
                    nil))
           (all-blocks (monday-docs-sync--parse-buffer))
           (blocks (if monday-docs-sync-max-blocks
                       (seq-take all-blocks monday-docs-sync-max-blocks)
                     all-blocks))
           (url (monday-docs-sync--doc-url-from-keyword))
           (keyword-board-id (monday-docs-sync--board-id-from-keyword))
           (start-http (lambda ()
                         (message "monday-docs-sync: starting — %d/%d block(s) to write → %s"
                                  (length blocks) (length all-blocks) url)
                         (monday-docs-sync--run-async url-id blocks url
                                                      keyword-board-id))))
      (cond
       ((null stale) (funcall start-http))
       (t
        (message "monday-docs-sync: rendering %d stale PlantUML diagram(s) async…"
                 (length stale))
        (monday-docs-sync--render-queue-async stale start-http))))))

(provide 'monday-docs-sync)
;;; monday-docs-sync.el ends here
