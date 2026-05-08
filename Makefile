.PHONY: help dev dev-nix test smoke check bench-tui docs graphs docs-html docs-serve doc-coverage check-docs clean

# Tiny convenience frontend. Nix and scripts remain the source of truth.

help:
	@echo 'fen workspace targets:'
	@echo '  dev                 — run scripts/fen-dev using FEN_BIN or fen on PATH'
	@echo '  dev-nix             — build .#fen, then run scripts/fen-dev from source'
	@echo '  test                — fast local busted test run (TESTS=... to filter)'
	@echo '  smoke               — provider smoke test using FEN_BIN or fen on PATH'
	@echo '  check               — fennel-check, doc block validation, and tests'
	@echo '  bench-tui           — run TUI transcript performance harness'
	@echo '  docs                — regenerate docs/generated/ from Fennel sources, including graphs'
	@echo '  graphs              — regenerate docs/generated/graphs/*.dot'
	@echo '  docs-html           — regenerate docs/generated/html/ static site'
	@echo '  docs-serve          — serve docs/generated/html/ locally (PORT=8000; busybox/python/nix)'
	@echo '  doc-coverage        — print documentation coverage report'
	@echo '  check-docs          — validate @doc block formatting; non-zero on errors'
	@echo '  clean               — remove generated local artifacts'

dev:
	scripts/fen-dev

dev-nix:
	@out=$$(nix build .#fen --print-out-paths); \
	FEN_BIN="$$out/bin/fen" scripts/fen-dev

test:
	sh scripts/run-tests.sh $(TESTS)

smoke:
	FEN_BIN="$${FEN_BIN:-fen}" scripts/smoke.sh

check:
	fennel scripts/fennel-check.fnl
	fennel scripts/check-docs.fnl
	sh scripts/run-tests.sh $(TESTS)

bench-tui:
	fennel scripts/tui-bench.fnl

docs:
	fennel scripts/gen-docs.fnl
	fennel scripts/gen-graphs.fnl

graphs:
	fennel scripts/gen-graphs.fnl

docs-html: docs
	fennel scripts/gen-static-docs.fnl

docs-serve: docs-html
	@if command -v busybox >/dev/null 2>&1; then \
		exec busybox httpd -f -p "$${PORT:-8000}" -h docs/generated/html; \
	elif command -v python3 >/dev/null 2>&1; then \
		exec python3 -m http.server "$${PORT:-8000}" --directory docs/generated/html; \
	elif command -v nix >/dev/null 2>&1; then \
		exec nix run nixpkgs#busybox -- httpd -f -p "$${PORT:-8000}" -h docs/generated/html; \
	else \
		echo "error: need busybox, python3, or nix to serve docs" >&2; \
		exit 1; \
	fi

doc-coverage:
	@fennel scripts/doc-coverage.fnl

check-docs:
	@fennel scripts/check-docs.fnl

clean:
	find packages extensions -type d -name dist -prune -exec rm -rf {} +
	find packages extensions -type d -name .lrbuild -prune -exec rm -rf {} +
	rm -rf dist result result-*
