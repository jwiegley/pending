;;; pending-test.el --- Tests for pending.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: BSD-3-Clause
;; See LICENSE.md for the full license text.

;;; Commentary:

;; ERT tests for `pending'.  The Phase-1 smoke and struct tests stay
;; intact; Phase 2 adds tests for state transitions, registry sync,
;; the buffer-kill hook, and the public predicates and accessors;
;; Phase 3 covers the spinner animation — frame index, render side
;; effects, the visibility gate, and timer parking; Phase 4 covers
;; the determinate / ETA bar rendering and per-indicator dispatch;
;; Phase 5 covers edit-survival (read-only properties, front-sticky
;; and rear-nonsticky semantics, region-deletion auto-cancel,
;; marker survival across edits before/after the placeholder);
;; Phase 6 covers streaming — append correctness across many
;; chunks, the `:streaming' transition on first chunk, mid-stream
;; cancel, stream-then-resolve replacement, the empty-chunk no-op,
;; read-only enforcement on streamed text, and the
;; `pending-finish-stream' read-only strip and never-streamed
;; fallback behaviour; Phase 7 covers process integration —
;; `pending-attach-process' wrapping a process sentinel so that
;; clean exits and failure exits both translate to the right
;; rejection, that resolving before the process exits leaves the
;; sentinel a no-op, that a pre-existing sentinel still fires
;; when chained, that non-terminal sentinel events (e.g.
;; `\"open\\n\"', `\"run\\n\"', `\"stopped\\n\"') do NOT reject
;; the placeholder (a critical correctness property for network
;; processes), and that a signalling pre-existing sentinel does
;; not block the wrapper's lifecycle handling; plus a defence-in-
;; depth check that `pending-finish-stream' on a killed buffer is
;; safe (the kill-buffer-hook normally cancels first); Phase 8
;; covers the interactive UI — `pending-cancel-at-point' both for
;; the success path and the no-pending `user-error' branch,
;; `pending-list' populating a `tabulated-list-mode' buffer with
;; rows for each registered placeholder, `pending-list-cancel'
;; cancelling the row's struct, and `pending-mode-line-string'
;; together with `global-pending-lighter-mode' producing the right
;; lighter format and toggling cleanly on/off.

;;; Code:

(require 'ert)
(require 'cl-lib)
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
  "`pending--gen-id' returns successively-numbered uninterned symbols.
The IDs are uninterned (so they don't leak into the global obarray)
but their `symbol-name' encodes a monotonic counter so the registry
ordering and the *Pending* list view stay deterministic."
  (let ((pending--next-id 0))
    (let ((s1 (pending--gen-id))
          (s2 (pending--gen-id)))
      (should (symbolp s1))
      (should (symbolp s2))
      ;; Uninterned: not `eq' to the equally-named interned symbol.
      (should-not (eq s1 'pending-1))
      (should-not (eq s2 'pending-2))
      ;; Names encode the monotonic counter.
      (should (equal (symbol-name s1) "pending-1"))
      (should (equal (symbol-name s2) "pending-2"))
      ;; Distinct symbols even when names collide with interned ones.
      (should-not (eq s1 s2)))))


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

(ert-deftest pending-test/cancel-survives-on-cancel-quit ()
  "If on-cancel signals quit, `pending-cancel' still transitions state.
Regression: the `condition-case' around the on-cancel callback used to
handle only `error', so a `quit' signal (e.g. user types C-g during a
`y-or-n-p' inside the callback) propagated past the `unwind-protect'
cleanup and skipped `pending--resolve-internal', wedging the placeholder
in a non-terminal state."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-quit*")
      (with-current-buffer buf
        (let ((p (pending-make
                  buf
                  :label "X"
                  :on-cancel (lambda (_) (signal 'quit nil)))))
          (let ((inhibit-message t))    ; silence the warning
            (pending-cancel p :user))
          (should (eq (pending-status p) :cancelled)))))))

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


;;; Phase 6 — streaming

(ert-deftest pending-test/stream-append-correctness ()
  "Stream three chunks; resulting region equals the concatenation.
The end marker advances on each insert because its insertion-type
flips to t on the first chunk, so successive inserts append rather
than push the marker."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream*")
      (with-current-buffer buf
        (insert "Pre:")
        (let ((p (pending-make buf :label "X")))
          (pending-resolve-stream p "abc")
          (pending-resolve-stream p "def")
          (pending-resolve-stream p "ghi")
          (pending-finish-stream p)
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "Pre:abcdefghi" (buffer-string))))))))

(ert-deftest pending-test/stream-transitions-to-streaming ()
  "First chunk transitions `:scheduled' -> `:streaming'.
The end marker's insertion-type also flips from nil to t at this
moment so subsequent inserts at its position advance the marker."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-trans*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (should (eq (pending-status p) :scheduled))
          (pending-resolve-stream p "hi")
          (should (eq (pending-status p) :streaming))
          (pending-finish-stream p)
          (should (eq (pending-status p) :resolved)))))))

(ert-deftest pending-test/stream-then-resolve-replaces ()
  "Calling `pending-resolve' mid-stream replaces the streamed content.
The streamed text is dropped; the buffer ends up with the
replacement text from `pending-resolve' regardless of how many
chunks had streamed in."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-replace*")
      (with-current-buffer buf
        (insert "Pre:")
        (let ((p (pending-make buf :label "X")))
          (pending-resolve-stream p "streamed-content")
          (pending-resolve p "FINAL")
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "Pre:FINAL" (buffer-string)))
          (should-not (string-match-p "streamed-content" (buffer-string))))))))

(ert-deftest pending-test/stream-mid-cancel ()
  "Cancelling mid-stream runs `on-cancel' and replaces with cancellation glyph.
The streamed content is dropped via the regular swap-region path
that `pending-cancel' invokes."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-mid-cancel*")
      (with-current-buffer buf
        (let* ((flag nil)
               (p (pending-make buf :label "X"
                                :on-cancel (lambda (_) (setq flag t)))))
          (pending-resolve-stream p "partial")
          (pending-cancel p :user)
          (should (eq (pending-status p) :cancelled))
          (should flag)
          ;; Streamed content is replaced with the cancellation glyph.
          (should-not (string-match-p "partial" (buffer-string))))))))

(ert-deftest pending-test/stream-empty-chunk-no-op ()
  "Empty stream chunk is a no-op.
Status does not transition; the placeholder stays in `:scheduled'
because the empty-chunk early-return bypasses the state machine."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-empty*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-resolve-stream p "")
          (should (eq (pending-status p) :scheduled))
          (pending-finish-stream p)
          (should (eq (pending-status p) :resolved)))))))

(ert-deftest pending-test/streamed-text-is-read-only ()
  "Streamed text cannot be edited mid-stream.
Each chunk is propertized `read-only' just like the initial label
so the user gets the standard `text-read-only' rejection."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-readonly*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-resolve-stream p "abc")
          (goto-char (1+ (overlay-start (pending-overlay p))))
          (should-error (let ((inhibit-read-only nil)) (insert "EVIL"))
                        :type 'text-read-only))))))

(ert-deftest pending-test/finish-stream-clears-read-only ()
  "After `pending-finish-stream', the streamed text is freely editable.
The finalize path calls `remove-text-properties' over the whole
streamed region so `read-only', `front-sticky', and `rear-nonsticky'
all come off."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-finish-edit*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               (start nil) (end nil))
          (pending-resolve-stream p "abc")
          (setq start (marker-position (pending-start p))
                end   (marker-position (pending-end p)))
          (pending-finish-stream p)
          (when (and start end)
            (goto-char (1+ start))
            (let ((inhibit-read-only nil))
              (insert "X"))
            (should (string-match-p "aXbc" (buffer-string)))))))))

(ert-deftest pending-test/finish-stream-without-chunks ()
  "Finish-stream on a never-streamed placeholder behaves like resolve.
With no chunks ever streamed the call delegates to
`(pending-resolve p \"\")', so the buffer ends up with the
placeholder removed and replaced by the empty string."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-no-stream*")
      (with-current-buffer buf
        (insert "Before:")
        (let ((p (pending-make buf :label "X")))
          (pending-finish-stream p)
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "Before:" (buffer-string)))
          (should-not (string-match-p "X" (buffer-string))))))))


;;; Phase 7 — process integration

(ert-deftest pending-test/process-clean-exit-rejects ()
  "A clean process exit on an unresolved placeholder rejects.
The wrapper sentinel installed by `pending-attach-process'
detects a `\"finished\"' event while P is still active and
rejects with the reason `\"process exited without resolving\"'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-proc-clean*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               (proc (start-process "p-test-clean" nil "true")))
          (pending-attach-process p proc)
          ;; Wait for the process to exit (true returns immediately).
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          ;; The sentinel runs asynchronously; give it a chance.
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (pending-active-p p) (< (float-time) deadline))
              (sit-for 0.05)))
          (should (eq (pending-status p) :rejected))
          (should (string-match-p "without resolving"
                                  (or (pending-reason p) ""))))))))

(ert-deftest pending-test/process-failure-rejects ()
  "A non-zero process exit rejects with a `process:' reason.
The wrapper sentinel detects an `\"exited abnormally\"' event and
rejects with `\"process: ...\"' formed from the trimmed event
string."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-proc-fail*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               (proc (start-process "p-test-fail" nil "false")))
          (pending-attach-process p proc)
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (pending-active-p p) (< (float-time) deadline))
              (sit-for 0.05)))
          (should (eq (pending-status p) :rejected))
          (should (stringp (pending-reason p)))
          (should (string-match-p "process:" (pending-reason p))))))))

(ert-deftest pending-test/process-resolved-before-exit ()
  "Resolving before the process exits leaves the sentinel a no-op.
If the caller calls `pending-resolve' BEFORE the process exits,
the wrapper sentinel's `pending-reject' call hits the
single-resolution guard and is suppressed; status stays
`:resolved'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-proc-resolve*")
      (with-current-buffer buf
        (let* ((warning-minimum-log-level :error)
               (p (pending-make buf :label "X"))
               (proc (start-process "p-test-resolved" nil "sleep" "0.1")))
          (pending-attach-process p proc)
          (pending-resolve p "manual-resolve")
          ;; Wait for the process to exit; sentinel should be a no-op.
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          ;; Status should still be :resolved, not :rejected.
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "manual-resolve" (buffer-string))))))))

(ert-deftest pending-test/process-existing-sentinel-still-fires ()
  "Attaching to a process that already has a sentinel chains them.
The caller-installed sentinel runs FIRST, then the wrapper
runs.  Both side effects (the user's flag and the placeholder
rejection) are observed."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-proc-chain*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               (sentinel-flag nil)
               (proc (start-process "p-test-chain" nil "true")))
          (set-process-sentinel proc (lambda (_proc _event)
                                       (setq sentinel-flag t)))
          (pending-attach-process p proc)
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (pending-active-p p) (< (float-time) deadline))
              (sit-for 0.05)))
          (should sentinel-flag)
          (should (eq (pending-status p) :rejected)))))))

(ert-deftest pending-test/process-non-terminal-events-no-op ()
  "Non-terminal sentinel events (e.g. \"open\\n\", \"run\\n\") do not reject.
The fix replaces event-string parsing with a `process-status'
check, so any status that isn't `exit', `signal', `failed', or
`closed' is a no-op.  This is critical for network processes —
gptel, url-retrieve via `make-process', MCP servers, and language
servers all emit `\"open\\n\"' on connect, which the previous
implementation incorrectly rejected on."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-non-terminal*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               ;; Use a long-running process; we won't actually kill it.
               (proc (start-process "p-test-nonterm" nil "sleep" "10")))
          (pending-attach-process p proc)
          ;; Manually call the sentinel with a non-terminal event.
          ;; In real Emacs, "open" fires when a network process connects;
          ;; we simulate by direct call since `start-process' isn't a
          ;; network process.  The point: when process-status returns
          ;; `run' (still alive), our sentinel must be a no-op.
          (pending--process-sentinel p proc "run\n")
          (should (eq (pending-status p) :scheduled))
          (pending--process-sentinel p proc "open\n")
          (should (eq (pending-status p) :scheduled))
          (pending--process-sentinel p proc "stopped\n")
          (should (eq (pending-status p) :scheduled))
          ;; Cleanup: kill the sleep process so the test ends.
          (delete-process proc)
          ;; Wait briefly for the kill sentinel to fire and reject the placeholder.
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          ;; The wrapper sentinel was called with "killed\n" or similar; status
          ;; should now be :rejected (or possibly the original :scheduled if
          ;; the kill happened before the sentinel ran).  We don't assert
          ;; further to avoid flakiness; the prior `:scheduled' assertions
          ;; before the kill are the meat of this test.
          )))))

(ert-deftest pending-test/process-existing-sentinel-error-still-runs-wrapper ()
  "If the user's existing sentinel signals, the wrapper still runs.
The `condition-case' around the chained call must catch the error
so the wrapper's lifecycle bookkeeping is not skipped."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-bad-sentinel*")
      (with-current-buffer buf
        (let* ((warning-minimum-log-level :error)
               (p (pending-make buf :label "X"))
               (proc (start-process "p-test-bad" nil "true")))
          ;; Install a sentinel that signals.
          (set-process-sentinel proc (lambda (_proc _event) (error "boom")))
          (pending-attach-process p proc)
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (pending-active-p p) (< (float-time) deadline))
              (sit-for 0.05)))
          ;; Wrapper still ran, so the placeholder is rejected.
          (should (eq (pending-status p) :rejected)))))))


;;; Phase 7 — buffer-dead defense in depth

(ert-deftest pending-test/finish-stream-buffer-dead-still-resolves ()
  "Killing the buffer mid-stream and then calling `pending-finish-stream'
must still flip status (status will be :cancelled because
kill-buffer-hook fires first; finish-stream sees the terminal
state and bails).  Documents that the buffer-kill hook handles
the dead-buffer case before `pending-finish-stream' ever sees
it.  The defense-in-depth code in `pending-finish-stream' is
still valuable for correctness but is essentially unreachable in
normal use."
  (pending-test--with-fresh-registry
    (let* ((buf (generate-new-buffer "*p-finish-dead*"))
           (callback-ran nil)
           (p (with-current-buffer buf
                (pending-make buf :label "X"
                              :on-resolve (lambda (_) (setq callback-ran t))))))
      (with-current-buffer buf (pending-resolve-stream p "abc"))
      (kill-buffer buf)
      ;; By now, kill-buffer-hook should have run, cancelling the placeholder.
      ;; Status: :cancelled. Reason: :buffer-killed. The on-resolve callback
      ;; was fired by pending-cancel.
      (should (memq (pending-status p) '(:cancelled :resolved)))
      (should callback-ran)
      ;; Calling finish-stream now is a no-op (placeholder is terminal).
      (pending-finish-stream p))))



;;; Phase 8 — interactive UI

(ert-deftest pending-test/cancel-at-point-cancels ()
  "`pending-cancel-at-point' cancels the pending at point.
Point is positioned inside the placeholder overlay so `pending-at'
returns the struct; the command then routes through `pending-cancel'
with reason `:cancelled-by-user'.  The label is more than one
character long so the position one past the overlay start lands
strictly inside the overlay range."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-cap*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "MIDDLE")))
          (goto-char (1+ (overlay-start (pending-overlay p))))
          (pending-cancel-at-point)
          (should (eq (pending-status p) :cancelled)))))))

(ert-deftest pending-test/cancel-at-point-no-pending ()
  "`pending-cancel-at-point' signals `user-error' when no pending at point.
The buffer holds plain text only, so `pending-at' returns nil and the
command takes the error branch."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-no-cap*")
      (with-current-buffer buf
        (insert "no placeholder here")
        (goto-char (point-min))
        (should-error (pending-cancel-at-point) :type 'user-error)))))

(ert-deftest pending-test/list-populates ()
  "`pending-list' creates the *Pending* buffer with one row per placeholder.
The mode is `pending-list-mode' and `tabulated-list-entries' has at
least the two rows we made before opening the list."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-list*")
      (with-current-buffer buf
        (pending-make buf :label "A" :group 'g1)
        (pending-make buf :label "B" :group 'g2))
      (unwind-protect
          (progn
            (pending-list)
            (with-current-buffer "*Pending*"
              (should (eq major-mode 'pending-list-mode))
              (should (= (length tabulated-list-entries) 2))))
        (when (get-buffer "*Pending*")
          (kill-buffer "*Pending*"))))))

(ert-deftest pending-test/list-cancel-row ()
  "`pending-list-cancel' on a row cancels the placeholder.
Walks the buffer rows to find the one whose `tabulated-list-get-id'
returns the target struct, then invokes the cancel command."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-list-cancel*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "TARGET")))
          (unwind-protect
              (progn
                (pending-list)
                (with-current-buffer "*Pending*"
                  ;; Find the row for our target.
                  (goto-char (point-min))
                  (let (found)
                    (while (and (not found) (not (eobp)))
                      (when (eq (tabulated-list-get-id) p)
                        (setq found t))
                      (unless found (forward-line 1)))
                    (should found)
                    (pending-list-cancel)))
                (should (eq (pending-status p) :cancelled)))
            (when (get-buffer "*Pending*")
              (kill-buffer "*Pending*"))))))))

(ert-deftest pending-test/mode-line-string-format ()
  "`pending-mode-line-string' returns nil when idle, else a count string.
With one active placeholder, the string contains the count digit `1'."
  (pending-test--with-fresh-registry
    (should (null (pending-mode-line-string)))
    (pending-test--with-buffer (buf "*p-mlstr*")
      (with-current-buffer buf
        (pending-make buf :label "X")
        (let ((s (pending-mode-line-string)))
          (should (stringp s))
          (should (string-match-p "1" s)))))))

(ert-deftest pending-test/mode-line-shows-smallest-eta ()
  "When two placeholders have ETAs, lighter shows the smaller remaining time."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-min-eta*")
      (with-current-buffer buf
        (let ((p1 (pending-make buf :label "fast" :indicator :eta :eta 5.0))
              (p2 (pending-make buf :label "slow" :indicator :eta :eta 100.0)))
          ;; Force start-times to known values for determinism.
          (setf (pending-start-time p1) (- (float-time) 1.0))
          (setf (pending-start-time p2) (- (float-time) 1.0))
          (let ((s (pending-mode-line-string)))
            (should (stringp s))
            ;; The smaller remaining ETA is ~4s (5 - 1), not ~99s.
            (should (string-match-p "~[1-9]s" s))
            (should-not (string-match-p "~9[0-9]s" s))))))))

(ert-deftest pending-test/lighter-mode-toggles ()
  "`global-pending-lighter-mode' adds and removes the mode-line construct.
Toggling on adds the shared sentinel by `memq'; toggling off removes
it via `delq' so a subsequent `memq' returns nil."
  (pending-test--with-fresh-registry
    (let ((global-mode-string nil))
      (global-pending-lighter-mode 1)
      (should (memq pending--mode-line-construct global-mode-string))
      (global-pending-lighter-mode -1)
      (should-not (memq pending--mode-line-construct global-mode-string)))))


;;; Phase 9 — kill-emacs-query and demo

(ert-deftest pending-test/kill-emacs-query-default-allows-exit ()
  "With `pending-confirm-on-emacs-exit' nil, the query allows exit.
Default behaviour: even if active placeholders are present, the
query function returns t (no prompt, no block)."
  (pending-test--with-fresh-registry
    (let ((pending-confirm-on-emacs-exit nil))
      (pending-test--with-buffer (buf "*p-kill-q*")
        (with-current-buffer buf
          (pending-make buf :label "X"))
        (should (pending--kill-emacs-query))))))

(ert-deftest pending-test/kill-emacs-query-empty-allows-exit ()
  "With no active pendings, the query allows exit even when confirm is on.
The early-out for an empty registry sidesteps the `yes-or-no-p'
prompt, so this case is safe to call non-interactively."
  (pending-test--with-fresh-registry
    (let ((pending-confirm-on-emacs-exit t))
      (should (pending--kill-emacs-query)))))

(ert-deftest pending-test/demo-creates-buffer ()
  "`pending-demo' creates the *pending-demo* buffer with three placeholders.
Defensive cleanup cancels any remaining placeholders before killing
the demo buffer so leftover timers cannot fire after the test ends."
  (unwind-protect
      (pending-test--with-fresh-registry
        (pending-demo)
        (let ((buf (get-buffer "*pending-demo*")))
          (should buf)
          (with-current-buffer buf
            ;; Three placeholders in the demo.
            (should (= 3 (length (pending-list-active buf)))))))
    (when (get-buffer "*pending-demo*")
      ;; Cancel any remaining placeholders before killing the buffer.
      (with-current-buffer "*pending-demo*"
        (dolist (p (pending-list-active (get-buffer "*pending-demo*")))
          (pending-cancel p :test-cleanup)))
      (kill-buffer "*pending-demo*"))))


;;; Phase 10 — simple positional API

(ert-deftest pending-test/overlay-creates-token ()
  "`pending-overlay' returns a usable token with start/end markers."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-overlay*")
      (with-current-buffer buf
        (insert "Before-MID-After")
        (let* ((beg (+ (point-min) 7))
               (end (+ (point-min) 10))
               (token (pending-overlay beg end "rewriting")))
          (should (pending-p token))
          (should (eq (pending-buffer token) buf))
          (should (= (marker-position (pending-start token)) beg))
          (should (= (marker-position (pending-end token)) end))
          (should (eq (pending-indicator token) :lighter))
          (let ((bs (overlay-get (pending-overlay token) 'before-string)))
            (should (stringp bs))
            (should (string-match-p "rewriting" bs))))))))

(ert-deftest pending-test/insert-creates-zero-width ()
  "`pending-insert' creates a zero-width placeholder at POS."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-insert*")
      (with-current-buffer buf
        (insert "Hello world")
        (let ((token (pending-insert (point) "calling LLM")))
          (should (pending-p token))
          (should (= (marker-position (pending-start token))
                     (marker-position (pending-end token))))
          (let ((bs (overlay-get (pending-overlay token) 'before-string)))
            (should (string-match-p "calling LLM" bs))))))))

(ert-deftest pending-test/resolve-replaces-region ()
  "`pending-resolve' on an overlay TOKEN replaces [BEG, END] with STR."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-region*")
      (with-current-buffer buf
        (insert "Before-OLD-After")
        (let* ((beg (+ (point-min) 7))
               (end (+ (point-min) 10))
               (token (pending-overlay beg end "...")))
          (pending-resolve token "NEW")
          (should (eq (pending-status token) :resolved))
          (should (string-match-p "Before-NEW-After" (buffer-string))))))))

(ert-deftest pending-test/resolve-inserts-at-pos ()
  "`pending-resolve' on an insert TOKEN (BEG=END) inserts STR at POS."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-pos*")
      (with-current-buffer buf
        (insert "Hello world")
        (goto-char (1+ (point-min)))  ; between H and ello
        (let ((token (pending-insert (point) "...")))
          (pending-resolve token "NEW")
          (should (eq (pending-status token) :resolved))
          (should (string-match-p "HNEWello world" (buffer-string))))))))

(ert-deftest pending-test/goto-jumps-to-start ()
  "`pending-goto' moves point to TOKEN's start position."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-goto*")
      (with-current-buffer buf
        (insert "Some content here xyz")
        (let* ((target-pos (+ (point-min) 5))
               (token (pending-insert target-pos "...")))
          (goto-char (point-min))
          (pending-goto token)
          (should (= (point) target-pos))
          (should (eq (current-buffer) buf)))))))

(ert-deftest pending-test/alist-snapshot ()
  "`pending-alist' returns (ID . STRUCT) entries for active placeholders."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-alist*")
      (with-current-buffer buf
        (let ((t1 (pending-insert (point-min) "A"))
              (t2 (pending-insert (point-min) "B")))
          (let ((alist (pending-alist)))
            (should (= 2 (length alist)))
            (should (member (cons (pending-id t1) t1) alist))
            (should (member (cons (pending-id t2) t2) alist))))))))

(ert-deftest pending-test/lighter-mode-no-spinner-anim ()
  "`:lighter' indicator does not advance the spinner frame index."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-lighter-anim*")
      (with-current-buffer buf
        (let ((token (pending-insert (point-min) "static")))
          (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
            (pending--tick))
          (should (null (pending-last-frame token)))
          (let ((bs (overlay-get (pending-overlay token) 'before-string)))
            (should (string-match-p "static" bs))))))))


;;; Phase 11 — face policy: never face inserted text

(ert-deftest pending-test/inserted-label-has-no-face ()
  "`pending-make' insert mode: the inserted label text has no `face' property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-no-face*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "WORK")))
          (let ((face (get-text-property (overlay-start (pending-ov p)) 'face)))
            (should-not face))
          (let ((overlay-face (overlay-get (pending-ov p) 'face)))
            (should-not overlay-face)))))))

(ert-deftest pending-test/overlay-region-has-overlay-face ()
  "`pending-overlay' adopt mode (non-empty region): overlay HAS a face,
but the underlying buffer text does NOT carry a face text property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-overlay-face*")
      (with-current-buffer buf
        (insert "Before-MID-After")
        (let* ((tok (pending-overlay 8 11 "rewriting"))
               (ov  (pending-ov tok)))
          (should (eq (overlay-get ov 'face) 'pending-highlight))
          ;; Underlying buffer text at position 8 has no face property.
          (should-not (get-text-property 8 'face)))))))

(ert-deftest pending-test/zero-width-overlay-has-no-overlay-face ()
  "`pending-insert' (zero-width) does NOT set a face on the overlay."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-insert-no-face*")
      (with-current-buffer buf
        (insert "Hello")
        (let* ((tok (pending-insert 3 "calling"))
               (ov  (pending-ov tok)))
          (should-not (overlay-get ov 'face)))))))

(ert-deftest pending-test/resolved-text-has-no-face ()
  "After `pending-resolve', the inserted resolution text has no `face' property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolved-no-face*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-resolve p "DONE")
          (should-not (get-text-property (point-min) 'face)))))))

(ert-deftest pending-test/streamed-text-has-no-face ()
  "Streamed chunks land in the buffer without a `face' property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-no-face*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-resolve-stream p "abc")
          (let ((pos (1+ (overlay-start (pending-ov p)))))
            (should-not (get-text-property pos 'face))))))))


(provide 'pending-test)

;;; pending-test.el ends here
