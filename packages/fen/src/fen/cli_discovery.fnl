;; Script-facing views over Fen's live extension registries.
;;
;; This deliberately reads the same registries and discovery modules used by
;; runtime docs and extensions instead of maintaining a CLI-only capability
;; table. Provider/model views use the secret-free model introspection API.

(local json (require :fen.util.json))
(local registry (require :fen.core.extensions.register))
(local models (require :fen.core.llm.models))

(local M {})

(local KINDS {:commands :commands :command :commands
              :tools :tools :tool :tools
              :providers :providers :provider :providers
              :models :models :model :models
              :presenters :presenters :presenter :presenters
              :session-backends :session-backends :session-backend :session-backends
              :extensions :extensions :extension :extensions
              :skills :skills :skill :skills
              :agents :agents :agent :agents})

(fn canonical-kind [kind]
  (. KINDS kind))

(fn sort-by-name! [items]
  (table.sort items (fn [a b]
                      (< (tostring (or a.name a.id ""))
                         (tostring (or b.name b.id "")))))
  items)

(fn copy-data [value ?seen]
  "Copy JSON-safe data while dropping callbacks from registry metadata."
  (let [kind (type value)]
    (if (= kind :function)
        nil
        (not= kind :table)
        value
        (let [seen (or ?seen {})]
          (if (. seen value)
              nil
              (let [out {}]
                (tset seen value true)
                (each [k v (pairs value)]
                  (when (not= (type v) :function)
                    (tset out k (copy-data v seen))))
                (tset seen value nil)
                out))))))

(fn provider-records [opts]
  (models.inspect-providers {} {:provider (?. opts :provider)
                                :check? (?. opts :check?)}))

(fn model-records [opts]
  "Return one merged, canonical-id-sorted catalog row per model across
   providers. With opts.all? the merged catalog is limited to providers whose
   auth is available (available? true) so callers see only runnable models;
   each provider's dynamic catalog is fetched and reports catalog-status per
   row (falling back to static/default metadata when the fetch fails)."
  (let [all? (?. opts :all?)
        out []]
    (each [_ provider (ipairs
                        (models.inspect-providers
                          {} {:provider (?. opts :provider) :catalog? true}))]
      (when (or (not all?) provider.available?)
        (each [_ model (ipairs provider.models)]
          (table.insert out
                        {:name model.id
                         :id model.id
                         :canonical-id model.canonical-id
                         :provider provider.name
                         :default? model.default?
                         :source model.source
                         :available? provider.available?
                         :catalog-status provider.catalog.status}))))
    (table.sort out (fn [a b]
                      (< (tostring a.canonical-id)
                         (tostring b.canonical-id))))
    out))

(fn records [requested-kind opts]
  (let [kind (canonical-kind requested-kind)]
    (if (not kind)
        (values nil (.. "unknown discovery surface: " (tostring requested-kind)))
        (= kind :skills)
        (let [skill-mod (require :fen.extensions.skills)
              skills (skill-mod.discover (or (?. opts :extra-skill-paths) []))]
          (sort-by-name! skills))
        (= kind :agents)
        (let [agent-discovery (require :fen.extensions.subagent.discover)
              agents (agent-discovery.list)]
          (sort-by-name! agents))
        (= kind :providers)
        (provider-records opts)
        (= kind :models)
        (model-records opts)
        (let [out []]
          (each [_ item (ipairs (registry.list kind))]
            (table.insert out (copy-data item)))
          (sort-by-name! out)))))

(fn M.list [kind opts]
  (records kind opts))

(fn item-matches? [kind item wanted]
  (or (= (tostring item.name) wanted)
      (and (= kind :models)
           (or (= (tostring item.id) wanted)
               (= (tostring item.canonical-id) wanted)))))

(fn M.show [kind name opts]
  (let [canonical (canonical-kind kind)]
    (if (not canonical)
        (values nil (.. "unknown discovery surface: " (tostring kind)))
        (let [(items err) (records canonical opts)]
          (if err
              (values nil err)
              (let [wanted (tostring name)
                    matches []]
                (each [_ item (ipairs items)]
                  (when (item-matches? canonical item wanted)
                    (table.insert matches item)))
                (if (= (length matches) 1)
                    (. matches 1)
                    (> (length matches) 1)
                    (values nil (.. "ambiguous " (tostring kind) " entry: " wanted
                                    " (use a canonical provider/id or --provider)"))
                    nil)))))))

(local SURFACE-SUMMARIES
  {:commands "Registered slash commands."
   :tools "Agent tools available to a run."
   :providers "Registered LLM providers and secret-free availability metadata."
   :models "Provider model catalogs; may fetch dynamic catalogs."
   :presenters "Registered interactive presenters."
   :session-backends "Registered session persistence backends."
   :extensions "Loaded and discovered extensions."
   :skills "Discovered Agent Skills."
   :agents "Discovered subagent definitions."})

(fn M.kinds [] [:commands :tools :providers :models :presenters :session-backends :extensions :skills :agents])

(fn M.surfaces []
  (icollect [_ kind (ipairs (M.kinds))]
    {:name kind :description (. SURFACE-SUMMARIES kind)}))

(fn M.render [payload json?]
  (if json?
      (json.encode payload)
      (let [items (or payload.items payload.surfaces
                      (if payload.entry [payload.entry] []))
            lines []]
        (each [_ item (ipairs items)]
          (table.insert lines (.. (tostring (or item.name item.id "(unnamed)"))
                                  (if item.description (.. "\t" item.description) "")
                                  (if item.owner (.. "\towner=" (tostring item.owner)) ""))))
        (if (> (length lines) 0) (table.concat lines "\n") "(none)"))))

M
