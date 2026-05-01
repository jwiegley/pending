;;; pending.el --- Async pending content placeholders -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Maintainer: John Wiegley <jwiegley@gmail.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/jwiegley/pending
;; Keywords: convenience, tools

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: BSD-3-Clause
;; See LICENSE.md for the full license text.

;;; Commentary:

;; Mark a buffer region (or a single point) as "the answer goes here,
;; hold tight," let some async work run, then atomically swap the
;; placeholder for the result.  One undo step.  The placeholder text
;; is read-only while it's active, so the user can't accidentally type
;; into it; if they delete it, the underlying request gets cancelled.
;;
;; The original itch was gptel: I'd send a prompt and the buffer would
;; sit there, no marker for where the answer would land, no indication
;; anything was happening.  This solves that for any callback-driven
;; async pattern -- gptel, `make-process', `url-retrieve', plain
;; timers.
;;
;; Three pieces worth knowing up front:
;;
;;   - The token returned by every constructor is the only handle.
;;     Pass it to `pending-finish', `pending-cancel', `pending-update'.
;;     Once a token is terminal, all operations are no-ops with a
;;     `:debug' warning.
;;
;;   - All terminal transitions go through `pending--resolve-internal'.
;;     One mutation path, one place that flips status, fires
;;     `:on-resolve', and tears down the overlay.  This was important
;;     to get right -- earlier drafts had four code paths and they
;;     drifted.
;;
;;   - One global timer drives every spinner, ticking at `pending-fps'.
;;     N pending regions don't mean N timers.  The timer parks itself
;;     when the registry is empty and re-arms when a placeholder's
;;     buffer becomes visible again.
;;
;; See `DESIGN.md' for the long-form design rationale and `README.md'
;; for the API tour.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

;; Register with customize so `:package-version' on individual options
;; resolves to a real Emacs version in M-x customize-changed.
(when (boundp 'customize-package-emacs-version-alist)
  (add-to-list 'customize-package-emacs-version-alist
               '(pending ("0.1.0" . "30.1") ("0.2.0" . "30.2"))))


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
The default style is selected by `pending-default-spinner-style'.

See also: `pending--spinner-frames-fallback' (built-in defaults that
back up this user-customizable alist when a key is missing)."
  :type '(alist :key-type symbol
                :value-type (vector string))
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-bar-style 'eighths
  "Bar character set.

`eighths' uses Unicode eighth-block characters (from `▏' to `█'),
giving smooth eighth-cell quantization on UTF-8 capable displays.

`ascii' uses plain ASCII characters (`.', `-', `+', `*', `#'),
giving five-step quantization for terminals or fonts where Unicode
block elements don't render."
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
Implemented via `pending--kill-emacs-query', which is registered on
`kill-emacs-query-functions' at load time.  When this option is nil
\(the default) the query function returns t unconditionally and the
exit is not blocked.  Set to t to be asked for confirmation if any
placeholder is still active when Emacs is being killed."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defcustom pending-list-auto-refresh t
  "If non-nil, automatically refresh `*Pending*' on registry mutation.
When the global registry changes — via `pending-make' adding a new
placeholder, a terminal transition removing one through
`pending--resolve-internal', or any other registry mutator — the
`*Pending*' list buffer (when live and in `pending-list-mode') is
re-populated from the live registry so the user-facing view stays
in sync without pressing `g'.  Set to nil to keep v0.1 semantics
where the list view is a snapshot until manually refreshed."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.2.0"))

(defcustom pending-pulse-on-resolve t
  "If non-nil, flash the resolved region briefly via `pulse.el'.
On a successful `:resolved' transition (`pending-finish' or
`pending-stream-finish') the inserted text is momentarily
highlighted using `pulse-momentary-highlight-region'.  Reject
and cancel paths never pulse — they reflect failure or
abandonment, not a successful completion.

`pulse' is loaded lazily the first time a pulse fires so this
option does not pull the library in for users who set it nil."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.2.0"))

(defcustom pending-fringe-bitmap nil
  "If non-nil, fringe bitmap symbol shown beside each pending region.
A symbol naming a registered fringe bitmap (e.g. `right-arrow' or a
custom bitmap from `define-fringe-bitmap').  When non-nil, the
placeholder overlay carries a fringe-display proxy in its
`before-string' so the bitmap renders in the left fringe of the
window line that contains the placeholder, giving an off-screen-
visible cue that scrolls with the buffer.

This is purely decorative and only renders in graphical frames
\(see `display-graphic-p').  Set to nil to disable."
  :type '(choice (const :tag "Off" nil) symbol)
  :group 'pending
  :package-version '(pending . "0.2.0"))

(defcustom pending-svg-spinner-enable t
  "If non-nil, render spinners as SVG images on graphical frames.
When t and the frame supports SVG (`image-type-available-p' \\='svg)
and `display-graphic-p' is non-nil, `pending--render' renders the
spinner glyph as a small SVG arc-rotation image instead of the
Unicode text glyph.  Falls back to Unicode automatically on TTY
or when SVG support is unavailable."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.2.0"))

(defcustom pending-svg-spinner-size 16
  "Pixel size of the SVG spinner image.
Width and height; the SVG is square.  Changing this value clears
the SVG cache so the next render regenerates images at the new
size."
  :type '(integer :tag "Pixels"
                  :match (lambda (_ v) (and (integerp v) (> v 0))))
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (boundp 'pending--svg-cache)
                    (hash-table-p pending--svg-cache))
           (clrhash pending--svg-cache)))
  :group 'pending
  :package-version '(pending . "0.2.0"))

(defcustom pending-protect-adopted-region t
  "If non-nil, freeze an adopted region's text while a placeholder is active.
When `pending-region BEG END STR' (or `pending-make' with both
START and END) adopts an existing buffer region, this option
controls whether the adopted text is made read-only via
`read-only' / `front-sticky' / `rear-nonsticky' text properties
on the buffer text itself.

The principle is \"the placeholder is read-only while active\":
adopted text is about to be replaced by the async result, so
editing it during async work would race the resolve.  Defaults to t.

A subtle but important benefit: text properties live in the
buffer string itself and ARE inherited by indirect buffers (made
via `make-indirect-buffer'), while overlays are buffer-specific
and do NOT project into indirect views.  Setting this option
non-nil therefore extends edit protection across indirect-buffer
projections of the placeholder's buffer.

Set to nil to leave the adopted region editable while the
placeholder is active (matches v0.1.0 behaviour where adopt
mode relied on the overlay's `modification-hooks' alone -- fast
to set up, but does not survive into indirect buffers).
Insert-mode placeholders are always read-only regardless of this
setting."
  :type 'boolean
  :group 'pending
  :package-version '(pending . "0.2.0"))


;;; Faces

(defface pending-highlight
  '((((class color) (background dark))
     :background "#1e3a5f" :foreground "#a8c5e8" :extend t)
    (((class color) (background light))
     :background "#e8f0fa" :foreground "#1f4a78" :extend t)
    (t :inherit shadow))
  "Face for the highlighted region of a pending overlay (BEG..END).
Applied as the overlay's `face' property only when the overlay
covers existing buffer text — adopt mode with `BEG' < `END'.  In
insert mode and zero-width adopt mode (`pending-insert' / overlays
where `BEG' equals `END') the overlay carries no face, so the
inserted label receives no background.  The library never adds a
`face' property to text it inserts itself."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-lighter
  '((((class color))
     :foreground "white" :background "red" :weight bold)
    (t :inverse-video t :weight bold))
  "Face for the lighter STR shown at BEG of a pending overlay.
Bold white-on-red by default for high visibility — the lighter is
a visual badge attached to the overlay's `before-string', not text
in the buffer."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-face
  '((t :inherit pending-highlight))
  "Compatibility alias for `pending-highlight'.
Used as the default value of `pending-make''s `:face' keyword.  The
library applies it as the overlay's `face' property only when the
overlay covers existing buffer text (adopt mode with a non-empty
range).  Inserted text — labels, streamed chunks, and resolution
text — is never faced by `pending'."
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
  "Face previously applied to rejected placeholders' replacement text.
Retained for backward compatibility and customization.  As of
v0.1.0 the library does not face inserted text — `pending-reject'
inserts plain buffer text and surrounding font-lock applies."
  :group 'pending
  :package-version '(pending . "0.1.0"))

(defface pending-cancelled-face
  '((t :inherit shadow :slant italic))
  "Face previously applied to cancelled placeholders' replacement text.
Retained for backward compatibility and customization.  As of
v0.1.0 the library does not face inserted text — `pending-cancel'
inserts plain buffer text and surrounding font-lock applies."
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
  ;; Location.  The slot for the placeholder overlay is named `ov'
  ;; (auto-generated accessor: `pending-ov'), so the public symbol
  ;; `pending-region' is free for the positional constructor below.
  ;; A multi-arity wrapper named `pending-region' below preserves
  ;; the historical 1-arg accessor call shape for back-compat.
  buffer start end ov
  ;; Visual mode
  indicator spinner-style face
  ;; Determinate / ETA state
  percent eta start-time deadline
  ;; Lifecycle
  status reason resolved-at
  ;; Callbacks
  on-cancel on-resolve
  ;; Internal
  attached-process attached-timer in-resolve
  ;; Render bookkeeping
  last-frame)


;;; Identity generator

(defvar pending--next-id 0
  "Monotonic counter feeding `pending--gen-id'.")

(defun pending--gen-id ()
  "Return a fresh, uninterned identifier symbol for a pending struct.
The returned symbol has the form `pending-N' where N is a monotonic
counter.  Uninterned symbols are not added to the global obarray, so
generating placeholders does not leak symbols across an Emacs session.
The buffer-global registry uses `eq' for comparison, which works
correctly with uninterned symbols."
  (make-symbol (format "pending-%d" (cl-incf pending--next-id))))


;;; Registries

(defvar pending--registry (make-hash-table :test 'eq)
  "Global hash table mapping pending id symbols to pending structs.
Updated by `pending--register' and `pending--unregister'.")

(defvar-local pending--buffer-registry nil
  "Buffer-local list of pending structs that live in this buffer.
Kept in sync with `pending--registry' so buffer-scoped queries do not
have to scan the global table.")

(defvar pending--list-refresh-pending nil
  "Non-nil while a debounced `*Pending*' list-refresh is queued.
Set when `pending--list-refresh-if-live' schedules an idle timer to
do the actual repaint; cleared inside the timer callback before
the repaint runs.  A second `pending--list-refresh-if-live' call
arriving while the flag is set is coalesced — back-to-back
registry mutations only repaint once.")

(defun pending--list-refresh-flush ()
  "Run any pending `*Pending*' debounced refresh synchronously now.
Useful for tests and for callers that need the list view fully
in sync with the registry before reading `tabulated-list-entries'.
No-op when no refresh is queued."
  (when pending--list-refresh-pending
    (setq pending--list-refresh-pending nil)
    (let ((buf (get-buffer "*Pending*")))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (when (derived-mode-p 'pending-list-mode)
            (let ((inhibit-message t)
                  (point-line (line-number-at-pos)))
              (pending--list-populate)
              (tabulated-list-print t)
              (goto-char (point-min))
              (forward-line (1- point-line)))))))))


;;; Internal helpers

(defun pending--list-refresh-if-live ()
  "Schedule a refresh of the `*Pending*' buffer if it is live and visible.
Used to keep the list view in lockstep with the registry across
mutating paths — `pending--register' and `pending--unregister'
(which is invoked transitively from `pending--resolve-internal' and
`pending-stream-finish').  No-op when the buffer is missing, dead,
in a different mode, off-screen, or when
`pending-list-auto-refresh' is nil.

The repaint runs asynchronously through a one-shot 0.05s idle
timer so back-to-back mutations (e.g. resolving twenty placeholders
in a tight loop) coalesce into a single tabulated-list-print.  The
visibility gate skips the work entirely when no window shows
`*Pending*' — the user can press \\`g' on demand to refresh a
hidden buffer.

The timer body re-validates the buffer and mode at fire time
because the user could have killed the buffer or switched modes
during the idle window."
  (when (and pending-list-auto-refresh
             (not pending--list-refresh-pending)
             (let ((buf (get-buffer "*Pending*")))
               (and buf
                    (buffer-live-p buf)
                    (get-buffer-window buf 'visible))))
    (setq pending--list-refresh-pending t)
    (run-with-idle-timer
     0.05 nil
     (lambda ()
       (setq pending--list-refresh-pending nil)
       (let ((buf (get-buffer "*Pending*")))
         (when (and buf (buffer-live-p buf))
           (with-current-buffer buf
             (when (derived-mode-p 'pending-list-mode)
               (let ((inhibit-message t)
                     (point-line (line-number-at-pos)))
                 (pending--list-populate)
                 (tabulated-list-print t)
                 ;; Best-effort cursor restoration.
                 (goto-char (point-min))
                 (forward-line (1- point-line)))))))))))

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
        (add-hook 'kill-buffer-hook #'pending--on-kill-buffer nil t))))
  (pending--list-refresh-if-live))

(defun pending--unregister (p)
  "Remove P from the global and buffer-local pending registries.
Cancels P's `attached-timer' if any.  Does NOT delete the overlay or
clear markers — that happens in `pending--resolve-internal' since the
order matters for atomic region replacement.

When the buffer-local registry empties as a result of removing P,
the buffer-local `kill-buffer-hook' entry installed by
`pending--register' is also removed so a buffer that no longer
hosts any placeholders does not carry a stale hook into its
remaining lifetime.

Parks the global animation timer if the global registry has
emptied as a result of this removal."
  (remhash (pending-id p) pending--registry)
  (let ((buf (pending-buffer p)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq pending--buffer-registry
              (delq p pending--buffer-registry))
        (when (null pending--buffer-registry)
          (remove-hook 'kill-buffer-hook #'pending--on-kill-buffer t)))))
  (let ((tm (pending-attached-timer p)))
    (when (timerp tm)
      (cancel-timer tm))
    (setf (pending-attached-timer p) nil))
  ;; Note: the wrapper sentinel installed on `attached-process' (when
  ;; any) is left in place — detaching it here would race the active
  ;; sentinel callback we may be running inside of right now.  If the
  ;; process exits later, the call to `pending-reject' from the
  ;; wrapper is a no-op because the placeholder is already terminal.
  (when (zerop (hash-table-count pending--registry))
    (pending--park-timer))
  (pending--list-refresh-if-live))

(defun pending--swap-region (p new-text)
  "Atomically replace P's region with NEW-TEXT.
The replacement is wrapped in an `atomic-change-group' so undo sees
exactly one step.  `inhibit-read-only' and `inhibit-modification-hooks'
are bound around the swap so neither this library's own read-only
enforcement nor its modification hooks fight the operation.

NEW-TEXT is inserted as plain buffer text without any `face' property:
the placeholder library never adds a face to text it inserts itself.
Highlighting only ever appears as the overlay's `face' property when
the overlay covers EXISTING buffer text (adopt mode with BEG < END).

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
              (insert (or new-text ""))
              (set-marker (pending-end p) (point)))))))))

(defun pending--maybe-pulse (buffer start end)
  "Briefly highlight BUFFER's region [START, END] via `pulse.el'.
No-op when `pending-pulse-on-resolve' is nil, when `pulse' is
unavailable (require fails), when BUFFER is dead, when BUFFER has no
visible window (a flash on an off-screen buffer is wasted work), or
when START or END is nil or START >= END.

`pulse' is loaded lazily here so disabling the feature avoids the
library load entirely.  When `pulse-momentary-highlight-region' is
already `fboundp' the require call is skipped — this lets tests
substitute the function via `cl-letf' without our `require' load
overwriting the substitution from underneath them.

The visibility gate uses the cheap (selected frame only) variant
of `get-buffer-window' rather than the cross-frame `\\='visible'
form.  A buffer that resolves on an off-screen frame thus does not
pulse — that is the right tradeoff for a hot path that runs once
per resolve, since an unseen pulse is wasted CPU either way."
  (when (and pending-pulse-on-resolve
             (buffer-live-p buffer)
             (integerp start)
             (integerp end)
             (< start end)
             (get-buffer-window buffer)
             (or (fboundp 'pulse-momentary-highlight-region)
                 (require 'pulse nil 'noerror)))
    (with-current-buffer buffer
      (with-demoted-errors "pending--maybe-pulse: %S"
        (pulse-momentary-highlight-region start end)))))

(cl-defun pending--resolve-internal (p new-status reason new-text
                                       &optional run-on-resolve
                                       &key no-swap)
  "Flip P from a non-terminal state to terminal NEW-STATUS with REASON.
This is the single mutation path for terminal transitions; it
enforces the single-resolution invariant of DESIGN.md §2.

Steps:
  1. Bail out early if `pending-in-resolve' is already set on P
     (re-entrant guard) or if P is already in a terminal state.
  2. Set P's status, REASON-derived reason slot, and resolved-at.
  3. Unless NO-SWAP, replace the placeholder region with NEW-TEXT
     (plain text, no face) via `pending--swap-region'.  The NO-SWAP
     branch is used by `pending-stream-finish', which has already
     written the streamed content into the buffer and only needs the
     bookkeeping half of the resolve.
  4. Unregister P from both registries (also cancels P's deadline
     timer if any).
  5. Delete P's overlay and clear its markers.
  6. If NEW-STATUS is `:resolved' and `pending-pulse-on-resolve' is
     non-nil, briefly highlight the resolved text via `pulse.el'.
  7. If RUN-ON-RESOLVE is non-nil, fire P's `on-resolve' callback
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
          ;; Strip animation decorations before swapping the region
          ;; so the spinner glyph does not survive into the resolved
          ;; text.  No-op when the slot was never set.
          (when (and (overlayp (pending-ov p))
                     (overlay-buffer (pending-ov p)))
            (overlay-put (pending-ov p) 'before-string nil)
            (overlay-put (pending-ov p) 'after-string nil))
          (unless no-swap
            (pending--swap-region p new-text))
          ;; Capture the post-swap pulse range BEFORE we clear
          ;; markers and delete the overlay.  We pulse only on
          ;; successful resolution — reject and cancel paths set
          ;; new-status to `:rejected' or `:cancelled' and do not
          ;; trigger the flash.
          (let ((pulse-buf (and (eq new-status :resolved)
                                (pending-buffer p)))
                (pulse-start (and (eq new-status :resolved)
                                  (markerp (pending-start p))
                                  (marker-position (pending-start p))))
                (pulse-end (and (eq new-status :resolved)
                                (markerp (pending-end p))
                                (marker-position (pending-end p)))))
            (pending--unregister p)
            (let ((ov (pending-ov p)))
              (when (overlayp ov)
                (delete-overlay ov))
              (setf (pending-ov p) nil))
            (let ((sm (pending-start p))
                  (em (pending-end p)))
              (when (markerp sm) (set-marker sm nil))
              (when (markerp em) (set-marker em nil)))
            (when (eq new-status :resolved)
              (pending--maybe-pulse pulse-buf pulse-start pulse-end)))
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

(defun pending--on-modify (ov after _beg _end &optional _len)
  "Overlay modification hook: auto-cancel on region collapse or buffer death.
OV is the overlay carrying the `pending' property.  AFTER is non-nil
when the hook fires after the modification (we ignore the before-edit
call).  The remaining arguments — region beginning, end, and pre-edit
length — are unused; the decision is made by inspecting OV after the
fact.

Wired onto OV's `modification-hooks', `insert-in-front-hooks', and
`insert-behind-hooks' by `pending-make'.  Suppressed during the
library's own atomic resolve via the `inhibit-modification-hooks'
binding in `pending--swap-region', so the cancel-on-collapse path
fires only for user-initiated edits.

Cancels the pending placeholder with reason `:buffer-killed' when its
buffer has been killed, or `:region-deleted' when the overlay has
collapsed to zero length (the user has removed the entire region)."
  (when after
    (let ((p (overlay-get ov 'pending)))
      (when p
        (cond
         ;; Buffer killed — defer to the buffer-killed reason.
         ((or (null (overlay-buffer ov))
              (not (buffer-live-p (overlay-buffer ov))))
          (pending-cancel p :buffer-killed))
         ;; Overlay collapsed to zero length — user deleted the region.
         ((= (overlay-start ov) (overlay-end ov))
          (pending-cancel p :region-deleted)))))))


;;; Spinner animation

(defconst pending--spinner-frames-fallback
  '((dots-1 . ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
    (dots-2 . ["⠁" "⠂" "⠄" "⡀" "⢀" "⠠" "⠐" "⠈"])
    (line   . ["|" "/" "-" "\\"])
    (arc    . ["◜" "◠" "◝" "◞" "◡" "◟"])
    (clock  . ["🕛" "🕐" "🕑" "🕒" "🕓" "🕔" "🕕" "🕖" "🕗" "🕘" "🕙" "🕚"]))
  "Built-in spinner frame sets, used when `pending-spinner-styles' is unset.
The user-facing `pending-spinner-styles' defcustom shadows this; the
fallback ensures a vector is always available even if the user has
intentionally narrowed `pending-spinner-styles' or supplied an unknown
key.

See also: `pending-spinner-styles' (user-customizable counterpart).")

(defvar pending--global-timer nil
  "Single timer driving all active spinner animations.
Created lazily by `pending--ensure-timer' when the first placeholder is
made; parked by `pending--park-timer' or `pending--tick' once the
registry has no active placeholders left to animate.")

(defun pending--get-frames (style)
  "Return the frame vector for spinner STYLE.
First consults the user-facing `pending-spinner-styles' defcustom,
then the built-in `pending--spinner-frames-fallback', then falls back
to `pending-default-spinner-style' in either alist.  Always returns a
non-nil vector."
  (or (cdr (assq style pending-spinner-styles))
      (cdr (assq style pending--spinner-frames-fallback))
      (cdr (assq pending-default-spinner-style pending-spinner-styles))
      (cdr (assq pending-default-spinner-style
                 pending--spinner-frames-fallback))))

(defun pending--frame-index (p frames)
  "Return the spinner frame index for P given FRAMES vector.
The index is computed from elapsed wall-time so animation phase
remains consistent across timer parks and resumes; per DESIGN.md §4
this avoids the visible \"jump\" that a tick-counter would produce
when the timer is cancelled and re-armed."
  (let* ((elapsed (- (float-time) (or (pending-start-time p) (float-time))))
         (n (length frames)))
    (if (or (zerop n) (<= elapsed 0))
        0
      (mod (truncate (* (max 1 pending-fps) elapsed)) n))))

(defun pending--needs-redraw-p (p)
  "Return non-nil if P's overlay should re-render this tick.
P must be in an active lifecycle state (per `pending-active-p') and
live in a buffer that is currently displayed in some visible window
of some live frame."
  (and (pending-active-p p)
       (let ((buf (pending-buffer p)))
         (and (buffer-live-p buf)
              (get-buffer-window buf 'visible)))))


;;; SVG spinner (graphical frames only)

;; `svg.el' is loaded lazily inside `pending--svg-spinner' so callers
;; that disable the SVG path (via `pending-svg-spinner-enable' nil or
;; on TTY) never pull the library in.  The byte compiler still wants
;; to know these symbols exist.
(declare-function svg-create "svg" (width height &rest args))
(declare-function svg-circle "svg" (svg x y radius &rest args))
(declare-function svg-image  "svg" (svg &rest props))

(defvar pending--svg-cache (make-hash-table :test 'equal)
  "Cache of generated SVG spinner image strings.
Keyed on (FACE STYLE FRAME-INDEX SIZE) tuples, value is a
propertized one-character string whose `display' property is the
SVG image returned by `svg-image'.  Bounded by N styles M frames
K faces SIZE values, all small.  Cleared by the `:set' on
`pending-svg-spinner-size'.")

(defun pending--svg-spinner (frame-index frames-count face size)
  "Build a propertized image string for the SVG spinner glyph.
FRAME-INDEX selects the rotation angle (0..FRAMES-COUNT-1).
FRAMES-COUNT is the number of equally-spaced rotations.  FACE
contributes the stroke color (its foreground; falls back to the
`default' face's foreground, then to `currentColor').  SIZE is
the SVG width and height in pixels.

The returned value is a one-character string whose `display'
property is the SVG image, with `:ascent center' so it sits on
the text baseline correctly."
  (require 'svg)
  (let* ((angle (if (and (integerp frames-count) (> frames-count 0))
                    (* (/ 360.0 frames-count) frame-index)
                  0.0))
         (svg (svg-create size size))
         (cx (/ size 2.0))
         (cy (/ size 2.0))
         (radius (* size 0.35))
         (color (or (face-foreground face nil 'default) "currentColor"))
         ;; ~25% of the ring is the visible arc; the rest is the gap.
         ;; Compute as circumference fractions in user units.
         (circumference (* 2 float-pi radius))
         (dash-arc (* circumference 0.25))
         (gap-arc  (* circumference 0.75)))
    ;; Background ring at low opacity for visual stability.
    (svg-circle svg cx cy radius
                :stroke color :stroke-width 2 :fill "none"
                :opacity 0.25)
    ;; Foreground arc rotating clockwise.
    (svg-circle svg cx cy radius
                :stroke color :stroke-width 2 :fill "none"
                :stroke-dasharray (format "%.2f %.2f" dash-arc gap-arc)
                :transform (format "rotate(%.2f %.2f %.2f)" angle cx cy))
    (propertize " " 'display (svg-image svg :ascent 'center))))

(defun pending--svg-cached (frame-index frames-count style face size)
  "Return a cached SVG spinner string, creating it if absent.
FRAME-INDEX is the rotation index (0..FRAMES-COUNT-1).
FRAMES-COUNT is the number of equally-spaced rotations in the
animation cycle.  STYLE is the spinner style symbol (used in the
cache key only).  FACE supplies the stroke colour.  SIZE is the
SVG width and height in pixels.

The cache key is (FACE STYLE FRAME-INDEX SIZE) so distinct styles,
faces, sizes, and per-style rotation positions are all memoized
independently.  See `pending--svg-spinner' for the generation
details."
  (let ((key (list face style frame-index size)))
    (or (gethash key pending--svg-cache)
        (puthash key
                 (pending--svg-spinner frame-index frames-count face size)
                 pending--svg-cache))))

(defun pending--svg-spinner-available-p ()
  "Return non-nil if the SVG spinner path should run.
True when the user has not disabled it via
`pending-svg-spinner-enable', the current frame is graphical, and
SVG image support is compiled into Emacs."
  (and pending-svg-spinner-enable
       (display-graphic-p)
       (image-type-available-p 'svg)))


;;; Progress bar rendering

(defconst pending--bar-blocks-eighths
  ["·" "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█"]
  "Eighths-resolution bar characters (index 0..8).
Index 0 is empty (a middle dot used as a faint dotted background) and
index 8 is full.  Indices 1..7 use Unicode block elements at
eighth-cell resolution so the bar advances smoothly rather than in
whole-cell jumps.")

(defconst pending--bar-blocks-ascii
  ["." "." "-" "-" "+" "+" "*" "*" "#"]
  "ASCII fallback bar characters (index 0..8).
Approximates eighths-resolution within ASCII: empty `.', then
quarter `-', then half `+', then three-quarters `*', then full
\\=`#'.  Used when `pending-bar-style' is `ascii'.")

(defun pending--bar-blocks ()
  "Return the bar-character vector for `pending-bar-style'.
`eighths' (default) selects `pending--bar-blocks-eighths'; `ascii'
selects `pending--bar-blocks-ascii'.  Any other value falls through to
the eighths vector."
  (pcase pending-bar-style
    ('ascii pending--bar-blocks-ascii)
    (_      pending--bar-blocks-eighths)))

(defun pending--render-bar (fraction width)
  "Render a progress bar of WIDTH cells, FRACTION in [0.0, 1.0].
FRACTION outside that range is silently clamped.  WIDTH is the visible
character count, not the byte length — Unicode block characters in
`pending--bar-blocks-eighths' are multi-byte, so we build the bar via
`concat' rather than `aset' on a unibyte buffer.

The returned string is propertized with `pending-progress-face' and is
exactly WIDTH visible characters wide.  Style selection is governed by
`pending-bar-style' via `pending--bar-blocks'."
  (let* ((blocks (pending--bar-blocks))
         (max-i  (1- (length blocks)))
         (clamp  (max 0.0 (min 1.0 (or fraction 0.0))))
         (units  (truncate (* clamp width max-i)))
         (full   (/ units max-i))
         (partial (mod units max-i))
         (full-char  (aref blocks max-i))
         (empty-char (aref blocks 0))
         (parts  '()))
    ;; Build right-to-left so a single `apply #'concat' produces the
    ;; final string in the correct order.  Handle the case where the
    ;; bar is exactly full (full == width) separately so we do not push
    ;; an extra partial cell that would overflow WIDTH.
    (let ((empty-count (max 0 (- width full (if (< full width) 1 0)))))
      (dotimes (_ empty-count)
        (push empty-char parts))
      (when (< full width)
        (push (aref blocks partial) parts))
      (dotimes (_ full)
        (push full-char parts)))
    (propertize (apply #'concat parts) 'face 'pending-progress-face)))

(defconst pending--eta-ceiling (- 1.0 1e-9)
  "Strict upper bound on the visible ETA fraction.
Floating-point arithmetic saturates `(- 1.0 (* 0.05 (exp x)))' to
exactly 1.0 once the exponential term drops below double-precision
machine epsilon (around `ratio = 35').  We clamp the final value
slightly below 1.0 so callers can rely on the strict invariant
\"ETA fraction is in [0.0, 1.0)\".")

(defun pending--eta-fraction (start-time eta &optional now)
  "Return the visual fraction in [0.0, 1.0) for an ETA-mode bar.
START-TIME is the `float-time' when the placeholder was created.  ETA
is the estimated total seconds (a positive number).  NOW defaults to
`(float-time)'.  Never returns 1.0 — saturates asymptotically toward
1.0 past the deadline so we cannot claim \"done\" until the caller
actually resolves.  The final value is clamped to
`pending--eta-ceiling' so the strict upper bound holds even at large
ratios where IEEE 754 would otherwise round to exactly 1.0.

Formula (piecewise, mirroring DESIGN.md §4):
  ratio = (now - start-time) / eta
  ratio <= 0           -> 0
  0 < ratio <= 0.8     -> ratio
  0.8 < ratio <= 1.0   -> 0.8 + (ratio - 0.8) * 0.75   (linear to 0.95)
  ratio > 1.0          -> 1 - 0.05 * exp(-(ratio - 1)) (asymptote)

Yields these checkpoints:
  t = 0      -> 0.0
  t = 0.5 T  -> 0.5
  t = 0.8 T  -> 0.8
  t = T      -> 0.95
  t = 2 T    -> ~0.9816
  t = 4 T    -> ~0.99752"
  (let* ((t-now (or now (float-time)))
         (elapsed (- t-now start-time))
         (ratio (if (and (numberp eta) (> eta 0)) (/ elapsed eta) 0.0)))
    (cond
     ((<= ratio 0) 0.0)
     ((<= ratio 0.8) ratio)
     ((<= ratio 1.0) (+ 0.8 (* (- ratio 0.8) 0.75)))
     (t (min pending--eta-ceiling
             (- 1.0 (* 0.05 (exp (- 1.0 ratio)))))))))

(defun pending--render (p)
  "Update P's overlay decoration for the current frame.
Dispatches on `(pending-indicator p)':
  `:spinner' — `before-string' is the spinner glyph plus a space; no
              `after-string'.
  `:percent' — `before-string' is the spinner glyph; `after-string'
              is a determinate progress bar derived from
              `(pending-percent p)' followed by the rounded percent.
  `:eta'     — `before-string' is the spinner glyph; `after-string'
              is a piecewise-asymptotic progress bar derived from time
              elapsed vs `(pending-eta p)' followed by the estimated
              remaining seconds.
  `:lighter' — static badge mode: `before-string' is the placeholder's
              label propertized with `pending-lighter'.  No animation,
              no after-string.  Used by `pending-region' and
              `pending-insert' for visual badge placeholders.

The spinner glyph debounces via `(pending-last-frame p)' so we only
re-propertize the `before-string' when the frame index has actually
moved.  The `after-string' is rebuilt every tick — rendering 10
short bar strings per second is microsecond-scale and not worth
caching at this stage.  No-op if the overlay has been deleted.

In `:lighter' mode the spinner-glyph block is skipped entirely so
no animation cost is paid; the badge is rendered once below."
  (let* ((ov (pending-ov p))
         (indicator (or (pending-indicator p) :spinner))
         ;; Optional fringe-bitmap proxy stashed by `pending-make'.
         ;; Prepended to whatever the indicator wants in
         ;; `before-string' so the fringe cue scrolls with the line
         ;; and survives the frame-index debounce path below.
         (fringe (overlay-get ov 'pending--fringe-string)))
    (when (and (overlayp ov) (overlay-buffer ov))
      ;; Spinner glyph — same code path in every indicator mode except
      ;; `:lighter', which uses a static badge in `before-string' below
      ;; and must not have its frame index advanced.
      (unless (eq indicator :lighter)
        (let* ((style (or (pending-spinner-style p)
                          pending-default-spinner-style))
               (frames (pending--get-frames style))
               (frame (pending--frame-index p frames)))
          (unless (eql frame (pending-last-frame p))
            (let ((glyph-str
                   (if (pending--svg-spinner-available-p)
                       ;; SVG image string (one-character propertized
                       ;; space whose `display' is the SVG image).  No
                       ;; trailing space — the image already occupies
                       ;; visual width.
                       (pending--svg-cached
                        frame (length frames) style
                        'pending-spinner-face
                        pending-svg-spinner-size)
                     ;; Unicode text glyph (the v0.1 fallback).
                     (propertize (concat (aref frames frame) " ")
                                 'face 'pending-spinner-face))))
              (overlay-put
               ov 'before-string
               (if fringe (concat fringe glyph-str) glyph-str)))
            (setf (pending-last-frame p) frame))))
      ;; Mode-specific decoration.
      (pcase indicator
        (:spinner
         (overlay-put ov 'after-string nil))
        (:percent
         (let* ((raw  (or (pending-percent p) 0.0))
                (frac (max 0.0 (min 1.0 raw)))
                (bar  (pending--render-bar frac pending-bar-width))
                (txt  (format " %s %d%%" bar (round (* 100 frac)))))
           (overlay-put ov 'after-string
                        (propertize txt 'face 'pending-progress-face))))
        (:eta
         (let* ((eta   (or (pending-eta p) 0.001))
                (start (or (pending-start-time p) (float-time)))
                (now   (float-time))
                (frac  (pending--eta-fraction start eta now))
                (bar   (pending--render-bar frac pending-bar-width))
                (remaining-secs (max 1 (round (- eta (- now start)))))
                (txt   (format " %s ~%ds" bar remaining-secs)))
           (overlay-put ov 'after-string
                        (propertize txt 'face 'pending-progress-face))))
        (:lighter
         (let ((badge (propertize (or (pending-label p) "")
                                  'face 'pending-lighter)))
           (overlay-put ov 'before-string
                        (if fringe (concat fringe badge) badge)))
         (overlay-put ov 'after-string nil))))))

(defun pending--ensure-timer ()
  "Start the global animation timer if it is not running.
Idempotent: a no-op when the timer is already live."
  (unless (and pending--global-timer (timerp pending--global-timer))
    (setq pending--global-timer
          (run-with-timer 0 (/ 1.0 (max 1 pending-fps)) #'pending--tick))))

(defun pending--park-timer ()
  "Cancel the global animation timer.
Called when `pending--tick' notices no placeholder needs animation, or
when `pending--unregister' empties the registry.  Safe to call when
the timer is already nil."
  (when (timerp pending--global-timer)
    (cancel-timer pending--global-timer))
  (setq pending--global-timer nil))

(defun pending--tick ()
  "Drive one animation frame across all registered placeholders.
Renders visible active placeholders.  Parks the global timer if no
active placeholder is currently in a visible window — the
`window-buffer-change-functions' hook re-arms it when one becomes
visible.

Per-render errors are caught with `with-demoted-errors' so a buggy
render path on one placeholder cannot kill the timer for everyone."
  (let ((any-visible nil))
    (maphash
     (lambda (_id p)
       (when (pending--needs-redraw-p p)
         (setq any-visible t)
         (with-demoted-errors "pending--tick render error: %S"
           (pending--render p))))
     pending--registry)
    (unless any-visible
      (pending--park-timer))))

(defun pending--on-window-buffer-change (_window-or-frame)
  "Re-arm the global timer if any active placeholder is now visible.
Hooked onto `window-buffer-change-functions' so a placeholder whose
buffer becomes visible after the timer parked itself starts animating
again at the next available tick."
  (let ((needed nil))
    (maphash (lambda (_id p)
               (when (pending--needs-redraw-p p)
                 (setq needed t)))
             pending--registry)
    (when needed
      (pending--ensure-timer))))

(add-hook 'window-buffer-change-functions
          #'pending--on-window-buffer-change)


;;; Overlay keymap

(defvar pending-region-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'pending-cancel-at-point)
    (define-key m [mouse-1] #'pending-cancel-at-point)
    m)
  "Keymap installed on the placeholder overlay.
Bound to `RET' and `mouse-1' for `pending-cancel-at-point' so the user
can cancel an active placeholder by activating it directly.")


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
    in BUFFER.  The inserted label text is propertized read-only so
    the user cannot edit it while the async work is active; the
    library lifts the read-only restriction during its own resolve.
  - If START and END are both non-nil (positions or markers), adopt
    the existing region [START, END]; do not insert text.  When
    `pending-protect-adopted-region' is non-nil (the default), the
    adopted text is made read-only via text properties so the user
    cannot edit the placeholder while the async work is active;
    the protection survives into indirect buffers since it lives on
    the buffer text itself.  Set the option to nil to opt out and
    leave the adopted text editable.
  - It is an error to supply only one of START or END.

LABEL is a short string shown inside the placeholder, default
\"Pending\".  GROUP is an optional symbol for filtering.

INDICATOR selects the visual; `:spinner' (default), `:percent', or
`:eta'.  PERCENT and ETA prime the determinate / ETA modes; FACE
overrides `pending-face' for the OVERLAY's `face' property — used
only when the overlay covers existing buffer text (adopt mode with
BEG < END); insert and zero-width adopt overlays carry no face.
The library never faces text it inserts itself.  SPINNER-STYLE
selects an entry from `pending-spinner-styles'.

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
         (raw-label (or label "Pending"))
         ;; Honour `pending-label-max-width': the inserted label is
         ;; truncated with an ellipsis so a very long string (e.g. a
         ;; user prompt or stack trace) does not blow out the layout.
         ;; The struct's `label' slot stores this truncated form per
         ;; the docstring on `pending-label-max-width' — callers that
         ;; need the original should keep it in their own state.
         (resolved-label
          (if (and (integerp pending-label-max-width)
                   (> pending-label-max-width 0)
                   (> (length raw-label) pending-label-max-width))
              (truncate-string-to-width
               raw-label (max 1 pending-label-max-width)
               0 nil "…")
            raw-label))
         (resolved-indicator (or indicator :spinner))
         (resolved-spinner (or spinner-style pending-default-spinner-style))
         (resolved-face (or face 'pending-face))
         (inhibit-read-only (or inhibit-read-only pending-allow-read-only))
         (adopt-mode-p (and start end))
         start-marker
         end-marker)
    (with-current-buffer buffer
      (cond
       ;; Insert mode.
       ((and (null start) (null end))
        (let ((insert-point (point)))
          (setq start-marker (copy-marker insert-point nil))
          ;; Insert the label text propertized read-only so the user
          ;; cannot edit the placeholder while the async work is
          ;; active.  `front-sticky (read-only)' makes insertions just
          ;; before the placeholder block too -- otherwise a user
          ;; positioned at the start could sneak text in front.
          ;; `rear-nonsticky (read-only)' makes insertions immediately
          ;; after the placeholder explicitly allowed.  The library's
          ;; own swap is wrapped in `inhibit-read-only' so the
          ;; placeholder remains mutable from the inside.
          ;; No `face' property: the library never faces text it
          ;; inserts itself.  Highlighting only ever appears as the
          ;; overlay's `face' property when the overlay covers
          ;; existing buffer text (adopt mode with BEG < END).
          (insert (propertize resolved-label
                              'read-only t
                              'front-sticky '(read-only)
                              'rear-nonsticky '(read-only)))
          ;; End marker is insertion-type nil at construction.
          ;; `pending-stream-insert' flips it to t on the first chunk
          ;; so subsequent inserts at its position append rather than
          ;; push the marker; `pending-stream-finish' flips it back
          ;; to nil so the resolved text is not stretched by typing
          ;; immediately after.  Mirrors gptel's tracking-marker
          ;; discipline (gptel.el:1389, 1794).  At rest, with no
          ;; streaming in progress, typing just after the placeholder
          ;; lands outside the region — the canonical smoke-test
          ;; behaviour.
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
          (setq end-marker (copy-marker e nil))
          ;; Apply read-only text properties to the adopted region so
          ;; the user cannot edit the placeholder while it is active.
          ;; Text properties live in the buffer text itself and ARE
          ;; inherited by indirect buffers, so this also projects edit
          ;; protection into any indirect view.  Skipped when
          ;; `pending-protect-adopted-region' is nil or when the range
          ;; is empty (no text to protect).  The library binds
          ;; `inhibit-read-only' inside its own resolve / cancel /
          ;; reject path so the swap is not blocked.  On terminal
          ;; transition, `pending--swap-region' deletes the adopted
          ;; range, so the read-only properties disappear together
          ;; with the protected text — no separate cleanup needed.
          (when (and pending-protect-adopted-region (< s e))
            (let ((inhibit-read-only t))
              (add-text-properties
               s e
               '(read-only t
                           front-sticky (read-only)
                           rear-nonsticky (read-only)))))))))
    ;; Overlay front- and rear-advance default to nil; the end
    ;; marker's insertion-type is flipped to t by
    ;; `pending-stream-insert' so streamed chunks extend the
    ;; placeholder cleanly.
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
               :ov ov
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
               :in-resolve nil
               :last-frame nil)))
      (overlay-put ov 'pending p)
      ;; Only apply the overlay face when the overlay covers existing
      ;; buffer text — adopt mode with a non-empty range.  In insert
      ;; mode the overlay covers freshly-inserted label text (which
      ;; the library policy says must NOT be faced), and in zero-width
      ;; adopt mode there is no region to highlight; in both cases
      ;; the overlay's `face' is left unset.  See `pending--swap-region':
      ;; the library never faces text it inserts itself either.
      (when adopt-mode-p
        (let ((sp (marker-position start-marker))
              (ep (marker-position end-marker)))
          (when (and sp ep (< sp ep))
            (overlay-put ov 'face resolved-face))))
      (overlay-put ov 'priority 100)
      (overlay-put ov 'evaporate nil)
      ;; Optional fringe-bitmap proxy.  When `pending-fringe-bitmap'
      ;; names a registered fringe bitmap and we are on a graphical
      ;; frame, stash a 1-character string whose `display' property
      ;; is `(left-fringe BITMAP pending-spinner-face)'.  The render
      ;; loop prepends this to whatever spinner / lighter glyph the
      ;; indicator wants in `before-string', so the placeholder
      ;; carries a fringe cue that scrolls with the buffer line.
      ;; Skipped on tty per `display-graphic-p'.
      (when (and pending-fringe-bitmap (display-graphic-p))
        (overlay-put
         ov 'pending--fringe-string
         (propertize "!"
                     'display
                     (list 'left-fringe
                           pending-fringe-bitmap
                           'pending-spinner-face))))
      ;; Modification hooks fire on user edits inside the region or at
      ;; its edges.  They detect the "user deleted the placeholder"
      ;; case and auto-cancel with `:region-deleted'.
      ;; `pending--swap-region' binds `inhibit-modification-hooks' so
      ;; the library's own resolve does not retrigger them.
      (overlay-put ov 'modification-hooks '(pending--on-modify))
      (overlay-put ov 'insert-in-front-hooks '(pending--on-modify))
      (overlay-put ov 'insert-behind-hooks '(pending--on-modify))
      (overlay-put ov 'help-echo
                   (lambda (_window _object _pos)
                     (format "Pending: %s [%s]"
                             (pending-label p)
                             (pending-status p))))
      ;; Bind RET / mouse-1 over the placeholder so the user can cancel
      ;; an active placeholder interactively without typing the
      ;; command's name.  See `pending-region-map'.
      (overlay-put ov 'keymap pending-region-map)
      (pending--register p)
      ;; For `:lighter' (static badge) mode, render once now so the
      ;; lighter is visible without waiting for the animation timer.
      ;; The timer's visibility gate would otherwise delay rendering
      ;; until the buffer is shown, which is wrong for a static badge
      ;; that callers expect to see immediately on construction.
      (when (eq resolved-indicator :lighter)
        (with-demoted-errors "pending--render initial lighter: %S"
          (pending--render p)))
      ;; Wake the global animation timer; safe no-op if it is already
      ;; running.  See `pending--ensure-timer' and DESIGN.md §4 for the
      ;; single-timer rationale.
      (pending--ensure-timer)
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


;;; Public API: simple positional surface (overlay / insert / goto / alist)

;;;###autoload
(defun pending-region (beg-or-token &optional end str)
  "Create a pending overlay or return a token's overlay.

BEG-OR-TOKEN is either a buffer position (integer or marker) — in
which case END and STR must also be supplied — or a `pending'
struct, in which case END and STR are nil.

Two call shapes are supported:

  (pending-region BEG END STR)
    Mark the region [BEG, END] in the current buffer as pending an
    asynchronous change.  Highlights the region with
    `pending-highlight' face and shows STR as a lighter badge at BEG
    using `pending-lighter' face.  If BEG equals END, no region is
    highlighted; only the lighter shows.  The lighter is a visual
    `before-string' overlay; no buffer text is inserted.  Returns a
    TOKEN (a `pending' struct) usable with `pending-finish',
    `pending-cancel', and `pending-goto'.  The token is registered in
    the global registry; query snapshots via `pending-alist' and the
    interactive `pending-list' command.

  (pending-region TOKEN)
    Back-compat accessor: return the live overlay object owned by
    TOKEN, or nil if the placeholder has been resolved or cleaned up.
    Equivalent to `(pending-ov TOKEN)'.

The 3-arg form is a thin wrapper around `pending-make' optimised
for the common visual-badge use case."
  (cond
   ;; Accessor form: 1 arg, must be a pending struct.
   ((and (null end) (null str))
    (pending-ov beg-or-token))
   ;; Constructor form: 3 args, BEG is integer/marker.
   (t
    (pending-make (current-buffer)
                  :start beg-or-token
                  :end end
                  :label str
                  :indicator :lighter
                  :face 'pending-highlight))))

;;;###autoload
(defun pending-insert (pos str)
  "Mark POS as pending insertion of asynchronously-computed text.
Shows STR as a lighter badge at POS using `pending-lighter' face.
No region is highlighted (BEG = END).

Returns a TOKEN usable with `pending-finish', `pending-cancel',
and `pending-goto'.  When eventually resolved with text via
`pending-finish', the text is inserted at POS."
  (pending-region pos pos str))

(defun pending-alist ()
  "Return an alist snapshot of all currently registered pending placeholders.
Each element is (ID . PENDING-STRUCT).  Order is unspecified.

This is a fresh list; mutating the alist does not affect the
underlying registry.  Use the API functions (`pending-finish',
`pending-cancel', `pending-goto') to operate on tokens."
  (let (result)
    (maphash
     (lambda (id p) (push (cons id p) result))
     pending--registry)
    result))

(defun pending--read-token (prompt)
  "Read a pending token via `completing-read' with PROMPT.
Each completion candidate is a human-readable summary of one
registered placeholder; the matching value is the placeholder
struct itself.  Signals a `user-error' when no placeholders
are registered."
  (let* ((alist (pending-alist))
         (choices
          (mapcar
           (lambda (entry)
             (let* ((p (cdr entry))
                    (label (or (pending-label p) ""))
                    (key (format "%s [%s] %s"
                                 (symbol-name (car entry))
                                 (or (and (buffer-live-p (pending-buffer p))
                                          (buffer-name (pending-buffer p)))
                                     "<dead>")
                                 label)))
               (cons key p)))
           alist)))
    (unless choices
      (user-error "No pending placeholders registered"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

;;;###autoload
(defun pending-goto (token)
  "Move point to the buffer position of TOKEN.
TOKEN is a `pending' struct as returned by `pending-region' or
`pending-insert'.  Switches to TOKEN's buffer if it is not already
current.  Signals a `user-error' if the buffer is dead.

Interactively, prompt with `completing-read' over the registered
placeholders."
  (interactive
   (list (pending--read-token "Goto pending: ")))
  (let ((buf (pending-buffer token)))
    (unless (buffer-live-p buf)
      (user-error "Pending token's buffer is dead"))
    (pop-to-buffer-same-window buf)
    (when (and (markerp (pending-start token))
               (marker-position (pending-start token)))
      (goto-char (pending-start token)))))


;;; Public API: terminal transitions

(defun pending-finish (p text)
  "Atomically replace P's placeholder region with TEXT.
Transition P to `:resolved'.  Return t on success, or nil if P was
already in a terminal state (in which case a `:debug' warning is
logged).

TEXT is inserted as plain buffer text with no `face' property — the
library never faces text it inserts itself.

The replacement happens inside an `atomic-change-group' so undo sees
one step, with `inhibit-read-only' and `inhibit-modification-hooks'
bound during the swap.  Side effects: removes the overlay, clears
markers, unregisters P, cancels its deadline timer, and runs the
`on-resolve' callback once (errors there are caught and warned)."
  (pending--resolve-internal p :resolved nil text t))

(defun pending-reject (p reason &optional replacement-text)
  "Mark P as failed with REASON and replace its region.
REASON should be a string or a keyword/symbol describing the failure.
REPLACEMENT-TEXT defaults to a glyph plus the reason.  Transition P
to `:rejected' and return t on success, or nil if P was already
terminal.

The inserted text carries no `face' property — the library never
faces text it inserts itself; surrounding font-lock and major-mode
faces apply normally.

Side effects mirror `pending-finish' (removes overlay, clears
markers, unregisters, cancels timer, runs `on-resolve')."
  (let ((text (or replacement-text
                  (format "✗ %s"
                          (if reason
                              (pending--format-reason reason)
                            "Failed")))))
    (pending--resolve-internal p :rejected reason text t)))

(defun pending-cancel (p &optional reason)
  "Cancel P, optionally with REASON (default `:cancelled-by-user').
Call P's `on-cancel' callback FIRST, so the caller can abort its
underlying work (e.g. kill a process).  Then transition P to
`:cancelled' and replace its region with a small cancelled glyph.

The inserted glyph carries no `face' property — the library never
faces text it inserts itself; surrounding font-lock and major-mode
faces apply normally.

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
                :error))
              (quit
               ;; If on-cancel signals quit (e.g. user types C-g during a
               ;; `y-or-n-p' inside the callback), the quit would otherwise
               ;; propagate past this `unwind-protect' cleanup and skip the
               ;; subsequent `pending--resolve-internal' below — leaving the
               ;; placeholder wedged in a non-terminal state.  Convert quit
               ;; into a warning so the cancel pipeline still completes.
               (display-warning
                'pending
                (format "on-cancel callback for %s quit — proceeding with cancel"
                        (pending-id p))
                :warning))))
        (setf (pending-in-resolve p) nil))
      (pending--resolve-internal
       p :cancelled effective-reason
       (format "✗ %s" (pending--format-reason effective-reason))
       t)))))


;;; Public API: streaming

(defun pending-stream-insert (p chunk)
  "Append CHUNK (a string) to P's placeholder region.
The spinner / progress indicator stays visible.

On the first chunk (when P is `:scheduled' or `:running') the
loading-label content is deleted and replaced by CHUNK, the end
marker's insertion-type is flipped to t, and the status transitions
to `:streaming'.  Subsequent chunks append at the end marker, which
advances with the insert because of its insertion-type.

Streamed text gets the same read-only properties as the initial
label (`read-only' t, `front-sticky' \\='(read-only),
`rear-nonsticky' \\='(read-only)) so the user cannot edit it
mid-stream.  `pending-stream-finish' strips these properties so the
resolved text becomes editable.  The streamed text carries no
`face' property — the library never faces text it inserts itself;
the buffer's normal font-lock applies.  The overlay is grown via
`move-overlay' so its decorations and modification-hooks cover the
streamed text too.

This does NOT finalize.  The caller must follow up with
`pending-stream-finish', `pending-reject', or `pending-cancel'.

If P is already terminal, this is a no-op and a `:debug' warning is
logged (the chunk is dropped).

CHUNK must be a string; an empty string is a no-op.  Signals
`wrong-type-argument' if CHUNK is not a string."
  (cond
   ((not (stringp chunk))
    (signal 'wrong-type-argument (list 'stringp chunk)))
   ((zerop (length chunk)) nil)
   ((pending--terminal-status-p (pending-status p))
    (display-warning
     'pending
     (format "Drop stream chunk: %s already terminal (%s)"
             (pending-id p) (pending-status p))
     :debug)
    nil)
   (t
    (let ((buf (pending-buffer p)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((first-chunk-p
                 (memq (pending-status p) '(:scheduled :running))))
            ;; First chunk: delete the label content (it was just a
            ;; loading placeholder), flip end marker insertion-type to
            ;; t, and transition state.  This mirrors gptel's
            ;; tracking-marker pattern at gptel.el:1794 and gives the
            ;; user the natural visual: the "Calling Claude" label is
            ;; replaced by the first arriving chunk of real content.
            (when first-chunk-p
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t)
                    (start (marker-position (pending-start p)))
                    (end (marker-position (pending-end p))))
                (when (and start end (< start end))
                  (delete-region start end)))
              (set-marker-insertion-type (pending-end p) t)
              (setf (pending-status p) :streaming)))
          ;; Insert at the end marker.  With insertion-type t the
          ;; marker advances past the inserted text on its own.
          ;; `inhibit-modification-hooks' prevents `pending--on-modify'
          ;; from firing on this library-internal insert.  No `face'
          ;; property: the library never faces text it inserts itself.
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t))
            (save-excursion
              (goto-char (pending-end p))
              (insert (propertize chunk
                                  'read-only t
                                  'front-sticky '(read-only)
                                  'rear-nonsticky '(read-only)))))
          ;; Grow the overlay to cover the streamed text so its face,
          ;; decorations, and modification-hooks track the new range.
          ;; Without this, the overlay would still cover only the
          ;; original [start, end] and edits inside the streamed
          ;; region would not be detected.
          (let ((ov (pending-ov p)))
            (when (and (overlayp ov) (overlay-buffer ov))
              (move-overlay ov
                            (marker-position (pending-start p))
                            (marker-position (pending-end p)))))
          t))))))

(defun pending-stream-finish (p)
  "Finalize a streamed placeholder.
Transition P from `:streaming' to `:resolved'.  Lock the end marker
by flipping its insertion-type back to nil, strip read-only
properties from the streamed region (so the user can edit the
resolved text), then route through `pending--resolve-internal' with
the NO-SWAP flag so the buffer text already streamed in is left
alone but the standard bookkeeping (status flip, unregister, marker
clear, pulse, on-resolve) runs through the single mutation path.
Mirrors gptel's finalize pattern at gptel.el:1389.
Return t on success.
If P is `:scheduled' or `:running' (no chunks were ever streamed),
behave like `(pending-finish P \"\")'.
If P is already terminal, this is a no-op and a `:debug' warning
is logged.

Re-entrancy note: routing through `pending--resolve-internal' makes
a re-entrant call (e.g. from inside an `on-cancel' callback that
ran while the placeholder is in `:cancelled' or back-to-back inside
the same finalize) hit the in-resolve guard cleanly — the original
terminal status wins and the second call returns nil rather than
clobbering the reason or firing the wrong callback."
  (cond
   ((pending--terminal-status-p (pending-status p))
    (display-warning
     'pending
     (format "ignoring stream-finish on already-terminal placeholder %s (status %s)"
             (pending-id p) (pending-status p))
     :debug)
    nil)
   ((memq (pending-status p) '(:scheduled :running))
    ;; No chunks ever streamed — replace the label with the empty
    ;; string, going through the regular resolve path.
    (pending-finish p ""))
   ((pending-in-resolve p)
    ;; Re-entered while a resolve is already in progress on this
    ;; placeholder (e.g. an `on-cancel' callback for a parallel
    ;; cancel called us).  Refuse the operation; the in-flight
    ;; resolve owns the terminal transition.
    nil)
   (t
    ;; In :streaming state — pre-process the buffer-side bits
    ;; (lock end marker, strip read-only on streamed text) and then
    ;; delegate the bookkeeping half of the resolve to
    ;; `pending--resolve-internal' via NO-SWAP so the streamed
    ;; content stays put but the in-resolve guard, status flip,
    ;; unregister, marker-clear, pulse, and on-resolve all run
    ;; through the single mutation path.
    (let ((buf (pending-buffer p)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (set-marker-insertion-type (pending-end p) nil)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (start (marker-position (pending-start p)))
                (end (marker-position (pending-end p))))
            (when (and start end)
              ;; Strip read-only and stickiness from the streamed
              ;; region so the resolved text becomes ordinary
              ;; editable text.  Streamed chunks carry no `face'
              ;; property either, so there is nothing visual to
              ;; preserve here.
              (remove-text-properties
               start end
               '(read-only nil front-sticky nil rear-nonsticky nil)))))))
    (pending--resolve-internal p :resolved nil nil t :no-swap t))))


;;; Public API: process integration

(defun pending--process-sentinel (p process _event)
  "Internal sentinel handling PROCESS lifecycle for pending P.
Reads the live process state via `process-status':

  exit, signal, closed, failed -> the process is dead.  If P is
  still active and exit was clean, reject with \"process exited
  without resolving\".  Otherwise reject with the status symbol.

  run, open, stop, listen, connect -> the process is alive (or
  resuming).  No-op.

The kernel-level status is authoritative — the EVENT string is
localized and varies across process types, but `process-status'
is a documented C-API symbol.  Notably this means non-terminal
events such as `\"open\\n\"' \(network connect), `\"run\\n\"'
\(resumed from stop), and `\"stopped\\n\"' \(SIGSTOP/SIGTSTP) are
correctly treated as no-ops."
  (when (pending-active-p p)
    (let ((status (process-status process)))
      (pcase status
        ('exit
         ;; Clean exit but no explicit resolve.
         (let ((code (process-exit-status process)))
           (if (zerop code)
               (pending-reject p "process exited without resolving")
             (pending-reject p (format "process: exited with code %d" code)))))
        ('signal
         ;; Killed by a signal.  process-exit-status returns the signal number.
         (pending-reject p (format "process: killed (signal %d)"
                                   (process-exit-status process))))
        ('failed
         (pending-reject p "process: failed"))
        ('closed
         ;; Network process: peer closed the connection.
         (pending-reject p "process: connection closed"))
        ;; Any other status (run, open, stop, listen, connect) — alive.
        (_ nil)))))

(defun pending-attach-process (p process)
  "Wire PROCESS so that its death rejects P appropriately.
P is a pending struct returned by `pending-make'.  PROCESS is a
process object (typically returned by `make-process' or
`start-process').
The process's existing sentinel, if any, is preserved: it runs
FIRST, then a wrapper handles automatic state transitions.  Errors
signalled from the existing sentinel are caught and reported as
`pending' warnings so a buggy caller-installed sentinel does not
prevent the wrapper's lifecycle handling.
Lifecycle handling (in the wrapper) consults `process-status', not
the event string, so it survives localized event strings and handles
non-terminal events such as `\"open\\n\"' (network
connect), `\"run\\n\"' (resumed), and `\"stopped\\n\"' (suspended):
  - `exit' status with code 0 — if P is still active, reject with
    \"process exited without resolving\".  This represents a
    process that ran to completion but the caller did not call
    `pending-finish' on P explicitly.
  - `exit' with non-zero code, `signal', `failed', or `closed' —
    reject with a `\"process: ...\"' reason describing the cause.
  - Any live status (`run', `open', `stop', `listen', `connect') —
    no-op; the placeholder remains active.
If multiple processes are attached over P's lifetime, the LAST
attach wins for the `attached-process' slot, but each prior
process's wrapper sentinel still chains through to its predecessor
— so a stale process exit will still flow into `pending-reject',
which is a no-op once P is terminal because of the
single-resolution guard.
The PROCESS reference is stored in P's `attached-process' slot.
Return P."
  (let ((existing (process-sentinel process)))
    ;; If our own previous wrapper is still installed (this caller
    ;; is re-attaching the same process across multiple
    ;; `pending-attach-process' calls), peel one layer so successive
    ;; attaches do not pile up O(K) closures each chaining through
    ;; the previous one.  Detection rides on a `pending--wrapped-by'
    ;; entry on the process object; the original sentinel that
    ;; predates any pending wrapping is captured under
    ;; `pending--wrapped-original' so each new wrapper keeps the
    ;; same outermost target.
    (when (process-get process 'pending--wrapped-by)
      (setq existing (process-get process 'pending--wrapped-original)))
    (let ((wrapper
           (lambda (proc event)
             (when existing
               (condition-case err
                   (funcall existing proc event)
                 (error
                  (display-warning
                   'pending
                   (format "existing sentinel for process %s signaled: %S"
                           (process-name proc) err)
                   :error))))
             (pending--process-sentinel p proc event))))
      (set-process-sentinel process wrapper)
      (process-put process 'pending--wrapped-by wrapper)
      (process-put process 'pending--wrapped-original existing))
    (setf (pending-attached-process p) process))
  p)


;;; Public API: live updates

(cl-defun pending-update (p &key label percent eta indicator)
  "Update P's metadata while it is still active.  Mutates the named slots only.
LABEL, PERCENT, ETA, and INDICATOR replace the corresponding slots
when non-nil.  No state transition happens; the next animation tick
will pick up the new values.  Return P.

Clears P's `last-frame' slot so the next render redraws the
indicator even though the frame index has not advanced — a live
`:indicator' or `:spinner-style' change therefore takes effect on
the next tick.  The shared SVG cache (`pending--svg-cache') is
not touched.

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
    ;; Force the next tick's spinner glyph to redraw even though the
    ;; frame index hasn't advanced, so a live `:spinner-style' or
    ;; `:indicator' change picks up immediately.
    (setf (pending-last-frame p) nil)
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


;;; Public API: interactive cancel-at-point

;;;###autoload
(defun pending-cancel-at-point ()
  "Cancel the pending placeholder at point, if any.
Interactive equivalent of `pending-cancel' on `pending-at'.

If no pending overlay covers point, signal a `user-error'.  Reason
slot is set to `:cancelled-by-user'.  This command is bound under
`pending-region-map' to `RET' and `mouse-1' so users can activate a
placeholder directly to cancel it."
  (interactive)
  (let ((p (pending-at)))
    (if p
        (pending-cancel p :cancelled-by-user)
      (user-error "No pending placeholder at point"))))


;;; Public API: tabulated-list UI

(defvar pending-list-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'pending-list-refresh)
    (define-key m (kbd "RET") #'pending-list-jump)
    (define-key m (kbd "c") #'pending-list-cancel)
    (define-key m (kbd "?") #'pending-list-describe)
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `pending-list-mode' buffers.
Inherits from `tabulated-list-mode-map' since `pending-list-mode' is
derived from `tabulated-list-mode'.")

(define-derived-mode pending-list-mode tabulated-list-mode "Pending-List"
  "Major mode for the *Pending* list buffer.
Each row corresponds to one entry in `pending--registry'.  The row's
tabulated-list id is the `pending' struct itself, so commands such as
`pending-list-cancel' and `pending-list-jump' operate on the struct
directly via `tabulated-list-get-id'.

\\{pending-list-mode-map}"
  (setq tabulated-list-format
        [("ID" 16
          (lambda (a b)
            ;; Sort numerically by the trailing integer in the id symbol's
            ;; name.  Lexicographic sort (the default `t' predicate) puts
            ;; "pending-12" before "pending-2" once the count exceeds 9.
            (< (string-to-number
                (replace-regexp-in-string "[^0-9]" "" (aref (cadr a) 0)))
               (string-to-number
                (replace-regexp-in-string "[^0-9]" "" (aref (cadr b) 0))))))
         ("Buffer" 24 t)
         ("Label" 30 t)
         ("Status" 12 t)
         ("Elapsed" 8
          (lambda (a b)
            (< (string-to-number (aref (cadr a) 4))
               (string-to-number (aref (cadr b) 4)))))
         ("ETA" 8
          (lambda (a b)
            (let ((va (string-to-number (aref (cadr a) 5)))
                  (vb (string-to-number (aref (cadr b) 5))))
              (when (zerop va) (setq va most-positive-fixnum))
              (when (zerop vb) (setq vb most-positive-fixnum))
              (< va vb))))
         ("Group" 10 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("ID" . nil))
  (tabulated-list-init-header))

(defun pending--list-populate ()
  "Populate `tabulated-list-entries' from `pending--registry'.
Each entry's id slot is the `pending' struct so the row commands can
operate on it directly via `tabulated-list-get-id'.  The label cell is
truncated to fit the column width using `truncate-string-to-width' so
long labels do not break the layout."
  (let (entries)
    (maphash
     (lambda (_id p)
       (let* ((buf-name (if (buffer-live-p (pending-buffer p))
                            (buffer-name (pending-buffer p))
                          "<dead>"))
              (label (or (pending-label p) ""))
              (status (symbol-name (pending-status p)))
              (elapsed (if (pending-start-time p)
                           (format "%.1f"
                                   (- (float-time)
                                      (pending-start-time p)))
                         "0.0"))
              (eta (if (pending-eta p)
                       (format "%.1fs" (pending-eta p))
                     "-"))
              (group (if (pending-group p)
                         (symbol-name (pending-group p))
                       "-")))
         (push
          (list p
                (vector (symbol-name (pending-id p))
                        buf-name
                        (truncate-string-to-width label 30 0 nil "…")
                        status
                        elapsed
                        eta
                        group))
          entries)))
     pending--registry)
    (setq tabulated-list-entries (nreverse entries))))

(defun pending-list-refresh ()
  "Refresh the *Pending* list buffer from the live registry.
No-op outside `pending-list-mode'."
  (interactive)
  (when (derived-mode-p 'pending-list-mode)
    (pending--list-populate)
    (tabulated-list-print t)))

(defun pending-list-jump ()
  "Jump to the placeholder at the current row of the *Pending* list.
Pops to the placeholder's buffer and moves point to its start marker
when the buffer is still live and the marker is still pointing
somewhere.  No-op when called outside `pending-list-mode' or when the
row's struct has no live buffer."
  (interactive)
  (when (derived-mode-p 'pending-list-mode)
    (let ((p (tabulated-list-get-id)))
      (when (and p (buffer-live-p (pending-buffer p)))
        (pop-to-buffer (pending-buffer p))
        (when (and (markerp (pending-start p))
                   (marker-position (pending-start p)))
          (goto-char (pending-start p)))))))

(defun pending-list-cancel ()
  "Cancel the placeholder at the current row of the *Pending* list.
Reason is `:cancelled-from-list'.  After cancelling, refresh the list
so the cancelled row drops out of the registry view.  No-op when
called outside `pending-list-mode'."
  (interactive)
  (when (derived-mode-p 'pending-list-mode)
    (let ((p (tabulated-list-get-id)))
      (when p
        (pending-cancel p :cancelled-from-list)
        (pending-list-refresh)))))

;;;###autoload
(defun pending-list-describe ()
  "Describe the placeholder at point in the *Pending* list.
Opens a `*Pending: ID*' buffer in `pending-description-mode' with
structured details (status, timing, callbacks, process, etc.) about
the row's struct.  No-op when called outside `pending-list-mode' or
when the row is empty."
  (interactive)
  (when (derived-mode-p 'pending-list-mode)
    (let ((p (tabulated-list-get-id)))
      (when p
        (pending-describe p)))))

;;;###autoload
(defun pending-list ()
  "Display all active pending placeholders in a tabulated-list buffer.
Columns: ID, Buffer, Label, Status, Elapsed, ETA, Group.  Rows are
sorted by ID by default; clicking a column header sorts by that
column.  Bindings: `g' refresh, `RET' jump to placeholder, `c' cancel,
`?' describe, `q' quit."
  (interactive)
  (let ((buf (get-buffer-create "*Pending*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'pending-list-mode)
        (pending-list-mode))
      (pending--list-populate)
      (tabulated-list-print t))
    (pop-to-buffer buf)))


;;; Public API: description buffer

(defvar pending-description-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'pending-describe-refresh)
    (define-key m (kbd "RET") #'pending-describe-jump)
    (define-key m (kbd "c") #'pending-describe-cancel)
    (define-key m (kbd "q") #'quit-window)
    m)
  "Keymap for `pending-description-mode' buffers.
`g' refreshes the rendered details, `RET' jumps to the placeholder
in its buffer, `c' cancels the placeholder, and `q' buries the
description buffer.")

(define-derived-mode pending-description-mode special-mode "Pending-Desc"
  "Major mode for `*Pending: ID*' description buffers.
The buffer displays structured details for a single placeholder —
identity, lifecycle status, timing, indicator state, callback
wiring, and any attached process.  See `pending-describe'.

\\{pending-description-mode-map}"
  (setq buffer-read-only t)
  (setq truncate-lines nil))

(defvar-local pending-description--token nil
  "Buffer-local pointer to the token being described.
Set by `pending--describe-render' so the keymap commands can
operate on the same struct across refreshes.")

(defun pending-describe-refresh ()
  "Re-render the current `pending-description-mode' buffer.
No-op outside `pending-description-mode'.  Reads the token from
the buffer-local `pending-description--token' so the keymap
commands have nothing to track manually."
  (interactive)
  (when (and (derived-mode-p 'pending-description-mode)
             pending-description--token)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (pending--describe-render pending-description--token))))

(defun pending-describe-jump ()
  "Jump to the placeholder being described in its buffer.
Delegates to `pending-goto'.  No-op when there is no token in
the buffer-local `pending-description--token'."
  (interactive)
  (when (and (derived-mode-p 'pending-description-mode)
             pending-description--token)
    (pending-goto pending-description--token)))

(defun pending-describe-cancel ()
  "Cancel the placeholder being described.
Reason is `:cancelled-from-describe'.  Refreshes the buffer so
the new terminal status is visible.  No-op when there is no
token in the buffer-local `pending-description--token'."
  (interactive)
  (when (and (derived-mode-p 'pending-description-mode)
             pending-description--token)
    (pending-cancel pending-description--token :cancelled-from-describe)
    (pending-describe-refresh)))

(defun pending--describe-render (token)
  "Insert structured details about TOKEN into the current buffer.
Called by `pending-describe' (initial render) and
`pending-describe-refresh' after re-erasing the buffer.  Sets the
buffer-local `pending-description--token' so the keymap commands
can find their target across refreshes."
  (setq pending-description--token token)
  (let* ((status (pending-status token))
         (started (pending-start-time token))
         (resolved (pending-resolved-at token))
         (elapsed (when started
                    (- (or resolved (float-time)) started)))
         (buf (pending-buffer token))
         (buf-name (if (buffer-live-p buf)
                       (buffer-name buf)
                     "<dead>")))
    (insert (propertize (format "Pending %s\n"
                                (symbol-name (pending-id token)))
                        'face 'bold))
    (insert (make-string 40 ?-) "\n\n")
    (insert (format "%-12s %s\n" "ID:"
                    (symbol-name (pending-id token))))
    (insert (format "%-12s %s\n" "Label:"
                    (or (pending-label token) "")))
    (insert (format "%-12s %s\n" "Status:" status))
    (when (pending-reason token)
      (insert (format "%-12s %s\n" "Reason:"
                      (pending--format-reason (pending-reason token)))))
    (insert (format "%-12s %s\n" "Buffer:" buf-name))
    (when (pending-group token)
      (insert (format "%-12s %s\n" "Group:" (pending-group token))))
    (insert "\n")
    (insert (format "%-12s %s\n" "Indicator:"
                    (or (pending-indicator token) :spinner)))
    (when (pending-spinner-style token)
      (insert (format "%-12s %s\n" "Spinner:"
                      (pending-spinner-style token))))
    (when (pending-eta token)
      (insert (format "%-12s %.2fs\n" "ETA:" (pending-eta token))))
    (when (pending-percent token)
      (insert (format "%-12s %.0f%%\n" "Percent:"
                      (* 100 (pending-percent token)))))
    (when (pending-deadline token)
      (insert (format "%-12s %.2fs\n" "Deadline:"
                      (pending-deadline token))))
    (insert "\n")
    (when started
      (insert (format "%-12s %s\n" "Started:"
                      (format-time-string "%FT%T" started))))
    (when resolved
      (insert (format "%-12s %s\n" "Resolved:"
                      (format-time-string "%FT%T" resolved))))
    (when elapsed
      (insert (format "%-12s %.2fs\n" "Elapsed:" elapsed)))
    (insert "\n")
    (insert (format "%-12s %s\n" "on-cancel:"
                    (if (pending-on-cancel token) "yes" "no")))
    (insert (format "%-12s %s\n" "on-resolve:"
                    (if (pending-on-resolve token) "yes" "no")))
    (when (pending-attached-process token)
      (insert (format "%-12s %S\n" "process:"
                      (pending-attached-process token))))
    (insert "\n")
    (insert (substitute-command-keys
             (concat "Press \\[pending-describe-jump] to jump, "
                     "\\[pending-describe-cancel] to cancel, "
                     "\\[pending-describe-refresh] to refresh, "
                     "\\[quit-window] to quit.\n")))))

;;;###autoload
(defun pending-describe (token)
  "Show TOKEN's details in a `*Pending: ID*' buffer.
Pops up a read-only buffer in `pending-description-mode' showing
structured details: token id, label, status, reason, owner buffer,
group, indicator type and per-mode state, schedule and resolve
timestamps, elapsed time, callback wiring, and any attached
process.

Interactively, prompt with `completing-read' over the registered
placeholders.  Bindings inside the description buffer: \\<pending-description-mode-map>\\[pending-describe-refresh] refresh,
\\[pending-describe-jump] jump to placeholder, \\[pending-describe-cancel] cancel, \\[quit-window] quit."
  (interactive (list (pending--read-token "Describe pending: ")))
  (let* ((bufname (format "*Pending: %s*" (symbol-name (pending-id token))))
         (buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pending-description-mode)
        (pending--describe-render token)
        (goto-char (point-min))))
    (pop-to-buffer buf)))


;;; Mode-line lighter

(defvar pending--mode-line-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'pending-list)
    m)
  "Keymap on the mode-line lighter; `mouse-1' opens `pending-list'.")

(defun pending-mode-line-string ()
  "Return a propertized mode-line string summarising active pendings.
Format: `\" [3⏳~5s]\"' — count of active placeholders followed by the
smallest positive remaining ETA across them, in seconds.  When no
placeholder has an ETA in the future, the trailing tilde-segment is
omitted.  Returns nil when there are no active placeholders so the
mode-line construct disappears entirely.

The returned string is propertized with `pending-spinner-face',
carries a `help-echo' tooltip describing the count, and binds
`mouse-1' to `pending-list' so clicking the lighter opens the
*Pending* list buffer.

This runs once per redisplay; the implementation makes a single
`maphash' pass over `pending--registry' tracking the count and the
smallest positive remaining ETA simultaneously rather than going
through `pending-list-active' (consing a list) and then a separate
`mapcar' / `apply min'."
  (let ((count 0)
        (best nil)
        (now (float-time)))
    (maphash
     (lambda (_id p)
       (when (pending-active-p p)
         (cl-incf count)
         (let ((eta (pending-eta p))
               (st  (pending-start-time p)))
           (when (and eta st)
             (let ((rem (- eta (- now st))))
               (when (and (> rem 0) (or (null best) (< rem best)))
                 (setq best rem)))))))
     pending--registry)
    (when (> count 0)
      (let* ((eta-text (if best (format "~%ds" (max 1 (round best))) ""))
             (text (format " [%d⏳%s]" count eta-text)))
        (propertize text
                    'face 'pending-spinner-face
                    'mouse-face 'mode-line-highlight
                    'local-map pending--mode-line-keymap
                    'help-echo
                    (format
                     "%d active pending placeholder%s\nmouse-1: list"
                     count (if (= count 1) "" "s")))))))

(defvar pending--mode-line-construct '(:eval (pending-mode-line-string))
  "Mode-line construct used by `global-pending-lighter-mode'.
Stored as a single shared `defvar' so the minor mode can add it to
and remove it from `global-mode-string' by `eq'-identity rather than
relying on structural equality of freshly-consed lists.")

;;;###autoload
(define-minor-mode global-pending-lighter-mode
  "Toggle a global mode-line lighter summarising active pendings.
When enabled, append `pending--mode-line-construct' (an `:eval' form
that calls `pending-mode-line-string') to `global-mode-string', so the
lighter automatically updates each redisplay.  When disabled, remove
that construct via `delq' on its identity."
  :global t
  :group 'pending
  :lighter nil
  (if global-pending-lighter-mode
      (unless (memq pending--mode-line-construct global-mode-string)
        (setq global-mode-string
              (append global-mode-string
                      (list pending--mode-line-construct))))
    (setq global-mode-string
          (delq pending--mode-line-construct global-mode-string))))


;;; Emacs-exit confirmation

(defun pending--kill-emacs-query ()
  "Block Emacs exit if active placeholders exist and confirmation is enabled.
Installed on `kill-emacs-query-functions' at load time.  Returns t
\(allow exit) when `pending-confirm-on-emacs-exit' is nil, when no
active placeholders are registered, or when the user answers `yes' to
the prompt; returns nil (block exit) when the user answers `no'."
  (or (not pending-confirm-on-emacs-exit)
      (let ((actives (pending-list-active)))
        (or (null actives)
            (yes-or-no-p
             (format "%d active pending placeholder%s; quit anyway? "
                     (length actives)
                     (if (= 1 (length actives)) "" "s")))))))

(add-hook 'kill-emacs-query-functions #'pending--kill-emacs-query)


;;; Demo

;;;###autoload
(defun pending-demo ()
  "Open *pending-demo* with several concurrent placeholders.
Demonstrates spinner, percent, and ETA indicators with varied
durations.  Useful for visual inspection of the library on the
current theme.

Resolves placeholders automatically over the course of about 12
seconds."
  (interactive)
  (let ((buf (get-buffer-create "*pending-demo*")))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (insert "Pending demo:\n\n")
      (insert "Spinner (3s):    ")
      (let ((p (pending-make buf :label "Calling A"
                             :indicator :spinner)))
        (run-at-time 3 nil (lambda () (when (pending-active-p p)
                                        (pending-finish p "A done")))))
      (insert "\nETA (8s):        ")
      (let ((p (pending-make buf :label "Calling B"
                             :indicator :eta :eta 8.0)))
        (run-at-time 8 nil (lambda () (when (pending-active-p p)
                                        (pending-finish p "B done")))))
      (insert "\nPercent (0..1):  ")
      (let ((p (pending-make buf :label "Calling C"
                             :indicator :percent :percent 0.0)))
        (dotimes (i 10)
          (run-at-time (* (1+ i) 1.0) nil
                       (lambda ()
                         (when (pending-active-p p)
                           (pending-update p :percent (/ (1+ i) 10.0))
                           (when (= i 9)
                             (pending-finish p "C done")))))))
      (insert "\n\nPress `q' to bury this buffer.\n")
      (insert "Use `M-x pending-cancel-at-point' (or RET on a placeholder) to cancel.\n")
      (insert "Use `M-x pending-list' to see all active placeholders.\n")
      (goto-char (point-min)))))


;;; Unload cleanup

(defun pending-unload-function ()
  "Tear down `pending' global state on `unload-feature'.
Called automatically by `unload-feature'.  Removes the
`window-buffer-change-functions' and `kill-emacs-query-functions'
hooks, cancels the global animation timer, and walks every live
buffer to remove the buffer-local `kill-buffer-hook' entry our
`pending--register' may have installed.  Returning nil lets
`unload-feature' continue with its standard cleanup of symbols
defined in this file."
  (remove-hook 'window-buffer-change-functions
               #'pending--on-window-buffer-change)
  (remove-hook 'kill-emacs-query-functions #'pending--kill-emacs-query)
  (when (timerp pending--global-timer)
    (cancel-timer pending--global-timer))
  (setq pending--global-timer nil)
  ;; Strip the buffer-local kill hook from every buffer that still
  ;; carries it.  The check guards against the trivial common case
  ;; where the hook was never installed; only the actual placeholder
  ;; buffers paid the registration cost.
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (memq #'pending--on-kill-buffer
                     (buffer-local-value 'kill-buffer-hook buf)))
      (with-current-buffer buf
        (remove-hook 'kill-buffer-hook #'pending--on-kill-buffer t))))
  nil)


(provide 'pending)

;;; pending.el ends here
