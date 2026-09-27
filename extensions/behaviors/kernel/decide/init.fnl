;; Decide extension entry point. Experimental.
;;
;; Opt-in (`:enabled-by-default false`). Everything Jev-backed lives in this
;; extension: the decision service (`fen.extensions.decide.service`), the
;; compaction questions compact calls (`fen.extensions.decide.compaction`),
;; and the input-time questions registered here (`fen.extensions.decide.input`).
;; Consumers require those modules, never this entry (the loader cache-busts
;; entry modules on a fresh load!).

(local store (require :fen.extensions.decide.state))
(local service (require :fen.extensions.decide.service))
(local decide-input (require :fen.extensions.decide.input))
(local subcommands (require :fen.util.subcommands))

(local M {})

(fn undo-command! [api]
  ;; Success already shows as the :queued steering line from requeue!.
  (let [result (decide-input.undo!)]
    (when (not result.ok)
      (api.emit {:type :info
                 :text (.. "decide undo: " (tostring result.error))}))))

(fn register-command! [api]
  (let [sub (subcommands.build
              {:name :decide
               :emit api.emit
               :summary "Experimental Jev decisions"
               :subcommands
                 {:undo {:description "move the line last reclassified as follow-up back to steering"
                         :handler (fn [_ _] (undo-command! api))}}})]
    (api.register :command
      {:name :decide
       :description "Experimental Jev decisions: /decide undo"
       :usage sub.usage
       :subcommands sub.descriptor
       :handler sub.handler
       :complete sub.complete})))

;; @doc fen.extensions.decide.register
;; kind: function
;; signature: (register api) -> true
;; summary: Capture the api handle for the decision service, finish ask-async! tasks left by a previous instance with nil, pump new tasks on each :runtime-tick, and register the observing input handler, its staleness listeners, and /decide undo.
;; tags: decide register
(fn M.register [api]
  (set store.api api)
  ;; Runs on first load, /reload, and re-enable: tasks from an earlier
  ;; instance report nil now instead of resuming late.
  (service.finish-pending!)
  ;; Everything below resolves through module tables at call time so /reload stays safe.
  (api.on :runtime-tick (fn [_ev] (service.pump!)))
  ;; Observes non-slash input after transforms and before the steering
  ;; fallback (order 1000); never changes the input, and a failure never
  ;; disturbs it.
  (api.register :input-handler
    {:name :decide
     :order 900
     :handle (fn [input ctx]
               (let [(ok? err) (pcall decide-input.observe! api input ctx)]
                 (when (not ok?)
                   (api.log :warn (.. "decide: input observer failed: " (tostring err)))))
               {:action :continue})})
  ;; Every submitted line (slash commands too) and every reset makes a pending topic-shift answer stale.
  (api.on :user (fn [ev] (decide-input.forget-pending! ev)))
  (api.on :reset-conversation (fn [ev] (decide-input.forget-pending! ev)))
  ;; Queue clears report an empty follow-up queue here, which invalidates /decide undo.
  (api.on :set-status-info (fn [ev] (decide-input.on-status-info ev)))
  (register-command! api)
  true)

M
