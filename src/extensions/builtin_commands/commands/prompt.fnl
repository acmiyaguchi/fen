;; Prompt introspection slash commands.

(local extensions (require :core.extensions))

(local M {})

(fn format-fragments []
  (let [items (extensions.prompt-contributions)
        lines ["Prompt fragments"]]
    (if (= (length items) 0)
        (table.insert lines "  none")
        (each [_ f (ipairs items)]
          (table.insert lines
                        (.. "  " (tostring f.order)
                            "  " (tostring f.owner)
                            "  slot=" (tostring f.slot)
                            "  seq=" (tostring f.seq)
                            "  " (if f.dynamic? "dynamic" "static")))))
    (table.concat lines "\n")))

(fn M.register [api]
  (api.register :command
    {:name :prompt
     :order 30
     :description "Show the current system prompt"
     :handler (fn [_args state]
                (extensions.emit
                  {:type :assistant-text
                   :text (or (?. state :agent :system-prompt) "")}))})

  (api.register :command
    {:name :prompt-fragments
     :order 31
     :description "Show system-prompt fragment order and owners"
     :handler (fn [_args _state]
                (extensions.emit
                  {:type :assistant-text
                   :text (format-fragments)}))}))

M
