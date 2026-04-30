package = "fen-provider-openai"
version = "1-1"
rockspec_format = "3.0"

source = {
   url = "git+https://github.com/acmiyaguchi/fen.git",
   dir = "fen/packages/providers/openai",
}

description = {
   summary = "fen LLM provider package",
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
   type = "builtin",
   modules = {
      ["fen.providers.openai_completions"] = "dist/fen/providers/openai_completions.lua",
   },
}
