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
   type = "builtin",
   modules = {
      ["fen.core.agent"] = "dist/fen/core/agent.lua",
      ["fen.core.extensions.events"] = "dist/fen/core/extensions/events.lua",
      ["fen.core.extensions"] = "dist/fen/core/extensions/init.lua",
      ["fen.core.extensions.loader.discover"] = "dist/fen/core/extensions/loader/discover.lua",
      ["fen.core.extensions.loader"] = "dist/fen/core/extensions/loader/init.lua",
      ["fen.core.extensions.loader.manifest"] = "dist/fen/core/extensions/loader/manifest.lua",
      ["fen.core.extensions.loader.reload"] = "dist/fen/core/extensions/loader/reload.lua",
      ["fen.core.extensions.register.command"] = "dist/fen/core/extensions/register/command.lua",
      ["fen.core.extensions.register.control"] = "dist/fen/core/extensions/register/control.lua",
      ["fen.core.extensions.register.hook"] = "dist/fen/core/extensions/register/hook.lua",
      ["fen.core.extensions.register"] = "dist/fen/core/extensions/register/init.lua",
      ["fen.core.extensions.register.panel"] = "dist/fen/core/extensions/register/panel.lua",
      ["fen.core.extensions.register.presenter"] = "dist/fen/core/extensions/register/presenter.lua",
      ["fen.core.extensions.register.prompt"] = "dist/fen/core/extensions/register/prompt.lua",
      ["fen.core.extensions.register.status"] = "dist/fen/core/extensions/register/status.lua",
      ["fen.core.extensions.register.tool"] = "dist/fen/core/extensions/register/tool.lua",
      ["fen.core.extensions.state"] = "dist/fen/core/extensions/state.lua",
      ["fen.core.extensions.test_api"] = "dist/fen/core/extensions/test_api.lua",
      ["fen.core.extensions.util"] = "dist/fen/core/extensions/util.lua",
      ["fen.core.llm.event_stream"] = "dist/fen/core/llm/event_stream.lua",
      ["fen.core.llm"] = "dist/fen/core/llm/init.lua",
      ["fen.core.llm.models"] = "dist/fen/core/llm/models.lua",
      ["fen.core.prompt"] = "dist/fen/core/prompt/init.lua",
      ["fen.core.prompt.resources"] = "dist/fen/core/prompt/resources.lua",
      ["fen.core.session"] = "dist/fen/core/session.lua",
      ["fen.core.tools"] = "dist/fen/core/tools.lua",
      ["fen.core.types"] = "dist/fen/core/types.lua",
   },
}
