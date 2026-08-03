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
  (set state.closed-subagent-workspaces {})
  (set state.transcript [{:type :info :text "main"}])
  (set state.streaming-assistant-rows {})
  (set state.transcript-layout-cache nil)
  (set state.scroll-offset 0)
  (set state.new-content-below? false)
  (set state.last-user-jump-index nil)
  (set state.selection nil)
  (set state.selection-paint nil)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.paste-active? false)
  (set state.paste-buffer "")
  (set state.paste-counter 0)
  (set state.pastes {})
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft "")
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
          (assert.are.equal :main main.input-mode)
          (assert.are.equal :interactive-session main.source.kind)
          (assert.are.same state.transcript main.transcript)
          (assert.is_nil main.view-state))))

    (it "creates and switches tabs with isolated view and input state"
      (fn []
        (set state.input-buf "main draft")
        (set state.input-cursor 10)
        (let [job (workspaces.create!
                    {:id :job :kind :subagent-job :title "reviewer #3"
                     :job-id "subagent-3" :cwd "/tmp/review"
                     :input-mode :steer
                     :capabilities {:edit false :input true
                                    :submit false :steer true}})]
          (assert.are.equal 2 (length (workspaces.list)))
          (assert.are.equal "subagent-3" job.job-id)
          (assert.are.equal "/tmp/review" job.cwd)
          (assert.is_nil job.view-state)
          (workspaces.activate! :job)
          (assert.are.equal "" state.input-buf)
          (set state.input-buf "focus tests")
          (set state.input-cursor 11)
          (workspaces.activate! :main-session)
          (assert.are.equal "main draft" state.input-buf)
          (assert.are.equal 10 state.input-cursor)
          (workspaces.activate! :job)
          (assert.are.equal "focus tests" state.input-buf)
          (assert.are.equal 11 state.input-cursor))))

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

    (it "rejects nested view swaps without disturbing the displayed workspace"
      (fn []
        (let [other (workspaces.create!
                      {:id :other :kind :session-viewer :title "other"
                       :transcript [{:type :info :text "other"}]})]
          (workspaces.activate! other.id)
          (let [(ok? err)
                (pcall #(workspaces.with-main!
                          #(workspaces.with-main! (fn [] nil))))]
            (assert.is_false ok?)
            (assert.is_truthy
              (string.find (tostring err) "not reentrant" 1 true)))
          (assert.are.equal :other state.active-workspace-id)
          (assert.are.equal "other" (. state.transcript 1 :text)))))

    (it "keeps the tab bar invisible with only the main session"
      (fn []
        (assert.are.equal 0 (tabs-panel.height {:w 80}))))

    (it "renders a tab bar once a second workspace exists"
      (fn []
        (table.insert state.workspaces {:id :other :kind :subagent-job :title "other"})
        (assert.are.equal 1 (tabs-panel.height {:w 80}))
        (let [row (. (tabs-panel.render {:w 80}) 1)]
          ;; Only tab segments carry styling; unused row space keeps the
          ;; terminal's neutral background.
          (assert.is_nil row.bg)
          (assert.are.equal (bor tb.WHITE tb.REVERSE)
                            (. row.segments 1 :attr))
          (assert.are.equal (bor tb.WHITE tb.DIM)
                            (. row.segments 3 :attr))
          (assert.are.equal "[main]" (. row.segments 1 :text))
          (assert.are.equal "[other x]" (. row.segments 3 :text)))))

    (it "marks background activity and truncates tabs within narrow widths"
      (fn []
        (table.insert state.workspaces {:id :other :kind :subagent-job
                                        :title "reviewer #123"
                                        :activity-count 2 :dirty? true})
        (let [wide (tabs-panel.layout 80)
              narrow (tabs-panel.layout 9)
              wide-text (table.concat
                          (icollect [_ seg (ipairs wide.segments)] seg.text))
              narrow-text (table.concat
                            (icollect [_ seg (ipairs narrow.segments)] seg.text))]
          (assert.is_truthy (string.find wide-text "reviewer #123*" 1 true))
          (assert.is_true (<= (length narrow-text) 9))
          (assert.is_truthy (string.find narrow-text "~" 1 true)))))

    (it "uses the rendered tab geometry for hit-testing"
      (fn []
        (table.insert state.workspaces {:id :other :kind :session-viewer :title "other"
                                        :activity-count 0 :dirty? false})
        ;; Main occupies 0..5, separator 6, and other starts at 7.
        (assert.are.equal :main-session (tabs-panel.tab-at 0 80))
        (assert.is_nil (tabs-panel.tab-at 6 80))
        (assert.are.equal :other (tabs-panel.tab-at 7 80))
        (assert.is_nil (tabs-panel.tab-at 7 7))))

    (it "exposes a close hit on subagent tabs"
      (fn []
        (table.insert state.workspaces {:id "subagent:subagent-1"
                                        :kind :subagent-job
                                        :title "scout #1"
                                        :activity-count 0 :dirty? false})
        (var close-hit nil)
        (each [_ hit (ipairs (. (tabs-panel.layout 80) :hits))]
          (when (= hit.action :close) (set close-hit hit)))
        (assert.are.equal "subagent:subagent-1" close-hit.workspace-id)
        (assert.are.equal :close close-hit.action)))

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
                                            :arguments {:path "state.fnl"}})
          (workspaces.sync-subagents!)
          (let [tabs (workspaces.list)
                ws (. tabs 2)]
            (assert.are.equal :subagent-job ws.kind)
            (assert.is_false ws.capabilities.edit)
            (assert.is_false ws.capabilities.submit)
            (assert.are.equal run.id ws.job-id)
            (assert.are.equal "scout #1" ws.title)
            (assert.are.equal :steer ws.input-mode)
            (assert.is_true ws.capabilities.input)
            (assert.is_true ws.capabilities.steer)
            (assert.are.equal :subagent-run ws.source.kind)
            (assert.are.equal run.id ws.source.run-id)
            (assert.is_nil ws.view-state)
            (assert.are.equal :tool-call (. ws.transcript 2 :type))
            (assert.are.equal "read" (. ws.transcript 2 :name))
            (assert.is_truthy (string.find (. ws.transcript 2 :short)
                                          "state.fnl" 1 true))
            (assert.are.equal 1 ws.activity-count)
            ;; The backing event list is capped at 50, but the tab must still
            ;; redraw when later child progress replaces its tail.
            (for [i 1 51]
              (run-state.append-event! run.id {:type :info :summary (tostring i)}))
            (workspaces.sync-subagents!)
            (assert.is_truthy (string.find (. ws.transcript (length ws.transcript) :text)
                                          "51" 1 true))))))

    (it "uses canonical ingestion without leaking child status into main chrome"
      (fn []
        (set state.status-info.running-label "main-tool")
        (let [run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? true})]
          (run-state.append-event! run.id
                                   {:type :user :text "inspect README"})
          (run-state.append-event! run.id
                                   {:type :tool-call :id "c1" :name "read"
                                    :arguments {:path "README.md"}})
          (run-state.append-event! run.id
                                   {:type :tool-result :id "c1" :name "read"
                                    :result {:is-error? true
                                             :content [{:type :text :text "body"}]}})
          (run-state.append-event! run.id
                                   {:type :assistant-thinking :text "checking"
                                    :final? true})
          (run-state.append-event! run.id
                                   {:type :assistant-text :text "**done**"
                                    :final? true})
          (run-state.finish! run.id :completed {:result "**done**"})
          (workspaces.sync-subagents!)
          (let [ws (. (workspaces.list) 2)]
            (assert.are.equal :user (. ws.transcript 2 :type))
            (assert.are.equal "inspect README" (. ws.transcript 2 :text))
            (assert.are.equal :tool-call (. ws.transcript 3 :type))
            (assert.are.equal :tool-result (. ws.transcript 4 :type))
            (assert.is_true (. ws.transcript 4 :suppressed?))
            (assert.is_true (. ws.transcript 4 :is-error?))
            (assert.are.equal :assistant-thinking (. ws.transcript 5 :type))
            (assert.are.equal :assistant-text (. ws.transcript 6 :type))
            (assert.are.equal "**done**" (. ws.transcript 6 :text))
            (assert.are.equal 6 (length ws.transcript))
            (assert.are.equal "main-tool" state.status-info.running-label)))))

    (it "migrates an active legacy tab into canonical rows"
      (fn []
        (let [run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? true})]
          (run-state.append-event! run.id
                                   {:type :assistant-text :text "canonical"
                                    :final? true})
          (workspaces.sync-subagents!)
          (let [ws (. (workspaces.list) 2)]
            (workspaces.activate! ws.id)
            (set ws.source-event-seq nil)
            (set ws.source-event-count 1)
            (set ws.transcript [{:type :info :text "legacy"}])
            (set state.transcript ws.transcript)
            (workspaces.sync-subagents!)
            (assert.are.equal ws.id state.active-workspace-id)
            (assert.are.equal :assistant-text (. state.transcript 2 :type))
            (assert.are.equal "canonical" (. state.transcript 2 :text))))))

    (it "uses the full final result for legacy summary-only assistant events"
      (fn []
        (let [run (run-state.start! {:agent "scout" :task "legacy"
                                     :cwd "/tmp" :background? true})]
          (run-state.append-event! run.id
                                   {:type :assistant-text
                                    :summary "truncated old answer" :final? true})
          (run-state.finish! run.id :completed {:result "full legacy answer"})
          (workspaces.sync-subagents!)
          (let [ws (. (workspaces.list) 2)
                last (. ws.transcript (length ws.transcript))]
            (assert.are.equal :assistant-text last.type)
            (assert.are.equal "full legacy answer" last.text)))))

    (it "orders subagent workspaces newest on the left"
      (fn []
        (let [first (run-state.start! {:agent "scout" :task "one"
                                       :cwd "/tmp" :background? true})]
          (run-state.finish! first.id :completed {:result "one"})
          (run-state.start! {:agent "reviewer" :task "two"
                             :cwd "/tmp" :background? true})
          (workspaces.sync-subagents!)
          (let [tabs (workspaces.list)]
            (assert.are.equal :main-session (. tabs 1 :id))
            (assert.are.equal "subagent:subagent-2" (. tabs 2 :id))
            (assert.are.equal "subagent:subagent-1" (. tabs 3 :id))))))

    (it "closes subagent tabs without deleting retained run history"
      (fn []
        (run-state.start! {:agent "scout" :task "inspect state"
                           :requested-cwd "." :cwd "/tmp"
                           :physical-cwd "/tmp" :background? true})
        (workspaces.sync-subagents!)
        (workspaces.activate! "subagent:subagent-1")
        (assert.is_true (workspaces.close! "subagent:subagent-1"))
        (assert.are.equal :main-session state.active-workspace-id)
        (assert.are.equal 1 (length (workspaces.list)))
        (assert.is_truthy (run-state.find "subagent-1"))
        (workspaces.sync-subagents!)
        (assert.are.equal 1 (length (workspaces.list)))))

    (it "preserves registry identity until subagent membership changes"
      (fn []
        (let [empty-registry state.workspaces]
          (workspaces.sync-subagents!)
          (workspaces.sync-subagents!)
          (assert.is_true (rawequal empty-registry state.workspaces)))
        (run-state.start! {:agent "scout" :task "one"
                           :cwd "/tmp" :background? true})
        (workspaces.sync-subagents!)
        (let [registry state.workspaces
              first (workspaces.find "subagent:subagent-1")
              legacy-view {:input-buf "migrate me"}]
          ;; An inactive legacy marker is cleared only by ensure!'s registry
          ;; migration sweep, making repeated unchanged syncs observable.
          (set first.view-state legacy-view)
          (workspaces.sync-subagents!)
          (workspaces.sync-subagents!)
          (assert.is_true (rawequal registry state.workspaces))
          (assert.is_true (rawequal legacy-view first.view-state))

          (run-state.start! {:agent "reviewer" :task "two"
                             :cwd "/tmp" :background? true})
          (workspaces.sync-subagents!)
          (assert.is_false (rawequal registry state.workspaces))
          (assert.is_nil first.view-state)

          (let [added-registry state.workspaces
                second (workspaces.find "subagent:subagent-2")]
            (set first.view-state legacy-view)
            (assert.is_true (workspaces.close! second.id))
            (assert.is_false (rawequal added-registry state.workspaces))
            (workspaces.list)
            (assert.is_nil first.view-state)))))

    (it "clears activity on focus and survives behavior reload"
      (fn []
        (let [run (run-state.start! {:agent "reviewer" :task "inspect"
                                     :cwd "/tmp" :background? true})]
          (run-state.append-event! run.id {:type :info :summary "progress"})
          (workspaces.sync-subagents!)
          (let [ws (workspaces.find "subagent:subagent-1")
                old-module (. package.loaded :fen.extensions.tui.workspaces)]
            (assert.is_true ws.dirty?)
            (assert.is_true (> ws.activity-count 0))
            (workspaces.activate! ws.id)
            (assert.is_false ws.dirty?)
            (assert.are.equal 0 ws.activity-count)
            (set state.scroll-offset 4)
            (set state.input-buf "reload-safe note")
            (workspaces.capture-active!)
            ;; Simulate the duplicated table left by the pre-fix module. Flat
            ;; fields must win during the one-time reload migration.
            (set ws.view-state {:scroll-offset 99 :input-buf "stale note"})
            (let [registry state.workspaces]
              (tset package.loaded :fen.extensions.tui.workspaces nil)
              (let [reloaded (require :fen.extensions.tui.workspaces)]
                (reloaded.ensure!)
                (assert.is_true (rawequal registry state.workspaces))
                (assert.are.equal ws.id state.active-workspace-id)
                (assert.are.equal 4 state.scroll-offset)
                (assert.are.equal "reload-safe note" state.input-buf)
                (assert.is_nil ws.view-state))
              (tset package.loaded :fen.extensions.tui.workspaces old-module))))))

    (it "records subagent model and usage for active-tab status"
      (fn []
        (let [run (run-state.start! {:agent "scout" :task "inspect"
                                     :cwd "/tmp" :background? true})]
          (run-state.append-event! run.id {:type :agent-started
                                           :provider :sakana
                                           :model "fugu-ultra"})
          (run-state.append-event! run.id {:type :llm-end
                                           :usage {:input 10 :output 5
                                                   :total-tokens 15}})
          (workspaces.sync-subagents!)
          (let [ws (. (workspaces.list) 2)]
            (assert.are.equal :sakana ws.provider)
            (assert.are.equal "fugu-ultra" ws.model)
            (assert.are.equal 15 (. ws.usage :total-tokens))
            (run-state.finish! run.id :completed {:result "done"})
            (workspaces.sync-subagents!)
            (assert.are.equal :readonly ws.input-mode)
            (assert.is_false ws.capabilities.input)
            (assert.is_false ws.capabilities.steer)))))

    (it "removes cleared subagent tabs and restores main when one is active"
      (fn []
        (run-state.start! {:agent "scout" :task "inspect state"
                           :requested-cwd "." :cwd "/tmp"
                           :physical-cwd "/tmp" :background? true})
        (workspaces.sync-subagents!)
        (workspaces.activate! "subagent:subagent-1")
        (assert.are.equal "subagent:subagent-1" state.active-workspace-id)
        (run-state.reset!)
        (workspaces.sync-subagents!)
        (assert.are.equal :main-session state.active-workspace-id)
        (assert.are.equal 1 (length (workspaces.list)))
        (assert.are.equal "main" (. state.transcript 1 :text))))))
