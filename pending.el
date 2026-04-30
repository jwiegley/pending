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
;; This file currently provides the Phase 1 skeleton: customization
;; group, defcustoms, faces, the `pending' struct type, the error
;; symbol, an ID generator, and the global and buffer-local registries.
;; Subsequent phases add lifecycle, animation, streaming, and the
;; interactive UI.

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
  attached-process attached-timer)


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


(provide 'pending)

;;; pending.el ends here
