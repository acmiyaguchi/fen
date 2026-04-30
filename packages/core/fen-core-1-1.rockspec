package = "fen-core"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/core",
}

description = {
   summary = "fen core agent, prompt, session, LLM, and extension APIs",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "fen-util >= 1-1",
}

test_dependencies = {
   "busted >= 2.0",
}

build = {
   type = "command",
   build_command = [[
set -eu
rm -rf .luarocks-build
PATH="$(SCRIPTS_DIR):$PATH"
find src -type f -name '*.fnl' | sort | while IFS= read -r src; do
  out=".luarocks-build/${src#src/}"
  out="${out%.fnl}.lua"
  mkdir -p "$(dirname "$out")"
  fennel --compile "$src" > "$out"
done
   ]],
   install = {
      lua = {
         ["fen.core.agent"] = ".luarocks-build/fen/core/agent.lua",
         ["fen.core.extensions.events"] = ".luarocks-build/fen/core/extensions/events.lua",
         ["fen.core.extensions"] = ".luarocks-build/fen/core/extensions/init.lua",
         ["fen.core.extensions.loader.discover"] = ".luarocks-build/fen/core/extensions/loader/discover.lua",
         ["fen.core.extensions.loader"] = ".luarocks-build/fen/core/extensions/loader/init.lua",
         ["fen.core.extensions.loader.manifest"] = ".luarocks-build/fen/core/extensions/loader/manifest.lua",
         ["fen.core.extensions.loader.reload"] = ".luarocks-build/fen/core/extensions/loader/reload.lua",
         ["fen.core.extensions.register.command"] = ".luarocks-build/fen/core/extensions/register/command.lua",
         ["fen.core.extensions.register.control"] = ".luarocks-build/fen/core/extensions/register/control.lua",
         ["fen.core.extensions.register.hook"] = ".luarocks-build/fen/core/extensions/register/hook.lua",
         ["fen.core.extensions.register"] = ".luarocks-build/fen/core/extensions/register/init.lua",
         ["fen.core.extensions.register.panel"] = ".luarocks-build/fen/core/extensions/register/panel.lua",
         ["fen.core.extensions.register.presenter"] = ".luarocks-build/fen/core/extensions/register/presenter.lua",
         ["fen.core.extensions.register.prompt"] = ".luarocks-build/fen/core/extensions/register/prompt.lua",
         ["fen.core.extensions.register.status"] = ".luarocks-build/fen/core/extensions/register/status.lua",
         ["fen.core.extensions.register.tool"] = ".luarocks-build/fen/core/extensions/register/tool.lua",
         ["fen.core.extensions.state"] = ".luarocks-build/fen/core/extensions/state.lua",
         ["fen.core.extensions.test_api"] = ".luarocks-build/fen/core/extensions/test_api.lua",
         ["fen.core.extensions.util"] = ".luarocks-build/fen/core/extensions/util.lua",
         ["fen.core.llm.event_stream"] = ".luarocks-build/fen/core/llm/event_stream.lua",
         ["fen.core.llm"] = ".luarocks-build/fen/core/llm/init.lua",
         ["fen.core.llm.models"] = ".luarocks-build/fen/core/llm/models.lua",
         ["fen.core.prompt"] = ".luarocks-build/fen/core/prompt/init.lua",
         ["fen.core.prompt.resources"] = ".luarocks-build/fen/core/prompt/resources.lua",
         ["fen.core.session"] = ".luarocks-build/fen/core/session.lua",
         ["fen.core.tools"] = ".luarocks-build/fen/core/tools.lua",
         ["fen.core.types"] = ".luarocks-build/fen/core/types.lua",
      },
   },
}
