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
   "fennel >= 1.4",
}

external_dependencies = {
   LUA = { header = "lua.h" },
   CURL = { header = "curl/curl.h" },
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
  find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
    out=".lrbuild/${src#src/fen/}"
    out="${out%.fnl}.lua"
    mkdir -p "$(dirname "$out")"
    "${FENNEL:-fennel}" --compile "$src" > "$out"
  done
fi
mkdir -p .lrbuild
$(CC) $(CFLAGS) -I$(LUA_INCDIR) -I$(CURL_INCDIR) -shared vendor/fen_http.c -L$(CURL_LIBDIR) -lcurl -o .lrbuild/fen_http.so
$(CC) $(CFLAGS) -I$(LUA_INCDIR) -shared vendor/fen_random.c -o .lrbuild/fen_random.so
   ]],
   install = {
      lua = {
         ["fen.util.base64"] = ".lrbuild/util/base64.lua",
         ["fen.util.checksum"] = ".lrbuild/util/checksum.lua",
         ["fen.util.flat_extensions"] = ".lrbuild/util/flat_extensions.lua",
         ["fen.util.frontmatter"] = ".lrbuild/util/frontmatter.lua",
         ["fen.util.http"] = ".lrbuild/util/http/init.lua",
         ["fen.util.http.backend"] = ".lrbuild/util/http/backend.lua",
         ["fen.util.http.backends.native"] = ".lrbuild/util/http/backends/native.lua",
         ["fen.util.id"] = ".lrbuild/util/id.lua",
         ["fen.util.json"] = ".lrbuild/util/json.lua",
         ["fen.util.log"] = ".lrbuild/util/log.lua",
         ["fen.util.log_sink"] = ".lrbuild/util/log_sink.lua",
         ["fen.util.path"] = ".lrbuild/util/path.lua",
         ["fen.util.process"] = ".lrbuild/util/process.lua",
         ["fen.util.random"] = ".lrbuild/util/random.lua",
         ["fen.util.search.bitap"] = ".lrbuild/util/search/bitap.lua",
         ["fen.util.sha256"] = ".lrbuild/util/sha256.lua",
         ["fen.util.sse"] = ".lrbuild/util/sse.lua",
         ["fen.util.text"] = ".lrbuild/util/text.lua",
         ["fen.util.tokens"] = ".lrbuild/util/tokens.lua",
      },
      lib = {
         ["fen_http"] = ".lrbuild/fen_http.so",
         ["fen_random"] = ".lrbuild/fen_random.so",
      },
   },
}
