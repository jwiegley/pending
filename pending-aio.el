;;; pending-aio.el --- aio promise adapter for pending  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>
;; Maintainer: John Wiegley <jwiegley@gmail.com>
;; URL: https://github.com/jwiegley/pending
;; Keywords: convenience, tools

;; Note: this file ships as an optional add-on inside the `pending'
;; package; the canonical Package-Requires lives in `pending.el'.
;; Loading this file requires `aio' to be installed.

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: BSD-3-Clause
;; See LICENSE.md for the full license text.

;;; Commentary:

;; Optional adapter that turns a `pending' TOKEN into an `aio-promise',
;; so callers using the `aio' coroutine library can `aio-await' a
;; placeholder's resolution.
;;
;; Loading this file requires `aio' to be installed; if not, the load
;; signals.  The main `pending' package does NOT load this file —
;; users opt in via `(require \\='pending-aio)'.
;;
;; Usage:
;;
;;   (require 'pending-aio)
;;
;;   (aio-defun my-async-fn ()
;;     (let* ((token (pending-make (current-buffer) :label "Working"))
;;            (promise (pending-as-promise token)))
;;       ;; ...kick off the async work that will eventually call
;;       ;; `pending-finish' / `pending-cancel' / `pending-reject' on
;;       ;; the token...
;;       (let ((resolved (aio-await promise)))
;;         (message "Token %s ended with status %s"
;;                  (pending-id resolved)
;;                  (pending-status resolved)))))

;;; Code:

(require 'pending)
(require 'aio)

(defun pending-as-promise (token)
  "Return an `aio-promise' that resolves when TOKEN reaches a terminal state.
The promise resolves with TOKEN itself, so the caller can read
`(pending-status TOKEN)', `(pending-reason TOKEN)', and
`(pending-resolved-at TOKEN)' on the awaited value to discover
how the placeholder ended.

If TOKEN is already terminal at call time, the returned promise
resolves immediately with TOKEN.

Implementation note: the adapter chains itself onto TOKEN's
`on-resolve' slot.  Any pre-existing on-resolve callback is
invoked first (with errors caught and reported as a `pending'
warning) so installing the adapter does not silently displace
caller-supplied handlers.  Errors thrown inside the existing
on-resolve callback are not propagated to the promise — only
the resolve event itself triggers the await return."
  (let ((promise (aio-promise)))
    (cond
     ((memq (pending-status token) '(:resolved :rejected :cancelled :expired))
      (aio-resolve promise (lambda () token)))
     (t
      (let ((existing (pending-on-resolve token)))
        (setf (pending-on-resolve token)
              (lambda (p)
                (when existing
                  (condition-case err
                      (funcall existing p)
                    (error
                     (display-warning
                      'pending
                      (format "on-resolve callback for %s signaled: %S"
                              (pending-id p) err)
                      :error))))
                (aio-resolve promise (lambda () p)))))))
    promise))

(provide 'pending-aio)
;;; pending-aio.el ends here
