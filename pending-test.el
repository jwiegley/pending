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

(ert-deftest pending-test/struct-constructor ()
  "The Phase-1 struct constructor produces a `pending-p' value."
  (should (pending-p (pending--make-struct :id 'p :label "x"))))

(ert-deftest pending-test/gen-id-monotonic ()
  "`pending--gen-id' returns successively-numbered symbols."
  (let ((pending--next-id 0))
    (should (eq (pending--gen-id) 'pending-1))
    (should (eq (pending--gen-id) 'pending-2))))

(provide 'pending-test)

;;; pending-test.el ends here
