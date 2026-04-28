;; /help command.

(local extensions (require :core.extensions))

(local M {})

(local HELP-TEXT
  (.. "\n"
      "/new            reset the current conversation\n"
      "/reload         hot-reload core modules (run `make build` first)\n"
      "/status         show model, provider, message count, and token usage\n"
      "/queue          show/clear queued steering and follow-up messages\n"
      "/cancel-all     cancel current turn and clear queues\n"
      "/expand [on|off] toggle full tool-result bodies (default: collapsed)\n"
      "/markdown [on|off] toggle Markdown rendering of assistant text\n"
      "/thinking [on|off] show or hide thinking blocks (default: visible)\n"
      "/help           this list\n"
      "ctrl-o          toggle tool-result bodies\n"
      "ctrl-t          toggle thinking blocks\n"
      "ctrl-c / ctrl-d to quit"))

(fn M.register [api]
  (api.register :command
    {:name :help
     :description "Show available commands"
     :handler (fn [_args _state]
                (extensions.emit {:type :assistant-text :text HELP-TEXT}))}))

M
