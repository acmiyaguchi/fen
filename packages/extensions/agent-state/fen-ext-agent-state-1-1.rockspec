package = "fen-ext-agent-state"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/extensions/agent-state",
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
rm -rf .lrbuild
PATH="$(SCRIPTS_DIR):$PATH"
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".lrbuild/${src#src/fen/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
   ]],
   install = {
      lua = {
         ["fen.extensions.agent_state"] = ".lrbuild/extensions/agent_state/init.lua",
         ["fen.extensions.agent_state.manifest"] = ".lrbuild/extensions/agent_state/manifest.lua",
         ["fen.extensions.agent_state.tool"] = ".lrbuild/extensions/agent_state/tool.lua",
      },
   },
}
