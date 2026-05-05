;; First-party agent_state tool extension.
;;
;; The implementation lives next to this extension in
;; extensions.agent_state.tool; this module only contributes the tool
;; descriptor/registration so introspection is optional extension surface
;; instead of part of the core tool registry.

(local agent-state (require :fen.extensions.agent_state.tool))
(local extensions (require :fen.core.extensions))

(extensions.unregister-by-owner :agent_state)
(local api (extensions.make-api :agent_state))

(api.register :tool
              {:name :agent_state
               :label "Agent State"
               :snippet "Inspect read-only agent state"
               :description "Read structured state of the running agent. Read-only; does not evaluate code. Query is a tiny Fennel-shaped data language. Examples: (:get :model), (:count (:get :messages)), (:get :messages -1), (:pluck (:get :tools) :name), (:get :extensions :panels), (:where (:get :messages) :role :assistant), (:last (:where (:get :messages) :role :assistant)), (:slice (:get :messages) -5 5), (:keys (:get)). Prefer narrow queries over dumping large roots. Output defaults to JSON; use format=fennel for Fennel rendering when available."
               :parameters {:type :object
                            :properties {:query {:type :string
                                                 :description "Read-only query form, e.g. (:get :messages -1 :content)"}
                                         :format {:type :string
                                                  :enum [:json :fennel]
                                                  :description "Output format; defaults to json"}
                                         :max_bytes {:type :integer
                                                     :description "Maximum output bytes before truncation (default 8192)"}}
                            :required [:query]}
               :execute (fn [args ctx] (agent-state.execute args ctx api))})

true
