package = "fen-ext-default-prompt"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/default-prompt",
}

description = {
   summary = "fen first-party extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
if [ -n "${FEN_WORKSPACE:-}" ] && [ -f "$FEN_WORKSPACE/scripts/fennel-build.fnl" ]; then
  "${FENNEL:-fennel}" "$FEN_WORKSPACE/scripts/fennel-build.fnl" --lrbuild
else
  rm -rf .lrbuild
  find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
    out=".lrbuild/${src#src/fen/}"
    out="${out%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
fi
   ]],
   install = {
      lua = {
         ["fen.extensions.default_prompt"] = ".lrbuild/extensions/default_prompt/init.lua",
         ["fen.extensions.default_prompt.manifest"] = ".lrbuild/extensions/default_prompt/manifest.lua",
      },
   },
}
