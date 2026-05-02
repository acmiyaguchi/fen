.PHONY: help dev test clean

# Tiny convenience frontend. Nix and scripts remain the source of truth.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — build .#fen, then run bin/fen-dev from source'
	@echo '  test                — fast local busted test run'
	@echo '  clean               — remove generated local artifacts'

dev:
	@out=$$(nix build .#fen --print-out-paths); \
	FEN_BIN="$$out/bin/fen" bin/fen-dev

test:
	sh scripts/run-tests.sh

clean:
	find packages -type d -name dist -prune -exec rm -rf {} +
	find packages -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf dist result result-*
