;; Prompt introspection slash commands.

(local extensions (require :core.extensions))

(local M {})

(fn trim [s]
  (-> (or s "") (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn rendered-arg? [args]
  (= (string.lower (trim args)) "rendered"))

(fn format-fragments []
  (let [items (extensions.list :prompt-fragments)
        lines ["Prompt fragments"]]
    (if (= (length items) 0)
        (table.insert lines "  none")
        (each [_ f (ipairs items)]
          (let [name (if f.id
                         (.. (tostring f.owner) "/" (tostring f.id))
                         (tostring f.owner))]
            (table.insert lines
                          (.. "  " (tostring f.order)
                              "  " name
                              "  seq=" (tostring f.seq)
                              "  " (if f.dynamic? "dynamic" "static")))
            (when f.title
              (table.insert lines (.. "      title: " (tostring f.title))))
            (when f.description
              (table.insert lines (.. "      desc: " (tostring f.description)))))))
    (table.concat lines "\n")))

(fn M.register [api]
  (api.register :command
    {:name :prompt
     :order 30
     :description "Show system-prompt fragments; use `/prompt rendered` for the full prompt"
     :handler (fn [args state]
                (extensions.emit
                  {:type :assistant-text
                   :text (if (rendered-arg? args)
                             (or (?. state :agent :system-prompt) "")
                             (format-fragments))}))}))

M
