package = "fen-ext-builtin-tools"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/kernel/builtin-tools",
}

description = {
   summary = "fen first-party extension package",
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
         ["fen.extensions.builtin_tools.bash"] = ".lrbuild/extensions/builtin_tools/bash.lua",
         ["fen.extensions.builtin_tools.edit"] = ".lrbuild/extensions/builtin_tools/edit.lua",
         ["fen.extensions.builtin_tools.find"] = ".lrbuild/extensions/builtin_tools/find.lua",
         ["fen.extensions.builtin_tools.grep"] = ".lrbuild/extensions/builtin_tools/grep.lua",
         ["fen.extensions.builtin_tools"] = ".lrbuild/extensions/builtin_tools/init.lua",
         ["fen.extensions.builtin_tools.ls"] = ".lrbuild/extensions/builtin_tools/ls.lua",
         ["fen.extensions.builtin_tools.manifest"] = ".lrbuild/extensions/builtin_tools/manifest.lua",
         ["fen.extensions.builtin_tools.read"] = ".lrbuild/extensions/builtin_tools/read.lua",
         ["fen.extensions.builtin_tools.registry"] = ".lrbuild/extensions/builtin_tools/registry.lua",
         ["fen.extensions.builtin_tools.truncate"] = ".lrbuild/extensions/builtin_tools/truncate.lua",
         ["fen.extensions.builtin_tools.util"] = ".lrbuild/extensions/builtin_tools/util.lua",
         ["fen.extensions.builtin_tools.write"] = ".lrbuild/extensions/builtin_tools/write.lua",
      },
   },
}
