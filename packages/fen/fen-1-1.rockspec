package = "fen"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/fen",
}

description = {
   summary = "Kitchen-sink fen CLI rock",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-core >= 1-1",
   "fen-util >= 1-1",
   "fen-ext-provider-openai >= 1-1",
   "fen-ext-provider-anthropic >= 1-1",
   "fen-ext-builtin-tools >= 1-1",
   "fen-ext-essentials >= 1-1",
   "fen-ext-sessions >= 1-1",
   "fen-ext-status >= 1-1",
   "fen-ext-queue >= 1-1",
   "fen-ext-prompt >= 1-1",
   "fen-ext-extensions-inspector >= 1-1",
   "fen-ext-default-prompt >= 1-1",
   "fen-ext-tui >= 1-1",
   "fen-ext-mem >= 1-1",
   "fen-ext-session-jsonl >= 1-1",
   "fen-ext-skills >= 1-1",
   "fen-ext-agent-state >= 1-1",
   "fen-ext-compact >= 1-1",
   "fen-ext-handoff >= 1-1",
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
mkdir -p .lrbuild
printf 'return "%s"\n' "${FEN_VERSION:-unknown}" > .lrbuild/version.lua
   ]],
   install = {
      lua = {
         ["fen.main"] = ".lrbuild/main.lua",
         ["fen.version"] = ".lrbuild/version.lua",
      },
      bin = {
         ["fen"] = "bin/fen.lua",
      },
   },
}
