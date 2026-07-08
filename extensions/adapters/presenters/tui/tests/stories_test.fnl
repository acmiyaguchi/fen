;; Tests for reusable TUI story fixtures.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local stories (require :fen.extensions.tui.stories))

(fn names []
  (icollect [_ story (ipairs (stories.list))]
    story.name))

(fn has-name? [wanted]
  (var found? false)
  (each [_ name (ipairs (names))]
    (when (= name wanted)
      (set found? true)))
  found?)

(describe "tui stories registry"
  (fn []
    (it "lists story names and descriptions"
      (fn []
        (let [listed (stories.list)]
          (assert.is_true (>= (length listed) 6))
          (assert.is_true (has-name? :idle-empty))
          (assert.is_true (has-name? :busy-tool))
          (assert.is_true (has-name? :slash-completion))
          (assert.is_true (has-name? :scrolled-transcript))
          (assert.is_true (has-name? :errors-panel))
          (assert.is_true (has-name? :narrow-status))
          (each [_ story (ipairs listed)]
            (assert.are.equal :string (type story.description))
            (assert.is_true (> (length story.description) 0))))))

    (it "finds stories by keyword or string name"
      (fn []
        (assert.are.equal :busy-tool (. (stories.find :busy-tool) :name))
        (assert.are.equal :busy-tool (. (stories.find "busy-tool") :name))
        (assert.is_nil (stories.find :missing-story))))

    (it "errors for unknown setup names"
      (fn []
        (let [(ok? err) (pcall stories.setup! :missing-story)]
          (assert.is_false ok?)
          (assert.is_not_nil (string.find (tostring err) "unknown TUI story" 1 true)))))))

(describe "tui story setup"
  (fn []
    (it "resets state before seeding each story"
      (fn []
        (stories.setup! :busy-tool)
        (assert.are.equal "$ make test" state.status-info.running-label)
        (stories.setup! :idle-empty)
        (assert.are.equal "" state.input-buf)
        (assert.are.equal 0 (length state.transcript))
        (assert.is_nil state.status-info.running-label)
        (assert.is_false state.error-panel-visible?)
        (assert.is_false state.completion.active?)))

    (it "seeds the idle empty-input story"
      (fn []
        (stories.setup! :idle-empty)
        (assert.are.equal 80 state.tb-cols)
        (assert.are.equal 24 state.tb-rows)
        (assert.are.equal "" state.input-buf)
        (assert.are.equal 0 state.input-cursor)
        (assert.are.equal 0 (length state.transcript))))

    (it "seeds the busy tool story"
      (fn []
        (stories.setup! :busy-tool)
        (assert.are.equal "$ make test" state.status-info.running-label)
        (assert.are.equal 0 state.status-info.spin-frame)
        (assert.is_true (> (length state.transcript) 0))))

    (it "seeds the slash completion story"
      (fn []
        (stories.setup! :slash-completion)
        (assert.are.equal "/re" state.input-buf)
        (assert.are.equal (length state.input-buf) state.input-cursor)
        (assert.is_true state.completion.active?)
        (assert.are.equal :command state.completion.kind)
        (assert.is_true (>= (length state.completion.items) 2))))

    (it "seeds the scrolled transcript story"
      (fn []
        (stories.setup! :scrolled-transcript)
        (assert.is_true (> (length state.transcript) 6))
        (assert.is_true (> state.scroll-offset 0))
        (assert.is_true state.new-content-below?)))

    (it "seeds the errors panel story"
      (fn []
        (stories.setup! :errors-panel)
        (assert.is_true state.error-panel-visible?)
        (assert.are.equal :error (. state.transcript 2 :type))
        (assert.are.equal :extension-error (. state.transcript 3 :type))))

    (it "seeds the narrow status story with small dimensions"
      (fn []
        (stories.setup! :narrow-status)
        (assert.are.equal 32 state.tb-cols)
        (assert.are.equal 10 state.tb-rows)
        (assert.are.equal "anthropic" state.status-info.provider)
        (assert.are.equal "claude-sonnet" state.status-info.model)
        (assert.is_true (> state.scroll-offset 0))))

    (it "allows caller dimension overrides"
      (fn []
        (stories.setup! :narrow-status {:cols 44 :rows 13})
        (assert.are.equal 44 state.tb-cols)
        (assert.are.equal 13 state.tb-rows)))))
