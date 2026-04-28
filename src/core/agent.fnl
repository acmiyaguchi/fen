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

(fn make-agent [opts]
  (let [provider-api (. opts :provider-api)
        model (. opts :model)
        system (. opts :system)
        tools (. opts :tools)
        api-key (. opts :api-key)
        on-event (. opts :on-event)
        max-tokens (. opts :max-tokens)
        convert-to-llm (. opts :convert-to-llm)
        provider-options (. opts :provider-options)
        get-steering (. opts :get-steering)
        get-follow-up (. opts :get-follow-up)
        tool-list (or tools [])]
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
     ;; Queue callbacks mirror pi-mono's steering/follow-up seams. They return
     ;; raw user lines; this module wraps them as canonical UserMessages when
     ;; the loop reaches a safe injection boundary.
     :get-steering (or get-steering (fn [] []))
     :get-follow-up (or get-follow-up (fn [] []))
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

(fn inject-user-lines! [agent lines event-type]
  "Append queued raw user lines as canonical messages and emit an event for
   the live UI. Empty/nil callback returns are fine."
  (each [_ line (ipairs (or lines []))]
    (when (and line (not= line ""))
      (table.insert agent.messages (types.user-message line))
      (emit agent {:type event-type :text line}))))

(fn inject-after-natural-stop! [agent]
  "Poll queues when the agent would otherwise stop. Steering wins over
   follow-up, matching pi-mono: a steering message typed while the assistant is
   responding should run before any follow-up messages. Returns true when a
   queued message was injected and the loop should continue."
  (let [steering (agent.get-steering)]
    (if (> (length (or steering [])) 0)
        (do (inject-user-lines! agent steering :steering-injected)
            true)
        (let [followups (agent.get-follow-up)]
          (when (> (length (or followups [])) 0)
            (inject-user-lines! agent followups :follow-up-injected)
            true)))))

(fn visible-assistant-block? [block]
  (or (and (= block.type :text)
           (= (type block.text) :string)
           (not= block.text ""))
      (and (= block.type :thinking)
           (= (type block.thinking) :string)
           (not= block.thinking ""))))

(fn emit-assistant-display [agent asst final?]
  "Emit assistant text/thinking transcript events in content-block order.
   Thinking events are visible rows like pi-mono's assistant message renderer;
   `final?` marks the last visible block as turn-completing. Returns true when
   at least one visible block was emitted."
  (var last-visible nil)
  (each [i block (ipairs (or asst.content []))]
    (when (visible-assistant-block? block)
      (set last-visible i)))
  (var emitted? false)
  (each [i block (ipairs (or asst.content []))]
    (when (visible-assistant-block? block)
      (set emitted? true)
      (if (= block.type :thinking)
          (emit agent {:type :assistant-thinking
                       :text block.thinking
                       :final? (and final? (= i last-visible))
                       :spacer-after? (< i last-visible)})
          (= block.type :text)
          (emit agent {:type :assistant-text
                       :text block.text
                       :final? (and final? (= i last-visible))}))))
  emitted?)

(fn run-tool-calls [agent tool-calls]
  "Execute the tool-call blocks of the latest assistant turn; append a
   canonical ToolResultMessage for each."
  (each [_ tc (ipairs tool-calls)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (let [out (tools-mod.execute-call agent.tools tc {:agent agent})]
      (table.insert agent.messages out.message)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :duration-seconds out.duration-seconds
                   :result out.result}))))

(fn run-tool-calls-coop [agent tool-calls yield!]
  "Like run-tool-calls but yields between each tool, and routes through
   tools-mod.execute-call-coop so tools with an :execute-coop variant (bash)
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
    (let [out (tools-mod.execute-call-coop agent.tools tc yield! {:agent agent})]
      (table.insert agent.messages out.message)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :duration-seconds out.duration-seconds
                   :result out.result})
      (yield!))))

(fn make-provider-stream-handler [agent state]
  "Translate provider stream events into lightweight agent/TUI delta events.
   The final canonical AssistantMessage still arrives from the provider return
   value and is appended exactly once by step-coop-loop."
  (fn [ev]
    (if (= ev.type :text-delta)
        (when (and ev.delta (not= ev.delta ""))
          (set state.visible? true)
          (emit agent {:type :assistant-text-delta
                       :content-index ev.content-index
                       :delta ev.delta}))
        (= ev.type :thinking-delta)
        (when (and ev.delta (not= ev.delta ""))
          (set state.visible? true)
          (emit agent {:type :assistant-thinking-delta
                       :content-index ev.content-index
                       :delta ev.delta}))
        nil)))

(fn finish-stream-display [agent state final?]
  (when state.visible?
    (emit agent {:type :assistant-stream-end :final? final?})))

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
    (inject-user-lines! agent (agent.get-steering) :steering-injected)
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
          (do (emit-assistant-display agent asst false)
              (run-tool-calls agent (types.assistant-tool-calls asst)))
          ;; :stop / :length / :aborted → final
          (let [text (types.assistant-text asst)]
            (when (not (emit-assistant-display agent asst true))
              (emit agent {:type :assistant-text :text text}))
            (set final text)
            (set done? true)
            (when (inject-after-natural-stop! agent)
              (set done? false))))))
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
    (inject-user-lines! agent (agent.get-steering) :steering-injected)
    (emit agent {:type :llm-start})
    (yield!)
    (let [context (build-context agent)
          opts (build-options agent)
          stream-state {:visible? false}
          on-stream (make-provider-stream-handler agent stream-state)
          asst (if llm.complete-stream
                   (llm.complete-stream agent.provider-api agent.model context opts on-stream yield!)
                   llm.complete-coop
                   (llm.complete-coop agent.provider-api agent.model context opts yield!)
                   (llm.complete agent.provider-api agent.model context opts))]
      (emit agent {:type :llm-end :usage asst.usage})
      (table.insert agent.messages asst)
      (yield!)
      (if (= asst.stop-reason :error)
          (let [err-text (or asst.error-message "unknown")]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (do (if stream-state.visible?
                  (finish-stream-display agent stream-state false)
                  (emit-assistant-display agent asst false))
              (run-tool-calls-coop agent (types.assistant-tool-calls asst) yield!))
          (let [text (types.assistant-text asst)]
            (if stream-state.visible?
                (finish-stream-display agent stream-state true)
                (when (not (emit-assistant-display agent asst true))
                  (emit agent {:type :assistant-text :text text})))
            (set final text)
            (set done? true)
            (when (inject-after-natural-stop! agent)
              (set done? false))))))
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
   Provider HTTP uses `llm.complete-coop` when available; providers
   without a coop implementation fall back to blocking `complete`. Tools
   are dispatched through `tools-mod.execute-call-coop`, so bash drains its
   pipe in nonblocking chunks; tools without an :execute-coop entry
   block for the duration of their call.

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
