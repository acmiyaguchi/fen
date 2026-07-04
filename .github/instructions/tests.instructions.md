---
applyTo: "**/tests/**/*.fnl,**/*_test.fnl"
---

# Tests (Busted + Fennel)

Tests run under Busted with Fennel loading.

- **Extend `fennel.path`, not `package.path`,** to add `.fnl` source roots.
- **Mock modules via `package.loaded`** before requiring the module under test,
  so the mock is in place when the module resolves its dependencies.
- Keep tests focused and hot-reload-agnostic; test observable behavior, not reload wiring.
- New behavior should come with a test; flag behavior changes that add none.
