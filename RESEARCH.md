# Research

Source survey for the `pending` library. The DESIGN.md was authored by
an emacs-lisp-pro agent that *speculated* about `org-pending`'s shape
without reading the source. This file records what was actually found.

## 1. `org-pending` — verified facts

### Location

Bruno Barbier maintains the patch on framagit:

- Repository: <https://framagit.org/brubar/org-mode-mirror>
- Branch: `bba-pending-contents` (development branch where
  `lisp/org-pending.el` lives at the time of this writing).
- A second branch `bba-ngnu-pending-contents` exists with later
  iterations.
- Raw file:
  <https://framagit.org/brubar/org-mode-mirror/-/raw/bba-pending-contents/lisp/org-pending.el>
- Mailing-list thread title: "Pending contents in org documents" on
  <https://list.orgmode.org/?q=org-pending> — 87 messages as of the
  search.
- Patch attachments visible at messages such as
  <https://list.orgmode.org/87o78vwnds.fsf@localhost/2-org-pending.diff>
  and
  <https://list.orgmode.org/878qatogtr.fsf@localhost/2-org-pending.diff>.
- The patch targets Org 9.7 per `:package-version` declarations in
  the source.

A local copy was downloaded to `/tmp/org-pending.el` (1736 lines)
during research. It is **not** vendored into this repo.

### Stated independence from Org

The commentary section ends with the explicit line:

> ;; This file does *NOT* depend on Org mode.

`(require)` declarations at the top:

```elisp
(require 'cl-lib)
(require 'string-edit)
(require 'compile)
```

No `(require 'org)`. Karthink's claim is correct — the library can
stand alone. We could in principle just take this file as-is. We
choose not to, for the reasons enumerated in DESIGN.md §1: API
shape preferences, no animation, no progress bar visualization, and
the `org-` prefix is a discoverability problem for non-Org users.

### Public API (verified)

The whole user-facing surface is small:

| Symbol                                   | Kind        | Purpose                                                  |
|------------------------------------------|-------------|----------------------------------------------------------|
| `org-pending`                            | function    | Constructor: lock a region, return a `reglock` struct.   |
| `org-pending-send-update`                | function    | Push `:progress`/`:success`/`:failure` into a reglock.   |
| `org-pending-sending-outcome-to`         | macro       | Run a body, send its result/error as outcome.            |
| `org-pending-cancel`                     | function    | User-side cancellation entry point.                      |
| `org-pending-unlock-NOW!`                | function    | Force-unlock (for emergencies/dev).                      |
| `org-pending-list`                       | command     | Open an interactive list of locks.                       |
| `org-pending-describe-reglock`           | function    | Describe a single lock in `*Region Lock*` buffer.        |
| `org-pending-describe-reglock-at-point`  | command     | Same, dispatched from overlay keymap (RET / mouse-1/2).  |
| `org-pending-locks-in`                   | predicate   | Region-overlap query.                                    |
| `org-pending-locks-in-buffer-p`          | predicate   | Buffer query.                                            |
| `org-pending-no-locks-in-emacs-p`        | predicate   | Global query.                                            |
| `org-pending-on-outcome-replace`         | helper      | Default `:on-outcome` — replace region with outcome.     |
| `org-pending-user-edit`                  | command     | Interactive prompt-the-user-to-edit-this-region pattern. |
| `org-pending-updating-region`            | macro       | Lock-while-running-this-elisp pattern.                   |

The reglock struct (`org-pending-reglock`) exposes a small set of
slots through `cl-defstruct` accessors:

- `id` — unique symbol per Emacs instance.
- `region` — `(start-marker . end-marker)`.
- `scheduled-at`, `outcome-at` — `float-time` values.
- `outcome` — `(:success R)` or `(:failure ERR)` once landed.
- `before-destroy-function`, `user-cancel-function`,
  `insert-details-function` — caller-supplied callbacks.
- `properties` — alist for caller extension via
  `org-pending-reglock-property` / `setf`.

Plus several internal `--`-prefixed slots for overlays, status,
liveness predicate, etc.

### Lifecycle

States in chronological order:

```
:scheduled  →  :pending  →  :success
                       →  :failure
```

Updates flow through `org-pending-send-update` with messages
`(:progress P)`, `(:success R)`, `(:failure ERR)`. There is no
distinct `:running` state, no streaming state, and no `:cancelled`
or `:expired` terminal — cancellation is reified as
`(:failure (org-pending-user-cancel "Canceled"))`.

### Visual representation

Each region gets **two overlays**:

1. **`:region`** overlay covering the locked content. Read-only via
   `modification-hooks`, `insert-in-front-hooks`,
   `insert-behind-hooks` that `signal` the custom error
   `org-pending-error-read-only`.
2. **`:status`** overlay (called the *anchor*) over a small visible
   slice — by default the first non-blank to end-of-line within the
   region. This carries:
   - `before-string` = a Unicode glyph keyed by status:
     - `:scheduled` → `⏱`
     - `:pending`   → `⏳`
     - `:failure`   → `❌`
     - `:success`   → `✔️`
   - `after-string` = `" |<short progress text>|"` while pending.
   - `face` = `org-pending-{scheduled,pending}` (inheriting from
     `lazy-highlight` and `next-error` respectively).
   - `keymap` for RET/mouse-1/mouse-2/touchscreen-down →
     `org-pending-describe-reglock-at-point`.

There is **no animation** — the glyph is static and only changes
on state transition. There is **no progress bar** — progress is a
single line of text appended via `after-string`.

On terminal states, both overlays are deleted and `:on-outcome` is
called. If `:on-outcome` returns a region, an outcome overlay is
optionally added (e.g., to display a fringe `large-circle` for
success or `exclamation-mark` for failure).

### Indirect-buffer handling

Notable trick: overlays are buffer-specific, but the library
*projects* read-only properties onto the underlying text via
`add-text-properties` so that indirect buffers also see the lock.
The function is `org-pending--add-overlay-projection`. We will
likely not need this for v1 of `pending` (most consumers are LLM
chat in a single buffer), but we should document the limitation.

### Manager / registry

`org-pending--manager` is a `cl-defstruct` with:

- `used-names` — an obarray for unique-id allocation.
- A list of live reglocks.

It exposes `org-pending--mgr-handle-new-reglock`,
`org-pending--mgr-handle-reglock-update`,
`org-pending--mgr-garbage-collect`. The manager is hooked into
`kill-buffer-query-functions` and `kill-emacs-query-functions` so
the user is asked to confirm before destroying live locks (this
behavior is itself gated by `org-pending-confirm-ignore-reglocks-on-exit`).

### Concurrency model

There is no built-in concurrency. The library is purely a
reactive UI layer — the consumer drives state transitions from
its own timers / sentinels / threads / callbacks via
`org-pending-send-update`. This is the right shape and we adopt
it.

### Cancellation

The `user-cancel-function` slot defaults to
`org-pending--user-cancel-default` which sends
`(:failure (org-pending-user-cancel "Canceled"))`. Callers
override this to abort the underlying work
(kill processes, cancel timers, etc.) before the failure
message is sent.

### Description buffer

`org-pending-describe-reglock` opens a buffer named
`*Region Lock*` showing structured details about the lock:
schedule time, duration, outcome time, owner buffer, and any
custom details inserted via `insert-details-function`. This is a
genuinely useful UX feature we should consider for v1 or v2 of
`pending`.

### What we are taking from it

| Adopt                                          | Reject                                          |
|------------------------------------------------|-------------------------------------------------|
| State-machine-as-cl-defstruct                  | Two overlays per region — one is enough         |
| `:progress`/`:success`/`:failure` message API  | Three-state lifecycle — we want streaming + cancel separate |
| Read-only via modification-hooks               | Static glyph — we want animated spinner         |
| Manager + buffer/emacs kill-query integration  | Org-style anchor inference (first line)         |
| `*Region Lock*` description buffer (later)     | Indirect-buffer projection (not v1)             |
| User-cancel callback as a struct slot          | Naming: org-pending uses snake-case-ish; we use keyword-arg dash style |

### What we are adding beyond it

- Animated spinner (10 fps, single global timer).
- Determinate (`:percent`) and time-driven (`:eta`) progress bars
  with eighth-block rendering.
- First-class streaming via `pending-stream-insert` /
  `pending-stream-finish` modeled on gptel's tracking-marker
  pattern.
- Distinct `:cancelled` and `:expired` terminal states (vs collapsing
  both into `:failure`).
- Deadline timers built in.

## 2. spinner.el (Malabarba)

- Source: <https://github.com/Malabarba/spinner.el>, GNU ELPA.
- Author: Artur Malabarba (also the original Magit Forge developer).
- One vector of frame strings per named style; index advanced by a
  per-spinner timer.
- Used by Magit and a few other packages for mode-line indication.

We **do not depend** on it. The frame-vector idea is worth
borrowing; the per-spinner-timer architecture is not — we use a
single global timer (DESIGN.md §6).

## 3. Built-in `progress-reporter`

- `make-progress-reporter MIN MAX MESSAGE`,
  `progress-reporter-update`, `progress-reporter-done`.
- Writes via `message`, not into buffer text. Suited to long
  synchronous loops, not async I/O.
- Used in this repo by `agent-shell-active-message.el:37-42` as a
  minibuffer activity indicator.

We do not use it directly. Our progress-bar math is
self-contained because we render into an overlay rather than the
echo area.

## 4. Promise / future libraries

| Library      | Style                          | Verdict                                    |
|--------------|--------------------------------|--------------------------------------------|
| `aio`        | coroutines via `aio-defun`     | Optional adapter only.                     |
| `promise.el` | Promises/A+                    | Not a hard dep.                            |
| `deferred`   | `.then`-style chaining (older) | Not used.                                  |
| `make-thread`| native cooperative threads     | Wrong layer — we're a visual placeholder.  |

Conclusion: stay callback-shaped. A `pending-as-promise` adapter
might land in v2; not v1.

## 5. gptel patterns (in this repo)

`gptel/gptel.el` is the closest existing pattern for "async
text lands here later." Lines worth re-reading:

- `gptel.el:1769-1794` — initial response insertion sets up
  `start-marker` and `tracking-marker`.
- `gptel.el:1794` — `(set-marker-insertion-type tracking-marker t)`
  while streaming.
- `gptel.el:1389` — finalize flips it back to nil.
- `gptel.el:1382-1383, 1454-1456` — done/error/abort paths share
  the same marker pair.
- `gptel.el:1349, 544, 586` — `inhibit-read-only` bindings during
  library-internal text mutations.
- `gptel.el:557, 835, 1179, 1186, 2091, 2114, 2474` — overlay
  creation idioms with various `front-advance`/`rear-advance`
  combinations.
- `gptel.el:256` — `pulse-momentary-highlight-region` on
  `gptel-post-response-functions` for the post-resolution flash.

We adopt the marker discipline directly. We do not adopt the FSM
machinery — gptel's FSM is request-state, ours is region-state.

## 6. agent-shell patterns (in this repo)

- `agent-shell-active-message.el:37-42` — minibuffer
  progress-reporter at 0.1s tick. Same cadence we want for
  in-buffer animation.
- `agent-shell-heartbeat.el:37-110` — generic heartbeat with
  `(:started, :busy, :ended)` callback discipline. We mirror the
  shape, not the names — `pending` distinguishes
  resolved/rejected/cancelled/expired terminals.

## 7. Other libraries scanned

- `pulse.el` — fading-overlay-on-timer technique, useful for
  post-resolve flash.
- `magit-section` — `before-string` for inline section headings.
- `dired-async` — mode-line lighter pattern, transferable.
- `tabulated-list` — substrate for `pending-list`.
- `gt.el` (translation) — uses
  `before-string`/`after-string`/replacement overlays, near-isomorphic
  to what we need for resolved state.

## 8. Mailing-list discussion themes

The 87-message thread "Pending contents in org documents" on
<https://list.orgmode.org/?q=org-pending> covers, by visible
fragments:

- Progress-message formatting (the `|...|` after-string).
- Indirect-buffer correctness (the projection trick was added in
  response to discussion).
- Kill-emacs / kill-buffer interaction and confirmation prompts.
- Whether the library belongs in Org or Emacs core.
- Babel async source-block evaluation as a primary motivating
  use-case.
- Usage by gptel-agent (karthink) was mentioned in passing —
  link: <https://github.com/karthink/gptel-agent>.

Worth reading before tackling Phase 8 (interactive UI), since it
covers UX trade-offs Bruno wrestled with.

## 9. References to verify before writing code

When implementation begins, the engineer should:

1. Re-read `/tmp/org-pending.el` (or download fresh) for the
   exact `cl-defstruct` and overlay setup; cross-check our
   DESIGN.md choices against any subtleties that became apparent
   only when implementing.
2. Pull the latest `bba-pending-contents` and `bba-ngnu-pending-contents`
   branches and diff — Bruno may have changed things since this
   research was conducted on 2026-04-30.
3. Read `karthink/gptel-agent` if still online — it appears to be
   a downstream consumer of `org-pending` that might illustrate
   integration patterns we have to support.
4. Verify the actual current state of the patch in upstream Org
   (`git.savannah.gnu.org/cgit/emacs/org-mode.git`) — at this
   research date it had not yet landed in `main`.
