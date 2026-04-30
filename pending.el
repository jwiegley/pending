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
;; This file currently provides only the bootstrap entry point; the
;; full skeleton lands in Phase 1 of the implementation plan.

;;; Code:

(provide 'pending)

;;; pending.el ends here
