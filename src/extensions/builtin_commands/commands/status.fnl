;; /status command.

(local extensions (require :core.extensions))
(local util (require :extensions.builtin_commands.util))

(local M {})

(fn format-auth [state]
  "Describe how the active provider is authenticating for the status row."
  (let [provider state.opts.provider]
    (if (= provider :openai-codex)
        "subscription (via pi)"
        (= provider :openai)
        "$OPENAI_API_KEY"
        (= provider :openai-responses)
        "$OPENAI_API_KEY"
        (= provider :anthropic)
        "$ANTHROPIC_API_KEY"
        (.. "custom (" (tostring provider) ")"))))

(fn format-status [state]
  (let [agent state.agent
        usage (util.usage-totals agent.messages)
        approx (util.estimated-context-tokens agent)
        session-path (if state.session state.session.path nil)]
    (.. "Status\n"
        "version: " (util.runtime-version) "\n"
        "model: " (tostring agent.model) "\n"
        "provider: " (tostring agent.provider-api) "\n"
        "auth: " (format-auth state) "\n"
        "messages: " (tostring (length (or agent.messages []))) "\n"
        "approx context: ~" (tostring approx) " tokens\n"
        "reported usage: " (tostring usage.total-tokens) " tokens"
        " (input " (tostring usage.input)
        ", output " (tostring usage.output)
        ", cache read " (tostring usage.cache-read)
        ", cache write " (tostring usage.cache-write) ")\n"
        "tokens: " (util.format-token-summary usage approx) "\n"
        "reply cap: " (tostring agent.max-tokens) " tokens\n"
        "session: " (or session-path "disabled") "\n"
        "note: approx context is estimated locally; reported usage comes from completed provider calls.")))

(fn M.register [api]
  (api.register :command
    {:name :status
     :description "Show model, provider, message count, and token usage"
     :handler (fn [_args state]
                (extensions.emit
                  {:type :assistant-text
                   :text (format-status state)}))}))

M
