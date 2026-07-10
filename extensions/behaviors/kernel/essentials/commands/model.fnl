;; /model command: list and switch active provider/model.
;;
;; Bare /model opens an fzf-style overlay over available models. In an
;; interactive presenter, /model <query> seeds that selector; exact/indexed
;; references and headless use retain direct switching.

(local M {})

(local trim (. (require :fen.util.text) :trim))

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
          (api.emit
            {:type :error
             :error (.. "failed to persist default model: "
                        (tostring err))})))
      (when state.update-queue-status (state.update-queue-status))
      (api.emit
        {:type :set-status-info
         :info {:provider state.opts.provider
                :model state.agent.model
                :thinking-status state.agent.thinking-status}})
      (api.emit
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

(fn completion-choices [api ctx]
  (let [state (?. ctx :state)
        opts (or (?. state :opts) {})
        current (and state state.agent (current-canonical state))
        out []]
    (each [_ m (ipairs (sorted-copy (api.models.list opts)))]
      (let [canon (api.models.canonical-id m)
            details []]
        (when (= canon current)
          (table.insert details "current"))
        (when m.default?
          (table.insert details "default"))
        (when m.api
          (table.insert details (tostring m.api)))
        (table.insert out {:label canon
                           :value canon
                           :description (table.concat details " · ")})))
    out))

(fn pick-model! [api state available ?initial-query]
  (let [choices (build-choices api state available)]
    (if (= (length choices) 0)
        (api.emit
          {:type :error :error "no models configured"})
        (let [picked (api.ui.select {:label "switch model"
                                     :choices choices
                                     :initial-query (or ?initial-query "")})]
          (when picked
            (let [m (or picked.value picked)]
              (when (and m m.provider m.id)
                (switch-model! api state m))))))))

(fn exact-resolution? [api query resolved]
  (and (= resolved.status :ok)
       (let [m resolved.model]
         (or (= query (api.models.canonical-id m))
             (= query (tostring m.id))))))

(fn apply-resolution! [api state query resolved]
  (if (= resolved.status :ok)
      (switch-model! api state resolved.model)
      (= resolved.status :ambiguous)
      (api.emit
        {:type :assistant-text
         :text (format-candidates
                 api
                 (.. "ambiguous model: " query)
                 resolved.candidates)})
      (api.emit
        {:type :error
         :error (.. "unknown model: " query " (try /model)")})))

(fn handle-model [api args state]
  (let [query (trim args)
        available (api.models.list state.opts)]
    (if (= query "")
        (pick-model! api state available)
        (let [indexed (indexed-model query available)
              resolved (and (not indexed)
                            (api.models.resolve query available))]
          (if indexed
              (switch-model! api state indexed)
              (exact-resolution? api query resolved)
              (switch-model! api state resolved.model)
              (api.ui.has-ui?)
              (pick-model! api state available query)
              (apply-resolution! api state query resolved))))))

;; @doc fen.extensions.essentials.commands.model.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /model command for selecting configured models by overlay with an optional initial query, or by direct index or exact id.
;; tags: commands model register
(fn M.register [api]
  (api.register :command
    {:name :model
     :order 12
     :description "Switch model (fuzzy selector; exact id/index switches directly)"
     :idle-only? true
     :complete (fn [_arg-prefix ctx] (completion-choices api ctx))
     :handler (fn [args state] (handle-model api args state))}))

M
