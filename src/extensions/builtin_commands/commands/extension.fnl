;; Extension-management slash commands.

(local extensions (require :core.extensions))
(local util (require :extensions.builtin_commands.util))

(local M {})

(fn M.register [api]
  (api.register :command
    {:name :reload-extension
     :order 20
     :description "Reload one external extension by name"
     :idle-only? true
     :handler (fn [args state]
                (let [name (util.first-arg args)]
                  (if (or (not name) (= name ""))
                      (extensions.emit {:type :error
                                        :error "usage: /reload-extension <name>"})
                      (let [(ok? err) (if state.reload-extension
                                          (state.reload-extension name)
                                          (values false "extension loader unavailable"))]
                        (if ok?
                            (let [saved state.agent.messages
                                  new-agent (state.make-agent-from-opts
                                              state.opts state.on-event state.loader
                                              state.agent-extra)]
                              ;; Pick up changed tools/system-prompt fragments
                              ;; while preserving the live conversation.
                              (set new-agent.messages saved)
                              (set state.agent new-agent)
                              (extensions.emit {:type :info
                                                :text (.. "reloaded extension: " name)}))
                            (extensions.emit {:type :error
                                              :error (.. "reload-extension: "
                                                         (tostring err))}))))))})

  (api.register :command
    {:name :extensions
     :order 10
     :description "List loaded/discovered extensions"
     :handler (fn [_args _state]
                (let [items (extensions.list :extensions)
                      lines ["Extensions"]]
                  (if (= (length items) 0)
                      (table.insert lines "  none")
                      (each [_ e (ipairs items)]
                        (table.insert lines
                                      (.. "  " (tostring e.name)
                                          " — " (tostring e.status)
                                          (if e.path (.. " — " e.path) "")))))
                  (extensions.emit {:type :assistant-text
                                    :text (table.concat lines "\n")})))}))

M
