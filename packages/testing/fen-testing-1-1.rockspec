package = "fen-testing"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/testing",
}

description = {
   summary = "fen test helpers for package and extension tests",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fennel >= 1.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
   "fen-ext-builtin-tools >= 1-1",
}

build = {
   type = "command",
   build_command = [[
set -eu
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  find src -type f -name '*.fnl' ! -path '*/macros.fnl' | sort | while IFS= read -r src; do
    out=".lrbuild/${src#src/fen/}"
    out="${out%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
fi
   ]],
   install = {
      lua = {
         ["fen.testing"] = ".lrbuild/testing/init.lua",
         ["fen.testing.macros"] = "src/fen/testing/macros.fnl",
         ["fen.testing.tools"] = ".lrbuild/testing/tools.lua",
      },
   },
}
