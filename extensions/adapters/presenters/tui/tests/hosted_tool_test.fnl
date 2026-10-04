;; Hosted tool activity (#574): while a Codex web search runs the busy row says so, and when it ends one info row names what was searched; the bus event never becomes a raw `hosted-tool:` row.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local workspaces (require :fen.extensions.tui.workspaces))
(local events (require :fen.core.extensions.events))

(fn reset! []
  (test-api.reset!)
  (set tb.width-value 80)
  (set tb.height-value 10)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 10 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!)
  (set state.status-info.running-label nil)
  (set state.status-info.running-tools nil)
  (set state.status-info.thinking? false)
  (set state.status-info.turn-start 0))

(fn frame []
  (tb.clear)
  (paint.paint-frame!)
  (tui-test.screen-lines tb))

(fn busy-row []
  ;; 10 rows: the busy panel sits directly above the input row.
  (. (frame) 9))

(fn screen-has? [needle]
  (not= nil (string.find (table.concat (frame) "\n") needle 1 true)))

(fn search-start! [?id]
  (events.emit {:type :hosted-tool :phase :start :name "web_search"
                :id (or ?id "ws_1")}))

(fn search-end! [?fields]
  (let [ev {:type :hosted-tool :phase :end :name "web_search" :id "ws_1"
            :status "completed" :detail "latest Lua release"}]
    (each [k v (pairs (or ?fields {}))] (tset ev k v))
    (events.emit ev)))

(fn busy-shows? [needle]
  (not= nil (string.find (or (busy-row) "") needle 1 true)))

(fn info-texts []
  (icollect [_ ev (ipairs state.transcript)]
    (when (= ev.type :info) ev.text)))

(describe "hosted web search activity in the TUI"
  (fn []
    (before_each reset!)

    (it "shows the search in the busy row while it runs, without a transcript row"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (assert.is_true (busy-shows? "searching the web"))
        (assert.are.equal 0 (length state.transcript))
        (assert.is_false (screen-has? "hosted-tool"))))

    (it "replaces the busy label with one web search row when the search ends"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (search-end!)
        (assert.is_nil state.status-info.running-label)
        (assert.is_true (busy-shows? "thinking"))
        (assert.is_false (busy-shows? "searching"))
        (assert.are.same ["web search: latest Lua release"] (info-texts))
        (assert.are.equal 1 (length state.transcript))
        (assert.is_true (screen-has? "web search: latest Lua release"))
        (assert.is_false (screen-has? "hosted-tool"))))

    (it "marks a search that did not complete and omits a missing detail"
      (fn []
        (search-start!)
        (search-end! {:status "failed" :detail "latest Lua release"})
        (search-start! "ws_2")
        (events.emit {:type :hosted-tool :phase :end :name "web_search"
                      :id "ws_2" :status "completed"})
        (assert.are.same ["web search failed: latest Lua release" "web search"]
                         (info-texts))
        (assert.is_nil state.status-info.running-label)))

    (it "counts a search alongside a running local tool and restores its label"
      (fn []
        (events.emit {:type :llm-start})
        (events.emit {:type :tool-call :name :bash :arguments {:cmd "ls"}
                      :id "tc-1"})
        (search-start!)
        (assert.are.equal "2 tools" state.status-info.running-label)
        (search-end!)
        (assert.are.equal "$ ls" state.status-info.running-label)))

    (it "clears a search left running when the turn errors"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (events.emit {:type :error :error "stream dropped"})
        (assert.is_nil state.status-info.running-label)
        (assert.is_false (busy-shows? "searching"))))

    (it "clears a search left running when the final stream ends"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (events.emit {:type :assistant-text-delta :content-index 1
                      :delta "Lua 5.5.1"})
        (events.emit {:type :assistant-stream-end :final? true})
        (assert.is_nil state.status-info.running-label)
        (assert.is_false (busy-shows? "searching"))))

    (it "clears a search left running when the turn is cancelled"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (events.emit {:type :cancelled})
        (assert.is_nil state.status-info.running-label)))

    (it "drops a search cut off by a provider retry so later rounds show the real activity"
      (fn []
        ;; Attempt 1 starts ws_A and drops mid-search; its end never arrives.
        (events.emit {:type :llm-start})
        (search-start! "ws_A")
        (events.emit {:type :provider-retry :attempt 1 :max-attempts 3
                      :delay-ms 0 :reason "stream closed"})
        (assert.is_nil state.status-info.running-label)
        (assert.is_false (busy-shows? "searching"))
        ;; Attempt 2 searches again and asks for a local tool.
        (search-start! "ws_B")
        (assert.are.equal "searching the web" state.status-info.running-label)
        (search-end! {:id "ws_B"})
        (events.emit {:type :assistant-stream-end :final? false})
        (events.emit {:type :llm-end})
        (events.emit {:type :tool-call :name :bash :arguments {:cmd "ls"}
                      :id "tc-1"})
        (assert.are.equal "$ ls" state.status-info.running-label)
        (events.emit {:type :tool-result :id "tc-1"
                      :result {:content [{:type :text :text "a"}]}})
        (events.emit {:type :llm-start})
        (assert.is_nil state.status-info.running-label)
        (assert.is_true (busy-shows? "thinking"))
        (assert.is_false (busy-shows? "searching"))))

    (it "drops a search still open when its model call ends"
      (fn []
        (events.emit {:type :llm-start})
        (search-start!)
        (events.emit {:type :llm-end})
        (events.emit {:type :tool-call :name :bash :arguments {:cmd "ls"}
                      :id "tc-1"})
        (assert.are.equal "$ ls" state.status-info.running-label)))

    (it "keeps side-chat search activity on the side chat's own status"
      (fn []
        (workspaces.ensure!)
        (let [ws (workspaces.create! {:id :btw :kind :side-chat :title "btw"
                                      :status :running})]
          (workspaces.append-to! ws.id {:type :hosted-tool :phase :start
                                        :name "web_search" :id "ws_9"})
          (assert.is_nil state.status-info.running-label)
          (assert.are.equal "searching the web"
                            (. (workspaces.status-info ws) :running-label))
          (workspaces.append-to! ws.id {:type :hosted-tool :phase :end
                                        :name "web_search" :id "ws_9"
                                        :status "completed" :detail "q"})
          (assert.is_nil (. (workspaces.status-info ws) :running-label))
          (assert.are.equal "web search: q"
                            (transcript.event-text
                              (. ws.transcript (length ws.transcript)))))))))
