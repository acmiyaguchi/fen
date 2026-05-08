;; Custom-provider config loader + registry adapter.
;;
;; Reads `${XDG_CONFIG_HOME:-~/.config}/fen/models.json`. Custom providers are
;; normalized from the JSON shape and can be registered into the extension
;; provider registry with owner :models_json. Provider :name is the dispatch key;
;; provider :api is protocol/family metadata used only to find a first-party
;; delegate implementation.

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))
(local register-registry (require :fen.core.extensions.register))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))

;; @doc fen.core.llm.models.config-dir
;; kind: function
;; signature: (config-dir) -> string
;; summary: Return fen's user configuration directory, honoring XDG_CONFIG_HOME through the shared path helper.
;; tags: models config paths
(fn config-dir []
  (path.config-dir :fen))

;; @doc fen.core.llm.models.config-path
;; kind: function
;; signature: (config-path) -> string
;; summary: Return the models.json path used for custom provider and model registry configuration.
;; tags: models config paths
(fn config-path []
  (.. (config-dir) "/models.json"))

(fn slurp [path]
  "Read entire file or return nil silently if missing. We don't log here —
   the file is optional and a missing file is the common case."
  (let [(f _) (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

;; @doc fen.core.llm.models.looks-like-env-var?
;; kind: function
;; signature: (looks-like-env-var? s) -> boolean
;; summary: Return true when an apiKey string looks like an environment variable name rather than a literal credential.
;; tags: models config auth
(fn looks-like-env-var? [s]
  "Heuristic: an apiKey value that's all uppercase letters / digits /
   underscores is treated as an environment variable name. Pi-mono uses
   try-env-then-literal; we keep it simpler. Anyone wanting a literal that
   happens to be all-caps can lowercase it (Ollama's example uses
   lowercase 'ollama' anyway)."
  (if (and s (= (type s) :string)
           (not= s "")
           (string.match s "^[A-Z][A-Z0-9_]*$"))
      true
      false))

;; @doc fen.core.llm.models.resolve-api-key
;; kind: function
;; signature: (resolve-api-key value) -> string|nil
;; summary: Resolve a models.json apiKey field by treating nil/empty values as absent and all-caps values as environment variable names.
;; tags: models config auth
(fn resolve-api-key [value]
  "value → resolved string or nil.
   - nil/empty → nil.
   - All-caps env-var name → os.getenv lookup (nil if unset).
   - Anything else → literal."
  (if (or (= value nil) (= value ""))
      nil
      (looks-like-env-var? value)
      (let [v (os.getenv value)]
        (if (and v (not= v "")) v nil))
      value))

;; Cached parse — populated on first load, dropped when the module is
;; re-required (which happens on /reload — main.fnl adds :fen.core.llm.models to
;; RELOADABLE).
(var cache nil)

(fn parse [raw path]
  "raw JSON string → providers map. log.warn + return empty on malformed."
  (let [(ok? value) (pcall json.decode raw)]
    (if (not ok?)
        (do (log.warn (.. "models: malformed JSON in " path
                          ": " (tostring value)))
            {})
        (let [providers (or (?. value :providers) {})]
          (if (= (type providers) :table)
              providers
              (do (log.warn (.. "models: " path
                                " missing top-level 'providers' object"))
                  {}))))))

;; @doc fen.core.llm.models.load
;; kind: function
;; signature: (load) -> table
;; summary: Load and cache the raw providers map from models.json, returning an empty table for missing or malformed config.
;; tags: models config providers
(fn load []
  "Returns the providers map. Cached after first successful read; the cache
   is keyed on the module identity so `/reload` (which re-requires the
   module) implicitly invalidates it."
  (when (= cache nil)
    (let [path (config-path)
          raw (slurp path)]
      (set cache (if raw (parse raw path) {}))))
  cache)

(fn normalize-provider [raw]
  "Translate a raw JSON provider entry (camelCase, snake_case-ish wire
   shape) to the canonical Lua-side record. We keep the `compat` table verbatim
   — providers consume it directly."
  (when (and raw (= (type raw) :table))
    {:api (or raw.api raw.API)
     :base-url (or raw.baseUrl raw.base-url raw.base_url)
     :api-key (resolve-api-key (or raw.apiKey raw.api-key raw.api_key))
     :compat (or raw.compat {})
     :models (or raw.models [])}))

;; @doc fen.core.llm.models.get-provider
;; kind: function
;; signature: (get-provider name) -> ModelsProvider|nil
;; summary: Return the normalized models.json provider record for name, including api, base-url, api-key, compat, and models.
;; tags: models config providers
(fn get-provider [name]
  "Returns a normalized provider record, or nil if `name` isn't configured.
   `name` is matched as-is against the keys in the providers map."
  (normalize-provider (. (load) name)))

;; @doc fen.core.llm.models.first-model-id
;; kind: function
;; signature: (first-model-id provider) -> string|nil
;; summary: Pick the first declared model id from a normalized provider record for default-model selection.
;; tags: models providers defaults
(fn first-model-id [provider]
  "Convenience for default-model selection: pick the first model id declared
   under that provider, or nil if the models array is empty."
  (let [m (?. provider :models 1)]
    (if (= (type m) :table) m.id m)))

(fn copy-table [t]
  (let [out {}]
    (each [k v (pairs (or t {}))]
      (tset out k v))
    out))

(fn find-delegate-provider [api]
  "Find a non-models.json provider that implements api. Resolved at call time
   so /reload picks up new first-party provider code."
  (var found nil)
  (each [_ ref (ipairs (provider-registry.list)) &until found]
    (when (and (= (tostring ref.api) (tostring api))
               (not= ref.owner :models_json))
      (set found (provider-registry.find ref.name))))
  found)

(fn make-wrapper-complete [name provider registered-delegate]
  (fn [model context options ?on-event ?yield-fn]
    (let [delegate (or (find-delegate-provider provider.api)
                       registered-delegate)]
      (when (not delegate)
        (error (.. "models: provider " (tostring name)
                   " has no registered delegate for api "
                   (tostring provider.api))))
      (let [merged (copy-table options)]
        ;; models.json apiKey is authoritative for this provider. nil is
        ;; intentional for authless local endpoints and omits the auth header.
        (tset merged :api-key provider.api-key)
        (when provider.base-url (tset merged :base-url provider.base-url))
        (when provider.compat (tset merged :compat provider.compat))
        (delegate.complete model context merged ?on-event ?yield-fn)))))

;; @doc fen.core.llm.models.register-providers!
;; kind: function
;; signature: (register-providers!) -> number
;; summary: Register every valid models.json provider into the extension registry under owner :models_json and return the count installed.
;; tags: models providers extensions
(fn register-providers! []
  "Register models.json providers into the extension provider registry.
   Idempotent across /reload; custom names override built-ins because this
   should run after first-party provider extensions register."
  (register-registry.unregister-by-owner :models_json)
  (var count 0)
  (each [name _raw (pairs (load))]
    (let [provider (get-provider name)
          delegate (and provider provider.api (find-delegate-provider provider.api))]
      (if (not provider)
          nil
          (or (not provider.api) (= provider.api ""))
          (log.warn (.. "models: provider " (tostring name)
                        " missing api; skipping"))
          (not delegate)
          (log.warn (.. "models: provider " (tostring name)
                        " uses unknown api " (tostring provider.api)
                        "; skipping"))
          (let [spec {:name name
                      :api provider.api
                      :complete (make-wrapper-complete name provider delegate)
                      :default-model (first-model-id provider)
                      :models provider.models
                      :api-key provider.api-key
                      :base-url provider.base-url
                      :compat provider.compat}]
            (register-registry.register :provider spec :models_json)
            (set count (+ count 1))))))
  count)

;; @doc fen.core.llm.models.canonical-model-id
;; kind: function
;; signature: (canonical-model-id model-ref) -> string
;; summary: Format a model reference as the canonical provider/id string accepted by model resolution and displayed by commands.
;; tags: models resolve
(fn canonical-model-id [model-ref]
  (.. (tostring model-ref.provider) "/" (tostring model-ref.id)))

(fn provider-auth-configured? [provider]
  (if provider.auth-backend
      (let [backend (auth-backend-registry.find provider.auth-backend)]
        (if (and backend backend.configured?)
            (let [(ok? result) (pcall backend.configured?)]
              (and ok? result))
            false))
      provider.api-key-var
      (let [v (os.getenv provider.api-key-var)]
        (and v (not= v "")))
      true))

(fn add-provider-models! [out provider]
  (when (provider-auth-configured? provider)
    (let [models (or provider.models [])
          builtin? (not= provider.owner :models_json)]
      (if (> (length models) 0)
          (each [i m (ipairs models)]
            (let [id (if (= (type m) :table) m.id m)]
              (when id
                (table.insert out
                  {:provider provider.name
                   :id id
                   :api provider.api
                   :api-key provider.api-key
                   :base-url provider.base-url
                   :compat provider.compat
                   :builtin? builtin?
                   :default? (= i 1)}))))
          provider.default-model
          (table.insert out
            {:provider provider.name
             :id provider.default-model
             :api provider.api
             :api-key provider.api-key
             :base-url provider.base-url
             :compat provider.compat
             :builtin? builtin?
             :default? true})))))

;; @doc fen.core.llm.models.available-models
;; kind: function
;; signature: (available-models opts) -> [ModelRef]
;; summary: Return selectable model refs from registered providers, filtering credential-gated built-ins until auth is configured.
;; tags: models providers resolve
(fn available-models [_opts]
  "Return flat model refs for registry-backed providers. Env-var and auth
   backend built-ins are listed only when configured; custom/authless providers
   are selectable."
  (let [out []]
    (each [_ provider (ipairs (provider-registry.list))]
      (add-provider-models! out provider))
    out))

(fn find-canonical [query models]
  (var found nil)
  (each [_ m (ipairs models)]
    (when (= query (canonical-model-id m))
      (set found m)))
  found)

(fn collect-matches [pred models]
  (let [out []]
    (each [_ m (ipairs models)]
      (when (pred m) (table.insert out m)))
    out))

(fn result-for-matches [matches]
  (if (= (length matches) 1)
      {:status :ok :model (. matches 1)}
      (> (length matches) 1)
      {:status :ambiguous :candidates matches}
      {:status :miss :candidates []}))

;; @doc fen.core.llm.models.resolve-model-exact
;; kind: function
;; signature: (resolve-model-exact query models) -> {:status :model :candidates}
;; summary: Resolve an exact model query by canonical provider/id first and then by unique bare model id.
;; tags: models resolve
(fn resolve-model-exact [query models]
  "Resolve pi-mono-style exact model refs: canonical provider/id first,
   then unique bare id."
  (let [q (tostring (or query ""))
        canonical (find-canonical q models)]
    (if canonical
        {:status :ok :model canonical}
        (result-for-matches
          (collect-matches #(= q (tostring $1.id)) models)))))

;; @doc fen.core.llm.models.resolve-model
;; kind: function
;; signature: (resolve-model query models) -> {:status :model :candidates}
;; summary: Resolve a model query by exact provider/id or bare id first, then by unique substring over provider/id or id.
;; tags: models resolve
(fn resolve-model [query models]
  "Resolve a model query for fen's command-mode v1: exact provider/id or
   unique bare id first, then unique substring over provider/id or id."
  (let [exact (resolve-model-exact query models)]
    (if (not= exact.status :miss)
        exact
        (let [q (tostring (or query ""))]
          (if (= q "")
              {:status :miss :candidates []}
              (result-for-matches
                (collect-matches
                  #(or (string.find (canonical-model-id $1) q 1 true)
                       (string.find (tostring $1.id) q 1 true))
                  models)))))))

{: config-dir : config-path
 : load : get-provider
 : register-providers!
 : resolve-api-key : looks-like-env-var?
 : first-model-id
 : available-models : canonical-model-id
 : resolve-model-exact : resolve-model}
