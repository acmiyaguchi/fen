;; /model command: list and switch active provider/model.
;;
;; Bare /model opens an fzf-style overlay over available models. /model
;; <query> keeps the existing index/canonical-id/substring resolve path so
;; scripts and muscle memory still work.

(local extensions (require :fen.core.extensions))

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

(fn format-candidates [api title candidates]
  (let [lines [title]]
    (each [_ m (ipairs (sorted-copy candidates))]
      (table.insert lines (.. "  " (api.models.canonical-id m))))
    (table.concat lines "\n")))

(fn indexed-model [query available]
  (let [idx (tonumber query)]
    (when (and idx (= query (tostring idx)) (>= idx 0)
               (= idx (math.floor idx)))
      (. (sorted-copy available) (+ idx 1)))))

(fn switch-model! [api state model-ref]
  (let [saved state.agent.messages]
    (set state.opts.provider model-ref.provider)
    (set state.opts.model model-ref.id)
    (set state.opts.provider-from-settings? false)
    (set state.opts.model-from-settings? false)
    (let [new-agent (state.make-agent-from-opts
                      state.opts state.on-event state.agent-extra)]
      (set new-agent.messages saved)
      (set state.agent new-agent)
      (let [(ok? err) (pcall api.settings.set-defaults!
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
                   (api.models.canonical-id model-ref))}))))

(fn build-choices [api state available]
  (let [out []]
    (each [_ m (ipairs (sorted-copy available))]
      (let [canon (api.models.canonical-id m)
            current? (= canon (current-canonical state))
            prefix (if current? "* " "  ")
            default-suffix (if m.default? " (default)" "")]
        (table.insert out
                      {:label (.. prefix canon default-suffix)
                       :value m
                       :description (tostring (or m.api ""))})))
    out))

(fn pick-model! [api state available]
  (let [choices (build-choices api state available)]
    (if (= (length choices) 0)
        (extensions.emit
          {:type :error :error "no models configured"})
        (let [picked (api.ui.select {:label "switch model"
                                 :choices choices})]
          (when picked
            (let [m (or picked.value picked)]
              (when (and m m.provider m.id)
                (switch-model! api state m))))))))

(fn handle-model [api args state]
  (let [query (trim args)
        available (api.models.list state.opts)]
    (if (= query "")
        (pick-model! api state available)
        (let [by-index (indexed-model query available)]
          (if by-index
              (switch-model! api state by-index)
              (let [resolved (api.models.resolve query available)]
                (if (= resolved.status :ok)
                    (switch-model! api state resolved.model)
                    (= resolved.status :ambiguous)
                    (extensions.emit
                      {:type :assistant-text
                       :text (format-candidates
                               api
                               (.. "ambiguous model: " query)
                               resolved.candidates)})
                    (extensions.emit
                      {:type :error
                       :error (.. "unknown model: " query " (try /model)")}))))))))

;; @doc fen.extensions.builtin_commands.commands.model.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /model command for selecting configured models by overlay, index, exact id, or substring query.
;; tags: commands model register
(fn M.register [api]
  (api.register :command
    {:name :model
     :order 12
     :description "Switch model (overlay if no arg; index/name/substring if given)"
     :idle-only? true
     :handler (fn [args state] (handle-model api args state))}))

M
