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
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/build/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  SNAKE=builtin_tools
  find . -type f -name '*.fnl' \
    -not -path './tests/*' \
    -not -path './vendor/*' \
    -not -path './.lrbuild/*' \
    -not -path './dist/*' \
    | sort | while IFS= read -r src; do
    rel="${src#./}"
    out=".lrbuild/extensions/${SNAKE}/${rel%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
fi
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
