;; OpenRouter provider (openrouter.ai/api/v1/chat/completions).
;;
;; OpenRouter speaks the OpenAI Chat Completions wire protocol, so this adapter
;; reuses `fen.extensions.provider_openai.openai_completions` through its
;; flavor seam (`complete-with`) instead of forking the wire conversion or the
;; stream reducer. This module owns only what is OpenRouter-specific:
;;
;; - identity (`:openrouter` / `:openrouter-completions`) and endpoint;
;; - the normalized `reasoning` request object mapped from fen's thinking
;;   controls (never top-level `reasoning_effort`);
;; - `reasoning_details` capture/echo (enabled on the shared reducer), which
;;   keeps Gemini thought signatures and Anthropic signed thinking intact
;;   across tool turns;
;; - explicit `cache_control` breakpoints for Anthropic and Google models;
;; - app attribution headers, sticky `session_id`, and
;;   `provider.require_parameters` so routing never silently drops tools or
;;   reasoning;
;; - a curated catalog: `/models` is fetched but only configured ids are
;;   returned, never OpenRouter's full catalog; the fetch also records which
;;   of them take `reasoning`.

(local completions (require :fen.extensions.provider_openai.openai_completions))
(local model-catalog (require :fen.extensions.provider_openai.openai_model_catalog))
(local json (require :fen.util.json))
(local http (require :fen.util.http))

(local API :openrouter-completions)
(local PROVIDER :openrouter)
(local DEFAULT-BASE-URL "https://openrouter.ai/api/v1")
(local APP-URL "https://github.com/acmiyaguchi/fen")
(local APP-TITLE "fen")
(local APP-CATEGORIES "cli-agent")
;; OpenRouter caps session_id at 256 characters.
(local SESSION-ID-MAX 256)

;; Curated, tool-capable models across vendors. Order matters: the first entry
;; is the provider default when no `--model` / saved model is given. Users
;; extend or replace this list through a models.json provider with
;; `"api": "openrouter-completions"` instead of seeing the full catalog.
(local MODELS
  [{:id "google/gemini-3.8-flash"}
   {:id "anthropic/claude-sonnet-5"}
   {:id "deepseek/deepseek-v4.1-flash"}
   {:id "qwen/qwen3.8-flash"}])

;; `reasoning.effort` values OpenRouter accepts besides `none`.
(local EFFORTS {:max true :xhigh true :high true :medium true :low true
                :minimal true})

(fn starts-with? [s prefix]
  (= (string.sub s 1 (length prefix)) prefix))

;; ----------------------------------------------------------------
;; Reasoning
;; ----------------------------------------------------------------

(fn level->reasoning [level]
  "Map a provider-neutral thinking level to `{:effort level}`, or nil. `off`
   is nil like no setting: some models (current Gemini) make reasoning
   mandatory and reject `enabled: false`, so a saved global `off` must leave
   the model default rather than brick them."
  (let [l (string.lower (tostring (or level "")))]
    (when (. EFFORTS l) {:effort l})))

(fn effort->reasoning [effort]
  "Map an explicit --reasoning-effort word to OpenRouter's `reasoning`
   object, or nil when it is not a value OpenRouter accepts. Only this exact
   escape hatch disables reasoning (`none`/`off`)."
  (let [e (string.lower (tostring (or effort "")))]
    (if (or (= e "off") (= e "none")) {:enabled false}
        (level->reasoning e))))

;; @doc fen.extensions.provider_openrouter.openrouter_completions.reasoning-config
;; kind: function
;; signature: (reasoning-config options) -> table|nil
;; summary: Map fen thinking options to OpenRouter's normalized reasoning object; thinking-budget beats reasoning-effort beats thinking-level, only reasoning-effort none/off disables, and nil (including thinking-level off) leaves the model default.
;; tags: openrouter provider reasoning thinking
(fn reasoning-config [options]
  (let [opts (or options {})
        budget opts.thinking-budget]
    (if (and (= (type budget) :number) (> budget 0))
        {:max_tokens budget}
        (or (and opts.reasoning-effort (effort->reasoning opts.reasoning-effort))
            (and opts.thinking-level (level->reasoning opts.thinking-level))))))

;; Per-process reasoning support by model id, refreshed by every `list-models`
;; (which core calls once per catalog cache lifetime, i.e. until /reload,
;; which also resets this reloadable module). true/false when the live
;; catalog says so; absent means unknown.
(local reasoning-support {})

(fn reasoning-supported? [model]
  "False only when the last catalog fetch showed model without `reasoning` in
   its supported_parameters; true or nil (unknown) otherwise."
  (. reasoning-support (tostring (or model ""))))

;; ----------------------------------------------------------------
;; Prompt caching
;; ----------------------------------------------------------------

;; @doc fen.extensions.provider_openrouter.openrouter_completions.cache-breakpoints?
;; kind: function
;; signature: (cache-breakpoints? model) -> boolean
;; summary: True for Anthropic and Google models, whose upstreams only prompt-cache at explicit cache_control breakpoints.
;; tags: openrouter provider caching
(fn cache-breakpoints? [model]
  (let [m (tostring (or model ""))]
    (or (not= nil (string.match m "^~?anthropic/"))
        (not= nil (string.match m "^~?google/")))))

(fn mark-cache-breakpoint! [msg]
  "Put `cache_control` on the last text part of msg, converting a plain string
   content into a one-part array. Returns true when a breakpoint was placed."
  (let [content msg.content]
    (if (and (= (type content) :string) (not= content ""))
        (do (set msg.content [{:type :text :text content
                               :cache_control {:type :ephemeral}}])
            true)
        (and (= (type content) :table) (not (json.null? content)))
        (do (var placed? false)
            (for [i (length content) 1 -1 &until placed?]
              (let [part (. content i)]
                (when (and (= (type part) :table) (= part.type :text))
                  (set part.cache_control {:type :ephemeral})
                  (set placed? true))))
            placed?)
        false)))

;; @doc fen.extensions.provider_openrouter.openrouter_completions.add-cache-breakpoints!
;; kind: function
;; signature: (add-cache-breakpoints! messages) -> messages
;; summary: Mark the system prompt and the latest user/tool message with ephemeral cache_control breakpoints (two of Anthropic's four).
;; tags: openrouter provider caching
(fn add-cache-breakpoints! [messages]
  (var system-done? false)
  (each [_ msg (ipairs (or messages [])) &until system-done?]
    (when (= msg.role :system)
      (mark-cache-breakpoint! msg)
      (set system-done? true)))
  (var tail-done? false)
  (for [i (length (or messages [])) 1 -1 &until tail-done?]
    (let [msg (. messages i)]
      (when (or (= msg.role :user) (= msg.role :tool))
        (set tail-done? (mark-cache-breakpoint! msg)))))
  messages)

;; ----------------------------------------------------------------
;; Request policy (flavor hooks for openai_completions)
;; ----------------------------------------------------------------

;; @doc fen.extensions.provider_openrouter.openrouter_completions.patch-headers
;; kind: function
;; signature: (patch-headers headers opts streaming?) -> table
;; summary: Add OpenRouter app attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) to a Chat Completions request.
;; tags: openrouter provider http
(fn patch-headers [headers _opts _streaming?]
  (tset headers :http-referer APP-URL)
  (tset headers :x-openrouter-title APP-TITLE)
  (tset headers :x-openrouter-categories APP-CATEGORIES)
  headers)

;; @doc fen.extensions.provider_openrouter.openrouter_completions.patch-body
;; kind: function
;; signature: (patch-body body model context opts streaming?) -> table
;; summary: Apply OpenRouter request policy to a Chat Completions body: reasoning object (omitted for models the live catalog marks as non-reasoning), require_parameters routing, sticky session_id, and cache_control breakpoints.
;; tags: openrouter provider http reasoning caching
(fn patch-body [body model _context opts _streaming?]
  (let [opts (or opts {})
        reasoning (when (not= false (reasoning-supported? model))
                    (reasoning-config opts))
        session-id opts.prompt-cache-key]
    ;; The normalized `reasoning` object is the only reasoning knob sent, and
    ;; never to a model that cannot take it: under require_parameters that
    ;; would leave no endpoint to route to.
    (set body.reasoning_effort nil)
    (set body.reasoning reasoning)
    ;; Only route to endpoints that honor every parameter (tools, reasoning).
    ;; That makes the parameter set itself a routing filter: `max_tokens` is
    ;; the one limit every endpoint lists (many lack max_completion_tokens),
    ;; and many tool-capable endpoints do not list `parallel_tool_calls`, so
    ;; sending its default `true` would only shrink the pool for no behavior
    ;; change; it is dropped, while an explicit false still goes out.
    (set body.provider {:require_parameters true})
    (let [limit (or body.max_completion_tokens body.max_tokens)]
      (set body.max_completion_tokens nil)
      (set body.max_tokens limit))
    (when (= body.parallel_tool_calls true)
      (set body.parallel_tool_calls nil))
    (when (and (= (type session-id) :string) (not= session-id ""))
      (set body.session_id (string.sub session-id 1 SESSION-ID-MAX)))
    (when (cache-breakpoints? model)
      (add-cache-breakpoints! body.messages))
    body))

(local FLAVOR {:api API
               :provider PROVIDER
               :default-base-url DEFAULT-BASE-URL
               :reasoning-details? true
               :patch-headers patch-headers
               :patch-body patch-body})

;; @doc fen.extensions.provider_openrouter.openrouter_completions.build-request-opts
;; kind: function
;; signature: (build-request-opts model context options ?on-chunk) -> table
;; summary: Assemble the fen.util.http opts for an OpenRouter Chat Completions POST (streaming when ?on-chunk is given).
;; tags: openrouter provider http
(fn build-request-opts [model context options ?on-chunk]
  (completions.build-request-opts model context options ?on-chunk FLAVOR))

(fn complete [model context options ?on-event ?yield-fn]
  "Streams when ?on-event is given, else a single POST; cooperative when
   ?yield-fn is given. Returns a canonical AssistantMessage."
  (completions.complete-with FLAVOR model context options ?on-event ?yield-fn))

;; ----------------------------------------------------------------
;; Curated catalog
;; ----------------------------------------------------------------

(fn catalog-headers [api-key]
  (let [headers {:accept "application/json"}]
    (when (and api-key (not= api-key ""))
      (set headers.authorization (.. "Bearer " api-key)))
    headers))

;; `:nitro`, `:floor`, `:free`, ... route variants share their base model's
;; catalog entry.
(fn base-model-id [id]
  (or (string.match id "^(.+):[^:/]+$") id))

(fn model-id [m]
  (if (= (type m) :table) m.id m))

(fn catalog-entry [id item]
  "One returned model: id plus what the live catalog item (if any) says."
  (let [params (?. item :supported_parameters)
        reasoning? (when (= (type params) :table)
                     (accumulate [found? false _ p (ipairs params) &until found?]
                       (= p :reasoning)))]
    {:id id
     :context-window (when (= (type (?. item :context_length)) :number)
                       item.context_length)
     : reasoning?}))

;; @doc fen.extensions.provider_openrouter.openrouter_completions.curate-models
;; kind: function
;; signature: (curate-models decoded wanted declared?) -> [{:id string :context-window number? :reasoning? boolean?}]
;; summary: Match wanted model ids against a decoded /models catalog in wanted order, enriched with context length and reasoning support; the curated list keeps only live ids, a declared (models.json) list keeps every id.
;; tags: openrouter provider models
(fn curate-models [decoded wanted declared?]
  (let [by-id {}
        out []]
    (each [_ item (ipairs (or (?. decoded :data) []))]
      (when (and (= (type item) :table) (= (type item.id) :string))
        (tset by-id item.id item)))
    (each [_ m (ipairs wanted)]
      (let [id (model-id m)
            item (and id (or (. by-id id) (. by-id (base-model-id id))))]
        (when (or item (and id declared?))
          (table.insert out (catalog-entry id item)))))
    out))

(fn remember-reasoning-support! [models]
  "Record what one catalog fetch says; several providers (the built-in and a
   models.json override) may share this adapter, so entries merge by id."
  (each [_ m (ipairs models)]
    (tset reasoning-support m.id m.reasoning?)))

;; @doc fen.extensions.provider_openrouter.openrouter_completions.list-models
;; kind: function
;; signature: (list-models opts) -> [{:id string :context-window number? :reasoning? boolean?}]
;; summary: Fetch OpenRouter's /models catalog and return the configured ids: every id of a models.json override (opts.models), else the curated ids that are live.
;; tags: openrouter provider models http
(fn list-models [opts]
  (let [opts (or opts {})
        declared? (and opts.models (> (length opts.models) 0))
        wanted (if declared? opts.models MODELS)
        resp (http.request {:method :GET
                            :url (model-catalog.models-url
                                   (or opts.base-url DEFAULT-BASE-URL))
                            :headers (catalog-headers opts.api-key)
                            :timeout-ms (or opts.timeout-ms 30000)
                            :connect-timeout-ms (or opts.connect-timeout-ms 10000)
                            :yield opts.yield})]
    (when resp.error
      (error {:reason :request-failed}))
    (when (or (< resp.status 200) (>= resp.status 300))
      (error {:reason (if (or (= resp.status 401) (= resp.status 403))
                          :authentication-failed
                          :request-failed)}))
    (let [(ok? decoded) (pcall json.decode (or resp.body ""))]
      (when (or (not ok?) (not= (type decoded) :table))
        (error {:reason :request-failed}))
      (let [models (curate-models decoded wanted declared?)]
        (remember-reasoning-support! models)
        models))))

;; @doc fen.extensions.provider_openrouter.openrouter_completions.api
;; kind: data
;; signature: keyword
;; summary: Provider API keyword (openrouter-completions); models.json providers with this api delegate to the OpenRouter adapter.
;; tags: openrouter provider metadata
;; @doc fen.extensions.provider_openrouter.openrouter_completions.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword used on canonical assistant messages emitted by the OpenRouter adapter.
;; tags: openrouter provider metadata
;; @doc fen.extensions.provider_openrouter.openrouter_completions.models
;; kind: data
;; signature: [{:id string}]
;; summary: Curated tool-capable OpenRouter model ids; the first entry is the provider default.
;; tags: openrouter provider models
{:api API
 :provider PROVIDER
 :default-base-url DEFAULT-BASE-URL
 :models MODELS
 : reasoning-config
 : cache-breakpoints?
 : add-cache-breakpoints!
 : patch-headers
 : patch-body
 : build-request-opts
 : curate-models
 : list-models
 : complete}
