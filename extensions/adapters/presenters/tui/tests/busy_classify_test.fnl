;; Busy-time input classification as the TUI user sees it: the line queues as
;; steering at once, a confident decide answer surfaces a transcript notice,
;; and /decide undo moves a reclassified line back to steering.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 12}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local command-registry (require :fen.core.extensions.register.command))
(local input-pipeline (require :fen.core.extensions.input))
(local types (require :fen.core.types))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local input (require :fen.extensions.tui.input))
(local steering (require :fen.extensions.steering.service))
(local steering-state (require :fen.extensions.steering.state))
(local steering-ext (require :fen.extensions.steering))
(local queue-ext (require :fen.extensions.queue))

(local original-decide (. package.loaded :fen.extensions.decide.service))
(local original-decide-input (. package.loaded :fen.extensions.decide.input))
(var asks [])

(local run {:busy? true :turn-id 1
            :agent {:messages [(types.user-message "refactor the parser")]}})

(fn on-submit [line]
  ;; The interactive runtime's routing: slash lines dispatch as commands,
  ;; everything else goes through the input-handler pipeline.
  (if (= (string.sub line 1 1) "/")
      (command-registry.dispatch line run)
      (input-pipeline.handle {:kind :user-input :text line}
                             {:busy? run.busy? :state run})))

(fn reset! []
  (test-api.reset!)
  (steering.clear-queues!)
  (set asks [])
  (tset package.loaded :fen.extensions.decide.service
        {:enabled? (fn [] true)
         :ask-async! (fn [_st _qs on-done] (table.insert asks on-done))
         :finish-pending! (fn [] nil)
         :pump! (fn [] nil)})
  (tset package.loaded :fen.extensions.decide nil)
  (tset package.loaded :fen.extensions.decide.input nil)
  (set run.busy? true)
  (set tb.width-value 80)
  (set tb.height-value 12)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 12 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (steering-ext.register (test-api.make-runtime-api :steering))
  (queue-ext.register (test-api.make-runtime-api :queue))
  ((. (require :fen.extensions.decide) :register) (test-api.make-runtime-api :decide))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!)
  (set state.status-info.running-label "$ make test"))

(fn frame []
  (tb.clear)
  (paint.paint-frame!)
  (tui-test.screen-text tb))

(fn press-enter! []
  (input.handle-key {:key tb.KEY_ENTER :ch 0 :mod 0}
                    on-submit nil (fn [] run.busy?)))

(fn type-and-submit! [text]
  (each [c (string.gmatch text ".")]
    (input.handle-key {:key 0 :ch (string.byte c) :utf8 c :mod 0}
                      on-submit nil (fn [] run.busy?)))
  (press-enter!))

(fn run-subcommand! [text]
  ;; A typed subcommand leaves its argument menu open: the first Enter commits
  ;; the highlighted argument, the second submits the line.
  (type-and-submit! text)
  (press-enter!))

(fn answer [choice confidence]
  {:route {:type :choice : choice :confidence confidence
           :probabilities {choice confidence}}})

(fn has? [screen s]
  (not= nil (string.find screen s 1 true)))

(describe "busy input classification in the TUI"
  (fn []
    (before_each reset!)
    (after_each
      (fn []
        (tset package.loaded :fen.extensions.decide.service original-decide)
        (tset package.loaded :fen.extensions.decide nil)
        (tset package.loaded :fen.extensions.decide.input original-decide-input)
        (steering.clear-queues!)
        (test-api.reset!)))

    (it "moves a follow-up out of steering, shows how to undo, and /decide undo restores it"
      (fn []
        (type-and-submit! "then add a changelog entry")
        ;; Accepted immediately as steering, before any decision arrives.
        (assert.are.same ["then add a changelog entry"] steering-state.steering-queue)
        (assert.is_true (has? (frame) "queued> steering: then add a changelog entry"))
        ((. asks 1) (answer :follow-up 0.9))
        (let [screen (frame)]
          (assert.is_true (has? screen "queued> follow-up: then add a changelog entry"))
          (assert.is_true (has? screen "/decide undo to steer now")))
        (assert.are.same ["then add a changelog entry"] steering-state.follow-up-queue)
        (run-subcommand! "/decide undo")
        (assert.are.same ["then add a changelog entry"] steering-state.steering-queue)
        (assert.are.same [] steering-state.follow-up-queue)
        (assert.are.equal "" state.input-buf)
        ;; A second undo has nothing left to move and says so.
        (run-subcommand! "/decide undo")
        (assert.is_true (has? (frame) "decide undo: nothing to undo"))
        (assert.are.same ["then add a changelog entry"] steering-state.steering-queue)))

    (it "suggests ctrl-c for a cancel request without cancelling or moving the line"
      (fn []
        (type-and-submit! "stop, never mind")
        ((. asks 1) (answer :cancel 0.95))
        (let [screen (frame)]
          (assert.is_true (has? screen "reads as a cancel request · ctrl-c cancels the turn"))
          (assert.is_true (has? screen "ctrl-c cancel")))
        (assert.is_nil run.cancel-requested?)
        (assert.is_false state.cancel-pressed?)
        (assert.are.same ["stop, never mind"] steering-state.steering-queue)))

    (it "keeps the steering route with no notice on a correction, low confidence, or no answer"
      (fn []
        (type-and-submit! "use the other parser")
        ((. asks 1) (answer :correction 0.99))
        (type-and-submit! "maybe docs too")
        ((. asks 2) (answer :follow-up 0.4))
        (type-and-submit! "and tests")
        ((. asks 3) nil)
        (let [screen (frame)]
          (assert.is_false (has? screen "reads as"))
          (assert.is_false (has? screen "queued> follow-up")))
        (assert.are.same ["use the other parser" "maybe docs too" "and tests"]
                         steering-state.steering-queue)))

    (it "never classifies > follow-ups or slash commands"
      (fn []
        (type-and-submit! "> after this turn")
        (type-and-submit! "/queue")
        (assert.are.equal 0 (length asks))
        (assert.are.same ["after this turn"] steering-state.follow-up-queue)))))
