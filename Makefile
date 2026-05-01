.PHONY: help dev build check dist test fennel-check dist-tree run smoke install-local install-local-clean clean

# Make is now a convenience frontend. Nix and scripts are the source of truth:
# - Nix builds reproducible package/distribution artifacts.
# - scripts/* contain the non-Nix compatibility steps used by Nix and local checks.
# - bin/fen-dev + .#fenSingle is the canonical source-checkout dev runtime.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — build .#fenSingle, then run bin/fen-dev from source'
	@echo '  build               — nix build .#fenSingle (canonical dev/runtime artifact)'
	@echo '  check               — nix flake check'
	@echo '  dist                — nix build .#dist (portable tarball baseline)'
	@echo '  fennel-check        — fast strict compile/global check for .fnl files'
	@echo '  test                — fast busted test run'
	@echo '  dist-tree           — compatibility: generate package dist/ trees + native modules'
	@echo '  run                 — compatibility: dist-tree, then ./bin/fen'
	@echo '  install-local       — compatibility: luarocks make all rocks into ./lua_modules'
	@echo '  clean               — remove generated local artifacts'

dev:
	@out=$$(nix build .#fenSingle --print-out-paths); \
	FEN_BIN="$$out/bin/fen" bin/fen-dev

build:
	nix build .#fenSingle

check:
	nix flake check

dist:
	nix build .#dist

fennel-check:
	sh scripts/check-fennel.sh

test:
	sh scripts/run-tests.sh

# Compatibility/internal targets below this point. They are still used for the
# dist-tree/POSIX-launcher path and by package plumbing, but not for normal dev.
dist-tree:
	sh scripts/build-dist-tree.sh

run: dist-tree
	./bin/fen

smoke: dist-tree
	./scripts/smoke.sh

install-local:
	sh scripts/install-local-rocks.sh

install-local-clean:
	rm -rf lua_modules
	$(MAKE) install-local

clean:
	find packages -type d -name dist -prune -exec rm -rf {} +
	find packages -type d -name .luarocks-build -prune -exec rm -rf {} +
	find packages -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf result result-* fen-dist.tar.gz
