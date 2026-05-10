;; Fast in-process tests for TUI transcript viewport and rendering behavior.
;; These assert rows/state directly with a stubbed termbox2 rather than driving
;; a real terminal. Real PTY/perf coverage belongs to the libvirt harness.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local tb (require :termbox2))
(local state (require :fen.extensions.tui.state))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local ingest (require :fen.extensions.tui.ingest))
(local input (require :fen.extensions.tui.input))

(fn texts [rows]
  (let [out []]
    (each [_ row (ipairs rows)]
      (table.insert out row.text))
    out))

(fn reset! []
  (tui-test.reset-state! {:cols 80 :rows 24 :markdown? false})
  (transcript.ensure-defaults!))

(describe "tui transcript viewport tests"
  (fn []
    (before_each reset!)

    (it "returns the tail rows when not scrolled"
      (fn []
        (set state.transcript
             [{:type :user :text "first"}
              {:type :assistant-text :text "second"}
              {:type :assistant-text :text "third"}
              {:type :user :text "fourth"}
              {:type :assistant-text :text "fifth"}])
        (assert.are.same ["ai>  third" "you> fourth" "ai>  fifth"]
                         (texts (transcript.viewport-lines 80 3)))))

    (it "uses scroll-offset to show older rows"
      (fn []
        (set state.transcript
             [{:type :user :text "first"}
              {:type :assistant-text :text "second"}
              {:type :assistant-text :text "third"}
              {:type :user :text "fourth"}
              {:type :assistant-text :text "fifth"}])
        (set state.scroll-offset 1)
        (assert.are.same ["ai>  third" "you> fourth"]
                         (texts (transcript.viewport-lines 80 2)))))

    (it "deep-scroll indexed viewport maps offsets to event rows"
      (fn []
        (for [i 1 600]
          (table.insert state.transcript
                        {:type :user :text (.. "prompt " (tostring i))}))
        ;; region-h + scroll-offset > 500 forces the indexed path.
        ;; With 600 one-row events, offset 550 and height 5 should show rows 46-50.
        (set state.scroll-offset 550)
        (assert.are.same ["you> prompt 46"
                          "you> prompt 47"
                          "you> prompt 48"
                          "you> prompt 49"
                          "you> prompt 50"]
                         (texts (transcript.viewport-lines 80 5)))))

    (it "computes max-scroll bounds from rendered row count"
      (fn []
        (set state.tb-cols 80)
        (set state.tb-rows 6)
        (set state.transcript [{:type :user :text "one"}
                               {:type :assistant-text :text "two"}])
        (assert.are.equal 0 (transcript.max-scroll 1))
        (for [i 1 8]
          (table.insert state.transcript
                        {:type :user :text (.. "extra " (tostring i))}))
        ;; tb-rows 6 minus status row and one input row gives 4 visible rows;
        ;; 10 one-row events therefore allow 6 rows of scrollback.
        (assert.are.equal 6 (transcript.max-scroll 1))))

    (it "page and mouse scrolling clamp to transcript bounds"
      (fn []
        (set state.tb-cols 80)
        (set state.tb-rows 6)
        (for [i 1 10]
          (table.insert state.transcript
                        {:type :user :text (.. "prompt " (tostring i))}))
        (input.handle-key {:key tb.KEY_PGUP :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 3 state.scroll-offset)
        (input.handle-key {:key tb.KEY_PGUP :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 6 state.scroll-offset)
        (input.handle-key {:key tb.KEY_PGUP :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 6 state.scroll-offset)
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_DOWN})
        (assert.are.equal 3 state.scroll-offset)
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_DOWN})
        (assert.are.equal 0 state.scroll-offset)
        (input.handle-mouse {:key tb.KEY_MOUSE_WHEEL_UP})
        (assert.are.equal 3 state.scroll-offset)))

    (it "ctrl-g jumps to recent user messages and repeats backward"
      (fn []
        (set state.tb-cols 80)
        (set state.tb-rows 6)
        (set state.transcript
             [{:type :user :text "one"}
              {:type :assistant-text :text "a2"}
              {:type :assistant-text :text "a3"}
              {:type :assistant-text :text "a4"}
              {:type :user :text "two"}
              {:type :assistant-text :text "a6"}
              {:type :assistant-text :text "a7"}
              {:type :assistant-text :text "a8"}
              {:type :user :text "three"}
              {:type :assistant-text :text "a10"}
              {:type :assistant-text :text "a11"}
              {:type :assistant-text :text "a12"}])
        (input.handle-key {:key 0x07 :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 0 state.scroll-offset)
        (assert.are.equal 9 state.last-user-jump-index)
        (input.handle-key {:key 0x07 :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 4 state.scroll-offset)
        (assert.are.equal 5 state.last-user-jump-index)
        (assert.are.same ["you> two" "ai>  a6" "ai>  a7" "ai>  a8"]
                         (texts (transcript.viewport-lines 80 4)))
        (input.handle-key {:key 0x07 :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 8 state.scroll-offset)
        (assert.are.equal 1 state.last-user-jump-index)))

    (it "ctrl-g from a scrolled viewport targets the previous user above it"
      (fn []
        (set state.tb-cols 80)
        (set state.tb-rows 6)
        (for [i 1 12]
          (table.insert state.transcript
                        {:type (if (or (= i 1) (= i 5) (= i 9)) :user :assistant-text)
                         :text (.. "row " (tostring i))}))
        (set state.scroll-offset 3)
        (input.handle-key {:key 0x07 :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 4 state.scroll-offset)
        (assert.are.equal 5 state.last-user-jump-index)
        (assert.are.same ["you> row 5" "ai>  row 6" "ai>  row 7" "ai>  row 8"]
                         (texts (transcript.viewport-lines 80 4)))))

    (it "ctrl-y jumps to live bottom and resumes following"
      (fn []
        (set state.tb-cols 80)
        (set state.tb-rows 6)
        (for [i 1 10]
          (table.insert state.transcript
                        {:type :user :text (.. "prompt " (tostring i))}))
        (set state.scroll-offset 6)
        (set state.new-content-below? true)
        (set state.last-user-jump-index 4)
        (input.handle-key {:key 0x19 :ch 0 :mod 0} (fn [_] nil) nil nil)
        (assert.are.equal 0 state.scroll-offset)
        (assert.is_false state.new-content-below?)
        (assert.is_nil state.last-user-jump-index)))))

(describe "tui transcript rendering tests"
  (fn []
    (before_each reset!)

    (it "renders user and assistant rows with stable prefixes"
      (fn []
        (assert.are.same ["you> hello"]
                         (texts (transcript.lines-for-event
                                 {:type :user :text "hello"} 80)))
        (assert.are.same ["ai>  hi"]
                         (texts (transcript.lines-for-event
                                 {:type :assistant-text :text "hi"} 80)))))

    (it "wraps long rows at the requested width"
      (fn []
        (assert.are.same ["you> abc" "defgh"]
                         (texts (transcript.lines-for-event
                                 {:type :user :text "abcdefgh"} 8)))
        (assert.are.same ["you> "]
                         (texts (transcript.lines-for-event
                                 {:type :user :text ""} 8)))))

    (it "materializes streaming text chunks lazily"
      (fn []
        (let [ev {:type :assistant-text
                  :text ""
                  :text-chunks ["hel" "lo"]
                  :text-dirty? true}]
          (assert.are.equal "hello" (transcript.event-text ev))
          (assert.is_false ev.text-dirty?)
          (assert.are.equal "hello" ev.text))))

    (it "formats compact built-in tool-call labels"
      (fn []
        (let [cases [["read" {:path "README.md" :offset 2 :limit 3} "read README.md:2-4"]
                     ["bash" {:cmd "echo hi" :timeout 5} "$ echo hi (timeout 5s)"]
                     ["edit" {:path "a.fnl"} "edit a.fnl"]
                     ["write" {:path "a.fnl"} "write a.fnl"]
                     ["ls" {:path "docs" :limit 10} "ls docs (limit 10)"]
                     ["grep" {:pattern "foo" :path "src" :glob "*.fnl" :limit 7}
                      "grep /foo/ in src (*.fnl) limit 7"]
                     ["find" {:pattern "*.fnl" :path "packages" :limit 4}
                      "find *.fnl in packages limit 4"]]]
          (each [_ spec (ipairs cases)]
            (assert.are.equal (. spec 3)
                              (transcript.tool-call-short (. spec 1) (. spec 2))))
          (assert.is_nil (transcript.tool-call-short "unknown" {})))))

    (it "renders compact built-in tool-call labels through ingestion"
      (fn []
        (ingest.append-event {:type :tool-call
                              :id "call-1"
                              :name "read"
                              :arguments {:path "README.md" :offset 2 :limit 3}})
        (let [ev (. state.transcript 1)]
          (assert.are.same ["tool> run read README.md:2-4"]
                           (texts (transcript.lines-for-event ev 80)))
          (assert.are.equal "read README.md:2-4" ev.short))))

    (it "renders collapsed tool-result summaries by default"
      (fn []
        (ingest.append-event {:type :tool-call
                              :id "call-1"
                              :name "read"
                              :arguments {:path "README.md"}})
        (ingest.append-event {:type :tool-result
                              :id "call-1"
                              :result {:content [{:type :text
                                                  :text "line1\nline2\n"}]}})
        (let [call (. state.transcript 1)
              result (. state.transcript 2)
              rows (texts (transcript.lines-for-event call 80))]
          (assert.are.same ["tool> ok  read README.md (2 lines, 12B)"] rows)
          (assert.are.same [] (texts (transcript.lines-for-event result 80)))
          (assert.are.equal 12 result.body-bytes)
          (assert.are.equal 2 result.body-lines))))

    (it "includes error and duration metadata in collapsed tool-result summaries"
      (fn []
        (ingest.append-event {:type :tool-call
                              :id "call-1"
                              :name "write"
                              :arguments {:path "out.txt"}})
        (ingest.append-event {:type :tool-result
                              :id "call-1"
                              :is-error? true
                              :duration-seconds 61
                              :result {:content [{:type :text :text "failed"}]}})
        (assert.are.same ["tool> err write out.txt (1m01s)"]
                         (texts (transcript.lines-for-event
                                 (. state.transcript 1) 80)))))

    (it "marks non-mutating tool errors in collapsed summaries"
      (fn []
        (ingest.append-event {:type :tool-call
                              :id "call-1"
                              :name "read"
                              :arguments {:path "missing.txt"}})
        (ingest.append-event {:type :tool-result
                              :id "call-1"
                              :is-error? true
                              :result {:content [{:type :text :text "not found"}]}})
        (assert.are.same ["tool> err read missing.txt (1 line, 9B)"]
                         (texts (transcript.lines-for-event
                                 (. state.transcript 1) 80)))))

    (it "keeps best-effort path metadata for unpaired tool-result fallbacks"
      (fn []
        (let [ev {:type :tool-result
                  :tool-name "read"
                  :tool-path "README.md"
                  :body-lines 1
                  :body-bytes 9
                  :body-pretty "not found"}]
          (assert.are.same ["tool< ok  read README.md (1 line, 9B)"]
                           (texts (transcript.lines-for-event ev 80))))))

    (it "renders expanded tool-result bodies when requested"
      (fn []
        (ingest.append-event {:type :tool-call
                              :id "call-1"
                              :name "read"
                              :arguments {:path "README.md"}})
        (ingest.append-event {:type :tool-result
                              :id "call-1"
                              :result {:content [{:type :text
                                                  :text "line1\nline2"}]}})
        (set state.expand-tool-results? true)
        (assert.are.same ["tool> ok  read README.md (2 lines, 11B)"
                          "     line1"
                          "     line2"]
                         (texts (transcript.lines-for-event
                                 (. state.transcript 1) 80)))))))
