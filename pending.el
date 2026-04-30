;;; pending.el --- Async pending content placeholders -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Maintainer: John Wiegley <jwiegley@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/jwiegley/pending
;; Keywords: convenience, tools

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A standalone Emacs Lisp library for marking buffer regions whose
;; content will be supplied asynchronously, with animated progress
;; indication.
;;
;; Insert a colored placeholder where some asynchronously computed text
;; is going to appear, optionally with a spinner or progress bar, then
;; atomically replace it with the result when ready.  Use cases include
;; LLM streaming responses, long-running shell commands, network
;; fetches, and arbitrary callback-driven work.
;;
;; See `DESIGN.md' in this package for the canonical reference on the
;; API, visual design, lifecycle, and implementation plan.
;;
;; This file currently provides Phase 2: the core lifecycle.  On top
;; of the Phase 1 skeleton (customization group, faces, struct, error
;; symbol, registries), it implements `pending-make' (insert and adopt
;; modes), `pending-resolve', `pending-reject', `pending-cancel',
;; `pending-update', the public predicates and accessors, the global
;; and buffer-local registry mutators, and the `kill-buffer-hook'
;; teardown.  Animation, streaming, edit-survival, the interactive
;; lister, and process integration are still to come.

;;; Code:

(require 'cl-lib)

;; Register with customize so `:package-version' on individual options
;; resolves to a real Emacs version in M-x customize-changed.
(when (boundp 'customize-package-emacs-version-alist)
  (add-to-list 'customize-package-emacs-version-alist
               '(pending ("0.1.0" . "30.1"))))


;;; Customization group

(defgroup pending nil
  "Async pending content placeholders."
  :group 'tools
  :prefix "pending-")


;;; User options

(defcustom pending-fps 10
  "Animation rate of pending placeholders, in frames per second.
Used by the single global animation timer that walks the registry on
each tick.  A value of 10 is the conventional sweet spot for in-buffer
spinners — fast enough to read as motion, slow enough not to hammer
redisplay."
  :type '(integer :match (lambda (_ v) (and (integerp v) (> v 0))))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-bar-width 16
  "Width of the textual progress bar, in cells.
Used by the `:percent' and `:eta' indicators when rendering the bar
string in the placeholder's after-string."
  :type '(integer :match (lambda (_ v) (and (integerp v) (> v 0))))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-default-spinner-style 'dots-1
  "Default key into `pending-spinner-styles' for new placeholders.
Callers can override per region by passing :spinner-style to
`pending-make'."
  :type '(choice (const :tag "Braille dots (sweep)" dots-1)
                 (const :tag "Braille dots (rotate)" dots-2)
                 (const :tag "ASCII line" line)
                 (const :tag "Arc" arc)
                 (const :tag "Clock" clock)
                 (symbol :tag "Other (must be a key of `pending-spinner-styles')"))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-spinner-styles
  '((dots-1 . ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
    (dots-2 . ["⠁" "⠂" "⠄" "⡀" "⢀" "⠠" "⠐" "⠈"])
    (line   . ["|" "/" "-" "\\"])
    (arc    . ["◜" "◠" "◝" "◞" "◡" "◟"])
    (clock  . ["🕛" "🕐" "🕑" "🕒" "🕓" "🕔" "🕕" "🕖" "🕗" "🕘" "🕙" "🕚"]))
  "Alist mapping spinner style symbols to vectors of frame strings.
Each value is a vector of single-glyph strings used in cyclic order.
The default style is selected by `pending-default-spinner-style'."
  :type '(alist :key-type symbol
                :value-type (vector string))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-bar-style 'eighths
  "Visual style of the progress bar.
`eighths' uses Unicode block elements with eighth-cell resolution and
looks best in monospace fonts that render those glyphs.  `ascii' falls
back to plain `#' and `-' for terminals or fonts without good Unicode
block support."
  :type '(choice (const :tag "Eighth-block Unicode" eighths)
                 (const :tag "ASCII fallback"       ascii))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-bar-family nil
  "Font family used for the progress bar segment, or nil.
When non-nil, the bar text is rendered in this family so that
proportional buffer faces do not break alignment.  When nil, the bar
inherits the surrounding face — variable-pitch users may then see
misalignment."
  :type '(choice (const :tag "Inherit buffer face" nil)
                 (string :tag "Font family"))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-fringe-bitmap nil
  "Optional fringe bitmap symbol shown beside placeholders, or nil.
When non-nil, this should be the symbol naming a fringe bitmap defined
via `define-fringe-bitmap'.  It gives off-screen visibility — the user
can scroll past the placeholder and still see a marker in the fringe.
Has no effect in terminal frames."
  :type '(choice (const :tag "No fringe bitmap" nil)
                 (symbol :tag "Bitmap symbol"))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-allow-read-only nil
  "If non-nil, allow placement of placeholders in read-only buffers.
By default `pending-make' refuses to operate on a buffer where
`buffer-read-only' is non-nil; setting this to t binds
`inhibit-read-only' during insertion and resolution.  Useful for hosts
like `compilation-mode' or chat buffers that flip read-only on the
caller's behalf."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-label-max-width 60
  "Maximum width, in characters, of a placeholder's visible label.
Labels longer than this are truncated with an ellipsis; the full label
remains available in the placeholder's tooltip."
  :type '(integer :match (lambda (_ v) (and (integerp v) (> v 0))))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-confirm-on-emacs-exit nil
  "If non-nil, prompt before exiting Emacs while placeholders are active.
Currently declared for forward compatibility; the corresponding
`kill-emacs-query-functions' integration is not yet wired up."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.1.0"))


;;; Faces

(defface pending-face
  '((((class color) (background dark))
     :background "#1e3a5f" :foreground "#a8c5e8" :extend t)
    (((class color) (background light))
     :background "#e8f0fa" :foreground "#1f4a78" :extend t)
    (t :inherit shadow))
  "Face for the placeholder body — that is, the label text."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-spinner-face
  '((((class color) (background dark)) :foreground "#ffd866")
    (((class color) (background light)) :foreground "#b6862c"))
  "Face for the before-string spinner glyph."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-progress-face
  '((t :inherit pending-face))
  "Face for the after-string progress bar and ETA text.
Apply `pending-bar-family' on top of this face when set, to keep
alignment under variable-pitch buffer faces."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-error-face
  '((t :inherit error :weight bold))
  "Face for rejected placeholders' replacement text."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-cancelled-face
  '((t :inherit shadow :slant italic))
  "Face for cancelled placeholders' replacement text."
  :group 'pending
  :package-version '(pending . "0.1.0"))


;;; Errors

(define-error 'pending-error "Pending placeholder error")


;;; Pending struct

(cl-defstruct (pending (:constructor pending--make-struct)
                       (:copier nil)
                       (:predicate pending-p))
  ;; Identity
  id group label
  ;; Location
  buffer start end overlay
  ;; Visual mode
  indicator spinner-style face
  ;; Determinate / ETA state
  percent eta start-time deadline
  ;; Lifecycle
  status reason resolved-at
  ;; Callbacks
  on-cancel on-resolve
  ;; Internal
  attached-process attached-timer in-resolve)


;;; Identity generator

(defvar pending--next-id 0
  "Monotonic counter feeding `pending--gen-id'.")

(defun pending--gen-id ()
  "Return a freshly-generated identifier symbol for a pending struct.
The returned symbol has the form `pending-N' where N is a monotonic
counter; the symbols are not interned across Emacs sessions."
  (intern (format "pending-%d" (cl-incf pending--next-id))))


;;; Registries

(defvar pending--registry (make-hash-table :test 'eq)
  "Global hash table mapping pending id symbols to pending structs.
Updated by `pending--register' and `pending--unregister'.")

(defvar-local pending--buffer-registry nil
  "Buffer-local list of pending structs that live in this buffer.
Kept in sync with `pending--registry' so buffer-scoped queries do not
have to scan the global table.")


;;; Internal helpers

(defun pending--terminal-status-p (status)
  "Return non-nil if STATUS is a terminal lifecycle keyword.
The terminal states are `:resolved', `:rejected', `:cancelled', and
`:expired'."
  (memq status '(:resolved :rejected :cancelled :expired)))

(defun pending--register (p)
  "Register P in the global and buffer-local pending registries.
Adds P to `pending--registry' keyed by its id, and pushes P onto the
buffer-local `pending--buffer-registry' of P's buffer.  Both updates
happen, in that order.  Also installs the buffer-kill cleanup hook
in P's buffer if not already present.

This function has side effects only; it does not return a useful
value."
  (puthash (pending-id p) p pending--registry)
  (let ((buf (pending-buffer p)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (push p pending--buffer-registry)
        (add-hook 'kill-buffer-hook #'pending--on-kill-buffer nil t)))))

(defun pending--unregister (p)
  "Remove P from the global and buffer-local pending registries.
Cancels P's `attached-timer' if any.  Does NOT delete the overlay or
clear markers — that happens in `pending--resolve-internal' since the
order matters for atomic region replacement."
  (remhash (pending-id p) pending--registry)
  (let ((buf (pending-buffer p)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq pending--buffer-registry
              (delq p pending--buffer-registry)))))
  (let ((tm (pending-attached-timer p)))
    (when (timerp tm)
      (cancel-timer tm))
    (setf (pending-attached-timer p) nil)))

(defun pending--swap-region (p new-text face)
  "Atomically replace P's region with NEW-TEXT propertized by FACE.
The replacement is wrapped in an `atomic-change-group' so undo sees
exactly one step.  `inhibit-read-only' and `inhibit-modification-hooks'
are bound around the swap so neither this library's own read-only
enforcement nor its modification hooks fight the operation.

The end marker is left pointing at the position immediately after the
inserted text."
  (let ((buf (pending-buffer p)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (atomic-change-group
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (start (marker-position (pending-start p)))
                (end (marker-position (pending-end p))))
            (when (and start end)
              (delete-region start end)
              (goto-char start)
              (insert (propertize (or new-text "") 'face face))
              (set-marker (pending-end p) (point)))))))))

(defun pending--resolve-internal (p new-status reason new-text face
                                    &optional run-on-resolve)
  "Flip P from a non-terminal state to terminal NEW-STATUS with REASON.
This is the single mutation path for terminal transitions; it
enforces the single-resolution invariant of DESIGN.md §2.

Steps:
  1. Bail out early if `pending--in-resolve' is already set on P
     (re-entrant guard) or if P is already in a terminal state.
  2. Set P's status, REASON-derived reason slot, and resolved-at.
  3. Replace the placeholder region with NEW-TEXT propertized by FACE
     via `pending--swap-region'.
  4. Unregister P from both registries (also cancels P's deadline
     timer if any).
  5. Delete P's overlay and clear its markers.
  6. If RUN-ON-RESOLVE is non-nil, fire P's `on-resolve' callback
     once, with errors caught so a buggy callback does not crash this
     resolver.

Returns t on success; nil if P was already terminal or a re-entrant
resolve was suppressed."
  (cond
   ((pending-in-resolve p)
    nil)
   ((pending--terminal-status-p (pending-status p))
    (display-warning
     'pending
     (format "ignoring %s on already-terminal placeholder %s (status %s)"
             new-status (pending-id p) (pending-status p))
     :debug)
    nil)
   (t
    (setf (pending-in-resolve p) t)
    (unwind-protect
        (progn
          (setf (pending-status p) new-status
                (pending-reason p) reason
                (pending-resolved-at p) (float-time))
          (pending--swap-region p new-text face)
          (pending--unregister p)
          (let ((ov (pending-overlay p)))
            (when (overlayp ov)
              (delete-overlay ov))
            (setf (pending-overlay p) nil))
          (let ((sm (pending-start p))
                (em (pending-end p)))
            (when (markerp sm) (set-marker sm nil))
            (when (markerp em) (set-marker em nil)))
          (when (and run-on-resolve (pending-on-resolve p))
            (condition-case err
                (funcall (pending-on-resolve p) p)
              (error
               (display-warning
                'pending
                (format "on-resolve callback for %s signaled: %S"
                        (pending-id p) err)
                :error))))
          t)
      (setf (pending-in-resolve p) nil)))))

(defun pending--format-reason (reason)
  "Render REASON as user-visible text.
REASON may be a string, symbol, keyword, or nil.  Strings are returned
verbatim; keywords have their leading colon stripped; other symbols
are rendered as their name; nil renders as the empty string; anything
else is formatted with %S."
  (cond
   ((null reason) "")
   ((stringp reason) reason)
   ((keywordp reason) (substring (symbol-name reason) 1))
   ((symbolp reason) (symbol-name reason))
   (t (format "%S" reason))))

(defun pending--on-kill-buffer ()
  "Cancel every pending placeholder living in the buffer being killed.
Installed buffer-locally on `kill-buffer-hook' by `pending--register'.
Iterates a snapshot of `pending--buffer-registry' and calls
`pending-cancel' with reason `:buffer-killed' on each."
  (dolist (p (copy-sequence pending--buffer-registry))
    (pending-cancel p :buffer-killed)))


;;; Public API: construction

;;;###autoload
(cl-defun pending-make (buffer &key
                                label
                                start end
                                indicator
                                deadline
                                eta
                                percent
                                face
                                spinner-style
                                on-cancel
                                on-resolve
                                group)
  "Create and insert a pending placeholder in BUFFER.
Return the new `pending' struct.  The placeholder is registered in
`pending--registry' and the buffer-local `pending--buffer-registry'
of BUFFER so it can be enumerated.

Insertion modes:
  - If START and END are both nil, insert a new placeholder at point
    in BUFFER.  Both markers are created at the inserted text.
  - If START and END are both non-nil (positions or markers), adopt
    the existing region [START, END]; do not insert text.
  - It is an error to supply only one of START or END.

LABEL is a short string shown inside the placeholder, default
\"Pending\".  GROUP is an optional symbol for filtering.

INDICATOR selects the visual; `:spinner' (default), `:percent', or
`:eta'.  PERCENT and ETA prime the determinate / ETA modes; FACE
overrides `pending-face'; SPINNER-STYLE selects an entry from
`pending-spinner-styles'.

DEADLINE, if non-nil, is wall-clock seconds before the placeholder is
auto-rejected with reason `:timed-out'.  A one-shot timer is
scheduled.

ON-CANCEL is a function of one argument (the pending struct) called
when the placeholder is cancelled, before the status flips.
ON-RESOLVE is a function called exactly once when the placeholder
transitions to any terminal state.

Side effects: inserts placeholder text (insert mode), creates and
adopts an overlay, registers the struct, optionally schedules the
deadline timer, and installs the buffer-kill hook locally.  Signals
`pending-error' if BUFFER is dead, read-only and
`pending-allow-read-only' is nil, START and END do not match, or any
position falls outside BUFFER's bounds."
  (unless (buffer-live-p buffer)
    (signal 'pending-error (list "buffer is not live" buffer)))
  (with-current-buffer buffer
    (when (and buffer-read-only (not pending-allow-read-only))
      (signal 'pending-error (list "buffer is read-only" buffer))))
  (when (and (null start) end)
    (signal 'pending-error
            (list "must supply both START and END or neither")))
  (when (and start (null end))
    (signal 'pending-error
            (list "must supply both START and END or neither")))
  (let* ((id (pending--gen-id))
         (resolved-label (or label "Pending"))
         (resolved-indicator (or indicator :spinner))
         (resolved-spinner (or spinner-style pending-default-spinner-style))
         (resolved-face (or face 'pending-face))
         (inhibit-read-only (or inhibit-read-only pending-allow-read-only))
         start-marker
         end-marker)
    (with-current-buffer buffer
      (cond
       ;; Insert mode.
       ((and (null start) (null end))
        (let ((insert-point (point)))
          (setq start-marker (copy-marker insert-point nil))
          (insert resolved-label)
          ;; End marker is insertion-type nil for now: Phase 6 will
          ;; flip it to t while streaming and back to nil at finish,
          ;; mirroring gptel's tracking-marker discipline
          ;; (gptel.el:1389, 1794).  Keeping it nil now means typing
          ;; just after the placeholder lands outside the region — the
          ;; behaviour the canonical smoke test expects.
          (setq end-marker (copy-marker (point) nil))))
       ;; Adopt mode.
       (t
        (let ((s (if (markerp start) (marker-position start) start))
              (e (if (markerp end)   (marker-position end)   end)))
          (unless (and (integerp s) (integerp e))
            (signal 'pending-error (list "invalid START/END" start end)))
          (when (or (< s (point-min)) (> s (point-max))
                    (< e (point-min)) (> e (point-max)))
            (signal 'pending-error (list "START/END outside buffer" s e)))
          (when (> s e)
            (signal 'pending-error (list "START after END" s e)))
          (setq start-marker (copy-marker s nil))
          (setq end-marker (copy-marker e nil))))))
    ;; Front- and rear-advance both nil for now; Phase 6 will flip the
    ;; rear when streaming begins.
    (let* ((ov (make-overlay (marker-position start-marker)
                             (marker-position end-marker)
                             buffer))
           (p (pending--make-struct
               :id id
               :group group
               :label resolved-label
               :buffer buffer
               :start start-marker
               :end end-marker
               :overlay ov
               :indicator resolved-indicator
               :spinner-style resolved-spinner
               :face resolved-face
               :percent percent
               :eta eta
               :start-time (float-time)
               :deadline deadline
               :status :scheduled
               :reason nil
               :resolved-at nil
               :on-cancel on-cancel
               :on-resolve on-resolve
               :attached-process nil
               :attached-timer nil
               :in-resolve nil)))
      (overlay-put ov 'pending p)
      (overlay-put ov 'face resolved-face)
      (overlay-put ov 'priority 100)
      (overlay-put ov 'evaporate nil)
      (overlay-put ov 'help-echo
                   (lambda (_window _object _pos)
                     (format "Pending: %s [%s]"
                             (pending-label p)
                             (pending-status p))))
      (pending--register p)
      ;; Skip silently if DEADLINE is non-positive — "ignore" semantics
      ;; rather than signalling on every miscall.
      (when (and (numberp deadline) (> deadline 0))
        (setf (pending-attached-timer p)
              (run-at-time
               deadline nil
               (lambda ()
                 (when (pending-active-p p)
                   (pending-reject p :timed-out))))))
      p)))


;;; Public API: terminal transitions

(defun pending-resolve (p text)
  "Atomically replace P's placeholder region with TEXT.
Transition P to `:resolved'.  Return t on success, or nil if P was
already in a terminal state (in which case a `:debug' warning is
logged).

The replacement happens inside an `atomic-change-group' so undo sees
one step, with `inhibit-read-only' and `inhibit-modification-hooks'
bound during the swap.  Side effects: removes the overlay, clears
markers, unregisters P, cancels its deadline timer, and runs the
`on-resolve' callback once (errors there are caught and warned)."
  (pending--resolve-internal p :resolved nil text 'pending-face t))

(defun pending-reject (p reason &optional replacement-text)
  "Mark P as failed with REASON and replace its region.
REASON should be a string or a keyword/symbol describing the failure.
REPLACEMENT-TEXT defaults to a glyph plus the reason rendered with
`pending-error-face'.  Transition P to `:rejected' and return t on
success, or nil if P was already terminal.

Side effects mirror `pending-resolve' (removes overlay, clears
markers, unregisters, cancels timer, runs `on-resolve')."
  (let ((text (or replacement-text
                  (format "✗ %s"
                          (if reason
                              (pending--format-reason reason)
                            "Failed")))))
    (pending--resolve-internal p :rejected reason text
                               'pending-error-face t)))

(defun pending-cancel (p &optional reason)
  "Cancel P, optionally with REASON (default `:cancelled-by-user').
Call P's `on-cancel' callback FIRST, so the caller can abort its
underlying work (e.g. kill a process).  Then transition P to
`:cancelled' and replace its region with a small cancelled glyph
faced `pending-cancelled-face'.

The on-cancel callback is wrapped in `condition-case' so a buggy
callback does not break the cancel path.  This function is safe to
call re-entrantly from inside the callback's own chain — the
single-resolution guard makes recursive cancels into no-ops.

Return t on success, or nil if P was already terminal."
  (let ((effective-reason (or reason :cancelled-by-user)))
    (cond
     ((pending-in-resolve p)
      nil)
     ((pending--terminal-status-p (pending-status p))
      (display-warning
       'pending
       (format "ignoring cancel on already-terminal placeholder %s (status %s)"
               (pending-id p) (pending-status p))
       :debug)
      nil)
     (t
      ;; Set the re-entrancy guard before invoking on-cancel: a buggy
      ;; callback that calls back into `pending-cancel' on the same
      ;; struct would otherwise loop forever (status is still
      ;; non-terminal at this point, so only the in-resolve flag
      ;; protects us).  `pending--resolve-internal' below also sets
      ;; this flag — that is harmless (idempotent assignment).
      (setf (pending-in-resolve p) t)
      (unwind-protect
          (when (pending-on-cancel p)
            (condition-case err
                (funcall (pending-on-cancel p) p)
              (error
               (display-warning
                'pending
                (format "on-cancel callback for %s signaled: %S"
                        (pending-id p) err)
                :error))))
        (setf (pending-in-resolve p) nil))
      (pending--resolve-internal
       p :cancelled effective-reason
       (format "✗ %s" (pending--format-reason effective-reason))
       'pending-cancelled-face t)))))


;;; Public API: mid-flight updates

(cl-defun pending-update (p &key label percent eta indicator)
  "Update P's metadata mid-flight.  Mutates the named slots only.
LABEL, PERCENT, ETA, and INDICATOR replace the corresponding slots
when non-nil.  No state transition happens; the next animation tick
will pick up the new values.  Return P.

If P is in a terminal state, log a `:debug' warning and return P
unchanged."
  (cond
   ((pending--terminal-status-p (pending-status p))
    (display-warning
     'pending
     (format "ignoring update on already-terminal placeholder %s (status %s)"
             (pending-id p) (pending-status p))
     :debug)
    p)
   (t
    (when label     (setf (pending-label p) label))
    (when percent   (setf (pending-percent p) percent))
    (when eta       (setf (pending-eta p) eta))
    (when indicator (setf (pending-indicator p) indicator))
    p)))


;;; Public API: predicates and accessors

(defun pending-active-p (p)
  "Return non-nil if P is in an active (non-terminal) lifecycle state.
The active states are `:scheduled', `:running', and `:streaming'."
  (memq (pending-status p) '(:scheduled :running :streaming)))

(defun pending-at (&optional pos buffer)
  "Return the pending struct at POS in BUFFER, or nil if none.
POS defaults to point; BUFFER defaults to the current buffer.
Searches the overlays at POS for one carrying a `pending' property
and returns its value."
  (let ((target-buffer (or buffer (current-buffer))))
    (when (buffer-live-p target-buffer)
      (with-current-buffer target-buffer
        (let ((effective-pos (or pos (point)))
              (result nil))
          (dolist (ov (overlays-at effective-pos))
            (let ((p (overlay-get ov 'pending)))
              (when (and p (null result))
                (setq result p))))
          result)))))

(defun pending-list-active (&optional buffer group)
  "Return the list of active pending structs.
If BUFFER is non-nil, restrict the result to placeholders whose
buffer is BUFFER.  If GROUP is non-nil, restrict to placeholders
whose `group' slot is `eq' to GROUP.

Only placeholders for which `pending-active-p' returns non-nil are
included.  Order within the result is unspecified."
  (let ((acc nil))
    (maphash
     (lambda (_id p)
       (when (and (pending-active-p p)
                  (or (null buffer) (eq (pending-buffer p) buffer))
                  (or (null group)  (eq (pending-group p)  group)))
         (push p acc)))
     pending--registry)
    (nreverse acc)))


(provide 'pending)

;;; pending.el ends here
