# Notes

Informal observations, decisions to revisit, and open questions. The
authoritative design is in `DESIGN.md`; this is the scratchpad of
"things we noticed that don't fit cleanly into a section."

## Naming

- Library prefix: `pending-` (public), `pending--` (internal).
- Emacs faces: `pending-face`, `pending-spinner-face`,
  `pending-progress-face`, `pending-error-face`,
  `pending-cancelled-face`.
- Group: `(defgroup pending nil ...)` under `'tools`.
- Package name on file disk: `pending.el`. No `pending-pkg.el`
  unless `package.el` requires it (Eask handles this).
- Constructor: `pending-make` (verb-leading; matches `gptel-make-tool`
  and the wider `cl-defstruct` `make-X` convention).
- The struct itself is `pending` (so `(pending-p obj)` reads
  naturally).

## Decisions explicitly made and recorded

| # | Decision                                              | Why                                                        |
|---|-------------------------------------------------------|------------------------------------------------------------|
| 1 | One overlay per region, not two                       | org-pending uses two; one suffices because we don't need a separate "anchor" — the placeholder text *is* the anchor. Simpler bookkeeping. |
| 2 | Single global animation timer                         | N timers for N placeholders is wasteful; one tick walks the registry. |
| 3 | Callback API, not promise API                         | Matches every async surface in Emacs. Promise adapter is v2. |
| 4 | Read-only via text properties, not overlay hooks      | Composes with `inhibit-read-only`; standard error message; no surprising hook ordering. |
| 5 | Streaming as a first-class state                      | gptel's pattern is the primary use case; org-pending lacks this. |
| 6 | Distinct `:cancelled` and `:expired` terminal states  | Caller often needs to know "user gave up" vs "deadline hit" vs "remote error" — collapsing into `:rejected` loses information. |
| 7 | Text spinner only in v1, SVG deferred to v2           | TUI must work; SVG is decoration. |
| 8 | `cl-defstruct`, not plist                             | Type-checked accessors; `cl-defmethod` dispatch later if needed. |

## Decisions NOT yet made (revisit during implementation)

- **Description buffer**: org-pending has `*Region Lock*`. Worth the
  ~80 LOC for v1, or push to v2? Lean toward v2 — the use case
  (debugging long-running locks) is real but `pending-list` covers
  most of it.
- **Indirect-buffer projection**: skipped for v1. If a consumer files
  a real bug we can port org-pending's approach (~30 LOC).
- **Kill-emacs query**: org-pending blocks Emacs exit until the user
  confirms. We probably want this too, gated by a defcustom defaulting
  to nil (vs org-pending's t) — most pending placeholders should
  not block exit by default.
- **Pulse on resolve**: gptel does
  `pulse-momentary-highlight-region` on response insertion.
  We could do the same in `pending-resolve`. Cheap, nice UX. Probably
  v1.
- **Overlay priority value**: DESIGN.md says 100; check no other
  package in the user's setup conflicts (gptel uses default).
- **Bar character set**: eighth-blocks (`▏▎▍▌▋▊▉█`) look great in
  monospace and at most modern fonts but break on minimal
  terminals. Provide a defcustom `pending-bar-style` with
  `eighths`/`ascii` (`#`/`-`) options.
- **Whether to call `force-window-update` after each tick**: probably
  no — just dirty the overlay. Test on Emacs 27 to be sure.

## Edge cases worth a test

- Two pending regions overlap (one inside another's `[start,end]`).
  Expected: undefined behavior; document that overlapping is not
  supported. Detect at `pending-make` time and signal
  `pending-error`.
- Pending in a buffer that becomes file-visiting, gets
  `revert-buffer`d, etc. Expected: revert silently kills overlays
  via `kill-all-local-variables`; we hook `kill-buffer-hook` but
  not `revert-buffer-hook`. Check if a custom
  `revert-buffer-restore-functions` integration is needed.
- Pending region inside a `narrow-to-region` that excludes it.
  Expected: still active (markers track absolute positions), but
  invisible. The visibility heuristic (`get-buffer-window`) covers
  the window-not-shown case but not narrow-excluded. Acceptable;
  document.
- A buffer made indirect via `make-indirect-buffer` after pending
  was created: see org-pending's `org-pending--after-indirect-clone`
  which deletes copied overlays. We should at least install a hook
  to clean up duplicate overlays in indirect buffers.

## Org-pending coexistence

If a user has both libraries loaded, and someone calls
`org-pending` and `pending-make` on the same region, the second
caller's overlay would stack on the first. We should:

- **Not** detect-and-error against org-pending (too coupled).
- Document: "if you're in an Org buffer, prefer `org-pending` for
  Org-aware features (Babel async, dblock); use `pending` for
  generic placeholders."

## Potential v2 / v3 features

- Promise adapter: `pending-as-promise` returning an `aio-promise`.
- SVG spinners with cached image-string per (face,size,frame).
- `pending-resolve` accepts a function instead of a string —
  invoked at resolution time with the struct, returns the
  replacement text. Useful for late binding.
- Group-level operations: `pending-cancel-group`,
  `pending-list-group`.
- Sticky lighter showing "longest-running pending: X (35s)".
- `treesit`/`syntax-ppss`-aware insertion: don't break a string
  literal mid-token.
- Persistent restoration: serialize active pendings to file-local
  variables on save, re-mark on load (probably not — pending state
  is inherently ephemeral).

## Code-quality reminders

- All public functions need docstrings with arg/return types and a
  side-effect summary.
- Use `cl-typecase` over `pcase` when dispatching on types
  (gptel's convention).
- `byte-compile-file` must be warning-free.
- `M-x checkdoc` clean.
- Use `;;;###autoload` only where the function is interactive or
  used early in init.
- Avoid `eval-after-load 'org` glue in v1 — the goal is Org
  independence.
- No `cl-loop` if `dolist` / `dotimes` / `seq-do` will do; gptel
  uses `cl-loop` heavily, but readability matters more.

## Coordination with `org-pending` upstream

- After v1 ships, send a short note to the org-mode list
  cross-linking the two libraries.
- If `org-pending` lands in Emacs core, consider extracting the
  shared bits into a third-party library both can build on
  (probably overkill — keep separate).

## Aesthetic tuning to do during dev

- Try `:background` colors on `pending-face` against:
  - `modus-operandi` / `modus-vivendi`
  - `doom-one` / `doom-solarized-light`
  - default `light` / `dark`
- The DESIGN.md defaults (`#1e3a5f` / `#e8f0fa`) are reasonable
  starting points. Adjust by hand on each theme.
- The spinner color (`#ffd866`) should pop against most backgrounds
  but check `solarized-light`.

## Out-of-scope for this design pass

- Persistent storage of pending state.
- Network protocol for cross-Emacs-instance pending.
- Integration with specific LLM SDKs (kept at the example level).
- Multi-region pending (a single placeholder spanning disjoint
  regions).
- Hooks for animation styling beyond `defcustom` knobs.
