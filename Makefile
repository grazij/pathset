BINARY = pathset
VERSION ?= 0.4.0
PREFIX ?= /usr/local
CC ?= cc
# CFLAGS belongs to whoever is doing the build: override it freely, including
# from the command line. No -O level is set here on purpose — optimization is
# the packager's call, and Homebrew's compiler shim discards any -O it is
# handed and substitutes its own regardless.
CFLAGS ?= -Wall -Wextra -Wpedantic

# Flags pathset needs to compile correctly. These are not negotiable, so they
# live outside CFLAGS where an override cannot delete them. Dropping
# -DPATHSET_VERSION in particular would silently build a binary whose -V
# reports "unknown".
REQUIRED_CFLAGS = -std=c11 -DPATHSET_VERSION=\"$(VERSION)\"

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
	REQUIRED_CFLAGS += -mmacosx-version-min=11.0
	UNIVERSAL_FLAGS = -arch arm64 -arch x86_64
else
	UNIVERSAL_FLAGS =
endif

# CFLAGS last so the builder still wins on warnings and optimization.
ALL_CFLAGS = $(REQUIRED_CFLAGS) $(CPPFLAGS) $(CFLAGS)

# `build` and `release` produce a native single-arch binary so source-based
# installers (e.g. Homebrew compiling on the user's host) don't pay for a
# fat binary they won't use. Use `universal` / `release-universal` when
# producing a distribution artifact that needs to run on both arm64 and
# x86_64 macOS.
ARCH_FLAGS ?=

# Homebrew tap location and GitHub coordinates used by the `formula` target.
# Override on the command line if your layout differs:
#   make formula TAP_DIR=../my-tap GITHUB_USER=alice GITHUB_REPO=pathset
TAP_DIR ?= ../homebrew-tap
GITHUB_USER ?= grazij
GITHUB_REPO ?= pathset

.PHONY: all build test clean install uninstall run lint release universal release-universal man formula formula-verify

all: build

build: $(BINARY)

$(BINARY): pathset.c
	$(CC) $(ALL_CFLAGS) $(ARCH_FLAGS) $(LDFLAGS) -o $@ $<

# Maintainer target: a from-scratch build plus the test suite, run before
# tagging. Does not regenerate the man page — `make man` is a separate
# deliberate step, so no build target depends on help2man. The Homebrew
# formula runs plain `make build`; it neither tests nor generates docs on the
# user's machine.
release: clean build test
	@echo
	@./$(BINARY) -V
	@echo "==> $(BINARY) $(VERSION) ready (native single-arch)."
	@echo "    if you changed the -h/-V text: 'make man' and commit $(BINARY).1"
	@echo "    next: bump VERSION in Makefile if needed, then 'git tag v$(VERSION) && git push --tags'"

# macOS fat binary (arm64 + x86_64). No-op on non-Darwin hosts.
universal: ARCH_FLAGS = $(UNIVERSAL_FLAGS)
universal: clean build

release-universal: ARCH_FLAGS = $(UNIVERSAL_FLAGS)
release-universal: clean build test
	@echo
	@./$(BINARY) -V
	@lipo -info ./$(BINARY) 2>/dev/null || true
	@echo "==> $(BINARY) $(VERSION) ready (universal fat binary)."
	@echo "    if you changed the -h/-V text: 'make man' and commit $(BINARY).1"
	@echo "    next: bump VERSION in Makefile if needed, then 'git tag v$(VERSION) && git push --tags'"

test: build
	./tests/run.sh

clean:
	rm -f $(BINARY)

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(BINARY) $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	@if [ -f $(BINARY).1 ]; then \
		install -d $(DESTDIR)$(PREFIX)/share/man/man1; \
		install -m 0644 $(BINARY).1 $(DESTDIR)$(PREFIX)/share/man/man1/$(BINARY).1; \
	fi

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BINARY)
	rm -f $(DESTDIR)$(PREFIX)/share/man/man1/$(BINARY).1

# Regenerate the man page from the binary's -h / -V output. Requires help2man
# (brew install help2man / apt install help2man), which is why this is a
# maintainer-only step run before tagging: the generated page is committed, so
# nobody installing pathset needs help2man.
man: build
	help2man --help-option=-h --version-option=-V --no-info \
		--name="manage your shell PATH from a config file" \
		./$(BINARY) -o $(BINARY).1

run: build
	-./$(BINARY) -c examples/path.example

lint:
	$(CC) $(ALL_CFLAGS) -fsyntax-only pathset.c

# Bump the Homebrew formula to v$(VERSION): compute the SHA256 of the
# tagged tarball, rewrite Formula/pathset.rb, commit + push here, then
# mirror to TAP_DIR and commit + push there. Assumes the tag has already
# been pushed to GitHub.
formula:
	@set -e; \
	echo "==> $(BINARY) $(VERSION) — bumping Homebrew formula"; \
	if [ ! -d "$(TAP_DIR)/Formula" ]; then \
		echo "error: $(TAP_DIR)/Formula not found (override with TAP_DIR=...)" >&2; \
		exit 1; \
	fi; \
	tarball="https://github.com/$(GITHUB_USER)/$(GITHUB_REPO)/archive/refs/tags/v$(VERSION).tar.gz"; \
	echo "    fetching $$tarball"; \
	tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	curl -fsSL "$$tarball" -o "$$tmp"; \
	sha=$$(shasum -a 256 "$$tmp" | awk '{print $$1}'); \
	if [ -z "$$sha" ]; then \
		echo "error: empty SHA — is tag v$(VERSION) pushed to $(GITHUB_USER)/$(GITHUB_REPO)?" >&2; \
		exit 1; \
	fi; \
	echo "    sha256: $$sha"; \
	sed -i.bak -E "s|^(  url )\".*\"|\1\"$$tarball\"|" Formula/pathset.rb; \
	sed -i.bak -E "s|^(  sha256 )\".*\"|\1\"$$sha\"|" Formula/pathset.rb; \
	rm -f Formula/pathset.rb.bak; \
	git add Formula/pathset.rb; \
	git commit -m "chore(formula): bump to v$(VERSION)"; \
	git push origin main; \
	cp Formula/pathset.rb "$(TAP_DIR)/Formula/pathset.rb"; \
	cd "$(TAP_DIR)" && \
		git add Formula/pathset.rb && \
		git diff --cached --stat && \
		git commit -m "$(BINARY) $(VERSION)" && \
		git push origin main; \
	echo "==> formula published to $(GITHUB_USER)/homebrew-tap"; \
	echo "    sanity check: make formula-verify"

# First-time / sanity-check install via the published tap.
formula-verify:
	brew untap $(GITHUB_USER)/tap 2>/dev/null || true
	brew tap $(GITHUB_USER)/tap
	brew install $(GITHUB_USER)/tap/$(BINARY)
	$(BINARY) -V
	brew uninstall $(BINARY)
