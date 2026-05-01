EMACS ?= emacs
EMACS_BATCH ?= $(EMACS) --batch -L .
# Like EMACS_BATCH but goes through `eask emacs' so the eask-installed
# package archive (`.eask/<emacs-version>/elpa') is on `load-path'.
# Used for byte-compile steps that need optional deps (e.g. `aio' for
# `pending-aio.el').
EMACS_EASK ?= eask emacs --batch -L .

DOCDIR  = doc
TEXI    = $(DOCDIR)/pending.texi
INFO    = $(DOCDIR)/pending.info
HTML    = $(DOCDIR)/pending.html

.PHONY: all compile test docs info html clean clean-docs \
        format format-check lint coverage profile warnings all-checks

all: compile

compile:
	@eask compile

test:
	@eask test ert pending-test.el pending-aio-test.el

docs: info

info: $(INFO)

html: $(HTML)

$(INFO): $(TEXI)
	makeinfo -o $@ $<

$(HTML): $(TEXI)
	makeinfo --html --no-split -o $@ $<

clean-docs:
	@rm -f $(INFO) $(HTML)

clean: clean-docs
	@eask clean all

# `format' --- indent every .el file in place via Emacs's indent-region.
# (Elisp has no canonical formatter; we enforce reproducible indent-region
# with spaces. Each file is loaded first so its `defmacro' forms with
# `(declare (indent ...))' register before we re-indent.)
# `enable-local-variables' / `enable-local-eval' are disabled so a
# malicious file-local form cannot execute arbitrary code under our
# format target.
format:
	$(EMACS_BATCH) --eval "(setq enable-local-variables nil enable-local-eval nil)" \
	  --eval "(setq-default indent-tabs-mode nil)" \
	  --eval "(load \"./pending.el\" nil t)" \
	  --eval "(load \"./pending-test.el\" nil t)" \
	  --eval "(dolist (f (directory-files \".\" t \"\\\\.el\\\\'\")) (find-file f) (emacs-lisp-mode) (setq indent-tabs-mode nil) (let ((inhibit-message t)) (indent-region (point-min) (point-max))) (when (buffer-modified-p) (save-buffer)))"

# `format-check` --- fail if `make format` would change anything.
format-check:
	@./scripts/format-check.sh

# `lint` --- package-lint + checkdoc + byte-compile -W=error.
# The byte-compile step needs `aio' on `load-path' to compile
# `pending-aio.el'; we go through `eask emacs' so the eask-installed
# package archive is visible.
lint:
	@eask lint package
	@eask lint checkdoc
	$(EMACS_EASK) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile pending.el pending-aio.el pending-test.el pending-aio-test.el

# `coverage` --- run tests under undercover.el and emit lcov.
coverage:
	@./scripts/coverage.sh

# `profile` --- run benchmark suite, emit profile-report.txt.
profile:
	@./scripts/profile.sh

# `warnings` --- verify clean compile (alias for byte-compile -W=error).
# Goes through `eask emacs' for the same reason as `lint': `pending-
# aio.el' needs `aio' on `load-path'.
warnings:
	$(EMACS_EASK) --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile pending.el pending-aio.el pending-test.el pending-aio-test.el

# `all-checks` --- what CI runs.
all-checks: warnings test lint format-check docs coverage

# Memory sanitizer: N/A for Elisp (garbage-collected; no manual
# memory management).
# fuzz: not implemented for Elisp (no widely-adopted Elisp fuzzer).
