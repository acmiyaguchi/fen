;; Ephemeral side-agent conversations hosted by :side-chat workspaces.
;;
;; Workspace records are persistent presenter data: options, conversation
;; history, queue state, and display metadata.  Executable agents and turns
;; live in a process-local registry instead, so a /reload never leaves a
;; provider closure pinned in fen.extensions.tui.state.workspaces.

(local text (require :fen.util.text))
(local workspaces (require :fen.extensions.tui.workspaces))

(local M {})
(local WORKSPACE-ID :btw)
(local READ-ONLY-TOOLS "read,grep,find,ls")
(local CANCEL-RESUME-LIMIT 8)

;; Keep live resources outside the reload-excluded presenter state, but retain
;; them across replacement of this reloadable module.  The next module table
;; can therefore cancel/reap a coroutine created by the previous one.
(local registry (debug.getregistry))
(local REGISTRY-KEY "fen.extensions.tui.side-chat.runtime")
(when (= (. registry REGISTRY-KEY) nil)
  (tset registry REGISTRY-KEY {:live {} :reap [] :runtimes {}}))
(local volatile (. registry REGISTRY-KEY))
(when (= volatile.runtimes nil) (set volatile.runtimes {}))
;; Every module instance gets a distinct owner token.  A turn that outlives a
;; behavior reload is cooperatively cancelled rather than allowed to continue
;; executing old behavior indefinitely.
(local OWNER {})

(fn copy-data [value]
  (let [kind (type value)]
    (if (= kind :table)
        (let [out {}]
          (each [k v (pairs value)]
            (let [copied (copy-data v)]
              (when (and (not= copied nil)
                         (or (= (type k) :string)
                             (= (type k) :number)
                             (= (type k) :boolean)))
                (tset out k copied))))
          out)
        (or (= kind :string) (= kind :number) (= kind :boolean))
        value
        nil)))

(fn copy-table [source]
  (or (copy-data (or source {})) {}))

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

(fn safe-side-opts [source]
  "Clone options and force an isolated read-only tool policy."
  (let [opts (copy-table source)]
    ;; Keep only plain option data on the workspace; runtime callbacks stay
    ;; volatile.  Reapply this policy when migrating an older workspace too.
    (set opts.tools READ-ONLY-TOOLS)
    (set opts.denied-tools nil)
    (set opts.no-tools? false)
    (set opts.active-tool-names {})
    (set opts.pinned-tools [])
    opts))

(fn side-opts [runtime]
  (safe-side-opts (or runtime.opts {})))

(fn current-runtime []
  ;; The presenter context is the active process runtime, not workspace state.
  ;; Resolve it at call time so a reloaded side-chat module does not retain an
  ;; old run-state table in the workspace record.
  (let [(ok? tui-state) (pcall require :fen.extensions.tui.state)]
    (when (and ok? tui-state.presenter-ctx)
      tui-state.presenter-ctx.state)))

(fn live-entry [ws]
  (. volatile.live ws.id))

(fn runtime-handle [runtime]
  (when runtime
    (if runtime.factory
        runtime
        {:opts (copy-table runtime.opts)
         :factory runtime.make-agent-from-opts
         :provider (?. runtime :agent :provider-name)
         :model (?. runtime :agent :model)})))

(fn entry-for! [ws ?runtime]
  (let [existing (live-entry ws)
        runtime (runtime-handle
                  (or ?runtime (and existing existing.runtime)
                      (. volatile.runtimes ws.id) (current-runtime)))]
    (when runtime (tset volatile.runtimes ws.id runtime))
    (if (and existing (= existing.owner OWNER))
        (do (when runtime (set existing.runtime runtime)) existing)
        (and existing existing.busy?)
        ;; An old module still owns a live turn.  Mark it for cooperative
        ;; cancellation; the reaper will keep its coroutine reachable.
        (do (set existing.cancel-requested? true)
            (when ws.side (set ws.side.cancel-requested? true))
            existing)
        (let [entry {:owner OWNER :runtime runtime :agent nil :turn nil
                     :busy? false :turn-id 0 :turn-result nil
                     :turn-error nil :cancel-requested? false
                     :discard? false}]
          (tset volatile.live ws.id entry)
          entry))))

(fn append-construction-error! [ws error]
  (set ws.status :error)
  (let [detail (text.first-line error)
        message (.. "could not create side agent for "
                    (tostring (or ws.model "the configured model"))
                    "; check provider credentials/model and retry /btw"
                    (if (and detail (not= detail "")) (.. ": " detail) ""))]
    (workspaces.append-to! ws.id {:type :error :error message})
    message))

(fn copy-history! [ws agent]
  ;; Agent messages are canonical data.  Keep the persistent history table
  ;; shared with the live agent so a reload during a turn cannot lose messages.
  (when (and ws.side agent.messages
             (not (rawequal ws.side.history agent.messages)))
    (set ws.side.history agent.messages)))

(fn make-agent! [ws entry]
  (if (not entry.runtime)
      (values nil "side agent runtime is unavailable; retry /btw")
      (let [opts (safe-side-opts (or ws.side.opts {}))
            factory entry.runtime.factory]
        (set ws.side.opts opts)
        (if (not factory)
            (values nil "side agent factory is unavailable; retry /btw")
            (let [(ok? agent-or-error)
                  (pcall factory
                         opts
                         (fn [ev] (M.on-event! WORKSPACE-ID ev))
                         {})]
              (if (and ok? agent-or-error)
                  (do
                    ;; A factory may return a fresh messages array.  Replace it
                    ;; with the persistent data history before the turn starts.
                    (set agent-or-error.messages (or ws.side.history []))
                    (values agent-or-error nil))
                  (values nil (tostring agent-or-error))))))))

(fn ensure-agent! [ws entry]
  (if entry.agent
      true
      (let [(agent error) (make-agent! ws entry)]
        (if agent
            (do
              (set entry.agent agent)
              (set ws.provider agent.provider-name)
              (set ws.model agent.model)
              (set ws.status :idle)
              (workspaces.refresh! ws)
              true)
            (do
              (append-construction-error! ws error)
              false)))))

(fn M.on-event! [id ev]
  "Ingest a side-agent event into only its workspace."
  (let [ws (workspaces.find id)]
    (when (and ws (= ws.kind :side-chat) ws.side)
      ;; Message history is data owned by the workspace.  This fallback also
      ;; handles factories that do not share the history table themselves.
      (when (and (= ev.type :message-appended) ev.message ev.index
                 (> ev.index (length (or ws.side.history []))))
        (tset ws.side.history ev.index ev.message))
      (when (= ev.type :llm-end)
        (add-usage! ws.usage ev.usage))
      ;; Main-session lifecycle plumbing consumes this event without rendering
      ;; it.  Side chats have no session flush subscriber, so omit it directly.
      (when (not= ev.type :message-appended)
        (workspaces.append-to! id ev)))))

(fn submit-agent-turn! [entry line emit]
  ;; This is intentionally resolved for every turn.  The old runtime state may
  ;; still exist for provider construction, but the turn implementation always
  ;; comes from the current module table after /reload.
  (let [(ok? interactive) (pcall require :fen.interactive)]
    (if (and ok? interactive.submit-agent-turn!)
        (interactive.submit-agent-turn! entry line {:emit-user? true} emit)
        {:ok false :error "side turn submitter is unavailable; retry /btw"})))

(fn start! [ws line]
  (let [entry (entry-for! ws)]
    (if (and entry entry.busy?)
        {:ok false :error "side agent is busy"}
        (not (ensure-agent! ws entry))
        {:ok false
         :error "side agent could not be constructed; check credentials/model and retry /btw"}
        (let [result (submit-agent-turn!
                       entry line
                       (fn [ev] (M.on-event! WORKSPACE-ID ev)))]
          (when result.started
            (set ws.side.busy? true)
            (set ws.status :running)
            (workspaces.refresh! ws))
          result))))

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

(fn new-side-data [runtime]
  {:opts (side-opts runtime)
   :history []
   :busy? false
   :turn-id 0
   :turn-result nil
   :turn-error nil
   :cancel-requested? false
   :pending []})

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
              :side (new-side-data runtime)})]
    (entry-for! ws runtime)
    ws))

(fn M.open! [runtime ?initial]
  "Open or focus the singleton btw workspace and optionally submit a turn."
  (let [ws (or (workspaces.find WORKSPACE-ID)
               (make-side! runtime))
        entry (entry-for! ws runtime)
        initial (text.trim (tostring (or ?initial "")))]
    ;; Refresh the volatile runtime handle and retry construction on every
    ;; focus.  A failed provider must not create a dead singleton tab.
    (when runtime
      (set entry.runtime (runtime-handle runtime))
      (when (and ws.side (not ws.side.busy?))
        (set ws.side.opts (side-opts runtime))))
    (when (and ws.side (not ws.side.busy?))
      (ensure-agent! ws entry))
    (workspaces.activate! ws.id)
    (when (not= initial "")
      (let [result (M.submit! ws initial {:queue? true})]
        (when (and (not result.ok) (not result.queued))
          (workspaces.append-to! ws.id
                                 {:type :error :error result.error}))))
    ws))

(fn finish-turn! [ws entry ok? value]
  (when entry.agent (copy-history! ws entry.agent))
  (if ok?
      (set ws.side.turn-result value)
      (do (set ws.side.turn-error value)
          (when (and ws.side.turn-error (not entry.discard?))
            (workspaces.append-to!
              ws.id {:type :error
                     :error (.. "side agent task: " (text.first-line value))
                     :traceback (debug.traceback entry.turn (tostring value))}))))
  (set entry.busy? false)
  (set entry.turn nil)
  (set entry.cancel-requested? false)
  (when ws.side
    (set ws.side.busy? false)
    (set ws.side.cancel-requested? false)
    (set ws.status (if entry.discard? :closed :idle))
    (when entry.discard?
      (set ws.side nil)
      (set ws.agent nil)))
  (tset volatile.live ws.id nil)
  (when entry.discard? (tset volatile.runtimes ws.id nil))
  (when (not entry.discard?) (workspaces.refresh! ws)))

(fn resume-entry! [item limit]
  (let [entry item.entry
        turn entry.turn]
    (if (or (not turn) (= (coroutine.status turn) :dead))
        true
        (do
          (let [(ok? value) (pcall coroutine.resume turn)]
            (when (or (not ok?) (= (coroutine.status turn) :dead))
              (set item.done? true)
              (set item.ok? ok?)
              (set item.value value)))
          (var resumes 1)
          (while (and (not item.done?) (< resumes limit))
            (let [(ok? value) (pcall coroutine.resume turn)]
              (when (or (not ok?) (= (coroutine.status turn) :dead))
                (set item.done? true)
                (set item.ok? ok?)
                (set item.value value)))
            (set resumes (+ resumes 1)))
          item.done?))))

(fn reap-entry! [item]
  (let [ws item.ws
        entry item.entry]
    (when (resume-entry! item CANCEL-RESUME-LIMIT)
      ;; A cancelled turn is intentionally finalized only after the coroutine
      ;; is dead.  Until then ws.side and the entry remain reachable.
      (when (and ws ws.side (= (live-entry ws) entry))
        (finish-turn! ws entry item.ok? item.value))
      true)))

(fn park-for-reap! [ws entry]
  (var found? false)
  (each [_ item (ipairs volatile.reap)]
    (when (= item.entry entry) (set found? true)))
  (when (not found?)
    (table.insert volatile.reap {:ws ws :entry entry :done? false
                                  :ok? true :value nil})))

(fn tick-one! [ws]
  (let [entry (live-entry ws)]
    (when (and entry (= entry.owner OWNER) entry.turn)
      (let [item {:ws ws :entry entry :done? false :ok? true :value nil}]
        (when (resume-entry! item 1)
          (finish-turn! ws entry item.ok? item.value))))
    ;; A fresh module instance asks an old in-flight turn to unwind.  It is
    ;; then handled by the same bounded reap path as Ctrl-W.
    (when (and entry (not= entry.owner OWNER) entry.busy?)
      (set entry.cancel-requested? true)
      (when ws.side (set ws.side.cancel-requested? true))
      (park-for-reap! ws entry))
    (when (and ws.side (not ws.side.busy?) (> (length ws.side.pending) 0))
      (let [line (table.remove ws.side.pending 1)
            result (start! ws line)]
        (when (not result.ok)
          (workspaces.append-to! ws.id {:type :error :error result.error}))))
    ws))

(fn M.tick! []
  "Advance live side turns and drain cancelled turns without blocking the UI."
  (each [_ ws (ipairs (workspaces.list))]
    (when (= ws.kind :side-chat)
      (tick-one! ws)))
  (let [kept []]
    (each [_ item (ipairs volatile.reap)]
      (if (reap-entry! item)
          nil
          (table.insert kept item)))
    (set volatile.reap kept)))

(fn M.reset! []
  "Clear volatile side-chat resources between isolated presenter tests."
  (each [id entry (pairs volatile.live)]
    (set entry.cancel-requested? true)
    (when entry.turn
      (var attempts 0)
      (while (and (< attempts 64)
                  (not= (coroutine.status entry.turn) :dead))
        (pcall coroutine.resume entry.turn)
        (set attempts (+ attempts 1))))
    (tset volatile.live id nil))
  (set volatile.reap [])
  (set volatile.runtimes {})
  true)

(fn M.busy? []
  (let [ws (workspaces.find WORKSPACE-ID)]
    (not (not (and ws ws.side ws.side.busy?)))))

(fn last-assistant-text [ws]
  (var found nil)
  (let [messages (or (?. ws :side :history) [])]
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
        (let [reply (last-assistant-text ws)]
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

(fn M.request-cancel! [ws]
  "Request cooperative cancellation without discarding the side conversation."
  (when (and ws ws.side ws.side.busy?)
    (set ws.side.cancel-requested? true)
    (let [entry (live-entry ws)]
      (when entry (set entry.cancel-requested? true)))
    (workspaces.refresh! ws)
    true))

(fn M.cancel! [ws]
  "Cancel one side conversation, reaping its coroutine before tab removal."
  (when (and ws ws.side)
    ;; Reuse the #417 cooperative request path before applying the bounded
    ;; close-time drain below.
    (M.request-cancel! ws)
    (set ws.side.pending [])
    (set ws.side.cancel-requested? true)
    (let [entry (live-entry ws)]
      (if (and entry entry.turn)
          (do
            (set entry.discard? true)
            (set entry.cancel-requested? true)
            ;; Resume several times now, then keep the entry on the reap list
            ;; if provider/tool cleanup needs more cooperative turns.
            (let [item {:ws ws :entry entry :done? false
                        :ok? true :value nil}]
              (if (resume-entry! item CANCEL-RESUME-LIMIT)
                  (finish-turn! ws entry item.ok? item.value)
                  (do (set ws.status :closed)
                      (park-for-reap! ws entry)))))
          (do
            (tset volatile.live ws.id nil)
            (tset volatile.runtimes ws.id nil)
            (set ws.side nil)
            (set ws.agent nil)
            (set ws.status :closed)))
    true)))

(set M.WORKSPACE-ID WORKSPACE-ID)
(set M.READ-ONLY-TOOLS READ-ONLY-TOOLS)

M
