;; Agent loop. Operates entirely on canonical AgentMessages (see core.types);
;; provider-specific conversion is delegated to whichever provider record is
;; selected via `:provider-api`.
;;
;; Mirrors pi-mono's split: the agent loop owns the prompt → assistant →
;; tool-calls → tool-results → loop control. Wire shaping, auth, and HTTP
;; transport live in src/providers/*.

(local llm (require :core.llm))
(local tools-mod (require :core.tools))
(local types (require :core.types))
(local log (require :util.log))

(local SAFETY-CAP 100)

;; Sentinel raised from yield! when cancellation is requested. step-coop
;; pcalls the loop and converts this into a clean :cancelled exit; any
;; other error propagates normally. Using a unique table value keeps it
;; from colliding with strings or numbers a downstream error might raise.
(local CANCEL-MARKER {:type :cancel-marker})

(fn make-yield [cancel-fn]
  "Returns a yield function for use inside step-coop. Plain `coroutine.yield`
   if no cancel-fn was given; otherwise yields then raises CANCEL-MARKER
   when cancel-fn returns truthy. Provider coop transports receive this
   same function as their yield-fn so cancellation propagates through HTTP."
  (if cancel-fn
      (fn []
        (coroutine.yield)
        (when (cancel-fn) (error CANCEL-MARKER)))
      (fn [] (coroutine.yield))))

(fn make-agent [{: provider-api : model : system : tools : api-key : on-event
                 : max-tokens : convert-to-llm : provider-options}]
  (let [tool-list (or tools tools-mod.registry)]
    {:provider-api (or provider-api :openai-completions)
     : model
     : api-key
     :system-prompt system
     :messages []
     :tools tool-list
     :max-tokens (or max-tokens 16384)
     :on-event (or on-event (fn [_] nil))
     ;; Mirrors pi-mono's `convertToLlm`: AgentMessage[] → canonical Message[].
     ;; The provider's convert-messages then turns canonical Messages into
     ;; wire shape. Default is identity — agent.messages already holds
     ;; canonical Messages; this seam is here for future custom AgentMessage
     ;; extensions (notes, internal markers, etc.).
     :convert-to-llm (or convert-to-llm (fn [msgs] msgs))
     ;; Provider-specific extras passed verbatim into the provider's
     ;; complete options (e.g. {:thinking-budget 2048} for Anthropic,
     ;; {:base-url "..."} for either). :api-key and :max-tokens are
     ;; injected automatically; anything else flows through.
     :provider-options (or provider-options {})}))

(fn build-options [agent]
  (let [opts {:api-key agent.api-key :max-tokens agent.max-tokens}]
    (each [k v (pairs agent.provider-options)]
      (tset opts k v))
    opts))

(fn emit [agent ev] (agent.on-event ev))

(fn build-context [agent]
  {:system-prompt agent.system-prompt
   :messages (agent.convert-to-llm agent.messages)
   :tools (tools-mod.descriptors agent.tools)})

(fn run-tool-calls [agent tool-calls]
  "Execute the tool-call blocks of the latest assistant turn; append a
   canonical ToolResultMessage for each."
  (each [_ tc (ipairs tool-calls)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (let [result (tools-mod.execute agent.tools tc.name tc.arguments)
          msg (types.tool-result-message
                {:tool-call-id tc.id
                 :tool-name tc.name
                 :content result.content
                 :is-error? result.is-error?
                 :details result.details})]
      (table.insert agent.messages msg)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :result result}))))

(fn run-tool-calls-coop [agent tool-calls yield!]
  "Like run-tool-calls but yields between each tool, and routes through
   tools-mod.execute-coop so tools with an :execute-coop variant (bash)
   can yield while waiting on their own I/O. Tools without a coop
   implementation still block for the duration of their call. yield! is
   the cancellation-aware yield helper from `make-yield` so a queued
   cancel fires at any of these yield points."
  (each [_ tc (ipairs tool-calls)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (yield!)
    (let [result (tools-mod.execute-coop agent.tools tc.name tc.arguments yield!)
          msg (types.tool-result-message
                {:tool-call-id tc.id
                 :tool-name tc.name
                 :content result.content
                 :is-error? result.is-error?
                 :details result.details})]
      (table.insert agent.messages msg)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :result result})
      (yield!))))

(fn step [agent user-msg]
  "Run one user turn through the loop. Appends a UserMessage, then iterates
   provider call → tool execution until the assistant returns a non-tool
   stop reason or we hit the safety cap. Returns the final visible text."
  (table.insert agent.messages (types.user-message user-msg))
  (var done? false)
  (var final nil)
  (var safety SAFETY-CAP)
  (while (and (not done?) (> safety 0))
    (set safety (- safety 1))
    (emit agent {:type :llm-start})
    (let [context (build-context agent)
          asst (llm.complete agent.provider-api agent.model context
                             (build-options agent))]
      (emit agent {:type :llm-end :usage asst.usage})
      (table.insert agent.messages asst)
      (if (= asst.stop-reason :error)
          (let [err-text (or asst.error-message "unknown")]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (run-tool-calls agent (types.assistant-tool-calls asst))
          ;; :stop / :length / :aborted → final
          (let [text (types.assistant-text asst)]
            (emit agent {:type :assistant-text :text text})
            (set final text)
            (set done? true)))))
  (when (and (not done?) (<= safety 0))
    (log.warn (.. "agent: hit step safety cap (" SAFETY-CAP " turns)"))
    (set final "[error] tool-call loop exceeded safety cap"))
  final)

(fn step-coop-loop [agent yield!]
  "The body of `step-coop`, extracted so it can run inside a pcall that
   converts the CANCEL-MARKER sentinel into a clean cancellation exit.
   Returns the final visible text on normal completion."
  (var done? false)
  (var final nil)
  (var safety SAFETY-CAP)
  (while (and (not done?) (> safety 0))
    (set safety (- safety 1))
    (emit agent {:type :llm-start})
    (yield!)
    (let [context (build-context agent)
          asst (if llm.complete-coop
                   (llm.complete-coop agent.provider-api agent.model context
                                      (build-options agent) yield!)
                   (llm.complete agent.provider-api agent.model context
                                 (build-options agent)))]
      (emit agent {:type :llm-end :usage asst.usage})
      (table.insert agent.messages asst)
      (yield!)
      (if (= asst.stop-reason :error)
          (let [err-text (or asst.error-message "unknown")]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (run-tool-calls-coop agent (types.assistant-tool-calls asst) yield!)
          (let [text (types.assistant-text asst)]
            (emit agent {:type :assistant-text :text text})
            (set final text)
            (set done? true)))))
  (when (and (not done?) (<= safety 0))
    (log.warn (.. "agent: hit step-coop safety cap (" SAFETY-CAP " turns)"))
    (set final "[error] tool-call loop exceeded safety cap"))
  final)

(fn rollback-messages! [agent target-len]
  "Truncate agent.messages back to `target-len`. Mutates in place so any
   external holder of the same table (e.g. /reload preserving messages by
   reference) sees the same truncation."
  (while (> (length agent.messages) target-len)
    (table.remove agent.messages)))

(fn step-coop [agent user-msg cancel-fn]
  "Cooperative variant of `step` that yields between phases so the TUI
   event loop can interleave redraws, resize handling, and input editing.
   Provider HTTP uses `llm.complete-coop` when available; providers without
   a coop implementation fall back to the blocking `complete` path. Tool
   execution itself is still blocking until Phase 4.

   When `cancel-fn` is provided, every yield checks it after resuming. A
   truthy return rolls agent.messages back to its pre-turn length (so the
   session never persists a half-finished turn), emits `:cancelled`, and
   returns \"[cancelled]\". Non-cancel errors propagate as before."
  (let [start-len (length agent.messages)
        yield! (make-yield cancel-fn)]
    (table.insert agent.messages (types.user-message user-msg))
    (let [(ok? result) (pcall step-coop-loop agent yield!)]
      (if (and (not ok?) (= result CANCEL-MARKER))
          (do (rollback-messages! agent start-len)
              (emit agent {:type :cancelled})
              "[cancelled]")
          (not ok?)
          (error result)
          result))))

{: make-agent : step : step-coop : SAFETY-CAP}
