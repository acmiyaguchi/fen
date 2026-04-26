.PHONY: build run test clean dist help

FENNEL ?= fennel
LUA    ?= lua

SRC_DIR    := src
DIST_DIR   := dist
VENDOR_DIR := vendor

FNL_SOURCES := $(shell find $(SRC_DIR) -name '*.fnl')
LUA_OUTPUTS := $(patsubst $(SRC_DIR)/%.fnl,$(DIST_DIR)/%.lua,$(FNL_SOURCES))

# Vendored C binding for termbox2: there's no published lua-termbox2 rock,
# so we ship a small Lua-C shim around termbox2.h. The dev shell exports
# LUA_INCDIR pointing at ${pkgs.lua5_4}/include; outside nix you may need
# to override it (e.g. LUA_INCDIR=/usr/include/lua5.4).
CC         ?= cc
CFLAGS     ?= -O2 -fPIC -Wall
LUA_INCDIR ?= /usr/include/lua5.4
TERMBOX_SO := $(DIST_DIR)/termbox2.so

help:
	@echo 'agent-fennel make targets:'
	@echo '  build  — compile Fennel sources + vendored termbox2 binding into dist/'
	@echo '  run    — build then launch interactive TUI'
	@echo '  test   — run tests/*.fnl'
	@echo '  dist   — tarball dist/ + bin/ + README.md'
	@echo '  clean  — remove dist/'

build: $(LUA_OUTPUTS) $(TERMBOX_SO)

$(DIST_DIR)/%.lua: $(SRC_DIR)/%.fnl
	@mkdir -p $(dir $@)
	$(FENNEL) --compile $< > $@

$(TERMBOX_SO): $(VENDOR_DIR)/lua_termbox2.c $(VENDOR_DIR)/termbox2.h
	@mkdir -p $(DIST_DIR)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -I$(VENDOR_DIR) -shared $< -o $@

run: build
	./bin/agent-fennel

TEST_FILES := $(wildcard tests/*_test.fnl)

test:
	busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test $(TEST_FILES)

dist: build
	tar czf agent-fennel-dist.tar.gz dist bin README.md

clean:
	rm -rf $(DIST_DIR) agent-fennel-dist.tar.gz
