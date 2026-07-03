;; Deterministic, scriptable mock provider.
;;
;; Returns canonical AssistantMessages with no network I/O, so tests, smoke
;; runs, and offline dev can drive the agent loop and TUI deterministically.
;;
;; Drive responses with a *script*, resolved in this order:
;;   1. `options.mock-script` (provider option) — a path string, or an
;;      already-loaded sequence/function (handy for in-process tests);
;;   2. the `FEN_MOCK_SCRIPT` environment variable — a path to a `.fnl`/`.lua`
;;      file (the CLI / smoke / dev knob);
;;   3. no script → echo the last user text.
;;
;; A loaded script is either:
;;   - a SEQUENCE of turns, replayed one per assistant turn. The turn index is
;;     `(count of assistant messages already in context) + 1`, so replay is
;;     stateless and survives /reload — there is no cursor to keep.
;;   - a FUNCTION `(fn [req] turn)` for programmable / rule-based responses,
;;     where `req = {:messages :tools :system-prompt :model :options :turn}`.
;;
;; A "turn" is a string (shorthand for visible text) or a table:
;;   {:text "..."}                                   ; visible assistant text
;;   {:thinking "..." :text "..."}                   ; reasoning + text
;;   {:tool-call {:id "c1" :name :read :args {...}}}  ; one tool call
;;   {:tool-calls [{...} {...}]}                      ; parallel tool calls
;;   {:error "boom"}                                  ; stop-reason :error
;;   {:content [...] :stop-reason :stop :usage {...}} ; raw canonical passthrough
;; `:stop-reason` defaults to :tool-use when the turn calls a tool, else :stop.

(local types (require :fen.core.types))

(local API :mock)
(local PROVIDER :mock)

;; Loaded-script cache keyed by file path. A plain reloadable-module local:
;; cleared on /reload, which is correct — it is an optimization, not identity
;; state that must persist.
(local script-cache {})

(fn load-script-file [path]
  (or (. script-cache path)
      (let [loaded (if (string.match path "%.lua$")
                       (dofile path)
                       (let [fennel (require :fennel)]
                         (fennel.dofile path)))]
        (when (= loaded nil)
          (error (.. "mock provider: script returned nil: " path)))
        (tset script-cache path loaded)
        loaded)))

(fn resolve-script [options]
  "Return the loaded script (sequence/function), or nil for the echo default."
  (let [opt options.mock-script]
    (if (or (= (type opt) :table) (= (type opt) :function)) opt
        (= (type opt) :string) (load-script-file opt)
        (let [env (os.getenv "FEN_MOCK_SCRIPT")]
          (when (and env (not= env "")) (load-script-file env))))))

(fn count-assistant [messages]
  (accumulate [n 0 _ m (ipairs (or messages []))]
    (if (= m.role :assistant) (+ n 1) n)))

(fn last-user-text [messages]
  "Text of the last user message, or nil. User content may be a bare string
   or a canonical block list, so guard the string case before reusing the
   shared text-block concatenator."
  (let [last (accumulate [found nil _ m (ipairs (or messages []))]
               (if (= m.role :user) m found))]
    (when last
      (if (= (type last.content) :string) last.content
          (types.assistant-text last)))))

(fn norm-tool-call [tc]
  (types.tool-call-block
    (or tc.id (.. "mock_call_" (tostring (or tc.name :tool))))
    (tostring (or tc.name :noop))
    (or tc.args tc.arguments {})))

;; @doc fen.extensions.provider_mock.mock_provider.spec->assistant
;; kind: function
;; signature: (spec->assistant spec model) -> AssistantMessage
;; summary: Normalize a mock turn spec (string or table) into a canonical AssistantMessage; stop-reason defaults to :tool-use when the turn calls a tool, else :stop.
;; tags: provider mock testing
(fn spec->assistant [spec model]
  (let [spec (if (= (type spec) :string) {:text spec} (or spec {}))]
    (if spec.error
        (types.assistant-error API PROVIDER model spec.error)
        (let [content (or spec.content
                          (let [c []]
                            (when (and spec.thinking (not= spec.thinking ""))
                              (table.insert c (types.thinking-block {:thinking spec.thinking})))
                            (when (and spec.text (not= spec.text ""))
                              (table.insert c (types.text-block spec.text)))
                            (when spec.tool-call
                              (table.insert c (norm-tool-call spec.tool-call)))
                            (when spec.tool-calls
                              (each [_ tc (ipairs spec.tool-calls)]
                                (table.insert c (norm-tool-call tc))))
                            c))]
          (types.assistant-message
            {:api API :provider PROVIDER :model model
             :content content
             :usage spec.usage
             :stop-reason (or spec.stop-reason
                              (if (> (length (types.assistant-tool-calls {:content content})) 0)
                                  :tool-use :stop))})))))

(fn resolve-spec [model context options]
  (let [script (resolve-script options)
        turn (+ (count-assistant context.messages) 1)]
    (if (= (type script) :function)
        (script {:messages context.messages
                 :tools context.tools
                 :system-prompt context.system-prompt
                 :model model
                 :options options
                 :turn turn})
        (= (type script) :table)
        (or (. script turn) {:text "[mock] script exhausted"})
        ;; default: echo the last user message
        {:text (.. "[mock] " (or (last-user-text context.messages) "no input"))})))

(fn emit-block-events [asst emit]
  "Synthesize streaming block events from an already-complete AssistantMessage,
   so the agent's streaming path sees the same event sequence a real provider
   would produce."
  (when emit
    (emit {:type :start})
    ;; Error assistant messages often carry a synthetic "[error] ..." text
    ;; block for final-message consumers. Do not replay that block as normal
    ;; assistant text in the stream fallback; emit only the terminal error.
    (when (not= asst.stop-reason :error)
      (each [i block (ipairs (or asst.content []))]
        (if (= block.type :text)
            (let [text (or block.text "")]
              (emit {:type :text-start :content-index i})
              (when (not= text "")
                (emit {:type :text-delta :content-index i :delta text}))
              (emit {:type :text-end :content-index i :content text}))
            (= block.type :thinking)
            (let [text (or block.thinking "")]
              (emit {:type :thinking-start :content-index i})
              (when (not= text "")
                (emit {:type :thinking-delta :content-index i :delta text}))
              (emit {:type :thinking-end :content-index i :content text}))
            (= block.type :tool-call)
            (do
              (emit {:type :tool-call-start :content-index i})
              (emit {:type :tool-call-end :content-index i :tool-call block})))))
    (emit (if (= asst.stop-reason :error)
              {:type :error :message asst}
              {:type :done :message asst}))))

;; @doc fen.extensions.provider_mock.mock_provider.complete
;; kind: function
;; signature: (complete model context options ?on-event ?yield-fn) -> AssistantMessage
;; summary: Deterministic provider entry point. Builds a canonical AssistantMessage from the resolved mock script (or an echo default) and, when streaming, replays it through a local block-event synthesizer. When options.mock-record is a table, appends a snapshot of each outbound call (model, options, system-prompt, tools, copied messages) so tests can assert what the agent sent. Performs no network I/O.
;; tags: provider mock complete
(fn complete [model context options ?on-event ?yield-fn]
  (let [options (or options {})
        spec (resolve-spec model context options)
        asst (spec->assistant spec model)]
    ;; Recording hook: callers (tests) pass a table on options.mock-record to
    ;; capture each outbound call. Snapshot messages by shallow copy because the
    ;; agent mutates its message list in place across loop iterations.
    (when (= (type options.mock-record) :table)
      (table.insert options.mock-record
                    {:model model
                     :options options
                     :context {:system-prompt context.system-prompt
                               :tools context.tools
                               :messages (icollect [_ v (ipairs (or context.messages []))] v)}}))
    (when ?on-event
      (emit-block-events asst ?on-event))
    asst))

;; @doc fen.extensions.provider_mock.mock_provider.api
;; kind: data
;; signature: keyword
;; summary: Provider API family keyword for the deterministic mock adapter.
;; tags: provider mock metadata
;; @doc fen.extensions.provider_mock.mock_provider.provider
;; kind: data
;; signature: keyword
;; summary: Provider owner keyword stamped on canonical assistant messages emitted by the mock adapter.
;; tags: provider mock metadata
{:api API
 :provider PROVIDER
 :default-model :mock
 :models [{:id "mock"}]
 : complete
 : spec->assistant}
