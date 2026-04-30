;; /model command: list and switch active provider/model.
;;
;; Bare /model opens an fzf-style overlay over available models. /model
;; <query> keeps the existing index/canonical-id/substring resolve path so
;; scripts and muscle memory still work.

(local extensions (require :fen.core.extensions))
(local models (require :fen.core.llm.models))
(local settings (require :fen.core.settings))

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
    (set state.opts.provider-from-settings? false)
    (set state.opts.model-from-settings? false)
    (when state.loader.reload
      (state.loader.reload state.loader))
    (let [new-agent (state.make-agent-from-opts
                      state.opts state.on-event state.loader state.agent-extra)]
      (set new-agent.messages saved)
      (set new-agent.on-message-append
           (fn [_message _agent]
             (state.flush)
             (when state.update-queue-status (state.update-queue-status))))
      (set state.agent new-agent)
      (let [(ok? err) (pcall settings.set-defaults!
                              model-ref.provider model-ref.id)]
        (when (not ok?)
          (extensions.emit
            {:type :error
             :error (.. "failed to persist default model: "
                        (tostring err))})))
      (when state.update-queue-status (state.update-queue-status))
      (extensions.emit
        {:type :set-status-info
         :info {:provider state.opts.provider
                :model state.agent.model}})
      (extensions.emit
        {:type :info
         :text (.. "switched model to "
                   (models.canonical-model-id model-ref))}))))

(fn build-choices [state available]
  (let [out []]
    (each [_ m (ipairs (sorted-copy available))]
      (let [canon (models.canonical-model-id m)
            current? (= canon (current-canonical state))
            prefix (if current? "* " "  ")
            default-suffix (if m.default? " (default)" "")]
        (table.insert out
                      {:label (.. prefix canon default-suffix)
                       :value m
                       :description (tostring (or m.api ""))})))
    out))

(fn pick-model! [state available]
  (let [choices (build-choices state available)]
    (if (= (length choices) 0)
        (extensions.emit
          {:type :error :error "no models configured"})
        (let [ui (extensions.build-ui-slot)
              picked (ui.select {:label "switch model"
                                 :choices choices})]
          (when picked
            (let [m (or picked.value picked)]
              (when (and m m.provider m.id)
                (switch-model! state m))))))))

(fn handle-model [args state]
  (let [query (trim args)
        available (models.available-models state.opts)]
    (if (= query "")
        (pick-model! state available)
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
     :description "Switch model (overlay if no arg; index/name/substring if given)"
     :idle-only? true
     :handler handle-model}))

M
