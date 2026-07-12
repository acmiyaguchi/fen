;; First-party agent_state tool extension.
;;
;; The implementation lives next to this extension in
;; extensions.agent_state.tool; this module only contributes the tool
;; descriptor/registration so introspection is optional extension surface
;; instead of part of the core tool registry.

(local agent-state (require :fen.extensions.agent_state.tool))
(local json (require :fen.util.json))
(local types (require :fen.core.types))

(local M {})

(fn models-result [value is-error?]
  (let [text (if (= (type value) :string) value (json.encode value))]
    {:content [(types.text-block text)]
     :is-error? (or is-error? false)}))

(fn models-providers-view [providers]
  (let [out []]
    (each [_ p (ipairs providers)]
      (table.insert out {:name p.name :api p.api :builtin? p.builtin?
                         :default-model p.default-model :available? p.available?
                         :auth p.auth :catalog p.catalog
                         :model-count (length (or p.models []))}))
    out))

(fn models-list-view [providers wanted include-unavailable?]
  (let [out []]
    (each [_ p (ipairs providers)]
      (when (and (or (not wanted) (= wanted "")
                     (= (tostring p.name) (tostring wanted)))
                 (or include-unavailable? p.available?))
        (each [_ m (ipairs (or p.models []))]
          (table.insert out {:provider p.name :id m.id
                             :canonical-id m.canonical-id :default? m.default?
                             :source m.source :available? p.available?}))))
    out))

(fn models-current-view [providers ctx]
  (let [agent (?. ctx :agent)
        provider-name (?. agent :provider-name)
        model (?. agent :model)
        out {:provider provider-name :model model
             :canonical-id (.. (tostring provider-name) "/" (tostring model))}]
    (var found nil)
    (each [_ p (ipairs providers) &until found]
      (when (= (tostring p.name) (tostring provider-name)) (set found p)))
    (when found
      (set out.api found.api)
      (set out.available? found.available?)
      (set out.auth found.auth)
      (set out.catalog found.catalog)
      (each [_ m (ipairs (or found.models []))]
        (when (= (tostring m.id) (tostring model))
          (set out.default? m.default?)
          (set out.source m.source))))
    out))

(fn execute-models [args ctx api ?yield-fn]
  (if (or (not ctx) (not ctx.agent))
      (models-result "error: models requires agent context" true)
      (let [_ (when ?yield-fn (?yield-fn))
            action (or args.action :current)
            query (if (= action :current)
                      {:provider (?. ctx :agent :provider-name) :catalog? true}
                      (= action :list)
                      {:provider args.provider :catalog? true}
                      {:catalog? false})
            ;; Inspection options are intentionally allowlisted: the provider
            ;; registry resolves its own credentials and endpoints.
            providers (api.models.inspect {:yield ?yield-fn} query)]
        (if (= action :current)
            (models-result (models-current-view providers ctx) false)
            (= action :providers)
            (models-result (models-providers-view providers) false)
            (= action :list)
            (models-result (models-list-view providers args.provider
                                             args.include_unavailable) false)
            (models-result (.. "error: unknown action: " (tostring action)) true)))))

(fn M.register [api]
  (api.register :tool
              {:name :agent_state
               :label "Agent State"
               :snippet "Inspect read-only agent state"
               :description "Read structured state of the running agent. Read-only; does not evaluate code. Query is a tiny Fennel-shaped data language. Examples: (:get :model), (:get :thinking), (:count (:get :messages)), (:get :messages -1), (:pluck (:get :tools) :name), (:get :extensions :panels), (:where (:get :messages) :role :assistant), (:last (:where (:get :messages) :role :assistant)), (:slice (:get :messages) -5 5), (:keys (:get)). Prefer narrow queries over dumping large roots. Output defaults to JSON; use format=fennel for Fennel rendering when available."
               :parameters {:type :object
                            :properties {:query {:type :string
                                                 :description "Read-only query form, e.g. (:get :messages -1 :content)"}
                                         :format {:type :string
                                                  :enum [:json :fennel]
                                                  :description "Output format; defaults to json"}
                                         :max_bytes {:type :integer
                                                     :description "Maximum output bytes before truncation (default 8192)"}}
                            :required [:query]}
               :execute (fn [args ctx ?yield-fn]
                          (agent-state.execute args ctx api ?yield-fn))})
  (api.register :tool
    {:name :models
     :label "Models"
     :snippet "Inspect providers and models"
     :description "Inspect model providers without exposing credentials. Actions: current, providers, and list."
     :parameters {:type :object
                  :properties {:action {:type :string :enum [:current :providers :list]}
                               :provider {:type :string}
                               :include_unavailable {:type :boolean}}}
     :execute (fn [args ctx ?yield-fn]
                (execute-models args ctx api ?yield-fn))})
  (api.register :introspect
    {:name :tool
     :description "agent_state query language capabilities"
     :snapshot (fn [_]
                 {:max-bytes-default 8192
                  :formats [:json :fennel]
                  :ops [:get :keys :count :pluck :where :slice :first :last]})})
  true)

M
