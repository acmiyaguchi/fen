;; Custom-provider config loader.
;;
;; Reads `${XDG_CONFIG_HOME:-~/.config}/agent-fennel/models.json` and exposes
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

(local json (require :util.json))
(local log (require :util.log))

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn config-dir []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel")
        (.. (home) "/.config/agent-fennel"))))

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
;; re-required (which happens on /reload — main.fnl adds :core.llm.models to
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

{: config-dir : config-path
 : load : get-provider
 : resolve-api-key : looks-like-env-var?
 : first-model-id}
