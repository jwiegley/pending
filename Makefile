EMACS ?= emacs

.PHONY: all compile test clean

all: compile

compile:
	@eask compile

test:
	@eask test ert pending-test.el

clean:
	@eask clean all
