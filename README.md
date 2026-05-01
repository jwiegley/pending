# pending

I've been using `gptel` heavily for a while now, and one thing keeps
bothering me: the moment I send a request, the buffer just sits there.
No indication that anything's happening, no marker for *where* the
answer will land. If I then go edit somewhere else and the response
comes back, sometimes it lands in the wrong place. Sometimes I forget
I asked anything at all.

So I wrote `pending`. It marks a region (or a single point) as "the
answer goes here, hold tight," shows a small animated lighter while the
async work runs, and then atomically swaps the placeholder for the
result. One undo step. The placeholder text is read-only while it's
active, so I can't accidentally type into it. If I delete it, the
underlying request gets cancelled too.

```text
Calling Claude  ⠋ [████████░░░░░░░░] 47%
```

**v0.2.0 — Emacs 27.1+ — BSD-3-Clause**

## At a glance

```elisp
;; Mark point as "we'll fill this in shortly," kick off gptel, let
;; the placeholder sit in the buffer until the response comes back.

(let ((tok (pending-insert (point) "Calling Claude")))
  (gptel-request "Tell me a joke."
   :callback (lambda (response _info)
               (if (stringp response)
                   (pending-finish tok response)
                 (pending-cancel tok)))))
```

While the request is active, a bold red `Calling Claude` lighter
sits at point. A spinner animates beside it. When the callback fires,
the lighter and spinner go away and the response text takes their
place. Everything happens as one undo step.

## Why I wrote it

A few things weren't working for me:

- **Visible async**: I want to see *where* the answer will land and
  *that* something is happening. No silent five-second wait staring
  at a static buffer.
- **Atomic swap**: replacement is one undo step. No torn intermediate
  states where half the response is in the buffer and half isn't.
- **Edit-survival**: while active, the placeholder body is read-only.
  Edits before and after adjust the placeholder's markers
  automatically. If I do delete the region outright, the placeholder
  cancels itself.
- **Backend-agnostic**: it doesn't know or care about gptel. Works
  with `make-process`, `url-retrieve`, plain timers — anything
  callback-driven.
- **One global timer**: ten frames per second, single timer, walks
  the registry once per tick. N pending regions don't mean N timers.

## Installation

`pending` needs Emacs 27.1 or newer. No third-party runtime
dependencies.

### `package-vc-install` from GitHub

```elisp
(package-vc-install
 '(pending :url "https://github.com/jwiegley/pending"))
```

### `package-vc-install` from a local checkout

```elisp
(package-vc-install-from-checkout "/path/to/pending" "pending")
```

### `use-package`

```elisp
(use-package pending
  :vc (:url "https://github.com/jwiegley/pending")
  :commands (pending-make pending-region pending-insert
             pending-finish pending-cancel pending-list
             pending-demo)
  :config
  (global-pending-lighter-mode 1))
```

### Manual

Drop `pending.el` somewhere on `load-path` and `(require 'pending)`.

## Quick start

### Mark a region for rewrite

```elisp
;; Mark the current line as being rewritten asynchronously.
(let ((tok (pending-region (line-beginning-position)
                           (line-end-position)
                           "rewriting")))
  ;; ... do work ...
  (pending-finish tok "the new text"))
```

### Mark a single point for insertion

```elisp
;; Insert at point when the answer arrives.
(let ((tok (pending-insert (point) "Calling Claude")))
  (run-at-time 2 nil (lambda () (pending-finish tok "Hello!"))))
```

### Cancel from point

Move point onto a placeholder and run `M-x pending-cancel-at-point`.
It's also bound to `RET` and `mouse-1` over the placeholder.

### Show the lighter

```elisp
M-x global-pending-lighter-mode
```

The mode-line gains a small `[N⏳~Ks]` summary while any placeholders
are active. Click it to open `M-x pending-list`.

## Concepts

### Tokens

Every constructor returns a *token* — a `pending` struct used as a
handle. Pass it to `pending-finish`, `pending-cancel`,
`pending-update`, and friends. Tokens are valid until they hit a
terminal state (`:resolved`, `:rejected`, `:cancelled`, `:expired`);
after that, all operations are no-ops (with a `:debug` warning, so
you can spot accidental late calls).

### The registry

All active placeholders live in a global registry. Snapshot it with
`pending-alist` (returns `((ID . STRUCT) ...)`) or filter it with
`pending-list-active` (which honours `:buffer` and `:group`). The
registry also feeds `M-x pending-list` and the mode-line lighter.

### Lighter vs region highlight

There are two visual treatments, and I keep them distinct:

- **Region highlight** — when the overlay covers existing buffer
  text (adopt mode `pending-region BEG END STR` with `BEG < END`),
  the overlay carries `pending-highlight` as its `face`. That's so
  the user can see *which* characters the async work will rewrite.
  In insert mode and zero-width adopt mode, the overlay has no face
  — there's no pre-existing region to highlight.
- **Lighter** — a small bold badge (face `pending-lighter`) attached
  to the overlay's `before-string`. This is the prominent visual
  marker.

The simple API uses a static lighter (`:lighter` indicator). The rich
API can substitute an animated spinner, a determinate bar, or an ETA
bar in place of the static lighter.

The library never adds a `face` text property to text it inserts
itself. Labels, streamed chunks, and resolution / rejection /
cancellation replacement text all land in the buffer as plain text,
so the surrounding font-lock and major-mode faces apply normally.
Only the overlay (in adopt mode with a non-empty range) and the
overlay's `before-string` lighter / `after-string` progress bar are
faced. This was a deliberate decision: I don't want a generic library
fighting with the user's syntax highlighting.

### Read-only protection

While a placeholder is active, its inserted text is read-only via
text properties (`read-only t`, `front-sticky '(read-only)`,
`rear-nonsticky '(read-only)`). The user can edit before and after
freely, but can't edit the body. The library binds
`inhibit-read-only` during its own operations so the internal swaps
still work.

In *adopt mode* (`pending-make` with explicit `:start` and `:end`),
the library by default applies the same read-only properties to the
adopted text — gated on `pending-protect-adopted-region` (default
`t`). Set the option to nil to opt out and leave the adopted text
editable. The text-property-based protection lives in the buffer
text itself, so it is inherited by indirect buffers (made via
`make-indirect-buffer`) — this is the trick org-pending uses for
its own indirect-buffer projection. The properties disappear
naturally on resolve/reject/cancel because the swap deletes the
protected text. In *insert mode* (no `:start`/`:end`) and during
streaming, all inserted text is protected unconditionally.

### Auto-cancellation paths

A few edge conditions auto-cancel an active placeholder so it
can't strand state:

- **Region deletion** — if the user deletes the entire placeholder
  region, the overlay collapses to zero length and a
  `modification-hook` cancels with reason `:region-deleted`.
- **Buffer kill** — `kill-buffer-hook` walks the buffer's pending
  registry and cancels each one with reason `:buffer-killed`.
- **Deadline** — when `pending-make` is called with `:deadline N`,
  a one-shot timer fires `pending-reject` with `:timed-out` if the
  placeholder is still active after `N` seconds.
- **Process death** — `pending-attach-process` wraps the process
  sentinel; non-clean exit (or clean exit without an explicit
  resolve) rejects with a reason derived from `process-status`.
- **Emacs exit** — when `pending-confirm-on-emacs-exit` is non-nil
  and active placeholders exist, `kill-emacs-query-functions`
  prompts before exit.

## The simple API

### `pending-region BEG END STR`

```elisp
(pending-region BEG END STR)  ; constructor
(pending-region TOKEN)        ; back-compat accessor
```

Mark the region `[BEG, END]` in the current buffer as pending an
async change. When `BEG < END`, the overlay covers existing buffer
text and is faced with `pending-highlight` (the underlying buffer
text is untouched — only the overlay carries a face). `STR` shows
as a lighter badge at `BEG` via the overlay's `before-string`.
Returns a token.

If `BEG` equals `END`, the region is empty and only the lighter
shows — equivalent to `pending-insert`. In that case the overlay
carries no face. The 1-arg form returns the token's overlay
(back-compat with the auto-generated accessor name).

```elisp
(let ((tok (pending-region (region-beginning) (region-end)
                           "summarising")))
  (gptel-request (buffer-substring (region-beginning) (region-end))
   :callback (lambda (text _) (pending-finish tok text))))
```

### `pending-insert POS STR`

```elisp
(pending-insert POS STR)
```

Mark `POS` as pending insertion. No region is highlighted (BEG = END);
only the lighter `STR` shows. Returns a token. When eventually
resolved, the text is inserted at `POS`.

```elisp
(pending-insert (point) "fetching weather")
```

### `pending-finish TOKEN TEXT`

Atomically replace `TOKEN`'s region with `TEXT`. Transition to
`:resolved`. Returns t on success, nil if `TOKEN` was already in a
terminal state.

```elisp
(pending-finish tok "Hello, world!")
```

### `pending-cancel TOKEN &optional REASON`

Cancel `TOKEN`. Calls the placeholder's `:on-cancel` callback first
(so the caller can abort underlying work — kill a process, abort a
gptel request), then replaces the region with a small cancelled
glyph (`✗ REASON`). The inserted glyph is plain text — no `face` is
applied. Default `REASON` is `:cancelled-by-user`.

```elisp
(pending-cancel tok)              ; cancelled-by-user
(pending-cancel tok :timed-out)   ; explicit reason
```

### `pending-goto TOKEN`

Move point to `TOKEN`'s start position, switching buffers if
necessary. Interactively, prompts via `completing-read` over the
registered placeholders.

```elisp
M-x pending-goto RET <pick from list> RET
```

### `pending-list`

Interactive command. Opens the `*Pending*` tabulated-list buffer
showing every registered placeholder. Columns: ID, Buffer, Label,
Status, Elapsed, ETA, Group. Bindings: `g` refresh, `RET` jump,
`c` cancel, `q` quit.

### `pending-alist`

Returns a fresh alist `((ID . STRUCT) ...)` snapshot of the registry.
Useful for programmatic queries.

```elisp
(length (pending-alist))                                   ; how many
(mapcar (lambda (cell) (pending-label (cdr cell)))         ; all labels
        (pending-alist))
```

### `pending-cancel-at-point`

Interactive. Cancel the placeholder under point. Bound to `RET` and
`mouse-1` over a placeholder by `pending-region-map`.

## The rich API

### `pending-make BUFFER &key ...`

The full constructor. Inserts (or adopts) a placeholder with a wide
keyword surface.

```elisp
(pending-make BUFFER
              &key label start end indicator deadline eta percent
                   face spinner-style on-cancel on-resolve group)
```

Keyword reference:

| Keyword           | Meaning                                                                                  |
|-------------------|------------------------------------------------------------------------------------------|
| `:label`          | Short string shown in the placeholder. Default `"Pending"`.                              |
| `:start` `:end`   | Adopt mode: take over an existing region. Both or neither.                               |
| `:indicator`      | `:spinner` (default), `:percent`, `:eta`, or `:lighter` (static badge).                  |
| `:percent`        | Initial fraction in `[0.0, 1.0]` for `:percent` mode.                                    |
| `:eta`            | Estimated total seconds for `:eta` mode (asymptotes to ~95% at this time).               |
| `:deadline`       | Wall-clock seconds until auto-rejection with reason `:timed-out`.                        |
| `:face`           | Override `pending-face` for the OVERLAY's `face` property in adopt mode (BEG < END only). Inserted text is never faced. |
| `:spinner-style`  | Key into `pending-spinner-styles`.                                                       |
| `:on-cancel`      | Function `(P)` called *before* status flips to `:cancelled`. Abort underlying work here. |
| `:on-resolve`     | Function `(P)` called once on transition to any terminal state.                          |
| `:group`          | Symbol for filtering via `pending-list-active`.                                          |

Insert mode vs adopt mode:

- **Insert mode** (no `:start`/`:end`) — inserts a new placeholder
  at point in `BUFFER`. The label text is propertized read-only.
- **Adopt mode** (both `:start` and `:end`) — takes over the
  existing region without inserting text. By default the adopted
  region becomes read-only while the placeholder is active
  (controllable via `pending-protect-adopted-region`). Set that
  defcustom to nil to leave the adopted text editable, matching
  the v0.1.0 behaviour.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :indicator :spinner
              :on-cancel (lambda (_) (gptel-abort)))
```

### `pending-update P &key label percent eta indicator`

Mutate slots while active without changing state. Useful when the
caller learns more about progress — switch from `:spinner` to
`:percent` once the total work size is known.

```elisp
(pending-update tok :percent 0.42)
(pending-update tok :indicator :eta :eta 10.0)
```

### `pending-stream-insert P CHUNK`

Append `CHUNK` (a string) to `P`'s region. The first chunk replaces
the loading label and transitions to `:streaming`; subsequent chunks
append at the end marker (which has insertion-type `t` while
streaming, so it advances with the insert).

The streamed text is read-only while streaming, but carries no
`face` — the buffer's normal font-lock applies. Animation continues
uninterrupted.

```elisp
(pending-stream-insert tok "Once upon a time, ")
(pending-stream-insert tok "in a faraway land...")
```

### `pending-stream-finish P`

Finalize a streamed placeholder: flip the end marker's
insertion-type back to nil, strip read-only properties, remove the
overlay, fire `:on-resolve`. The buffer text is left as-is (it
already holds the streamed content).

```elisp
(pending-stream-finish tok)
```

If `P` never received a chunk (status is `:scheduled` or
`:running`), this is equivalent to `(pending-finish P "")`.

### `pending-reject P REASON &optional REPLACEMENT-TEXT`

Mark `P` as failed. `REASON` is a string or symbol.
`REPLACEMENT-TEXT` defaults to `"✗ REASON"`. Plain text — no `face`
applied; surrounding font-lock applies normally.

```elisp
(pending-reject tok "API rate limit exceeded")
(pending-reject tok :network-down "Try again later.")
```

### `pending-attach-process P PROCESS`

Wire `PROCESS` so its death rejects `P` automatically. Wraps the
process sentinel; any caller-installed sentinel runs first, then a
wrapper inspects `process-status` and calls `pending-reject` on
non-clean exit. The reason is derived from the live process status,
which survives localized event strings (so the test still works
in a non-English locale).

```elisp
(let ((proc (start-process "build" nil "make")))
  (pending-attach-process tok proc))
```

### `pending-active-p P`

Non-nil if `P` is in an active state: `:scheduled`, `:running`, or
`:streaming`.

### `pending-status P`

Returns the current status keyword.

### `pending-at &optional POS BUFFER`

Returns the pending struct at `POS` (default point) in `BUFFER`
(default current buffer), or nil.

## Indicator modes

Pick a visual via `:indicator` to `pending-make`. The simple
positional API always uses `:lighter`; the rich API defaults to
`:spinner`.

| Indicator   | Visual                                                  | Use when                                                 |
|-------------|---------------------------------------------------------|----------------------------------------------------------|
| `:spinner`  | Animated glyph + label (default).                       | Duration unknown, but the library should look alive.     |
| `:percent`  | Spinner glyph + bar + percent.                          | Caller can supply a fraction in `[0.0, 1.0]`.            |
| `:eta`      | Spinner glyph + bar + remaining-seconds estimate.       | Caller has a rough guess at total wall-clock seconds.    |
| `:lighter`  | Static badge (`pending-lighter` face). No animation.    | Visual marker only; no progress to convey.               |

What it looks like (terminal):

```text
:spinner    Calling Claude  ⠋
:percent    Generating  ⠙ [████████░░░░░░░░] 47%
:eta        Downloading  ⠹ [████████████░░░░] ~3s
:lighter    Calling Claude
```

`:eta` uses a piecewise-asymptotic formula that hits 80% at
`t = 0.8 × ETA`, 95% at `t = ETA`, and saturates toward (but never
reaches) 100% past the deadline. That's deliberate — I find the
"100% but still working" effect actively annoying, so I designed
this one to never hit 100% until it actually finishes.

On graphical frames where SVG is compiled into Emacs (the common
case), the spinner glyph is rendered as a small rotating SVG arc
via `svg.el`. This is enabled by default through
`pending-svg-spinner-enable` and gated on `(display-graphic-p)`
plus `(image-type-available-p 'svg)`; the cache key is `(face
style frame-index size)` and is cleared when
`pending-svg-spinner-size` changes. TTYs and SVG-less builds
fall back automatically to the Unicode text glyph.

## Integration recipes

### gptel — streaming response

```elisp
(defun my/gptel-pending-stream (prompt)
  "Send PROMPT via gptel; stream the response into a pending placeholder."
  (let ((p (pending-make (current-buffer)
                         :label "Calling Claude"
                         :indicator :spinner
                         :on-cancel (lambda (_)
                                      (gptel-abort (current-buffer))))))
    (gptel-request
     prompt
     :stream t
     :position (pending-end p)
     :callback (lambda (chunk info)
                 (cond
                  ((stringp chunk) (pending-stream-insert p chunk))
                  ((plist-get info :error)
                   (pending-reject p (plist-get info :error)))
                  (t (pending-stream-finish p)))))
    p))
```

### gptel — non-streaming response (callback)

```elisp
(defun my/gptel-pending-call (prompt)
  "Send PROMPT via gptel; replace the pending placeholder with the response."
  (let ((p (pending-insert (point) "Calling Claude")))
    (gptel-request
     prompt
     :callback (lambda (response info)
                 (cond
                  ((stringp response) (pending-finish p response))
                  ((plist-get info :error)
                   (pending-reject p (plist-get info :error)))
                  (t (pending-cancel p)))))
    p))
```

### `make-process` — capture stdout into a pending region

```elisp
(defun my/run-shell-pending (cmd)
  "Run CMD in a shell; stream stdout into a pending placeholder."
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

### `url-retrieve` — async fetch

```elisp
(defun my/fetch-pending (url)
  "GET URL; replace the pending placeholder with its body."
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

### Pure-delay timer (tests/demos)

```elisp
(defun my/delay-pending (seconds text)
  "Show a pending placeholder; replace with TEXT after SECONDS."
  (let ((p (pending-insert (point) (format "wait %ds" seconds))))
    (run-at-time seconds nil
                 (lambda ()
                   (when (pending-active-p p)
                     (pending-finish p text))))
    p))
```

### Generic callback-driven async (template)

```elisp
(defun my/with-pending (label callback)
  "Show a pending placeholder labelled LABEL.
CALLBACK is called with the token; it must arrange to call
`pending-finish' or `pending-reject' on the token."
  (let ((p (pending-make (current-buffer)
                         :label label
                         :indicator :spinner)))
    (funcall callback p)
    p))
```

## Mode-line lighter

`global-pending-lighter-mode` is a global minor mode. Enable it and
a small construct gets appended to `global-mode-string`:

```text
 [3⏳~5s]
```

— meaning *3 active placeholders; the smallest remaining ETA across
them is approximately 5 seconds*. When no placeholder has an ETA in
the future, the trailing tilde-segment goes away: `[3⏳]`. When no
placeholders are active, the lighter is hidden entirely.

The lighter is propertized with `pending-spinner-face`, carries a
help-echo tooltip, and binds `mouse-1` to `pending-list` so a click
opens the list buffer.

The construct calls `pending-mode-line-string` on each redisplay
to compute the live text. Callers wiring the lighter into a custom
mode-line construct directly can use that function; it returns nil
when no placeholders are active so the segment disappears
naturally.

```elisp
(global-pending-lighter-mode 1)
```

## The `*Pending*` buffer

`M-x pending-list` opens a tabulated-list view, one row per
registered placeholder.

| Column   | Width | Sort | Meaning                                   |
|----------|-------|------|-------------------------------------------|
| ID       | 16    | yes  | Generated symbol name (`pending-N`).      |
| Buffer   | 24    | yes  | Buffer hosting the placeholder.           |
| Label    | 30    | yes  | The label string, truncated.              |
| Status   | 12    | yes  | Status keyword, e.g. `:streaming`.        |
| Elapsed  | 8     | yes  | Wall-clock seconds since creation.        |
| ETA      | 8     | yes  | The placeholder's ETA, or `-`.            |
| Group    | 10    | yes  | The placeholder's group symbol, or `-`.   |

Bindings:

| Key   | Command                  | Effect                                   |
|-------|--------------------------|------------------------------------------|
| `g`   | `pending-list-refresh`   | Re-read the registry.                    |
| `RET` | `pending-list-jump`      | Pop to the placeholder's buffer.         |
| `c`   | `pending-list-cancel`    | Cancel; reason `:cancelled-from-list`.   |
| `?`   | `pending-list-describe`  | Open `*Pending: ID*` description buffer. |
| `q`   | `quit-window`            | Bury the buffer.                         |

The list auto-refreshes when the registry mutates (controlled by
`pending-list-auto-refresh`); pressing `g` is still available for
explicit refresh.

## Describing a single placeholder

`M-x pending-describe` (or `?` from the `*Pending*` list)
opens a `*Pending: ID*` buffer in `pending-description-mode`
showing structured details about one placeholder: token id,
label, status, reason, owner buffer, group, indicator type and
per-mode state (eta / percent / deadline / spinner-style),
schedule and resolve timestamps, elapsed wall-clock seconds,
on-cancel and on-resolve callback wiring, and any attached
process. Modeled on `org-pending`'s `org-pending-describe-reglock`.

Bindings inside the description buffer:

| Key   | Command                     | Effect                                       |
|-------|-----------------------------|----------------------------------------------|
| `g`   | `pending-describe-refresh`  | Re-render from the live token slots.         |
| `RET` | `pending-describe-jump`     | Pop to the placeholder's buffer.             |
| `c`   | `pending-describe-cancel`   | Cancel; reason `:cancelled-from-describe`.   |
| `q`   | `quit-window`               | Bury the buffer.                             |

## Customization

| Variable                          | Default      | Effect                                                                  |
|-----------------------------------|--------------|-------------------------------------------------------------------------|
| `pending-fps`                     | `10`         | Animation frame rate. The single global timer ticks at `1/fps` seconds. |
| `pending-bar-width`               | `16`         | Width in cells of the `:percent` and `:eta` progress bars.              |
| `pending-default-spinner-style`   | `'dots-1`    | Default key into `pending-spinner-styles`.                              |
| `pending-spinner-styles`          | (see source) | Alist mapping style symbols to vectors of frame strings.                |
| `pending-bar-style`               | `'eighths`   | Bar character set: `eighths` (Unicode) or `ascii`.                      |
| `pending-allow-read-only`         | `nil`        | When non-nil, placeholders may be placed in read-only buffers.          |
| `pending-label-max-width`         | `60`         | Maximum visible label width; longer labels are truncated.               |
| `pending-confirm-on-emacs-exit`   | `nil`        | When non-nil, prompt before exit while placeholders are active.         |
| `pending-list-auto-refresh`       | `t`          | When non-nil, debounce-refresh the `*Pending*` list buffer on registry mutation. |
| `pending-pulse-on-resolve`        | `t`          | When non-nil, briefly flash the resolved region via `pulse.el` on `:resolved`. |
| `pending-fringe-bitmap`           | `nil`        | Symbol naming a registered fringe bitmap to render as a left-fringe cue beside each placeholder; nil disables. |
| `pending-svg-spinner-enable`      | `t`          | On graphical frames with SVG support, render the spinner as an SVG.    |
| `pending-svg-spinner-size`        | `16`         | Pixel size of the SVG spinner image (square).                          |
| `pending-protect-adopted-region`  | `t`          | In adopt mode, freeze the existing region with read-only text properties (which project into indirect buffers). |

Spinner styles ship with: `dots-1`, `dots-2`, `line`, `arc`,
`clock`. Add your own:

```elisp
(add-to-list 'pending-spinner-styles
             '(my-style . ["a" "b" "c"]))
```

## Faces

The library never adds a `face` text property to text it inserts
itself. Faces are applied only to overlay properties — the overlay's
`face` (when adopting an existing region), the overlay's
`before-string` lighter, and the overlay's `after-string` progress
bar. The surrounding buffer's font-lock is never disturbed.

| Face                       | Role                                                          |
|----------------------------|---------------------------------------------------------------|
| `pending-highlight`        | Overlay `face` for adopt-mode placeholders covering existing buffer text (`BEG < END`). |
| `pending-lighter`          | Lighter badge in the overlay's `before-string`. White on red. |
| `pending-face`             | Default value of `pending-make`'s `:face` keyword; inherits from `pending-highlight`. |
| `pending-spinner-face`     | Spinner glyph in the `before-string`.                         |
| `pending-progress-face`    | Bar and ETA text in the `after-string`.                       |
| `pending-error-face`       | Retained for backward compatibility (no longer applied to inserted text). |
| `pending-cancelled-face`   | Retained for backward compatibility (no longer applied to inserted text). |

## Hooks and lifecycle callbacks

### `:on-cancel` (per-placeholder)

Called *before* the cancellation pipeline runs. Abort underlying
work here — kill processes, abort gptel requests, cancel timers.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :on-cancel (lambda (p)
                           (gptel-abort (pending-buffer p))))
```

If `:on-cancel` signals an error or `quit`, the cancel pipeline
catches it and proceeds; the placeholder can't get stranded. I went
back and forth on this one — letting an `:on-cancel` error abort
the cancel felt more honest, but in practice it leaves zombies in
the buffer when the underlying API has already changed shape under
you. Catching wins.

### `:on-resolve` (per-placeholder)

Called *once* on transition to any terminal state (`:resolved`,
`:rejected`, `:cancelled`, `:expired`). Inspect
`(pending-status p)` inside the callback to differentiate.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :on-resolve (lambda (p)
                            (message "Done: %s -> %s"
                                     (pending-label p)
                                     (pending-status p))))
```

### Global hooks the library installs

- `kill-buffer-hook` (buffer-local) — cancels every placeholder in
  the buffer being killed with reason `:buffer-killed`.
- `kill-emacs-query-functions` — when
  `pending-confirm-on-emacs-exit` is non-nil, prompts before exit
  if active placeholders exist.
- `window-buffer-change-functions` — re-arms the parked animation
  timer when a placeholder's buffer becomes visible.

`pending-unload-function` cleans up the timer and removes the
global hooks on `unload-feature`.

## Promise adapter for `aio` users

`pending-aio.el` is an optional add-on that turns a `pending` token
into an [`aio`][aio] promise, so coroutine-based callers can
`aio-await` a placeholder's resolution. It is gated behind an
explicit `(require 'pending-aio)` and depends on `aio` — the main
`pending` package does not pull `aio` in.

```elisp
(require 'pending-aio)

(aio-defun my-async-fn ()
  (let* ((token (pending-make (current-buffer) :label "Working"))
         (resolved (aio-await (pending-as-promise token))))
    ;; ...do work that eventually calls
    ;; (pending-finish token "result")...
    (message "Token %s ended with status %s"
             (pending-id resolved)
             (pending-status resolved))))
```

`pending-as-promise TOKEN` returns an `aio-promise' that resolves
with `TOKEN' itself once the placeholder reaches any terminal
state (`:resolved`, `:rejected`, `:cancelled`, `:expired`). If
`TOKEN' is already terminal at call time, the returned promise is
pre-resolved. The adapter chains itself onto the token's
`:on-resolve' slot, so any pre-existing handler still fires.

[aio]: https://github.com/skeeto/emacs-aio

## Comparison with `org-pending`

Bruno Barbier's [`org-pending`][1] is a closely related upstream
Org patch that nevertheless declares itself independent of Org
mode. It solves a similar problem from a different angle. The table
is a condensed version of `RESEARCH.md` §1.

| Aspect            | `org-pending`                                | `pending`                                                |
|-------------------|----------------------------------------------|----------------------------------------------------------|
| Distribution      | Org-mode patch (`bba-pending-contents`)      | Standalone library                                       |
| Org dependency    | None — but the namespace and prefix imply Org | None                                                     |
| State machine     | `:scheduled → :pending → :success/:failure`  | Adds `:running`, `:streaming`, `:cancelled`, `:expired`  |
| Animation         | Static Unicode glyph                         | Animated spinner (10 fps, single global timer)           |
| Progress bar      | Single line of text in `after-string`        | Eighth-block Unicode bar (or ASCII fallback)             |
| Streaming         | Message-passing via `org-pending-send-update`| First-class `pending-stream-insert` / `-stream-finish`   |
| Description UI    | `*Region Lock*` describe buffer              | Tabulated list (`pending-list`) plus per-token `pending-describe` buffer |
| Indirect buffers  | Read-only projection                         | Yes — adopt-mode read-only properties live on buffer text and project |
| Kill-emacs query  | Built in (`kill-emacs-query-functions`)      | Same hook, gated by `pending-confirm-on-emacs-exit`      |

The two libraries can coexist. Pick whichever suits your caller:
if you live in Org and want minimal animation, prefer
`org-pending`; if you want streaming and progress visualization
out of the box, prefer this one.

[1]: https://framagit.org/brubar/org-mode-mirror/-/tree/bba-pending-contents

## Caveats

- **About 50 placeholders per buffer is the sweet spot.** Each
  placeholder is an overlay, and overlays have O(n) scan cost for
  some buffer operations. Keep concurrent counts modest. I haven't
  hit any actual problem in practice, but the cost is real.
- **Variable-pitch alignment.** The `:percent` and `:eta` bars
  assume a monospaced cell width. Under variable-pitch buffer
  faces, the bar may look ragged. Customise `pending-progress-face`
  with a `:family` attribute pointing at a fixed-pitch family to
  compensate.
- **Overlay scope.** A placeholder's overlay lives in one buffer.
  v0.2 projects the read-only text properties into indirect
  buffers (gated on `pending-protect-adopted-region`), but the
  visible overlay decoration (spinner, lighter, progress bar) only
  appears in the host buffer.
- **No cross-buffer multi-region pending.** A single pending
  struct represents one contiguous region in one buffer.
  Coordinate multiple related placeholders via the `:group`
  keyword and `pending-list-active`.

## Roadmap

Landed in v0.2.0:

- Auto-refresh of `*Pending*` on registry mutation.
- Pulse-on-resolve flash via `pulse.el`.
- Fringe bitmap indicator beside the placeholder.
- SVG spinner for graphical frames.
- `*Region Lock*`-style description buffer for a single
  placeholder (`pending-describe`).
- Indirect-buffer projection of read-only properties (gated on
  `pending-protect-adopted-region`).
- `pending-as-promise` adapter for `aio` users (optional add-on
  in `pending-aio.el`).

Still on the roadmap:

- Group operations (`pending-cancel-group`).

## Development

This package uses [Eask] for build automation, with a Makefile
wrapper. A [Nix] flake provides a reproducible dev shell, and
[lefthook] runs the same checks on each commit. The CI runs the
full suite on a matrix of Emacs 28.2 / 29.4 / 30.1 / snapshot.

### Quick start

```bash
# Enter the dev shell (Emacs + eask + texinfo + lefthook + ...)
nix develop

# Wire up the pre-commit hooks (one-time)
lefthook install

# Run the CI suite once locally
make all-checks
```

### Common targets

```bash
# Install dependencies
eask install-deps

# Compile (warning-free)
eask compile

# Run tests (117 ERT tests across pending-test.el and pending-aio-test.el)
eask test ert pending-test.el pending-aio-test.el

# All-in-one via Make
make compile
make test
make docs           # build doc/pending.info
make lint           # package-lint + checkdoc + byte-compile -W=error
make format-check   # reproducible indent-region check
make coverage       # ERT under undercover.el; baseline in .coverage-baseline
make profile        # microbenchmarks; baseline in .perf-baseline
make all-checks     # the whole suite
make clean
```

### Pre-commit checks

`lefthook.yml` runs the same checks in parallel on each commit:
byte-compile, tests, lint, format-check, checkdoc, docs-build,
coverage, profile, `nix flake check`, the byte-compile flake
output, `shellcheck`, and `shfmt`. Run `lefthook install` once
after cloning to wire up the git hook.

For a one-off run without committing:

```bash
lefthook run pre-commit
```

[Eask]: https://github.com/emacs-eask/cli
[Nix]:  https://nixos.org/
[lefthook]: https://github.com/evilmartians/lefthook

### Generating the manual

The Texinfo source lives at `doc/pending.texi`; the built
`pending.info` ships in the package.

```bash
make info       # build doc/pending.info
make html       # build doc/pending.html (preview)
make clean-docs
```

### Interactive development

```elisp
;; Reload the library after editing
(unload-feature 'pending t)
(load-file "pending.el")

;; Run a single test
M-x ert RET pending-test/scheduled-to-resolved RET

;; Open the demo
M-x pending-demo
```

## Contributing

Bug reports and pull requests are welcome via GitHub. When filing
an issue, please include:

- Emacs version (`M-x emacs-version`).
- Whether you're running graphical or terminal Emacs.
- Steps to reproduce.
- A backtrace if the bug manifests as an error.

When sending a PR, please:

- Match the existing code style: lexical binding, `--` for internal
  symbols, real docstrings on every public function.
- Add ERT tests for new behaviour.
- Ensure `eask compile` is warning-free and `eask test` is green.
- Run `M-x checkdoc` on touched files.

## License

BSD 3-Clause. See [LICENSE.md](LICENSE.md).

## Acknowledgments

- **`org-pending`** (Bruno Barbier) — prior art and design
  vocabulary; see `RESEARCH.md` for a detailed comparison.
- **`gptel`** (karthink) — marker discipline (`gptel.el:1389,
  1794`) directly inspired the streaming end-marker
  insertion-type flip.
- **`agent-shell`** — the active-message lifecycle pattern in
  `agent-shell-active-message.el` informed the global animation
  timer.
- **`spinner.el`** (Artur Malabarba) — Unicode spinner frame sets
  carried forward as `pending-spinner-styles`.
