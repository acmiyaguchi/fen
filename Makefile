.PHONY: build run test clean dist help

FENNEL ?= fennel
LUA    ?= lua

SRC_DIR  := src
DIST_DIR := dist

FNL_SOURCES := $(shell find $(SRC_DIR) -name '*.fnl')
LUA_OUTPUTS := $(patsubst $(SRC_DIR)/%.fnl,$(DIST_DIR)/%.lua,$(FNL_SOURCES))

help:
	@echo 'agent-fennel make targets:'
	@echo '  build  — compile Fennel sources to dist/'
	@echo '  run    — build then launch interactive TUI'
	@echo '  test   — run tests/*.fnl'
	@echo '  dist   — tarball dist/ + bin/ + README.md'
	@echo '  clean  — remove dist/'

build: $(LUA_OUTPUTS)

$(DIST_DIR)/%.lua: $(SRC_DIR)/%.fnl
	@mkdir -p $(dir $@)
	$(FENNEL) --compile $< > $@

run: build
	./bin/agent-fennel

TEST_FILES := $(wildcard tests/*_test.fnl)

test:
	busted --loaders=lua,fennel --helper=tests/busted-helper.lua --pattern=_test $(TEST_FILES)

dist: build
	tar czf agent-fennel-dist.tar.gz dist bin README.md

clean:
	rm -rf $(DIST_DIR) agent-fennel-dist.tar.gz
