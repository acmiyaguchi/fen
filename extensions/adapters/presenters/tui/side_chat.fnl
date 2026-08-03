;; Ephemeral side-agent conversations hosted by :side-chat workspaces.
;;
;; The workspace record owns all mutable conversation state so it survives a
;; behavior reload and disappears with the tab.  Turns reuse the normal agent
;; constructor, turn-submit helper, cooperative agent.step loop, canonical TUI
;; ingestion, and provider streaming path; only session persistence and the
;; parent event bus are intentionally omitted.

(local text (require :fen.util.text))
(local workspaces (require :fen.extensions.tui.workspaces))

(local M {})
(local WORKSPACE-ID :btw)
(local READ-ONLY-TOOLS "read,grep,find,ls")

(fn copy-table [source]
  (let [out {}]
    (each [k v (pairs (or source {}))]
      (tset out k v))
    out))

(fn add-usage! [totals usage]
  (when (= (type usage) :table)
    (each [_ key (ipairs [:input :output :cache-read :cache-write :reasoning
                          :total-tokens])]
      (let [value (. usage key)]
        (when (= (type value) :number)
          (tset totals key (+ (or (. totals key) 0) value))))))
  (when (and (not totals.total-tokens)
             (or totals.input totals.output))
    (set totals.total-tokens (+ (or totals.input 0) (or totals.output 0)))))

(fn side-opts [runtime]
  "Clone the current run options and force an isolated read-only tool policy."
  (let [opts (copy-table runtime.opts)]
    ;; runtime.opts is updated by /model and remains the provider resolver's
    ;; canonical input; agent.provider-name may instead name a lower-level API
    ;; adapter such as :openai-responses and must not replace it here.
    (set opts.tools READ-ONLY-TOOLS)
    (set opts.denied-tools nil)
    (set opts.no-tools? false)
    (set opts.active-tool-names {})
    (set opts.pinned-tools [])
    opts))

(fn M.on-event! [id ev]
  "Ingest a side-agent event into only its workspace."
  (let [ws (workspaces.find id)]
    (when (and ws (= ws.kind :side-chat) ws.side)
      (when (= ev.type :llm-end)
        (add-usage! ws.usage ev.usage))
      ;; Main-session lifecycle plumbing consumes this event without rendering
      ;; it.  Side chats have no session flush subscriber, so omit it directly.
      (when (not= ev.type :message-appended)
        (workspaces.append-to! id ev)))))

(fn start! [ws line]
  (if (not (?. ws :side :agent))
      {:ok false :error "side agent is unavailable"}
      (let [submit (?. ws :side :runtime :submit-agent-turn!)
            result (if submit
                       (submit ws.side line {:emit-user? true}
                               (fn [ev] (M.on-event! ws.id ev)))
                       {:ok false :error "side turn submitter is unavailable"})]
        (when result.started
          (set ws.status :running)
          (workspaces.refresh! ws))
        result)))

(fn M.submit! [ws line ?opts]
  "Submit only to WS's private agent, optionally queueing an initial command."
  (let [value (tostring (or line ""))
        opts (or ?opts {})]
    (if (= value "")
        {:ok false :error "cannot submit an empty side turn"}
        (and (?. ws :side :busy?) opts.queue?)
        (do (table.insert ws.side.pending value)
            {:ok true :queued true})
        (?. ws :side :busy?)
        {:ok false :error "side agent is busy"}
        (start! ws value))))

(fn make-side! [runtime]
  (let [ws (workspaces.create!
             {:id WORKSPACE-ID
              :kind :side-chat
              :title "btw"
              :source {:kind :ephemeral-side-chat}
              :status :idle
              :provider (?. runtime :agent :provider-name)
              :model (?. runtime :agent :model)
              :usage {}
              :activity-count 0
              :dirty? false
              :side {:agent nil :runtime runtime
                     :busy? false :turn nil :turn-id 0
                     :turn-result nil :turn-error nil
                     :cancel-requested? false :pending []}})
        opts (side-opts runtime)
        (ok? agent-or-error)
        (pcall runtime.make-agent-from-opts
               opts
               (fn [ev] (M.on-event! WORKSPACE-ID ev))
               {})]
    (if ok?
        (do (set ws.side.agent agent-or-error)
            (set ws.agent agent-or-error)
            ;; Construction must always begin with a blank conversation even
            ;; when the parent has a long persisted transcript.
            (set ws.side.agent.messages [])
            (set ws.provider ws.side.agent.provider-name)
            (set ws.model ws.side.agent.model))
        (do (set ws.status :error)
            (workspaces.append-to!
              ws.id {:type :error
                     :error (.. "could not create side agent: "
                                (text.first-line agent-or-error))})))
    (workspaces.refresh! ws)
    ws))

(fn M.open! [runtime ?initial]
  "Open or focus the singleton btw workspace and optionally submit a turn."
  (let [ws (or (workspaces.find WORKSPACE-ID)
               (make-side! runtime))
        initial (text.trim (tostring (or ?initial "")))]
    (workspaces.activate! ws.id)
    (when (not= initial "")
      (let [result (M.submit! ws initial {:queue? true})]
        (when (not result.ok)
          (workspaces.append-to! ws.id
                                 {:type :error :error result.error}))))
    ws))

(fn finish-turn! [ws ok? value]
  (if ok?
      (set ws.side.turn-result value)
      (do (set ws.side.turn-error value)
          (workspaces.append-to!
            ws.id {:type :error
                   :error (.. "side agent task: " (text.first-line value))
                   :traceback (debug.traceback ws.side.turn (tostring value))})))
  (set ws.side.busy? false)
  (set ws.side.turn nil)
  (set ws.side.cancel-requested? false)
  (set ws.status :idle)
  (workspaces.refresh! ws))

(fn tick-one! [ws]
  (when (and ws.side ws.side.turn)
    (let [(ok? value) (coroutine.resume ws.side.turn)]
      (when (or (not ok?) (= (coroutine.status ws.side.turn) :dead))
        (finish-turn! ws ok? value))))
  (when (and ws.side (not ws.side.busy?) (> (length ws.side.pending) 0))
    (let [line (table.remove ws.side.pending 1)
          result (start! ws line)]
      (when (not result.ok)
        (workspaces.append-to! ws.id {:type :error :error result.error}))))
  ws)

(fn M.tick! []
  "Advance every live side turn once from the presenter's cooperative tick."
  (each [_ ws (ipairs (workspaces.list))]
    (when (= ws.kind :side-chat)
      (tick-one! ws))))

(fn M.busy? []
  (let [ws (workspaces.find WORKSPACE-ID)]
    (not (not (?. ws :side :busy?)))))

(fn last-assistant-text [agent]
  (var found nil)
  (let [messages (or (?. agent :messages) [])]
    (for [i (length messages) 1 -1]
      (let [message (. messages i)]
        (when (and (= found nil) (= message.role :assistant)
                   (not= message.stop-reason :error)
                   (not= message.stop-reason :aborted))
          (let [parts []]
            (each [_ block (ipairs (or message.content []))]
              (when (and (= block.type :text) (not= block.text ""))
                (table.insert parts block.text)))
            (let [reply (table.concat parts "")]
              (when (not= reply "")
                (set found reply))))))))
  found)

(fn M.use-last! [?ws]
  "Replace the main input draft with the side agent's last assistant reply."
  (let [ws (or ?ws (workspaces.active))]
    (if (not= (?. ws :kind) :side-chat)
        (values nil "/btw-use is available only in the btw tab")
        (let [reply (last-assistant-text (?. ws :side :agent))]
          (if (not reply)
              (values nil "the btw conversation has no assistant reply yet")
              (do (workspaces.with-main!
                    (fn []
                      (let [state (require :fen.extensions.tui.state)]
                        (set state.input-buf reply)
                        (set state.input-cursor (length reply))
                        (set state.history-pos 0)
                        (set state.history-draft ""))))
                  true))))))

(fn M.cancel! [ws]
  "Cooperatively stop and discard one side conversation before tab removal."
  (when (and ws ws.side)
    (set ws.side.cancel-requested? true)
    (when ws.side.turn
      ;; An unstarted turn first yields immediately before provider dispatch;
      ;; an in-flight turn is already parked in the cancellable yield wrapper.
      ;; Two bounded resumes therefore unwind either state without starting a
      ;; provider request after close.
      (for [_ 1 2]
        (when (and ws.side.turn
                   (not= (coroutine.status ws.side.turn) :dead))
          (pcall coroutine.resume ws.side.turn))))
    (set ws.side.turn nil)
    (set ws.side.busy? false)
    (set ws.side.pending [])
    (set ws.side.agent nil)
    (set ws.agent nil)
    (set ws.side nil)
    (set ws.status :closed)
    true))

(set M.WORKSPACE-ID WORKSPACE-ID)
(set M.READ-ONLY-TOOLS READ-ONLY-TOOLS)

M
