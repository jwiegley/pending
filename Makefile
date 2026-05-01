EMACS ?= emacs

DOCDIR  = doc
TEXI    = $(DOCDIR)/pending.texi
INFO    = $(DOCDIR)/pending.info
HTML    = $(DOCDIR)/pending.html

.PHONY: all compile test docs info html clean clean-docs

all: compile

compile:
	@eask compile

test:
	@eask test ert pending-test.el

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
