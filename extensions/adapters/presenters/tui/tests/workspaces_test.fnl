;; Workspace registry and read-only subagent projections.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)

(local tb (require :termbox2))
(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))
(local tabs-panel (require :fen.extensions.tui.panels.tabs))
(local run-state (require :fen.extensions.subagent.state))

(fn reset! []
  (run-state.reset!)
  (set state.workspaces [])
  (set state.active-workspace-id :main-session)
  (set state.transcript [{:type :info :text "main"}])
  (set state.streaming-assistant-rows {})
  (set state.transcript-layout-cache nil)
  (set state.scroll-offset 0)
  (set state.new-content-below? false)
  (set state.last-user-jump-index nil)
  (set state.selection nil)
  (set state.selection-paint nil)
  (set state.dirty? false)
  (set state.force-redraw? false)
  (workspaces.ensure!))

(describe "tui workspaces"
  (fn []
    (before_each reset!)

    (it "seeds one compatible main-session workspace"
      (fn []
        (let [tabs (workspaces.list)
              main (. tabs 1)]
          (assert.are.equal 1 (length tabs))
          (assert.are.equal :main-session main.id)
          (assert.are.equal :main-session main.kind)
          (assert.are.same state.transcript main.transcript))))

    (it "keeps transcript view state isolated while switching"
      (fn []
        (let [other {:id :other :kind :session-viewer :title "other"
                     :transcript [{:type :info :text "other"}]
                     :streaming-assistant-rows {}
                     :transcript-layout-cache nil
                     :scroll-offset 3 :new-content-below? true
                     :last-user-jump-index nil :selection nil :selection-paint nil}]
          (table.insert state.workspaces other)
          (workspaces.activate! :other)
          (assert.are.equal "other" (. state.transcript 1 :text))
          (set state.scroll-offset 7)
          (workspaces.activate! :main-session)
          (assert.are.equal "main" (. state.transcript 1 :text))
          (workspaces.activate! :other)
          (assert.are.equal 7 state.scroll-offset))))

    (it "initializes workspace state before routing main transcript updates"
      (fn []
        (set state.workspaces nil)
        (set state.active-workspace-id nil)
        (workspaces.with-main!
          #(table.insert state.transcript {:type :info :text "early update"}))
        (assert.are.equal :main-session state.active-workspace-id)
        (assert.are.equal "early update" (. state.transcript 2 :text))))

    (it "routes main transcript updates to main while another tab is displayed"
      (fn []
        (let [other {:id :other :kind :session-viewer :title "other"
                     :transcript [] :streaming-assistant-rows {}
                     :transcript-layout-cache nil :scroll-offset 0
                     :new-content-below? false :last-user-jump-index nil
                     :selection nil :selection-paint nil}]
          (table.insert state.workspaces other)
          (workspaces.activate! :other)
          (workspaces.with-main!
            #(table.insert state.transcript {:type :info :text "main update"}))
          (assert.are.equal 0 (length state.transcript))
          (workspaces.activate! :main-session)
          (assert.are.equal "main update" (. state.transcript 2 :text)))))

    (it "restores the displayed workspace when with-main callback fails"
      (fn []
        (let [other {:id :other :kind :session-viewer :title "other"
                     :transcript [{:type :info :text "other"}]
                     :streaming-assistant-rows {}
                     :transcript-layout-cache nil :scroll-offset 0
                     :new-content-below? false :last-user-jump-index nil
                     :selection nil :selection-paint nil}]
          (table.insert state.workspaces other)
          (workspaces.activate! :other)
          (let [(ok? _) (pcall #(workspaces.with-main! #(error "boom")))]
            (assert.is_false ok?))
          (assert.are.equal :other state.active-workspace-id)
          (assert.are.equal "other" (. state.transcript 1 :text)))))

    (it "renders a tab bar once a second workspace exists"
      (fn []
        (table.insert state.workspaces {:id :other :kind :session-viewer :title "other"})
        (assert.are.equal 1 (tabs-panel.height {:w 80}))
        (let [row (. (tabs-panel.render {:w 80}) 1)]
          ;; Only tab segments carry styling; unused row space keeps the
          ;; terminal's neutral background.
          (assert.is_nil row.bg)
          (assert.are.equal (bor tb.WHITE tb.REVERSE)
                            (. row.segments 1 :attr))
          (assert.are.equal (bor tb.WHITE tb.DIM)
                            (. row.segments 3 :attr))
          (assert.is_truthy (string.find (. row.segments 1 :text)
                                        "main" 1 true)))))

    (it "uses the rendered tab geometry for hit-testing"
      (fn []
        (table.insert state.workspaces {:id :other :kind :session-viewer :title "other"
                                        :activity-count 0 :dirty? false})
        ;; Main occupies 0..5, separator 6, and other starts at 7.
        (assert.are.equal :main-session (tabs-panel.tab-at 0 80))
        (assert.is_nil (tabs-panel.tab-at 6 80))
        (assert.are.equal :other (tabs-panel.tab-at 7 80))
        (assert.is_nil (tabs-panel.tab-at 7 7))))

    (it "does nothing when the optional subagent extension is unavailable"
      (fn []
        (let [loaded (. package.loaded :fen.extensions.subagent.state)
              preload (. package.preload :fen.extensions.subagent.state)]
          (tset package.loaded :fen.extensions.subagent.state nil)
          (tset package.preload :fen.extensions.subagent.state
                (fn [] (error "module unavailable")))
          (let [(ok? result) (pcall workspaces.sync-subagents!)]
            (tset package.loaded :fen.extensions.subagent.state loaded)
            (tset package.preload :fen.extensions.subagent.state preload)
            (assert.is_true ok?)
            (assert.are.equal :main-session result.id)
            (assert.are.equal 1 (length (workspaces.list)))))))

    (it "projects a subagent event stream into a read-only workspace"
      (fn []
        (let [run (run-state.start! {:agent "scout" :task "inspect state"
                                     :requested-cwd "." :cwd "/tmp"
                                     :physical-cwd "/tmp" :background? true})]
          (run-state.append-event! run.id {:type :tool-call :name "read"
                                            :summary "state.fnl"})
          (workspaces.sync-subagents!)
          (let [tabs (workspaces.list)
                ws (. tabs 2)]
            (assert.are.equal :subagent-job ws.kind)
            (assert.are.equal run.id ws.job-id)
            (assert.is_truthy (string.find ws.title "subagent-1" 1 true))
            (assert.are.equal "tool> read: state.fnl" (. ws.transcript 2 :text))
            (assert.are.equal 1 ws.activity-count)
            ;; The backing event list is capped at 50, but the tab must still
            ;; redraw when later child progress replaces its tail.
            (for [i 1 51]
              (run-state.append-event! run.id {:type :info :summary (tostring i)}))
            (workspaces.sync-subagents!)
            (assert.is_truthy (string.find (. ws.transcript (length ws.transcript) :text)
                                          "51" 1 true))))))))
