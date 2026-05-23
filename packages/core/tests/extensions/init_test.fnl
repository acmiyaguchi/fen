;; Tests for core.extensions — the v1 api skeleton (issue #15, Step 1).
;;
;; Covers: register :tool/:command/:hook, on/emit (incl. wildcard and pcall
;; isolation), prompt fragment rendering, list/freeze,
;; merged-tools, run-before-tool veto, unregister-by-owner.

(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local introspect-registry (require :fen.core.extensions.register.introspect))
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
   :collect-introspection introspect-registry.collect
   :find-provider provider-registry.find
   :list-providers-by-api provider-registry.list-by-api
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))

(before_each (fn [] (extensions.reset!)))

(describe "core.extensions test runtime api"
  (fn []
    (it "exposes the small public extension surface"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              keys []]
          (each [k _ (pairs api)] (table.insert keys k))
          (table.sort keys)
          (assert.are.same [:auth :commands :diagnostics :emit :introspect :list :models :on
                            :prompt :register :session :settings :ui]
                           keys)))))

    (it "rejects privileged register kinds for public extension apis"
      (fn []
        (let [api (ext-api.make-runtime-api :external nil {:privileged? false})]
          (assert.has_error
            (fn []
              (api.register :provider {:name :p :api :openai-completions}))))))

    (it "allows public extensions to register introspectors"
      (fn []
        (let [api (ext-api.make-runtime-api :external nil {:privileged? false})]
          (api.register :introspect {:name :state :snapshot (fn [_] {:ok true})})
          (assert.are.equal true (. (api.introspect.collect :external) :external :state :ok))))))

(describe "core.extensions register :tool"
  (fn []
    (it "appends to tools-extra and exposes via merged-tools"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
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
        (let [api (ext-api.make-runtime-api :ext-a)
              handle (api.register :tool {:name :greet :execute (fn [] {})})]
          (assert.are.equal 1 (length (extensions.merged-tools [])))
          (handle.unregister)
          (assert.are.equal 0 (length (extensions.merged-tools []))))))))

(describe "core.extensions register :command"
  (fn []
    (it "stores by name and overwrites on duplicate"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :command {:name :hi
                                  :description "first"
                                  :handler (fn [])})
          (api.register :command {:name :hi
                                  :description "second"
                                  :handler (fn [])})
          (let [commands (extensions.list :commands)]
            (assert.are.equal 1 (length commands))
            (assert.are.equal :hi (. commands 1 :name))
            (assert.are.equal "second" (. commands 1 :description)))))))

(describe "core.extensions register :status"
  (fn []
    (it "stores ordered status blocks and exposes render functions"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :status {:name :late
                               :side :right
                               :order 20
                               :render (fn [_] {:text "late"})})
          (b.register :status {:name :early
                               :side :right
                               :order 10
                               :render (fn [_] {:text "early"})})
          (let [lst (extensions.list :status)]
            (assert.are.equal 2 (length lst))
            (assert.are.equal :early (. lst 1 :name))
            (assert.are.equal :ext-b (. lst 1 :owner))
            (assert.are.equal :right (. lst 1 :side))
            (assert.are.same {:text "early"} ((. lst 1 :render) {}))))))

    (it "unregister-by-owner drops status blocks"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :status {:name :a :render (fn [_] {:text "a"})})
          (b.register :status {:name :b :render (fn [_] {:text "b"})})
          (extensions.unregister-by-owner :ext-a)
          (let [lst (extensions.list :status)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :b (. lst 1 :name))))))))

(describe "core.extensions register :panel"
  (fn []
    (it "stores ordered panels and preserves render and height"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :panel {:name :late
                              :placement :above-input
                              :order 20
                              :height (fn [_] 2)
                              :render (fn [_] [{:text "late"}])})
          (b.register :panel {:name :early
                              :placement :above-input
                              :order 10
                              :height (fn [_] 1)
                              :render (fn [_] [{:text "early"}])})
          (let [lst (extensions.list :panels)]
            (assert.are.equal 2 (length lst))
            (assert.are.equal :early (. lst 1 :name))
            (assert.are.equal :ext-b (. lst 1 :owner))
            (assert.are.equal :above-input (. lst 1 :placement))
            (assert.are.equal 1 ((. lst 1 :height) {}))
            (assert.are.same [{:text "early"}] ((. lst 1 :render) {}))))))

    (it "defaults placement to :above-input and order to 50"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :panel {:name :p
                                :height (fn [_] 1)
                                :render (fn [_] [])})
          (let [lst (extensions.list :panels)]
            (assert.are.equal :above-input (. lst 1 :placement))
            (assert.are.equal 50 (. lst 1 :order))))))

    (it "rejects unknown placements"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.has_error
            (fn []
              (api.register :panel {:name :p
                                    :placement :nowhere
                                    :height (fn [_] 1)
                                    :render (fn [_] [])}))))))

    (it "rejects missing render or height"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.has_error
            (fn []
              (api.register :panel {:name :p :height (fn [_] 1)})))
          (assert.has_error
            (fn []
              (api.register :panel {:name :p :render (fn [_] [])}))))))

    (it "unregister-by-owner drops panels"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :panel {:name :a
                              :height (fn [_] 1)
                              :render (fn [_] [])})
          (b.register :panel {:name :b
                              :height (fn [_] 1)
                              :render (fn [_] [])})
          (extensions.unregister-by-owner :ext-a)
          (let [lst (extensions.list :panels)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :b (. lst 1 :name))))))))

(describe "core.extensions register :introspect"
  (fn []
    (it "stores descriptors and collects owner-scoped snapshots"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :introspect {:name :summary
                                   :description "state summary"
                                   :snapshot (fn [ctx] {:n ctx.n})})
          (b.register :introspect {:name :summary
                                   :snapshot (fn [_] {:other true})})
          (let [lst (extensions.list :introspectors)]
            (assert.are.equal 2 (length lst))
            (assert.are.equal :ext-a (. lst 1 :owner))
            (assert.are.equal :summary (. lst 1 :name))
            (assert.are.equal "state summary" (. lst 1 :description)))
          (let [snapshots (extensions.collect-introspection nil {:n 42})]
            (assert.are.equal 42 (. snapshots :ext-a :summary :n))
            (assert.are.equal true (. snapshots :ext-b :summary :other))))))

    (it "isolates snapshot failures"
      (fn []
        (let [api (ext-api.make-runtime-api :bad)]
          (api.register :introspect {:name :boom
                                     :snapshot (fn [_] (error "boom"))})
          (let [snapshots (api.introspect.collect)]
            (assert.is_truthy (string.find (. snapshots :bad :boom :error) "boom" 1 true))))))

    (it "unregister handle and owner cleanup remove introspectors"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)
              h (a.register :introspect {:name :a :snapshot (fn [_] {})})]
          (b.register :introspect {:name :b :snapshot (fn [_] {})})
          (assert.are.equal 2 (length (extensions.list :introspectors)))
          (h.unregister)
          (assert.are.equal 1 (length (extensions.list :introspectors)))
          (extensions.unregister-by-owner :ext-b)
          (assert.are.equal 0 (length (extensions.list :introspectors))))))

    (it "rejects missing name or snapshot"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.has_error (fn [] (api.register :introspect {:snapshot (fn [_] {})})))
          (assert.has_error (fn [] (api.register :introspect {:name :x}))))))))

(describe "core.extensions register :session-backend"
  (fn []
    (it "stores session backends and tracks the active backend/info"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              backend {:name :memory
                       :open (fn [_cwd] {})
                       :open-existing (fn [_ref] {})
                       :append (fn [_handle _msg] nil)
                       :close (fn [_handle] nil)
                       :load (fn [_ref] [])
                       :find (fn [_cwd _target] nil)
                       :list (fn [_cwd _limit] [])
                       :latest (fn [_cwd] nil)}]
          (api.register :session-backend backend)
          (assert.are.equal :memory (. (extensions.find-session-backend :memory) :name))
          (extensions.set-active-session-backend! :memory)
          (assert.are.equal :memory (. (extensions.active-session-backend) :name))
          (extensions.set-session-info! {:backend :memory :id "s1"})
          (assert.are.equal "s1" (. (extensions.session-info) :id))
          (let [lst (extensions.list :session-backends)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :memory (. lst 1 :name))
            (assert.are.equal :ext-a (. lst 1 :owner))))))))

(describe "core.extensions register :provider / :auth-backend"
  (fn []
    (it "stores providers by name and exposes api metadata"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              complete (fn [])]
          (api.register :provider {:name :openai
                                   :api :openai-completions
                                   :default-model :gpt-5.4-nano
                                   :api-key-var :OPENAI_API_KEY
                                   :complete complete})
          (let [p (extensions.find-provider :openai)]
            (assert.are.equal :openai p.name)
            (assert.are.equal :ext-a p.__owner)
            (assert.are.equal complete p.complete))
          (assert.is_nil (extensions.find-provider :openai-completions))
          (let [by-api (extensions.list-providers-by-api :openai-completions)]
            (assert.are.equal 1 (length by-api))
            (assert.are.equal :openai (. by-api 1 :name)))
          (let [lst (extensions.list :providers)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :openai (. lst 1 :name))
            (assert.are.equal :openai-completions (. lst 1 :api))))))

    (it "replaces duplicate provider names"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :provider {:name :p :api :old :complete (fn [])})
          (api.register :provider {:name :p :api :new :complete (fn [])})
          (assert.are.equal :new (. (extensions.find-provider :p) :api)))))

    (it "stores auth backends and unregisters both kinds by owner"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :provider {:name :p :api :p-api :complete (fn [])})
          (api.register :auth-backend {:name :auth
                                       :configured? (fn [] true)
                                       :get-fresh-creds! (fn [] {})})
          (assert.is_truthy (extensions.find-provider :p))
          (assert.is_truthy (extensions.find-auth-backend :auth))
          (extensions.unregister-by-owner :ext-a)
          (assert.is_nil (extensions.find-provider :p))
          (assert.is_nil (extensions.find-auth-backend :auth)))))))

(describe "core.extensions on/emit"
  (fn []
    (it "fires handlers registered for a specific event type"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :tool-call (fn [ev] (table.insert seen ev)))
          (extensions.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :bash (. seen 1 :name)))))

    (it "fires :* wildcard subscribers for every event"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :* (fn [ev] (table.insert seen ev.type)))
          (extensions.emit {:type :llm-start})
          (extensions.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.same [:llm-start :tool-call] seen))))

    (it "isolates handlers via pcall — a throwing handler does not block siblings"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              fired []]
          (api.on :error (fn [_] (error "boom")))
          (api.on :error (fn [ev] (table.insert fired ev.error)))
          (extensions.emit {:type :error :error "real"})
          (assert.are.same ["real"] fired))))

    (it "adds runtime metadata to persisted error diagnostics"
      (fn []
        (extensions.emit {:type :error :error "real"})
        (let [rec (. (events.list-errors) 1)]
          (assert.is_table rec.runtime)
          (assert.is_string rec.runtime.version)
          (assert.is_string rec.runtime.source))))

    (it "emits extension-error diagnostics for throwing handlers"
      (fn []
        (let [bad (ext-api.make-runtime-api :bad-ext)
              diag (ext-api.make-runtime-api :diag-ext)
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
        (let [api (ext-api.make-runtime-api :bad-diag)
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
        (let [api (ext-api.make-runtime-api :ext-a)
              fired []
              unsub (api.on :ping (fn [_] (table.insert fired 1)))]
          (extensions.emit {:type :ping})
          (unsub)
          (extensions.emit {:type :ping})
          (assert.are.equal 1 (length fired)))))))

(describe "core.extensions prompt"
  (fn []
    (it "renders static text"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.prompt "hello extension")
          (assert.are.equal "hello extension"
                            (extensions.render-prompt {})))))

    (it "joins multiple fragments with blank-line separator"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.prompt "first")
          (b.prompt "second")
          (assert.are.equal "first\n\nsecond"
                            (extensions.render-prompt {})))))

    (it "evaluates dynamic (function) fragments at render time"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              counter {:n 0}]
          (api.prompt
            (fn []
              (set counter.n (+ counter.n 1))
              (.. "tick=" (tostring counter.n))))
          (assert.are.equal "tick=1" (extensions.render-prompt {}))
          (assert.are.equal "tick=2" (extensions.render-prompt {})))))

    (it "degrades a failing dynamic fragment to an HTML comment"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.prompt (fn [] (error "broke")))
          (let [text (extensions.render-prompt {})]
            (assert.is_truthy (string.find text "extension ext%-a failed"))
            (assert.is_truthy (string.find text "broke"))))))))

(describe "core.extensions register :hook + run-before-tool"
  (fn []
    (it "no hooks → not blocked"
      (fn []
        (let [r (extensions.run-before-tool :bash {} {})]
          (assert.is_false r.block?))))

    (it "veto from a hook stops the chain and reports reason"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
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
        (let [api (ext-api.make-runtime-api :ext-a)
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
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :tool {:name :greet :execute (fn [] {})})
          (let [lst (api.list :tools)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :greet (. lst 1 :name))
            (assert.are.equal :ext-a (. lst 1 :owner))
            (assert.has_error (fn [] (tset lst :extra :nope)))
            (assert.has_error (fn [] (tset lst 1 {:name :changed})))
            (assert.has_error (fn [] (tset (. lst 1) :name :changed)))))))

    (it ":prompt-fragments reports final render order"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.prompt "late" {:order 90})
          (api.prompt "early" {:order 25
                               :id :early
                               :title "Early fragment"
                               :description "Runs before the body."})
          (api.prompt (fn [] "middle") {:order 30})
          (let [lst (api.list :prompt-fragments)]
            (assert.are.equal 3 (length lst))
            (assert.are.equal 25 (. lst 1 :order))
            (assert.are.equal :early (. lst 1 :id))
            (assert.are.equal "Early fragment" (. lst 1 :title))
            (assert.are.equal "Runs before the body." (. lst 1 :description))
            (assert.is_false (. lst 1 :dynamic?))
            (assert.are.equal 30 (. lst 2 :order))
            (assert.is_true (. lst 2 :dynamic?))
            (assert.are.equal 90 (. lst 3 :order))))))))

(describe "core.extensions unregister-by-owner"
  (fn []
    (it "drops every contribution tagged with the owner"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :tool {:name :a-tool :execute (fn [] {})})
          (b.register :tool {:name :b-tool :execute (fn [] {})})
          (a.register :command {:name :a-cmd :handler (fn [])})
          (b.register :command {:name :b-cmd :handler (fn [])})
          (a.register :status {:name :a-status :render (fn [_] {:text "a"})})
          (b.register :status {:name :b-status :render (fn [_] {:text "b"})})
          (a.prompt "from-a")
          (b.prompt "from-b")
          (a.on :ping (fn [] nil))
          (b.on :ping (fn [] nil))
          (extensions.unregister-by-owner :ext-a)
          (let [tools (extensions.merged-tools [])
                handlers (extensions.list :event-handlers)
                ping-bucket (. handlers :ping)]
            (assert.are.equal 1 (length tools))
            (assert.are.equal :b-tool (. tools 1 :name))
            (let [commands (extensions.list :commands)
                  names {}]
              (each [_ cmd (ipairs commands)]
                (tset names cmd.name cmd))
              (assert.is_nil (. names :a-cmd))
              (assert.is_not_nil (. names :b-cmd)))
            (let [statuses (extensions.list :status)]
              (assert.are.equal 1 (length statuses))
              (assert.are.equal :b-status (. statuses 1 :name)))
            (assert.are.equal "from-b" (extensions.render-prompt {}))
            (assert.are.equal 1 (length ping-bucket))
            (assert.are.equal :ext-b (. ping-bucket 1 :owner))))))))

(describe "core.extensions ui slot"
  (fn []
    (it "has-ui? false when no presenter is registered"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.is_false (api.ui.has-ui?)))))

    (it "presenter ui table promotes when registered as :active?"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
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
        (let [api (ext-api.make-runtime-api :ext-a)
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
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :presenter {:name :no-run :active? true})
          (let [(ok? err) (extensions.run-active-presenter {})]
            (assert.is_false ok?)
            (assert.is_truthy (string.find (tostring err) "has no run"))))))))
)