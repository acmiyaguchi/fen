FENNEL ?= fennel
CC ?= cc
CFLAGS ?= -O2 -fPIC -Wall
DEBUG_CFLAGS ?= -O0 -g3 -ggdb -fPIC -Wall -fno-omit-frame-pointer
LUA_INCDIR ?= /usr/include/lua5.4
SRC_DIR := src
DIST_DIR := dist
FNL_SOURCES := $(shell find $(SRC_DIR) -name '*.fnl' | sort)
LUA_OUTPUTS := $(patsubst $(SRC_DIR)/%.fnl,$(DIST_DIR)/%.lua,$(FNL_SOURCES))
TERMBOX_SRC := $(wildcard vendor/lua_termbox2.c)
TERMBOX_SO := $(if $(TERMBOX_SRC),$(DIST_DIR)/termbox2.so,)
VERSION_FILE := $(if $(wildcard src/fen/main.fnl),$(DIST_DIR)/fen/version.lua,)
VERSION := $(shell git -C ../.. describe --tags --always --dirty 2>/dev/null || git describe --tags --always --dirty 2>/dev/null || echo unknown)
.PHONY: build debug-build clean fennel-check
build: $(LUA_OUTPUTS) $(TERMBOX_SO) $(VERSION_FILE)
$(DIST_DIR)/%.lua: $(SRC_DIR)/%.fnl
	@mkdir -p $(dir $@)
	$(FENNEL) --compile $< > $@
$(DIST_DIR)/termbox2.so: vendor/lua_termbox2.c vendor/termbox2.h
	@mkdir -p $(DIST_DIR)
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -Ivendor -shared $< -o $@
.PHONY: FORCE
FORCE:
$(DIST_DIR)/fen/version.lua: FORCE
	@mkdir -p $(dir $@)
	@printf 'return "%s"\n' '$(VERSION)' > $@
debug-build:
	$(MAKE) clean
	$(MAKE) CFLAGS="$(DEBUG_CFLAGS)" build
fennel-check:
	@rc=0; for f in $(FNL_SOURCES); do if ! $(FENNEL) --compile --globals "$(FNL_SRC_GLOBALS)" "$$f" > /dev/null 2>&1; then echo "FAIL: $$PWD/$$f"; $(FENNEL) --compile --globals "$(FNL_SRC_GLOBALS)" "$$f" 2>&1 | head -5; rc=1; fi; done; exit $$rc
clean:
	rm -rf $(DIST_DIR)
