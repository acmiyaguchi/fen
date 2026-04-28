;; Tests for core.extensions — the v1 api skeleton (issue #15, Step 1).
;;
;; Covers: register :tool/:command/:hook, on/emit (incl. wildcard and pcall
;; isolation), contribute-system-prompt fragment rendering, list/freeze,
;; merged-tools, run-before-tool veto, unregister-by-owner.

(local extensions (require :core.extensions))

(before_each (fn [] (extensions.reset!)))

(describe "core.extensions register :tool"
  (fn []
    (it "appends to tools-extra and exposes via merged-tools"
      (fn []
        (let [api (extensions.make-api :ext-a)
              base [{:name :built-in :execute (fn [] {})}]
              spec {:name :greet
                    :description "say hi"
                    :execute (fn [] {})}
              handle (api.register :tool spec)
              merged (extensions.merged-tools base)]
          (assert.are.equal :tool handle.kind)
          (assert.are.equal :greet handle.name)
          (assert.are.equal :ext-a handle.owner)
          (assert.are.equal 2 (length merged))
          (assert.are.equal :built-in (. merged 1 :name))
          (assert.are.equal :greet (. merged 2 :name))
          (assert.are.equal :ext-a (. merged 2 :__owner)))))

    (it "unregister handle removes the tool"
      (fn []
        (let [api (extensions.make-api :ext-a)
              handle (api.register :tool {:name :greet :execute (fn [] {})})]
          (assert.are.equal 1 (length (extensions.merged-tools [])))
          (handle.unregister)
          (assert.are.equal 0 (length (extensions.merged-tools []))))))))

(describe "core.extensions register :command"
  (fn []
    (it "stores by name and overwrites on duplicate"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.register :command {:name :hi
                                  :description "first"
                                  :handler (fn [])})
          (api.register :command {:name :hi
                                  :description "second"
                                  :handler (fn [])})
          (assert.are.equal "second"
                            (. extensions.commands-extra :hi :description)))))))

(describe "core.extensions on/emit"
  (fn []
    (it "fires handlers registered for a specific event type"
      (fn []
        (let [api (extensions.make-api :ext-a)
              seen []]
          (api.on :tool-call (fn [ev] (table.insert seen ev)))
          (extensions.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :bash (. seen 1 :name)))))

    (it "fires :* wildcard subscribers for every event"
      (fn []
        (let [api (extensions.make-api :ext-a)
              seen []]
          (api.on :* (fn [ev] (table.insert seen ev.type)))
          (extensions.emit {:type :llm-start})
          (extensions.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.same [:llm-start :tool-call] seen))))

    (it "isolates handlers via pcall — a throwing handler does not block siblings"
      (fn []
        (let [api (extensions.make-api :ext-a)
              fired []]
          (api.on :error (fn [_] (error "boom")))
          (api.on :error (fn [ev] (table.insert fired ev.error)))
          (extensions.emit {:type :error :error "real"})
          (assert.are.same ["real"] fired))))

    (it "emits extension-error diagnostics for throwing handlers"
      (fn []
        (let [bad (extensions.make-api :bad-ext)
              diag (extensions.make-api :diag-ext)
              seen []]
          (bad.on :ping (fn [_] (error "boom")))
          (diag.on :extension-error (fn [ev] (table.insert seen ev)))
          (extensions.emit {:type :ping})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :bad-ext (. seen 1 :owner))
          (assert.are.equal :ping (. seen 1 :event))
          (assert.is_truthy (string.find (. seen 1 :error) "boom")))))

    (it "does not recursively emit extension-error for diagnostic handler failures"
      (fn []
        (let [api (extensions.make-api :bad-diag)
              seen []]
          (api.on :extension-error (fn [_] (error "diag boom")))
          (api.on :extension-error (fn [ev] (table.insert seen ev)))
          (extensions.emit {:type :extension-error
                            :owner :source
                            :event :ping
                            :error "original"})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :source (. seen 1 :owner)))))

    (it "returns an unsubscribe function"
      (fn []
        (let [api (extensions.make-api :ext-a)
              fired []
              unsub (api.on :ping (fn [_] (table.insert fired 1)))]
          (extensions.emit {:type :ping})
          (unsub)
          (extensions.emit {:type :ping})
          (assert.are.equal 1 (length fired)))))))

(describe "core.extensions contribute-system-prompt"
  (fn []
    (it "static text appears in fragments-for :end by default"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.contribute-system-prompt "hello extension")
          (assert.are.equal "hello extension"
                            (extensions.fragments-for :end)))))

    (it "honors :slot opt"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.contribute-system-prompt "before" {:slot :before-body})
          (assert.are.equal "before"
                            (extensions.fragments-for :before-body))
          (assert.is_nil (extensions.fragments-for :end)))))

    (it "joins multiple fragments with blank-line separator"
      (fn []
        (let [a (extensions.make-api :ext-a)
              b (extensions.make-api :ext-b)]
          (a.contribute-system-prompt "first")
          (b.contribute-system-prompt "second")
          (assert.are.equal "first\n\nsecond"
                            (extensions.fragments-for :end)))))

    (it "evaluates dynamic (function) fragments at render time"
      (fn []
        (let [api (extensions.make-api :ext-a)
              counter {:n 0}]
          (api.contribute-system-prompt
            (fn []
              (set counter.n (+ counter.n 1))
              (.. "tick=" (tostring counter.n))))
          (assert.are.equal "tick=1" (extensions.fragments-for :end))
          (assert.are.equal "tick=2" (extensions.fragments-for :end)))))

    (it "degrades a failing dynamic fragment to an HTML comment"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.contribute-system-prompt (fn [] (error "broke")))
          (let [text (extensions.fragments-for :end)]
            (assert.is_truthy (string.find text "extension ext%-a failed"))
            (assert.is_truthy (string.find text "broke"))))))

    (it "rejects unknown slots"
      (fn []
        (let [api (extensions.make-api :ext-a)
              (ok? err) (pcall api.contribute-system-prompt "x" {:slot :nope})]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "unknown slot")))))))

(describe "core.extensions register :hook + run-before-tool"
  (fn []
    (it "no hooks → not blocked"
      (fn []
        (let [r (extensions.run-before-tool :bash {} {})]
          (assert.is_false r.block?))))

    (it "veto from a hook stops the chain and reports reason"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.register :hook
                        {:before-tool
                         (fn [name _ _]
                           (when (= name :bash)
                             {:block true :reason "no shell"}))})
          (let [r (extensions.run-before-tool :bash {:cmd "ls"} {})]
            (assert.is_true r.block?)
            (assert.are.equal "no shell" r.reason)))))

    (it "subsequent hooks after a veto are skipped"
      (fn []
        (let [api (extensions.make-api :ext-a)
              second-fired? {:n false}]
          (api.register :hook
                        {:before-tool (fn [_ _ _] {:block true :reason "x"})})
          (api.register :hook
                        {:before-tool (fn [_ _ _] (set second-fired?.n true))})
          (extensions.run-before-tool :bash {} {})
          (assert.is_false second-fired?.n))))))

(describe "core.extensions list / introspection"
  (fn []
    (it ":tools returns frozen list with owner tags"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.register :tool {:name :greet :execute (fn [] {})})
          (let [lst (api.list :tools)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :greet (. lst 1 :name))
            (assert.are.equal :ext-a (. lst 1 :owner))
            (assert.has_error (fn [] (tset lst :extra :nope)))
            (assert.has_error (fn [] (tset lst 1 {:name :changed})))
            (assert.has_error (fn [] (tset (. lst 1) :name :changed)))))))

    (it ":system-prompt-contributions reports per-slot owners"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.contribute-system-prompt "x" {:slot :before-body})
          (api.contribute-system-prompt (fn [] "y") {:slot :end})
          (let [lst (api.list :system-prompt-contributions)]
            (assert.are.equal 1 (length lst.before-body))
            (assert.are.equal :ext-a (. lst.before-body 1 :owner))
            (assert.is_false (. lst.before-body 1 :dynamic?))
            (assert.is_true (. lst.end 1 :dynamic?))))))))

(describe "core.extensions unregister-by-owner"
  (fn []
    (it "drops every contribution tagged with the owner"
      (fn []
        (let [a (extensions.make-api :ext-a)
              b (extensions.make-api :ext-b)]
          (a.register :tool {:name :a-tool :execute (fn [] {})})
          (b.register :tool {:name :b-tool :execute (fn [] {})})
          (a.register :command {:name :a-cmd :handler (fn [])})
          (b.register :command {:name :b-cmd :handler (fn [])})
          (a.contribute-system-prompt "from-a")
          (b.contribute-system-prompt "from-b")
          (a.on :ping (fn [] nil))
          (b.on :ping (fn [] nil))
          (extensions.unregister-by-owner :ext-a)
          (let [tools (extensions.merged-tools [])
                ping-bucket (. extensions.handlers :ping)]
            (assert.are.equal 1 (length tools))
            (assert.are.equal :b-tool (. tools 1 :name))
            (assert.is_nil (. extensions.commands-extra :a-cmd))
            (assert.is_not_nil (. extensions.commands-extra :b-cmd))
            (assert.are.equal "from-b" (extensions.fragments-for :end))
            (assert.are.equal 1 (length ping-bucket))))))))

(describe "core.extensions ui slot"
  (fn []
    (it "has-ui? false when no presenter is registered"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (assert.is_false (api.ui.has-ui?)))))

    (it "presenter ui table promotes when registered as :active?"
      (fn []
        (let [api (extensions.make-api :ext-a)
              notified []
              presenter-ui {:notify (fn [t _] (table.insert notified t))
                            :prompt (fn [_] nil)
                            :select (fn [_] nil)}]
          (api.register :presenter
                        {:name :test-tui
                         :active? true
                         :ui presenter-ui})
          (assert.is_true (api.ui.has-ui?))
          (api.ui.notify "hi" nil)
          (assert.are.same ["hi"] notified))))

    (it "dispatches active presenter lifecycle generically"
      (fn []
        (let [api (extensions.make-api :ext-a)
              calls []]
          (api.register :presenter
                        {:name :test-presenter
                         :active? true
                         :init (fn [ctx]
                                 (table.insert calls (.. "init:" ctx.label)))
                         :run (fn [ctx]
                                (table.insert calls (.. "run:" ctx.label)))
                         :shutdown (fn [ctx]
                                      (table.insert calls
                                                    (.. "shutdown:" ctx.label)))})
          (let [(init-ok? init-err) (extensions.init-active-presenter {:label "x"})
                (run-ok? run-err) (extensions.run-active-presenter {:label "x"})
                (shutdown-ok? shutdown-err)
                (extensions.shutdown-active-presenter {:label "x"})]
            (assert.is_true init-ok?)
            (assert.is_nil init-err)
            (assert.is_true run-ok?)
            (assert.is_nil run-err)
            (assert.is_true shutdown-ok?)
            (assert.is_nil shutdown-err)
            (assert.are.same ["init:x" "run:x" "shutdown:x"] calls)))))

    (it "requires run for the active presenter"
      (fn []
        (let [api (extensions.make-api :ext-a)]
          (api.register :presenter {:name :no-run :active? true})
          (let [(ok? err) (extensions.run-active-presenter {})]
            (assert.is_false ok?)
            (assert.is_truthy (string.find (tostring err) "has no run"))))))))
