;; Agent loop. Operates entirely on canonical AgentMessages (see core.types);
;; provider-specific conversion is delegated to whichever provider record is
;; selected via `:provider-name`.
;;
;; Mirrors pi-mono's split: the agent loop owns the prompt → assistant →
;; tool-calls → tool-results → loop control. Wire shaping, auth, and HTTP
;; transport live in src/providers/*.

(local llm (require :fen.core.llm))
(local tools-mod (require :fen.core.tools))
(local types (require :fen.core.types))
(local log (require :fen.util.log))
(local text-util (require :fen.util.text))
(local process (require :fen.util.process))
(local session-backend (require :fen.core.extensions.register.session_backend))

;; @doc fen.core.agent.SAFETY-CAP
;; kind: constant
;; signature: number
;; summary: Hard ceiling on tool-call iterations per step. Bump if a real workflow needs more, don't remove.
;; tags: agent loop limits
(local SAFETY-CAP 100)
(local DEFAULT-PARALLEL-TOOL-CAP 4)

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

;; @doc fen.core.agent.make-agent
;; kind: function
;; signature: (make-agent {:provider-name :model :system :tools :api-key :on-event :max-tokens :convert-to-llm :provider-options}) -> Agent
;; summary: Construct an Agent record with empty messages, ready for repeated step calls. :api-key and :max-tokens are auto-injected into provider-options. :convert-to-llm projects custom AgentMessages onto canonical Messages before each provider call.
;; tags: agent loop
(fn make-agent [opts]
  (let [provider-name (or (. opts :provider-name) (. opts :provider-api))
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
        tool-context (. opts :tool-context)
        thinking-status (. opts :thinking-status)
        tool-list (or tools [])]
    {:provider-name (or provider-name :openai)
     : model
     : thinking-status
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
     :tool-context (or tool-context (fn [_agent] {}))
     ;; Provider-specific extras passed verbatim into the provider's
     ;; complete options (e.g. {:thinking-budget 2048} for Anthropic,
     ;; {:base-url "..."} for either). :api-key and :max-tokens are
     ;; injected automatically; anything else flows through.
     :provider-options (or provider-options {})}))

(fn build-options [agent]
  (let [opts {:api-key agent.api-key :max-tokens agent.max-tokens}]
    (each [k v (pairs agent.provider-options)]
      (tset opts k v))
    ;; Resolve the session id at call time (not at construction): the agent is
    ;; built before the session is opened, and /new and /continue rotate the id
    ;; mid-process. A stable prompt-cache-key keeps OpenAI prompt caching sticky
    ;; across turns and resumes; other providers ignore the key. Don't override
    ;; an explicit caller-supplied value.
    (when (= opts.prompt-cache-key nil)
      (let [info (session-backend.info)
            id (and info info.id)]
        (when id (set opts.prompt-cache-key id))))
    opts))

(fn emit [agent ev] (agent.on-event ev))

(fn append-message! [agent message]
  "Append one canonical message and emit the lifecycle append event."
  (table.insert agent.messages message)
  (let [index (length agent.messages)]
    (emit agent {:type :message-appended
                 :message message
                 :agent agent
                 : index}))
  message)

(fn context-message? [m]
  "Errored assistant turns are recorded in the session (for debugging and
   replay tooling) but excluded from provider context. Their `[error] ...`
   text — and any partial, possibly-malformed content left by a failed or
   aborted stream — only pollutes later turns, and re-sending malformed
   partial content is exactly the poison-pill that wedges a session into
   repeated provider 4xx. The agent loop stops on `:error` without running
   tools, so dropping the whole turn never orphans a tool-call/result pair."
  (not (and (= m.role :assistant) (= m.stop-reason :error))))

(fn build-context [agent]
  (let [msgs []]
    (each [_ m (ipairs agent.messages)]
      (when (context-message? m) (table.insert msgs m)))
    {:system-prompt agent.system-prompt
     :messages (agent.convert-to-llm msgs)
     :tools (tools-mod.descriptors agent.tools)}))

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

(fn assistant-tool-calls [msg]
  "Return tool-call content blocks without depending on a reloadable accessor.
   This keeps the agent loop robust when fen.core.types has been hot-reloaded
   across versions with slightly different helper exports."
  (let [out []]
    (each [_ block (ipairs (or msg.content []))]
      (when (= block.type :tool-call)
        (table.insert out block)))
    out))

(fn safe-tool-text [s]
  (. (text-util.scrub-tool-text (tostring (or s ""))) :text))

(fn synthetic-tool-result [tc message ?details]
  "Build a tool-result message for a tool call that did not return normally.
   This keeps provider history valid: APIs like OpenAI Responses reject any
   prior function_call that is missing a matching function_call_output."
  (types.tool-result-message
    {:tool-call-id tc.id
     :tool-name tc.name
     :content [(types.text-block (safe-tool-text message))]
     :is-error? true
     :details ?details}))

(fn append-synthetic-tool-result! [agent tc message ?emit-call?]
  (when ?emit-call?
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id}))
  (let [msg (synthetic-tool-result tc message {:synthetic? true})
        result {:content msg.content :is-error? true :details msg.details}]
    (append-message! agent msg)
    (emit agent {:type :tool-result
                 :name tc.name
                 :id tc.id
                 :duration-seconds 0
                 :result result})
    msg))

(fn append-cancelled-tool-results! [agent tool-calls start-index current-emitted?]
  "Satisfy every unreturned tool call after a cancellation. `start-index` is
   the current/pending tool call; the current call may already have emitted a
   :tool-call event, while later calls have not."
  (for [i start-index (length tool-calls)]
    (let [tc (. tool-calls i)]
      (append-synthetic-tool-result!
        agent tc "[cancelled] tool call cancelled before completion"
        (not (and current-emitted? (= i start-index)))))))

(fn edit-tool-call? [tc]
  (= (tostring tc.name) "edit"))

(fn append-unique! [xs seen v]
  (let [key (tostring v)]
    (when (and v (not= key "") (not (. seen key)))
      (tset seen key true)
      (table.insert xs key))))

(fn edit-call-paths [tc]
  "Return every file path targeted by an edit tool call, deduped per call."
  (let [args (or tc.arguments {})
        paths []
        seen {}]
    (when (edit-tool-call? tc)
      (append-unique! paths seen args.path)
      (each [_ f (ipairs (or args.files []))]
        (append-unique! paths seen (?. f :path))))
    paths))

(fn same-turn-edit-conflicts [tool-calls]
  "Detect edit calls in one assistant turn that target the same file.
   Separate same-file edit calls would otherwise mutate sequentially and
   validate against different snapshots. Force a retry as one batched edit so
   the edit tool's normal all-or-nothing validation applies."
  (let [path-indices {}]
    (each [i tc (ipairs tool-calls)]
      (each [_ path (ipairs (edit-call-paths tc))]
        (when (not (. path-indices path))
          (tset path-indices path []))
        (table.insert (. path-indices path) i)))
    (let [conflict-paths-by-index {}]
      (each [path indices (pairs path-indices)]
        (when (> (length indices) 1)
          (each [_ i (ipairs indices)]
            (when (not (. conflict-paths-by-index i))
              (tset conflict-paths-by-index i []))
            (table.insert (. conflict-paths-by-index i) path))))
      (let [reasons {}]
        (each [i paths (pairs conflict-paths-by-index)]
          (tset reasons i
                (.. "error: multiple edit calls in the same assistant turn target "
                    (table.concat paths ", ")
                    ". Retry with a single batched edit call containing all non-overlapping edits for each file.")))
        reasons))))

(fn tool-context [agent]
  (let [base {:agent agent}
        extra (agent.tool-context agent)]
    (each [k v (pairs (or extra {}))]
      (tset base k v))
    base))

(fn find-tool-record [reg name]
  (var found nil)
  (each [_ t (ipairs (or reg []))]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

(fn tool-parallel-cap [tool]
  (let [raw (or (?. tool :parallel-cap) DEFAULT-PARALLEL-TOOL-CAP)
        cap (tonumber raw)]
    (if (and cap (> cap 0))
        (math.floor cap)
        DEFAULT-PARALLEL-TOOL-CAP)))

(fn parallel-safe-tool-call? [agent tc edit-conflicts i ?yield!]
  "Only cooperative callers can benefit from parallel-safe tools: the scheduler
   relies on each tool's yield callback to multiplex child work. A tool must
   explicitly opt in with internal metadata; provider descriptors strip this."
  (let [tool (find-tool-record agent.tools tc.name)]
    (and ?yield! (not (. edit-conflicts i)) tool (?. tool :parallel-safe?))))

(fn append-tool-output! [agent tc out]
  (append-message! agent out.message)
  (emit agent {:type :tool-result
               :name tc.name
               :id tc.id
               :duration-seconds out.duration-seconds
               :result out.result}))

(fn append-tool-failure! [agent tc err emitted?]
  (append-synthetic-tool-result!
    agent tc
    (.. "error: tool " (tostring tc.name) " failed: " (tostring err))
    (not emitted?)))

(fn run-serial-tool-call [agent tool-calls i edit-conflicts ?yield!]
  (let [tc (. tool-calls i)]
    (emit agent {:type :tool-call
                 :name tc.name
                 :arguments tc.arguments
                 :id tc.id})
    (when ?yield!
      (let [(ok? thrown) (pcall ?yield!)]
        (when (not ok?)
          (if (= thrown CANCEL-MARKER)
              (do (append-cancelled-tool-results! agent tool-calls i true)
                  (error CANCEL-MARKER))
              (error thrown)))))
    (if (. edit-conflicts i)
        (append-synthetic-tool-result! agent tc (. edit-conflicts i) false)
        (let [(ok? out-or-err) (pcall tools-mod.execute-call
                                  agent.tools tc (tool-context agent) ?yield!)]
          (if ok?
              (do
                (append-tool-output! agent tc out-or-err)
                (when ?yield!
                  (let [(yield-ok? thrown) (pcall ?yield!)]
                    (when (not yield-ok?)
                      (if (= thrown CANCEL-MARKER)
                          (do (append-cancelled-tool-results! agent tool-calls (+ i 1) false)
                              (error CANCEL-MARKER))
                          (error thrown))))))
              (= out-or-err CANCEL-MARKER)
              (do (append-cancelled-tool-results! agent tool-calls i true)
                  (error CANCEL-MARKER))
              (append-tool-failure! agent tc out-or-err true))))))

(fn batch-parallel-cap [agent tasks]
  ;; Mixed parallel-safe batches use the most conservative cap among their
  ;; tools. The subagent batch is homogeneous today, but this keeps future
  ;; opt-in tools from accidentally exceeding their own resource limits.
  (var cap nil)
  (each [_ task (ipairs tasks)]
    (let [tool (find-tool-record agent.tools task.tc.name)
          c (tool-parallel-cap tool)]
      (set cap (if cap (math.min cap c) c))))
  (or cap DEFAULT-PARALLEL-TOOL-CAP))

(fn run-parallel-tool-batch [agent tasks ?yield!]
  "Run a consecutive batch of explicitly parallel-safe tool calls. Results are
   appended after the batch in original order, regardless of completion order."
  (let [ctx (tool-context agent)
        cap (batch-parallel-cap agent tasks)
        n (length tasks)]
    (var next-index 1)
    (var active 0)
    (var completed 0)
    (var cancelled? false)

    (fn mark-done! [task]
      (when (not task.done?)
        (set task.done? true)
        (set active (- active 1))
        (set completed (+ completed 1))))

    (fn child-yield [task]
      (when task.cancel? (error CANCEL-MARKER))
      (coroutine.yield)
      (when task.cancel? (error CANCEL-MARKER)))

    (fn resume-task! [task]
      (when (and task.co (not task.done?))
        (let [(ok? out-or-err) (coroutine.resume task.co)]
          (when (or (not ok?) (= (coroutine.status task.co) :dead))
            (mark-done! task)
            (if ok?
                (set task.out out-or-err)
                (= out-or-err CANCEL-MARKER)
                (do (set task.cancelled? true)
                    (set cancelled? true))
                (set task.error out-or-err))))))

    (fn launch-task! [task]
      (set task.emitted? true)
      (emit agent {:type :tool-call
                   :name task.tc.name
                   :arguments task.tc.arguments
                   :id task.tc.id})
      (set task.co
           (coroutine.create
             (fn []
               (tools-mod.execute-call agent.tools task.tc ctx
                                       #(child-yield task)))))
      (set active (+ active 1))
      (resume-task! task))

    (fn cancel-active! []
      ;; Cancellation asks every live child to throw from its next yield, then
      ;; resumes once so cleanup runs inside the child coroutine. Parallel-safe
      ;; tools must release resources synchronously after observing cancel; the
      ;; first-party subagent/process path does so with non-yielding SIGTERM /
      ;; SIGKILL cleanup. With cap-sized batches this can briefly block the TUI
      ;; while child process groups are reaped, but avoids leaked children.
      (each [_ task (ipairs tasks)]
        (when (and task.co (not task.done?))
          (set task.cancel? true)))
      (each [_ task (ipairs tasks)]
        (when (and task.co (not task.done?))
          (let [(ok? out-or-err) (coroutine.resume task.co)]
            (mark-done! task)
            (if (and ok? out-or-err)
                (set task.out out-or-err)
                (do (set task.cancelled? true)
                    (when (not ok?) (set task.error out-or-err))))))))

    (while (and (< completed n) (not cancelled?))
      (while (and (< active cap) (<= next-index n) (not cancelled?))
        (launch-task! (. tasks next-index))
        (set next-index (+ next-index 1)))
      (when (and (< completed n) (not cancelled?))
        (each [_ task (ipairs tasks)]
          (resume-task! task))
        (when (and (< completed n) (not cancelled?))
          (let [(ok? thrown) (pcall ?yield!)]
            (when (not ok?)
              (if (= thrown CANCEL-MARKER)
                  (set cancelled? true)
                  (error thrown)))))))

    (when cancelled?
      (cancel-active!))

    (each [_ task (ipairs tasks)]
      (if task.out
          (append-tool-output! agent task.tc task.out)
          (or cancelled? task.cancelled?)
          (append-synthetic-tool-result!
            agent task.tc "[cancelled] tool call cancelled before completion"
            (not task.emitted?))
          task.error
          (append-tool-failure! agent task.tc task.error task.emitted?)
          (append-tool-failure! agent task.tc "tool returned nil" task.emitted?)))
    (not cancelled?)))

(fn run-tool-calls [agent tool-calls ?yield!]
  "Execute the tool-call blocks of the latest assistant turn; append a
   canonical ToolResultMessage for each. Pass ?yield! for cooperative mode:
   yields between each tool and forwards yield-fn into the tool's
   `:execute` so a coop-aware tool can yield while waiting on its own I/O.
   Explicitly parallel-safe tools may run concurrently in capped batches;
   all other tools remain serial. Tool failures and cancellations always
   append matching tool-result messages before the loop unwinds, so resumed
   history remains provider-valid."
  (let [edit-conflicts (same-turn-edit-conflicts tool-calls)]
    (var i 1)
    (while (<= i (length tool-calls))
      (let [tc (. tool-calls i)]
        (if (parallel-safe-tool-call? agent tc edit-conflicts i ?yield!)
            (let [tasks []]
              (var j i)
              (while (and (<= j (length tool-calls))
                          (parallel-safe-tool-call? agent (. tool-calls j)
                                                    edit-conflicts j ?yield!))
                (table.insert tasks {:tc (. tool-calls j)})
                (set j (+ j 1)))
              (let [completed? (run-parallel-tool-batch agent tasks ?yield!)]
                (when (not completed?)
                  (append-cancelled-tool-results! agent tool-calls j false)
                  (error CANCEL-MARKER)))
              (set i j))
            (do
              (run-serial-tool-call agent tool-calls i edit-conflicts ?yield!)
              (set i (+ i 1))))))))

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
        (= ev.type :provider-retry)
        (emit agent ev)
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
      (values (llm.complete agent.provider-name agent.model context opts) nil)
      (let [stream-state {:visible? false}
            on-stream (make-provider-stream-handler agent stream-state)
            asst (llm.complete agent.provider-name agent.model
                               context opts on-stream ?yield!)]
        (values asst stream-state))))

;; @doc fen.core.agent.complete-messages
;; kind: function
;; signature: (complete-messages agent messages ?model ?opts ?on-event ?yield-fn) -> AssistantMessage
;; summary: Run one provider completion using an agent's provider configuration, explicit canonical messages, and no tools.
;; tags: agent llm extensions
(fn complete-messages [agent messages ?model ?opts ?on-event ?yield-fn]
  "Run one provider completion against explicit canonical messages and no
   tools. This is an internal helper for first-party extensions that need a
   one-shot model call without adding the helper to the public extension api."
  (let [opts (build-options agent)
        context {:system-prompt agent.system-prompt
                 :messages (agent.convert-to-llm (or messages []))
                 :tools []}]
    (each [k v (pairs (or ?opts {}))]
      (tset opts k v))
    (llm.complete agent.provider-name (or ?model agent.model) context
                  opts ?on-event ?yield-fn)))

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
          ;; Wall-clock around the provider round-trip only (monotonic delta, so
          ;; no epoch resolution needed). Persisted into usage so per-turn
          ;; latency is measurable in the transcript and /status.
          t0 (process.monotonic-ms)
          (asst stream-state) (complete-once agent context opts ?yield!)
          streamed? (and stream-state stream-state.visible?)]
      (when asst.usage
        (set asst.usage.latency-ms (- (process.monotonic-ms) t0)))
      (emit agent {:type :llm-end :usage asst.usage})
      (append-message! agent asst)
      (when ?yield! (?yield!))
      (if (= asst.stop-reason :error)
          (let [err-text (tostring (or asst.error-message "unknown"))]
            (emit agent {:type :error :error err-text})
            (set final (.. "[error] " err-text))
            (set done? true))
          (= asst.stop-reason :tool-use)
          (do (if streamed?
                  (finish-stream-display agent stream-state false)
                  (emit-assistant-display agent asst false))
              (run-tool-calls agent (assistant-tool-calls asst) ?yield!))
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
      {:api agent.provider-name
       :provider :agent
       :model agent.model
       :content []
       :stop-reason :aborted})))

;; @doc fen.core.agent.step
;; kind: function
;; signature: (step agent user-msg ?cancel-fn) -> string
;; summary: Run one user turn. Appends a UserMessage, then iterates provider-call -> tool-execution until a non-tool stop reason or the safety cap. Cooperative yields when called inside a coroutine; ?cancel-fn polled at every yield.
;; tags: agent loop step
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
    (let [(ok? result) (xpcall #(step-loop agent yield!)
                               #(if (= $1 CANCEL-MARKER)
                                    $1
                                    (debug.traceback (tostring $1) 2)))]
      (if (and coop? (not ok?) (= result CANCEL-MARKER))
          (do (append-aborted-assistant! agent)
              (emit agent {:type :cancelled})
              "[cancelled]")
          (not ok?)
          (error result)
          result))))

{: make-agent : step : SAFETY-CAP : complete-messages}
