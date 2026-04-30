;; Agent loop. Operates entirely on canonical AgentMessages (see core.types);
;; provider-specific conversion is delegated to whichever provider record is
;; selected via `:provider-api`.
;;
;; Mirrors pi-mono's split: the agent loop owns the prompt → assistant →
;; tool-calls → tool-results → loop control. Wire shaping, auth, and HTTP
;; transport live in src/providers/*.

(local llm (require :fen.core.llm))
(local tools-mod (require :fen.core.tools))
(local types (require :fen.core.types))
(local log (require :fen.util.log))

(local SAFETY-CAP 100)

;; Sentinel raised from yield! when cancellation is requested. `step` pcalls
;; the loop in cooperative mode and converts this into a clean :cancelled
;; exit; any other error propagates normally. A unique table value keeps it
;; from colliding with strings or numbers a downstream error might raise.
(local CANCEL-MARKER {:type :cancel-marker})

(fn in-coroutine? []
  "True when we're running inside a coroutine, false on the main thread.
   Lua 5.4: `coroutine.running` returns (thread, is-main?). The agent loop
   uses this to decide whether to thread a yield-fn through providers and
   tools; non-coop callers never yield."
  (let [(_co main?) (coroutine.running)]
    (not main?)))

(fn make-yield [cancel-fn]
  "Returns a yield function: plain `coroutine.yield` if no cancel-fn was
   given; otherwise yields then raises CANCEL-MARKER when cancel-fn returns
   truthy. Provider coop transports receive this same function as their
   yield-fn so cancellation propagates through HTTP."
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
        on-message-append (. opts :on-message-append)
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
     ;; Called immediately after this module appends a canonical message to
     ;; agent.messages. Used by session persistence to flush per message.
     :on-message-append (or on-message-append (fn [_message _agent] nil))
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

(fn append-message! [agent message]
  "Append one canonical message and notify the persistence hook immediately."
  (table.insert agent.messages message)
  (agent.on-message-append message agent)
  message)

(fn build-context [agent]
  {:system-prompt agent.system-prompt
   :messages (agent.convert-to-llm agent.messages)
   :tools (tools-mod.descriptors agent.tools)})

(fn inject-user-lines! [agent lines event-type]
  "Append queued raw user lines as canonical messages and emit an event for
   the live UI. Empty/nil callback returns are fine."
  (each [_ line (ipairs (or lines []))]
    (when (and line (not= line ""))
      (append-message! agent (types.user-message line))
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

(fn run-tool-calls [agent tool-calls ?yield!]
  "Execute the tool-call blocks of the latest assistant turn; append a
   canonical ToolResultMessage for each. Pass ?yield! for cooperative mode:
   yields between each tool and forwards yield-fn into the tool's
   `:execute` so a coop-aware tool (bash) can yield while waiting on its
   own I/O. Tools that don't use yield-fn block for the duration of their
   call."
  (each [_ tc (ipairs tool-calls)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (when ?yield! (?yield!))
    (let [out (tools-mod.execute-call agent.tools tc {:agent agent} ?yield!)]
      (append-message! agent out.message)
      (emit agent {:type :tool-result
                   :name tc.name
                   :id tc.id
                   :duration-seconds out.duration-seconds
                   :result out.result})
      (when ?yield! (?yield!)))))

(fn make-provider-stream-handler [agent state]
  "Translate provider stream events into lightweight agent/TUI delta events.
   The final canonical AssistantMessage still arrives from the provider return
   value and is appended exactly once by step-loop."
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

(fn complete-once [agent context opts ?yield!]
  "Single dispatch through `llm.complete`. In cooperative mode (?yield!
   present) we pass an on-stream handler and yield-fn; the dispatcher
   prefers the provider's native streaming, falls back through coop and
   blocking, and synthesizes block events when needed. The returned
   stream-state lets step-loop tell whether visible content arrived through
   the stream so it can pick the right end-of-turn presentation."
  (if (not ?yield!)
      (values (llm.complete agent.provider-api agent.model context opts) nil)
      (let [stream-state {:visible? false}
            on-stream (make-provider-stream-handler agent stream-state)
            asst (llm.complete agent.provider-api agent.model
                               context opts on-stream ?yield!)]
        (values asst stream-state))))

(fn step-loop [agent ?yield!]
  "Shared body of `step`. ?yield! nil = blocking mode (no yields, plain
   llm.complete, blocking tool execute). ?yield! present = cooperative
   mode (yields between phases, threads on-stream + yield-fn into
   `llm.complete` so the dispatcher picks streaming/coop transports, and
   forwards yield-fn into each tool's :execute so coop-aware tools can
   yield).

   `step` always wraps this in a pcall so the cooperative cancel path can
   catch CANCEL-MARKER cleanly; non-coop callers see identical error
   semantics because pcall re-raises everything else."
  (var done? false)
  (var final nil)
  (var safety SAFETY-CAP)
  (while (and (not done?) (> safety 0))
    (set safety (- safety 1))
    (inject-user-lines! agent (agent.get-steering) :steering-injected)
    (emit agent {:type :llm-start})
    (when ?yield! (?yield!))
    (let [context (build-context agent)
          opts (build-options agent)
          (asst stream-state) (complete-once agent context opts ?yield!)
          streamed? (and stream-state stream-state.visible?)]
      (emit agent {:type :llm-end :usage asst.usage})
      (append-message! agent asst)
      (when ?yield! (?yield!))
      (if (= asst.stop-reason :error)
          (let [err-text (or asst.error-message "unknown")]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (do (if streamed?
                  (finish-stream-display agent stream-state false)
                  (emit-assistant-display agent asst false))
              (run-tool-calls agent (types.assistant-tool-calls asst) ?yield!))
          (let [text (types.assistant-text asst)]
            (if streamed?
                (finish-stream-display agent stream-state true)
                (when (not (emit-assistant-display agent asst true))
                  (emit agent {:type :assistant-text :text text})))
            (set final text)
            (set done? true)
            (when (inject-after-natural-stop! agent)
              (set done? false))))))
  (when (and (not done?) (<= safety 0))
    (log.warn (.. "agent: hit step safety cap (" SAFETY-CAP " turns)"))
    (set final "[error] tool-call loop exceeded safety cap"))
  final)

(fn append-aborted-assistant! [agent]
  (append-message!
    agent
    (types.assistant-message
      {:api agent.provider-api
       :provider :agent
       :model agent.model
       :content []
       :stop-reason :aborted})))

(fn step [agent user-msg ?cancel-fn]
  "Run one user turn through the loop. Appends a UserMessage, then iterates
   provider call → tool execution until the assistant returns a non-tool
   stop reason or we hit the safety cap. Returns the final visible text.

   Cooperative mode auto-detects: if called inside a coroutine the loop
   yields between phases (so the TUI can interleave redraws, resize
   handling, input editing), threads an on-stream handler + yield-fn into
   `llm.complete` (the dispatcher picks the best transport — native
   streaming, coop, or blocking — and synthesizes events when needed),
   and forwards yield-fn into each tool's `:execute`. Called on the main
   thread, the loop runs straight through and tools run blocking.

   `?cancel-fn` is only meaningful in cooperative mode: every yield checks
   it after resuming. A truthy return preserves messages appended so far,
   appends an assistant message with `:stop-reason :aborted`, emits
   `:cancelled`, and returns \"[cancelled]\". Non-cancel errors propagate.
   Always pcalls the loop body so the cooperative cancel path is uniform;
   non-coop callers see identical error semantics because pcall re-raises
   anything that isn't CANCEL-MARKER."
  (let [coop? (in-coroutine?)
        yield! (when coop? (make-yield ?cancel-fn))]
    (append-message! agent (types.user-message user-msg))
    (let [(ok? result) (pcall step-loop agent yield!)]
      (if (and coop? (not ok?) (= result CANCEL-MARKER))
          (do (append-aborted-assistant! agent)
              (emit agent {:type :cancelled})
              "[cancelled]")
          (not ok?)
          (error result)
          result))))

{: make-agent : step : SAFETY-CAP}
