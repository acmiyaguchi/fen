.PHONY: build debug-build run run-debug run-gdb run-valgrind test smoke fennel-check clean dist help

FENNEL ?= fennel
LUA    ?= lua

SRC_DIR    := src
DIST_DIR   := dist
VENDOR_DIR := vendor

FNL_SOURCES := $(shell find $(SRC_DIR) -name '*.fnl')
LUA_OUTPUTS := $(patsubst $(SRC_DIR)/%.fnl,$(DIST_DIR)/%.lua,$(FNL_SOURCES))
VERSION_FILE := $(DIST_DIR)/version.lua
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

# Vendored C binding for termbox2: there's no published lua-termbox2 rock,
# so we ship a small Lua-C shim around termbox2.h. The dev shell exports
# LUA_INCDIR pointing at ${pkgs.lua5_4}/include; outside nix you may need
# to override it (e.g. LUA_INCDIR=/usr/include/lua5.4).
CC         ?= cc
CFLAGS       ?= -O2 -fPIC -Wall
DEBUG_CFLAGS ?= -O0 -g3 -ggdb -fPIC -Wall -fno-omit-frame-pointer
LUA_INCDIR ?= /usr/include/lua5.4
TERMBOX_SO := $(DIST_DIR)/termbox2.so

# Globals allowed in src/ files (standard Lua 5.4).
FNL_SRC_GLOBALS := print,pairs,ipairs,tostring,tonumber,require,dofile,os,io,string,table,math,coroutine,error,pcall,xpcall,type,next,select,assert,unpack,rawget,rawset,setmetatable,getmetatable,collectgarbage,_G,bit32
# Globals allowed in tests/ (standard Lua + busted BDD).
FNL_TEST_GLOBALS := $(FNL_SRC_GLOBALS),describe,it,before_each,after_each,setup,teardown,pending,finally,insulate,expose

help:
	@echo 'fen make targets:'
	@echo '  build         — compile Fennel sources + vendored termbox2 binding into dist/'
	@echo '  debug-build   — rebuild with C debug symbols/frame pointers'
	@echo '  fennel-check  — lint-check all .fnl files (compile + strict-globals)'
	@echo '  run           — build then launch interactive TUI'
	@echo '  run-debug     — debug-build, enable core dumps, then launch TUI'
	@echo '  run-gdb       — debug-build, then launch Lua under gdb'
	@echo '  run-valgrind  — debug-build, then launch Lua under valgrind (Linux)'
	@echo '  test          — run tests/**/*_test.fnl'
	@echo '  smoke         — live --print round-trip against each configured provider'
	@echo '  dist   — tarball dist/ + bin/ + README.md'
	@echo '  clean  — remove dist/'

build: $(LUA_OUTPUTS) $(TERMBOX_SO) $(VERSION_FILE)

$(DIST_DIR)/%.lua: $(SRC_DIR)/%.fnl
	@mkdir -p $(dir $@)
	$(FENNEL) --compile $< > $@

$(TERMBOX_SO): $(VENDOR_DIR)/lua_termbox2.c $(VENDOR_DIR)/termbox2.h
	@mkdir -p $(DIST_DIR)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -I$(VENDOR_DIR) -shared $< -o $@

.PHONY: FORCE
FORCE:

$(VERSION_FILE): FORCE
	@mkdir -p $(DIST_DIR)
	@printf 'return "%s"\n' '$(VERSION)' > $@

debug-build:
	$(MAKE) clean
	$(MAKE) CFLAGS="$(DEBUG_CFLAGS)" build

run: build
	./bin/fen

# Crash-capture helper: builds the C termbox shim with symbols, enables core
# dumps for this process tree, and prints the usual post-mortem commands if the
# Lua process dies from a signal (SIGSEGV exits as 139).
run-debug: debug-build
	@ulimit -c unlimited 2>/dev/null || true; \
	printf '%s\n' 'debug: core dumps enabled where the OS permits them'; \
	printf '%s\n' 'debug: on NixOS/systemd use: coredumpctl debug lua'; \
	./bin/fen; \
	rc=$$?; \
	if [ $$rc -ge 128 ]; then \
		sig=$$(($$rc - 128)); \
		printf '\nfen died from signal %s (exit %s)\n' "$$sig" "$$rc"; \
		printf '%s\n' 'Try: coredumpctl list lua'; \
		printf '%s\n' 'Then: coredumpctl debug lua   # in gdb: bt full'; \
	fi; \
	exit $$rc

# Run the actual Lua interpreter under gdb rather than debugging the shell
# launcher. gdb inherits the LUA_* paths needed to load dist/main.lua and
# dist/termbox2.so.
run-gdb: debug-build
	@LUA="$${FEN_LUA:-$(LUA)}"; \
	LUA_PATH="$(PWD)/dist/?.lua;$(PWD)/dist/?/init.lua;$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;$${LUA_PATH:-;}" \
	LUA_CPATH="$(PWD)/dist/?.so;$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-;}" \
	gdb --args "$$LUA" "$(PWD)/dist/main.lua"

run-valgrind: debug-build
	@LUA="$${FEN_LUA:-$(LUA)}"; \
	LUA_PATH="$(PWD)/dist/?.lua;$(PWD)/dist/?/init.lua;$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;$${LUA_PATH:-;}" \
	LUA_CPATH="$(PWD)/dist/?.so;$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-;}" \
	valgrind --tool=memcheck --track-origins=yes --leak-check=full "$$LUA" "$(PWD)/dist/main.lua"

TEST_FILES := $(shell find tests -name '*_test.fnl' | sort)

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
	for f in $(TEST_FILES); do \
		if ! $(FENNEL) --compile --add-fennel-path './tests/?.fnl' --add-fennel-path './tests/support/?.fnl' --add-fennel-path './tests/?/init.fnl' --add-macro-path './tests/?.fnl' --add-macro-path './tests/support/?.fnl' --globals '$(FNL_TEST_GLOBALS)' "$$f" > /dev/null 2>&1; then \
			echo "FAIL: $$f"; \
			$(FENNEL) --compile --add-fennel-path './tests/?.fnl' --add-fennel-path './tests/support/?.fnl' --add-fennel-path './tests/?/init.fnl' --add-macro-path './tests/?.fnl' --add-macro-path './tests/support/?.fnl' --globals '$(FNL_TEST_GLOBALS)' "$$f" 2>&1 | head -5; \
			rc=1; \
		fi; \
	done; \
	[ $$rc -eq 0 ] && echo 'All Fennel files check OK.'

dist: build
	tar czf fen-dist.tar.gz dist bin README.md

clean:
	rm -rf $(DIST_DIR) fen-dist.tar.gz
