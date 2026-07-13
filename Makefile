.PHONY: help dev dev-nix dev-portable build-nix build-cross-nix docker-load-nix docker-run-nix docker-shell-nix docker-smoke-nix test test-list test-shuffle test-pty profile-tui-scroll check-tui-scroll-perf stall-check smoke smoke-mock check check-static check-fennel bench-tui docs docs-serve docs-publish hero-cast graphs graphs-local check-graphs doc-coverage check-docs check-links clean fen install uninstall check-portable check-portable-tools check-portable-docker check-pins distclean

# Tiny convenience frontend. Nix and scripts remain the source of truth.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — run scripts/dev/fen-dev using FEN_BIN or fen on PATH'
	@echo '  dev-nix             — build .#fen, then run scripts/dev/fen-dev from source'
	@echo '  dev-portable        — build build/fen without Nix, then run scripts/dev/fen-dev from source'
	@echo '  build-nix           — build the native Nix binary without creating result symlinks'
	@echo '  build-cross-nix     — build all x86_64-hosted cross binaries in one Nix invocation'
	@echo '  docker-run-nix      — build/load scratch image and run fen (ARGS="--help")'
	@echo '  docker-shell-nix    — build/load scratch image and open /bin/sh'
	@echo '  docker-smoke-nix    — build/load scratch image and run fen --help'
	@echo '  test                — fast local busted test run (TESTS=... BUSTED_ARGS=... to filter)'
	@echo '  test-list           — list Busted test names without running them'
	@echo '  test-shuffle        — run Busted with shuffled order (REPEAT=3 by default)'
	@echo '  test-pty            — opt-in real-PTY TUI smoke test with artifacts'
	@echo '  profile-tui-scroll  — automate a rapid-scroll PTY profile and metrics capture'
	@echo '  check-tui-scroll-perf — fail if the rapid-scroll burst exceeds its wall-time budget'
	@echo '  stall-check         — resource-constrained TUI-stall harness (#167; FEN_DEBUG_CHUNK_DELAY_MS)'
	@echo '  smoke               — live provider smoke test using FEN_BIN or fen on PATH'
	@echo '  smoke-mock          — deterministic local mock-provider smoke test'
	@echo '  check               — fennel-check, generated graph freshness, doc + link validation, and tests'
	@echo '  bench-tui           — run TUI transcript performance harness'
	@echo '  docs                — build all documentation: generated Markdown/JSON, graphs, static HTML site'
	@echo '  docs-serve          — build and serve the docs site locally (PORT=8000; busybox/python/nix)'
	@echo '  docs-publish        — package the deployable site into dist/docs/ (consumed by the Pages workflow)'
	@echo '  hero-cast           — auto-record the "what is fen?" hero demo (needs a provider key) + render GIF/SVG'
	@echo '  graphs              — regenerate tracked docs/graphs/ artifacts (commit when module structure changes)'
	@echo '  fen                 — non-Nix single-file build against system Lua+curl (-> build/fen)'
	@echo '  install             — install build/fen to $$(PREFIX)/bin (default /usr/local)'
	@echo '  check-portable      — build build/fen and run --version/--help/module smoke (exercises the non-Nix path)'
	@echo '  check-portable-docker — build+smoke make fen in a clean Debian container (needs docker)'
	@echo '  check-pins          — verify Makefile third-party pins match flake.lock nixpkgs (needs nix)'
	@echo '  clean               — remove generated local artifacts'
	@echo '  distclean           — clean plus build/ and the third-party source cache'

dev:
	scripts/dev/fen-dev

dev-nix:
	@out=$$(nix build --no-link .#fen --print-out-paths) && \
	FEN_BIN="$$out/bin/fen" scripts/dev/fen-dev

build-nix:
	nix build --no-link --print-out-paths .#fen

build-cross-nix:
	nix build --no-link --print-out-paths \
		.#fen-linux-aarch64-musl-static \
		.#fen-linux-armv7-musleabihf-static \
		.#fen-linux-armv7-n900-musleabihf-static

docker-load-nix:
	nix run .#loadDockerDev

docker-run-nix:
	nix run .#dockerRun -- $(ARGS)

docker-shell-nix:
	nix run .#dockerShell -- $(ARGS)

docker-smoke-nix:
	nix run .#dockerSmoke

test:
	sh scripts/test/run-tests.sh $(TESTS)

test-list:
	BUSTED_ARGS="$${BUSTED_ARGS:-} --list" sh scripts/test/run-tests.sh $(TESTS)

test-shuffle:
	BUSTED_ARGS="$${BUSTED_ARGS:-} --shuffle --repeat=$${REPEAT:-3}" sh scripts/test/run-tests.sh $(TESTS)

test-pty:
	FEN_BUILD_PTY_HELPER=1 sh scripts/test/run-tests.sh extensions/adapters/presenters/tui/tests/smoke/pty_test.fnl

profile-tui-scroll:
	FEN_BUILD_PTY_HELPER=1 BUSTED_ARGS='--tags=scrollprofile' \
		sh scripts/test/run-tests.sh extensions/adapters/presenters/tui/tests/smoke/pty_test.fnl

check-tui-scroll-perf:
	FEN_SCROLL_PROFILE_MAX_MS="$${FEN_SCROLL_PROFILE_MAX_MS:-250}" \
		$(MAKE) profile-tui-scroll

stall-check:
	sh scripts/dev/stall-check.sh

smoke:
	FEN_BIN="$${FEN_BIN:-fen}" scripts/smoke/live.sh

smoke-mock:
	FEN_BIN="$${FEN_BIN:-fen}" scripts/smoke/mock.sh

check: check-static
	sh scripts/test/run-tests.sh $(TESTS)

check-static: check-fennel check-graphs check-docs check-links

check-fennel:
	fennel scripts/test/fennel-check.fnl

bench-tui:
	fennel scripts/test/tui-bench.fnl

docs:
	fennel scripts/docs/gen-docs.fnl
	fennel scripts/docs/gen-graphs.fnl --kind all
	fennel scripts/docs/gen-static-docs.fnl

graphs:
	fennel scripts/docs/gen-graphs.fnl --kind tracked

graphs-local:
	fennel scripts/docs/gen-graphs.fnl --kind local

check-graphs:
	@command -v dot >/dev/null 2>&1 || { echo 'error: Graphviz dot is required for check-graphs (use nix develop)' >&2; exit 127; }
	fennel scripts/docs/gen-graphs.fnl --kind tracked
	git diff --exit-code -- docs/graphs

# Package the publishable docs bundle (analog of dist/fen-* for the binary).
# gen-static-docs emits a self-contained docs/generated/html/ (assets copied in,
# all links local), so the bundle is just that tree plus a .nojekyll marker so
# GitHub Pages serves it verbatim instead of running it through Jekyll.
docs-publish: docs
	rm -rf dist/docs
	mkdir -p dist/docs
	cp -r docs/generated/html/. dist/docs/
	cp scripts/install.sh dist/docs/install.sh
	touch dist/docs/.nojekyll

# Auto-record the hero "what is fen?" demo against a real provider (needs a key
# in the env) and render docs/assets/demo.{gif,svg}. Opt-in; the assets are
# committed. Re-run until you get a good take, and scrub the cast first.
hero-cast:
	sh scripts/docs/record-hero-cast.sh

docs-serve: docs
	@if command -v busybox >/dev/null 2>&1; then \
		exec busybox httpd -f -p "$${PORT:-8000}" -h docs/generated/html; \
	elif command -v python3 >/dev/null 2>&1; then \
		exec python3 -m http.server "$${PORT:-8000}" --directory docs/generated/html; \
	elif command -v nix >/dev/null 2>&1; then \
		exec nix run nixpkgs#busybox -- httpd -f -p "$${PORT:-8000}" -h docs/generated/html; \
	else \
		echo "error: need busybox, python3, or nix to serve docs" >&2; \
		exit 1; \
	fi

doc-coverage:
	@fennel scripts/docs/doc-coverage.fnl

check-docs:
	@fennel scripts/docs/check-docs.fnl

check-links:
	@fennel scripts/docs/check-links.fnl

clean:
	find packages extensions -type d -name dist -prune -exec rm -rf {} +
	find packages extensions -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf dist result result-* tmp build/fen build/fen-lua.zip build/fen-lua.list build/archive-root build/obj

distclean: clean
	rm -rf build third_party/.cache

# --- Non-Nix single-file build (`make fen`) ----------------------------------
# Nix (`nix build .#fen`) stays canonical and is the SOURCE OF TRUTH for the
# native object list, compile flags, and pinned dependency versions in this
# section: keep them in sync with nix/artifacts.nix. This path links against the
# host Lua + libcurl and fetches the same third-party sources the Nix build uses
# (kubazip, lua-cjson, luafilesystem, LuaSocket, fennel, dkjson, and — only when no system
# Lua 5.4 is found — Lua itself). Configuration is inline; there is no separate
# ./configure step. Override on the command line, e.g.
#   make fen LUA=bundled
#   make fen LUA=/opt/lua CURL=/opt/curl PREFIX=/opt
#   make fen OFFLINE=1            # fail instead of downloading
#   make fen FENNEL_LUA=/path/to/fennel.lua
# See docs/distribution.md ("Building without Nix").
#
# Pinned third-party sources (must match nix/artifacts.nix / flake.lock nixpkgs;
# `make check-pins` verifies this). Versions drive the URLs/dirs so each pin has
# one source of truth here; SHAs are independent. lfs tags `.` as `_`.
KUBAZIP_VER := 0.3.5
CJSON_VER := 2.1.0.10
LFS_VER := 1.8.0
LUASOCKET_VER := 3.1.0
FENNEL_VER := 1.6.0
DKJSON_VER := 2.8
LUA_VER := 5.4.7
KUBAZIP_URL := https://github.com/kuba--/zip/archive/refs/tags/v$(KUBAZIP_VER).tar.gz
KUBAZIP_SHA := a586c97074f94bdc0f5259ecbd172365cbbf6d213a4edd770d76dacbb5a978ae
KUBAZIP_DIR := zip-$(KUBAZIP_VER)
CJSON_URL := https://github.com/openresty/lua-cjson/archive/refs/tags/$(CJSON_VER).tar.gz
CJSON_SHA := 0c551d6898f89f876e48730f9b55790d0ba07d5bc0aa6c76153277f63c19489f
CJSON_DIR := lua-cjson-$(CJSON_VER)
LFS_URL := https://github.com/lunarmodules/luafilesystem/archive/refs/tags/v$(subst .,_,$(LFS_VER)).tar.gz
LFS_SHA := 16d17c788b8093f2047325343f5e9b74cccb1ea96001e45914a58bbae8932495
LFS_DIR := luafilesystem-$(subst .,_,$(LFS_VER))
LUASOCKET_URL := https://github.com/lunarmodules/luasocket/archive/refs/tags/v$(LUASOCKET_VER).tar.gz
LUASOCKET_SHA := bf033aeb9e62bcaa8d007df68c119c966418e8c9ef7e4f2d7e96bddeca9cca6e
LUASOCKET_DIR := luasocket-$(LUASOCKET_VER)
FENNEL_URL := https://github.com/bakpakin/Fennel/archive/refs/tags/$(FENNEL_VER).tar.gz
FENNEL_SHA := e1f0e457629aedb1e477140667d50297c52913b6cdcf150701795b7717f9ebec
FENNEL_DIR := Fennel-$(FENNEL_VER)
DKJSON_URL := http://dkolf.de/dkjson-lua/dkjson-$(DKJSON_VER).lua
DKJSON_SHA := eb3bf160688fb395a2db6bc52eeff4f7855a6321d2b41bdc754554d13f4e7d44
LUA_URL := https://www.lua.org/ftp/lua-$(LUA_VER).tar.gz
LUA_SHA := 9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
LUA_DIR := lua-$(LUA_VER)

# Targets that need no toolchain probing live outside the goal-gated block:
# `uninstall` is just rm; `check-pins` only needs the pins above + nix eval.
PREFIX ?= /usr/local
DESTDIR ?=
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/fen"

# Convenience wrapper around the flake check (the single drift-comparison
# implementation, also run by `nix flake check`); reads the *_VER pins above.
check-pins:
	@sys=$$(nix eval --impure --raw --expr builtins.currentSystem); \
		out=$$(nix build ".#checks.$$sys.checkPins" --no-link --print-out-paths) && cat "$$out"

# Real end-to-end smoke of `make fen` on a clean Debian image (apt toolchain +
# network fetch). The genuine non-Nix path; can't run under nix flake check.
check-portable-docker:
	sh scripts/build/portable-docker-smoke.sh

# Probing/fetch only runs when a portable build goal is requested, so `make test`,
# `make uninstall`, and `make check-pins` never shell out to pkg-config or fetch.
PORTABLE_GOALS := fen install dev-portable check-portable
ifneq ($(filter $(PORTABLE_GOALS),$(MAKECMDGOALS)),)

# Tunables (override on the command line). LUA: auto|bundled|DIR. CURL: auto|DIR.
CACHE ?= third_party/.cache
LUA ?= auto
CURL ?= auto
OFFLINE ?= 0
FENNEL ?= fennel
ZIPCMD ?= zip
PKG_CONFIG ?= pkg-config
FENNEL_LUA ?=

# Prefer an explicit CC; otherwise the first of cc/gcc/clang on PATH.
ifeq ($(origin CC),default)
CC := $(shell command -v cc gcc clang 2>/dev/null | head -n1)
endif

FETCH = sh scripts/build/portable-fetch.sh

# --- Lua 5.4: pkg-config, a bundled static build, or an explicit DIR ---------
LUA_BUNDLED_HOME := $(CACHE)/lua
ifeq ($(LUA),auto)
# NB: no `case`/unbalanced `)` inside $(shell ...) — Make would close it early.
LUA_PC_MOD := $(shell for m in lua5.4 lua-5.4 lua54 lua; do \
	$(PKG_CONFIG) --exists $$m 2>/dev/null || continue; \
	$(PKG_CONFIG) --modversion $$m 2>/dev/null | grep -q '^5\.4' || continue; \
	echo $$m; break; \
	done)
ifeq ($(strip $(LUA_PC_MOD)),)
LUA_MODE := bundled
else
LUA_MODE := pkgconfig
endif
else ifeq ($(LUA),bundled)
LUA_MODE := bundled
else
LUA_MODE := dir
endif

ifeq ($(LUA_MODE),pkgconfig)
LUA_CFLAGS := $(shell $(PKG_CONFIG) --cflags $(LUA_PC_MOD))
LUA_LIBS := $(shell $(PKG_CONFIG) --libs $(LUA_PC_MOD))
LUA_DEP :=
LUA_INTERP ?= $(shell command -v lua5.4 lua luajit 2>/dev/null | head -n1)
else ifeq ($(LUA_MODE),bundled)
LUA_CFLAGS := -I$(CURDIR)/$(LUA_BUNDLED_HOME)/include
LUA_LIBS := $(CURDIR)/$(LUA_BUNDLED_HOME)/lib/liblua.a -lm -ldl
LUA_DEP := $(LUA_BUNDLED_HOME)/lib/liblua.a
LUA_INTERP := $(CURDIR)/$(LUA_BUNDLED_HOME)/bin/lua
else
LUA_CFLAGS := -I$(LUA)/include
LUA_LIBS := -L$(LUA)/lib -llua5.4
LUA_DEP :=
LUA_INTERP ?= $(shell command -v lua5.4 lua luajit 2>/dev/null | head -n1)
endif

# --- libcurl: pkg-config, curl-config, an explicit DIR, or a bare -lcurl -----
ifeq ($(CURL),auto)
ifeq ($(shell $(PKG_CONFIG) --exists libcurl 2>/dev/null && echo y),y)
CURL_CFLAGS := $(shell $(PKG_CONFIG) --cflags libcurl)
CURL_LIBS := $(shell $(PKG_CONFIG) --libs libcurl)
else ifneq ($(shell command -v curl-config 2>/dev/null),)
CURL_CFLAGS := $(shell curl-config --cflags)
CURL_LIBS := $(shell curl-config --libs)
else
CURL_CFLAGS :=
CURL_LIBS := -lcurl
endif
else
CURL_CFLAGS := -I$(CURL)/include
CURL_LIBS := -L$(CURL)/lib -lcurl
endif

# --- fennel.lua: build from the pinned source, or use an explicit file -------
ifeq ($(strip $(FENNEL_LUA)),)
FENNEL_LUA_FILE := $(CURDIR)/$(CACHE)/fennel.lua
FENNEL_LUA_DEP := $(FENNEL_LUA_FILE)
else
FENNEL_LUA_FILE := $(FENNEL_LUA)
FENNEL_LUA_DEP :=
endif

# --- resolved third-party source locations -----------------------------------
KUBAZIP_SRC := $(CURDIR)/$(CACHE)/$(KUBAZIP_DIR)/src
KUBAZIP_INC := $(KUBAZIP_SRC)
CJSON_SRC := $(CURDIR)/$(CACHE)/$(CJSON_DIR)
LFS_SRC := $(CURDIR)/$(CACHE)/$(LFS_DIR)/src
LUASOCKET_SRC := $(CURDIR)/$(CACHE)/$(LUASOCKET_DIR)/src
DKJSON_LUA := $(CURDIR)/$(CACHE)/dkjson.lua
KUBAZIP_STAMP := $(CACHE)/$(KUBAZIP_DIR)/.stamp
CJSON_STAMP := $(CACHE)/$(CJSON_DIR)/.stamp
LFS_STAMP := $(CACHE)/$(LFS_DIR)/.stamp
LUASOCKET_STAMP := $(CACHE)/$(LUASOCKET_DIR)/.stamp

# --- version stamp -----------------------------------------------------------
# gitShortRev stays a pure hash to match nix/artifacts.nix; the -dirty marker
# rides only on the version string.
FEN_GIT_REV := $(shell git rev-parse HEAD 2>/dev/null)
FEN_GIT_SHORT := $(shell git rev-parse --short HEAD 2>/dev/null)
FEN_DIRTY := $(shell git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && echo false || echo true)
FEN_VERSION ?= $(if $(FEN_GIT_SHORT),$(FEN_GIT_SHORT)$(if $(filter true,$(FEN_DIRTY)),-dirty),unknown)
ARTIFACT_SYSTEM := $(shell m=$$(uname -m); \
	if [ "$$m" = x86_64 ] || [ "$$m" = amd64 ]; then echo linux-x86_64; \
	elif [ "$$m" = aarch64 ] || [ "$$m" = arm64 ]; then echo linux-aarch64; \
	elif [ "$$m" = armv7l ] || [ "$$m" = armhf ] || [ "$$m" = arm ]; then echo linux-armv7-gnueabihf; \
	else echo "$$(uname -s | tr 'A-Z' 'a-z')-$$m"; fi)

# --- third-party source fetch/extract rules ---------------------------------
$(KUBAZIP_STAMP):
	$(FETCH) tarball $(KUBAZIP_URL) $(KUBAZIP_SHA) $(CACHE)/$(KUBAZIP_DIR).tar.gz $(CACHE) $(OFFLINE)
	mkdir -p $(KUBAZIP_SRC)/zip && cp $(KUBAZIP_SRC)/zip.h $(KUBAZIP_SRC)/zip/zip.h
	@touch $@
$(CJSON_STAMP):
	$(FETCH) tarball $(CJSON_URL) $(CJSON_SHA) $(CACHE)/$(CJSON_DIR).tar.gz $(CACHE) $(OFFLINE)
	@touch $@
$(LFS_STAMP):
	$(FETCH) tarball $(LFS_URL) $(LFS_SHA) $(CACHE)/$(LFS_DIR).tar.gz $(CACHE) $(OFFLINE)
	@touch $@
$(LUASOCKET_STAMP):
	$(FETCH) tarball $(LUASOCKET_URL) $(LUASOCKET_SHA) $(CACHE)/$(LUASOCKET_DIR).tar.gz $(CACHE) $(OFFLINE)
	@touch $@
$(DKJSON_LUA):
	$(FETCH) file $(DKJSON_URL) $(DKJSON_SHA) $@ $(OFFLINE)

# Bundled static Lua (only used when LUA resolves to "bundled").
$(LUA_BUNDLED_HOME)/lib/liblua.a:
	$(FETCH) tarball $(LUA_URL) $(LUA_SHA) $(CACHE)/$(LUA_DIR).tar.gz $(CACHE) $(OFFLINE)
	$(MAKE) -C $(CACHE)/$(LUA_DIR) linux CC='$(CC)' MYCFLAGS=-DLUA_USE_LINUX MYLIBS='-lm -ldl'
	mkdir -p $(LUA_BUNDLED_HOME)/include $(LUA_BUNDLED_HOME)/lib $(LUA_BUNDLED_HOME)/bin
	cp $(CACHE)/$(LUA_DIR)/src/lua.h $(CACHE)/$(LUA_DIR)/src/luaconf.h \
		$(CACHE)/$(LUA_DIR)/src/lualib.h $(CACHE)/$(LUA_DIR)/src/lauxlib.h \
		$(CACHE)/$(LUA_DIR)/src/lua.hpp $(LUA_BUNDLED_HOME)/include/
	cp $(CACHE)/$(LUA_DIR)/src/liblua.a $(LUA_BUNDLED_HOME)/lib/
	cp $(CACHE)/$(LUA_DIR)/src/lua $(LUA_BUNDLED_HOME)/bin/ 2>/dev/null || true

# fennel.lua runtime library, built with whatever Lua interpreter is available.
$(FENNEL_LUA_FILE): $(LUA_DEP)
	@[ -x '$(LUA_INTERP)' ] || { echo 'error: no usable Lua interpreter to build fennel.lua (set LUA_INTERP= or FENNEL_LUA=)' >&2; exit 1; }
	$(FETCH) tarball $(FENNEL_URL) $(FENNEL_SHA) $(CACHE)/$(FENNEL_DIR).tar.gz $(CACHE) $(OFFLINE)
	$(MAKE) -C $(CACHE)/$(FENNEL_DIR) fennel.lua LUA='$(LUA_INTERP)'
	cp $(CACHE)/$(FENNEL_DIR)/fennel.lua $@

# --- native objects (same set/flags as nix/artifacts.nix fenBinaryObjects) ---
FEN_OBJDIR := build/obj
FEN_CFLAGS := -O2 -Wall $(LUA_CFLAGS)
FEN_TB_INC := extensions/adapters/presenters/tui/vendor
# Single source of truth shared with nix/artifacts.nix (fenBinaryObjects).
LUASOCKET_C_SRCS := $(shell cat scripts/build/luasocket-c-modules.txt)
LUASOCKET_OBJS := $(addprefix $(FEN_OBJDIR)/luasocket-,$(addsuffix .o,$(LUASOCKET_C_SRCS)))
FEN_OBJS := \
	$(FEN_OBJDIR)/lua_termbox2.o \
	$(FEN_OBJDIR)/fen_http.o \
	$(FEN_OBJDIR)/fen_process.o \
	$(FEN_OBJDIR)/fen_random.o \
	$(FEN_OBJDIR)/lfs.o \
	$(FEN_OBJDIR)/lua_cjson.o \
	$(FEN_OBJDIR)/strbuf.o \
	$(FEN_OBJDIR)/fpconv.o \
	$(FEN_OBJDIR)/zip.o \
	$(LUASOCKET_OBJS)

$(FEN_OBJDIR):
	@mkdir -p $@

# Every object needs Lua headers; in bundled mode that means building Lua first.
$(FEN_OBJS): $(LUA_DEP)

$(FEN_OBJDIR)/lua_termbox2.o: $(FEN_TB_INC)/lua_termbox2.c | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -I$(FEN_TB_INC) -c $< -o $@
$(FEN_OBJDIR)/fen_http.o: packages/util/vendor/fen_http.c | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) $(CURL_CFLAGS) -c $< -o $@
$(FEN_OBJDIR)/fen_process.o: packages/util/vendor/fen_process.c | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -c $< -o $@
$(FEN_OBJDIR)/fen_random.o: packages/util/vendor/fen_random.c | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -c $< -o $@
$(FEN_OBJDIR)/lfs.o: $(LFS_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -c $(LFS_SRC)/lfs.c -o $@
$(FEN_OBJDIR)/luasocket-%.o: $(LUASOCKET_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -DLUASOCKET_NODEBUG -I$(LUASOCKET_SRC) -c $(LUASOCKET_SRC)/$*.c -o $@
$(FEN_OBJDIR)/lua_cjson.o: $(CJSON_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -DNDEBUG -fPIC -c $(CJSON_SRC)/lua_cjson.c -o $@
$(FEN_OBJDIR)/strbuf.o: $(CJSON_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -DNDEBUG -fPIC -c $(CJSON_SRC)/strbuf.c -o $@
$(FEN_OBJDIR)/fpconv.o: $(CJSON_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -DNDEBUG -fPIC -c $(CJSON_SRC)/fpconv.c -o $@
$(FEN_OBJDIR)/zip.o: $(KUBAZIP_STAMP) | $(FEN_OBJDIR)
	$(CC) $(FEN_CFLAGS) -D_DEFAULT_SOURCE -DZIP_HAVE_SYMLINK=1 -I$(KUBAZIP_SRC) -c $(KUBAZIP_SRC)/zip.c -o $@

check-portable-tools:
	@command -v $(FENNEL) >/dev/null 2>&1 || { echo 'error: the fennel CLI is required (luarocks install fennel)' >&2; exit 1; }
	@command -v $(ZIPCMD) >/dev/null 2>&1 || { echo 'error: the zip CLI is required' >&2; exit 1; }
	@[ -n '$(CC)' ] || { echo 'error: no C compiler found (set CC=)' >&2; exit 1; }

fen: $(FEN_OBJS) $(FENNEL_LUA_DEP) $(DKJSON_LUA) | check-portable-tools
	@echo 'fen: linking build/fen (lua=$(LUA_MODE), $(FEN_VERSION), $(ARTIFACT_SYSTEM))'
	$(CC) $(FEN_CFLAGS) -I$(KUBAZIP_INC) packages/fen/fen.c $(FEN_OBJS) \
		$(LUA_LIBS) $(CURL_LIBS) -lm -o build/fen
	FENNEL='$(FENNEL)' ZIPCMD='$(ZIPCMD)' FENNEL_LUA='$(FENNEL_LUA_FILE)' \
		DKJSON_LUA='$(DKJSON_LUA)' LUASOCKET_SRC='$(LUASOCKET_SRC)' FEN_VERSION='$(FEN_VERSION)' \
		FEN_GIT_REV='$(FEN_GIT_REV)' FEN_GIT_SHORT='$(FEN_GIT_SHORT)' \
		FEN_DIRTY='$(FEN_DIRTY)' ARTIFACT_SYSTEM='$(ARTIFACT_SYSTEM)' \
		sh scripts/build/portable-pack.sh build/fen
	@echo 'built build/fen ($(FEN_VERSION), $(ARTIFACT_SYSTEM))'

install: fen
	install -Dm755 build/fen "$(DESTDIR)$(PREFIX)/bin/fen"
	@echo "installed $(DESTDIR)$(PREFIX)/bin/fen"

# Build the non-Nix binary and smoke it. This is how the portable path is
# exercised; there is no GitHub CI and the Nix sandbox cannot fetch, so run this
# in a dev shell / on Debian before relying on the path.
check-portable: fen
	./build/fen --version
	@./build/fen --help >/dev/null && echo 'check-portable: --version/--help ok'
	@env -u LUA_PATH -u LUA_CPATH -u FEN_ROCKS_TREE ./build/fen eval 'local socket = require("socket"); assert(socket.bind); assert(require("mime")); assert(require("socket.http")); assert(require("socket.unix")); assert(require("socket.serial")); print("check-portable: LuaSocket ok")'

dev-portable: fen
	FEN_BIN="$(CURDIR)/build/fen" scripts/dev/fen-dev $(ARGS)

endif
