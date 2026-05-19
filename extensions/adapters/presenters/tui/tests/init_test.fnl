;; Tests for tui.tui pure-logic helpers (spinner, timer, append-event
;; side effects on status-info). Avoids termbox2 entirely — we install a
;; full stub into package.loaded before requiring tui.tui so the module
;; load succeeds without touching the real C library.

;; ---- termbox2 stub ----
;; tui.tnl does `(local tb (require :termbox2))` at module load and
;; references constants like tb.GREEN, tb.CYAN, etc. Install a minimal
;; stub that returns sensible values for everything so the module
;; compiles and loads.
(local tui-test (require :fen.testing.tui))
(local tb-stub (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local ext-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local input (require :fen.extensions.tui.input))
(local command-registry (require :fen.core.extensions.register.command))
(local transcript (require :fen.extensions.tui.panels.transcript))
(local busy-panel (require :fen.extensions.tui.panels.busy))
(local ingest (require :fen.extensions.tui.ingest))
(local paint (require :fen.extensions.tui.paint))

(tui.register (ext-api.make-runtime-api :tui))

;; Reset all mutable state between tests so one test's turn-start/spin-frame
;; doesn't leak into the next.
(fn reset-state! []
  (set state.transcript [])
  (set state.streaming-assistant-rows {})
  (set state.transcript-layout-cache nil)
  (set state.scroll-offset 0)
  (set state.new-content-below? false)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.history [])
  (set state.history-pos 0)
  (set state.history-draft "")
  (set state.pending-quit? false)
  (set state.alt-pending? false)
  (set state.cancel-pressed? false)
  (set state.expand-tool-results? false)
  (set state.markdown? true)
  (set state.hide-thinking-block? false)
  (set state.animations? true)
  (set state.status-info
       {:model nil :provider nil :thinking-status nil
        :cum-input 0 :cum-output 0
        :cum-cache-read 0 :cum-cache-write 0
        :last-input 0
        :start-ms 0
        :running-label nil
        :thinking? false
        :cancelling? false
        :turn-start 0
        :spin-frame 0})
  (set state.dirty? false)
  (set state.force-redraw? false)
  (set state.spinner-ticks 0)
  (set state.spinner-interval-ticks 8)
  (set tb-stub.present-count 0)
  (set tb-stub.clear-count 0))

(describe "busy-panel.spin-char"
  (fn []
    (before_each reset-state!)

    (it "returns the first braille frame at spin-frame 0"
      (fn []
        (set state.status-info.spin-frame 0)
        ;; The first frame is ⠋ (U+280B).
        (assert.are.equal "⠋" (busy-panel.spin-char))))

    (it "cycles through frames modulo 10"
      (fn []
        ;; Frame 9 → index 10 → last frame ⠏
        (set state.status-info.spin-frame 9)
        (assert.are.equal "⠏" (busy-panel.spin-char))
        ;; Frame 10 → wraps to index 1 → ⠋ again
        (set state.status-info.spin-frame 10)
        (assert.are.equal "⠋" (busy-panel.spin-char))))

    (it "handles large frame numbers by wrapping"
      (fn []
        ;; 73 % 10 = 3 → index 4 → ⠸
        (set state.status-info.spin-frame 73)
        (assert.are.equal "⠸" (busy-panel.spin-char))))

    (it "returns a static glyph when animations are disabled"
      (fn []
        (set state.animations? false)
        (set state.status-info.spin-frame 9)
        (assert.are.equal "•" (busy-panel.spin-char))))))

(describe "busy-panel.turn-elapsed"
  (fn []
    (before_each reset-state!)

    (it "returns empty string when turn-start is 0 (idle)"
      (fn []
        (set state.status-info.turn-start 0)
        (assert.are.equal "" (busy-panel.turn-elapsed))))

    (it "returns seconds since turn-start"
      (fn []
        (let [now (os.time)]
          (set state.status-info.turn-start (- now 42))
          (assert.are.equal "42s" (busy-panel.turn-elapsed)))))

    (it "returns 0s when turn-start equals now"
      (fn []
        (set state.status-info.turn-start (os.time))
        (assert.are.equal "0s" (busy-panel.turn-elapsed))))))

(describe "tui dirty redraw scheduling"
  (fn []
    (before_each reset-state!)

    (it "invalidate! marks the frame dirty"
      (fn []
        (assert.is_false state.dirty?)
        (paint.invalidate!)
        (assert.is_true state.dirty?)))

    (it "invalidate-full! marks both force-redraw and dirty"
      (fn []
        (paint.invalidate-full!)
        (assert.is_true state.dirty?)
        (assert.is_true state.force-redraw?)))

    (it "ctrl-o routes through the redraw bus and requests cache clearing"
      (fn []
        (assert.is_false state.expand-tool-results?)
        (input.handle-key {:key 0x0f :ch 0 :mod 0} (fn [_]) nil (fn [] false))
        (assert.is_true state.expand-tool-results?)
        (assert.is_true state.dirty?)
        (assert.is_true state.force-redraw?)))

    (it "ingest appends invalidate instead of immediate redraw"
      (fn []
        (ingest.append-event {:type :info :text "hello"})
        (assert.is_true state.dirty?)
        (assert.are.equal 1 (length state.transcript))))

    (it "redraw-if-needed! skips clean idle frames"
      (fn []
        (set state.tb-initialized? true)
        (paint.redraw-if-needed!)
        (assert.are.equal 0 (or tb-stub.present-count 0))))

    (it "redraw-if-needed! presents once for dirty frames"
      (fn []
        (set state.tb-initialized? true)
        (paint.invalidate!)
        (paint.redraw-if-needed!)
        (assert.are.equal 1 (or tb-stub.present-count 0))
        (assert.is_false state.dirty?)))

    (it "redraw-if-needed! blank-presents then repaints for force redraw"
      (fn []
        (set state.tb-initialized? true)
        (paint.invalidate-full!)
        (paint.redraw-if-needed!)
        (assert.are.equal 2 (or tb-stub.present-count 0))
        (assert.is_false state.force-redraw?)))

    (it "busy spinner advances only after the configured tick interval"
      (fn []
        (set state.status-info.thinking? true)
        (set state.spinner-interval-ticks 3)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.status-info.spin-frame)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.status-info.spin-frame)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 1 state.status-info.spin-frame)
        (assert.is_true state.dirty?)))

    (it "spinner tick counter resets while idle"
      (fn []
        (set state.status-info.thinking? true)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 1 state.spinner-ticks)
        (set state.status-info.thinking? false)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.spinner-ticks)))

    (it "does not advance or invalidate for spinner frames when animations are disabled"
      (fn []
        (set state.animations? false)
        (set state.status-info.thinking? true)
        (set state.spinner-interval-ticks 1)
        (set state.dirty? false)
        (paint.advance-spinner-if-due!)
        (assert.are.equal 0 state.spinner-ticks)
        (assert.are.equal 0 state.status-info.spin-frame)
        (assert.is_false state.dirty?)))

    (it "tab-completes a unique slash command"
      (fn []
        (set state.input-buf "/mark")
        (set state.input-cursor (length state.input-buf))
        (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0} (fn [_]) nil (fn [] false))
        (assert.are.equal "/markdown " state.input-buf)
        (assert.are.equal (length state.input-buf) state.input-cursor)))

    (it "tab-completes when Tab arrives as Ctrl-I character input"
      (fn []
        (set state.input-buf "/mark")
        (set state.input-cursor (length state.input-buf))
        (input.handle-key {:key 0 :ch 9 :mod 0 :utf8 "\t"} (fn [_]) nil (fn [] false))
        (assert.are.equal "/markdown " state.input-buf)
        (assert.are.equal (length state.input-buf) state.input-cursor)))

    (it "tab-completes raw Ctrl-I key events even when KEY_TAB is unavailable"
      (fn []
        (let [saved tb-stub.KEY_TAB]
          (tset tb-stub :KEY_TAB nil)
          (set state.input-buf "/mark")
          (set state.input-cursor (length state.input-buf))
          (input.handle-key {:key 9 :ch 0 :mod 0} (fn [_]) nil (fn [] false))
          (tset tb-stub :KEY_TAB saved)
          (assert.are.equal "/markdown " state.input-buf)
          (assert.are.equal (length state.input-buf) state.input-cursor))))

    (it "tab-completes exact command names even when longer commands share the prefix"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-exact-test)]
          (api.register :command
                        {:name :foo
                         :description "Exact command"
                         :handler (fn [_args _state])})
          (api.register :command
                        {:name :foo-bar
                         :description "Longer command sharing exact prefix"
                         :handler (fn [_args _state])})
          (set state.input-buf "/foo")
          (set state.input-cursor (length state.input-buf))
          (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0} (fn [_]) nil (fn [] false))
          (command-registry.unregister-by-owner :completion-exact-test)
          (assert.are.equal "/foo " state.input-buf)
          (assert.are.equal (length state.input-buf) state.input-cursor))))

    (it "shows a hint for ambiguous slash command completion"
      (fn []
        (set state.input-buf "/e")
        (set state.input-cursor (length state.input-buf))
        (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0} (fn [_]) nil (fn [] false))
        (assert.are.equal "/e" state.input-buf)
        (assert.are.equal "commands: /errors /expand" (. state.transcript 1 :text))))

    (it "tab-completes slash commands registered by other extensions"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-test)]
          (api.register :command
                        {:name :zebra
                         :description "Test command completion from extension registry"
                         :handler (fn [_args _state])})
          (set state.input-buf "/zeb")
          (set state.input-cursor (length state.input-buf))
          (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0} (fn [_]) nil (fn [] false))
          (command-registry.unregister-by-owner :completion-test)
          (assert.are.equal "/zebra " state.input-buf)
          (assert.are.equal (length state.input-buf) state.input-cursor))))

    (it "uses a long event timeout when clean and idle"
      (fn []
        (assert.are.equal 300 (tui.peek-timeout-ms (fn [] false)))))

    (it "uses a short event timeout while dirty, busy, or resolving alt"
      (fn []
        (set state.dirty? true)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] false)))
        (set state.dirty? false)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] true)))
        (set state.alt-pending? true)
        (assert.are.equal 30 (tui.peek-timeout-ms (fn [] false)))))

    (it "renders the materialized thinking setting in the status bar"
      (fn []
        (tui.set-status-info {:thinking-status "reason:medium"})
        (let [items (state.api.list :status)]
          (var found nil)
          (each [_ item (ipairs items)]
            (when (= item.name :thinking)
              (set found item)))
          (assert.is_table found)
          (let [row (found.render {:status-info state.status-info :state state :w 80})]
            (assert.are.equal "reason:medium" row.text)))))))

(describe "ingest.append-event status-info side effects"
  (fn []
    (before_each reset-state!)

    (it "stamps turn-start on first :llm-start of a turn"
      (fn []
        (set state.status-info.turn-start 0)
        (ingest.append-event {:type :llm-start})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (assert.is_true state.status-info.thinking?)))

    (it "does not overwrite turn-start on subsequent :llm-start"
      (fn []
        ;; First llm-start stamps turn-start.
        (ingest.append-event {:type :llm-start})
        (let [first-start state.status-info.turn-start]
          ;; Second llm-start (next iteration of the tool loop) should
          ;; NOT reset the timer.
          (ingest.append-event {:type :llm-start})
          (assert.are.equal first-start state.status-info.turn-start))))

    (it "clears turn-start and thinking? on final :assistant-text"
      (fn []
        (ingest.append-event {:type :llm-start})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :assistant-text :text "done"})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "keeps turn active for non-final thinking and clears on final thinking"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :assistant-thinking :text "step" :final? false})
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :assistant-thinking :text "done thinking" :final? true})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "clears turn-start and thinking? on :error"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :error :error "boom"})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))

    (it "clears turn-start and thinking? on :cancelled"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :cancelled})
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)
        (assert.is_false state.status-info.cancelling?)))

    (it "normalizes extension-loaded events into durable info rows"
      (fn []
        (ingest.append-event {:type :extension-loaded :name :builtin_tools})
        (assert.are.equal :info (. state.transcript 1 :type))
        (assert.are.equal "extension-loaded: builtin_tools"
                          (. state.transcript 1 :text))
        (let [rows (transcript.viewport-lines 80 1)]
          (assert.are.equal "extension-loaded: builtin_tools" (. rows 1 :text)))))

    (it "renders compaction summaries as collapsed transcript rows with expandable details"
      (fn []
        (ingest.append-event {:type :compaction-summary
                              :summary "summary body"
                              :tokens-before 42000
                              :tokens-after 19000
                              :messages-summarized 37
                              :messages-kept 12
                              :guidance "focus files"
                              :trigger :manual})
        (let [rows (transcript.viewport-lines 80 3)]
          (assert.are.equal "compact> Compacted ~42.0k → ~19.0k tokens (37 summarized, 12 kept)"
                            (. rows 1 :text))
          (assert.are.equal 1 (length rows)))
        (set state.expand-tool-results? true)
        (transcript.clear-render-caches!)
        (let [rows (transcript.viewport-lines 80 4)]
          (assert.are.equal "compact> Compacted ~42.0k → ~19.0k tokens (37 summarized, 12 kept)"
                            (. rows 1 :text))
          (assert.are.equal "     guidance: focus files" (. rows 2 :text))
          (assert.are.equal "     summary body" (. rows 3 :text)))))

    (it "sets running-label on :tool-call and clears on :tool-result"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :tool-call
                           :name :bash
                           :arguments {:cmd "ls"}
                           :id "tc-1"})
        (assert.are.equal "$ ls" state.status-info.running-label)
        ;; Turn-start should still be alive (turn in progress).
        (assert.is_truthy (> state.status-info.turn-start 0))
        (ingest.append-event {:type :tool-result
                           :tool-call-id "tc-1"
                           :result {:content [{:type :text :text "file1\nfile2"}]}})
        (assert.is_nil state.status-info.running-label)
        ;; Turn still alive — the agent loop may do another LLM call.
        (assert.is_truthy (> state.status-info.turn-start 0))))

    (it "coalesces assistant text deltas into one transcript row"
      (fn []
        (ingest.append-event {:type :llm-start})
        (ingest.append-event {:type :assistant-text-delta :content-index 1 :delta "he"})
        (ingest.append-event {:type :assistant-text-delta :content-index 1 :delta "llo"})
        (assert.are.equal 1 (length state.transcript))
        (assert.are.equal :assistant-text (. state.transcript 1 :type))
        (assert.are.equal "hello" (transcript.event-text (. state.transcript 1)))
        (assert.is_true (. state.transcript 1 :streaming?))
        (ingest.append-event {:type :assistant-stream-end :final? true})
        (assert.is_nil (. state.transcript 1 :streaming?))
        (assert.is_true (. state.transcript 1 :final?))
        (assert.are.equal 0 state.status-info.turn-start)
        (assert.is_false state.status-info.thinking?)))))

(describe "tui transcript scroll-lock follow mode"
  (fn []
    (before_each reset-state!)

    (fn setup-scroll-fixture []
      (set state.tb-cols 20)
      (set state.tb-rows 6)
      (set state.markdown? false)
      (for [i 1 6]
        (ingest.append-event {:type :info :text (.. "row" (tostring i))}))
      (set state.scroll-offset 2)
      (set state.new-content-below? false))

    (fn visible-texts []
      (let [out []]
        (each [_ row (ipairs (transcript.viewport-lines 20 4))]
          (table.insert out row.text))
        out))

    (it "preserves the visible rows when tool output arrives below a scrolled viewport"
      (fn []
        (setup-scroll-fixture)
        (let [before (visible-texts)]
          (ingest.append-event {:type :tool-result
                                :id "tc-1"
                                :result {:content [{:type :text :text "tool body"}]}})
          (assert.are.same before (visible-texts))
          (assert.is_truthy (> state.scroll-offset 2))
          (assert.is_true state.new-content-below?))))

    (it "preserves the visible rows across streaming assistant growth"
      (fn []
        (setup-scroll-fixture)
        (let [before (visible-texts)]
          (ingest.append-event {:type :assistant-text-delta
                                :content-index 1
                                :delta "stream row"})
          (ingest.append-event {:type :assistant-text-delta
                                :content-index 1
                                :delta (string.rep "x" 160)})
          (assert.are.same before (visible-texts))
          (assert.is_truthy (> state.scroll-offset 2))
          (assert.is_true state.new-content-below?))))

    (it "clears the new-content indicator when paging back to the bottom"
      (fn []
        (setup-scroll-fixture)
        (ingest.append-event {:type :info :text "new below"})
        (assert.is_true state.new-content-below?)
        (input.handle-key {:key tb-stub.KEY_PGDN :ch 0 :mod 0} (fn [_]) nil (fn [] false))
        (assert.are.equal 0 state.scroll-offset)
        (assert.is_false state.new-content-below?)))

    (it "keeps scroll-lock state on resize unless clamped back to the bottom"
      (fn []
        (setup-scroll-fixture)
        (ingest.append-event {:type :info :text "new below"})
        (input.handle-event {:type tb-stub.EVENT_RESIZE :w 20 :h 6} (fn [_]) nil (fn [] false))
        (assert.is_truthy (> state.scroll-offset 0))
        (assert.is_true state.new-content-below?)
        (input.handle-event {:type tb-stub.EVENT_RESIZE :w 20 :h 40} (fn [_]) nil (fn [] false))
        (assert.are.equal 0 state.scroll-offset)
        (assert.is_false state.new-content-below?)))))

(describe "tui thinking rendering"
  (fn []
    (before_each reset-state!)

    (it "renders visible thinking rows in dim transcript output"
      (fn []
        (set state.markdown? false)
        (ingest.append-event {:type :assistant-thinking
                           :text "reasoning trace"
                           :spacer-after? true})
        (let [rows (transcript.viewport-lines 80 3)]
          (assert.are.equal "…   reasoning trace" (. rows 1 :text))
          (assert.are.equal "" (. rows 2 :text)))))

    (it "collapses thinking rows when hide-thinking-block? is true"
      (fn []
        (set state.hide-thinking-block? true)
        (ingest.append-event {:type :assistant-thinking :text "secret"})
        (let [rows (transcript.viewport-lines 80 2)]
          (assert.are.equal "…   Thinking..." (. rows 1 :text)))))))

(describe "tui extension wiring (issue #15 Step 3b/3c)"
  (fn []
    (local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))
(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :emit events.emit
   :on events.on
   :register register-registry.register
   :unregister-by-owner register-registry.unregister-by-owner
   :list register-registry.list
   :dispatch-command command-registry.dispatch
   :merged-tools tool-registry.merged
   :run-before-tool hook-registry.run-before-tool
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :render-prompt prompt-registry.render
   :active-presenter presenter-registry.active-presenter
   :init-active-presenter presenter-registry.init-active-presenter
   :run-active-presenter presenter-registry.run-active-presenter
   :shutdown-active-presenter presenter-registry.shutdown-active-presenter
   :find-provider provider-registry.find
   :list-providers-by-api provider-registry.list-by-api
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})

    (it "registers /expand /markdown /animations /thinking-blocks with owner :tui"
      (fn []
        (let [names {}]
          (each [_ rec (ipairs (extensions.list :commands))]
            (when (= rec.owner :tui)
              (tset names rec.name true)))
          (assert.is_true (. names :expand))
          (assert.is_true (. names :markdown))
          (assert.is_true (. names :animations))
          (assert.is_true (. names :thinking-blocks)))))

    (it "registers an active presenter named :tui"
      (fn []
        (var found nil)
        (each [_ p (ipairs (extensions.list :presenters))]
          (when (= p.name :tui) (set found p)))
        (assert.is_not_nil found)
        (assert.is_true found.active?)))

    (it ":reset-conversation event clears the transcript"
      (fn []
        (reset-state!)
        (ingest.append-event {:type :info :text "stale"})
        (assert.are.equal 1 (length state.transcript))
        (extensions.emit {:type :reset-conversation})
        (assert.are.equal 0 (length state.transcript))))

    (it ":message-appended event stays out of the transcript"
      (fn []
        (reset-state!)
        (extensions.emit {:type :message-appended
                          :message {:role :user :content [{:type :text :text "hi"}]}
                          :index 1})
        (assert.are.equal 0 (length state.transcript))))

    (it ":agent-turn-complete event stays out of the transcript"
      (fn []
        (reset-state!)
        (extensions.emit {:type :agent-turn-complete
                          :status :ok
                          :result "done"
                          :message-count 2})
        (assert.are.equal 0 (length state.transcript))))

    (it ":set-status-info event applies the partial info"
      (fn []
        (reset-state!)
        (extensions.emit
          {:type :set-status-info
           :info {:model :gpt-test :steering-queued 7}})
        (assert.are.equal :gpt-test state.status-info.model)
        (assert.are.equal 7 state.status-info.steering-queued)))

    (it ":set-thinking-blocks event updates thinking visibility"
      (fn []
        (reset-state!)
        (set state.hide-thinking-block? false)
        (extensions.emit {:type :set-thinking-blocks :visible? false})
        (assert.is_true state.hide-thinking-block?)
        (extensions.emit {:type :set-thinking-blocks :visible? true})
        (assert.is_false state.hide-thinking-block?)))

    (it "/markdown command toggles state.markdown? via dispatch"
      (fn []
        (reset-state!)
        (set state.markdown? false)
        (extensions.dispatch-command "/markdown on" {})
        (assert.is_true state.markdown?)
        (extensions.dispatch-command "/markdown off" {})
        (assert.is_false state.markdown?)))

    (it "/expand command toggles state.expand-tool-results? via dispatch"
      (fn []
        (reset-state!)
        (extensions.dispatch-command "/expand on" {})
        (assert.is_true state.expand-tool-results?)
        (extensions.dispatch-command "/expand off" {})
        (assert.is_false state.expand-tool-results?)))

    (it "/animations command toggles state.animations? via dispatch"
      (fn []
        (reset-state!)
        (extensions.dispatch-command "/animations off" {})
        (assert.is_false state.animations?)
        (extensions.dispatch-command "/animations on" {})
        (assert.is_true state.animations?)))))

;; A signal-interrupted termbox poll/read (EINTR) must be treated as a
;; transient idle tick, never a session-fatal error (#132).
(describe "tui.interrupted-syscall?"
  (fn []
    (it "matches the EINTR strerror text (Linux and QNX wording)"
      (fn []
        (assert.is_true (tui.interrupted-syscall? "Interrupted system call"))
        (assert.is_true (tui.interrupted-syscall?
                          "Interrupted function call"))))
    (it "is case-insensitive and substring (shim-prefixed message)"
      (fn []
        (assert.is_true (tui.interrupted-syscall?
                          "tb_peek_event failed: interrupted function call"))))
    (it "is false for nil and for genuine fatal errors"
      (fn []
        (assert.is_false (tui.interrupted-syscall? nil))
        (assert.is_false (tui.interrupted-syscall? "Input/output error"))
        (assert.is_false (tui.interrupted-syscall? "Bad file descriptor"))))))