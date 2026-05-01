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

- [x] Create `pending.el` with package header (Author, Version,
      Package-Requires, URL, Keywords, lexical-binding cookie).
- [x] Create `pending-test.el` with `(require 'ert)` and a single
      smoke test that just `(should (featurep 'pending))`.
- [x] Create `Eask` file:
      ```elisp
      (package "pending" "0.1.0" "Async pending content placeholders")
      (author "John Wiegley" "jwiegley@gmail.com")
      (license "GPL-3.0")
      (package-file "pending.el")
      (script "test" "eask test ert pending-test.el")
      (depends-on "emacs" "27.1")
      ```
- [x] Create `Makefile` with `compile`, `test`, `clean` targets
      mimicking `use-package/Makefile` shape.
- [x] Create `LICENSE` (GPL-3.0).
- [x] Create `README.md` (already drafted in this directory; expand).

**Exit**: `eask install-deps && eask compile && eask run test` runs
clean.

---

## Phase 1 — Skeleton: types and configuration

**Goal**: the file loads; no behavior yet, but every public symbol
has its declaration. This is a long phase but each item is
mechanical.

- [x] `(defgroup pending nil ...)` rooted under `'tools`.
- [x] `defcustom`s:
      - [x] `pending-fps` (default 10)
      - [x] `pending-bar-width` (default 16)
      - [x] `pending-default-spinner-style` (default `'dots-1`)
      - [x] `pending-spinner-styles` (alist of style-symbol →
            frame-vector)
      - [x] `pending-bar-style` (`'eighths` or `'ascii`)
      - [x] `pending-bar-family` (default nil)
      - [x] ~~`pending-fringe-bitmap` (default nil)~~ — *removed for
            v0.1; deferred to v0.2 (see Deferred section below).*
      - [x] `pending-allow-read-only` (default nil)
      - [x] `pending-label-max-width` (default 60)
      - [x] `pending-confirm-on-emacs-exit` (default nil)
- [x] `defface`s: `pending-face`, `pending-spinner-face`,
      `pending-progress-face`, `pending-error-face`,
      `pending-cancelled-face`.
- [x] `(define-error 'pending-error "Pending placeholder error")`.
- [x] `cl-defstruct pending` with all slots from DESIGN.md §2.
- [x] `pending--next-id`, `pending--gen-id`.
- [x] `pending--registry` hash-table.
- [x] `defvar-local pending--buffer-registry`.
- [x] `(provide 'pending)`.

**Exit**: byte-compile zero warnings; `(require 'pending)` succeeds;
`(pending--make-struct ...)` returns a `pending-p` value.

**Mimic**: gptel's `defcustom`/`defface` style at
`gptel/gptel.el:1088 ff`.

---

## Phase 2 — Core lifecycle (no animation yet)

**Goal**: `pending-make` inserts a static placeholder; `resolve`,
`reject`, `cancel` finish it; registries stay in sync.

- [x] `pending--register` and `pending--unregister` (must update
      both registries atomically).
- [x] `pending--swap-region` (atomic delete + insert).
- [x] `pending-make` — insert mode and adopt mode.
- [x] `pending-finish`.
- [x] `pending-reject`.
- [x] `pending-cancel` — calls `on-cancel` callback first.
- [x] Single-resolution invariant: early return on terminal status.
- [x] `pending-update` (slot mutation only).
- [x] `pending-active-p`, `pending-status`, `pending-at`,
      `pending-list-active`.
- [x] `kill-buffer-hook` cancellation entry point.
- [x] ERT tests for state transitions and registry sync.

**Exit**: state-transition tests pass.

**Mimic**: gptel marker discipline at `gptel/gptel.el:1389,
1769-1794`. agent-shell-heartbeat lifecycle at
`agent-shell/agent-shell-heartbeat.el:78-92`.

---

## Phase 3 — Spinner animation

**Goal**: a placeholder animates a Unicode spinner at 10 fps.

- [x] `pending--spinner-frames-text` defconst with several styles.
- [x] `pending--global-timer`, `pending--ensure-timer`.
- [x] `pending--tick` walking the registry, dirty-tracking.
- [x] `pending--render` — sets `before-string` on the overlay.
- [x] `pending--needs-redraw-p` — visibility gate.
- [x] `window-buffer-change-functions` hook to wake parked timer.
- [x] Frame index from elapsed wall-time (so frame stays in sync
      across timer parks/resumes).

**Exit**: a manual `pending-make` shows an animated spinner; timer
parks when buffer is hidden; resumes when shown.

**Mimic**: agent-shell-active-message cadence at
`agent-shell/agent-shell-active-message.el:38`.

---

## Phase 4 — Determinate + ETA bars

**Goal**: `:percent` and `:eta` indicators render correctly.

- [x] `pending--bar-blocks` defconst (eighth-block characters).
- [x] ASCII fallback bar.
- [x] `pending--render-bar` returns a propertized string.
- [x] `pending--eta-fraction` implementing the piecewise-asymptotic
      formula from DESIGN.md §4.
- [x] Render dispatch on `(pending-indicator p)` — spinner /
      percent / eta.
- [x] ERT tests for ETA monotonicity and the 95% asymptote.

**Exit**: an `:eta 8` placeholder visually fills smoothly to ~95%
in 8 seconds.

---

## Phase 5 — Edit-survival

**Goal**: read-only enforcement; region-deletion auto-cancel.

- [x] Read-only properties on inserted text (`add-text-properties`
      with `read-only t front-sticky (read-only) rear-nonsticky
      (read-only)`).
- [x] Overlay `modification-hooks`, `insert-in-front-hooks`,
      `insert-behind-hooks` calling `pending--on-modify`.
- [x] `pending--on-modify` cancels with `:region-deleted` when the
      overlay collapses to zero length.
- [x] `inhibit-read-only` bound during `pending--swap-region` and
      `pending-stream-insert`.
- [x] ERT marker-survival and read-only tests.

**Exit**: marker-survival tests pass; the user can edit before/after
the placeholder freely but cannot edit it.

**Mimic**: gptel `inhibit-read-only` idiom at
`gptel/gptel.el:1349, 544, 586`.

---

## Phase 6 — Streaming

**Goal**: `pending-stream-insert` and `pending-stream-finish`.

- [x] `pending-stream-insert` inserts at end marker (which has
      insertion-type t while streaming), transitions to
      `:streaming` on first chunk.
- [x] Streamed text gets the same read-only properties as the
      initial label.
- [x] `pending-stream-finish` flips end marker insertion-type to
      nil, removes overlay decorations, transitions to
      `:resolved`.
- [x] ERT tests for streaming append correctness, mid-stream
      cancel, stream-then-resolve replacement.

**Exit**: gptel integration sketch from DESIGN.md §7 works against
a real `gptel-request`.

**Mimic**: gptel marker insertion-type flips at `gptel/gptel.el:1389,
1794`.

---

## Phase 7 — Process and timeout integration

**Goal**: `pending-attach-process` and deadline timers.

- [x] `pending-attach-process` — wraps the process sentinel.
- [x] `pending--process-sentinel` rejects on non-clean exit.
- [x] `pending--start-deadline-timer`.
- [x] Deadline cleanup in `pending--unregister`.
- [x] Convenience: `pending-make :deadline N` schedules
      auto-rejection.

**Exit**: `:deadline 1` rejects with `:timed-out`; shell-pending
sketch from DESIGN.md §7 works end-to-end.

---

## Phase 8 — Interactive UI + lighter

**Goal**: `pending-list`, `pending-cancel-at-point`, mode-line
lighter.

- [x] `pending-list` using `tabulated-list-mode`. Columns: ID,
      Buffer, Label, Status, Elapsed, ETA, Group.
- [x] `pending-list-mode` keymap: `g` refresh, `RET` jump, `c`
      cancel, `q` quit.
- [ ] Auto-refresh on registry mutation (or polled at 1 Hz).
      *(Deferred to v0.2 — manual refresh via `g` for v0.1.)*
- [x] `pending-cancel-at-point` using `pending-at`.
- [x] `pending-region-map` binding `RET` and `[mouse-1]` to
      `pending-cancel-at-point`.
- [x] `pending-mode-line-string` returning a glyph + count + nearest
      ETA.
- [x] `global-pending-lighter-mode` minor mode adding the function
      to `global-mode-string`.

**Exit**: `M-x pending-list` opens the list buffer; cancellation from
the list and from point both work; lighter shows summary.

---

## Phase 9 — Tests, demo, README, packaging

**Goal**: ship-ready library.

- [x] ERT test file fleshed out with all groups from DESIGN.md §8.
- [ ] `pending-test--with-mocked-time` macro for fast-forward
      testing.
      *(Deferred to v0.2 — current tests use `sit-for` and direct
      mutation of `pending-start-time` for determinism; a mocked-time
      macro is nice-to-have but not required for v0.1.)*
- [x] `pending-demo` interactive command with several concurrent
      placeholders of varying durations and modes.
- [x] README expanded with API table, integration recipes, comparison
      to `org-pending`, screenshots/asciinema (optional).
- [x] Texinfo manual (`doc/pending.texi`) with full API reference,
      integration recipes, customization tables, and indices; built
      `doc/pending.info` shipped in the package.
- [x] Makefile `docs`/`info`/`html` targets; `Eask` lists docs in
      `(files ...)`; `.gitignore` ignores generated HTML.
- [x] `;;;###autoload` cookies on user-facing commands.
- [ ] Tag `0.1.0` once everything is green.
      *(Tagging happens outside this implementation phase; the user
      tags via git after merging Phase 9.)*
- [x] Verify install via `package-vc-install` from the local repo
      path.

**Exit**: `eask compile` clean; `eask test` all green; README
renders; `M-x pending-demo` looks right on light + dark themes.

---

## Deferred to v0.2

Items intentionally postponed past the v0.1.0 tag:

- Auto-refresh of `*Pending*` list on registry mutation. Today the
  user types `g` to refresh; v0.2 should hook the registry mutation
  path so the list view stays live without manual interaction.
- Pulse-on-resolve flash via `pulse.el` for a brief post-resolution
  visual confirmation, similar to gptel's
  `gptel-post-response-functions` integration.
- `pending-as-promise` adapter for `aio` users — non-blocking; the
  callback shape is the v0.1 commitment.
- SVG spinner for graphical frames (would render with `svg.el`); v0.1
  ships with text-only Unicode spinners.
- Fringe bitmap indicator beside the placeholder for off-screen
  visibility in graphical frames. The `pending-fringe-bitmap`
  defcustom was scaffolded earlier but never wired up; it has been
  removed from v0.1 and will return alongside the SVG spinner work.
- Description buffer in the `*Region Lock*` style of `org-pending`
  for richer diagnostics on a single placeholder.
- ~~Indirect-buffer projection of read-only properties (org-pending's
  `--add-overlay-projection` trick), so a placeholder's edit
  protection survives across indirect-buffer views.~~ *Implemented in
  v0.2: adopt mode applies `read-only` text properties (gated on
  `pending-protect-adopted-region', default t).  Text properties live
  in the buffer text itself and project into indirect buffers, so this
  closes the gap with overlays.*
- ~~`pending-test--with-mocked-time` macro for deterministic fast-
  forward testing (DESIGN.md §8).~~ *Implemented in v0.2.*

---

## Cross-cutting checklist

Apply to every phase:

- [x] All public functions have docstrings.
- [x] `byte-compile-file` warning-free.
- [x] `M-x checkdoc` clean.
- [x] Tests stay green after each phase.
- [x] No `(require 'org)` anywhere.
- [x] No `(require 'cl)` (use `cl-lib`).
- [x] No third-party deps (Emacs core only).

## Stretch / v2

Items intentionally left for after v1 ships:

- SVG spinner. *Implemented in v0.2.*
- `pending-as-promise` adapter for `aio` users. *Implemented in
  v0.2 as the optional `pending-aio` add-on.*
- `*Pending*` description buffer (org-pending-style). *Implemented
  in v0.2 as `pending-describe'.*
- Indirect-buffer projection. *Implemented in v0.2 via
  `pending-protect-adopted-region'.*
- `kill-emacs-query-functions` integration (gated by a defcustom
  with default nil). *Implemented in Phase 9.*
- Pulse-on-resolve flash. *Implemented in v0.2.*
- Group operations (`pending-cancel-group`).
