# `pending` — Design Document

A standalone Emacs Lisp library for marking buffer regions whose
content will be supplied asynchronously, with animated progress
indication.

This document is the canonical reference for the API, visual
design, lifecycle, and implementation plan. Read it cover-to-cover
before writing any code. Companion files:

- `RESEARCH.md` — source survey, including a read-through of the
  actual `org-pending.el` from upstream (Bruno Barbier's branch).
- `NOTES.md` — informal observations, decisions to revisit.
- `PLAN.md` — phased implementation checklist.
- `README.md` — short user-facing summary.

---

## 1. Prior art and context survey

### org-pending

`org-pending` lives upstream in Org mode and is karthink's pointer for
"this problem is already half-solved." We have not read its source for
this design pass; everything below is informed speculation we should
treat as prior art to learn from, not copy.

What it almost certainly provides:

- An overlay-bound region marked as "the answer goes here."
- Some kind of registry so you can list what is still pending.
- Hooks for resolving with text or with a failure value.
- Read-only protection on the placeholder region.

Even if it is technically Org-independent (karthink's claim), there are
reasons to ship our own:

- Org's release cadence means new features land slowly.
- The name `org-pending` carries a connotation of Org-mode use; a generic
  client wanting to mark a placeholder in `comint-mode` or `eat` will
  not look there.
- Org core leans on its own utility libs (`org-element`, `org-macs`,
  `ol`) and any incidental use is friction for a standalone consumer.
- We want a modern API shape — keyword args, `cl-defstruct`, a single
  global animation timer, a streaming protocol modeled on gptel — and
  designing around an existing API would constrain us.

What we should adopt from its likely shape:

- The "first-class pending object" idea (a struct/value, not just an
  overlay).
- An interactive lister (`org-pending-list` → `pending-list`).
- A "buffer-local + global registry" with consistent cleanup on buffer
  kill.

What we should reject:

- Any coupling to `org-element`, Org buffer-local state, or `org-mode`
  hooks.
- Any assumption that the placeholder lives in an Org subtree.

We should cross-link: README mentions `org-pending` as related work and
explains the niche difference (no Org dep, gptel-grade streaming, ETA
mode, single global timer, agent-shell-shaped lifecycle vocabulary).

### spinner.el (Malabarba)

`spinner.el` is the canonical Emacs spinner library. Key mechanics worth
emulating:

- A vector of frame strings; an integer index advanced on a timer.
- A small set of named styles (`progress-bar`, `vertical-breathing`,
  `triangle`, `box-in-circle`, etc.) — lets the user pick.
- One timer per spinner, with `spinner-start` / `spinner-stop`.
- It supports inserting the spinner into the mode-line via a
  `:eval`-able function.
- For SVG, spinner.el itself is text-only; SVG spinners (e.g. as used by
  some Forge/Magit tooling) are typically separate.

What we should learn:

- Pre-defined frame vectors keyed by symbol (`pending-spinner-styles`).
- The frame index is independent of wall time — store
  `(% (truncate (* fps elapsed)) (length frames))`.
- The library should NOT mandate one timer per region. We will use a
  single global timer (see §6) — spinner.el's per-spinner timer model
  does not scale cleanly to "many in-buffer placeholders."

What we should reject:

- Per-spinner timers. With potentially dozens of placeholders, we want
  exactly one timer that walks the registry per tick.

We will not depend on `spinner.el`. Re-implementing the frame-vector
logic in 10 lines is cheaper than adding a dependency for a library we
already disagree with about timer architecture.

### Built-in `progress-reporter`

Excellent for minibuffer/message-area updates:

- `make-progress-reporter`, `progress-reporter-update`,
  `progress-reporter-done`.
- Auto-throttles updates.
- See `agent-shell-active-message.el:37-42` for a textbook use.

It is **not** suitable for in-buffer overlay rendering — it writes via
`message`, not into a buffer position. We borrow its API shape for our
ETA computation (current/min/max → percent) but the rendering substrate
is overlays, not the echo area.

### `make-thread` / `aio` / `promise.el` / `deferred.el`

The question is whether `pending-make` should return a struct (callback
shape) or a promise (`thenable` / `aio-await` shape).

- **callback shape**: `(pending-make ...)` returns a struct; the caller
  later does `(pending-finish p text)`. Simple, no dep, matches every
  existing async surface in Emacs (process sentinels, `url-retrieve`'s
  callback, `gptel-request`'s `:callback`).
- **promise shape**: `(pending-make ...)` returns a promise that
  resolves when `(pending-finish ...)` is called elsewhere. Composable
  with `aio-await`, but adds either a hard dep (`aio`) or a parallel
  promise impl.

**Recommendation**: stay callback-shaped. Optionally expose a thin
adapter `pending-as-promise` (autoloaded, only used if the user has
`aio` or `promise` loaded). The struct is the canonical handle. This
matches every other library it will integrate with — gptel, `make-process`,
`url-retrieve`, `make-thread` — and avoids importing a promise idiom
into a buffer-overlay library that does not need one.

`make-thread`: irrelevant here. `pending` is not concurrency; it is a
visual placeholder for work that runs elsewhere.

### gptel's tracking-marker pattern

The exact references in this repo:

- `gptel/gptel.el:1769-1794` — initial response insertion sets up
  `start-marker` (the position) and `tracking-marker` (a fresh
  `point-marker` at the end of inserted text).
- `gptel/gptel.el:1794` — `(set-marker-insertion-type tracking-marker t)`
  during streaming so subsequent inserts at the marker push it forward.
- `gptel/gptel.el:1389` — at finalize time,
  `(set-marker-insertion-type tracking-marker nil)` to "lock" the
  marker so any user editing after the response does not drag the
  marker.
- `gptel/gptel.el:1382-1383, 1454-1456` — error and abort paths reuse
  the same `start-marker` / `tracking-marker` pair, falling back to
  `start-marker` if streaming never started.

Lessons we adopt verbatim:

- **Two markers per region**: a `start` (insertion type nil — leftmost
  edge stays put on insertions before it) and an `end` (insertion type
  t while streaming so the stream extends the region; flipped to nil on
  resolution).
- **`info` as the carrier of streaming state**: gptel uses an info
  plist; we use a struct, but the same idea — one mutable handle keeps
  the markers and metadata together.
- **Error/abort/done converge** on the same marker pair. We do too:
  resolve, reject, cancel all operate on a single `pending` struct.

We will *not* use a plist; `cl-defstruct` is more inspectable, prints
better, and gives us slot accessors for free.

### agent-shell heartbeat & active-message

- `agent-shell/agent-shell-active-message.el:37-42`: minibuffer
  progress with a 0.1s `run-at-time` tick and
  `progress-reporter-update`. Exact same cadence we want for the
  in-buffer spinner — 10 fps is the sweet spot between "fast enough to
  read as motion" and "slow enough not to hammer redisplay."
- `agent-shell/agent-shell-heartbeat.el:37-110`: a generic heartbeat
  with `started`/`busy`/`ended` states, beats-per-second configurable,
  callback-driven. The lifecycle vocabulary
  (`started`/`busy`/`ended`) is what we mirror for `pending`'s state
  machine: `:scheduled` ≈ created-but-not-started, `:running` ≈ busy,
  resolved/rejected/cancelled ≈ ended-with-reason.

We deliberately keep our state names different from agent-shell's
(`:running` vs `busy`, four terminal states vs one `ended`) because
`pending` distinguishes success/failure/cancel/timeout at the type
level. But the *shape* — single bag of state, one callback fired on
each transition — is borrowed.

### pulse.el, magit-section, dired-async, tabulated-list

- **`pulse.el`** uses overlays with a fading face on a timer. Useful
  technique: start with a vivid face, decay over N ticks, then
  `delete-overlay`. We can use this for the *resolution flash* — when a
  placeholder resolves, briefly pulse the inserted text so the eye
  finds it. `gptel.el:256` already wires
  `pulse-momentary-highlight-region` into
  `gptel-post-response-functions`; we'll do the same.
- **`magit-section`** uses `before-string` overlays for inline
  decoration (the section heading "▶ Unstaged changes" arrow). Same
  technique we need for the spinner glyph.
- **`dired-async`** decorates the mode-line, not the buffer; transferable
  only insofar as it shows a global lighter pattern.
- **`tabulated-list`** is the right substrate for the `pending-list`
  buffer.

## 2. Conceptual model

### The pending region as a value

```elisp
(cl-defstruct (pending (:constructor pending--make-struct)
                       (:copier nil)
                       (:predicate pending-p))
  ;; Identity
  id                ; symbol, gensym'd `pending-N`
  group             ; user-supplied tag, optional, for filtering in pending-list
  label             ; string, "Calling Claude" — shown in placeholder + lister
  ;; Location
  buffer            ; the buffer this lives in
  start             ; marker, insertion-type nil (anchored on insertions before)
  end               ; marker, insertion-type t while streaming; nil after resolve
  overlay           ; the overlay covering [start, end]
  ;; Visual mode
  indicator         ; `:spinner' | `:percent' | `:eta'
  spinner-style     ; symbol, key into `pending--spinner-frames'
  face              ; defaulted to `pending-face'; user override
  ;; Determinate / ETA state
  percent           ; nil or float in [0.0, 1.0]; used in :percent mode
  eta               ; nil or float seconds (estimated total); used in :eta mode
  start-time        ; float, `(float-time)` at :running
  deadline          ; nil or float seconds (max wall-clock); auto-rejects
  ;; Lifecycle
  status            ; one of :scheduled :running :streaming :resolved
                    ;        :rejected :cancelled :expired
  reason            ; on terminal states, an explanatory value (string or symbol)
  resolved-at       ; float-time when terminal state entered
  ;; Callbacks
  on-cancel         ; (lambda (pending) ...) — called when user cancels
  on-resolve        ; optional, fires once on terminal state
  ;; Internal
  attached-process  ; optional process whose sentinel auto-rejects
  attached-timer    ; optional one-shot timer for deadline expiry
  )
```

`cl-defstruct` (not a plist) so it's printable, accessor-typed, and
`cl-defmethod`-dispatchable should we ever want polymorphism on
indicator type.

### Lifecycle

State diagram:

```
                 pending-make
                      │
                      ▼
                 :scheduled ──────► (no producer ever started)
                      │                          │
            (first stream chunk OR               │
             pending-update OR                   │
             pending-finish)                     │
                      ▼                          │
                  :running ◄─┐                   │
                      │      │                   │
              pending-stream-insert              │
                      │      │                   │
                      ▼      │                   │
                 :streaming ─┘                   │
                      │                                  ▲
       ┌──────────────┼──────────────┬───────────────────┤
       ▼              ▼              ▼                   │
  :resolved       :rejected     :cancelled         :expired
                                (user/programmatic) (deadline)
```

Allowed transitions (everything else is a no-op + warning):

- `:scheduled → :running` (first non-state mutation)
- `:scheduled → :resolved | :rejected | :cancelled | :expired`
- `:running   → :streaming` (first stream chunk)
- `:running   → :resolved | :rejected | :cancelled | :expired`
- `:streaming → :resolved | :rejected | :cancelled | :expired`
- terminal → terminal: ignored, log a warning at `:debug`.

### Single-resolution invariant

`pending--resolve-internal` is the one and only place that flips a
struct from non-terminal to terminal. It:

1. Acquires a tiny `with-mutex`-style guard via a slot
   `pending--in-resolve` (a boolean) so re-entrant resolves (e.g. a
   `:on-resolve` callback that itself triggers another resolve on the
   same struct) bail out at the top.
2. Checks current `status`; if already terminal, returns nil and
   `display-warning`s at `:debug` level.
3. Sets `status`, `reason`, `resolved-at`.
4. Replaces the placeholder text atomically (`atomic-change-group`).
5. Removes the struct from registries.
6. Cancels timers, detaches process sentinels, deletes overlay.
7. Calls `on-resolve` callback exactly once.

This is the ONLY mutation path on terminal state, so the invariant
collapses to "step 2 returns early." We rely on Emacs being
single-threaded — no real lock needed, just the early-return check.

### Identity & uniqueness

`gensym`-style is sufficient. We are not persisting these; nobody
unmarshals them from disk. A monotonically increasing counter is fine:

```elisp
(defvar pending--next-id 0)
(defun pending--gen-id ()
  (intern (format "pending-%d" (cl-incf pending--next-id))))
```

If we ever need to round-trip through some external system, we can
upgrade to `(format "%s-%d" (random) (cl-incf pending--next-id))` or
`make-temp-name`. Crypto-grade IDs are not warranted.

### Ownership

- The **caller** owns `pending-finish`, `pending-stream-insert`,
  `pending-stream-finish`, `pending-reject`, `pending-update`. These
  are how the producer reports progress and finalizes.
- The **library** owns the timer, overlay rendering, registry mutation,
  and edit-survival hooks.
- The **user** (interactively) can call `pending-cancel-at-point` and
  `pending-list` → cancel; both route through `pending-cancel`, which
  invokes the caller-supplied `on-cancel` before flipping to
  `:cancelled`.

The caller must NOT mutate struct slots directly; they must go through
the API. We document this and put the "API" functions above
`pending--` helpers, but we don't enforce it (Emacs has no private
slots).

## 3. Public API surface

### `pending-make`

```elisp
(cl-defun pending-make (buffer &key
                                label
                                start end
                                indicator
                                deadline
                                eta
                                percent
                                face
                                spinner-style
                                on-cancel
                                on-resolve
                                group)
  "Create and insert a pending placeholder in BUFFER.

Returns a `pending' struct.  The placeholder is also registered in
`pending--registry' (global) and the buffer-local
`pending--buffer-registry' so it can be enumerated.

Insertion modes:
  - If START and END are both nil, insert a new placeholder at point
    in BUFFER.  Both markers are created from `point-marker'.
  - If START and END are both non-nil (positions or markers), adopt
    the existing region [START, END]; do not insert text.  Useful when
    the caller has already laid out a stub.
  - It is an error to supply only one of START or END.

LABEL is a short string shown inside the placeholder
(e.g. \"Calling Claude\").  Defaults to \"Pending\".

INDICATOR selects the visual:
  :spinner  (default)
  :percent  (requires PERCENT to be non-nil at creation, or supplied
             via `pending-update' before the user looks at it)
  :eta      (requires ETA, in seconds; pure ETA mode pretends not to
             know exact percent and computes the bar from elapsed time)

DEADLINE, if non-nil, is wall-clock seconds before the placeholder is
auto-rejected with `:timed-out'.  A timer is registered.

PERCENT, if non-nil, is the initial fraction in [0.0, 1.0].
ETA, if non-nil, is the estimated total seconds.

FACE overrides the default `pending-face' for this placeholder.

SPINNER-STYLE selects a key in `pending-spinner-styles' (a defcustom
alist).  Defaults to `pending-default-spinner-style'.

ON-CANCEL is a function of one argument (the pending struct) called
when the placeholder is cancelled (interactively or programmatically).
This is where the caller aborts its underlying work, e.g. by calling
`delete-process' on a curl handle.

ON-RESOLVE, when non-nil, is a function called exactly once at any
terminal transition with the pending struct as its only argument.

GROUP is an optional symbol used to filter `pending-list' output.

Side effects:
  - Inserts placeholder text (in insert mode) covering [start,end]
    with read-only / front-sticky / rear-nonsticky properties.
  - Adds an overlay with the right faces and a `before-string'
    spinner glyph.
  - Adds the struct to both registries.
  - Starts the global animation timer if not already running.
  - Schedules the deadline timer if DEADLINE is non-nil.
  - If BUFFER is read-only or unreachable, signals `pending-error'.

Returns the struct unconditionally on success."
  ...)
```

Edge cases:

- BUFFER killed before we even insert: signal `pending-error`.
- Buffer is read-only: see §9 — by default we refuse and signal; we
  expose `pending-allow-read-only` for cases like compile-mode where
  the caller has already set `inhibit-read-only`.
- START or END outside buffer bounds: signal `pending-error`.
- No `:label` given and no `:group` either: log nothing, just default
  the label to "Pending".

### `pending-finish`

```elisp
(defun pending-finish (p text)
  "Atomically replace P's placeholder region with TEXT.
Transitions P to `:resolved' and returns t.  No-op + warning if P is
already terminal.

The replacement happens inside an `atomic-change-group' so undo sees
one step.  `inhibit-modification-hooks' is bound during the swap so
the read-only enforcement does not fight us.

Side effects: removes overlay, clears markers (set to point nowhere),
unregisters, runs ON-RESOLVE callback."
  ...)
```

### `pending-stream-insert`

```elisp
(defun pending-stream-insert (p chunk)
  "Append CHUNK (a string) to P's placeholder region.
Keeps the spinner / progress indicator visible and the placeholder
read-only.  The end marker advances (insertion-type t).

Transitions P from `:running' (or `:scheduled') to `:streaming' on
first call.  Subsequent calls remain in `:streaming'.

This does NOT finalize.  Caller must finish with
`pending-stream-finish' or `pending-reject' or `pending-cancel'.

If P is already terminal, this is a no-op + warning (the chunk is
dropped on the floor)."
  ...)
```

On the first chunk, the placeholder label content is replaced by CHUNK
and the end marker's insertion-type flips to t; subsequent chunks append
at the (now-advancing) end marker. The user sees the loading label
("Calling Claude") vanish and the first arriving chunk take its place,
with subsequent chunks growing the region naturally.

Streaming semantics:

- Inserted text within `[start, end)` is decorated with the same
  read-only properties as the original placeholder so the user cannot
  edit it mid-stream.
- The spinner glyph stays in `before-string` (or wherever §4 places
  it) until `pending-stream-finish`.

### `pending-stream-finish`

```elisp
(defun pending-stream-finish (p)
  "Finalize a streamed placeholder.
Transitions P from `:streaming' to `:resolved'.  Removes spinner,
locks end marker (`set-marker-insertion-type ... nil'), strips the
overlay's animated decorations, removes read-only protection,
deletes overlay, unregisters, fires ON-RESOLVE.

If P is in `:running' (no chunks ever streamed), behaves like
`(pending-finish P \"\")'."
  ...)
```

### `pending-reject`

```elisp
(defun pending-reject (p reason &optional replacement-text)
  "Mark P as failed with REASON (string or symbol).
By default, REPLACEMENT-TEXT is a propertized error glyph plus the
reason; the caller can override with an explicit string.

Transitions to `:rejected', removes registry entry, fires ON-RESOLVE
with the rejected struct.  The replacement uses `pending-error-face'."
  ...)
```

### `pending-cancel`

```elisp
(defun pending-cancel (p &optional reason)
  "Cancel P.
Calls P's ON-CANCEL callback (if any) FIRST, so the caller can abort
its work (e.g. kill a process).  Then transitions to `:cancelled'
with REASON (default `:cancelled-by-user').  Replaces the placeholder
with a small cancelled glyph + label using `pending-cancelled-face'.

Safe to call from anywhere, including the ON-CANCEL callback's own
chain (re-entrant resolves are idempotent — see single-resolution
invariant)."
  ...)
```

### `pending-update`

```elisp
(cl-defun pending-update (p &key label percent eta indicator)
  "Update P's metadata while it is still active.
Any non-nil keyword updates the corresponding slot.  If INDICATOR
changes, the visual decoration is re-rendered on next tick.  If
PERCENT or ETA changes, the bar is re-computed.

No state transition.  Returns P.

If P is terminal, no-op + warning."
  ...)
```

### Predicates and accessors (public)

```elisp
(defun pending-active-p (p)
  "Non-nil if P is in :scheduled, :running, or :streaming state.")

(defun pending-status (p)
  "Return the status keyword of P.")

(defun pending-at (&optional pos buffer)
  "Return the pending struct at POS (default `point') in BUFFER
(default `current-buffer'), or nil if none.")

(defun pending-list-active (&optional buffer group)
  "Return list of active pending structs.
If BUFFER non-nil, only ones in BUFFER.  If GROUP non-nil, only those
matching that group symbol.")
```

### Interactive UI

```elisp
;;;###autoload
(defun pending-cancel-at-point ()
  "Cancel the pending placeholder at point, if any.
Interactive equivalent of `pending-cancel' on `pending-at'."
  (interactive)
  ...)

;;;###autoload
(defun pending-list ()
  "Open the *Pending* tabulated-list buffer showing all active
placeholders across all buffers.  Columns: ID, Buffer, Label, Status,
Elapsed, ETA, Group.  RET on a row jumps to the placeholder.  `c'
cancels.  `g' refreshes."
  (interactive)
  ...)
```

### Convenience macros

```elisp
(defmacro pending-with (binding-spec &rest body)
  "Bind a fresh pending placeholder and execute BODY.

BINDING-SPEC is (VAR . KEYWORD-ARGS) where KEYWORD-ARGS go to
`pending-make'.  The placeholder is auto-rejected with `:body-error'
if BODY signals.

  (pending-with (p :buffer (current-buffer) :label \"Calling LLM\")
    (gptel-request \"hi\"
      :callback (lambda (resp _) (pending-finish p resp))))

The macro expands to a `condition-case' wrapping BODY so that uncaught
errors do not leave the placeholder hanging forever."
  ...)
```

We deliberately do NOT add a `pending-let*` (multi-bind) variant in v1
— it would muddy the lifetime semantics. If a caller needs N
placeholders, they call `pending-make` N times.

### Edge cases per function

- **Buffer killed**: `kill-buffer-hook` cancels every pending in that
  buffer (`pending-cancel` with reason `:buffer-killed`). The
  caller's `on-cancel` runs in the killed buffer's *previous*
  current-buffer — we do not try to switch to a dead buffer.
- **Region deleted by user**: detected via overlay's
  `modification-hooks` (see §5); fires `pending-cancel` with reason
  `:region-deleted`.
- **Double-resolution**: §2 invariant — second call returns nil and
  warns at `:debug`.
- **User cancels mid-stream**: `pending-cancel` runs `on-cancel`
  (caller kills curl), then replaces whatever has been streamed so far
  with the cancelled glyph. The streamed-so-far text is lost; if the
  caller wants to keep it, they should call `pending-stream-finish`
  before cancel-time, but at that point they've raced.

## 4. Visual design

### Overlay structure

We use **one overlay per placeholder**, covering `[start, end]`.

Properties:

| property            | value                                                |
|---------------------|------------------------------------------------------|
| `pending`           | the struct itself (so `pending-at` can recover it)   |
| `face`              | `pending-face` (or per-region override)              |
| `priority`          | 100 (high enough to win over font-lock)              |
| `evaporate`         | nil (we control deletion ourselves)                  |
| `before-string`     | propertized spinner/glyph + space                    |
| `after-string`      | propertized progress bar + " ▏"                      |
| `modification-hooks`| `(pending--on-modify)` — auto-cancel on edit         |
| `insert-in-front-hooks` | `(pending--on-edge-insert)`                      |
| `insert-behind-hooks`   | `(pending--on-edge-insert)`                      |
| `help-echo`         | function returning the dynamic tooltip               |
| `keymap`            | `pending-region-map` — RET / mouse-1 → cancel        |
| `cursor-sensor-functions` | nil (we keep the placeholder cursor-friendly)  |

**`before-string` vs `display` vs `after-string` trade-off**:

- `display` *replaces* the underlying buffer text. Tempting because we
  could put the entire indicator there and have empty buffer text.
  Rejected: it interacts badly with `visual-line-mode`, with
  copy-as-kill (you copy the literal stub text underneath), and with
  cursor positioning. gptel does not use `display` for response
  insertion either.
- `before-string` is the spinner glyph (1-2 chars). It does not affect
  cursor positioning of the underlying text.
- `after-string` is the progress bar trailer. Stays attached to the end
  of the region; perfect for "X% [████···]".
- Underlying buffer text is the **label** itself — e.g. `"Calling
  Claude"` — propertized read-only and given the `pending` face. This
  way:
  - kill-region within the placeholder copies a meaningful string.
  - the overlay can be deleted on resolve and the label vanishes
    naturally because we replace the region.

So the layout in the buffer reads:

```
┌─ before-string ─┐ ┌─── buffer text ───┐ ┌──── after-string ────┐
       ⠋               Calling Claude         [████····] 45%
```

### Spinner

Two styles, configurable per region.

**Text-only (default, works in TUI)**:

```elisp
(defvar pending--spinner-frames-text
  '((dots-1   . ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])  ; Braille
    (dots-2   . ["⠁" "⠂" "⠄" "⡀" "⢀" "⠠" "⠐" "⠈"])
    (line     . ["|" "/" "-" "\\"])
    (arc      . ["◜" "◠" "◝" "◞" "◡" "◟"])
    (clock    . ["🕛" "🕐" "🕑" "🕒" "🕓" "🕔" "🕕" "🕖" "🕗" "🕘" "🕙" "🕚"])))
```

**SVG (when `image-types` includes `svg`)**: an autoload-on-demand
`pending--svg-spinner` returns a propertized image string. Built once
per `(face, size, frame-index)` triple, cached in a hash keyed by
that tuple. We do not need this in v1; v1 ships text-only and v2 adds
SVG.

**Frame cadence**: 10 fps. Rationale:

- agent-shell-active-message uses 0.1s; we match it.
- 100ms is the sweet spot: low CPU, looks animated.
- Configurable via `pending-fps` (defcustom, default 10).

**One global timer, not per-region**:

```elisp
(defvar pending--global-timer nil)
(defvar pending--registry (make-hash-table :test 'eq))

(defun pending--ensure-timer ()
  (unless (and pending--global-timer (timerp pending--global-timer))
    (setq pending--global-timer
          (run-at-time 0 (/ 1.0 pending-fps) #'pending--tick))))

(defun pending--tick ()
  (let ((any-visible nil))
    (maphash
     (lambda (_id p)
       (when (pending--needs-redraw-p p)
         (setq any-visible t)
         (pending--render p)))
     pending--registry)
    (unless any-visible
      ;; All placeholders in invisible windows or terminal — sleep.
      (cancel-timer pending--global-timer)
      (setq pending--global-timer nil))))
```

Reasoning: with N placeholders and N timers, every tick scans N timer
lists. With 1 timer, we walk the registry once. The `pending--tick`
itself early-exits per-region if the buffer is not displayed.

When a new placeholder is created and the timer is parked, we call
`pending--ensure-timer` to wake it up.

### Progress bar rendering

Text bar, fixed width:

```
[████████░░░░░░░░] 47%
```

Exact characters (Unicode block elements give 1/8th resolution):

```elisp
(defconst pending--bar-blocks
  ;; index 0..8 → that-many eighths filled
  ["·" "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█"])
```

So a bar of `N` cells with fraction `f` shows
`floor(f*N)` full blocks, one partial block (eighth-resolution), and
fillers. This avoids the "bar jumps" feel.

Bar width: `pending-bar-width` defcustom, default 16. With
proportional/variable-pitch fonts, pad with `(propertize " "
'display '(space :width 1))` units; we use a monospace face on the
bar segment regardless of buffer face by setting
`(:family pending-bar-family)` on `pending-progress-face`.

If the surrounding buffer uses `variable-pitch-mode`, the after-string
is rendered in its own face, so monospace is preserved.

Layout for after-string:

- spinner-mode: `" ⠋ "` (just the spinner)
- percent-mode: `" [████····] 45%"`
- ETA-mode: `" [████····] ~12s"` (estimated remaining)

### ETA mode math

Goal: a bar that fills steadily toward 95% as elapsed approaches the
estimated total, and asymptotically slows past 95% so we never claim
"done" until actually resolved.

Let `t = (- now start-time)`, `T = eta` (estimated total).

```
ratio = t / T

if ratio <= 0.8:
    visual = ratio * (0.95 / 0.95)   # up to 0.8 directly
elif ratio <= 1.0:
    # piecewise linear from (0.8, 0.8) to (1.0, 0.95)
    visual = 0.8 + (ratio - 0.8) * (0.15 / 0.20)
else:
    # asymptotic: visual approaches 1.0 from 0.95, never reaches
    visual = 1.0 - 0.05 * exp(-(ratio - 1.0))
```

So:

- `t = 0`         → 0
- `t = 0.5 T`     → 0.5
- `t = 0.8 T`     → 0.8
- `t = T`         → 0.95
- `t = 2 T`       → ~0.982
- `t = 4 T`       → ~0.9975

We never display 100% in ETA mode. Resolution is the only thing that
removes the bar. Show estimated remaining as
`max(0, T - t)` clamped to `>= 1` once we're past `T` so the user
sees "1s" rather than "0s" forever.

If `:percent` is also supplied alongside `:eta`, `:percent` wins
(direct mode).

### Faces

```elisp
(defface pending-face
  '((((class color) (background dark))
     :background "#1e3a5f" :foreground "#a8c5e8" :extend t)
    (((class color) (background light))
     :background "#e8f0fa" :foreground "#1f4a78" :extend t)
    (t :inherit shadow))
  "Face for the placeholder body (label text).")

(defface pending-progress-face
  '((t :inherit pending-face :family "Menlo"))
  "Face for the after-string progress bar / ETA text.
Family forced to monospace to keep alignment.")

(defface pending-spinner-face
  '((((class color) (background dark)) :foreground "#ffd866")
    (((class color) (background light)) :foreground "#b6862c"))
  "Face for the before-string spinner glyph.")

(defface pending-error-face
  '((t :inherit error :weight bold))
  "Face for rejected placeholders (replacement text).")

(defface pending-cancelled-face
  '((t :inherit shadow :slant italic))
  "Face for cancelled placeholders.")
```

Theme defaults are specified in the defface; users can override with
`custom-theme-set-faces`.

### Visibility-driven animation

```elisp
(defun pending--needs-redraw-p (p)
  "Non-nil if P is in a state that animates AND its buffer/window
is currently visible."
  (and (memq (pending-status p) '(:scheduled :running :streaming))
       (let ((buf (pending-buffer p)))
         (and (buffer-live-p buf)
              (get-buffer-window buf 'visible)))))
```

Hook `pending--check-visibility` onto
`window-buffer-change-functions` (Emacs 27.1+) so when a buffer
becomes visible we re-arm the timer if it had parked itself.

### Fringe indicator

Optional. `pending-fringe-bitmap` defcustom (nil to disable, symbol
naming a bitmap to use, default nil). When non-nil, place an overlay
property `'before-string (propertize " " 'display
'(left-fringe pending-fringe-bitmap pending-spinner-face))`. This
gives off-screen visibility — you scroll past the placeholder, you
still see a bar of bitmaps in the fringe.

## 5. Marker and edit-survival semantics

### Insertion types

- **start marker**: insertion-type `nil` (default). Insertions *at*
  the marker's position go *before* it, leaving the marker pointing
  at the same character. Behavior: text typed at the buffer position
  just before the placeholder pushes the placeholder to the right —
  exactly what we want.
- **end marker**: insertion-type `t` *while running/streaming*.
  Insertions at its position go *to its left* — i.e. the marker
  advances to remain at the end. This lets `pending-stream-insert`
  call `(goto-char (pending-end p))` and `(insert chunk)` and have
  the marker still point at the new end. Mirrors gptel's pattern at
  `gptel.el:1794`.
- **end marker on resolve**: flip to `nil` via
  `set-marker-insertion-type`. Now post-resolve user typing at the
  end of the inserted text does not drag a marker that no longer
  matters (we're about to delete it anyway, but flipping is correct
  hygiene; gptel does it at `gptel.el:1389`).

### Pictorial trace

Placeholder text is "Pending" with `start` at index 5 and `end` at
index 12 (one past last char):

```
0       5       12
"Hello, Pending world"
       ^       ^
     start    end (insertion-type t)
```

**Scenario A — insert before the placeholder**: user types "X" at
position 3.

```
0       6       13
"HelXlo, Pending world"
        ^       ^
      start    end
```

`start`/`end` both shifted because they're markers — they track edits
*before* them automatically. ✓

**Scenario B — insert after the placeholder**: user types "X" at
position 12 (which is `end`).

With `end` at insertion-type `t`, the new char goes *to the left of*
the marker, which means the marker *stays* and the inserted char
becomes part of `[start, end)`. NOT what we want — the user typed
*after* our region.

Mitigation: while `:running` we forbid edits at the rear edge via
`insert-behind-hooks` on the overlay. The hook fires before the
insert is finalized; we either reject the edit (see read-only below)
or reroute the insert to *after* `end` by manually adjusting `end`
backward.

In practice we use the hook to *reject* — see read-only enforcement.

After resolution, end is insertion-type `nil`, and insertions at the
position go *after* the marker, which is the natural behavior when
the placeholder no longer exists.

**Scenario C — delete around the region**: user does
`(delete-region 4 14)`, swallowing the placeholder.

The markers' positions become whatever Emacs computes after delete
(both end up at position 4). We detect this in
`modification-hooks` (the overlay's), see that the region collapsed
to zero length, and fire `pending-cancel` with reason
`:region-deleted`.

### Region-deletion detection

Overlay `modification-hooks` are called both before and after the
modification (with a flag). We use the *after* hook:

```elisp
(defun pending--on-modify (ov after _beg _end &optional _len)
  (when after
    (let ((p (overlay-get ov 'pending)))
      (when p
        (cond
         ;; Overlay collapsed to nothing → user deleted the region.
         ((and (overlay-buffer ov)
               (= (overlay-start ov) (overlay-end ov)))
          (pending-cancel p :region-deleted))
         ;; Overlay buffer killed.
         ((not (overlay-buffer ov))
          (pending-cancel p :buffer-killed)))))))
```

### Read-only enforcement

Two options:

1. **`read-only` text property** on the placeholder text. `front-sticky`
   `(read-only)` so insertions at the start are blocked too.
   `rear-nonsticky` `(read-only)` so post-region insertions are
   allowed.
2. **Overlay's `modification-hooks` rejecting via `(error
   "Read-only")`**.

**Recommendation**: use the text property (option 1). It's the
mechanism Emacs already uses for read-only buffer regions; it composes
with `inhibit-read-only` (which we use at resolve-time); and the user
gets the standard "Text is read-only" message they already know. The
overlay-hook approach has surprising failure modes (e.g. yank into the
middle of a region partly succeeds and partly fails depending on
hook ordering).

We keep the overlay's `modification-hooks` only for *detecting*
deletions (option 2's read-only blocking is redundant with option 1),
not for blocking edits.

For streaming inserts within the region, we bind `inhibit-read-only`
to `t` inside `pending-stream-insert`. The user cannot insert (text
is read-only) but we can.

### Atomic resolution

```elisp
(defun pending--swap-region (p new-text face)
  (with-current-buffer (pending-buffer p)
    (atomic-change-group
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            (start (marker-position (pending-start p)))
            (end (marker-position (pending-end p))))
        (delete-region start end)
        (goto-char start)
        (insert (propertize new-text 'face face))
        (set-marker (pending-end p) (point))))))
```

`atomic-change-group` ensures undo sees one step and that if the
insert fails partway, the delete is rolled back. `inhibit-read-only`
defeats our own placeholder protection. `inhibit-modification-hooks`
prevents our own region-deletion detector from firing during this
swap.

## 6. Concurrency, timers, and cleanup

### Single global animation timer

Pseudocode:

```elisp
(defvar pending--global-timer nil)
(defvar pending--registry (make-hash-table :test 'eq)
  "Hash from id symbol → pending struct.")

(defun pending--tick ()
  (let ((dirty nil)
        (any-active nil))
    (maphash
     (lambda (_id p)
       (cond
        ((not (pending-active-p p))
         ;; Stale entry; remove.
         (push p dirty))
        ((pending--needs-redraw-p p)
         (setq any-active t)
         (pending--render p))))
     pending--registry)
    (dolist (p dirty)
      (pending--unregister p))
    (unless any-active
      (cancel-timer pending--global-timer)
      (setq pending--global-timer nil))))
```

Cadence: `(/ 1.0 pending-fps)` with `pending-fps` default 10. Tick is
cheap because:

- Most placeholders are in invisible buffers → skipped.
- Active placeholders only re-render when the spinner index or bar
  fraction has changed since last draw. We cache `last-frame` and
  `last-bar` in the struct and compare.

### Registry

Two structures, kept in sync:

```elisp
(defvar pending--registry (make-hash-table :test 'eq)
  "Global hash: id symbol → pending.")

(defvar-local pending--buffer-registry nil
  "Buffer-local list of pending structs in this buffer.")
```

Sync invariant: every pending P in `pending--registry` is also in
`(buffer-local-value 'pending--buffer-registry (pending-buffer P))`.
`pending--register` and `pending--unregister` are the only mutators
and update both atomically (single-threaded, so "atomically" here is
a sequence of two assignments).

### Buffer kill hook

```elisp
(defun pending--on-kill-buffer ()
  (dolist (p (copy-sequence pending--buffer-registry))
    (pending-cancel p :buffer-killed)))

(add-hook 'kill-buffer-hook #'pending--on-kill-buffer)
```

The `copy-sequence` is essential because `pending-cancel` mutates the
list as it goes.

### Process integration

```elisp
(defun pending-attach-process (p process)
  "Wire PROCESS so that its death rejects/cancels P appropriately.
Multiple processes can be attached; the LAST sentinel wins.
Returns P."
  (let ((existing (process-sentinel process)))
    (setf (pending-attached-process p) process)
    (set-process-sentinel
     process
     (lambda (proc event)
       (when existing (funcall existing proc event))
       (pending--process-sentinel p proc event)))
    p))

(defun pending--process-sentinel (p _proc event)
  (pcase event
    ((pred (string-prefix-p "finished"))
     ;; Process exited cleanly.  We don't auto-resolve; the caller
     ;; should have already called pending-finish.  If not, something
     ;; is wrong — reject.
     (when (pending-active-p p)
       (pending-reject p "process exited without resolving")))
    ((or (pred (string-prefix-p "exited abnormally"))
         (pred (string-prefix-p "killed"))
         (pred (string-prefix-p "broken pipe")))
     (when (pending-active-p p)
       (pending-reject p (format "process: %s" (string-trim event)))))))
```

### Deadline timer

```elisp
(defun pending--start-deadline-timer (p)
  (when (pending-deadline p)
    (setf (pending-attached-timer p)
          (run-at-time
           (pending-deadline p) nil
           (lambda () (when (pending-active-p p)
                        (pending-reject p :timed-out)))))))
```

Cancelled in `pending--unregister`:

```elisp
(when-let* ((tm (pending-attached-timer p)))
  (when (timerp tm) (cancel-timer tm))
  (setf (pending-attached-timer p) nil))
```

## 7. Integration sketches

### gptel — streaming pending

```elisp
(defun my/gptel-pending-request (prompt)
  (let* ((p (pending-make (current-buffer)
                          :label "Calling Claude"
                          :indicator :spinner
                          :on-cancel (lambda (_)
                                       (gptel-abort (current-buffer))))))
    (gptel-request
     prompt
     :stream t
     :position (pending-end p)        ; gptel's tracking-marker starts here
     :callback (lambda (chunk info)
                 (pcase chunk
                   ((pred stringp)
                    (pending-stream-insert p chunk))
                   (`(reasoning . ,_) nil)  ; ignore
                   (_  (if (plist-get info :error)
                           (pending-reject p (plist-get info :error))
                         (pending-stream-finish p))))))
    ;; Note: with :stream t and :callback, gptel routes each chunk to the
    ;; callback; the callback inserts via pending-stream-insert.  The
    ;; :position keyword is just where gptel's tracking-marker starts.
    p))
```

### make-process — capture stdout into a pending region

```elisp
(defun my/run-shell-pending (cmd)
  (let* ((p (pending-make (current-buffer)
                          :label (format "Running: %s" cmd)
                          :indicator :spinner))
         (proc (make-process
                :name "shell-pending"
                :buffer nil
                :command (list shell-file-name "-c" cmd)
                :filter (lambda (_proc out)
                          (pending-stream-insert p out))
                :sentinel (lambda (_proc event)
                            (if (string-prefix-p "finished" event)
                                (pending-stream-finish p)
                              (pending-reject p (string-trim event)))))))
    (pending-attach-process p proc)
    (setf (pending-on-cancel p) (lambda (_) (delete-process proc)))
    p))
```

### url-retrieve — async fetch

```elisp
(defun my/fetch-pending (url)
  (let ((p (pending-make (current-buffer)
                         :label (format "Fetching %s" url)
                         :indicator :eta :eta 5.0
                         :deadline 60)))
    (url-retrieve
     url
     (lambda (status)
       (cond
        ((plist-get status :error)
         (pending-reject p (format "%S" (plist-get status :error))))
        (t
         (goto-char (point-min))
         (re-search-forward "^$" nil t)
         (pending-finish p (buffer-substring (point) (point-max)))))))
    p))
```

### Pure delay — for testing

```elisp
(defun my/pending-delay (seconds)
  (let* ((p (pending-make (current-buffer)
                          :label (format "Wait %ds" seconds)
                          :indicator :eta :eta (float seconds))))
    (run-at-time seconds nil
                 (lambda () (pending-finish p (format "done after %ds" seconds))))
    p))
```

## 8. Testing strategy

### ERT plan

Test file: `pending-test.el`. All tests run with `lexical-binding`.

State transitions:

- `pending-test/scheduled-to-resolved`: create, immediately resolve;
  status is `:resolved`.
- `pending-test/scheduled-to-rejected`: create, reject; status is
  `:rejected`, reason matches.
- `pending-test/scheduled-to-cancelled`: create, cancel; on-cancel
  fires; status is `:cancelled`.
- `pending-test/running-to-streaming`: create, stream chunk; status is
  `:streaming` after.
- `pending-test/streaming-to-resolved-via-finish`: stream two chunks,
  stream-finish; status is `:resolved`, region text is concatenation.
- `pending-test/no-double-resolve`: resolve, then resolve again; second
  call returns nil; warning is captured; status remains `:resolved`.
- `pending-test/no-double-reject-after-resolve`: same but mixing
  resolve then reject.
- `pending-test/cancel-during-stream-runs-on-cancel`: stream a chunk,
  call `pending-cancel`; assert on-cancel was called once with the
  struct.

Marker survival:

- `pending-test/markers-survive-edit-before`: insert text before
  placeholder; assert `start`/`end` marker positions shifted by the
  edit length and the visible label is unchanged.
- `pending-test/markers-survive-edit-after`: insert text after; assert
  markers unchanged, post-region text moved.
- `pending-test/region-deletion-cancels`: do
  `(delete-region (1- (overlay-start ov)) (1+ (overlay-end ov)))`
  swallowing the placeholder; assert `pending-cancel` fired with
  `:region-deleted`.

Read-only:

- `pending-test/cannot-edit-placeholder`: try to `(insert ...)` inside
  the region; assert `text-read-only` error signaled.
- `pending-test/can-edit-around-placeholder`: insert before and after;
  assert no error.

Streaming:

- `pending-test/stream-append-correctness`: stream three chunks, assert
  `(buffer-substring start end)` equals the concatenation.
- `pending-test/stream-then-resolve-replaces`: stream "abc", then
  `pending-finish` with "xyz"; assert region text is "xyz".

Registry:

- `pending-test/registry-add-remove`: create N, assert
  `(hash-table-count pending--registry)` is N; resolve all, assert 0.
- `pending-test/buffer-registry-sync`: assert
  `pending--buffer-registry` length matches global count for that
  buffer.
- `pending-test/buffer-kill-cancels-all`: create 3 in a temp buffer,
  kill it; assert all 3 have status `:cancelled` with reason
  `:buffer-killed`.

Deadline:

- `pending-test/deadline-expires`: create with `:deadline 0.1`; wait
  via fast-forward; assert status is `:rejected` with reason
  `:timed-out`.

Cleanup:

- `pending-test/timer-stops-when-no-pending`: resolve all; assert
  `pending--global-timer` is nil after the next tick.
- `pending-test/overlay-deleted-on-resolve`: assert
  `(overlay-buffer ov)` is nil post-resolve.

### Fast-forward time

```elisp
(defmacro pending-test--with-mocked-time (&rest body)
  "Run BODY with `current-time' / `float-time' / `run-at-time'
mocked.  `(pending-test--advance SECONDS)' fires due timers."
  `(let ((pending-test--clock 0.0)
         (pending-test--scheduled nil))
     (cl-letf*
         (((symbol-function 'float-time)
           (lambda (&optional _) pending-test--clock))
          ((symbol-function 'run-at-time)
           (lambda (when repeat fn &rest args)
             (let ((due (if (numberp when)
                            (+ pending-test--clock when)
                          0)))
               (push (list due repeat fn args) pending-test--scheduled)
               (cons 'mock-timer (length pending-test--scheduled)))))
          ((symbol-function 'cancel-timer)
           (lambda (tm)
             (setq pending-test--scheduled
                   (cl-remove tm pending-test--scheduled :key #'car-safe))))
          ((symbol-function 'timerp)
           (lambda (x) (and (consp x) (eq (car x) 'mock-timer)))))
       ,@body)))
```

`pending-test--advance` walks the schedule, calling any function whose
`due <= clock`, repeating if `repeat` is non-nil.

### Manual demo

```elisp
;;;###autoload
(defun pending-demo ()
  "Set up several concurrent placeholders for visual inspection."
  (interactive)
  (let ((buf (get-buffer-create "*pending-demo*")))
    (pop-to-buffer buf)
    (erase-buffer)
    (insert "Demo: ")
    (my/pending-delay 3)
    (insert "  ")
    (my/pending-delay 8)
    (insert "  ")
    (let ((p (pending-make buf :label "Indeterminate" :indicator :spinner)))
      (run-at-time 12 nil (lambda () (pending-finish p "[done]"))))
    (insert "  ")
    (let ((p (pending-make buf :label "Determinate"
                               :indicator :percent :percent 0.0)))
      (dotimes (i 10)
        (run-at-time (* (1+ i) 1.0) nil
                     (lambda () (pending-update p :percent (/ (1+ i) 10.0))))))
    (newline)))
```

## 9. Risks and open questions

### Overlay performance with many placeholders

Per Emacs Lisp manual, overlay lookup at point is O(N) over overlays
in the buffer. For N=100 within one buffer, redisplay still walks
them. Mitigations:

- Document recommended ceiling: ~50 active placeholders per buffer.
- `overlay-priority` set high so we don't fight font-lock.
- Avoid `overlay-recenter` complications by keeping each overlay
  small.
- For pathological cases (e.g. user wants 1000 placeholders) we
  recommend using a single overlay and a custom display strategy —
  out of scope for v1.

### Org-pending name collision

`org-pending` (Org built-in) and `pending` (this library) coexist
fine because the prefixes differ. We mention `org-pending` in the
README. We should explicitly NOT name a function `pending-org-...`
that suggests integration unless we actually integrate.

### `visual-line-mode` and `display` strings

If we ever switched to a `display` string strategy (we won't — see
§4), `visual-line-mode` would treat the display value as a single
unit and could break wrapping. Using `before-string` / `after-string`
sidesteps the issue: those are layout-aware.

Caveat: a very long label may itself wrap mid-placeholder. We
truncate labels longer than `pending-label-max-width` (defcustom,
default 60) with an ellipsis. The full label is always available via
`help-echo` tooltip.

### Multi-window animation phase

If the same buffer is shown in two windows, both windows show the
same overlay. The spinner's frame index is per-region (struct slot),
not per-window. They animate in lock-step, which is fine and
cheaper than per-window.

### TUI vs GUI

- Text spinner works everywhere.
- SVG spinner only on `display-graphic-p`. v1 ships no SVG; v2 picks
  it up gated on `(image-type-available-p 'svg)`.
- `pending-fringe-bitmap` only meaningful in GUI; gracefully no-op in
  terminal.

### Read-only buffers

By default we refuse: `pending-make` signals
`pending-error` if `buffer-read-only` is non-nil. Caller can override
with `:allow-read-only t` (the function binds `inhibit-read-only`
during insert). `compilation-mode` and `gptel-mode` chat buffers
sometimes flip read-only; the consumer can supply the flag if they
own the buffer.

### Font / face availability

`pending-progress-face` defaults `:family "Menlo"` which may not
exist on Linux. Defcustom the family with a sensible fallback:
`pending-bar-family` defaults to nil meaning "use buffer face."
Ship without forced family in v1; document that variable-pitch users
may see misalignment.

## 10. Implementation plan

### Phase 1 — Skeleton (~120 LOC)

Goal: file builds; defgroup, defcustom, defface, struct, registry, ID
generator are in place. No interactive functionality yet.

Files: `pending.el`, `pending-pkg.el` (for package.el).

Deliverables:

- File header with `Package-Requires: ((emacs "27.1"))`.
- `(defgroup pending nil ...)`
- `defcustom`: `pending-fps`, `pending-bar-width`, `pending-default-spinner-style`,
  `pending-spinner-styles`, `pending-bar-family`, `pending-fringe-bitmap`,
  `pending-allow-read-only`, `pending-label-max-width`.
- `defface`: the five faces from §4.
- `cl-defstruct pending` with all slots.
- `pending--next-id`, `pending--gen-id`.
- `pending--registry` (hash), `pending--buffer-registry` (defvar-local).
- `(define-error 'pending-error ...)`.
- `(provide 'pending)`.

Exit: `M-x byte-compile-file pending.el` produces zero warnings;
`(require 'pending)` succeeds; `(make-pending--struct ...)` (or
whatever name `cl-defstruct` exposes) returns an instance.

Mimic from this repo: `gptel.el:1088` defface form pattern; gptel's
defcustom grouping under `gptel`.

### Phase 2 — Core lifecycle (~250 LOC)

Goal: create, resolve, reject, cancel work end-to-end with a *static*
label (no animation).

Files: `pending.el`.

Deliverables:

- `pending-make` (insert + adopt modes; without spinner timer yet).
- `pending--register`, `pending--unregister` keeping both registries
  synced.
- `pending-finish`, `pending-reject`, `pending-cancel`.
- `pending--swap-region` (atomic replacement).
- `pending-active-p`, `pending-status`, `pending-at`,
  `pending-list-active`.
- `pending-update` (just slot mutation; no re-render).
- `kill-buffer-hook` cancellation.
- Single-resolution guard.

Exit: ERT tests for the state-transition group all pass.

Mimic: gptel's start/tracking marker setup and insertion-type flips at
`gptel.el:1389, 1769-1794`; agent-shell-heartbeat's
started/busy/ended discipline at `agent-shell-heartbeat.el:78-92`.

### Phase 3 — Spinner animation (~120 LOC)

Goal: a placeholder shows a moving Unicode spinner.

Files: `pending.el`.

Deliverables:

- `pending--spinner-frames-text` defconst.
- `pending--global-timer`, `pending--ensure-timer`,
  `pending--tick`.
- `pending--render` placing `before-string` on the overlay.
- `pending--needs-redraw-p` visibility gate using `get-buffer-window`.
- `window-buffer-change-functions` hook to wake timer when buffer
  becomes visible.
- Frame index computed from elapsed wall-time, not tick count, so
  animations stay in sync across resumes.

Exit: `pending-demo` (a temporary version with one
`pending-make`) animates at ~10 fps when its buffer is visible, idle
when not; `(memq pending--global-timer timer-list)` is nil after the
last placeholder resolves.

Mimic: `agent-shell-active-message.el:38` cadence; spinner.el's
frame-vector approach (without the dep).

### Phase 4 — Determinate + ETA bars (~100 LOC)

Goal: `:percent` and `:eta` indicators render correctly.

Files: `pending.el`.

Deliverables:

- `pending--bar-blocks` defconst (eighth-block characters).
- `pending--render-bar` returning a propertized string of length
  `pending-bar-width`.
- ETA math from §4 (`pending--eta-fraction`).
- `:after-string` slot on the overlay.
- Render dispatch on `(pending-indicator p)`.

Exit: ERT tests for ETA monotonicity and asymptotic ceiling pass; the
demo with `:eta 8` visually fills smoothly to ~95% in 8 seconds.

### Phase 5 — Edit-survival (~80 LOC)

Goal: read-only enforcement; region-deletion auto-cancel.

Files: `pending.el`.

Deliverables:

- Read-only properties on inserted placeholder text via
  `add-text-properties`.
- `front-sticky (read-only)`, `rear-nonsticky (read-only)`.
- Overlay `modification-hooks`, `insert-in-front-hooks`,
  `insert-behind-hooks` calling `pending--on-modify`.
- `pending--on-modify` cancels on region collapse.

Exit: ERT marker-survival and read-only tests pass.

Mimic: gptel uses `inhibit-read-only` bindings — see
`gptel.el:1349, 544, 586` — same idiom we use in our `swap-region`.

### Phase 6 — Streaming (~80 LOC)

Goal: `pending-stream-insert` and `pending-stream-finish`.

Files: `pending.el`.

Deliverables:

- `pending-stream-insert` inserts at `end` marker, transitions to
  `:streaming`, leaves indicator visible.
- `pending-stream-finish` flips end marker insertion-type to nil,
  removes overlay decorations, transitions to `:resolved`.
- Streamed text is read-only (same properties as initial label).

Exit: ERT streaming tests pass; the gptel integration sketch from §7
works against a real `gptel-request`.

Mimic: `gptel.el:1769-1794` directly.

### Phase 7 — Process and timeout integration (~60 LOC)

Goal: `pending-attach-process` and deadline timers.

Files: `pending.el`.

Deliverables:

- `pending-attach-process`.
- `pending--process-sentinel`.
- `pending--start-deadline-timer`, deadline cleanup in
  `pending--unregister`.
- The shell + url-retrieve sketches from §7 work end-to-end.

Exit: ERT deadline-expiry test passes; manual smoke test with `sleep
2` shell command succeeds and a `:deadline 1` rejects with
`:timed-out`.

### Phase 8 — Interactive UI + lighter (~150 LOC)

Goal: `pending-list`, `pending-cancel-at-point`, mode-line lighter.

Files: `pending.el`.

Deliverables:

- `pending-list` using `tabulated-list-mode`. Columns: ID, Buffer,
  Label, Status, Elapsed, ETA, Group.
- `pending-list-mode` keymap: `g` refresh, `RET` jump, `c` cancel,
  `q` quit.
- `pending-cancel-at-point` using `pending-at`.
- `pending-mode-line-string` returning `" [3⏳~12s]"` style; opt-in
  via `(global-pending-lighter-mode)` minor mode that adds the
  function to `global-mode-string`.
- `pending-region-map` binding `RET` and `[mouse-1]` to
  `pending-cancel-at-point`.

Exit: `M-x pending-list` opens a buffer with current placeholders;
`c` on a row cancels and refreshes; lighter shows count and nearest
ETA.

### Phase 9 — Tests, demo, README, packaging (~ test 300 LOC + docs)

Goal: ship-ready library.

Files: `pending-test.el`, `README.org`, `pending.el`
(autoloads/comment headers), `Makefile`, `Eask`.

Deliverables:

- ERT test file with all the named tests in §8 (target: ≥90%
  coverage of public functions).
- `pending-demo` polished as in §8.
- README with §1-§7 condensed, integration recipes, comparison with
  `org-pending`.
- `;;;###autoload` cookies on `pending-make`, `pending-list`,
  `pending-cancel-at-point`, `pending-demo`,
  `global-pending-lighter-mode`.
- `Makefile` with `compile`, `test`, `clean` targets — copying the
  shape used by other packages here (e.g. `use-package/Makefile`).
- `Eask` file: declare package, deps `(emacs "27.1")`, scripts
  `compile`, `test`.
- Tag a `0.1.0` release.

Exit: `eask compile` clean; `eask test ert pending-test.el` all
green; README renders; `M-x pending-demo` looks correct on light and
dark themes; library installable via `package-vc-install` from the
repo URL.
