# Implementation Plan

Phased checklist for the implementation session that follows. Read
`DESIGN.md` first; this file just sequences the work and tracks
exit criteria.

Total estimated size: ~1100 LOC of library + ~300 LOC of tests +
documentation. Target ship time: a focused day.

---

## Phase 0 — Project bootstrap

**Goal**: file layout, build, and CI scaffolding ready before any
real code goes in.

- [ ] Create `pending.el` with package header (Author, Version,
      Package-Requires, URL, Keywords, lexical-binding cookie).
- [ ] Create `pending-test.el` with `(require 'ert)` and a single
      smoke test that just `(should (featurep 'pending))`.
- [ ] Create `Eask` file:
      ```elisp
      (package "pending" "0.1.0" "Async pending content placeholders")
      (author "John Wiegley" "jwiegley@gmail.com")
      (license "GPL-3.0")
      (package-file "pending.el")
      (script "test" "eask test ert pending-test.el")
      (depends-on "emacs" "27.1")
      ```
- [ ] Create `Makefile` with `compile`, `test`, `clean` targets
      mimicking `use-package/Makefile` shape.
- [ ] Create `LICENSE` (GPL-3.0).
- [ ] Create `README.md` (already drafted in this directory; expand).

**Exit**: `eask install-deps && eask compile && eask run test` runs
clean.

---

## Phase 1 — Skeleton: types and configuration

**Goal**: the file loads; no behavior yet, but every public symbol
has its declaration. This is a long phase but each item is
mechanical.

- [ ] `(defgroup pending nil ...)` rooted under `'tools`.
- [ ] `defcustom`s:
      - [ ] `pending-fps` (default 10)
      - [ ] `pending-bar-width` (default 16)
      - [ ] `pending-default-spinner-style` (default `'dots-1`)
      - [ ] `pending-spinner-styles` (alist of style-symbol →
            frame-vector)
      - [ ] `pending-bar-style` (`'eighths` or `'ascii`)
      - [ ] `pending-bar-family` (default nil)
      - [ ] `pending-fringe-bitmap` (default nil)
      - [ ] `pending-allow-read-only` (default nil)
      - [ ] `pending-label-max-width` (default 60)
      - [ ] `pending-confirm-on-emacs-exit` (default nil)
- [ ] `defface`s: `pending-face`, `pending-spinner-face`,
      `pending-progress-face`, `pending-error-face`,
      `pending-cancelled-face`.
- [ ] `(define-error 'pending-error "Pending placeholder error")`.
- [ ] `cl-defstruct pending` with all slots from DESIGN.md §2.
- [ ] `pending--next-id`, `pending--gen-id`.
- [ ] `pending--registry` hash-table.
- [ ] `defvar-local pending--buffer-registry`.
- [ ] `(provide 'pending)`.

**Exit**: byte-compile zero warnings; `(require 'pending)` succeeds;
`(pending--make-struct ...)` returns a `pending-p` value.

**Mimic**: gptel's `defcustom`/`defface` style at
`gptel/gptel.el:1088 ff`.

---

## Phase 2 — Core lifecycle (no animation yet)

**Goal**: `pending-make` inserts a static placeholder; `resolve`,
`reject`, `cancel` finish it; registries stay in sync.

- [ ] `pending--register` and `pending--unregister` (must update
      both registries atomically).
- [ ] `pending--swap-region` (atomic delete + insert).
- [ ] `pending-make` — insert mode and adopt mode.
- [ ] `pending-resolve`.
- [ ] `pending-reject`.
- [ ] `pending-cancel` — calls `on-cancel` callback first.
- [ ] Single-resolution invariant: early return on terminal status.
- [ ] `pending-update` (slot mutation only).
- [ ] `pending-active-p`, `pending-status`, `pending-at`,
      `pending-list-active`.
- [ ] `kill-buffer-hook` cancellation entry point.
- [ ] ERT tests for state transitions and registry sync.

**Exit**: state-transition tests pass.

**Mimic**: gptel marker discipline at `gptel/gptel.el:1389,
1769-1794`. agent-shell-heartbeat lifecycle at
`agent-shell/agent-shell-heartbeat.el:78-92`.

---

## Phase 3 — Spinner animation

**Goal**: a placeholder animates a Unicode spinner at 10 fps.

- [ ] `pending--spinner-frames-text` defconst with several styles.
- [ ] `pending--global-timer`, `pending--ensure-timer`.
- [ ] `pending--tick` walking the registry, dirty-tracking.
- [ ] `pending--render` — sets `before-string` on the overlay.
- [ ] `pending--needs-redraw-p` — visibility gate.
- [ ] `window-buffer-change-functions` hook to wake parked timer.
- [ ] Frame index from elapsed wall-time (so frame stays in sync
      across timer parks/resumes).

**Exit**: a manual `pending-make` shows an animated spinner; timer
parks when buffer is hidden; resumes when shown.

**Mimic**: agent-shell-active-message cadence at
`agent-shell/agent-shell-active-message.el:38`.

---

## Phase 4 — Determinate + ETA bars

**Goal**: `:percent` and `:eta` indicators render correctly.

- [ ] `pending--bar-blocks` defconst (eighth-block characters).
- [ ] ASCII fallback bar.
- [ ] `pending--render-bar` returns a propertized string.
- [ ] `pending--eta-fraction` implementing the piecewise-asymptotic
      formula from DESIGN.md §4.
- [ ] Render dispatch on `(pending-indicator p)` — spinner /
      percent / eta.
- [ ] ERT tests for ETA monotonicity and the 95% asymptote.

**Exit**: an `:eta 8` placeholder visually fills smoothly to ~95%
in 8 seconds.

---

## Phase 5 — Edit-survival

**Goal**: read-only enforcement; region-deletion auto-cancel.

- [ ] Read-only properties on inserted text (`add-text-properties`
      with `read-only t front-sticky (read-only) rear-nonsticky
      (read-only)`).
- [ ] Overlay `modification-hooks`, `insert-in-front-hooks`,
      `insert-behind-hooks` calling `pending--on-modify`.
- [ ] `pending--on-modify` cancels with `:region-deleted` when the
      overlay collapses to zero length.
- [ ] `inhibit-read-only` bound during `pending--swap-region` and
      `pending-resolve-stream`.
- [ ] ERT marker-survival and read-only tests.

**Exit**: marker-survival tests pass; the user can edit before/after
the placeholder freely but cannot edit it.

**Mimic**: gptel `inhibit-read-only` idiom at
`gptel/gptel.el:1349, 544, 586`.

---

## Phase 6 — Streaming

**Goal**: `pending-resolve-stream` and `pending-finish-stream`.

- [ ] `pending-resolve-stream` inserts at end marker (which has
      insertion-type t while streaming), transitions to
      `:streaming` on first chunk.
- [ ] Streamed text gets the same read-only properties as the
      initial label.
- [ ] `pending-finish-stream` flips end marker insertion-type to
      nil, removes overlay decorations, transitions to
      `:resolved`.
- [ ] ERT tests for streaming append correctness, mid-stream
      cancel, stream-then-resolve replacement.

**Exit**: gptel integration sketch from DESIGN.md §7 works against
a real `gptel-request`.

**Mimic**: gptel marker insertion-type flips at `gptel/gptel.el:1389,
1794`.

---

## Phase 7 — Process and timeout integration

**Goal**: `pending-attach-process` and deadline timers.

- [ ] `pending-attach-process` — wraps the process sentinel.
- [ ] `pending--process-sentinel` rejects on non-clean exit.
- [ ] `pending--start-deadline-timer`.
- [ ] Deadline cleanup in `pending--unregister`.
- [ ] Convenience: `pending-make :deadline N` schedules
      auto-rejection.

**Exit**: `:deadline 1` rejects with `:timed-out`; shell-pending
sketch from DESIGN.md §7 works end-to-end.

---

## Phase 8 — Interactive UI + lighter

**Goal**: `pending-list`, `pending-cancel-at-point`, mode-line
lighter.

- [ ] `pending-list` using `tabulated-list-mode`. Columns: ID,
      Buffer, Label, Status, Elapsed, ETA, Group.
- [ ] `pending-list-mode` keymap: `g` refresh, `RET` jump, `c`
      cancel, `q` quit.
- [ ] Auto-refresh on registry mutation (or polled at 1 Hz).
- [ ] `pending-cancel-at-point` using `pending-at`.
- [ ] `pending-overlay-map` binding `RET` and `[mouse-1]` to
      `pending-cancel-at-point`.
- [ ] `pending-mode-line-string` returning a glyph + count + nearest
      ETA.
- [ ] `global-pending-lighter-mode` minor mode adding the function
      to `global-mode-string`.

**Exit**: `M-x pending-list` opens the list buffer; cancellation from
the list and from point both work; lighter shows summary.

---

## Phase 9 — Tests, demo, README, packaging

**Goal**: ship-ready library.

- [ ] ERT test file fleshed out with all groups from DESIGN.md §8.
- [ ] `pending-test--with-mocked-time` macro for fast-forward
      testing.
- [ ] `pending-demo` interactive command with several concurrent
      placeholders of varying durations and modes.
- [ ] README expanded with API table, integration recipes, comparison
      to `org-pending`, screenshots/asciinema (optional).
- [ ] `;;;###autoload` cookies on user-facing commands.
- [ ] Tag `0.1.0` once everything is green.
- [ ] Verify install via `package-vc-install` from the local repo
      path.

**Exit**: `eask compile` clean; `eask test` all green; README
renders; `M-x pending-demo` looks right on light + dark themes.

---

## Cross-cutting checklist

Apply to every phase:

- [ ] All public functions have docstrings.
- [ ] `byte-compile-file` warning-free.
- [ ] `M-x checkdoc` clean.
- [ ] Tests stay green after each phase.
- [ ] No `(require 'org)` anywhere.
- [ ] No `(require 'cl)` (use `cl-lib`).
- [ ] No third-party deps (Emacs core only).

## Stretch / v2

Items intentionally left for after v1 ships:

- SVG spinner.
- `pending-as-promise` adapter for `aio` users.
- `*Pending*` description buffer (org-pending-style).
- Indirect-buffer projection.
- `kill-emacs-query-functions` integration (gated by a defcustom
  with default nil).
- Pulse-on-resolve flash.
- Group operations (`pending-cancel-group`).
