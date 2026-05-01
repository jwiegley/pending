# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project orientation

`pending` is a standalone Emacs Lisp library for marking buffer regions whose
content arrives asynchronously. Released as v0.1.0; see `git tag -l` for the
canonical release point. The repository sits inside John Wiegley's
`dot-emacs/lisp/` collection but has no coupling to the surrounding code; do
not introduce one.

Read `DESIGN.md` (canonical spec, ~1600 lines), then `RESEARCH.md` (verified
prior-art survey of `org-pending`, gptel, agent-shell), then `NOTES.md`
(explicit decisions table). `PLAN.md` records phase exit criteria and items
deferred to v0.2. The `README.md` (810 lines) and `doc/pending.texi` (~1380
lines) are the user-facing reference; keep them in sync when changing the
public API.

## Toolchain — important

The local Emacs install is provided through a Nix wrapper. There is **no
`emacs` on `$PATH`**. Every Emacs/Eask invocation must go through
`load-env-emacs30MacPort`, e.g.:

```bash
load-env-emacs30MacPort eask compile
load-env-emacs30MacPort emacs --batch -L . -l pending-test.el --eval ...
```

The wrapper prints `outputLib: invalid indirect expansion` and similar
`_assignFirst` lines on stderr — these are harmless Nix env-loader noise; do
NOT treat them as errors. Real Emacs/Eask output appears after them.

`makeinfo` is on `$PATH` directly (not behind the wrapper).

## Common commands

```bash
# Byte-compile (must stay warning-free)
load-env-emacs30MacPort eask compile

# Run the full ERT suite (currently 77 tests)
load-env-emacs30MacPort eask test ert pending-test.el
make test                        # equivalent

# Run a single test (or a regex of tests) — the eask CLI doesn't reliably
# filter, so go through emacs --batch directly:
load-env-emacs30MacPort emacs --batch -L . -l pending-test.el \
  --eval '(ert-run-tests-batch-and-exit "pending-test/scheduled-to-resolved")'

# Checkdoc — both files must stay clean
load-env-emacs30MacPort emacs --batch \
  --eval '(progn (find-file "pending.el") (checkdoc-current-buffer t) (princ "DONE"))'
load-env-emacs30MacPort emacs --batch \
  --eval '(progn (find-file "pending-test.el") (checkdoc-current-buffer t) (princ "DONE"))'

# Build the manual (regenerates doc/pending.info; commit alongside texi changes)
make docs

# Interactive REPL with the package loaded
load-env-emacs30MacPort emacs -Q -L . --eval '(require (quote pending))'
```

After non-trivial changes, the contract is: byte-compile clean, all tests
pass, both files checkdoc clean, and (if you touched the API or texi)
`make docs` regenerated. PLAN.md's "Cross-cutting checklist" lists this.

## Architecture — what requires reading multiple files

### Two API tiers, one token type

There are two public surfaces and they MUST stay aligned:

- **Simple positional API** (the user-facing default): `pending-region
  BEG END STR`, `pending-insert POS STR`, `pending-finish TOKEN STR`,
  `pending-cancel TOKEN`, `pending-goto TOKEN`, `pending-list`,
  `pending-alist`.
- **Rich keyword API** (for streaming, animation, deadlines, processes):
  `pending-make BUFFER &key ...` plus `pending-stream-insert`,
  `pending-stream-finish`, `pending-update`, `pending-attach-process`,
  `pending-reject`.

Both produce the same `pending` `cl-defstruct` token. New features should
work for tokens regardless of which constructor produced them. The simple
API is implemented as thin wrappers that delegate to `pending-make`.

### Single mutation path for terminal transitions

`pending--resolve-internal` is the **only** function that flips a token from
non-terminal to terminal status. Resolve, reject, cancel, stream-finish,
process-sentinel, deadline-timer all converge here. Two guards prevent
re-entrancy: a terminal-status check at the top, and a per-token
`in-resolve` boolean slot that is set eagerly in `pending-cancel` *before*
the on-cancel callback runs (so a buggy callback that recursively invokes
`pending-cancel` cannot loop).

Don't bypass `pending--resolve-internal` to "directly" set
`(pending-status p)` — you'll silently break the lifecycle invariants and
skip the registry/overlay/marker cleanup.

### Two registries, kept in lockstep

`pending--registry` is a global `eq` hash (id → struct). `pending--buffer-registry` is
a `defvar-local` list of structs in the current buffer. `pending--register`
and `pending--unregister` are the only mutators and update both atomically
(single-threaded, so the "atomically" is really just the two-statement
sequence). The buffer-local list is what makes `kill-buffer-hook` cancel
every placeholder in a dying buffer.

### Single global animation timer (not per-region)

`pending--global-timer` runs at `(/ 1.0 pending-fps)` ≈ 100ms. Each tick
walks `pending--registry` once. Park-on-no-visible: if no active token has
a window showing its buffer, the timer cancels itself; the
`window-buffer-change-functions` hook re-arms when one becomes visible
again. NOTES.md decision #2 explicitly rejects per-region timers — don't
revisit this without strong reason.

When adding work that needs periodic checks (auto-refresh of `*Pending*`
list is a v0.2 candidate), piggy-back on `pending--tick`. Don't start a
second timer.

### Indicator dispatch in `pending--render`

`pending--render` switches on `(pending-indicator p)`:

- `:spinner` — frame index from elapsed wall-time, glyph in `before-string`.
- `:percent` — same spinner glyph + bar/percent in `after-string`.
- `:eta` — same spinner glyph + bar/remaining-seconds in `after-string`.
- `:lighter` — static badge in `before-string`, no animation, no
  `after-string`. The spinner-glyph block is gated out for this mode.

The frame index uses `(- (float-time) start-time)` not a tick counter so
the animation phase is stable across timer parks/resumes (gptel-style; see
`gptel.el:1389,1794` referenced in DESIGN.md §4 and RESEARCH.md §5).

### Marker discipline for streaming

End marker insertion-type defaults to `nil`. `pending-stream-insert` flips
it to `t` on the first chunk so subsequent inserts at the marker advance it
naturally; `pending-stream-finish` flips it back. The first chunk also
deletes the placeholder label content so the streamed text replaces it
rather than appending after. This deviates from the literal "append" prose
in early DESIGN.md drafts but matches the LLM streaming UX (label
"Calling Claude" → response chunks). The streaming tests pin this contract.

When growing the overlay during streaming, `pending-stream-insert` calls
`move-overlay` so its face/decorations/modification-hooks track the new
range — without that call, mid-stream deletes of streamed text wouldn't
auto-cancel.

### Face policy (post-v0.1.0 patch)

The library **never** adds `face` text properties to text it inserts. The
overlay's `face` property is set only in adopt mode with a non-empty range
(BEG < END in `pending-region`). Insert mode and zero-width adopt mode
leave the overlay face nil. The lighter (a `before-string`) is faced with
`pending-lighter`; that's the single visual cue for those modes.

The mode is tracked by an explicit `adopt-mode-p` flag in `pending-make` —
not by `(< start end)`, because in insert mode the start-marker's
insertion-type is nil so it stays put while text is inserted, making `<`
true even though we're in insert mode. Don't simplify this gate without
re-running the face-policy tests.

### Read-only via text properties, not overlay hooks

`read-only t front-sticky (read-only) rear-nonsticky (read-only)` on the
inserted label and on streamed chunks. Library-internal mutations bind
`inhibit-read-only t` and `inhibit-modification-hooks t` (the latter
prevents `pending--on-modify` from auto-cancelling during the library's
own delete+insert). The overlay's `modification-hooks` exist solely to
DETECT region deletion (auto-cancel with `:region-deleted`); they don't
block edits.

### Process sentinels: dispatch on `process-status`, not on event strings

`pending--process-sentinel` reads `(process-status proc)` and pcase's on
the symbol (`exit`, `signal`, `failed`, `closed` → reject; everything
else, including `run`/`open`/`stop` → no-op). An earlier implementation
parsed event strings and false-rejected on `"open\n"` etc.; that bug is
the reason the test `pending-test/process-non-terminal-events-no-op`
exists. Don't regress this.

### Atomic resolve

`pending--swap-region` wraps `delete-region` + `insert` in
`atomic-change-group` so undo sees one step. Inserted text is plain (no
face property) per the face policy.

### Token identity

`pending--gen-id` uses `make-symbol` (uninterned) — not `intern`. The
registry is `:test 'eq` so uninterned symbols work fine and we don't leak
into the global obarray. If a future change wants to put IDs in
user-visible places (e.g. `customize`-able names), revisit; otherwise keep
uninterned.

### Unload hygiene

`pending-unload-function` removes the `window-buffer-change-functions` and
`kill-emacs-query-functions` hooks and cancels the global timer. When you
add new global state (top-level `add-hook`, registered timers, defvars
holding live processes), update this function.

## Conventions

- Lexical binding cookie required on first line of every `.el`.
- Public `pending-foo`, internal `pending--foo`, predicates end `-p`.
- No `(require 'org)` — ever. NOTES.md decision; the reason `pending`
  exists separately from `org-pending`. Same for any other third-party
  dep — the library is `(emacs "27.1")` plus `cl-lib` and `tabulated-list`
  (both core).
- `cl-defstruct`, not plists. `cl-typecase` is fine but most dispatch is
  `pcase`. Avoid `cl-loop` where `dolist`/`dotimes`/`mapcar` will do.
- New `defcustom`s need `:type`, `:group 'pending`, and
  `:package-version '(pending . "0.1.0")` (registered in
  `customize-package-emacs-version-alist` near the top of the file).
- New public API entries need `;;;###autoload` only if the user might call
  them before the package is loaded (interactive commands, top-level
  setup). Internals: never.

## Phase history & deferred items

The library was built in 9 phases plus a face-policy patch (see `git log`).
PLAN.md's "Deferred to v0.2" enumerates the known v0.2 candidates: SVG
spinner, pulse-on-resolve, `pending-as-promise` adapter, `*Pending*` list
auto-refresh, `*Region Lock*`-style description buffer, indirect-buffer
projection, fringe-bitmap indicator. When picking up a v0.2 task, check
DESIGN.md §10 / NOTES.md for prior thinking and the relevant `RESEARCH.md`
section.

## Coordinating documentation changes

When you change the public API, three places need updating in lockstep:
docstrings in `pending.el`, the matching section of `README.md`, and the
matching `@deffn`/`@defopt` in `doc/pending.texi`. After editing the texi
run `make docs` and commit the regenerated `doc/pending.info` alongside.

## Productization

The package is wired up for reproducible builds, automated checks, and
contributor onboarding:

- **Nix flake** (`flake.nix`) ships `devShells.default` (Emacs +
  package-lint + undercover + eask + texinfo + lefthook + shellcheck +
  shfmt) and `checks.<system>.{byte-compile,tests,lint,format,docs,coverage}`.
  Enter the shell with `nix develop`; run all checks with
  `nix flake check --no-warn-dirty`.
- **Lefthook** (`lefthook.yml`) runs the same checks pre-commit, in
  parallel, scoped to globs of staged files. After `nix develop`, run
  `lefthook install` once to wire up the git hook. For a one-off run:
  `lefthook run pre-commit`.
- **GitHub Actions** (`.github/workflows/ci.yml`) runs four jobs:
  `test-emacs` (matrix over 28.2/29.4/30.1/snapshot on Ubuntu),
  `coverage` (lcov uploaded to Codecov), `nix` (flake check + per-check
  builds), and `shellcheck`. The Makefile abstracts emacs invocations
  via `$(EMACS)` / `$(EMACS_BATCH)` (default `emacs`); CI invokes the
  Make targets with `EMACS=emacs` to bypass the local
  `load-env-emacs30MacPort` wrapper.
- **Coverage baseline** lives in `.coverage-baseline` as a single
  integer percent. `scripts/coverage.sh` runs ERT under undercover.el,
  emits `coverage.lcov`, and fails if the percent regresses below
  baseline. The script auto-bumps the baseline up on improvement.
- **Perf baseline** lives in `.perf-baseline` as four-line whitespace
  table mapping benchmark name to median wall-time seconds.
  `scripts/profile.sh` runs the four hot paths (make-and-resolve,
  gen-id, render-bar-eighths, eta-fraction) and fails if any ratio
  exceeds 1.05x. Update the baseline by deleting it and re-running
  `make profile` (the script reinitialises it from the current run);
  commit only when an intentional regression has been understood.
- **`make all-checks`** runs `warnings test lint format-check docs
  coverage` — what the lefthook + CI both run.
- **`make format-check`** snapshots every tracked .el file, runs
  `make format`, diffs against the snapshot, then restores the
  snapshot. So it works in any working-tree state (including
  pre-commit hooks where staged-but-uncommitted changes exist) and
  never leaves the tree mutated.
