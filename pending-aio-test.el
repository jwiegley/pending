;;; pending-aio-test.el --- Tests for pending-aio  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: BSD-3-Clause
;; See LICENSE.md for the full license text.

;;; Commentary:

;; ERT tests for `pending-aio'.  The whole file is gated on
;; `(require \\='aio nil \\='noerror)' so it is a no-op when the `aio'
;; package is not installed — that lets CI matrices that omit `aio'
;; load this file harmlessly.
;;
;; The tests inspect a promise via `aio-result' rather than via
;; `aio-listen' callbacks, since `aio-listen' schedules its callback
;; through `run-at-time 0' (i.e., asynchronously) and would not run
;; under a synchronous ERT test without an explicit
;; `accept-process-output' / `sit-for' loop.  `aio-result' returns
;; the value-function on a resolved promise immediately and nil on
;; an unresolved one, so we can assert on it directly.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pending)
;; `warning-minimum-log-level' is declared in `warnings'; loading the
;; library here makes its `defvar' visible so `let' bindings below
;; suppress library warnings instead of creating an inert lexical.
(require 'warnings)

;; The whole test body is gated on `(require 'aio nil 'noerror)' so that
;; CI matrices without `aio' installed simply skip these tests.  The
;; byte compiler can't prove the require succeeds statically, so
;; declare the entry point and the `aio' symbols we touch to keep
;; byte-compile -W=error clean.
(declare-function pending-as-promise "pending-aio" (token))
(declare-function aio-result "aio" (promise))

(when (require 'aio nil 'noerror)
  (require 'pending-aio)

  (ert-deftest pending-aio-test/promise-resolves-on-finish ()
    "Promise resolves when token transitions to `:resolved'.
The awaited value is the token itself."
    (with-temp-buffer
      (let* ((p (pending-make (current-buffer) :label "X"))
             (promise (pending-as-promise p)))
        (should (null (aio-result promise)))   ; unresolved
        (pending-finish p "ok")
        (should (eq (pending-status p) :resolved))
        (should (functionp (aio-result promise)))
        (should (eq p (funcall (aio-result promise)))))))

  (ert-deftest pending-aio-test/promise-resolves-on-cancel ()
    "Promise resolves when token transitions to `:cancelled'."
    (with-temp-buffer
      (let* ((p (pending-make (current-buffer) :label "X"))
             (promise (pending-as-promise p)))
        (should (null (aio-result promise)))
        (pending-cancel p)
        (should (eq (pending-status p) :cancelled))
        (should (functionp (aio-result promise)))
        (should (eq p (funcall (aio-result promise)))))))

  (ert-deftest pending-aio-test/promise-resolves-on-reject ()
    "Promise resolves when token transitions to `:rejected'."
    (with-temp-buffer
      (let* ((warning-minimum-log-level :error)
             (p (pending-make (current-buffer) :label "X"))
             (promise (pending-as-promise p)))
        (should (null (aio-result promise)))
        (pending-reject p "boom")
        (should (eq (pending-status p) :rejected))
        (should (functionp (aio-result promise)))
        (should (eq p (funcall (aio-result promise))))
        (should (equal (pending-reason p) "boom")))))

  (ert-deftest pending-aio-test/already-terminal-resolves-immediately ()
    "Calling `pending-as-promise' on a terminal token resolves now.
The fast-path branch resolves the promise synchronously inside
`pending-as-promise', so `aio-result' returns the value-function
immediately on return."
    (with-temp-buffer
      (let ((p (pending-make (current-buffer) :label "X")))
        (pending-finish p "ok")
        (let ((promise (pending-as-promise p)))
          (should (functionp (aio-result promise)))
          (should (eq p (funcall (aio-result promise))))))))

  (ert-deftest pending-aio-test/preserves-existing-on-resolve ()
    "Adapter chains a pre-existing `on-resolve' callback first.
Both side effects (the user's flag flip and the promise
resolution) are observed; the adapter does not silently displace
the caller's hook."
    (with-temp-buffer
      (let* ((flag nil)
             (p (pending-make (current-buffer)
                              :label "X"
                              :on-resolve (lambda (_) (setq flag t))))
             (promise (pending-as-promise p)))
        (pending-finish p "ok")
        (should flag)
        (should (eq p (funcall (aio-result promise)))))))

  (ert-deftest pending-aio-test/buggy-existing-callback-still-resolves-promise ()
    "If the pre-existing `on-resolve' signals, the promise still resolves.
The adapter wraps the existing call in `condition-case', so a
buggy upstream handler does not block the promise resolution."
    (with-temp-buffer
      (let* ((inhibit-message t)
             (p (pending-make (current-buffer)
                              :label "X"
                              :on-resolve (lambda (_) (error "Boom"))))
             (promise (pending-as-promise p)))
        (pending-finish p "ok")
        (should (functionp (aio-result promise)))
        (should (eq p (funcall (aio-result promise))))))))

(provide 'pending-aio-test)
;;; pending-aio-test.el ends here
