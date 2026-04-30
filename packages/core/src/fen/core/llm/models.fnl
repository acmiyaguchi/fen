;; Custom-provider config loader.
;;
;; Reads `${XDG_CONFIG_HOME:-~/.config}/fen/models.json` and exposes
;; provider records that main.fnl consults before falling back to the
;; built-in `openai` / `anthropic` entries. Mirrors the floor of pi-mono's
;; `~/.pi/agent/models.json`:
;;
;;   {"providers": {
;;      "ollama": {
;;        "baseUrl": "http://localhost:11434/v1",
;;        "api": "openai-completions",
;;        "apiKey": "ollama",
;;        "compat": {"maxTokensField": "max_tokens"},
;;        "models": [{"id": "llama3.1:8b"}]
;;      }
;;    }}
;;
;; Skipped vs pi-mono (per issue #8 trimmed-parity scope):
;;   - `!shell-cmd` apiKey resolution.
;;   - `modelOverrides` (partial overrides on built-in models).
;;   - Per-model compat overrides — provider-level only.
;;   - Cost/pricing fields.
;;
;; The file is optional. Missing → empty. Malformed → log.warn + empty (we
;; refuse to crash startup on a stray comma in a config file).

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))

(local PROVIDER-API
  {:openai :openai-completions
   :openai-responses :openai-responses
   :openai-codex :openai-codex-responses
   :anthropic :anthropic-messages})

(local DEFAULT-MODELS
  {:openai :gpt-5.5
   :openai-responses :gpt-5.5
   :openai-codex :gpt-5.5
   :anthropic :claude-sonnet-4-6})

;; openai-codex intentionally absent: Codex auth is OAuth credentials
;; from ~/.pi/agent/auth.json, resolved separately by main.fnl.
(local API-KEY-VARS
  {:openai :OPENAI_API_KEY
   :openai-responses :OPENAI_API_KEY
   :anthropic :ANTHROPIC_API_KEY})

(local AUTH-CHECKS {})

(fn register-builtin-auth-check! [provider-name check-fn]
  "Register an optional predicate used by available-models for built-ins whose
   auth is owned by a provider rock (for example openai-codex OAuth). Keeps
   fen-core independent of provider modules while letting the kitchen-sink CLI
   expose auth-configured provider models in /model."
  (if check-fn
      (tset AUTH-CHECKS provider-name check-fn)
      (tset AUTH-CHECKS provider-name nil)))

(fn auth-configured? [provider-name]
  (let [check (. AUTH-CHECKS provider-name)]
    (if check
        (let [(ok? result) (pcall check)]
          (and ok? result))
        false)))

(fn provider-api [provider-name]
  (. PROVIDER-API provider-name))

(fn default-model-id [provider-name]
  (. DEFAULT-MODELS provider-name))

(fn api-key-var [provider-name]
  (. API-KEY-VARS provider-name))

(fn builtin-provider? [provider-name]
  (if (. PROVIDER-API provider-name) true false))

(fn config-dir []
  (path.config-dir :fen))

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
   shape) to the canonical Lua-side record main.fnl wants. We keep the
   `compat` table verbatim — providers consume it directly."
  (when (and raw (= (type raw) :table))
    {:api (or raw.api raw.API)
     :base-url (or raw.baseUrl raw.base-url raw.base_url)
     :api-key (resolve-api-key (or raw.apiKey raw.api-key raw.api_key))
     :compat (or raw.compat {})
     :models (or raw.models [])}))

(fn get-provider [name]
  "Returns a normalized provider record, or nil if `name` isn't configured.
   `name` is matched as-is against the keys in the providers map."
  (normalize-provider (. (load) name)))

(fn first-model-id [provider]
  "Convenience for main.fnl when the user passes --provider <name> with no
   --model: pick the first model id declared under that provider, or nil
   if the models array is empty."
  (let [m (?. provider :models 1)]
    (?. m :id)))

(fn canonical-model-id [model-ref]
  (.. (tostring model-ref.provider) "/" (tostring model-ref.id)))

(fn add-model! [out provider-name provider builtin?]
  (each [i m (ipairs (or provider.models []))]
    (let [id (if (= (type m) :table) m.id m)]
      (when id
        (table.insert out
          {:provider provider-name
           :id id
           :api provider.api
           :api-key provider.api-key
           :base-url provider.base-url
           :compat provider.compat
           :builtin? builtin?
           :default? (= i 1)})))))

(fn available-models [_opts]
  "Return flat model refs for auth-configured built-ins plus all custom
   models.json providers. Custom providers intentionally allow nil api-key
   so authless local endpoints (Ollama/LM Studio/vLLM) are selectable."
  (let [out []
        custom-raw (load)]
    ;; Custom providers win on name collision with built-ins, matching
    ;; main.fnl's resolve-provider-config precedence.
    (each [name _raw (pairs custom-raw)]
      (let [provider (get-provider name)]
        (when provider
          (add-model! out name provider false))))
    (each [name api (pairs PROVIDER-API)]
      (when (not (. custom-raw name))
        (let [key-var (. API-KEY-VARS name)
              api-key (when key-var (os.getenv key-var))
              model-id (. DEFAULT-MODELS name)]
          (if (= name :openai-codex)
              (when (auth-configured? name)
                (add-model! out name
                            {:api api :api-key nil :models [{:id model-id}]}
                            true))
              (when (and model-id key-var api-key (not= api-key ""))
                (add-model! out name
                            {:api api :api-key api-key :models [{:id model-id}]}
                            true))))))
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

(fn resolve-model-exact [query models]
  "Resolve pi-mono-style exact model refs: canonical provider/id first,
   then unique bare id."
  (let [q (tostring (or query ""))
        canonical (find-canonical q models)]
    (if canonical
        {:status :ok :model canonical}
        (result-for-matches
          (collect-matches #(= q (tostring $1.id)) models)))))

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
 : resolve-api-key : looks-like-env-var?
 : first-model-id
 : provider-api : default-model-id : api-key-var : builtin-provider?
 : register-builtin-auth-check!
 : available-models : canonical-model-id
 : resolve-model-exact : resolve-model}
