;;; menubar-export.el --- Data + actions for the Hammerspoon menu bar -*- lexical-binding: t -*-
;;
;; Functions in this file are called from Hammerspoon via `emacsclient --eval'.
;; Keep them cheap, side-effect free (except for the explicit *action* ones),
;; and returning printable sexps so Hammerspoon can parse with
;; `hs.fnutils` after a simple `dofile'-style eval.

(require 'cl-lib)
(require 'seq)

(defgroup my-menubar nil
  "Hammerspoon menu bar ↔ Emacs integration."
  :group 'convenience)

(defcustom my/menubar-plan-roots
  '("~/.spacemacs.d/plans"
    "~/plans")
  "Directories whose direct children (*.org) are plan files."
  :type '(repeat directory)
  :group 'my-menubar)

(defcustom my/menubar-plan-root-globs
  '("~/Development/*/plans")
  "Glob patterns expanded at query time; each match is treated as a plan root."
  :type '(repeat string)
  :group 'my-menubar)

(defun my/menubar--plan-dirs ()
  "Return the current set of existing plan directories."
  (let ((dirs (mapcar #'expand-file-name my/menubar-plan-roots)))
    (dolist (g my/menubar-plan-root-globs)
      (dolist (d (file-expand-wildcards (expand-file-name g)))
        (push d dirs)))
    (cl-remove-duplicates
     (seq-filter #'file-directory-p dirs)
     :test #'equal)))

(defun my/menubar--count-annotations (file)
  "Return the pending annotation count for FILE, or 0 on error.
Uses `claude-collab-pending-annotations' if available."
  (condition-case _err
      (if (fboundp 'claude-collab-pending-annotations)
          (length (claude-collab-pending-annotations file))
        0)
    (error 0)))

(defun my/menubar-plans-summary ()
  "Return ((FILE PENDING MTIME) …), sorted newest-mtime first.
Shape chosen so Hammerspoon can read it with minimal Lua parsing."
  (let (rows)
    (dolist (dir (my/menubar--plan-dirs))
      (dolist (f (directory-files dir t "\\.org\\'" t))
        (let* ((attrs (file-attributes f))
               (mtime (float-time (file-attribute-modification-time attrs))))
          (push (list f (my/menubar--count-annotations f) mtime) rows))))
    (sort rows (lambda (a b) (> (nth 2 a) (nth 2 b))))))

(defun my/menubar-plans-pending-total ()
  "Return the sum of pending annotations across all plans (fast path)."
  (apply #'+ (mapcar (lambda (row) (nth 1 row))
                     (my/menubar-plans-summary))))

(defun my/menubar-jump-to-plan (file)
  "Raise an Emacs frame, open FILE, return t on success."
  (when (and (stringp file) (file-exists-p file))
    (let ((frame (or (car (seq-filter #'frame-visible-p (frame-list)))
                     (car (frame-list))
                     (make-frame))))
      (select-frame-set-input-focus frame))
    (find-file file)
    t))

(provide 'menubar-export)
;;; menubar-export.el ends here
