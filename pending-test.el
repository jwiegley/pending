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
;; the buffer-kill hook, and the public predicates and accessors;
;; Phase 3 covers the spinner animation — frame index, render side
;; effects, the visibility gate, and timer parking.

;;; Code:

(require 'ert)
(require 'pending)
;; `warning-minimum-log-level' is declared in `warnings'; loading the
;; library here makes its `defvar' visible so the `let' bindings below
;; suppress library warnings instead of creating an inert lexical.
(require 'warnings)


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
Rebinds `pending--registry' to a brand-new hash table, resets
`pending--next-id' so id counters and registry contents from earlier
tests cannot leak in, and rebinds `pending--global-timer' so the
animation timer started by `pending-make' is local to BODY.  The
timer is cancelled on exit so it cannot fire after BODY returns."
  (declare (indent 0) (debug t))
  `(let ((pending--registry (make-hash-table :test 'eq))
         (pending--next-id 0)
         (pending--global-timer nil))
     (unwind-protect
         (progn ,@body)
       (when (timerp pending--global-timer)
         (cancel-timer pending--global-timer)))))


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


;;; Phase 2 — adopt mode and deadline timer

(ert-deftest pending-test/pending-make-adopt-mode ()
  "Adopt mode wraps an existing region without inserting new text.
The overlay is anchored at the supplied START and END markers and
the placeholder lifecycle is otherwise normal."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/adopt*")
     (with-current-buffer buf
       (insert "Before:")
       (let ((s (point)))
         (insert "adopt")
         (let* ((e (point))
                (_ (insert ":After"))
                (text-before (buffer-string))
                (p (pending-make buf
                                 :label "X"
                                 :start (copy-marker s nil)
                                 :end   (copy-marker e nil))))
           ;; Adopting must not insert any new characters.
           (should (equal (buffer-string) text-before))
           (should (eq (pending-status p) :scheduled))
           ;; The overlay covers exactly the adopted region.
           (let ((ov (pending-overlay p)))
             (should (overlayp ov))
             (should (= (overlay-start ov) s))
             (should (= (overlay-end ov) e)))
           ;; And resolve replaces only that range.
           (pending-resolve p "ADOPTED")
           (should (equal (buffer-string) "Before:ADOPTED:After"))))))))

(ert-deftest pending-test/deadline-rejects-timed-out ()
  "A short deadline auto-rejects the placeholder with `:timed-out'."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/deadline*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X" :deadline 0.05)))
         ;; `sit-for' processes timers; `sleep-for' does not.
         (sit-for 0.2)
         (should (eq (pending-status p) :rejected))
         (should (eq (pending-reason p) :timed-out)))))))


;;; Phase 2 — re-entrancy and on-resolve coverage

(ert-deftest pending-test/cancel-reentry-is-safe ()
  "Re-entrant `pending-cancel' from inside on-cancel is a safe no-op.
A buggy callback that calls `pending-cancel' on the same struct must
not recurse into another full cancel — the in-resolve guard turns it
into a no-op so we run the user callback exactly once."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/cancel-reentry*")
     (with-current-buffer buf
       (let* ((calls 0)
              (p (pending-make
                  buf
                  :label "X"
                  :on-cancel (lambda (pp)
                               (cl-incf calls)
                               ;; Recursive call should be a safe no-op.
                               (pending-cancel pp :nested)))))
         (pending-cancel p :outer)
         (should (eq (pending-status p) :cancelled))
         (should (= calls 1)))))))

(ert-deftest pending-test/on-resolve-fires-for-all-terminals ()
  "ON-RESOLVE callback fires once for :resolved, :rejected, :cancelled."
  (pending-test--with-fresh-registry
   (dolist (case '((resolve . :resolved)
                   (reject  . :rejected)
                   (cancel  . :cancelled)))
     (pending-test--with-buffer (buf "*p-or*")
       (with-current-buffer buf
         (let* ((calls 0)
                (p (pending-make buf :label "X"
                                 :on-resolve (lambda (_) (cl-incf calls)))))
           (pcase (car case)
             ('resolve (pending-resolve p "ok"))
             ('reject  (pending-reject  p "bad"))
             ('cancel  (pending-cancel  p)))
           (should (= calls 1))
           (should (eq (pending-status p) (cdr case)))))))))


;;; Phase 3 — spinner animation

(ert-deftest pending-test/spinner-renders-frame ()
  "`pending--tick' decorates the overlay with a spinner glyph.
After resolution, the decoration is cleared so the spinner does not
survive into the resolved text."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/render*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "Working")))
         ;; Force the visibility gate open so we can render in batch.
         (cl-letf (((symbol-function 'get-buffer-window)
                    (lambda (&rest _) t)))
           (pending--tick))
         (let ((bs (overlay-get (pending-overlay p) 'before-string)))
           (should (stringp bs))
           ;; Glyph + space.
           (should (= (length bs) 2))
           (should (equal (substring bs 1 2) " ")))
         ;; Resolve clears the decoration on the (now-defunct) overlay's
         ;; before-string before the swap, so the resolved text in the
         ;; buffer contains no spinner.
         (let ((ov (pending-overlay p)))
           (pending-resolve p "DONE")
           (should (eq (pending-status p) :resolved))
           (when (overlayp ov)
             (should (null (overlay-get ov 'before-string))))
           (should (equal (buffer-string) "DONE"))))))))

(ert-deftest pending-test/spinner-frame-advances ()
  "`pending--frame-index' advances with elapsed wall-time.
With FPS = 10 and 0.5s elapsed, the frame index should be 5 modulo
the frame-set length."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/frame*")
     (with-current-buffer buf
       (let* ((p (pending-make buf :label "X"))
              (frames (pending--get-frames
                       (or (pending-spinner-style p)
                           pending-default-spinner-style))))
         (should (vectorp frames))
         (should (> (length frames) 0))
         ;; t = 0 → index 0.
         (setf (pending-start-time p) (float-time))
         (let ((pending-fps 10))
           (should (= 0 (pending--frame-index p frames))))
         ;; t = 0.5s, fps 10 → 5 mod n.
         (setf (pending-start-time p) (- (float-time) 0.5))
         (let ((pending-fps 10))
           (should (= (mod 5 (length frames))
                      (pending--frame-index p frames))))
         ;; t = 1.0s, fps 10 → 10 mod n.
         (setf (pending-start-time p) (- (float-time) 1.0))
         (let ((pending-fps 10))
           (should (= (mod 10 (length frames))
                      (pending--frame-index p frames)))))))))

(ert-deftest pending-test/timer-parks-when-empty ()
  "Resolving the last placeholder parks the global animation timer.
After `pending--unregister' empties the registry, the timer is
cancelled and `pending--global-timer' is nil."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*pending-test/park*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X")))
         ;; `pending-make' calls `pending--ensure-timer' itself.
         (should (timerp pending--global-timer))
         ;; Resolve empties the registry, which parks the timer in
         ;; `pending--unregister'.
         (pending-resolve p "ok")
         (should (zerop (hash-table-count pending--registry)))
         (should (null pending--global-timer))
         ;; A redundant tick on an empty registry remains a no-op
         ;; with the timer parked.
         (pending--tick)
         (should (null pending--global-timer)))))))

(ert-deftest pending-test/render-skips-when-buffer-hidden ()
  "`pending--tick' does not render when the buffer is not visible.
The placeholder remains in the registry, but `last-frame' stays nil.
With the tighter \"park on no visible\" semantics, the global timer
parks even though an active placeholder lingers — it is re-armed by
the `window-buffer-change-functions' hook when the buffer becomes
visible again."
  (pending-test--with-fresh-registry
   ;; A fresh, undisplayed buffer is not in any window.
   (pending-test--with-buffer (buf "*pending-test/hidden*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X")))
         (should (null (get-buffer-window buf 'visible)))
         ;; `pending-make' just armed the timer.
         (should (timerp pending--global-timer))
         (pending--tick)
         (should (null (pending-last-frame p)))
         (should (null (overlay-get (pending-overlay p) 'before-string)))
         ;; The struct is still registered; the timer just chose not
         ;; to draw it this tick.
         (should (= 1 (hash-table-count pending--registry)))
         ;; Tighter tick semantics: no visible placeholder → park.
         (should-not pending--global-timer))))))

(ert-deftest pending-test/unload-function-cleans-up ()
  "`pending-unload-function' removes the hook and cancels the timer."
  (pending-test--with-fresh-registry
   (let ((on-hook (memq #'pending--on-window-buffer-change
                        window-buffer-change-functions)))
     ;; Ensure the hook is registered before unload (it is at top-level load).
     (should on-hook))
   ;; Calling the unload function (without actually unloading) should
   ;; remove the hook and cancel the timer.
   (pending--ensure-timer)
   (should (timerp pending--global-timer))
   (pending-unload-function)
   (should-not (memq #'pending--on-window-buffer-change
                     window-buffer-change-functions))
   (should-not pending--global-timer)
   ;; Restore the hook so subsequent tests still work.
   (add-hook 'window-buffer-change-functions
             #'pending--on-window-buffer-change)))

(ert-deftest pending-test/get-frames-fallback ()
  "`pending--get-frames' returns a vector for known keys and unknowns.
Known keys come back from the user-facing `pending-spinner-styles';
unknown keys fall back to `pending-default-spinner-style'."
  (let ((frames (pending--get-frames 'dots-1)))
    (should (vectorp frames))
    (should (> (length frames) 0)))
  (let ((frames (pending--get-frames 'line)))
    (should (vectorp frames))
    (should (> (length frames) 0)))
  (let ((frames (pending--get-frames 'no-such-style)))
    (should (vectorp frames))
    (should (> (length frames) 0)))
  ;; If the user-facing alist is empty, the built-in fallback still
  ;; furnishes a vector for every defined style key.
  (let ((pending-spinner-styles nil))
    (let ((frames (pending--get-frames 'dots-1)))
      (should (vectorp frames))
      (should (> (length frames) 0)))))


;;; Phase 4 — determinate and ETA bars

(ert-deftest pending-test/eta-fraction-monotonic ()
  "ETA fraction is monotonically non-decreasing over time."
  (let* ((eta 8.0)
         (start 1000.0)
         (samples (mapcar
                   (lambda (dt)
                     (pending--eta-fraction start eta (+ start dt)))
                   (number-sequence 0 20))))
    (cl-loop for (a b) on samples while b
             do (should (<= a b)))))

(ert-deftest pending-test/eta-fraction-checkpoints ()
  "ETA fraction matches DESIGN.md §4 checkpoints."
  (let ((start 0.0) (eta 10.0))
    (should (= 0.0 (pending--eta-fraction start eta 0.0)))
    (should (= 0.5 (pending--eta-fraction start eta 5.0)))
    (should (= 0.8 (pending--eta-fraction start eta 8.0)))
    (should (< (abs (- 0.95 (pending--eta-fraction start eta 10.0))) 1e-9))
    ;; t = 2T → ~0.9816, definitely in (0.95, 1.0).
    (should (> (pending--eta-fraction start eta 20.0) 0.95))
    (should (< (pending--eta-fraction start eta 20.0) 1.0))
    ;; never reaches 1
    (should (< (pending--eta-fraction start eta 1000.0) 1.0))))

(ert-deftest pending-test/eta-fraction-asymptote ()
  "ETA fraction approaches 1.0 but never reaches it past the deadline."
  (let ((start 0.0) (eta 1.0))
    (dotimes (i 50)
      (let ((frac (pending--eta-fraction start eta (1+ (* i 10.0)))))
        (should (< frac 1.0))
        (should (>= frac 0.95))))))

(ert-deftest pending-test/render-bar-empty-and-full ()
  "Bar renders correctly at the boundary fractions.
WIDTH-cell bar with fraction 0 contains the empty char only; with
fraction 1 contains the full char only.  WIDTH is measured in visible
characters, not bytes."
  (dolist (style '(eighths ascii))
    (let ((pending-bar-style style))
      (let* ((blocks (pending--bar-blocks))
             (empty-char (aref blocks 0))
             (full-char  (aref blocks (1- (length blocks)))))
        (let ((bar0 (pending--render-bar 0.0 8))
              (barf (pending--render-bar 1.0 8))
              (bar5 (pending--render-bar 0.5 8)))
          (should (= 8 (length bar0)))
          (should (= 8 (length barf)))
          (should (= 8 (length bar5)))
          (should (string-match-p (regexp-quote empty-char) bar0))
          (should (string-match-p (regexp-quote full-char) barf))
          (should-not (string-match-p (regexp-quote full-char) bar0))
          (should-not (string-match-p (regexp-quote empty-char) barf)))))))

(ert-deftest pending-test/render-bar-clamps-out-of-range ()
  "`pending--render-bar' gracefully clamps fractions outside [0,1]."
  (let ((blocks (pending--bar-blocks)))
    ;; Negative fraction renders as all-empty.
    (should (string-match-p (regexp-quote (aref blocks 0))
                            (pending--render-bar -0.5 8)))
    ;; >1 fraction renders as all-full.
    (should (string-match-p (regexp-quote (aref blocks (1- (length blocks))))
                            (pending--render-bar 2.0 8)))))

(ert-deftest pending-test/render-percent-sets-after-string ()
  "Percent indicator populates the overlay's `after-string' with %."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-percent*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X" :indicator :percent
                              :percent 0.3)))
         (cl-letf (((symbol-function 'get-buffer-window)
                    (lambda (&rest _) t)))
           (pending--tick))
         (let ((after (overlay-get (pending-overlay p) 'after-string)))
           (should (stringp after))
           (should (string-match-p "30%" after))))))))

(ert-deftest pending-test/render-eta-sets-after-string ()
  "ETA indicator populates `after-string' with a remaining estimate."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-eta*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X" :indicator :eta :eta 5.0)))
         (cl-letf (((symbol-function 'get-buffer-window)
                    (lambda (&rest _) t)))
           (pending--tick))
         (let ((after (overlay-get (pending-overlay p) 'after-string)))
           (should (stringp after))
           (should (string-match-p "~[0-9]+s" after))))))))

(ert-deftest pending-test/render-spinner-no-after-string ()
  "Spinner indicator does not set `after-string'."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-spin*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X" :indicator :spinner)))
         (cl-letf (((symbol-function 'get-buffer-window)
                    (lambda (&rest _) t)))
           (pending--tick))
         (should (null (overlay-get (pending-overlay p) 'after-string))))))))


;;; Phase 5 — edit-survival

(ert-deftest pending-test/cannot-edit-placeholder-text ()
  "User attempting to edit placeholder text is rejected.
The inserted label carries `read-only' text properties; calling
`insert' inside the region with `inhibit-read-only' bound nil signals
`text-read-only'."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-readonly*")
     (with-current-buffer buf
       (insert "Before:")
       (let ((p (pending-make buf :label "MIDDLE")))
         (goto-char (1+ (overlay-start (pending-overlay p))))
         ;; Point now lies between two read-only characters of the
         ;; placeholder body — `insert' must signal `text-read-only'.
         (should-error (let ((inhibit-read-only nil))
                         (insert "EVIL"))
                       :type 'text-read-only))))))

(ert-deftest pending-test/can-edit-around-placeholder ()
  "User can edit the buffer outside the placeholder.
Inserts at `(point-min)' and after the placeholder; both succeed."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-around*")
     (with-current-buffer buf
       (insert "Before:")
       (let ((p (pending-make buf :label "MID")))
         (goto-char (point-min))
         (insert "Pre-")
         (goto-char (point-max))
         (insert "-Post")
         (should (string-match-p "Pre-Before:" (buffer-string)))
         (should (string-match-p "-Post" (buffer-string)))
         (pending-resolve p "OK"))))))

(ert-deftest pending-test/front-sticky-blocks-at-start ()
  "Insertion at exactly `(overlay-start)' is blocked by `front-sticky'."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-front-sticky*")
     (with-current-buffer buf
       (insert "Pre-")
       (let ((p (pending-make buf :label "MID")))
         (goto-char (overlay-start (pending-overlay p)))
         (should-error (let ((inhibit-read-only nil)) (insert "X"))
                       :type 'text-read-only))))))

(ert-deftest pending-test/rear-nonsticky-allows-at-end ()
  "Insertion at exactly `(overlay-end)' is allowed by `rear-nonsticky'."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-rear-nonsticky*")
     (with-current-buffer buf
       (insert "Pre-")
       (let ((p (pending-make buf :label "MID")))
         (goto-char (overlay-end (pending-overlay p)))
         (let ((inhibit-read-only nil))
           (insert "AFTER")
           (should (string-match-p "MIDAFTER" (buffer-string)))))))))

(ert-deftest pending-test/region-deletion-cancels ()
  "Deleting the placeholder region cancels with reason `:region-deleted'.
The overlay's `modification-hooks' detect a zero-length collapse and
call `pending-cancel' with `:region-deleted'.  The user's
`on-cancel' callback fires as part of the cancel path."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-delete*")
     (with-current-buffer buf
       (insert "X")
       (let* ((flag nil)
              (p (pending-make buf :label "MID"
                               :on-cancel (lambda (_) (setq flag t)))))
         (insert "Y")
         (let ((s (overlay-start (pending-overlay p)))
               (e (overlay-end (pending-overlay p)))
               (inhibit-read-only t))
           (delete-region s e))
         (should (eq (pending-status p) :cancelled))
         (should (eq (pending-reason p) :region-deleted))
         (should flag))))))

(ert-deftest pending-test/markers-survive-edit-before ()
  "Inserting text BEFORE the placeholder shifts markers but doesn't break them.
Both `pending-start' and `pending-end' are markers anchored on the
buffer; insertions at positions earlier than them push them forward
by exactly the inserted length."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-markers-before*")
     (with-current-buffer buf
       (insert "AB")
       (let* ((p (pending-make buf :label "MID"))
              (start-pos (marker-position (pending-start p)))
              (end-pos (marker-position (pending-end p))))
         (goto-char (point-min))
         (insert "Pre-")
         (should (= (+ 4 start-pos) (marker-position (pending-start p))))
         (should (= (+ 4 end-pos) (marker-position (pending-end p)))))))))

(ert-deftest pending-test/markers-survive-edit-after ()
  "Insertion AFTER the placeholder leaves the start and end markers fixed.
Confirms end-marker insertion-type is nil (not yet flipped for streaming)."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-markers-after*")
     (with-current-buffer buf
       (insert "AB")
       (let* ((p (pending-make buf :label "MID"))
              (start-pos (marker-position (pending-start p)))
              (end-pos (marker-position (pending-end p))))
         (goto-char (point-max))
         (insert "Post-")
         (should (= start-pos (marker-position (pending-start p))))
         (should (= end-pos   (marker-position (pending-end p)))))))))

(ert-deftest pending-test/resolved-text-is-editable ()
  "After resolve, the text is freely editable.
`pending--swap-region' inserts the resolved replacement without any
read-only properties, so the user can edit the post-resolve text in
the normal way."
  (pending-test--with-fresh-registry
   (pending-test--with-buffer (buf "*p-resolved-edit*")
     (with-current-buffer buf
       (let ((p (pending-make buf :label "X")))
         (pending-resolve p "DONE")
         (goto-char (point-min))
         (insert "POST-")
         (should (string-match-p "POST-DONE" (buffer-string))))))))


(provide 'pending-test)

;;; pending-test.el ends here
