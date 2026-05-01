.PHONY: build run test smoke fennel-check clean dist help install-local install-local-clean

FENNEL  ?= fennel
LUAROCKS ?= luarocks
CC      ?= cc
CFLAGS  ?= -O2 -fPIC -Wall
LUA_INCDIR ?= /usr/include/lua5.4

# Local rocks in dependency order: shared libs first, leaves next, CLI last.
ROCKSPECS := $(wildcard packages/util/*.rockspec) $(wildcard packages/core/*.rockspec) \
	$(sort $(wildcard packages/providers/*/*.rockspec packages/extensions/*/*.rockspec)) \
	$(wildcard packages/fen/*.rockspec)

# Globals allowed in src/ files (standard Lua 5.4).
FNL_SRC_GLOBALS := print,pairs,ipairs,tostring,tonumber,require,dofile,os,io,string,table,math,coroutine,error,pcall,xpcall,type,next,select,assert,unpack,rawget,rawset,setmetatable,getmetatable,collectgarbage,_G,bit32,debug
# Globals allowed in tests/ (standard Lua + busted BDD).
FNL_TEST_GLOBALS := $(FNL_SRC_GLOBALS),describe,it,before_each,after_each,setup,teardown,pending,finally,insulate,expose

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
TERMBOX_SO := packages/extensions/tui/dist/termbox2.so
FEN_HTTP_SO := packages/util/dist/fen_http.so

# libcurl include/lib for compiling fen_http.so. The Nix dev shell exports
# CURL_INCDIR/CURL_LIBDIR; outside Nix, set both or rely on the linker
# defaults (-lcurl resolved via system paths).
CURL_INCDIR ?=
CURL_LIBDIR ?=
CURL_INC_FLAG := $(if $(CURL_INCDIR),-I$(CURL_INCDIR),)
CURL_LIB_FLAG := $(if $(CURL_LIBDIR),-L$(CURL_LIBDIR),)

help:
	@echo 'fen workspace targets:'
	@echo '  build            — compile package src/ trees into package dist/'
	@echo '  fennel-check     — strict compile-check all source and test .fnl files'
	@echo '  test             — run all *_test.fnl files under busted'
	@echo '  smoke            — live --print round-trip against each configured provider'
	@echo '  install-local    — luarocks make all rocks into ./lua_modules and smoke fen --help'
	@echo '  install-local-clean — remove ./lua_modules, then install-local'
	@echo '  clean            — remove package dist/ trees and fen-dist.tar.gz'

build:
	@FENNEL='$(FENNEL)' $(FENNEL) scripts/fennel-build.fnl
	@mkdir -p packages/fen/dist/fen
	@printf 'return "%s"\n' '$(VERSION)' > packages/fen/dist/fen/version.lua
	$(MAKE) $(TERMBOX_SO) $(FEN_HTTP_SO)

$(TERMBOX_SO): packages/extensions/tui/vendor/lua_termbox2.c packages/extensions/tui/vendor/termbox2.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ipackages/extensions/tui/vendor -shared $< -o $@

$(FEN_HTTP_SO): packages/util/vendor/fen_http.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) $(CURL_INC_FLAG) -shared $< $(CURL_LIB_FLAG) -lcurl -o $@

run: build
	./bin/fen

test:
	busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test packages tests

smoke: build
	./scripts/smoke.sh

fennel-check:
	@FENNEL='$(FENNEL)' FNL_SRC_GLOBALS='$(FNL_SRC_GLOBALS)' FNL_TEST_GLOBALS='$(FNL_TEST_GLOBALS)' \
		$(FENNEL) scripts/fennel-check.fnl

install-local:
	@set -eu; \
	for rock in $(ROCKSPECS); do \
		d=$${rock%/*}; \
		echo "$(LUAROCKS) make $$rock"; \
		( \
			export PATH="$(PWD)/lua_modules/bin:$$PATH"; \
			export LUA_PATH="$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;$${LUA_PATH:-}"; \
			export LUA_CPATH="$(PWD)/lua_modules/lib/lua/5.4/?.so;$${LUA_CPATH:-}"; \
			export FEN_WORKSPACE="$(PWD)" FENNEL="$(FENNEL)"; \
			cd $$d && $(LUAROCKS) --tree="$(PWD)/lua_modules" make --deps-mode=all "$$(basename $$rock)" LUA_INCDIR="$${LUA_INCDIR:-}" CURL_INCDIR="$${CURL_INCDIR:-}" CURL_LIBDIR="$${CURL_LIBDIR:-}"; \
		); \
	done
	@PATH="$(PWD)/lua_modules/bin:$$PATH" \
	 LUA_PATH="$(PWD)/lua_modules/share/lua/5.4/?.lua;$(PWD)/lua_modules/share/lua/5.4/?/init.lua;;" \
	 LUA_CPATH="$(PWD)/lua_modules/lib/lua/5.4/?.so;;" \
	 fen --help >/dev/null
	@echo 'local LuaRocks install OK.'

install-local-clean:
	@rm -rf lua_modules
	$(MAKE) install-local

dist: build
	tar czf fen-dist.tar.gz packages/*/dist packages/*/*/dist bin README.md

clean:
	find packages -type d -name dist -prune -exec rm -rf {} +
	find packages -type d -name .luarocks-build -prune -exec rm -rf {} +
	find packages -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf fen-dist.tar.gz
