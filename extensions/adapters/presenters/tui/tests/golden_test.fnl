;; Story-based whole-frame golden snapshots for critical TUI states.
;; These tests reuse deterministic story fixtures and the capture-enabled
;; termbox stub to catch composed layout regressions without a real terminal.

(local view (require :fennel.view))
(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 24}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))

;; The TUI captures version text at module load for the right-side status.
;; Pin it before requiring the presenter so status placement is deterministic
;; across source trees, tags, and dirty checkouts.
(local saved-version (. package.loaded :fen.version))
(tset package.loaded :fen.version {:info (fn [] {:version "test" :source "source"})})
(tset package.loaded :fen.extensions.tui nil)
(local tui (require :fen.extensions.tui))
(tset package.loaded :fen.version saved-version)

(local paint (require :fen.extensions.tui.paint))
(local stories (require :fen.extensions.tui.stories))

(fn mask-build-status [line]
  "Mask source/build identity while preserving its occupied status slot."
  (let [(line _) (string.gsub line "src:[%w%.%-]+%*" "<build>")
        (line _) (string.gsub line "fen:[%w%.%-]+%*" "<build>")
        (line _) (string.gsub line "src:[%w%.%-]+" "<build>")
        (line _) (string.gsub line "fen:[%w%.%-]+" "<build>")]
    line))

(fn normalize-lines [lines]
  (icollect [_ line (ipairs lines)]
    (mask-build-status line)))

(fn render-story [name ?opts]
  (test-api.reset!)
  (stories.setup! name ?opts)
  (set tb.width-value state.tb-cols)
  (set tb.height-value state.tb-rows)
  (tb.clear)
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!)
  (paint.paint-frame!)
  (normalize-lines (tui-test.screen-lines tb)))

(fn assert-golden [name opts expected]
  (let [actual (render-story name opts)]
    (assert.are.same expected actual
                     (.. "golden mismatch for " (tostring name)
                         "\nexpected:\n" (view expected)
                         "\nactual:\n" (view actual)))))

(describe "tui story golden snapshots"
  (fn []
    (it "preserves a narrow status bar with right-side build identity"
      (fn []
        (assert-golden :narrow-status nil
                       [" anthropic:claude-sonne<build>"
                        ""
                        ""
                        ""
                        ""
                        ""
                        ""
                        ""
                        ""
                        ">"])))

    (it "renders the slash completion menu above the input"
      (fn []
        (assert-golden :slash-completion {:cols 40 :rows 8}
                       [" ?:?  ctx:~0                   <build>"
                        ""
                        ""
                        "┌─ commands (2)"
                        "│❯ reload   Reload extensions from sour…"
                        "│  redraw   Force a full TUI redraw"
                        "└─ tab/↑↓ move · enter select …"
                        "> /re"])))

    (it "renders busy tool feedback with the cancel/input row preserved"
      (fn []
        (assert-golden :busy-tool {:cols 40 :rows 7}
                       [" ?:?  ctx:~0                   <build>"
                        "you> run the focused tests"
                        "ai>  I'll run the focused test command n"
                        "ow."
                        ""
                        "  ⠋ $ make test"
                        ">"])))

    (it "renders a scrolled transcript with the new-content indicator"
      (fn []
        (assert-golden :scrolled-transcript {:cols 56 :rows 8}
                       [" ?:?  ctx:~0  scrolled:6 ↓new                  <build>"
                        "ai>  response 3"
                        "you> prompt 4"
                        "ai>  response 5"
                        "ai>  response 6"
                        "you> prompt 7"
                        "ai>  response 8"
                        ">"])))

    (it "renders the errors panel with traceback summaries"
      (fn []
        (assert-golden :errors-panel {:cols 64 :rows 12}
                       [" ?:?  ctx:~0                                           <build>"
                        "Errors — /errors to close, /errors clear to remove error rows"
                        "#1 extension handler failed owner=demo event=turn-complete: hand"
                        "    stack traceback:"
                        "      demo/init.fnl:8: bad argument"
                        "#2 example failure while loading extension"
                        "    stack traceback:"
                        "      stories/example.fnl:12: boom"
                        ""
                        ""
                        "extension-error: handler failed"
                        ">"])))))
