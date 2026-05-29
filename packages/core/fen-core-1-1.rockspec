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
   ]],
   install = {
      lua = {
         ["fen.core.agent"] = ".lrbuild/core/agent.lua",
         ["fen.core.diagnostics"] = ".lrbuild/core/diagnostics.lua",
         ["fen.core.docs.contracts"] = ".lrbuild/core/docs/contracts.lua",
         ["fen.core.extensions.events"] = ".lrbuild/core/extensions/events.lua",
         ["fen.core.extensions.loader.discover"] = ".lrbuild/core/extensions/loader/discover.lua",
         ["fen.core.extensions.loader"] = ".lrbuild/core/extensions/loader/init.lua",
         ["fen.core.extensions.loader.api"] = ".lrbuild/core/extensions/loader/api.lua",
         ["fen.core.extensions.loader.manifest"] = ".lrbuild/core/extensions/loader/manifest.lua",
         ["fen.core.extensions.loader.reload"] = ".lrbuild/core/extensions/loader/reload.lua",
         ["fen.core.extensions.register.auth_backend"] = ".lrbuild/core/extensions/register/auth_backend.lua",
         ["fen.core.extensions.register.command"] = ".lrbuild/core/extensions/register/command.lua",
         ["fen.core.extensions.register.control"] = ".lrbuild/core/extensions/register/control.lua",
         ["fen.core.extensions.register.hook"] = ".lrbuild/core/extensions/register/hook.lua",
         ["fen.core.extensions.register.introspect"] = ".lrbuild/core/extensions/register/introspect.lua",
         ["fen.core.extensions.register"] = ".lrbuild/core/extensions/register/init.lua",
         ["fen.core.extensions.register.panel"] = ".lrbuild/core/extensions/register/panel.lua",
         ["fen.core.extensions.register.presenter"] = ".lrbuild/core/extensions/register/presenter.lua",
         ["fen.core.extensions.register.provider"] = ".lrbuild/core/extensions/register/provider.lua",
         ["fen.core.extensions.register.prompt"] = ".lrbuild/core/extensions/register/prompt.lua",
         ["fen.core.extensions.register.session_backend"] = ".lrbuild/core/extensions/register/session_backend.lua",
         ["fen.core.extensions.register.status"] = ".lrbuild/core/extensions/register/status.lua",
         ["fen.core.extensions.register.tool"] = ".lrbuild/core/extensions/register/tool.lua",
         ["fen.core.extensions.rocks"] = ".lrbuild/core/extensions/rocks.lua",
         ["fen.core.extensions.state"] = ".lrbuild/core/extensions/state.lua",
         ["fen.core.extensions.test_api"] = ".lrbuild/core/extensions/test_api.lua",
         ["fen.core.extensions.util"] = ".lrbuild/core/extensions/util.lua",
         ["fen.core.llm.event_stream"] = ".lrbuild/core/llm/event_stream.lua",
         ["fen.core.llm"] = ".lrbuild/core/llm/init.lua",
         ["fen.core.llm.models"] = ".lrbuild/core/llm/models.lua",
         ["fen.core.prompt"] = ".lrbuild/core/prompt.lua",
         ["fen.core.llm.retry"] = ".lrbuild/core/llm/retry.lua",
         ["fen.core.settings"] = ".lrbuild/core/settings.lua",
         ["fen.core.thinking"] = ".lrbuild/core/thinking.lua",
         ["fen.core.tools"] = ".lrbuild/core/tools.lua",
         ["fen.core.types"] = ".lrbuild/core/types.lua",
      },
   },
}
