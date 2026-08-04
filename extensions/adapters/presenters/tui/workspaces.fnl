;; TUI presenter workspaces. Persistent identity remains in tui.state; this
;; reloadable module owns tab creation, switching, subagent projection, and the
;; compatibility projection through the existing flat state.* render fields.

(local state (require :fen.extensions.tui.state))
(local redraw (require :fen.extensions.tui.redraw))

(local M {})

;; This is the one dispatch point for workspace kinds.  New kinds add their
;; interaction policy here rather than teaching every TUI surface about them.
;; `status` is intentionally interpreted only by capabilities-for; input-mode
;; remains a compatibility projection derived from those capabilities.
(local KINDS
  {:main-session
   {:capabilities-for (fn [_ws _status]
                        {:edit true :input true :submit true :steer false})
    :closable? false
    :inherits-singleton? true
    :sort-rank 0
    :submit! (fn [_ws handlers line] (handlers.main line))}
   :side-chat
   {:capabilities-for (fn [_ws status]
                        {:edit true :input true
                         :submit (not= status :running) :steer false})
    :agent? true
    :closable? true
    :input-mode :side
    :sort-rank 1
    :status? true
    :submit! (fn [ws handlers line]
               ;; Side tabs interpret only their own paste-back command.
               ;; Every other slash-prefixed line remains ordinary side-agent
               ;; input and cannot reach parent-session command dispatch.
               (if (or (= line "/btw-use")
                       (string.match line "^/btw%-use%s+.*$"))
                   (handlers.command line)
                   (handlers.side ws line)))
    :close! (fn [ws]
              (let [(ok? side-chat)
                    (pcall require :fen.extensions.tui.side_chat)]
                (when ok? (side-chat.cancel! ws))))}
   :subagent-job
   {:capabilities-for (fn [_ws status]
                        (let [running? (= status :running)]
                          {:edit false :input running? :submit false :steer running?}))
    :agent? true
    :closable? true
    :sort-rank 2
    :status? true
    :subagent? true
    :submit! (fn [_ws handlers line] (handlers.steer line))}})

(set M.KINDS KINDS)

(fn M.kind-spec [ws]
  (. KINDS ws.kind))

(fn M.capabilities-for [ws]
  "Derive workspace authority from its kind and status in one place."
  (let [spec (M.kind-spec ws)
        policy (and spec spec.capabilities-for)]
    (if policy
        (policy ws ws.status)
        {:edit false :input false :submit false :steer false})))

(fn M.input-mode [ws]
  "Compatibility/display projection; capabilities remain authoritative."
  (let [spec (M.kind-spec ws)
        fixed-mode (and spec spec.input-mode)
        caps (M.capabilities-for ws)]
    (if fixed-mode fixed-mode
        caps.steer :steer
        caps.submit :main
        :readonly)))

(fn M.closable? [ws]
  (let [spec (M.kind-spec ws)]
    (and spec spec.closable?)))

(fn M.inherits-singleton? [ws]
  (let [spec (M.kind-spec ws)]
    (and spec spec.inherits-singleton?)))

(fn M.status? [ws]
  (let [spec (M.kind-spec ws)]
    (and spec spec.status?)))

(fn M.subagent? [ws]
  (let [spec (M.kind-spec ws)]
    (and spec spec.subagent?)))

(fn M.agent? [ws]
  (let [spec (M.kind-spec ws)]
    (and spec spec.agent?)))

(fn M.sort-rank [ws]
  (let [spec (M.kind-spec ws)]
    (or (and spec spec.sort-rank) 99)))

;; Workspace records own these fields directly. state.* temporarily projects the
;; active record so existing transcript, input, and Markdown/cache modules stay
;; shared rather than forked.
(local VIEW-KEYS [:transcript :streaming-assistant-rows :transcript-layout-cache
                  :scroll-offset :new-content-below? :last-user-jump-index
                  :selection :selection-paint
                  :input-buf :input-cursor
                  :paste-active? :paste-buffer :paste-counter :pastes
                  :history :history-pos :history-draft])

;; A module reload gets one migration sweep; ordinary active()/paint calls only
;; locate the current record. Replacing the registry (tests, reset, retention)
;; similarly earns one sweep rather than O(tabs × fields) writes per frame.
(var ensured-workspaces nil)
(var view-depth 0)

(fn fresh-value [key]
  (if (or (= key :transcript) (= key :history)) []
      (or (= key :streaming-assistant-rows) (= key :pastes)) {}
      (or (= key :transcript-layout-cache) (= key :selection)
          (= key :selection-paint) (= key :last-user-jump-index)) nil
      (or (= key :new-content-below?) (= key :paste-active?)) false
      (or (= key :scroll-offset) (= key :input-cursor)
          (= key :paste-counter) (= key :history-pos)) 0
      ""))

(fn ensure-view! [ws ?source]
  ;; Drop the short-lived duplicated representation from pre-fix /reloads.
  ;; The already-present flat values win and remain the only source of truth.
  (set ws.view-state nil)
  (each [_ key (ipairs VIEW-KEYS)]
    (when (= (. ws key) nil)
      (tset ws key
            (if (and ?source (not= (. ?source key) nil))
                (. ?source key)
                (fresh-value key)))))
  ws)

(fn save-view! [ws]
  (ensure-view! ws)
  (each [_ key (ipairs VIEW-KEYS)]
    (tset ws key (. state key)))
  ws)

(fn load-view! [ws]
  (ensure-view! ws)
  (each [_ key (ipairs VIEW-KEYS)]
    (tset state key (. ws key)))
  ws)

(fn ensure-metadata! [ws]
  (when (= ws.title nil) (set ws.title (tostring ws.id)))
  (when (= ws.activity-count nil) (set ws.activity-count 0))
  (when (= ws.dirty? nil) (set ws.dirty? false))
  ;; Keep these fields for old extensions/tests, but never read them as policy.
  ;; They are derived projections, refreshed whenever workspace metadata is.
  (set ws.capabilities (M.capabilities-for ws))
  (set ws.input-mode (M.input-mode ws))
  ws)

(fn main-workspace []
  (let [ws {:id :main-session :kind :main-session :title "main"
            :cwd nil :session-id nil :job-id nil
            :source {:kind :interactive-session}
            :activity-count 0 :dirty? false}]
    (ensure-view! ws state)))

(fn find-workspace [id]
  (var found nil)
  (each [_ ws (ipairs (or state.workspaces []))]
    (when (= ws.id id) (set found ws)))
  found)

(fn M.ensure! []
  (when (= state.workspaces nil) (set state.workspaces []))
  (when (= state.closed-subagent-workspaces nil)
    (set state.closed-subagent-workspaces {}))
  (when (= state.active-workspace-id nil)
    (set state.active-workspace-id :main-session))
  (when (= (length state.workspaces) 0)
    (table.insert state.workspaces (main-workspace)))
  (when (not (find-workspace state.active-workspace-id))
    (set state.active-workspace-id :main-session))
  (when (not (rawequal ensured-workspaces state.workspaces))
    (set ensured-workspaces state.workspaces)
    (each [_ ws (ipairs state.workspaces)]
      (ensure-metadata! ws)
      ;; Only main inherits the process's pre-tab singleton state during a
      ;; live upgrade. Other kinds start with isolated empty editor/view state.
      (ensure-view! ws (and (M.inherits-singleton? ws) state))))
  (find-workspace state.active-workspace-id))

(fn M.active []
  (M.ensure!))

(fn M.find [id]
  (M.ensure!)
  (find-workspace id))

(fn M.allows? [capability]
  "Return whether the active workspace grants CAPABILITY.

   Legacy main workspaces remain interactive across /reload; every other
   workspace defaults closed so a new tab kind cannot accidentally gain edit
   or submit authority."
  (let [capabilities (M.capabilities-for (M.active))]
    (not (not (. capabilities capability)))))

(fn M.accepts-input? []
  (M.allows? :input))

(fn with-view! [ws f]
  "Run F with WS projected into state, then restore the displayed workspace."
  (let [shown (M.ensure!)]
    (assert (= view-depth 0) "workspace view swap is not reentrant")
    (set view-depth 1)
    ;; Keep the depth guard live for the entire swap, including ensure/save/load.
    ;; A malformed workspace must not permanently poison future view swaps.
    (let [(ok? result)
          (xpcall
            #(do
               (when (not (rawequal shown ws))
                 (save-view! shown)
                 (load-view! ws))
               (let [(callback-ok? callback-result) (xpcall f debug.traceback)]
                 (save-view! ws)
                 (when (not (rawequal shown ws))
                   (load-view! shown))
                 (if callback-ok? callback-result (error callback-result))))
            debug.traceback)]
      (set view-depth 0)
      (if ok? result (error result)))))

(fn M.capture-active! []
  (let [active (M.active)]
    (with-view! active (fn [] active))))

(fn M.activate! [id]
  (let [_current (M.capture-active!)
        next (find-workspace id)]
    (when next
      (ensure-metadata! next)
      (set state.active-workspace-id id)
      (load-view! next)
      ;; Completion is modal presenter state, not conversation state. Closing
      ;; it here prevents a main-session popup from stealing focus in a job tab.
      (set state.completion nil)
      (set next.activity-count 0)
      (set next.dirty? false)
      (redraw.invalidate-full!))
    next))

(fn M.create! [spec]
  "Create one presenter tab record without teaching core sessions about tabs."
  (M.capture-active!)
  (let [id spec.id]
    (assert id "workspace id is required")
    (or (find-workspace id)
        (let [ws {}]
          (each [k v (pairs spec)] (tset ws k v))
          (ensure-metadata! ws)
          (ensure-view! ws)
          (table.insert state.workspaces ws)
          (redraw.invalidate-full!)
          ws))))

(fn M.with-main! [f]
  "Run F against the main transcript without changing the tab being viewed."
  (M.ensure!)
  (with-view! (find-workspace :main-session) f))

(fn M.close! [id]
  "Close a presenter workspace according to its kind policy.

   Subagent ids are remembered so retained runs do not recreate hidden tabs.
   Ephemeral kinds may dispose their private state through the policy close
   callback before the workspace record is removed."
  (let [ws (find-workspace id)
        spec (and ws (M.kind-spec ws))]
    (when (and ws (M.closable? ws))
      (M.capture-active!)
      (when (and spec spec.close!)
        (spec.close! ws))
      (when (M.subagent? ws)
        (when (= state.closed-subagent-workspaces nil)
          (set state.closed-subagent-workspaces {}))
        (tset state.closed-subagent-workspaces id true))
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

(fn M.switcher-choices []
  "Return api.ui.select choices for the existing modal focus path."
  (icollect [_ ws (ipairs (M.list))]
    {:label (.. (if (= ws.id state.active-workspace-id) "● " "  ")
                (or ws.title (tostring ws.id)))
     :value ws.id
     :description (table.concat
                    (icollect [_ part (ipairs [(tostring ws.kind)
                                              (and ws.status (tostring ws.status))
                                              ws.cwd])]
                      (when (and part (not= part "")) part))
                    " · ")}))

(fn M.submit! [line handlers]
  "Dispatch submission through the active kind's single policy entry."
  (let [ws (M.active)
        spec (M.kind-spec ws)]
    (when (and spec spec.submit!)
      (spec.submit! ws handlers line))))

(fn M.submit-steering! [line]
  "Route a subagent tab's steering draft through retained run state."
  (let [ws (M.active)
        note (tostring (or line ""))]
    (if (not (M.allows? :steer))
        (values nil "workspace is not steerable")
        (not (string.find note "%S"))
        (values nil "steering note is empty")
        (let [(available? run-state) (pcall require :fen.extensions.subagent.state)]
          (if (not available?)
              (values nil "subagent state is unavailable")
              (let [run (run-state.request-steer! ws.job-id note :user)]
                (if run
                    true
                    (values nil (.. "subagent run is not active: "
                                    (tostring ws.job-id))))))))))

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
  (let [ingest (require :fen.extensions.tui.ingest)]
    (with-view! ws #(ingest.append-event ev {:transcript-only? true}))))

(fn M.append-active! [ev]
  "Append one presenter-local row to the displayed workspace."
  (ingest-into! (M.active) ev))

(fn M.append-to! [id ev]
  "Append one canonical event to a workspace without touching main state."
  (let [ws (M.find id)]
    (when ws
      (ingest-into! ws ev)
      (if (= state.active-workspace-id id)
          (M.capture-active!)
          (do (set ws.activity-count (+ (or ws.activity-count 0) 1))
              (set ws.dirty? true)))
      ws)))

(fn M.refresh! [ws]
  "Refresh derived kind metadata after a workspace status transition."
  (when ws
    (ensure-metadata! ws)
    (redraw.invalidate!)
    ws))

(fn run-title [run]
  (.. (or run.agent "subagent") " #" (tostring (or run.seq "?"))))

(fn workspace-for-run [run]
  (find-workspace (.. "subagent:" run.id)))

(fn make-run-workspace [run]
  (M.create!
    {:id (.. "subagent:" run.id)
     :kind :subagent-job
     :title (run-title run)
     :cwd run.cwd
     :session-id nil
     :job-id run.id
     :source {:kind :subagent-run :run-id run.id}
     :status run.status
     :activity-count 0
     :dirty? false
     :source-event-seq 0
     :header-added? false
     :result-added? false
     :subagent-seq run.seq
     :started-at run.started-at
     :provider nil
     :model nil
     :usage nil}))

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
      (load-view! ws)))
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
    (set ws.status run.status)
    (ensure-metadata! ws)
    (when (or changed? status-changed? metadata-changed?)
      (if (= state.active-workspace-id ws.id)
          (M.capture-active!)
          (do (set ws.activity-count (+ (or ws.activity-count 0) 1))
              (set ws.dirty? true)))
      (redraw.invalidate!))
    ws))

(fn subagent-before? [a b]
  (let [a-rank (M.sort-rank a)
        b-rank (M.sort-rank b)]
    (if (< a-rank b-rank) true
        (> a-rank b-rank) false
        (= a-rank b-rank)
        (> (or a.subagent-seq 0) (or b.subagent-seq 0))
        (< (or a._workspace-order 0) (or b._workspace-order 0)))))

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
        (var membership-changed? false)
        (each [_ run (ipairs (run-state.runs))]
          (let [id (.. "subagent:" run.id)]
            (tset retained id true)
            (when (not (. state.closed-subagent-workspaces id))
              (let [existing (workspace-for-run run)
                    ws (or existing (make-run-workspace run))]
                (when (not existing) (set membership-changed? true))
                (project-run! ws run)))))
        ;; Run state keeps only a bounded history. Mirror that retention here so
        ;; completed job tabs cannot accumulate for the lifetime of a TUI. If a
        ;; cleared or closed run owns the visible tab, restore main before
        ;; removing it.
        (each [id _ (pairs state.closed-subagent-workspaces)]
          (when (not (. retained id))
            (tset state.closed-subagent-workspaces id nil)))
        (let [active (find-workspace state.active-workspace-id)]
          (when (and active (M.subagent? active)
                     (or (not (. retained active.id))
                         (. state.closed-subagent-workspaces active.id)))
            (M.activate! :main-session)))
        (let [kept []]
          (each [_ ws (ipairs state.workspaces)]
            (if (or (not (M.subagent? ws))
                    (and (. retained ws.id)
                         (not (. state.closed-subagent-workspaces ws.id))))
                (table.insert kept ws)
                (set membership-changed? true)))
          ;; Registry identity is the ensure! migration guard. Keep it stable
          ;; across runtime ticks, but replace it when tabs were added/removed
          ;; so every surviving legacy record gets one migration sweep.
          (when membership-changed?
            (set state.workspaces kept)
            (sort-workspaces!))))))
  (M.active))

(fn M.list []
  (M.ensure!)
  state.workspaces)

M
