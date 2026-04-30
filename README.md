# pending

> Status: **design only — no implementation yet**. See `DESIGN.md`,
> `PLAN.md`, `RESEARCH.md`, `NOTES.md` for the full design pass.

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

## Status

- [x] Research and design (this directory).
- [ ] Phase 0–9 implementation (see `PLAN.md`).
- [ ] First release: `0.1.0`.

## License

GPL-3.0-or-later. (Same as Emacs and `org-pending`.)
