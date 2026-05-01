# pending

A standalone Emacs Lisp library for marking buffer regions whose
content will arrive later. Insert a colored placeholder where some
asynchronously computed text is going to appear, optionally with a
spinner or progress bar, then atomically replace it with the result
when ready.

```text
Calling Claude  ⠋ [████████░░░░░░░░] 47%
```

Use cases:

- LLM responses (`gptel`, `agent-shell`, your own Claude/OpenAI client).
- Shell commands run via `make-process`.
- Network fetches via `url-retrieve`.
- Arbitrary callback-driven async work.

## Why not `org-pending`?

Bruno Barbier's [`org-pending`][1] is a closely related upstream Org
patch and is genuinely independent of Org mode (its commentary says
so explicitly). We took a hard look — see `RESEARCH.md` — and built
a separate library because we want:

- A spinner and a real progress bar (org-pending shows a static
  Unicode glyph and a textual progress message).
- First-class streaming via `pending-resolve-stream` for LLM
  token-by-token output.
- A single global animation timer rather than per-region timers.
- A shorter prefix and namespace not connoting Org.

`pending` and `org-pending` coexist fine; pick whichever fits your
caller.

[1]: https://framagit.org/brubar/org-mode-mirror/-/tree/bba-pending-contents

## Sketch of the API

```elisp
(let ((p (pending-make (current-buffer)
                       :label "Calling Claude"
                       :indicator :spinner
                       :on-cancel (lambda (_) (gptel-abort)))))
  (gptel-request
   "Hello"
   :stream t
   :callback (lambda (chunk info)
               (cond ((stringp chunk) (pending-resolve-stream p chunk))
                     ((plist-get info :error)
                      (pending-reject p (plist-get info :error)))
                     (t (pending-finish-stream p))))))
```

Full surface in `DESIGN.md` §3.

## API at a glance

| Symbol                          | Kind     | Purpose                                                         |
|---------------------------------|----------|-----------------------------------------------------------------|
| `pending-make`                  | function | Insert a placeholder; return a `pending' struct                 |
| `pending-resolve`               | function | Atomically replace the region with text; transition `:resolved` |
| `pending-resolve-stream`        | function | Append a streamed chunk; transition `:streaming` on first call  |
| `pending-finish-stream`         | function | Close out a stream; transition `:resolved`                      |
| `pending-reject`                | function | Replace the region with an error glyph; transition `:rejected`  |
| `pending-cancel`                | function | Cancel; run `:on-cancel` first, transition `:cancelled`         |
| `pending-update`                | function | Mutate label / percent / eta / indicator mid-flight             |
| `pending-attach-process`        | function | Wire a process so its death rejects the placeholder             |
| `pending-active-p`              | function | t if status is `:scheduled`, `:running`, or `:streaming`        |
| `pending-status`                | function | Current status keyword                                          |
| `pending-at`                    | function | The placeholder at point (or nil)                               |
| `pending-list-active`           | function | All active placeholders (filterable by buffer / group)          |
| `pending-cancel-at-point`       | command  | Cancel the placeholder at point                                 |
| `pending-list`                  | command  | Tabulated `*Pending*` buffer with rows for each placeholder     |
| `pending-demo`                  | command  | Open `*pending-demo*` showing all three indicator modes         |
| `global-pending-lighter-mode`   | minor    | Mode-line summary `[N⏳~Ks]` of active placeholders             |
| `pending-overlay-map`           | keymap   | RET / mouse-1 over a placeholder cancel it                      |

Status keywords: `:scheduled`, `:running`, `:streaming`, `:resolved`,
`:rejected`, `:cancelled`, `:expired`. Active states are the first
three; the rest are terminal.

## Interactive commands

- `M-x pending-list` — open the `*Pending*` tabulated list of
  placeholders. In that buffer: `g` refresh, `RET` jump to the
  placeholder, `c` cancel, `q` quit.
- `M-x pending-cancel-at-point` — cancel the placeholder under
  point. Also bound to `RET` and `mouse-1` over a placeholder via
  `pending-overlay-map`.
- `M-x pending-demo` — populate `*pending-demo*` with three
  concurrent placeholders (spinner, ETA, percent) that resolve
  themselves over ~12 seconds. Useful for theme inspection.
- `M-x global-pending-lighter-mode` — toggle a global mode-line
  lighter showing the count and the smallest remaining ETA.

## Installation

This library is currently distributed as a vendored package. To install
from a local clone via `package-vc-install`:

```elisp
(package-vc-install
 '(pending :url "https://github.com/jwiegley/pending"))
```

Or, after cloning locally, point `package-vc-install` at the directory:

```elisp
(package-vc-install-from-checkout "/path/to/pending" "pending")
```

For a manual install, drop `pending.el` somewhere on `load-path` and
`(require 'pending)`.

## Integration recipes

The sketches below also live in `DESIGN.md` §7. They are working
shapes — adapt the prompts, commands, and URLs to taste.

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
                    (pending-resolve-stream p chunk))
                   (`(reasoning . ,_) nil)  ; ignore
                   (_  (if (plist-get info :error)
                           (pending-reject p (plist-get info :error))
                         (pending-finish-stream p))))))
    ;; With :stream t and :callback, gptel routes each chunk to the
    ;; callback; the callback inserts via pending-resolve-stream.  The
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
                          (pending-resolve-stream p out))
                :sentinel (lambda (_proc event)
                            (if (string-prefix-p "finished" event)
                                (pending-finish-stream p)
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
         (pending-resolve p (buffer-substring (point) (point-max)))))))
    p))
```

## Comparison with `org-pending`

`org-pending` and `pending` solve the same problem from different
angles. The table below is a condensed version of `RESEARCH.md` §1.

| Aspect            | `org-pending`                              | `pending`                                              |
|-------------------|---------------------------------------------|---------------------------------------------------------|
| Distribution      | Org-mode patch (`bba-pending-contents`)     | Standalone library                                      |
| Org dependency    | None — but namespace and prefix imply Org   | None                                                    |
| State machine     | `:scheduled → :pending → :success/:failure` | Adds `:running`, `:streaming`, `:cancelled`, `:expired` |
| Animation         | Static Unicode glyph                        | Animated spinner (10 fps, single global timer)          |
| Progress bar      | Single line of text in `after-string`       | Eighth-block Unicode bar (or ASCII fallback)            |
| Streaming         | Message-passing via `org-pending-send-update` | First-class `pending-resolve-stream` / `-finish-stream` |
| Description UI    | `*Region Lock*` describe buffer             | Tabulated list (`pending-list`) — describe deferred     |
| Indirect buffers  | Read-only projection                        | Not yet — overlay+text-property scope is single-buffer  |
| Kill-emacs query  | Built in (`kill-emacs-query-functions`)     | Same hook, gated by `pending-confirm-on-emacs-exit`     |

The two libraries can coexist. Pick whichever suits your caller: if
you live in Org and want minimal animation, prefer `org-pending`; if
you want streaming and progress visualization out of the box, prefer
`pending`.

## Status

- [x] Research and design (this directory).
- [x] Phase 0–9 implementation (see `PLAN.md`).
- [ ] First release: `0.1.0`.

## License

GPL-3.0-or-later. (Same as Emacs and `org-pending`.)
