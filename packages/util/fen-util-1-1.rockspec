package = "fen-util"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/util",
}

description = {
   summary = "fen utility modules",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "lua-cjson >= 2.1",
   "lua-curl >= 0.3",
   "fennel >= 1.4",
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
         ["fen.util.base64"] = ".lrbuild/util/base64.lua",
         ["fen.util.checksum"] = ".lrbuild/util/checksum.lua",
         ["fen.util.http"] = ".lrbuild/util/http/init.lua",
         ["fen.util.http.backend"] = ".lrbuild/util/http/backend.lua",
         ["fen.util.http.backends.curl"] = ".lrbuild/util/http/backends/curl.lua",
         ["fen.util.json"] = ".lrbuild/util/json.lua",
         ["fen.util.log"] = ".lrbuild/util/log.lua",
         ["fen.util.path"] = ".lrbuild/util/path.lua",
         ["fen.util.process"] = ".lrbuild/util/process.lua",
         ["fen.util.sse"] = ".lrbuild/util/sse.lua",
      },
   },
}
