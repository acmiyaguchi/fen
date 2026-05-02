.PHONY: help dev build check test fennel-check clean

# Make is now a convenience frontend. Nix and scripts are the source of truth:
# - Nix builds reproducible package/distribution artifacts.
# - scripts/* contain the non-Nix compatibility steps used by Nix and local checks.
# - bin/fen-dev + .#fen is the canonical source-checkout dev runtime.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — build .#fen, then run bin/fen-dev from source'
	@echo '  build               — nix build .#fen (canonical dev/runtime artifact)'
	@echo '  check               — nix flake check'
	@echo '  fennel-check        — fast strict compile/global check for .fnl files'
	@echo '  test                — fast busted test run'
	@echo '  clean               — remove generated local artifacts'

dev:
	@out=$$(nix build .#fen --print-out-paths); \
	FEN_BIN="$$out/bin/fen" bin/fen-dev

build:
	nix build .#fen

check:
	nix flake check

fennel-check:
	sh scripts/check-fennel.sh

test:
	sh scripts/run-tests.sh

clean:
	find packages -type d -name dist -prune -exec rm -rf {} +
	find packages -type d -name .luarocks-build -prune -exec rm -rf {} +
	find packages -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf dist result result-*
