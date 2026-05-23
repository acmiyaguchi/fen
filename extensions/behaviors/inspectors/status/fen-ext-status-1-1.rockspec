package = "fen-ext-status"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/extensions/behaviors/inspectors/status",
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
  SNAKE=status
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
         ["fen.extensions.status"] = ".lrbuild/extensions/status/init.lua",
         ["fen.extensions.status.manifest"] = ".lrbuild/extensions/status/manifest.lua",
         ["fen.extensions.status.util"] = ".lrbuild/extensions/status/util.lua",
         ["fen.extensions.status.commands.status"] = ".lrbuild/extensions/status/commands/status.lua",
         ["fen.extensions.status.state.status"] = ".lrbuild/extensions/status/state/status.lua",
      },
   },
}
