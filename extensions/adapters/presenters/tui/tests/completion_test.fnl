;; Focused tests for the inline slash-command / argument completion menu.
;;
;; Drives the pure-logic layer (context detection, candidate collection,
;; navigation, commit) directly, plus the input.fnl Tab handler, without
;; touching real termbox2.

(local tui-test (require :fen.testing.tui))
(local tb-stub (tui-test.install-termbox-stub!))
(tui-test.install-markdown-stub!)

(local ext-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local input (require :fen.extensions.tui.input))
(local completion (require :fen.extensions.tui.completion))
(local command-registry (require :fen.core.extensions.register.command))

(fn reset! []
  (set state.tb-cols 80)
  (set state.tb-rows 24)
  (set state.input-buf "")
  (set state.input-cursor 0)
  (set state.completion nil)
  (set state.presenter-ctx nil)
  (set state.api {:emitted []
                  :emit (fn [ev] (table.insert state.api.emitted ev))})
  (completion.ensure-defaults!))

(fn set-buf! [s]
  (set state.input-buf s)
  (set state.input-cursor (length s)))

(describe "tui.completion context detection"
  (fn []
    (before_each reset!)

    (it "detects a command-name context inside the slash token"
      (fn []
        (let [ctx (completion.context "/mar" 4)]
          (assert.are.equal :command ctx.kind)
          (assert.are.equal "mar" ctx.prefix)
          (assert.are.equal 4 ctx.token-end))))

    (it "returns nil for plain prose"
      (fn []
        (assert.is_nil (completion.context "hello world" 5))))

    (it "returns nil when a slash is not the first character"
      (fn []
        (assert.is_nil (completion.context "hi /there" 9))))

    (it "returns nil when the cursor line is not the command line"
      (fn []
        ;; A newline before the cursor means we've moved off the command line.
        (assert.is_nil (completion.context "/cmd\nmore" 9))))

    (it "detects an argument context after the command name"
      (fn []
        (let [ctx (completion.context "/skills wal" 11)]
          (assert.are.equal :arg ctx.kind)
          (assert.are.equal "skills" ctx.command)
          (assert.are.equal "wal" ctx.arg-prefix)
          (assert.are.equal 8 ctx.arg-start))))))

(describe "tui.completion command candidates + menu"
  (fn []
    (before_each reset!)

    (it "lists commands matching the typed prefix"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-cand-test)]
          (api.register :command {:name :foo :description "Foo"
                                  :handler (fn [])})
          (api.register :command {:name :foobar :description "Foobar"
                                  :handler (fn [])})
          (api.register :command {:name :zap :description "Zap"
                                  :handler (fn [])})
          (let [cands (completion.command-candidates "foo")
                labels (icollect [_ c (ipairs cands)] c.label)]
            (command-registry.unregister-by-owner :completion-cand-test)
            (assert.are.same ["foo" "foobar"] labels)))))

    (it "falls back to substring command filtering when no prefix matches"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-substring-test)]
          (api.register :command {:name :zz-redraw :description "Force repaint"
                                  :handler (fn [])})
          (api.register :command {:name :zz-model :description "Switch model"
                                  :handler (fn [])})
          (let [cands (completion.command-candidates "draw")
                labels (icollect [_ c (ipairs cands)] c.label)]
            (command-registry.unregister-by-owner :completion-substring-test)
            (assert.are.same ["zz-redraw"] labels)))))

    (it "keeps the menu open for a single exact command match"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-refresh-test)]
          (api.register :command {:name :onlyone :description "only"
                                  :handler (fn [])})
          ;; Partial prefix with one match -> menu opens.
          (set-buf! "/only")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          ;; Fully-typed unique name keeps the completion visible so the
          ;; user can still see/confirm the resolved command.
          (set-buf! "/onlyone")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (assert.are.equal 1 (length state.completion.items))
          (assert.are.equal "onlyone" (. state.completion.items 1 :label))
          (command-registry.unregister-by-owner :completion-refresh-test))))

    (it "dismisses the menu for the current buffer until the input changes"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-dismiss-test)]
          (api.register :command {:name :alpha :handler (fn [])})
          (api.register :command {:name :alto :handler (fn [])})
          (set-buf! "/al")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (completion.dismiss!)
          (completion.refresh! {})
          (assert.is_false (completion.active?))
          (set-buf! "/alp")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (command-registry.unregister-by-owner :completion-dismiss-test))))

    (it "wraps selection with next!/prev!"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-nav-test)]
          (api.register :command {:name :aa :handler (fn [])})
          (api.register :command {:name :ab :handler (fn [])})
          (set-buf! "/a")
          (completion.refresh! {})
          (assert.are.equal 1 state.completion.cursor)
          (completion.next!)
          (assert.are.equal 2 state.completion.cursor)
          (completion.next!)
          (assert.are.equal 1 state.completion.cursor)
          (completion.prev!)
          (assert.are.equal 2 state.completion.cursor)
          (command-registry.unregister-by-owner :completion-nav-test))))

    (it "commits the selected command into the buffer with a trailing space"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-commit-test)]
          (api.register :command {:name :alpha :handler (fn [])})
          (api.register :command {:name :alto :handler (fn [])})
          (set-buf! "/al")
          (completion.refresh! {})
          (completion.next!) ;; select second (alto)
          (assert.is_true (completion.commit!))
          (assert.are.equal "/alto " state.input-buf)
          (assert.are.equal 6 state.input-cursor)
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-commit-test))))))

(describe "tui.completion argument completion"
  (fn []
    (before_each reset!)

    (it "asks the command's :complete hook and filters by the typed word"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-arg-test)]
          (api.register :command
                        {:name :pick
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [{:label "apple" :value "apple"}
                                      {:label "apricot" :value "apricot"}
                                      {:label "banana" :value "banana"}])})
          (set-buf! "/pick ap")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (let [labels (icollect [_ it (ipairs state.completion.items)] it.label)]
            (assert.are.same ["apple" "apricot"] labels))
          ;; Commit splices the argument in place.
          (assert.is_true (completion.commit!))
          (assert.are.equal "/pick apple " state.input-buf)
          (command-registry.unregister-by-owner :completion-arg-test))))

    (it "fuzzy-matches and ranks command arguments as they are typed"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-fuzzy-test)]
          (api.register :command
                        {:name :pickmodel
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [{:label "anthropic/claude-haiku-4-5"}
                                      {:label "anthropic/claude-sonnet-4-6"}
                                      {:label "openai/gpt-5.5"}])})
          (set-buf! "/pickmodel snt")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (assert.are.same ["anthropic/claude-sonnet-4-6"]
                           (icollect [_ it (ipairs state.completion.items)]
                             it.label))
          (command-registry.unregister-by-owner :completion-fuzzy-test))))

    (it "accepts bare string choices as label+value shorthand"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-string-test)]
          (api.register :command
                        {:name :strpick
                         :handler (fn [])
                         :complete (fn [_arg _ctx] ["alpha" "beta"])})
          (set-buf! "/strpick al")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (let [labels (icollect [_ it (ipairs state.completion.items)] it.label)]
            (assert.are.same ["alpha"] labels))
          (assert.is_true (completion.commit!))
          (assert.are.equal "/strpick alpha " state.input-buf)
          (command-registry.unregister-by-owner :completion-string-test))))

    (it "skips non-table, non-string, and label-less choices without crashing"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-malformed-test)]
          (api.register :command
                        {:name :mixed
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [42                    ;; number -> "42"
                                      true                  ;; boolean -> dropped
                                      {}                    ;; no label/value -> dropped
                                      {:value "vv"}         ;; value-only -> label "vv"
                                      {:label "good" :value "good"}])})
          (set-buf! "/mixed ")
          ;; Must not throw despite malformed entries.
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (let [labels (icollect [_ it (ipairs state.completion.items)] it.label)]
            (assert.are.same ["42" "vv" "good"] labels))
          (command-registry.unregister-by-owner :completion-malformed-test))))

    (it "normalize-choice returns nil for unusable values"
      (fn []
        (assert.is_nil (completion.normalize-choice true))
        (assert.is_nil (completion.normalize-choice (fn [])))
        (assert.is_nil (completion.normalize-choice {}))
        (assert.is_nil (completion.normalize-choice ""))
        (let [c (completion.normalize-choice "x")]
          (assert.are.equal "x" c.label)
          (assert.are.equal "x" c.value))))

    (it "is a no-op for commands without a completer"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-nocomp-test)]
          (api.register :command {:name :plain :handler (fn [])})
          (set-buf! "/plain xy")
          (completion.refresh! {})
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-nocomp-test))))

    (it "isolates completer errors and stays closed"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-err-test)]
          (api.register :command
                        {:name :boom
                         :handler (fn [])
                         :complete (fn [_ _] (error "kaboom"))})
          (set-buf! "/boom x")
          ;; Must not throw.
          (completion.refresh! {})
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-err-test))))))

(describe "tui.input Tab drives the completion menu"
  (fn []
    (before_each reset!)

    (it "extends to the common prefix before cycling"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-tab-test)]
          (api.register :command {:name :deploy :handler (fn [])})
          (api.register :command {:name :destroy :handler (fn [])})
          (set-buf! "/de")
          ;; Tab grows the common prefix "/de" -> "/des"? no: common of
          ;; deploy/destroy is "de", already typed -> menu cycles instead.
          (input.handle-key {:key 9 :ch 0 :mod 0} (fn [_]) nil (fn [] false))
          (assert.is_true (completion.active?))
          (command-registry.unregister-by-owner :completion-tab-test))))

    (it "passes the presenter context through to argument completers"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-ctx-test)]
          (api.register :command
                        {:name :ctxpick
                         :handler (fn [])
                         :complete (fn [_arg ctx]
                                     (if ctx.marker
                                         [{:label "seen" :value "seen"}]
                                         []))})
          (set state.presenter-ctx {:marker true})
          (set-buf! "/ctxpick se")
          (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0}
                            (fn [_]) nil (fn [] false))
          (assert.are.equal "/ctxpick seen " state.input-buf)
          (command-registry.unregister-by-owner :completion-ctx-test))))

    (it "enter submits an exact completed command instead of appending a space"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-enter-test)
              submitted []]
          (api.register :command {:name :reload :handler (fn [])})
          (set-buf! "/reload")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (assert.is_true (completion.selected-exact-command?))
          (input.handle-key {:key tb-stub.KEY_ENTER :ch 0 :mod 0}
                            (fn [line] (table.insert submitted line))
                            nil
                            (fn [] false))
          (assert.are.same ["/reload"] submitted)
          (assert.are.equal "" state.input-buf)
          (assert.are.equal 0 state.input-cursor)
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-enter-test))))

    (it "commits a fuzzy argument once, then submits on the next enter"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-arg-enter-test)
              submitted []]
          (api.register :command
                        {:name :pickmodel
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [{:label "anthropic/claude-haiku-4-5"}
                                      {:label "anthropic/claude-sonnet-4-6"}
                                      {:label "openai/gpt-5.5"}])})
          (set-buf! "/pickmodel snt")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (assert.are.same ["anthropic/claude-sonnet-4-6"]
                           (icollect [_ it (ipairs state.completion.items)]
                             it.label))

          ;; First Enter accepts the highlighted completion but does not
          ;; submit while the user is still confirming the completed line.
          (input.handle-key {:key tb-stub.KEY_ENTER :ch 0 :mod 0}
                            (fn [line] (table.insert submitted line))
                            nil
                            (fn [] false))
          (assert.are.equal "/pickmodel anthropic/claude-sonnet-4-6 "
                            state.input-buf)
          (assert.are.same [] submitted)
          (assert.is_false (completion.active?))

          ;; The next Enter must submit, not reopen completion and append the
          ;; same (or another) argument indefinitely.
          (input.handle-key {:key tb-stub.KEY_ENTER :ch 0 :mod 0}
                            (fn [line] (table.insert submitted line))
                            nil
                            (fn [] false))
          (assert.are.same ["/pickmodel anthropic/claude-sonnet-4-6 "]
                           submitted)
          (assert.are.equal "" state.input-buf)
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-arg-enter-test))))

    (it "enter commits a selected longer command when the typed word also matches"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-enter-longer-test)
              submitted []]
          (api.register :command {:name :reload :handler (fn [])})
          (api.register :command
                        {:name :reload-extensions
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [{:label "all" :value "all"}])})
          (set-buf! "/reload")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          (assert.is_true (completion.selected-exact-command?))
          (completion.next!)
          (assert.is_false (completion.selected-exact-command?))
          (input.handle-key {:key tb-stub.KEY_ENTER :ch 0 :mod 0}
                            (fn [line] (table.insert submitted line))
                            nil
                            (fn [] false))
          (assert.are.same [] submitted)
          (assert.are.equal "/reload-extensions " state.input-buf)
          (assert.are.equal 19 state.input-cursor)
          ;; Command-name selection continues into the command's argument
          ;; completion rather than applying argument Enter's dismissal.
          (assert.is_true (completion.active?))
          (assert.are.same ["all"]
                           (icollect [_ it (ipairs state.completion.items)]
                             it.label))
          (command-registry.unregister-by-owner :completion-enter-longer-test))))

    (it "tab commits an argument and continues completion for another argument"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-tab-continue-test)]
          (api.register :command
                        {:name :multi
                         :handler (fn [])
                         :complete (fn [_arg _ctx]
                                     [{:label "alpha" :value "alpha"}])})
          (set-buf! "/multi al")
          (input.handle-key {:key tb-stub.KEY_TAB :ch 0 :mod 0}
                            (fn [_]) nil (fn [] false))
          (assert.are.equal "/multi alpha " state.input-buf)
          (assert.is_true (completion.active?))
          (assert.are.same ["alpha"]
                           (icollect [_ it (ipairs state.completion.items)]
                             it.label))
          (command-registry.unregister-by-owner :completion-tab-continue-test))))

    (it "inserts a literal tab when not in a slash context"
      (fn []
        (set-buf! "hello")
        (input.handle-key {:key 9 :ch 0 :mod 0} (fn [_]) nil (fn [] false))
        (assert.are.equal "hello\t" state.input-buf)))

    (it "typing after opening keeps filtering the menu"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-type-test)]
          (api.register :command {:name :cat :handler (fn [])})
          (api.register :command {:name :car :handler (fn [])})
          (api.register :command {:name :dog :handler (fn [])})
          (set-buf! "/c")
          (completion.refresh! {})
          (assert.are.equal 2 (length state.completion.items))
          ;; Type "a" then "t" via printable-input path.
          (input.handle-key {:key 0 :ch (string.byte "a") :mod 0 :utf8 "a"}
                            (fn [_]) nil (fn [] false))
          (input.handle-key {:key 0 :ch (string.byte "t") :mod 0 :utf8 "t"}
                            (fn [_]) nil (fn [] false))
          (assert.are.equal "/cat" state.input-buf)
          ;; Only "cat" matches -> exact unique stays visible.
          (assert.is_true (completion.active?))
          (assert.are.equal 1 (length state.completion.items))
          (assert.are.equal "cat" (. state.completion.items 1 :label))
          (command-registry.unregister-by-owner :completion-type-test))))))
