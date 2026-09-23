# ccseat: make install, make uninstall, make test, make lint.
#
#   make install                   PREFIX=/usr/local (may need sudo)
#   make install PREFIX="$HOME/.local"   a per-user install
#   make install DESTDIR=/tmp/pkg  staged install for packagers
#
# The program and its library go to $(PREFIX)/share/ccseat; $(PREFIX)/bin/ccseat
# is a link to it (the entrypoint follows links to find its library).

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/ccseat

SHELLCHECK ?= shellcheck
TEST_ARGS ?=

LIB_FILES = $(wildcard lib/ccseat/*.sh)
LINT_FILES = bin/ccseat $(LIB_FILES) install.sh tests/run.sh tests/lib.sh \
	$(wildcard tests/test_*.sh) $(wildcard tests/stubs/*)

.PHONY: all install uninstall test lint check help

all: help

help:
	@echo "make install     install into PREFIX (default /usr/local)"
	@echo "make uninstall   remove what make install put in PREFIX"
	@echo "make test        run the test suite (TEST_ARGS='-j 4 pattern' to narrow it)"
	@echo "make lint        run shellcheck on every script"
	@echo "make check       lint, then test"

install:
	install -d "$(DESTDIR)$(SHAREDIR)/bin" "$(DESTDIR)$(SHAREDIR)/lib/ccseat" "$(DESTDIR)$(BINDIR)"
	install -m 755 bin/ccseat "$(DESTDIR)$(SHAREDIR)/bin/ccseat"
	install -m 644 $(LIB_FILES) "$(DESTDIR)$(SHAREDIR)/lib/ccseat/"
	install -m 644 LICENSE "$(DESTDIR)$(SHAREDIR)/LICENSE"
	ln -sf "$(SHAREDIR)/bin/ccseat" "$(DESTDIR)$(BINDIR)/ccseat"
	@echo "Installed ccseat into $(DESTDIR)$(BINDIR)/ccseat"
	@echo "Next: add  eval \"\$$(ccseat init zsh)\"  to ~/.zshrc (or bash; fish: ccseat init fish | source)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/ccseat"
	rm -f "$(DESTDIR)$(SHAREDIR)/bin/ccseat" "$(DESTDIR)$(SHAREDIR)/LICENSE"
	rm -f "$(DESTDIR)$(SHAREDIR)"/lib/ccseat/*.sh
	-rmdir "$(DESTDIR)$(SHAREDIR)/lib/ccseat" "$(DESTDIR)$(SHAREDIR)/lib" "$(DESTDIR)$(SHAREDIR)/bin" "$(DESTDIR)$(SHAREDIR)" 2>/dev/null
	@echo "Removed ccseat from $(DESTDIR)$(PREFIX). Seats and settings were kept."

test:
	@bash tests/run.sh $(TEST_ARGS)

lint:
	$(SHELLCHECK) $(LINT_FILES)

check: lint test
