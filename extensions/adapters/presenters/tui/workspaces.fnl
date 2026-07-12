;; TUI presenter workspaces. Persistent state remains in tui.state; this
;; reloadable module swaps the existing transcript/view fields at workspace
;; boundaries so legacy render/input code can keep using state.* directly.

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
   :activity-count 0 :dirty? false})

(fn find-workspace [id]
  (var found nil)
  (each [_ ws (ipairs (or state.workspaces []))]
    (when (= ws.id id) (set found ws)))
  found)

(fn M.ensure! []
  (when (= state.workspaces nil) (set state.workspaces []))
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
  (let [shown-id state.active-workspace-id]
    (if (= shown-id :main-session)
        (f)
        (do
          (M.capture-active!)
          (let [main (find-workspace :main-session)]
            (copy-view! main state)
            ;; Ingestion normally handles its own failures, but this boundary
            ;; must restore the visible tab even if a future caller raises.
            (let [(ok? result) (xpcall f debug.traceback)]
              (copy-view! state main)
              (copy-view! (find-workspace shown-id) state)
              (if ok? result (error result))))))))

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

(fn event-text [ev]
  (let [typ (tostring (or ev.type :event))
        summary (or ev.summary ev.error ev.name "")]
    (if (= typ "subagent-start")
        (.. "started: " summary)
        (= typ "subagent-done")
        (.. "finished (" (tostring (or ev.status "unknown")) "): " summary)
        (= typ "tool-call")
        (.. "tool> " (tostring (or ev.name "tool"))
            (if (= (tostring summary) "") "" (.. ": " summary)))
        (= typ "tool-result")
        (.. "tool< " (tostring (or ev.name "tool"))
            (if ev.is-error? " (error)" "")
            (if (= (tostring summary) "") "" (.. ": " summary)))
        (.. typ (if (= (tostring summary) "") "" (.. ": " summary))))))

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
   :source-event-count -1})

(fn project-run! [ws run]
  (let [count (or run.event-count (length (or run.events [])))
        changed? (or (not= ws.source-event-count count)
                     (not= ws.status run.status))]
    (when changed?
      (let [rows [{:type :info
                   :text (.. "subagent " run.id " — " (tostring run.status)
                             " — " (or run.cwd ""))}]]
        (each [_ ev (ipairs (or run.events []))]
          (table.insert rows {:type :info :text (event-text ev)}))
        (when run.result
          (table.insert rows {:type :assistant-text :text run.result :final? true}))
        (set ws.transcript rows)
        (set ws.streaming-assistant-rows {})
        (set ws.transcript-layout-cache nil)
        (set ws.status run.status)
        (set ws.source-event-count count)
        (if (= state.active-workspace-id ws.id)
            (copy-view! ws state)
            (do (set ws.activity-count (+ (or ws.activity-count 0) 1))
                (set ws.dirty? true)))
        (redraw.invalidate!)))
    ws))

(fn M.sync-subagents! []
  "Project bounded subagent event streams into read-only workspaces."
  (M.capture-active!)
  (let [run-state (require :fen.extensions.subagent.state)
        retained {}]
    (each [_ run (ipairs (run-state.runs))]
      (tset retained (.. "subagent:" run.id) true)
      (let [ws (or (workspace-for-run run) (make-run-workspace run))]
        (when (not (workspace-for-run run))
          (table.insert state.workspaces ws))
        (project-run! ws run)))
    ;; Run state keeps only a bounded history. Mirror that retention here so
    ;; completed job tabs cannot accumulate for the lifetime of a TUI.
    (let [kept []]
      (each [_ ws (ipairs state.workspaces)]
        (when (or (= ws.kind :main-session)
                  (. retained ws.id)
                  (= ws.id state.active-workspace-id))
          (table.insert kept ws)))
      (set state.workspaces kept)))
  (M.active))

(fn M.list []
  (M.ensure!)
  state.workspaces)

M
