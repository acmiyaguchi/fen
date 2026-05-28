;; Human-facing provider setup help used by first-run errors and the
;; `fen providers` subcommand. Keep this dependency-light so it can run before
;; the full agent runtime/provider HTTP stack is loaded.

(local M {})

(local CUSTOM-ALIASES
  {:custom true
   :models true
   :models.json true
   :ollama true
   :lm-studio true
   :vllm true})

(local PROVIDERS
  {:openai
   {:title "OpenAI API key"
    :summary "Default OpenAI Chat Completions provider."
    :requires ["OPENAI_API_KEY"]
    :models ["default: gpt-5.4-nano"]
    :setup ["export OPENAI_API_KEY=sk-..."
            "fen --provider openai"]
    :notes ["This is fen's built-in fallback when no saved provider is configured."
            "Use `fen providers openai-responses` for the Responses API variant."]}

   :openai-responses
   {:title "OpenAI Responses API"
    :summary "OpenAI-compatible Responses provider with reasoning/thinking block support."
    :requires ["OPENAI_API_KEY"]
    :models ["default: gpt-5.4-nano"]
    :setup ["export OPENAI_API_KEY=sk-..."
            "fen --provider openai-responses"]
    :notes ["Uses the same API key as the default OpenAI provider."
            "Prefer this when a model exposes useful Responses API reasoning items."]}

   :openai-codex
   {:title "ChatGPT subscription / Codex OAuth"
    :summary "OpenAI Codex Responses provider authenticated by fen's OAuth auth backend."
    :requires ["one-time `fen --login openai-codex`"]
    :models ["default: gpt-5.5"]
    :setup ["fen --login openai-codex"
            "fen --provider openai-codex"]
    :notes ["Credentials are stored in fen's auth.json, not in OPENAI_API_KEY."
            "Use `fen --logout openai-codex` to remove stored credentials."]}

   :anthropic
   {:title "Anthropic API key"
    :summary "Anthropic Messages provider."
    :requires ["ANTHROPIC_API_KEY"]
    :models ["default: claude-haiku-4-5"]
    :setup ["export ANTHROPIC_API_KEY=sk-ant-..."
            "fen --provider anthropic"]
    :notes ["Use `--thinking LEVEL` or `/thinking LEVEL` for extended thinking controls."]}})

(local ORDER [:openai :openai-responses :openai-codex :anthropic])

(local CUSTOM-SPEC
  {:title "Custom OpenAI-compatible provider"
   :summary "Ollama, vLLM, LM Studio, proxies, and other OpenAI-compatible endpoints."
   :requires ["~/.config/fen/models.json"]
   :models ["default: first model listed for the custom provider"]
   :setup ["mkdir -p ~/.config/fen"
           "edit ~/.config/fen/models.json (see Example below)"
           "fen --provider ollama"]
   :example ["{"
             "  \"providers\": {"
             "    \"ollama\": {"
             "      \"baseUrl\": \"http://localhost:11434/v1\","
             "      \"api\": \"openai-completions\","
             "      \"apiKey\": \"ollama\","
             "      \"compat\": {\"maxTokensField\": \"max_tokens\"},"
             "      \"models\": [{\"id\": \"llama3.1:8b\"}]"
             "    }"
             "  }"
             "}"]
   :notes ["apiKey values that look like UPPER_SNAKE_CASE are read from the environment."
           "Empty or omitted apiKey sends no Authorization header for auth-less local servers."
           "Run `/reload` in the TUI after editing models.json."]})

(fn normalize-name [name]
  (let [s (tostring (or name ""))]
    (if (= (string.sub s 1 1) ":")
        (string.sub s 2)
        s)))

(fn spec-for [name]
  (let [key (normalize-name name)]
    (if (. PROVIDERS key) (values (. PROVIDERS key) key)
        (. CUSTOM-ALIASES key) (values CUSTOM-SPEC :custom))))

(fn push-list [lines title items]
  (when (and items (> (length items) 0))
    (table.insert lines (.. title ":"))
    (each [_ item (ipairs items)]
      (table.insert lines (.. "  " item)))
    (table.insert lines "")))

;; Render a literal block (e.g. JSON example) with its own column-0 alignment
;; preserved, so it stays copy-pasteable. `push-list` would prepend "  " to
;; every line, which breaks heredoc terminators and shifts indentation.
(fn push-block [lines title items]
  (when (and items (> (length items) 0))
    (table.insert lines (.. title ":"))
    (each [_ item (ipairs items)]
      (table.insert lines item))
    (table.insert lines "")))

(fn render-spec [name spec]
  (let [lines []]
    (table.insert lines (.. "fen provider: " name))
    (table.insert lines (.. spec.title " — " spec.summary))
    (table.insert lines "")
    (push-list lines "Requires" spec.requires)
    (push-list lines "Models" spec.models)
    (push-list lines "Setup" spec.setup)
    (push-block lines "Example" spec.example)
    (push-list lines "Notes" spec.notes)
    (table.insert lines "More:")
    (table.insert lines "  fen providers              # list setup pages")
    (table.insert lines "  fen --help                 # all CLI options")
    (.. (table.concat lines "\n") "\n")))

(fn M.render-index []
  (let [lines ["fen provider setup"
               ""
               "Choose one model provider before starting fen."
               ""
               "Built-in providers:"]
        custom-label "custom / ollama"
        width (do (var w (length custom-label))
                  (each [_ n (ipairs ORDER)]
                    (when (> (length n) w) (set w (length n))))
                  w)
        pad (fn [s] (.. s (string.rep " " (- width (length s)))))]
    (each [_ name (ipairs ORDER)]
      (let [spec (. PROVIDERS name)]
        (table.insert lines (.. "  " (pad name) "  " spec.summary))))
    (table.insert lines "")
    (table.insert lines "Custom providers:")
    (table.insert lines (.. "  " (pad custom-label)
                            "  OpenAI-compatible endpoints via ~/.config/fen/models.json"))
    (table.insert lines "")
    (table.insert lines "Examples:")
    (table.insert lines "  fen providers openai")
    (table.insert lines "  fen providers anthropic")
    (table.insert lines "  fen providers openai-codex")
    (table.insert lines "  fen providers ollama")
    (.. (table.concat lines "\n") "\n")))

(fn M.render-provider [name]
  (let [(spec resolved) (spec-for name)]
    (if spec
        (render-spec resolved spec)
        (.. "unknown provider setup page: " (tostring name) "\n\n"
            (M.render-index)))))

(fn M.known-provider? [name]
  (if (spec-for name) true false))

(fn M.dispatch [argv]
  "Render the `fen providers [name]` subcommand. Returns (output exit-code).
   exit-code is 2 when a name was given but didn't match a built-in or alias."
  (let [name (. argv 2)
        output (if name (M.render-provider name) (M.render-index))
        code (if (or (not name) (M.known-provider? name)) 0 2)]
    (values output code)))

(fn source-suffix [source]
  (case source
    :default " (built-in default)"
    _ ""))

(fn M.missing-provider-message [provider-name key-var ?source]
  (let [name (tostring provider-name)
        deep-link (if (M.known-provider? name)
                      (.. "\n  fen providers " name)
                      "")]
    (.. "fen needs a configured model provider.\n\n"
        "Active provider: " name (source-suffix ?source) "\n"
        "Missing: " (tostring key-var) "\n\n"
        "Quick options:\n\n"
        "  OpenAI API key:\n"
        "    export OPENAI_API_KEY=sk-...\n"
        "    fen\n\n"
        "  Anthropic API key:\n"
        "    export ANTHROPIC_API_KEY=sk-ant-...\n"
        "    fen --provider anthropic\n\n"
        "  ChatGPT subscription / Codex OAuth:\n"
        "    fen --login openai-codex\n"
        "    fen --provider openai-codex\n\n"
        "  Local Ollama / OpenAI-compatible server:\n"
        "    write ~/.config/fen/models.json\n"
        "    fen --provider ollama\n\n"
        "More help:\n"
        "  fen providers"
        deep-link)))

(fn M.unknown-provider-message [provider-name]
  (.. "unknown --provider: " (tostring provider-name) "\n\n"
      "Expected a built-in provider, a name defined in ~/.config/fen/models.json,\n"
      "or a provider contributed by a loaded extension.\n\n"
      "Run `fen providers` to see setup help."))

M
