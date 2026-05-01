# pending

A standalone Emacs Lisp library for marking buffer regions whose
content will arrive asynchronously. Insert a colored placeholder where
some asynchronously computed text is going to appear, optionally with
a spinner or progress bar, then atomically replace it with the result
when ready.

```text
Calling Claude  ⠋ [████████░░░░░░░░] 47%
```

**v0.1.0 — Emacs 27.1+ — GPL-3.0-or-later**

## At a glance

```elisp
;; Mark the current point as "we'll fill this in shortly", kick off
;; gptel, and let the placeholder live in the buffer until the
;; response comes back.

(let ((tok (pending-insert (point) "Calling Claude")))
  (gptel-request "Tell me a joke."
   :callback (lambda (response _info)
               (if (stringp response)
                   (pending-resolve tok response)
                 (pending-cancel tok)))))
```

While the request is in flight, the buffer shows a bold red
`Calling Claude` lighter at point. A spinner animates beside it. When
the callback fires, the lighter and spinner disappear and the
response text takes their place — atomically, undoably as one step.

## Why pending?

- **Visible async**: users see immediately *where* the answer will land
  and *that* something is happening. No silent five-second wait while
  staring at a static buffer.
- **Atomic resolution**: the swap from placeholder to result is one
  undo step. No torn intermediate states.
- **Edit-survival**: while pending, the placeholder text is read-only.
  Surrounding edits adjust the placeholder's markers automatically; if
  the user deletes the region outright, the placeholder cancels itself.
- **Backend-agnostic**: works with `gptel`, `make-process`,
  `url-retrieve`, plain timers, or any callback-driven async pattern.
- **One global timer**: regardless of how many concurrent placeholders
  are active, a single 10 fps timer drives the animation.

## Installation

`pending` requires Emacs 27.1 or newer and has no third-party runtime
dependencies.

### Via `package-vc-install` from GitHub

```elisp
(package-vc-install
 '(pending :url "https://github.com/jwiegley/pending"))
```

### Via `package-vc-install` from a local checkout

```elisp
(package-vc-install-from-checkout "/path/to/pending" "pending")
```

### Via `use-package`

```elisp
(use-package pending
  :vc (:url "https://github.com/jwiegley/pending")
  :commands (pending-make pending-overlay pending-insert
             pending-resolve pending-cancel pending-list
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
(let ((tok (pending-overlay (line-beginning-position)
                            (line-end-position)
                            "rewriting")))
  ;; ... do work ...
  (pending-resolve tok "the new text"))
```

### Mark a single point for insertion

```elisp
;; Insert at point when the answer arrives.
(let ((tok (pending-insert (point) "Calling Claude")))
  (run-at-time 2 nil (lambda () (pending-resolve tok "Hello!"))))
```

### Cancel from point

Place the cursor on a placeholder and run `M-x pending-cancel-at-point`
(also bound to `RET` and `mouse-1` over the placeholder).

### Show the lighter mode

```elisp
M-x global-pending-lighter-mode
```

The mode-line gains a small `[N⏳~Ks]` summary while any placeholders
are active. Click it to open `M-x pending-list`.

## Core concepts

### Tokens

Every constructor returns a *token* — a `pending` struct used as a
handle for the placeholder. Pass the token to `pending-resolve`,
`pending-cancel`, `pending-update`, and friends to operate on the
placeholder. Tokens are valid until they reach a terminal state
(`:resolved`, `:rejected`, `:cancelled`, `:expired`); after that, all
operations are no-ops with a `:debug` warning.

### The pending registry

All active placeholders are recorded in a global registry. Snapshot
it with `pending-alist` (returns `((ID . STRUCT) ...)`) or filter it
with `pending-list-active` (which honours `:buffer` and `:group`
filters). The registry is also the data source for `M-x pending-list`
and the mode-line lighter.

### Lighter vs region highlight

The library distinguishes two visual treatments for placeholders:

- **Region highlight** — the body of the placeholder uses the
  `pending-highlight` face so the user can see *where* the
  asynchronous content will land.
- **Lighter** — a small bold badge (face `pending-lighter`) attached
  to the overlay's `before-string`. This is the prominent
  visual marker that draws the eye.

The simple API uses a static lighter (`:lighter` indicator). The rich
API can substitute an animated spinner, a determinate bar, or an ETA
bar in place of the static lighter.

### Read-only protection

While a placeholder is active, its inserted text is read-only via text
properties (`read-only t`, `front-sticky '(read-only)`, and
`rear-nonsticky '(read-only)`). The user can edit before and after the
placeholder freely, but cannot edit the placeholder body. The library
binds `inhibit-read-only` during its own operations so internal
swaps still work.

In *adopt mode* (`pending-make` with explicit `:start` and `:end`),
the library does *not* retroactively add read-only properties — the
caller owns that text. In *insert mode* (no `:start`/`:end`) and
during streaming, all inserted text is protected.

### Auto-cancellation paths

Several edge conditions auto-cancel an in-flight placeholder so it
cannot strand state:

- **Region deletion** — if the user deletes the entire placeholder
  region, the overlay collapses to zero length and a
  `modification-hook` cancels with reason `:region-deleted`.
- **Buffer kill** — `kill-buffer-hook` iterates the buffer's
  pending registry and cancels each with reason `:buffer-killed`.
- **Deadline** — when `pending-make` is called with `:deadline N`, a
  one-shot timer fires `pending-reject` with reason `:timed-out` if
  the placeholder is still active after `N` seconds.
- **Process death** — `pending-attach-process` wraps the process
  sentinel; if the process dies non-cleanly (or cleanly without an
  explicit resolve), the placeholder is rejected with a reason
  derived from `process-status`.
- **Emacs exit** — when `pending-confirm-on-emacs-exit` is non-nil and
  active placeholders exist, `kill-emacs-query-functions` prompts
  before exit.

## The simple API

### `pending-overlay BEG END STR`

```elisp
(pending-overlay BEG END STR)  ; constructor
(pending-overlay TOKEN)        ; back-compat accessor
```

Mark the region `[BEG, END]` in the current buffer as pending an
asynchronous change. Highlight the region with `pending-highlight`
and show `STR` as a lighter badge at `BEG`. Returns a token.

If `BEG` equals `END`, the region is empty and only the lighter shows
— equivalent to `pending-insert`. The 1-arg form returns the token's
overlay (back-compat with the auto-generated accessor name).

```elisp
(let ((tok (pending-overlay (region-beginning) (region-end)
                            "summarising")))
  (gptel-request (buffer-substring (region-beginning) (region-end))
   :callback (lambda (text _) (pending-resolve tok text))))
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

### `pending-resolve TOKEN TEXT`

Atomically replace `TOKEN`'s region with `TEXT`. Transition to
`:resolved`. Returns t on success, nil if `TOKEN` was already in a
terminal state.

```elisp
(pending-resolve tok "Hello, world!")
```

### `pending-cancel TOKEN &optional REASON`

Cancel `TOKEN`. Calls the placeholder's `:on-cancel` callback first
(so the caller can abort underlying work — e.g. kill a process), then
replaces the region with a small cancelled glyph (`✗ REASON`) faced
with `pending-cancelled-face`. Default `REASON` is
`:cancelled-by-user`.

```elisp
(pending-cancel tok)              ; cancelled-by-user
(pending-cancel tok :timed-out)   ; explicit reason
```

### `pending-goto TOKEN`

Move point to `TOKEN`'s start position. Switches to its buffer if
necessary. Interactively, prompts via `completing-read` over the
registered placeholders.

```elisp
M-x pending-goto RET <pick from list> RET
```

### `pending-list`

Interactive command. Opens the `*Pending*` tabulated-list buffer
showing every registered placeholder. Columns: ID, Buffer, Label,
Status, Elapsed, ETA, Group. Bindings: `g` refresh, `RET` jump, `c`
cancel, `q` quit.

### `pending-alist`

Returns a fresh alist `((ID . STRUCT) ...)` snapshot of the registry.
Useful for programmatic queries.

```elisp
(length (pending-alist))                                   ; how many
(mapcar (lambda (cell) (pending-label (cdr cell)))         ; all labels
        (pending-alist))
```

### `pending-cancel-at-point`

Interactive command. Cancel the placeholder under point. Bound to
`RET` and `mouse-1` over a placeholder by `pending-overlay-map`.

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
| `:face`           | Override `pending-face` for the placeholder body.                                        |
| `:spinner-style`  | Key into `pending-spinner-styles`.                                                       |
| `:on-cancel`      | Function `(P)` called *before* status flips to `:cancelled`. Abort underlying work here. |
| `:on-resolve`     | Function `(P)` called once on transition to any terminal state.                          |
| `:group`          | Symbol for filtering via `pending-list-active`.                                          |

Insert mode vs adopt mode:

- **Insert mode** (no `:start`/`:end`) — inserts a new placeholder at
  point in `BUFFER`. The label text is propertized read-only.
- **Adopt mode** (both `:start` and `:end`) — takes over the existing
  region without inserting text. The caller owns the text and is
  responsible for read-only protection.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :indicator :spinner
              :on-cancel (lambda (_) (gptel-abort)))
```

### `pending-update P &key label percent eta indicator`

Mutate slots mid-flight without changing state. Useful when the
caller learns more about progress — e.g. switch from `:spinner` to
`:percent` once the total work size is known.

```elisp
(pending-update tok :percent 0.42)
(pending-update tok :indicator :eta :eta 10.0)
```

### `pending-resolve-stream P CHUNK`

Append `CHUNK` (a string) to `P`'s region. The first chunk replaces
the loading label and transitions to `:streaming`; subsequent chunks
append at the end marker (which has insertion-type `t` while
streaming, so it advances with the insert).

The streamed text is also read-only. Animation continues uninterrupted
during streaming.

```elisp
(pending-resolve-stream tok "Once upon a time, ")
(pending-resolve-stream tok "in a faraway land...")
```

### `pending-finish-stream P`

Finalize a streamed placeholder: flip the end marker's insertion-type
back to nil, strip read-only properties, remove the overlay, and fire
`:on-resolve`. The buffer text is left as-is (it already holds the
streamed content).

```elisp
(pending-finish-stream tok)
```

If `P` never received a chunk (status is `:scheduled` or `:running`),
this is equivalent to `(pending-resolve P "")`.

### `pending-reject P REASON &optional REPLACEMENT-TEXT`

Mark `P` as failed. `REASON` is a string or symbol. `REPLACEMENT-TEXT`
defaults to `"✗ REASON"` faced with `pending-error-face`.

```elisp
(pending-reject tok "API rate limit exceeded")
(pending-reject tok :network-down "Try again later.")
```

### `pending-attach-process P PROCESS`

Wire `PROCESS` so its death rejects `P` automatically. Wraps the
process sentinel; any caller-installed sentinel runs first, then a
wrapper inspects `process-status` and calls `pending-reject` on
non-clean exit. The reason is derived from the live process status,
which is robust against localized event strings.

```elisp
(let ((proc (start-process "build" nil "make")))
  (pending-attach-process tok proc))
```

### `pending-active-p P`

Returns non-nil if `P` is in an active (non-terminal) state:
`:scheduled`, `:running`, or `:streaming`.

### `pending-status P`

Returns the current status keyword.

### `pending-at &optional POS BUFFER`

Returns the pending struct at `POS` (default point) in `BUFFER`
(default current buffer), or nil.

## Indicator modes

Choose a visual via `:indicator` to `pending-make`. The simple
positional API always uses `:lighter`; the rich API defaults to
`:spinner`.

| Indicator   | Visual                                                  | Use when                                                 |
|-------------|---------------------------------------------------------|----------------------------------------------------------|
| `:spinner`  | Animated glyph + label (default).                       | Duration unknown, but the library should look alive.     |
| `:percent`  | Spinner glyph + bar + percent.                          | Caller can supply a fraction in `[0.0, 1.0]`.            |
| `:eta`      | Spinner glyph + bar + remaining-seconds estimate.       | Caller has a rough guess at total wall-clock seconds.    |
| `:lighter`  | Static badge (`pending-lighter` face). No animation.    | Visual marker only; no progress to convey.               |

Visual examples (terminal renderings):

```text
:spinner    Calling Claude  ⠋
:percent    Generating  ⠙ [████████░░░░░░░░] 47%
:eta        Downloading  ⠹ [████████████░░░░] ~3s
:lighter    Calling Claude
```

`:eta` uses a piecewise-asymptotic formula that hits 80% at
`t = 0.8 × ETA`, 95% at `t = ETA`, and saturates toward (but never
reaches) 100% past the deadline. This avoids the "100% but still
working" effect that bothers users.

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
                  ((stringp chunk) (pending-resolve-stream p chunk))
                  ((plist-get info :error)
                   (pending-reject p (plist-get info :error)))
                  (t (pending-finish-stream p)))))
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
                  ((stringp response) (pending-resolve p response))
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
                          (pending-resolve-stream p out))
                :sentinel (lambda (_proc event)
                            (if (string-prefix-p "finished" event)
                                (pending-finish-stream p)
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
         (pending-resolve p (buffer-substring (point) (point-max)))))))
    p))
```

### Pure-delay timer (for tests/demos)

```elisp
(defun my/delay-pending (seconds text)
  "Show a pending placeholder; replace with TEXT after SECONDS."
  (let ((p (pending-insert (point) (format "wait %ds" seconds))))
    (run-at-time seconds nil
                 (lambda ()
                   (when (pending-active-p p)
                     (pending-resolve p text))))
    p))
```

### Generic callback-driven async (template)

```elisp
(defun my/with-pending (label callback)
  "Show a pending placeholder labelled LABEL.
CALLBACK is called with the token; it must arrange to call
`pending-resolve' or `pending-reject' on the token."
  (let ((p (pending-make (current-buffer)
                         :label label
                         :indicator :spinner)))
    (funcall callback p)
    p))
```

## Mode-line lighter

`global-pending-lighter-mode` is a global minor mode. When enabled, it
appends a small construct to `global-mode-string` that displays:

```text
 [3⏳~5s]
```

— meaning *3 active placeholders; the smallest remaining ETA across
them is approximately 5 seconds*. When no placeholder has an ETA in
the future, the trailing tilde-segment is omitted: `[3⏳]`. When no
placeholders are active, the lighter is hidden entirely.

The lighter is propertized with `pending-spinner-face`, carries a
help-echo tooltip, and binds `mouse-1` to `pending-list` so a click
opens the list buffer.

```elisp
(global-pending-lighter-mode 1)
```

## The `*Pending*` buffer

`M-x pending-list` opens a tabulated-list view with one row per
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
| `q`   | `quit-window`            | Bury the buffer.                         |

The list does not auto-refresh in v0.1; press `g` to update. Auto-
refresh is on the v0.2 roadmap.

## Customization

| Variable                          | Default      | Effect                                                                  |
|-----------------------------------|--------------|-------------------------------------------------------------------------|
| `pending-fps`                     | `10`         | Animation frame rate. The single global timer ticks at `1/fps` seconds. |
| `pending-bar-width`               | `16`         | Width in cells of the `:percent` and `:eta` progress bars.              |
| `pending-default-spinner-style`   | `'dots-1`    | Default key into `pending-spinner-styles`.                              |
| `pending-spinner-styles`          | (see source) | Alist mapping style symbols to vectors of frame strings.                |
| `pending-bar-style`               | `'eighths`   | Bar character set: `eighths` (Unicode) or `ascii`.                      |
| `pending-bar-family`              | `nil`        | Font family for the bar (avoids variable-pitch misalignment).           |
| `pending-allow-read-only`         | `nil`        | When non-nil, placeholders may be placed in read-only buffers.          |
| `pending-label-max-width`         | `60`         | Maximum visible label width; longer labels are truncated.               |
| `pending-confirm-on-emacs-exit`   | `nil`        | When non-nil, prompt before exit while placeholders are active.         |

Spinner styles ship with: `dots-1`, `dots-2`, `line`, `arc`, `clock`.
Add your own via:

```elisp
(add-to-list 'pending-spinner-styles
             '(my-style . ["a" "b" "c"]))
```

## Faces

| Face                       | Role                                                          |
|----------------------------|---------------------------------------------------------------|
| `pending-highlight`        | Background of the highlighted region (`BEG..END`).            |
| `pending-lighter`          | Static badge (`pending-overlay`/`pending-insert`). White on red. |
| `pending-face`             | Compatibility alias for `pending-highlight`.                  |
| `pending-spinner-face`     | Spinner glyph in the `before-string`.                         |
| `pending-progress-face`    | Bar and ETA text in the `after-string`.                       |
| `pending-error-face`       | Replacement text for rejected placeholders.                   |
| `pending-cancelled-face`   | Replacement text for cancelled placeholders.                  |

## Hooks and lifecycle callbacks

### `:on-cancel` (per-placeholder)

Called *before* the cancellation pipeline runs. Abort underlying work
here — kill processes, abort gptel requests, cancel timers.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :on-cancel (lambda (p)
                           (gptel-abort (pending-buffer p))))
```

If `:on-cancel` signals an error or `quit`, the cancel pipeline
catches it and proceeds; the placeholder cannot get stranded.

### `:on-resolve` (per-placeholder)

Called *once* on transition to any terminal state (`:resolved`,
`:rejected`, `:cancelled`, `:expired`). Inspect `(pending-status p)`
inside the callback to differentiate.

```elisp
(pending-make (current-buffer)
              :label "Calling Claude"
              :on-resolve (lambda (p)
                            (message "Done: %s -> %s"
                                     (pending-label p)
                                     (pending-status p))))
```

### Global hooks installed by the library

- `kill-buffer-hook` (buffer-local) — cancels every placeholder in
  the buffer being killed with reason `:buffer-killed`.
- `kill-emacs-query-functions` — when `pending-confirm-on-emacs-exit`
  is non-nil, prompts before exit if active placeholders exist.
- `window-buffer-change-functions` — re-arms the parked animation
  timer when a placeholder's buffer becomes visible.

`pending-unload-function` cleans up the timer and removes the global
hooks on `unload-feature`.

## Comparison with `org-pending`

Bruno Barbier's [`org-pending`][1] is a closely related upstream Org
patch that nevertheless declares itself independent of Org mode. It
solves a similar problem from a different angle. The table is a
condensed version of `RESEARCH.md` §1.

| Aspect            | `org-pending`                                | `pending`                                                |
|-------------------|----------------------------------------------|----------------------------------------------------------|
| Distribution      | Org-mode patch (`bba-pending-contents`)      | Standalone library                                       |
| Org dependency    | None — but the namespace and prefix imply Org | None                                                     |
| State machine     | `:scheduled → :pending → :success/:failure`  | Adds `:running`, `:streaming`, `:cancelled`, `:expired`  |
| Animation         | Static Unicode glyph                         | Animated spinner (10 fps, single global timer)           |
| Progress bar      | Single line of text in `after-string`        | Eighth-block Unicode bar (or ASCII fallback)             |
| Streaming         | Message-passing via `org-pending-send-update`| First-class `pending-resolve-stream` / `-finish-stream`  |
| Description UI    | `*Region Lock*` describe buffer              | Tabulated list (`pending-list`) — describe deferred      |
| Indirect buffers  | Read-only projection                         | Not yet — overlay+text-property scope is single-buffer   |
| Kill-emacs query  | Built in (`kill-emacs-query-functions`)      | Same hook, gated by `pending-confirm-on-emacs-exit`      |

The two libraries can coexist. Pick whichever suits your caller: if
you live in Org and want minimal animation, prefer `org-pending`; if
you want streaming and progress visualization out of the box, prefer
`pending`.

[1]: https://framagit.org/brubar/org-mode-mirror/-/tree/bba-pending-contents

## Limitations and caveats

- **~50 placeholders per buffer guideline.** Each placeholder is an
  overlay, and overlays have O(n) scan cost for some buffer
  operations. Keep concurrent counts modest.
- **Variable-pitch alignment.** The `:percent` and `:eta` bars assume
  a monospaced cell width. Under variable-pitch buffer faces, the bar
  may look ragged. Set `pending-bar-family` to a fixed-pitch family
  to compensate.
- **No SVG spinner in v0.1.** Spinners are text glyphs only. SVG
  spinners (and a fringe-bitmap indicator) are on the v0.2 roadmap.
- **Manual refresh of `*Pending*` list.** Press `g` to update; the
  list does not auto-refresh on registry mutation in v0.1.
- **Single-buffer scope.** A placeholder's overlay and read-only text
  properties live in one buffer. There is no projection across
  indirect buffers in v0.1; `org-pending`-style indirect-buffer
  projection is on the roadmap.
- **No cross-buffer multi-region pending.** A single pending struct
  represents one contiguous region in one buffer. Coordinate multiple
  related placeholders via the `:group` keyword and
  `pending-list-active`.

## Roadmap (v0.2)

- Auto-refresh of `*Pending*` on registry mutation.
- Pulse-on-resolve flash via `pulse.el`.
- `pending-as-promise` adapter for `aio` users.
- SVG spinner for graphical frames.
- Fringe bitmap indicator beside the placeholder.
- `*Region Lock*`-style description buffer for a single placeholder.
- Indirect-buffer projection of read-only properties.

## Development

This package uses [Eask] for build automation, with a Makefile
wrapper.

```bash
# Install dependencies
eask install-deps

# Compile (warning-free)
eask compile

# Run tests (72 ERT tests)
eask test ert pending-test.el

# All-in-one via Make
make compile
make test
make docs       # build doc/pending.info
make clean
```

[Eask]: https://github.com/emacs-eask/cli

### Generating the manual

The Texinfo source lives at `doc/pending.texi`; the built `pending.info`
ships in the package.

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

Bug reports and pull requests are welcome via GitHub. When filing an
issue, please include:

- Emacs version (`M-x emacs-version`).
- Whether you are running graphical or terminal Emacs.
- Steps to reproduce.
- A backtrace if the bug manifests as an error.

When sending a PR, please:

- Match the existing code style (lexical binding, `--` for internal
  symbols, comprehensive docstrings).
- Add ERT tests for new behaviour.
- Ensure `eask compile` is warning-free and `eask test` is green.
- Run `M-x checkdoc` on touched files.

## License

GPL-3.0-or-later. Same as Emacs and `org-pending`.

## Acknowledgments

- **`org-pending`** (Bruno Barbier) — prior art and design vocabulary;
  see `RESEARCH.md` for a detailed comparison.
- **`gptel`** (karthink) — marker discipline (`gptel.el:1389, 1794`)
  inspired the streaming end-marker insertion-type flip.
- **`agent-shell`** — the active-message lifecycle pattern in
  `agent-shell-active-message.el` informed the global animation
  timer.
- **`spinner.el`** (Artur Malabarba) — Unicode spinner frame sets
  carried forward as `pending-spinner-styles`.
