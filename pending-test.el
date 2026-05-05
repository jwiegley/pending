;;; pending-test.el --- Tests for pending.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley <jwiegley@gmail.com>

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: BSD-3-Clause
;; See LICENSE.md for the full license text.

;;; Commentary:

;; ERT tests for `pending'.  Tests are grouped by topic:
;;
;;   - smoke and struct construction
;;   - state transitions (the four terminal paths and their
;;     bookkeeping invariants)
;;   - registry and the buffer-kill hook
;;   - accessor predicates and snapshots
;;   - slot mutation via `pending-update'
;;   - adopt-mode placement and deadline timer
;;   - re-entrancy guards and on-resolve coverage
;;   - spinner animation (frame index, render side effects,
;;     visibility gate, single-timer parking)
;;   - determinate and ETA bar rendering, per-indicator dispatch
;;   - edit-survival (read-only properties, sticky semantics,
;;     region-deletion auto-cancel, marker survival across edits)
;;   - streaming (chunk append, `:streaming' transition, mid-stream
;;     cancel, stream-then-resolve, empty-chunk no-op, read-only
;;     enforcement on streamed text, finish strip and
;;     never-streamed fallback)
;;   - process integration (sentinel wrapping, clean and failure
;;     exits, resolve-before-exit no-op, sentinel chaining, network
;;     non-terminal events, faulty pre-existing sentinel survival,
;;     re-attach without wrapper-chain leak)
;;   - buffer-dead defence in depth
;;   - interactive UI (`pending-cancel-at-point', `pending-list',
;;     `pending-list-cancel', `pending-mode-line-string',
;;     `global-pending-lighter-mode')
;;   - `kill-emacs-query' and demo wiring
;;   - simple positional API (`pending-region', `pending-insert')
;;   - face policy (the library never faces text it inserts itself)

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
animation timer started by `pending-make' is local to BODY.  Also
rebinds `pending--list-refresh-pending' and
`pending--list-refresh-timer' so a test that leaves the debounced
refresh flag/timer set cannot bleed into subsequent tests.  The
animation timer and the list-refresh timer are cancelled on exit
so neither can fire after BODY returns."
  (declare (indent 0) (debug t))
  `(let ((pending--registry (make-hash-table :test 'eq))
         (pending--next-id 0)
         (pending--global-timer nil)
         (pending--list-refresh-pending nil)
         (pending--list-refresh-timer nil))
     (unwind-protect
         (progn ,@body)
       (when (timerp pending--global-timer)
         (cancel-timer pending--global-timer))
       (when (timerp pending--list-refresh-timer)
         (cancel-timer pending--list-refresh-timer)))))

(defvar pending-test--clock 0.0
  "Mocked wall-clock value for `pending-test--with-mocked-time'.
Bound by the macro to a fresh float per BODY; advanced by
`pending-test--advance'.")

(defvar pending-test--scheduled nil
  "List of pending mocked timer entries.
Each entry is `(COOKIE DUE FN ARGS)': COOKIE is a unique cons
identifying the entry by `eq', DUE is the `float-time' at which
the timer fires, FN is the callback, ARGS is the argument list.
The list is mutated by `run-at-time' (push), `cancel-timer'
\(remove), and `pending-test--advance' (drain due entries).")

(defmacro pending-test--with-mocked-time (&rest body)
  "Run BODY with `current-time' / `float-time' / `run-at-time' mocked.
Inside BODY:
- `(float-time)' returns `pending-test--clock' (a let-bound
   float).
- `pending-test--advance SECONDS' advances the clock and fires
   any due timers.
- `run-at-time' adds entries to `pending-test--scheduled' but
   does not actually schedule any real Emacs timer.
- `cancel-timer' removes mock-timer entries by identity.
- `timerp' recognises mock-timer cookies.

Useful for testing deadline expiry, ETA fraction, and spinner
frame index without burning real wall-time on `sit-for' loops.
Real timers (e.g. animation `run-with-timer' from
`pending--ensure-timer') are NOT mocked --- they go through the
unmocked `run-with-timer' inside the let-binding.  Tests that
need the animation timer mocked should call `pending--ensure-
timer' inside BODY and rely on the mocked `run-at-time'."
  (declare (indent 0) (debug t))
  `(let ((pending-test--clock 0.0)
         (pending-test--scheduled nil))
     (cl-letf*
         (((symbol-function 'float-time)
           (lambda (&optional _) pending-test--clock))
          ((symbol-function 'run-at-time)
           (lambda (when _repeat fn &rest args)
             (let ((due (cond ((numberp when)
                               (+ pending-test--clock when))
                              ((stringp when)
                               pending-test--clock)
                              (t pending-test--clock)))
                   (cookie (cons 'pending-test--mock-timer
                                 (cl-incf pending-test--next-mock-timer))))
               (push (list cookie due fn args) pending-test--scheduled)
               cookie)))
          ((symbol-function 'cancel-timer)
           (lambda (tm)
             (setq pending-test--scheduled
                   (cl-remove tm pending-test--scheduled
                              :key #'car :test #'eq))))
          ((symbol-function 'timerp)
           (lambda (x)
             (and (consp x) (eq (car-safe x) 'pending-test--mock-timer)))))
       ,@body)))

(defvar pending-test--next-mock-timer 0
  "Monotonic counter used to make mock-timer cookies distinct by `eq'.")

(defun pending-test--advance (seconds)
  "Advance the mocked clock by SECONDS and fire any due timers.
Timers are fired in chronological order.  A timer that schedules
another timer via `run-at-time' is honoured: the new entry is
added to `pending-test--scheduled' and will fire if its due time
falls within the remaining advance window.

Must be called inside `pending-test--with-mocked-time'."
  (let ((target (+ pending-test--clock seconds)))
    (catch 'done
      (while t
        ;; Find the entry with the earliest due time that is still
        ;; within the advance window.
        (let* ((due-now (cl-remove-if-not
                         (lambda (entry) (<= (cadr entry) target))
                         pending-test--scheduled))
               (next (and due-now
                          (car (sort due-now
                                     (lambda (a b)
                                       (< (cadr a) (cadr b))))))))
          (unless next (throw 'done nil))
          (setq pending-test--scheduled
                (cl-remove next pending-test--scheduled
                           :key #'car :test #'eq))
          (setq pending-test--clock (cadr next))
          (apply (caddr next) (cadddr next)))))
    (setq pending-test--clock target)))


;;; Smoke and struct tests

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


;;; State transitions

(ert-deftest pending-test/scheduled-to-resolved ()
  "Creating then resolving leaves status `:resolved' and replaces text."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*pending-finish*")
      (with-current-buffer buf
        (insert "Before: ")
        (let ((p (pending-make buf :label "Calling")))
          (should (eq (pending-status p) :scheduled))
          (should (equal (buffer-string) "Before: Calling"))
          (insert " :After")
          (pending-finish p "DONE")
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

(ert-deftest pending-test/no-double-finish ()
  "Resolving twice is a no-op on the second call; status persists."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*pending-double*")
      (with-current-buffer buf
        (let ((warning-minimum-log-level :error)
              (p (pending-make buf :label "Calling")))
          (should (eq t (pending-finish p "first")))
          (should (eq nil (pending-finish p "second")))
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "first" (buffer-string))))))))

(ert-deftest pending-test/no-finish-after-reject ()
  "`pending-finish' after `pending-reject' is suppressed."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*pending-reject-resolve*")
      (with-current-buffer buf
        (let ((warning-minimum-log-level :error)
              (p (pending-make buf :label "Calling")))
          (should (eq t (pending-reject p "nope")))
          (should (eq nil (pending-finish p "late")))
          (should (eq (pending-status p) :rejected)))))))


;;; Registry and buffer-kill

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
              (pending-finish p1 "1")
              (pending-finish p2 "2")
              (pending-finish p3 "3")
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


;;; Accessors

(ert-deftest pending-test/pending-at-finds-pending ()
  "`pending-at' returns the struct on the placeholder, nil after resolve."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*pending-at*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "Hello")))
          (goto-char (1+ (marker-position (pending-start p))))
          (should (eq (pending-at) p))
          (pending-finish p "X")
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


;;; Slot mutation

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
          (pending-finish p "done"))))))


;;; Adopt mode and deadline timer

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
            (let ((ov (pending-region p)))
              (should (overlayp ov))
              (should (= (overlay-start ov) s))
              (should (= (overlay-end ov) e)))
            ;; And resolve replaces only that range.
            (pending-finish p "ADOPTED")
            (should (equal (buffer-string) "Before:ADOPTED:After"))))))))

(ert-deftest pending-test/deadline-rejects-timed-out ()
  "Deadline timer rejects an active placeholder with `:timed-out'.
Uses `pending-test--with-mocked-time' so the test is
deterministic and does not burn real wall-clock time on a
`sit-for' loop."
  (pending-test--with-fresh-registry
    (pending-test--with-mocked-time
      (pending-test--with-buffer (buf "*pending-test/deadline*")
        (with-current-buffer buf
          (let ((p (pending-make buf :label "X" :deadline 0.05)))
            (should (eq (pending-status p) :scheduled))
            (pending-test--advance 0.1)
            (should (eq (pending-status p) :rejected))
            (should (eq (pending-reason p) :timed-out))))))))


;;; Re-entrancy and on-resolve coverage

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
              ('resolve (pending-finish p "ok"))
              ('reject  (pending-reject  p "bad"))
              ('cancel  (pending-cancel  p)))
            (should (= calls 1))
            (should (eq (pending-status p) (cdr case)))))))))


;;; Spinner animation

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
          (let ((bs (overlay-get (pending-region p) 'before-string)))
            (should (stringp bs))
            ;; Glyph + space.
            (should (= (length bs) 2))
            (should (equal (substring bs 1 2) " ")))
          ;; Resolve clears the decoration on the (now-defunct) overlay's
          ;; before-string before the swap, so the resolved text in the
          ;; buffer contains no spinner.
          (let ((ov (pending-region p)))
            (pending-finish p "DONE")
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
          (pending-finish p "ok")
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
          (should (null (overlay-get (pending-region p) 'before-string)))
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

(ert-deftest pending-test/unregister-removes-buffer-local-hook ()
  "Buffer-local `kill-buffer-hook' is removed when last placeholder leaves.
`pending--register' adds the hook on first registration; it must
come off when the buffer's local registry empties so a buffer that
no longer hosts placeholders does not carry a stale hook."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-hook-cleanup*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (should (memq #'pending--on-kill-buffer
                        (buffer-local-value 'kill-buffer-hook buf)))
          (pending-finish p "done")
          (should-not (memq #'pending--on-kill-buffer
                            (buffer-local-value 'kill-buffer-hook buf))))))))

(ert-deftest pending-test/unload-function-strips-buffer-local-hooks ()
  "`pending-unload-function' walks buffers and strips the local hook.
A buffer that still has live placeholders carries the buffer-local
`kill-buffer-hook' entry; unloading the feature must leave no
dangling hooks behind on any live buffer."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-hook-unload*")
      (with-current-buffer buf
        (pending-make buf :label "still-active")
        (should (memq #'pending--on-kill-buffer
                      (buffer-local-value 'kill-buffer-hook buf)))
        (pending-unload-function)
        (should-not (memq #'pending--on-kill-buffer
                          (buffer-local-value 'kill-buffer-hook buf)))
        ;; Restore for the rest of the suite.
        (add-hook 'window-buffer-change-functions
                  #'pending--on-window-buffer-change)))))

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


;;; Determinate and ETA bars

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
          (let ((after (overlay-get (pending-region p) 'after-string)))
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
          (let ((after (overlay-get (pending-region p) 'after-string)))
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
          (should (null (overlay-get (pending-region p) 'after-string))))))))


;;; Edit-survival

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
          (goto-char (1+ (overlay-start (pending-region p))))
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
          (pending-finish p "OK"))))))

(ert-deftest pending-test/front-sticky-blocks-at-start ()
  "Insertion at exactly `(overlay-start)' is blocked by `front-sticky'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-front-sticky*")
      (with-current-buffer buf
        (insert "Pre-")
        (let ((p (pending-make buf :label "MID")))
          (goto-char (overlay-start (pending-region p)))
          (should-error (let ((inhibit-read-only nil)) (insert "X"))
                        :type 'text-read-only))))))

(ert-deftest pending-test/rear-nonsticky-allows-at-end ()
  "Insertion at exactly `(overlay-end)' is allowed by `rear-nonsticky'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-rear-nonsticky*")
      (with-current-buffer buf
        (insert "Pre-")
        (let ((p (pending-make buf :label "MID")))
          (goto-char (overlay-end (pending-region p)))
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
          (let ((s (overlay-start (pending-region p)))
                (e (overlay-end (pending-region p)))
                (inhibit-read-only t))
            (delete-region s e))
          (should (eq (pending-status p) :cancelled))
          (should (eq (pending-reason p) :region-deleted))
          (should flag))))))

(ert-deftest pending-test/finish-fires-buffer-change-hooks ()
  "`pending-finish' must fire global change hooks during its swap.
External systems (notably `org-element--cache') rely on
`before-change-functions' / `after-change-functions' to keep
their state in sync with buffer text; suppressing them via
`inhibit-modification-hooks' caused org-element to emit \"Invalid
search bound (wrong side of point)\" warnings after a placeholder
resolved inside an `org-mode' buffer.  The library now uses
`pending--inhibit-on-modify', which gates only its own overlay
hook and leaves the global hooks intact."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-change-hooks-finish*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "loading"))
              (before-fired nil)
              (after-fired nil))
          (add-hook 'before-change-functions
                    (lambda (_b _e) (setq before-fired t))
                    nil 'local)
          (add-hook 'after-change-functions
                    (lambda (_b _e _l) (setq after-fired t))
                    nil 'local)
          (pending-finish p "done")
          (should before-fired)
          (should after-fired))))))

(ert-deftest pending-test/cancel-fires-buffer-change-hooks ()
  "`pending-cancel' likewise fires global change hooks during the swap."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-change-hooks-cancel*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "loading"))
              (before-fired nil)
              (after-fired nil))
          (add-hook 'before-change-functions
                    (lambda (_b _e) (setq before-fired t))
                    nil 'local)
          (add-hook 'after-change-functions
                    (lambda (_b _e _l) (setq after-fired t))
                    nil 'local)
          (pending-cancel p :test-cleanup)
          (should before-fired)
          (should after-fired))))))

(ert-deftest pending-test/reject-fires-buffer-change-hooks ()
  "`pending-reject' likewise fires global change hooks during the swap."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-change-hooks-reject*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "loading"))
              (before-fired nil)
              (after-fired nil))
          (add-hook 'before-change-functions
                    (lambda (_b _e) (setq before-fired t))
                    nil 'local)
          (add-hook 'after-change-functions
                    (lambda (_b _e _l) (setq after-fired t))
                    nil 'local)
          (pending-reject p :test-cleanup "failed")
          (should before-fired)
          (should after-fired))))))

(ert-deftest pending-test/stream-fires-buffer-change-hooks ()
  "Streaming sites must also fire global change hooks.
Covers the three streaming code paths that previously bound
`inhibit-modification-hooks': the first-chunk delete that strips
the loading label, the per-chunk insert at the end marker, and
the property-strip in `pending-stream-finish'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-change-hooks-stream*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "loading"))
              (before-count 0)
              (after-count 0))
          (add-hook 'before-change-functions
                    (lambda (_b _e) (cl-incf before-count))
                    nil 'local)
          (add-hook 'after-change-functions
                    (lambda (_b _e _l) (cl-incf after-count))
                    nil 'local)
          (pending-stream-insert p "first")
          (pending-stream-insert p "second")
          (pending-stream-finish p)
          (should (> before-count 0))
          (should (> after-count 0)))))))

(ert-deftest pending-test/internal-mod-flag-suppresses-on-modify ()
  "Binding `pending--inhibit-on-modify' makes `pending--on-modify' a no-op.
This is the mechanism by which the library's own delete+insert
during resolve does not retrigger the cancel-on-collapse path.
Replaces the earlier mechanism (binding
`inhibit-modification-hooks'), which also silenced unrelated
global hooks such as those used by `org-element--cache'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-internal-mod-flag*")
      (with-current-buffer buf
        (insert "X")
        (let ((p (pending-make buf :label "MID")))
          (insert "Y")
          (let ((s (overlay-start (pending-region p)))
                (e (overlay-end (pending-region p)))
                (inhibit-read-only t)
                (pending--inhibit-on-modify t))
            (delete-region s e))
          (should-not (eq (pending-status p) :cancelled))
          (pending-cancel p :test-cleanup))))))

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
          (pending-finish p "DONE")
          (goto-char (point-min))
          (insert "POST-")
          (should (string-match-p "POST-DONE" (buffer-string))))))))


;;; Streaming

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
          (pending-stream-insert p "abc")
          (pending-stream-insert p "def")
          (pending-stream-insert p "ghi")
          (pending-stream-finish p)
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
          (pending-stream-insert p "hi")
          (should (eq (pending-status p) :streaming))
          (pending-stream-finish p)
          (should (eq (pending-status p) :resolved)))))))

(ert-deftest pending-test/stream-then-finish-replaces ()
  "Calling `pending-finish' mid-stream replaces the streamed content.
The streamed text is dropped; the buffer ends up with the
replacement text from `pending-finish' regardless of how many
chunks had streamed in."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-replace*")
      (with-current-buffer buf
        (insert "Pre:")
        (let ((p (pending-make buf :label "X")))
          (pending-stream-insert p "streamed-content")
          (pending-finish p "FINAL")
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
          (pending-stream-insert p "partial")
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
          (pending-stream-insert p "")
          (should (eq (pending-status p) :scheduled))
          (pending-stream-finish p)
          (should (eq (pending-status p) :resolved)))))))

(ert-deftest pending-test/streamed-text-is-read-only ()
  "Streamed text cannot be edited mid-stream.
Each chunk is propertized `read-only' just like the initial label
so the user gets the standard `text-read-only' rejection."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-readonly*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-stream-insert p "abc")
          (goto-char (1+ (overlay-start (pending-region p))))
          (should-error (let ((inhibit-read-only nil)) (insert "EVIL"))
                        :type 'text-read-only))))))

(ert-deftest pending-test/stream-finish-clears-read-only ()
  "After `pending-stream-finish', the streamed text is freely editable.
The finalize path calls `remove-text-properties' over the whole
streamed region so `read-only', `front-sticky', and `rear-nonsticky'
all come off."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-finish-edit*")
      (with-current-buffer buf
        (let* ((p (pending-make buf :label "X"))
               (start nil) (end nil))
          (pending-stream-insert p "abc")
          (setq start (marker-position (pending-start p))
                end   (marker-position (pending-end p)))
          (pending-stream-finish p)
          (when (and start end)
            (goto-char (1+ start))
            (let ((inhibit-read-only nil))
              (insert "X"))
            (should (string-match-p "aXbc" (buffer-string)))))))))

(ert-deftest pending-test/stream-finish-without-chunks ()
  "Finish-stream on a never-streamed placeholder behaves like resolve.
With no chunks ever streamed the call delegates to
`(pending-finish p \"\")', so the buffer ends up with the
placeholder removed and replaced by the empty string."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-no-stream*")
      (with-current-buffer buf
        (insert "Before:")
        (let ((p (pending-make buf :label "X")))
          (pending-stream-finish p)
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "Before:" (buffer-string)))
          (should-not (string-match-p "X" (buffer-string))))))))

(ert-deftest pending-test/stream-finish-from-on-cancel-respects-guard ()
  "Re-entrant `pending-stream-finish' from `on-cancel' must lose the race.
A buggy `on-cancel' callback that calls `pending-stream-finish'
mid-cancel is now routed through the single mutation path with the
in-resolve guard set, so the original `:cancelled' transition wins
and the second call is suppressed.  The on-resolve callback fires
exactly once (through the cancel path's normal terminal transition,
not the buggy stream-finish), and the cancel reason is preserved.

Pre-fix: the buggy `pending-stream-finish' bypassed the guard,
flipped status to `:resolved', clobbered the reason, and fired
on-resolve directly — leaving the eventual `:cancelled' transition
to be silently dropped because the placeholder was already terminal."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-cancel-loop*")
      (with-current-buffer buf
        (let* ((on-resolve-count 0)
               (status-at-on-resolve nil)
               (stream-finish-result :unset)
               (p (pending-make
                   buf
                   :label "X"
                   :on-resolve
                   (lambda (pp)
                     (cl-incf on-resolve-count)
                     (setq status-at-on-resolve (pending-status pp)))
                   :on-cancel
                   (lambda (pp)
                     ;; Buggy callback — must be a no-op rather than
                     ;; flipping `:cancelled' into `:resolved'.
                     (setq stream-finish-result
                           (pending-stream-finish pp))))))
          (pending-stream-insert p "abc")
          (should (eq (pending-status p) :streaming))
          (pending-cancel p :test-reason)
          ;; Original cancel transition wins.
          (should (eq (pending-status p) :cancelled))
          (should (eq (pending-reason p) :test-reason))
          ;; Re-entrant stream-finish was suppressed (returned nil).
          (should (null stream-finish-result))
          ;; on-resolve fired exactly once, observing :cancelled.
          (should (= on-resolve-count 1))
          (should (eq status-at-on-resolve :cancelled)))))))


;;; Process integration

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
The wrapper sentinel reads the live `process-status' (`exit' with
non-zero exit code in this case) and rejects with a
`\"process: ...\"' string built from the exit code, not from the
localized event string."
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
If the caller calls `pending-finish' BEFORE the process exits,
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
          (pending-finish p "manual-resolve")
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

(ert-deftest pending-test/process-reattach-no-wrapper-leak ()
  "Re-attaching the same process does not pile up wrapper closures.
Each `pending-attach-process' on a process whose sentinel is
already our wrapper peels one layer (recorded under
`pending--wrapped-original' on the process object) before
installing a new one.  After two attaches the captured original is
still the user's sentinel, not the previous wrapper, and the
process's outermost sentinel matches the recorded
`pending--wrapped-by' marker.  Without the unwrap each attach
would chain through the previous wrapper and balloon to O(K)
closures."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-proc-reattach*")
      (with-current-buffer buf
        (let* ((warning-minimum-log-level :error)
               (user-sentinel-calls 0)
               (user-sentinel
                (lambda (_proc _event) (cl-incf user-sentinel-calls)))
               (p1 (pending-make buf :label "A"))
               (proc (start-process "p-test-reattach" nil "true")))
          (set-process-sentinel proc user-sentinel)
          (pending-attach-process p1 proc)
          ;; First attach: wrapper installed, original is user-sentinel.
          (let ((s1 (process-sentinel proc)))
            (should (eq s1 (process-get proc 'pending--wrapped-by)))
            (should (eq (process-get proc 'pending--wrapped-original)
                        user-sentinel))
            ;; Re-attach with a fresh placeholder; original captured
            ;; by the new wrapper must still be user-sentinel, not s1.
            (let ((p2 (pending-make buf :label "B")))
              (pending-attach-process p2 proc)
              (let ((s2 (process-sentinel proc)))
                (should (eq s2 (process-get proc 'pending--wrapped-by)))
                (should-not (eq s2 s1))
                (should (eq (process-get proc 'pending--wrapped-original)
                            user-sentinel)))))
          ;; Cleanup: let the process exit so the wrapper fires once.
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          ;; Give the sentinel a brief moment to fire.
          (let ((deadline (+ (float-time) 1.0)))
            (while (and (zerop user-sentinel-calls)
                        (< (float-time) deadline))
              (sit-for 0.05)))
          ;; The user's sentinel should have fired exactly once,
          ;; not once per attach (which would be 2).
          (should (= user-sentinel-calls 1)))))))


;;; Buffer-dead defense in depth

(ert-deftest pending-test/stream-finish-buffer-dead-still-resolves ()
  "Killing the buffer mid-stream and then calling `pending-stream-finish'
must still flip status (status will be :cancelled because
kill-buffer-hook fires first; stream-finish sees the terminal
state and bails).  Documents that the buffer-kill hook handles
the dead-buffer case before `pending-stream-finish' ever sees
it.  The defense-in-depth code in `pending-stream-finish' is
still valuable for correctness but is essentially unreachable in
normal use."
  (pending-test--with-fresh-registry
    (let* ((buf (generate-new-buffer "*p-stream-finish-dead*"))
           (callback-ran nil)
           (p (with-current-buffer buf
                (pending-make buf :label "X"
                              :on-resolve (lambda (_) (setq callback-ran t))))))
      (with-current-buffer buf (pending-stream-insert p "abc"))
      (kill-buffer buf)
      ;; By now, kill-buffer-hook should have run, cancelling the placeholder.
      ;; Status: :cancelled. Reason: :buffer-killed. The on-resolve callback
      ;; was fired by pending-cancel.
      (should (memq (pending-status p) '(:cancelled :resolved)))
      (should callback-ran)
      ;; Calling stream-finish now is a no-op (placeholder is terminal).
      (pending-stream-finish p))))



;;; Interactive UI

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
          (goto-char (1+ (overlay-start (pending-region p))))
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


;;; Kill-emacs-query and demo

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


;;; Simple positional API

(ert-deftest pending-test/region-creates-token ()
  "`pending-region' returns a usable token with start/end markers."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-overlay*")
      (with-current-buffer buf
        (insert "Before-MID-After")
        (let* ((beg (+ (point-min) 7))
               (end (+ (point-min) 10))
               (token (pending-region beg end "rewriting")))
          (should (pending-p token))
          (should (eq (pending-buffer token) buf))
          (should (= (marker-position (pending-start token)) beg))
          (should (= (marker-position (pending-end token)) end))
          (should (eq (pending-indicator token) :lighter))
          (let ((bs (overlay-get (pending-region token) 'before-string)))
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
          (let ((bs (overlay-get (pending-region token) 'before-string)))
            (should (string-match-p "calling LLM" bs))))))))

(ert-deftest pending-test/finish-replaces-region ()
  "`pending-finish' on an overlay TOKEN replaces [BEG, END] with STR."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-region*")
      (with-current-buffer buf
        (insert "Before-OLD-After")
        (let* ((beg (+ (point-min) 7))
               (end (+ (point-min) 10))
               (token (pending-region beg end "...")))
          (pending-finish token "NEW")
          (should (eq (pending-status token) :resolved))
          (should (string-match-p "Before-NEW-After" (buffer-string))))))))

(ert-deftest pending-test/finish-inserts-at-pos ()
  "`pending-finish' on an insert TOKEN (BEG=END) inserts STR at POS."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-pos*")
      (with-current-buffer buf
        (insert "Hello world")
        (goto-char (1+ (point-min)))  ; between H and ello
        (let ((token (pending-insert (point) "...")))
          (pending-finish token "NEW")
          (should (eq (pending-status token) :resolved))
          (should (string-match-p "HNEWello world" (buffer-string))))))))

(ert-deftest pending-test/resolve-preserves-point ()
  "`pending-finish' does not move point in the placeholder's buffer.
When the user's cursor sits outside the placeholder, resolution must
not jump it to the end of the inserted text — it should track the
same logical character it was on, shifted only by the natural
delete-then-insert of the swap."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-keeps-point*")
      (with-current-buffer buf
        (insert "ABCDEF")
        ;; Adopt the middle two chars 'CD' as a placeholder, then move
        ;; point AFTER the placeholder (between E and F).  Resolving
        ;; with longer text 'XYZ' must leave point logically between
        ;; E and F in the resulting "ABXYZEF".
        (let* ((beg (+ (point-min) 2))   ; before C
               (end (+ (point-min) 4))   ; before E
               (token (pending-region beg end "CD")))
          (goto-char (+ (point-min) 5))  ; between E and F
          (pending-finish token "XYZ")
          (should (eq (pending-status token) :resolved))
          (should (string= (buffer-string) "ABXYZEF"))
          ;; "ABXYZEF": A=1 B=2 X=3 Y=4 Z=5 E=6 F=7 — between E and F
          ;; is position 7.
          (should (= (point) (+ (point-min) 6))))))))

(ert-deftest pending-test/resolve-preserves-window-and-buffer ()
  "Resolution does not change the selected window or selected buffer.
The library has no business stealing focus when an async result lands."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolve-keeps-window*")
      (pending-test--with-buffer (other "*p-resolve-other*")
        (with-current-buffer buf
          (insert "Before-OLD-After")
          (let* ((beg (+ (point-min) 7))
                 (end (+ (point-min) 10))
                 (token (pending-region beg end "OLD")))
            ;; Switch to a different buffer; the resolve should not
            ;; pull us back to BUF.
            (set-buffer other)
            (let ((win-before (selected-window)))
              (pending-finish token "NEW")
              (should (eq (current-buffer) other))
              (should (eq (selected-window) win-before)))))))))

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
          (let ((bs (overlay-get (pending-region token) 'before-string)))
            (should (string-match-p "static" bs))))))))


;;; Face policy: never face inserted text

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

(ert-deftest pending-test/region-has-overlay-face ()
  "`pending-region' adopt mode (non-empty region): overlay HAS a face,
but the underlying buffer text does NOT carry a face text property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-overlay-face*")
      (with-current-buffer buf
        (insert "Before-MID-After")
        (let* ((tok (pending-region 8 11 "rewriting"))
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
  "After `pending-finish', the inserted resolution text has no `face' property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-resolved-no-face*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-finish p "DONE")
          (should-not (get-text-property (point-min) 'face)))))))

(ert-deftest pending-test/streamed-text-has-no-face ()
  "Streamed chunks land in the buffer without a `face' property."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-stream-no-face*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (pending-stream-insert p "abc")
          (let ((pos (1+ (overlay-start (pending-ov p)))))
            (should-not (get-text-property pos 'face))))))))


;;; v0.2 — auto-refresh of *Pending* list

(defun pending-test--drain-list-refresh ()
  "Drain a queued debounced `*Pending*' list refresh, if any.
The auto-refresh helper schedules an idle timer; ERT batch mode
does not go idle on its own, so we run the queued refresh
synchronously via `pending--list-refresh-flush' to mirror the
effect of an idle moment passing in interactive use."
  (pending--list-refresh-flush))

(ert-deftest pending-test/list-auto-refreshes-on-register ()
  "Creating a placeholder while *Pending* is open updates the list.
With `pending-list-auto-refresh' on (the default), `pending-make'
firing through `pending--register' schedules a debounced refresh of
the live `*Pending*' buffer so newly registered placeholders appear
without the user pressing `g'.

The refresh is async (idle-timer based) so the test must wait for
the queued refresh to fire before checking row count."
  (pending-test--with-fresh-registry
    (unwind-protect
        (progn
          (pending-list)
          (pending-test--with-buffer (buf "*p-auto-1*")
            (with-current-buffer buf
              (pending-make buf :label "A")
              (insert " ")
              (pending-make buf :label "B"))
            (pending-test--drain-list-refresh)
            (with-current-buffer "*Pending*"
              (should (= 2 (length tabulated-list-entries))))))
      (when (get-buffer "*Pending*") (kill-buffer "*Pending*")))))

(ert-deftest pending-test/list-auto-refreshes-on-resolve ()
  "Resolving a placeholder while *Pending* is open updates the list.
The terminal transition path goes through `pending--resolve-internal'
which calls `pending--unregister' which schedules a debounced refresh
so a resolved row drops out of the view shortly after.  The refresh
is async (idle-timer based); we drain the queue between mutations."
  (pending-test--with-fresh-registry
    (unwind-protect
        (pending-test--with-buffer (buf "*p-auto-2*")
          (with-current-buffer buf
            (let ((p1 (pending-make buf :label "A")))
              (insert " ")
              (let ((p2 (pending-make buf :label "B")))
                (pending-list)
                (pending-test--drain-list-refresh)
                (with-current-buffer "*Pending*"
                  (should (= 2 (length tabulated-list-entries))))
                (pending-finish p1 "done")
                (pending-test--drain-list-refresh)
                (with-current-buffer "*Pending*"
                  (should (= 1 (length tabulated-list-entries))))
                ;; Cleanup
                (pending-finish p2 "done")))))
      (when (get-buffer "*Pending*") (kill-buffer "*Pending*")))))

(ert-deftest pending-test/list-auto-refresh-disabled ()
  "Setting `pending-list-auto-refresh' nil suppresses auto-refresh.
Without auto-refresh, the *Pending* buffer is the snapshot taken
at `pending-list' time and stays stale until a manual `g'."
  (pending-test--with-fresh-registry
    (unwind-protect
        (let ((pending-list-auto-refresh nil))
          (pending-list)
          (pending-test--with-buffer (buf "*p-auto-3*")
            (with-current-buffer buf
              (pending-make buf :label "A"))
            (with-current-buffer "*Pending*"
              (should (= 0 (length tabulated-list-entries))))))
      (when (get-buffer "*Pending*") (kill-buffer "*Pending*")))))


;;; v0.2 — pulse-on-resolve

(ert-deftest pending-test/pulse-on-resolve-fires ()
  "`pending-finish' invokes `pulse-momentary-highlight-region' on the resolved range.
The pulse covers the buffer span [start, start+len(text)] so the
flash hits exactly the inserted text."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-1*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve t))
          ;; Force the visible-window gate open so `pending--maybe-pulse'
          ;; fires under batch.
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls)))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending-finish p "DONE")))
          (should (= 1 (length calls)))
          (let ((range (car calls)))
            (should (= 1 (car range)))
            (should (= 5 (cdr range)))))))))

(ert-deftest pending-test/pulse-not-on-cancel ()
  "Cancel does not pulse — pulses signal successful completion only."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-2*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve t))
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls)))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending-cancel p)))
          (should (= 0 (length calls))))))))

(ert-deftest pending-test/pulse-not-on-reject ()
  "Reject does not pulse — pulses signal successful completion only."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-reject*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve t))
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls)))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending-reject p "boom")))
          (should (= 0 (length calls))))))))

(ert-deftest pending-test/pulse-disabled-by-defcustom ()
  "`pending-pulse-on-resolve' nil disables pulsing."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-3*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve nil))
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls)))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending-finish p "DONE")))
          (should (= 0 (length calls))))))))

(ert-deftest pending-test/pulse-on-stream-finish ()
  "`pending-stream-finish' pulses the streamed region on `:resolved'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-stream*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve t))
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls)))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending-stream-insert p "hello")
              (pending-stream-finish p)))
          (should (= 1 (length calls)))
          (let ((range (car calls)))
            (should (= 1 (car range)))
            (should (= 6 (cdr range)))))))))

(ert-deftest pending-test/pulse-skipped-when-buffer-not-visible ()
  "No pulse when BUFFER has no window — flash on hidden buffer is waste."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-pulse-hidden*")
      (with-current-buffer buf
        (let* ((calls nil)
               (pending-pulse-on-resolve t))
          ;; Default: no window for `buf'.  Stub leaves the gate
          ;; closed.
          (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                     (lambda (s e &rest _) (push (cons s e) calls))))
            (let ((p (pending-make buf :label "X")))
              (pending-finish p "DONE")))
          (should (= 0 (length calls))))))))


;;; v0.2 — fringe bitmap indicator

(ert-deftest pending-test/fringe-bitmap-stashed-when-set ()
  "When `pending-fringe-bitmap' is set, overlay records a fringe display.
The fringe string is stashed under `pending--fringe-string' on the
overlay so `pending--render' can prepend it to whatever spinner /
lighter glyph the indicator wants in `before-string'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-fringe*")
      (with-current-buffer buf
        (let ((pending-fringe-bitmap 'right-arrow))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
            (let* ((p (pending-make buf :label "X"))
                   (stashed (overlay-get (pending-ov p) 'pending--fringe-string)))
              (should stashed)
              (let ((display (get-text-property 0 'display stashed)))
                (should display)
                (should (eq (car display) 'left-fringe))
                (should (eq (cadr display) 'right-arrow))))))))))

(ert-deftest pending-test/fringe-bitmap-skipped-in-tty ()
  "When `display-graphic-p' is nil, no fringe stash is recorded."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-fringe-tty*")
      (with-current-buffer buf
        (let ((pending-fringe-bitmap 'right-arrow))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil)))
            (let* ((p (pending-make buf :label "X"))
                   (stashed (overlay-get (pending-ov p) 'pending--fringe-string)))
              (should-not stashed))))))))

(ert-deftest pending-test/fringe-bitmap-disabled-by-default ()
  "When `pending-fringe-bitmap' is nil (default), no stash is recorded."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-fringe-off*")
      (with-current-buffer buf
        (let ((pending-fringe-bitmap nil))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
            (let* ((p (pending-make buf :label "X"))
                   (stashed (overlay-get (pending-ov p) 'pending--fringe-string)))
              (should-not stashed))))))))

(ert-deftest pending-test/fringe-bitmap-prepended-in-render ()
  "`pending--render' prepends the stashed fringe string to the spinner glyph.
With a fringe-bitmap set and the visibility gate forced open in
batch, a spinner-mode placeholder's `before-string' starts with
the fringe display proxy and is followed by the spinner glyph."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-fringe-render*")
      (with-current-buffer buf
        (let ((pending-fringe-bitmap 'right-arrow))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) t)))
            (let ((p (pending-make buf :label "X")))
              (pending--tick)
              (let* ((bs (overlay-get (pending-ov p) 'before-string))
                     (display (get-text-property 0 'display bs)))
                (should (stringp bs))
                ;; The leading character carries the fringe-display
                ;; proxy with our bitmap.
                (should display)
                (should (eq (car display) 'left-fringe))
                (should (eq (cadr display) 'right-arrow))
                ;; The spinner-glyph block trails the fringe proxy.
                (should (> (length bs) 1))))))))))

(ert-deftest pending-test/fringe-bitmap-prepended-on-lighter ()
  "Lighter mode also picks up the fringe stash via `pending--render'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-fringe-lighter*")
      (with-current-buffer buf
        (let ((pending-fringe-bitmap 'right-arrow))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
            (let* ((tok (pending-insert (point-min) "static"))
                   (bs (overlay-get (pending-ov tok) 'before-string))
                   (display (get-text-property 0 'display bs)))
              (should (stringp bs))
              (should display)
              (should (eq (car display) 'left-fringe))
              (should (eq (cadr display) 'right-arrow))
              ;; The lighter badge follows the fringe proxy.
              (should (string-match-p "static" bs)))))))))


;;; v0.2 — SVG spinner

(ert-deftest pending-test/svg-spinner-used-when-graphic ()
  "When graphic + SVG available, spinner before-string contains an image.
The image string is a propertized one-character space whose
`display' property is the SVG image returned by `svg-image'."
  (skip-unless (image-type-available-p 'svg))
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-svg-1*")
      (with-current-buffer buf
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                  ((symbol-function 'image-type-available-p)
                   (lambda (sym) (or (eq sym 'svg) t)))
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
          (let* ((p (pending-make buf :label "X"))
                 (pending-svg-spinner-enable t))
            (pending--tick)
            (let ((bs (overlay-get (pending-ov p) 'before-string)))
              (should bs)
              (should (stringp bs))
              ;; The display property carries an image specification.
              (let ((display (get-text-property 0 'display bs)))
                (should (consp display))
                (should (eq (car display) 'image))))))))))

(ert-deftest pending-test/svg-spinner-fallback-to-text ()
  "Without graphic support, spinner before-string is the text glyph.
The Unicode glyph + space form survives — no `image' display
property in the leading character."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-svg-2*")
      (with-current-buffer buf
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
          (let* ((p (pending-make buf :label "X"))
                 (pending-svg-spinner-enable t))
            (pending--tick)
            (let ((bs (overlay-get (pending-ov p) 'before-string)))
              (should bs)
              (should (stringp bs))
              ;; No image — the leading character has no `image' display.
              (let ((display (get-text-property 0 'display bs)))
                (should-not (and (consp display)
                                 (eq (car display) 'image)))))))))))

(ert-deftest pending-test/svg-spinner-disabled-by-defcustom ()
  "`pending-svg-spinner-enable' nil forces text glyph even on graphic.
Stubs simulate a graphical SVG-capable frame, but the defcustom
gate forces the Unicode fallback."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-svg-3*")
      (with-current-buffer buf
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                  ((symbol-function 'image-type-available-p) (lambda (_) t))
                  ((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
          (let* ((p (pending-make buf :label "X"))
                 (pending-svg-spinner-enable nil))
            (pending--tick)
            (let ((bs (overlay-get (pending-ov p) 'before-string)))
              (should bs)
              (should (stringp bs))
              ;; Without SVG enabled, the leading character is the
              ;; spinner glyph, not an image.
              (let ((display (get-text-property 0 'display bs)))
                (should-not (and (consp display)
                                 (eq (car display) 'image)))))))))))

(ert-deftest pending-test/svg-cached-key-distinct-by-frame ()
  "The SVG cache memoizes per (FACE STYLE FRAME-INDEX FRAMES-COUNT SIZE) key.
Two distinct frame indices populate two distinct entries; the
second call to `pending--svg-cached' for an already-cached key
returns the same string by `eq'.  A different FRAMES-COUNT value
on the same FRAME-INDEX is a distinct entry as well — the
rotation angle depends on both."
  (skip-unless (image-type-available-p 'svg))
  (let ((pending--svg-cache (make-hash-table :test 'equal)))
    (let ((s1 (pending--svg-cached 0 8 'dots-1 'pending-spinner-face 16))
          (s2 (pending--svg-cached 1 8 'dots-1 'pending-spinner-face 16))
          (s1b (pending--svg-cached 0 8 'dots-1 'pending-spinner-face 16))
          (s3 (pending--svg-cached 0 6 'dots-1 'pending-spinner-face 16)))
      (should (stringp s1))
      (should (stringp s2))
      (should (stringp s3))
      ;; FRAMES-COUNT in the key prevents collision between
      ;; (frame-index 0, frames-count 8) and (frame-index 0,
      ;; frames-count 6) — they describe different rotations.
      (should (= 3 (hash-table-count pending--svg-cache)))
      ;; Same key returns the same `eq' value (cached, not regenerated).
      (should (eq s1 s1b)))))


;;; v0.2 — mocked-time helpers

(ert-deftest pending-test/mocked-time-eta-fraction ()
  "ETA fraction reaches 0.5 at half the estimated time.
With `float-time' mocked to a known value, `pending--eta-
fraction' returns the deterministic checkpoint without any
wall-clock dependency."
  (pending-test--with-mocked-time
    (setq pending-test--clock 100.0)
    ;; start-time = 100, eta = 8s, now = 104 (4s elapsed = half).
    (should (= 0.5 (pending--eta-fraction 100.0 8.0 104.0)))))

(ert-deftest pending-test/mocked-time-spinner-frame ()
  "Spinner frame index advances based on mocked elapsed time.
With `pending-fps' = 10 and 0.5s elapsed, the index lands at
frame 5 modulo the frames-vector length."
  (pending-test--with-mocked-time
    (let* ((p (pending--make-struct :id 'mt
                                    :start-time 100.0
                                    :spinner-style 'dots-1))
           (frames (pending--get-frames 'dots-1)))
      (setq pending-test--clock 100.5)        ; 0.5 s elapsed
      ;; At 10 fps, 0.5s = 5 frames.
      (should (= (mod 5 (length frames))
                 (pending--frame-index p frames))))))

(ert-deftest pending-test/mocked-time-deadline-not-fired-yet ()
  "Advancing under the deadline does NOT fire the rejection timer.
Sanity check on the mocked-time fixture: a 0.1s advance against a
1.0s deadline must leave the placeholder active."
  (pending-test--with-fresh-registry
    (pending-test--with-mocked-time
      (pending-test--with-buffer (buf "*p-mt-deadline-pending*")
        (with-current-buffer buf
          (let ((p (pending-make buf :label "X" :deadline 1.0)))
            (pending-test--advance 0.1)
            (should (eq (pending-status p) :scheduled))
            ;; Advance the rest of the way to fire the deadline timer.
            (pending-test--advance 1.0)
            (should (eq (pending-status p) :rejected))
            (should (eq (pending-reason p) :timed-out))))))))


;;; v0.2 — adopted-region read-only projection

(ert-deftest pending-test/adopted-region-protected-from-edits ()
  "By default, an adopted region is read-only while the placeholder is active.
With `pending-protect-adopted-region' on (the default), text
properties applied by `pending-make' adopt mode block edits to
the adopted text via the standard `text-read-only' error.  The
library's own resolve binds `inhibit-read-only' so the swap
proceeds normally."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-adopt-protect*")
      (with-current-buffer buf
        (insert "Pre-MID-Post")
        ;; Bytes 1..4 = "Pre-", 5..7 = "MID", 8..12 = "-Post".
        (let ((p (pending-region 5 8 "rewriting")))
          (goto-char 6)              ; inside MID
          (should-error (let ((inhibit-read-only nil))
                          (insert "X"))
                        :type 'text-read-only)
          (pending-finish p "DONE")
          (should (eq (pending-status p) :resolved))
          (should (string-match-p "Pre-DONE-Post" (buffer-string))))))))

(ert-deftest pending-test/adopted-region-not-protected-when-disabled ()
  "Setting `pending-protect-adopted-region' nil leaves adopted text editable.
This restores the v0.1.0 behaviour where the overlay's
modification-hooks were the sole edit-detection mechanism."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-adopt-no-protect*")
      (with-current-buffer buf
        (insert "Pre-MID-Post")
        (let ((pending-protect-adopted-region nil))
          (let ((p (pending-region 5 8 "rewriting")))
            ;; The text in the adopted region should NOT carry the
            ;; read-only property when protection is disabled.
            (should-not (get-text-property 6 'read-only))
            (pending-cancel p :test-cleanup)
            (should (eq (pending-status p) :cancelled))))))))

(ert-deftest pending-test/protection-projects-into-indirect-buffer ()
  "Read-only properties on an adopted region are inherited by indirect buffers.
Overlays do not project into indirect buffers, but text
properties live in the buffer text itself and DO project.  This
test creates an adopted-region placeholder, makes an indirect
buffer of the host, and confirms the indirect view rejects an
edit inside the placeholder's range with `text-read-only'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (base "*p-projection-base*")
      (with-current-buffer base
        (insert "AAA-XXX-BBB")
        (let ((p (pending-region 5 8 "work")))
          (let ((indirect (make-indirect-buffer
                           base "*p-projection-indirect*" t)))
            (unwind-protect
                (with-current-buffer indirect
                  (goto-char 6)        ; inside XXX
                  (should-error (let ((inhibit-read-only nil))
                                  (insert "Y"))
                                :type 'text-read-only))
              (when (buffer-live-p indirect) (kill-buffer indirect))))
          ;; Cleanup so the registry empties before the host buffer dies.
          (pending-cancel p :test-cleanup))))))

(ert-deftest pending-test/adopted-region-read-only-cleared-on-resolve ()
  "After resolve, the resolved text is editable.
The adopted text is deleted by `pending--swap-region', so the
read-only properties disappear with it; the inserted replacement
text is plain (no properties), so editing post-resolve works."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-adopt-cleared*")
      (with-current-buffer buf
        (insert "Pre-MID-Post")
        (let ((p (pending-region 5 8 "work")))
          (pending-finish p "NEW")
          (should (eq (pending-status p) :resolved))
          ;; The replaced text contains "NEW"; inserting anywhere in it
          ;; should now succeed without raising `text-read-only'.
          (goto-char 6)
          (insert "Y")
          (should (string-match-p "NYEW" (buffer-string))))))))


;;; v0.2 — describe buffer

(ert-deftest pending-test/describe-buffer-created ()
  "`pending-describe' creates a *Pending: ID* buffer in the right mode.
The buffer's major mode is `pending-description-mode' and the
rendered text contains the placeholder's label."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-1*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "WORK")))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (should (get-buffer desc-buf))
                  (with-current-buffer desc-buf
                    (should (eq major-mode 'pending-description-mode))
                    (should (string-match-p "WORK" (buffer-string)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-shows-status ()
  "Description buffer reflects the placeholder's status keyword."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-2*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (with-current-buffer desc-buf
                    ;; `pending-make' starts in `:scheduled', and the
                    ;; placeholder may transition to `:running' later;
                    ;; either is acceptable here.
                    (should (string-match-p
                             ":\\(scheduled\\|running\\)"
                             (buffer-string)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-refresh-after-resolve ()
  "Refreshing the description after resolve shows the new status.
Calling `pending-describe-refresh' re-renders from the live token
slots so a placeholder that flipped to `:resolved' since the
buffer was first opened shows up correctly."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-3*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (pending-finish p "DONE")
                  (with-current-buffer desc-buf
                    (pending-describe-refresh)
                    (should (string-match-p ":resolved"
                                            (buffer-string)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-cancel-from-buffer ()
  "`pending-describe-cancel' cancels the placeholder and refreshes."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-cancel*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X")))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (with-current-buffer desc-buf
                    (pending-describe-cancel))
                  (should (eq (pending-status p) :cancelled))
                  (should (eq (pending-reason p)
                              :cancelled-from-describe))
                  (with-current-buffer desc-buf
                    (should (string-match-p ":cancelled"
                                            (buffer-string)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/list-describe-opens-buffer ()
  "`pending-list-describe' opens the description buffer for the row.
The list buffer's `?' binding routes through this command, which
reads the row's struct via `tabulated-list-get-id' and delegates
to `pending-describe'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-list-describe*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "TARGET")))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-list)
                  (with-current-buffer "*Pending*"
                    (goto-char (point-min))
                    (let (found)
                      (while (and (not found) (not (eobp)))
                        (when (eq (tabulated-list-get-id) p)
                          (setq found t))
                        (unless found (forward-line 1)))
                      (should found)
                      (pending-list-describe)))
                  (should (get-buffer desc-buf))
                  (with-current-buffer desc-buf
                    (should (eq major-mode 'pending-description-mode))
                    (should (string-match-p "TARGET" (buffer-string)))))
              (when (get-buffer "*Pending*") (kill-buffer "*Pending*"))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-renders-callback-flags ()
  "Description buffer shows yes/no for on-cancel and on-resolve.
With no callbacks set, both report `no'.  With either set, the
corresponding row reports `yes'."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-cb*")
      (with-current-buffer buf
        (let ((p (pending-make buf :label "X"
                               :on-cancel (lambda (_) nil)
                               :on-resolve (lambda (_) nil))))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (with-current-buffer desc-buf
                    (should (string-match-p "on-cancel:[[:space:]]+yes"
                                            (buffer-string)))
                    (should (string-match-p "on-resolve:[[:space:]]+yes"
                                            (buffer-string)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-renders-all-optional-fields ()
  "Description buffer renders group, eta, percent, deadline, reason.
A fully-populated placeholder exercises every conditional branch
in `pending--describe-render', so all optional rows appear in the
output."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-full*")
      (with-current-buffer buf
        (let ((p (pending-make buf
                               :label "Calling"
                               :indicator :percent
                               :percent 0.4
                               :eta 5.0
                               :group 'g1
                               :spinner-style 'arc)))
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (with-current-buffer desc-buf
                    (let ((s (buffer-string)))
                      ;; All optional rows we set must appear.
                      (should (string-match-p "Group:[[:space:]]+g1" s))
                      (should (string-match-p "Indicator:[[:space:]]+:percent" s))
                      (should (string-match-p "Spinner:[[:space:]]+arc" s))
                      (should (string-match-p "ETA:[[:space:]]+5\\." s))
                      (should (string-match-p "Percent:[[:space:]]+40%" s))
                      (should (string-match-p "Started:" s))
                      (should (string-match-p "Elapsed:" s)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-renders-deadline-and-reason ()
  "Description buffer renders the deadline row and reason after reject.
Combines two conditional branches (`pending-deadline' and
`pending-reason') in one render."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-deadline*")
      (with-current-buffer buf
        (let ((warning-minimum-log-level :error)
              (p (pending-make buf :label "X" :deadline 60.0)))
          (pending-reject p "boom")
          (let ((desc-buf (format "*Pending: %s*"
                                  (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (with-current-buffer desc-buf
                    (let ((s (buffer-string)))
                      (should (string-match-p "Deadline:[[:space:]]+60\\." s))
                      (should (string-match-p "Reason:[[:space:]]+boom" s))
                      (should (string-match-p "Resolved:" s))
                      (should (string-match-p ":rejected" s)))))
              (when (get-buffer desc-buf) (kill-buffer desc-buf)))))))))

(ert-deftest pending-test/describe-jump-from-buffer ()
  "`pending-describe-jump' delegates to `pending-goto'.
The token's start position becomes point in the placeholder's
buffer.  We call `pending-describe-jump' from inside the
description buffer using `set-buffer' (not `with-current-buffer')
so the buffer change made by `pending-goto' / `pop-to-buffer'
remains visible afterwards rather than being unwound."
  (pending-test--with-fresh-registry
    (pending-test--with-buffer (buf "*p-describe-jump*")
      (with-current-buffer buf
        (insert "Some content here xyz")
        (let* ((target-pos (+ (point-min) 5))
               (p (pending-insert target-pos "...")))
          (let ((desc-buf-name (format "*Pending: %s*"
                                       (symbol-name (pending-id p)))))
            (unwind-protect
                (progn
                  (pending-describe p)
                  (let ((desc-buf (get-buffer desc-buf-name)))
                    (should desc-buf)
                    (set-buffer desc-buf)
                    (pending-describe-jump))
                  (should (eq (current-buffer) buf))
                  (should (= (point) target-pos)))
              (when (get-buffer desc-buf-name)
                (kill-buffer desc-buf-name)))))))))


(provide 'pending-test)

;;; pending-test.el ends here
