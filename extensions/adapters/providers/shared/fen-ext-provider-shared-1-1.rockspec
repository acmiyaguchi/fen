package = "fen-ext-provider-shared"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/adapters/providers/shared",
}

description = {
   summary = "fen shared provider transport helpers (retry/backoff)",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
# fen ext build compiles in process and drops this marker so we skip the
# bootstrap compile. A standalone `luarocks make` (no fen) sets FEN_WORKSPACE to
# reach the shared build driver; see docs/extensions.md.
[ -f .lrbuild/.fen-precompiled ] || "${FENNEL:-fennel}" "${FEN_WORKSPACE:?set FEN_WORKSPACE to build this rock without fen}/scripts/build/fennel-build.fnl" --lrbuild
   ]],
   install = {
      lua = {
         ["fen.extensions.provider_shared"] = ".lrbuild/extensions/provider_shared/init.lua",
         ["fen.extensions.provider_shared.manifest"] = ".lrbuild/extensions/provider_shared/manifest.lua",
         ["fen.extensions.provider_shared.retry"] = ".lrbuild/extensions/provider_shared/retry.lua",
         ["fen.extensions.provider_shared.streaming"] = ".lrbuild/extensions/provider_shared/streaming.lua",
      },
   },
}
