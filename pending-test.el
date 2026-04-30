;;; pending-test.el --- Tests for pending.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT tests for `pending'.  At present this file ships only a smoke
;; test verifying that the library loads.  Subsequent phases add tests
;; for state transitions, marker survival, streaming, and so on (see
;; `DESIGN.md' section 8).

;;; Code:

(require 'ert)
(require 'pending)

(ert-deftest pending-test/loads ()
  "Smoke test: confirm `pending' is loaded."
  (should (featurep 'pending)))

(provide 'pending-test)

;;; pending-test.el ends here
