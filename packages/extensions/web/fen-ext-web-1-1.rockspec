package = "fen-ext-web"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/web",
}

description = {
   summary = "fen first-party web presenter extension package",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
   "luasocket >= 3.0",
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
  SNAKE=web
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
         ["fen.extensions.web"] = ".lrbuild/extensions/web/init.lua",
         ["fen.extensions.web.ingest"] = ".lrbuild/extensions/web/ingest.lua",
         ["fen.extensions.web.layout"] = ".lrbuild/extensions/web/layout.lua",
         ["fen.extensions.web.manifest"] = ".lrbuild/extensions/web/manifest.lua",
         ["fen.extensions.web.page"] = ".lrbuild/extensions/web/page.lua",
         ["fen.extensions.web.server"] = ".lrbuild/extensions/web/server.lua",
         ["fen.extensions.web.state"] = ".lrbuild/extensions/web/state.lua",
      },
   },
}
