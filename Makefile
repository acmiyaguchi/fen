.PHONY: help dev test bench-tui docs doc-coverage check-docs clean

# Tiny convenience frontend. Nix and scripts remain the source of truth.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — build .#fen, then run bin/fen-dev from source'
	@echo '  test                — fast local busted test run'
	@echo '  bench-tui           — run TUI transcript performance harness'
	@echo '  docs                — regenerate docs/generated/ from Fennel sources'
	@echo '  doc-coverage        — print documentation coverage report'
	@echo '  check-docs          — validate @doc block formatting; non-zero on errors'
	@echo '  clean               — remove generated local artifacts'

dev:
	@out=$$(nix build .#fen --print-out-paths); \
	FEN_BIN="$$out/bin/fen" bin/fen-dev

test:
	sh scripts/run-tests.sh

bench-tui:
	fennel scripts/tui-bench.fnl

docs:
	fennel scripts/gen-docs.fnl

doc-coverage:
	@fennel scripts/doc-coverage.fnl

check-docs:
	@fennel scripts/check-docs.fnl

clean:
	find packages extensions -type d -name dist -prune -exec rm -rf {} +
	find packages extensions -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf dist result result-*
