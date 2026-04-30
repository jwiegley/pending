;;; pending-test.el --- Tests for pending.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT tests for `pending'.  The Phase-1 smoke and struct tests stay
;; intact; Phase 2 adds tests for state transitions, registry sync,
;; the buffer-kill hook, and the public predicates and accessors.

;;; Code:

(require 'ert)
(require 'pending)


;;; Test harness

(defmacro pending-test--with-buffer (var-and-name &rest body)
  "Run BODY with a fresh temp buffer.
VAR-AND-NAME is `(VAR NAME)': VAR is bound to a freshly generated
buffer named after NAME.  The buffer is killed on exit, even if BODY
throws."
  (declare (indent 1) (debug ((symbolp stringp) body)))
  (let ((var (car var-and-name))
        (name (cadr var-and-name)))
    `(let ((,var (generate-new-buffer ,name)))
       (unwind-protect
           (progn ,@body)
         (when (buffer-live-p ,var) (kill-buffer ,var))))))

(defmacro pending-test--with-fresh-registry (&rest body)
  "Run BODY with fresh, isolated `pending' global state.
Rebinds `pending--registry' to a brand-new hash table and resets
`pending--next-id' so id counters and registry contents from earlier
tests cannot leak in."
  (declare (indent 0) (debug t))
  `(let ((pending--registry (make-hash-table :test 'eq))
         (pending--next-id 0))
     ,@body))


;;; Phase 1 carry-over tests

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


;;; Phase 2 — state transitions

(ert-deftest pending-test/scheduled-to-resolved ()
  "Creating then resolving leaves status `:resolved' and replaces text."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-resolve*")
     (with-current-buffer buf
       (insert "Before: ")
       (let ((p (pending-make buf :label "Calling")))
         (should (eq (pending-status p) :scheduled))
         (should (equal (buffer-string) "Before: Calling"))
         (insert " :After")
         (pending-resolve p "DONE")
         (should (eq (pending-status p) :resolved))
         (should (equal (buffer-string) "Before: DONE :After")))))))

(ert-deftest pending-test/scheduled-to-rejected ()
  "Creating then rejecting leaves status `:rejected' with the reason."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-reject*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "Calling")))
         (pending-reject p "boom")
         (should (eq (pending-status p) :rejected))
         (should (equal (pending-reason p) "boom"))
         (should (string-match-p "boom" (buffer-string))))))))

(ert-deftest pending-test/scheduled-to-cancelled-runs-on-cancel ()
  "Cancelling fires `on-cancel' once before flipping status."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-cancel*")
     (with-current-buffer buf
       (let* ((called 0)
              (seen-status nil)
              (p (pending-make
                  buf
                  :label "Calling"
                  :on-cancel (lambda (q)
                               (cl-incf called)
                               (setq seen-status (pending-status q))))))
         (pending-cancel p :reasons-of-state)
         (should (= called 1))
         (should (memq seen-status '(:scheduled :running :streaming)))
         (should (eq (pending-status p) :cancelled))
         (should (eq (pending-reason p) :reasons-of-state)))))))

(ert-deftest pending-test/no-double-resolve ()
  "Resolving twice is a no-op on the second call; status persists."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-double*")
     (with-current-buffer buf
       (let ((warning-minimum-log-level :error)
             (p (pending-make buf :label "Calling")))
         (should (eq t (pending-resolve p "first")))
         (should (eq nil (pending-resolve p "second")))
         (should (eq (pending-status p) :resolved))
         (should (string-match-p "first" (buffer-string))))))))

(ert-deftest pending-test/no-resolve-after-reject ()
  "`pending-resolve' after `pending-reject' is suppressed."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-reject-resolve*")
     (with-current-buffer buf
       (let ((warning-minimum-log-level :error)
             (p (pending-make buf :label "Calling")))
         (should (eq t (pending-reject p "nope")))
         (should (eq nil (pending-resolve p "late")))
         (should (eq (pending-status p) :rejected)))))))


;;; Phase 2 — registry / buffer-kill

(ert-deftest pending-test/registry-add-remove ()
  "Creating N placeholders adds N entries; resolving drains both registries."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-registry*")
     (with-current-buffer buf
       (let ((p1 (pending-make buf :label "one")))
         (insert " ")
         (let ((p2 (pending-make buf :label "two")))
           (insert " ")
           (let ((p3 (pending-make buf :label "three")))
             (should (= 3 (hash-table-count pending--registry)))
             (should (= 3 (length (buffer-local-value
                                   'pending--buffer-registry buf))))
             (pending-resolve p1 "1")
             (pending-resolve p2 "2")
             (pending-resolve p3 "3")
             (should (= 0 (hash-table-count pending--registry)))
             (should (= 0 (length (buffer-local-value
                                   'pending--buffer-registry buf)))))))))))

(ert-deftest pending-test/buffer-kill-cancels-all ()
  "Killing the buffer cancels every placeholder with `:buffer-killed'."
  (pending-test--with-fresh-registry
   (let* ((buf (generate-new-buffer "*pending-kill*"))
          (call-count 0)
          (recorder (lambda (_q) (cl-incf call-count)))
          (placeholders nil))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (push (pending-make buf :label "a" :on-cancel recorder)
                   placeholders)
             (insert " ")
             (push (pending-make buf :label "b" :on-cancel recorder)
                   placeholders)
             (insert " ")
             (push (pending-make buf :label "c" :on-cancel recorder)
                   placeholders))
           (kill-buffer buf)
           ;; The on-cancel callback ran for each placeholder.
           (should (= 3 call-count))
           ;; And the structs settled into the cancelled state with
           ;; the buffer-killed reason after the callback returned.
           (dolist (p placeholders)
             (should (eq (pending-status p) :cancelled))
             (should (eq (pending-reason p) :buffer-killed))))
       (when (buffer-live-p buf) (kill-buffer buf))))))


;;; Phase 2 — accessors

(ert-deftest pending-test/pending-at-finds-pending ()
  "`pending-at' returns the struct on the placeholder, nil after resolve."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-at*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "Hello")))
         (goto-char (1+ (marker-position (pending-start p))))
         (should (eq (pending-at) p))
         (pending-resolve p "X")
         (should (null (pending-at))))))))

(ert-deftest pending-test/pending-list-active-filtered ()
  "`pending-list-active' filters by buffer and group."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf-a "*pending-a*")
     (pending-test--with-buffer (buf-b "*pending-b*")
       (with-current-buffer buf-a
         (pending-make buf-a :label "a1" :group :foo)
         (insert " ")
         (pending-make buf-a :label "a2" :group :foo))
       (with-current-buffer buf-b
         (pending-make buf-b :label "b1" :group :bar))
       (should (= 2 (length (pending-list-active buf-a))))
       (should (= 1 (length (pending-list-active buf-b))))
       (should (= 2 (length (pending-list-active nil :foo))))
       (should (= 1 (length (pending-list-active nil :bar))))
       (should (= 0 (length (pending-list-active buf-a :bar))))))))


;;; Phase 2 — slot mutation

(ert-deftest pending-test/pending-update-mutates-slots ()
  "`pending-update' replaces named slots without changing status."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-update*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "L1" :percent 0.0)))
         (should (equal (pending-label p) "L1"))
         (should (eq (pending-status p) :scheduled))
         (pending-update p :label "L2" :percent 0.5)
         (should (equal (pending-label p) "L2"))
         (should (= 0.5 (pending-percent p)))
         (should (eq (pending-status p) :scheduled))
         ;; Cleanup: resolve so the registry empties.
         (pending-resolve p "done"))))))


(provide 'pending-test)

;;; pending-test.el ends here
