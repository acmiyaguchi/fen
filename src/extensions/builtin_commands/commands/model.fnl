;; /model command: list and switch active provider/model.

(local extensions (require :core.extensions))
(local models (require :core.llm.models))

(local M {})

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn current-canonical [state]
  (.. (tostring state.opts.provider) "/" (tostring state.agent.model)))

(fn compare-models [a b]
  (let [ap (tostring a.provider)
        bp (tostring b.provider)]
    (if (= ap bp)
        (< (tostring a.id) (tostring b.id))
        (< ap bp))))

(fn sorted-copy [items]
  (let [out []]
    (each [_ item (ipairs (or items []))]
      (table.insert out item))
    (table.sort out compare-models)
    out))

(fn format-model-line [state idx model-ref]
  (let [canon (models.canonical-model-id model-ref)
        current? (= canon (current-canonical state))
        marker (if current? "*" " ")
        suffix (if model-ref.default? " (default)" "")]
    (.. marker " " (tostring idx) "  " canon suffix)))

(fn format-model-list [state available]
  (let [lines [(.. "Current model: " (current-canonical state)) "" "Available models:"]
        sorted (sorted-copy available)]
    (if (= (length sorted) 0)
        (table.insert lines "  none configured")
        (each [i m (ipairs sorted)]
          (table.insert lines (format-model-line state (- i 1) m))))
    (table.insert lines "")
    (table.insert lines "Usage: /model <index>  or  /model <provider/model>  or  /model <unique-id>")
    (table.concat lines "\n")))

(fn format-candidates [title candidates]
  (let [lines [title]]
    (each [_ m (ipairs (sorted-copy candidates))]
      (table.insert lines (.. "  " (models.canonical-model-id m))))
    (table.concat lines "\n")))

(fn indexed-model [query available]
  (let [idx (tonumber query)]
    (when (and idx (= query (tostring idx)) (>= idx 0)
               (= idx (math.floor idx)))
      (. (sorted-copy available) (+ idx 1)))))

(fn switch-model! [state model-ref]
  (let [saved state.agent.messages]
    (set state.opts.provider model-ref.provider)
    (set state.opts.model model-ref.id)
    (when state.loader.reload
      (state.loader.reload state.loader))
    (let [new-agent (state.make-agent-from-opts
                      state.opts state.on-event state.loader state.agent-extra)]
      ;; Reuse the messages table by reference, matching /reload.
      (set new-agent.messages saved)
      (set new-agent.on-message-append
           (fn [_message _agent] (state.flush)))
      (set state.agent new-agent)
      (extensions.emit
        {:type :set-status-info
         :info {:provider state.opts.provider
                :model state.agent.model}})
      (extensions.emit
        {:type :assistant-text
         :text (.. "✓ Switched model to "
                   (models.canonical-model-id model-ref))}))))

(fn handle-model [args state]
  (let [query (trim args)
        available (models.available-models state.opts)]
    (if (= query "")
        (extensions.emit
          {:type :assistant-text
           :text (format-model-list state available)})
        (let [by-index (indexed-model query available)]
          (if by-index
              (switch-model! state by-index)
              (let [resolved (models.resolve-model query available)]
                (if (= resolved.status :ok)
                    (switch-model! state resolved.model)
                    (= resolved.status :ambiguous)
                    (extensions.emit
                      {:type :assistant-text
                       :text (format-candidates
                               (.. "ambiguous model: " query)
                               resolved.candidates)})
                    (extensions.emit
                      {:type :error
                       :error (.. "unknown model: " query " (try /model)")}))))))))

(fn M.register [api]
  (api.register :command
    {:name :model
     :order 12
     :description "Show/switch model by index or name (run /model to list)"
     :idle-only? true
     :handler handle-model}))

M
