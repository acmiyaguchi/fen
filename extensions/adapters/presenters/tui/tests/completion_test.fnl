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

    (it "opens the menu on refresh and keeps a single exact match closed"
      (fn []
        (let [api (ext-api.make-runtime-api :completion-refresh-test)]
          (api.register :command {:name :onlyone :description "only"
                                  :handler (fn [])})
          ;; Partial prefix with one match -> menu opens.
          (set-buf! "/only")
          (completion.refresh! {})
          (assert.is_true (completion.active?))
          ;; Fully-typed unique name -> nothing to choose, menu closes.
          (set-buf! "/onlyone")
          (completion.refresh! {})
          (assert.is_false (completion.active?))
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
          ;; Only "cat" matches -> exact unique -> menu closed.
          (assert.is_false (completion.active?))
          (command-registry.unregister-by-owner :completion-type-test))))))
