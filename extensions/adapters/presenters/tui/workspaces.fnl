;; TUI presenter workspaces. Persistent state remains in tui.state; this
;; reloadable module swaps the existing transcript/view fields at workspace
;; boundaries so legacy render/input and canonical ingestion can keep using
;; state.* directly.

(local state (require :fen.extensions.tui.state))
(local redraw (require :fen.extensions.tui.redraw))

(local M {})

(local VIEW-KEYS [:transcript :streaming-assistant-rows :transcript-layout-cache
                  :scroll-offset :new-content-below? :last-user-jump-index
                  :selection :selection-paint])

(fn copy-view! [from to]
  (each [_ key (ipairs VIEW-KEYS)]
    (tset to key (. from key)))
  to)

(fn main-workspace []
  {:id :main-session :kind :main-session :title "main"
   :capabilities {:edit true :submit true}
   :activity-count 0 :dirty? false})

(fn find-workspace [id]
  (var found nil)
  (each [_ ws (ipairs (or state.workspaces []))]
    (when (= ws.id id) (set found ws)))
  found)

(fn M.ensure! []
  (when (= state.workspaces nil) (set state.workspaces []))
  (when (= state.closed-subagent-workspaces nil)
    (set state.closed-subagent-workspaces {}))
  (when (= state.active-workspace-id nil) (set state.active-workspace-id :main-session))
  (when (= (length state.workspaces) 0)
    (let [main (main-workspace)]
      (copy-view! state main)
      (table.insert state.workspaces main)))
  (when (not (find-workspace state.active-workspace-id))
    (set state.active-workspace-id :main-session))
  (let [active (find-workspace state.active-workspace-id)]
    ;; Old state tables and early test fixtures may lack one of the new fields.
    (each [_ key (ipairs VIEW-KEYS)]
      (when (= (. active key) nil)
        (tset active key (. state key))))
    active))

(fn M.active []
  (M.ensure!))

(fn M.allows? [capability]
  "Return whether the active workspace grants CAPABILITY.

   Legacy main workspaces remain interactive across /reload; every other
   workspace defaults closed so a new projection cannot accidentally mutate
   the main draft."
  (let [ws (M.active)
        capabilities ws.capabilities]
    (if capabilities
        (not (not (. capabilities capability)))
        (= ws.kind :main-session))))

(fn M.capture-active! []
  (let [active (M.active)]
    (copy-view! state active)
    active))

(fn M.activate! [id]
  (let [current (M.capture-active!)
        next (find-workspace id)]
    (when next
      (set state.active-workspace-id id)
      (copy-view! next state)
      (set next.activity-count 0)
      (set next.dirty? false)
      (redraw.invalidate-full!))
    next))

(fn M.with-main! [f]
  "Run F against the main transcript without changing the tab being viewed."
  (let [shown (M.ensure!)]
    (if (= shown.id :main-session)
        (f)
        (do
          (M.capture-active!)
          (let [main (find-workspace :main-session)]
            (copy-view! main state)
            ;; Ingestion normally handles its own failures, but this boundary
            ;; must restore the visible tab even if a future caller raises.
            (let [(ok? result) (xpcall f debug.traceback)]
              (copy-view! state main)
              (copy-view! shown state)
              (if ok? result (error result))))))))

(fn M.close! [id]
  "Close a visible subagent workspace without deleting the retained run.

   Closed ids are remembered so sync-subagents! does not recreate the tab on
   the next child event; /subagents remains the durable inspection surface."
  (let [ws (find-workspace id)]
    (when (and ws (= ws.kind :subagent-job))
      (M.capture-active!)
      (when (= state.closed-subagent-workspaces nil)
        (set state.closed-subagent-workspaces {}))
      (tset state.closed-subagent-workspaces id true)
      (when (= state.active-workspace-id id)
        (M.activate! :main-session))
      (let [kept []]
        (each [_ candidate (ipairs state.workspaces)]
          (when (not= candidate.id id)
            (table.insert kept candidate)))
        (set state.workspaces kept))
      (redraw.invalidate-full!)
      true)))

(fn M.next! [delta]
  (M.capture-active!)
  (let [tabs state.workspaces
        n (length tabs)]
    (when (> n 0)
      (var current 1)
      (each [i ws (ipairs tabs)]
        (when (= ws.id state.active-workspace-id) (set current i)))
      (let [target (+ (% (+ (- current 1) delta) n) 1)]
        (M.activate! (. tabs target :id))))))

(local CANONICAL-EVENTS
  {:user true :steering-injected true :follow-up-injected true
   :tool-call true :tool-result true :assistant-text true
   :assistant-thinking true :assistant-text-delta true
   :assistant-thinking-delta true :assistant-stream-end true
   :error true :cancelled true})

(fn info-event [ev]
  {:type :info
   :text (let [summary (or ev.summary ev.error "")]
           (.. (tostring (or ev.type :event))
               (if (= (tostring summary) "") "" (.. ": " summary))))})

(fn display-event [ev]
  (if (and (or (= ev.type :assistant-text)
               (= ev.type :assistant-thinking))
           (= ev.text nil))
      ;; Runs recorded before canonical transport have only a short summary.
      ;; Keep that diagnostic visible, but do not manufacture an empty
      ;; assistant row that suppresses the authoritative final-result fallback.
      (info-event ev)
      (and (or (= ev.type :assistant-text-delta)
               (= ev.type :assistant-thinking-delta))
           (= ev.delta nil))
      (info-event ev)
      (. CANONICAL-EVENTS ev.type)
      ev
      (info-event ev)))

(fn ingest-into! [ws ev]
  "Run canonical ingestion against WS without changing the displayed tab."
  (let [shown (M.active)
        ingest (require :fen.extensions.tui.ingest)]
    (if (= shown.id ws.id)
        (ingest.append-event ev {:transcript-only? true})
        (do
          (copy-view! state shown)
          (copy-view! ws state)
          (let [(ok? err) (xpcall #(ingest.append-event ev {:transcript-only? true})
                                  debug.traceback)]
            (copy-view! state ws)
            (copy-view! shown state)
            (when (not ok?) (error err)))))))

(fn run-title [run]
  (.. (or run.agent "subagent") " " run.id))

(fn workspace-for-run [run]
  (find-workspace (.. "subagent:" run.id)))

(fn make-run-workspace [run]
  {:id (.. "subagent:" run.id)
   :kind :subagent-job
   :title (run-title run)
   :job-id run.id
   :cwd run.cwd
   :status run.status
   :capabilities {:edit false :submit false}
   :activity-count 0
   :dirty? false
   :transcript []
   :streaming-assistant-rows {}
   :transcript-layout-cache nil
   :scroll-offset 0
   :new-content-below? false
   :last-user-jump-index nil
   :selection nil
   :selection-paint nil
   :source-event-seq 0
   :header-added? false
   :result-added? false
   :subagent-seq run.seq
   :started-at run.started-at
   :provider nil
   :model nil
   :usage nil})

(fn copy-table [tbl]
  (when tbl
    (let [out {}]
      (each [k v (pairs tbl)]
        (tset out k v))
      out)))

(fn num [v]
  (and (= (type v) :number) v))

(fn usage-total [usage]
  (when usage
    (or (num (. usage :total-tokens))
        (and (or (num usage.input) (num usage.output))
             (+ (or (num usage.input) 0) (or (num usage.output) 0))))))

(fn add-usage! [totals usage]
  (when (= (type usage) :table)
    (each [_ k (ipairs [:input :output :cache-read :cache-write :reasoning
                        :total-tokens])]
      (let [v (num (. usage k))]
        (when v (tset totals k (+ (or (. totals k) 0) v)))))))

(fn usage-from-events [events]
  (let [totals {}]
    (each [_ ev (ipairs (or events []))]
      (when (= ev.type :llm-end)
        (add-usage! totals ev.usage)))
    (when (and (not (. totals :total-tokens))
               (or totals.input totals.output))
      (set totals.total-tokens (+ (or totals.input 0) (or totals.output 0))))
    (when (next totals) totals)))

(fn run-usage [run]
  (or (copy-table (?. run :details :usage))
      (copy-table (?. run :usage-acc :totals))
      (usage-from-events run.events)))

(fn run-provider-model [run]
  (var provider (?. run :details :provider))
  (var model (?. run :details :model))
  (each [_ ev (ipairs (or run.events []))]
    (when ev.provider (set provider ev.provider))
    (when ev.model (set model ev.model)))
  (values provider model))

(fn project-run! [ws run]
  ;; Upgrade tabs created by the pre-canonical projector in place on /reload.
  (when (= ws.source-event-seq nil)
    (set ws.transcript [])
    (set ws.streaming-assistant-rows {})
    (set ws.transcript-layout-cache nil)
    (set ws.source-event-seq 0)
    (set ws.header-added? false)
    (set ws.result-added? false)
    (when (= state.active-workspace-id ws.id)
      (copy-view! ws state)))
  (let [events (or run.events [])
        count (or run.event-count (length events))
        (provider model) (run-provider-model run)
        usage (run-usage run)
        status-changed? (not= ws.status run.status)
        metadata-changed? (or (not= ws.provider provider)
                              (not= ws.model model)
                              (not= (usage-total ws.usage) (usage-total usage)))]
    (var changed? false)
    (var old-seq (or ws.source-event-seq 0))
    (when (not ws.header-added?)
      (ingest-into! ws {:type :info
                        :text (.. "subagent " run.id " — " (or run.cwd ""))})
      (set ws.header-added? true)
      (set changed? true))
    (let [first-seq (+ (- count (length events)) 1)]
      (when (< old-seq (- first-seq 1))
        (ingest-into! ws {:type :info
                          :text (.. "[" (- (- first-seq 1) old-seq)
                                    " earlier child events omitted by retention limit]")})
        (set old-seq (- first-seq 1))
        (set changed? true))
      (each [i ev (ipairs events)]
        (let [seq (or ev.transport-seq (+ first-seq (- i 1)))]
          (when (> seq old-seq)
            (ingest-into! ws (display-event ev))
            (set ws.source-event-seq seq)
            (set old-seq seq)
            (set changed? true)))))
    (when (and run.result (not ws.result-added?))
      (var assistant-seen? false)
      (each [_ ev (ipairs events)]
        (when (or (and (= ev.type :assistant-text) (not= ev.text nil))
                  (and (= ev.type :assistant-text-delta) (not= ev.delta nil)))
          (set assistant-seen? true)))
      (when (not assistant-seen?)
        (ingest-into! ws {:type :assistant-text :text run.result :final? true}))
      (set ws.result-added? true)
      (set changed? true))
    (set ws.subagent-seq run.seq)
    (set ws.started-at run.started-at)
    (set ws.provider provider)
    (set ws.model model)
    (set ws.usage usage)
    (when (or changed? status-changed? metadata-changed?)
      (set ws.status run.status)
      (if (= state.active-workspace-id ws.id)
          (copy-view! ws state)
          (do (set ws.activity-count (+ (or ws.activity-count 0) 1))
              (set ws.dirty? true)))
      (redraw.invalidate!))
    ws))

(fn subagent-before? [a b]
  (if (= a.kind :main-session) true
      (= b.kind :main-session) false
      (and (= a.kind :subagent-job) (= b.kind :subagent-job))
      (> (or a.subagent-seq 0) (or b.subagent-seq 0))
      (= a.kind :subagent-job) true
      (= b.kind :subagent-job) false
      (< (or a._workspace-order 0) (or b._workspace-order 0))))

(fn sort-workspaces! []
  (each [i ws (ipairs state.workspaces)]
    (set ws._workspace-order i))
  (table.sort state.workspaces subagent-before?)
  (each [_ ws (ipairs state.workspaces)]
    (set ws._workspace-order nil)))

(fn M.sync-subagents! []
  "Project bounded subagent event streams into read-only workspaces."
  (M.capture-active!)
  (when (= state.closed-subagent-workspaces nil)
    (set state.closed-subagent-workspaces {}))
  (let [(available? run-state) (pcall require :fen.extensions.subagent.state)]
    (when available?
      (let [retained {}]
        (each [_ run (ipairs (run-state.runs))]
          (let [id (.. "subagent:" run.id)]
            (tset retained id true)
            (when (not (. state.closed-subagent-workspaces id))
              (let [ws (or (workspace-for-run run) (make-run-workspace run))]
                (when (not (workspace-for-run run))
                  (table.insert state.workspaces ws))
                (project-run! ws run)))))
        ;; Run state keeps only a bounded history. Mirror that retention here so
        ;; completed job tabs cannot accumulate for the lifetime of a TUI. If a
        ;; cleared or closed run owns the visible tab, restore main before
        ;; removing it.
        (each [id _ (pairs state.closed-subagent-workspaces)]
          (when (not (. retained id))
            (tset state.closed-subagent-workspaces id nil)))
        (let [active (find-workspace state.active-workspace-id)]
          (when (and active (= active.kind :subagent-job)
                     (or (not (. retained active.id))
                         (. state.closed-subagent-workspaces active.id)))
            (M.activate! :main-session)))
        (let [kept []]
          (each [_ ws (ipairs state.workspaces)]
            (when (or (not= ws.kind :subagent-job)
                      (and (. retained ws.id)
                           (not (. state.closed-subagent-workspaces ws.id))))
              (table.insert kept ws)))
          (set state.workspaces kept)
          (sort-workspaces!)))))
  (M.active))

(fn M.list []
  (M.ensure!)
  state.workspaces)

M
