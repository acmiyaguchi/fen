.PHONY: build debug-build run run-debug run-gdb run-valgrind test smoke fennel-check clean dist help install-local check-deps rockspecs

FENNEL  ?= fennel
LUA     ?= lua
LUAROCKS ?= luarocks
CC      ?= cc
CFLAGS  ?= -O2 -fPIC -Wall
DEBUG_CFLAGS ?= -O0 -g3 -ggdb -fPIC -Wall -fno-omit-frame-pointer
LUA_INCDIR ?= /usr/include/lua5.4

PACKAGE_DIRS := packages/util packages/core \
	packages/providers/openai packages/providers/openai-codex packages/providers/anthropic \
	packages/extensions/builtin-tools packages/extensions/builtin-commands packages/extensions/default-prompt \
	packages/extensions/tui packages/extensions/mem packages/extensions/skills \
	packages/extensions/agent-state packages/extensions/handoff packages/fen

# Dependency order for local LuaRocks installs.
ROCK_DIRS := packages/util packages/core \
	packages/providers/openai packages/providers/openai-codex packages/providers/anthropic \
	packages/extensions/builtin-tools packages/extensions/builtin-commands packages/extensions/default-prompt \
	packages/extensions/tui packages/extensions/mem packages/extensions/skills \
	packages/extensions/agent-state packages/extensions/handoff packages/fen

# Globals allowed in src/ files (standard Lua 5.4).
FNL_SRC_GLOBALS := print,pairs,ipairs,tostring,tonumber,require,dofile,os,io,string,table,math,coroutine,error,pcall,xpcall,type,next,select,assert,unpack,rawget,rawset,setmetatable,getmetatable,collectgarbage,_G,bit32,debug
# Globals allowed in tests/ (standard Lua + busted BDD).
FNL_TEST_GLOBALS := $(FNL_SRC_GLOBALS),describe,it,before_each,after_each,setup,teardown,pending,finally,insulate,expose

FNL_SOURCES := $(shell find packages -path '*/src/*.fnl' -type f | sort)
PKG_SRC_PATHS := $(foreach d,$(PACKAGE_DIRS),./$(d)/src/?.fnl ./$(d)/src/?/init.fnl)
TEST_FILES := $(shell find tests -name '*_test.fnl' | sort)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
TERMBOX_SO := packages/extensions/tui/dist/termbox2.so

help:
	@echo 'fen workspace targets:'
	@echo '  build            — compile all package src/ trees into package dist/'
	@echo '  debug-build      — rebuild packages with C debug symbols/frame pointers'
	@echo '  fennel-check     — lint-check all .fnl files (compile + strict-globals)'
	@echo '  test             — run tests/**/*_test.fnl across package src/ trees'
	@echo '  smoke            — live --print round-trip against each configured provider'
	@echo '  check-deps       — verify cross-package require declarations'
	@echo '  rockspecs        — regenerate checked-in rockspecs'
	@echo '  install-local    — luarocks make all rocks into ./lua_modules and smoke fen --help'
	@echo '  clean            — remove all package dist/ trees and fen-dist.tar.gz'

build:
	@set -eu; \
	for f in $(FNL_SOURCES); do \
		pkg=$${f%%/src/*}; \
		rel=$${f#$$pkg/src/}; \
		out=$$pkg/dist/$${rel%.fnl}.lua; \
		mkdir -p "$$(dirname "$$out")"; \
		echo "$(FENNEL) --compile $$f > $$out"; \
		$(FENNEL) --compile "$$f" > "$$out"; \
	done; \
	mkdir -p packages/fen/dist/fen; \
	printf 'return "%s"\n' '$(VERSION)' > packages/fen/dist/fen/version.lua
	$(MAKE) $(TERMBOX_SO)

$(TERMBOX_SO): packages/extensions/tui/vendor/lua_termbox2.c packages/extensions/tui/vendor/termbox2.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ipackages/extensions/tui/vendor -shared $< -o $@

debug-build:
	$(MAKE) clean
	$(MAKE) CFLAGS="$(DEBUG_CFLAGS)" build

run: build
	./bin/fen

run-debug: debug-build
	@ulimit -c unlimited 2>/dev/null || true; \
	printf '%s\n' 'debug: core dumps enabled where the OS permits them'; \
	./bin/fen; \
	rc=$$?; \
	if [ $$rc -ge 128 ]; then \
		sig=$$(($$rc - 128)); \
		printf '\nfen died from signal %s (exit %s)\n' "$$sig" "$$rc"; \
		printf '%s\n' 'Try: coredumpctl list lua'; \
		printf '%s\n' 'Then: coredumpctl debug lua   # in gdb: bt full'; \
	fi; \
	exit $$rc

run-gdb: debug-build
	@LUA="$${FEN_LUA:-$(LUA)}"; \
	LUA_PATH="$$(./scripts/ws-lua-path.sh);$${LUA_PATH:-;}" \
	LUA_CPATH="$(PWD)/packages/extensions/tui/dist/?.so;$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-;}" \
	gdb --args "$$LUA" "$(PWD)/bin/fen.lua"

run-valgrind: debug-build
	@LUA="$${FEN_LUA:-$(LUA)}"; \
	LUA_PATH="$$(./scripts/ws-lua-path.sh);$${LUA_PATH:-;}" \
	LUA_CPATH="$(PWD)/packages/extensions/tui/dist/?.so;$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-;}" \
	valgrind --tool=memcheck --track-origins=yes --leak-check=full "$$LUA" "$(PWD)/bin/fen.lua"

test:
	busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test $(TEST_FILES)

smoke: build
	./scripts/smoke.sh

fennel-check:
	@rc=0; \
	for f in $(FNL_SOURCES); do \
		if ! $(FENNEL) --compile --globals '$(FNL_SRC_GLOBALS)' "$$f" > /dev/null 2>&1; then \
			echo "FAIL: $$f"; \
			$(FENNEL) --compile --globals '$(FNL_SRC_GLOBALS)' "$$f" 2>&1 | head -5; \
			rc=1; \
		fi; \
	done; \
	paths='$(PKG_SRC_PATHS)'; \
	for f in $(TEST_FILES); do \
		args=''; for p in $$paths; do args="$$args --add-fennel-path $$p"; done; \
		if ! $(FENNEL) --compile $$args --add-fennel-path './tests/?.fnl' --add-fennel-path './tests/support/?.fnl' --add-fennel-path './tests/?/init.fnl' --add-macro-path './tests/?.fnl' --add-macro-path './tests/support/?.fnl' --globals '$(FNL_TEST_GLOBALS)' "$$f" > /dev/null 2>&1; then \
			echo "FAIL: $$f"; \
			$(FENNEL) --compile $$args --add-fennel-path './tests/?.fnl' --add-fennel-path './tests/support/?.fnl' --add-fennel-path './tests/?/init.fnl' --add-macro-path './tests/?.fnl' --add-macro-path './tests/support/?.fnl' --globals '$(FNL_TEST_GLOBALS)' "$$f" 2>&1 | head -5; \
			rc=1; \
		fi; \
	done; \
	[ $$rc -eq 0 ] && echo 'All Fennel files check OK.'; \
	exit $$rc

check-deps:
	./scripts/ws-check-deps.sh

rockspecs:
	./scripts/gen-rockspec.sh

install-local:
	@rm -rf lua_modules
	@set -eu; \
	for d in $(ROCK_DIRS); do \
		rock=$$(find $$d -maxdepth 1 -name '*.rockspec' | sort | head -1); \
		echo "$(LUAROCKS) make $$rock"; \
		( \
			export PATH="$(PWD)/lua_modules/bin:$$PATH"; \
			export LUA_PATH="$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;$${LUA_PATH:-}"; \
			export LUA_CPATH="$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-}"; \
			cd $$d && $(LUAROCKS) --tree="$(PWD)/lua_modules" make --deps-mode=all "$$(basename $$rock)" LUA_INCDIR="$${LUA_INCDIR:-}" CURL_INCDIR="$${CURL_INCDIR:-}" CURL_LIBDIR="$${CURL_LIBDIR:-}"; \
		); \
	done
	@PATH="$(PWD)/lua_modules/bin:$$PATH" \
	 LUA_PATH="$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;;" \
	 LUA_CPATH="$(PWD)/lua_modules/lib/lua/5.4/?.so;;" \
	 fen --help >/dev/null
	@echo 'local LuaRocks install OK.'

dist: build
	tar czf fen-dist.tar.gz packages/*/dist packages/*/*/dist bin README.md

clean:
	find packages -type d -name dist -prune -exec rm -rf {} +
	find packages -type d -name .luarocks-build -prune -exec rm -rf {} +
	find packages -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf fen-dist.tar.gz
