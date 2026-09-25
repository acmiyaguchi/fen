;; Tests for core.extensions — the v1 api skeleton (issue #15, Step 1).
;;
;; Covers: register :tool/:command/:hook, on/emit (incl. wildcard and pcall
;; isolation), prompt fragment rendering, list/freeze,
;; merged-tools, run-before-tool veto, unregister-by-owner.

(local events (require :fen.core.extensions.events))
(local diagnostics (require :fen.core.diagnostics))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-reg (require :fen.core.extensions.register.tool))
(local introspect-reg (require :fen.core.extensions.register.introspect))
(local session-reg (require :fen.core.extensions.register.session_backend))
(local provider-reg (require :fen.core.extensions.register.provider))
(local auth-reg (require :fen.core.extensions.register.auth_backend))
(local prompt-reg (require :fen.core.extensions.register.prompt))
(local hook-reg (require :fen.core.extensions.register.hook))
(local ext-input (require :fen.core.extensions.input))
(local presenter-reg (require :fen.core.extensions.register.presenter))
(local ext-api (require :fen.core.extensions.test_api))

(before_each (fn [] (ext-api.reset!)))

(describe "core.extensions test runtime api"
  (fn []
    (it "exposes the small public extension surface"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              keys []]
          (each [k _ (pairs api)] (table.insert keys k))
          (table.sort keys)
          (assert.are.same [:actions :auth :commands :diagnostics :emit :enqueue :introspect :list :log :models :on
                            :prompt :register :session :settings :turn :ui]
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
          (assert.are.equal true (. (api.introspect.collect :external) :external :state :ok))))

    (it "allows every extension to register actions but only privileged APIs to invoke them"
      (fn []
        (let [public (ext-api.make-runtime-api :external nil {:privileged? false})
              host (ext-api.make-runtime-api :host nil {:privileged? true})]
          (public.register :action {:name :ping
                                    :description "Return a typed state"
                                    :parameters {:type :object :properties {}}
                                    :invoke (fn [_args _ctx] {:pong true})})
          (assert.is_nil public.actions)
          (assert.has_error (fn [] (public.list :actions)))
          (let [result (host.actions.invoke :external :ping {} {:source :test})]
            (assert.is_true result.ok)
            (assert.are.equal :external result.owner)
            (assert.are.equal :ping result.action)
            (assert.is_true result.state.pong)))))))

(describe "core.extensions api.log"
  (fn []
    (it "tags records with the extension owner and exposes them through :logs"
      (fn []
        (let [api (ext-api.make-runtime-api :writer)
              rec (api.log :info "saved session")
              logs (api.list :logs)]
          (assert.are.equal "writer" rec.owner)
          (assert.are.equal "info" rec.level)
          (assert.are.equal "saved session" rec.msg)
          (assert.are.equal 1 (length logs))
          (assert.are.equal "writer" (. logs 1 :owner)))))))

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
              merged (tool-reg.merged base)]
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
          (assert.are.equal 1 (length (tool-reg.merged [])))
          (handle.unregister)
          (assert.are.equal 0 (length (tool-reg.merged []))))))

    (it "lists provider-facing tool docs without execute callbacks"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :tool {:name :greet
                               :label "Greeter"
                               :snippet "Say hello"
                               :description "say hi"
                               :parameters {:type :object
                                            :properties {:name {:type :string}}
                                            :required [:name]}
                               :parallel-safe? true
                               :parallel-cap 2
                               :execute (fn [] {})})
          (let [lst (register-registry.list :tools)
                item (. lst 1)]
            (assert.are.equal :greet item.name)
            (assert.are.equal :ext-a item.owner)
            (assert.are.equal "Greeter" item.label)
            (assert.are.equal "Say hello" item.snippet)
            (assert.are.equal "say hi" item.description)
            (assert.are.same [:name] item.parameters.required)
            (assert.is_true item.parallel-safe?)
            (assert.are.equal 2 item.parallel-cap)
            (assert.is_nil item.execute)))))))

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
          (let [commands (register-registry.list :commands)]
            (assert.are.equal 1 (length commands))
            (assert.are.equal :hi (. commands 1 :name))
            (assert.are.equal "second" (. commands 1 :description))))))

    (it "lists command usage and subcommand descriptor metadata"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              descriptor {:name :mem
                          :usage "/mem [gc|help]"
                          :has-help-subcommand? false
                          :subcommands [{:name "gc" :description "force GC"}]}]
          (api.register :command {:name :mem
                                  :description "memory"
                                  :usage descriptor.usage
                                  :subcommands descriptor
                                  :handler (fn [])})
          (let [cmd (. (register-registry.list :commands) 1)]
            (assert.are.equal "/mem [gc|help]" cmd.usage)
            (assert.are.equal "/mem [gc|help]" cmd.subcommands.usage)
            (assert.are.equal "gc" (. cmd.subcommands.subcommands 1 :name))
            (assert.is_true cmd.completes?)))))

    (it "uses subcommand descriptors as an argument-completion fallback"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :command {:name :mem
                                  :description "memory"
                                  :subcommands {:name :mem
                                                :has-help-subcommand? false
                                                :subcommands [{:name "gc" :description "force GC"}]}
                                  :handler (fn [])})
          (let [choices (command-registry.arg-completions :mem "" {})]
            (assert.are.equal 2 (length choices))
            (assert.are.equal "gc" (. choices 1 :label))
            (assert.are.equal "force GC" (. choices 1 :description))
            (assert.are.equal "help" (. choices 2 :label)))))))

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
          (let [lst (register-registry.list :status)]
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
          (register-registry.unregister-by-owner :ext-a)
          (let [lst (register-registry.list :status)]
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
          (let [lst (register-registry.list :panels)]
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
          (let [lst (register-registry.list :panels)]
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
          (register-registry.unregister-by-owner :ext-a)
          (let [lst (register-registry.list :panels)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :b (. lst 1 :name))))))))

(describe "core.extensions register :action"
  (fn []
    (it "lists descriptors, validates arguments, replaces duplicates, and cleans up owners"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)
              spec {:name :set
                    :description "Set a value"
                    :parameters {:type :object
                                 :properties {:value {:type :integer}}
                                 :required [:value]}
                    :invoke (fn [args ctx] {:value args.value :ctx ctx.label})}]
          (a.register :action spec)
          (b.register :action {:name :set
                               :description "Other owner"
                               :parameters {:type :object :properties {}}
                               :invoke (fn [_ _] {:other true})})
          (a.register :action {:name :set
                               :description "Replacement"
                               :parameters spec.parameters
                               :invoke spec.invoke})
          (let [listed (a.actions.list)]
            (assert.are.equal 2 (length listed))
            (assert.are.equal :ext-a (. listed 1 :owner))
            (assert.are.equal "Replacement" (. listed 1 :description))
            (assert.is_nil (. listed 1 :invoke)))
          (let [ok (a.actions.invoke :ext-a :set {:value 4} {:label "ctx"})
                invalid (a.actions.invoke :ext-a :set {} {})
                unknown (a.actions.invoke :missing :set {} {})]
            (assert.is_true ok.ok)
            (assert.are.equal 4 ok.state.value)
            (assert.are.equal "ctx" ok.state.ctx)
            (assert.is_false invalid.ok)
            (assert.are.equal "invalid action arguments" invalid.error)
            (assert.are.equal "value" (. invalid.details 1 :field))
            (assert.is_false unknown.ok)
            (assert.are.equal "unknown action" unknown.error))
          (register-registry.unregister-by-owner :ext-a)
          (assert.are.equal 1 (length (a.actions.list)))
          (register-registry.unregister-by-owner :ext-b)
          (assert.are.equal 0 (length (a.actions.list))))))))

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
          (let [lst (register-registry.list :introspectors)]
            (assert.are.equal 2 (length lst))
            (assert.are.equal :ext-a (. lst 1 :owner))
            (assert.are.equal :summary (. lst 1 :name))
            (assert.are.equal "state summary" (. lst 1 :description)))
          (let [snapshots (introspect-reg.collect nil {:n 42})]
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
          (assert.are.equal 2 (length (register-registry.list :introspectors)))
          (h.unregister)
          (assert.are.equal 1 (length (register-registry.list :introspectors)))
          (register-registry.unregister-by-owner :ext-b)
          (assert.are.equal 0 (length (register-registry.list :introspectors))))))

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
          (assert.are.equal :memory (. (session-reg.find :memory) :name))
          (session-reg.set-active! :memory)
          (assert.are.equal :memory (. (session-reg.active) :name))
          (session-reg.set-info! {:backend :memory :id "s1"})
          (assert.are.equal "s1" (. (session-reg.info) :id))
          (let [lst (register-registry.list :session-backends)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :memory (. lst 1 :name))
            (assert.are.equal :ext-a (. lst 1 :owner)))))))

    (it "appends and reads owner-scoped state through the active session handle"
      (fn []
        (let [entries []
              handle {:id "s1"}
              yield-fn (fn [] nil)
              backend {:name :memory
                       :open (fn [_cwd] handle)
                       :open-existing (fn [_ref] handle)
                       :append (fn [_handle _msg] nil)
                       :append-entry (fn [actual entry]
                                       (assert.are.equal handle actual)
                                       (table.insert entries entry)
                                       entry)
                       :latest-extension-state
                       (fn [actual owner actual-yield actual-accept]
                         (assert.are.equal handle actual)
                         (assert.are.equal yield-fn actual-yield)
                         (assert.is_function actual-accept)
                         (var found nil)
                         (each [_ entry (ipairs entries)]
                           (when (= (tostring entry.extension) (tostring owner))
                             (set found entry)))
                         found)
                       :close (fn [_handle] nil)
                       :load (fn [_ref] [])
                       :find (fn [_cwd _target] nil)
                       :list (fn [_cwd _limit] [])
                       :latest (fn [_cwd] nil)}
              backend-api (ext-api.make-runtime-api :backend nil {:privileged? true})
              a (ext-api.make-runtime-api :goal)
              b (ext-api.make-runtime-api :plan)]
          (backend-api.register :session-backend backend)
          (session-reg.set-active! :memory)
          (session-reg.set-info! {:backend :memory :id "s1"} handle)
          (a.session.append-state! {:status :running})
          (b.session.append-state! {:mode :ready} 2)
          (a.session.append-state! {:status :stopped})
          (let [accept (fn [value _entry] (= value.status :stopped))
                (goal-state goal-entry) (a.session.latest-state yield-fn accept)
                (plan-state plan-entry) (b.session.latest-state yield-fn (fn [_value _entry] true))]
            (assert.are.equal :stopped goal-state.status)
            (assert.are.equal :goal goal-entry.extension)
            (assert.are.equal 1 goal-entry.version)
            (assert.are.equal :ready plan-state.mode)
            (assert.are.equal :plan plan-entry.extension)
            (assert.are.equal 2 plan-entry.version)))))

    (it "rejects malformed extension state and does not leak across handles"
      (fn []
        (let [seen-handles []
              backend {:name :memory
                       :open (fn [_cwd] {})
                       :open-existing (fn [_ref] {})
                       :append (fn [_handle _msg] nil)
                       :append-entry (fn [handle entry]
                                       (table.insert seen-handles handle)
                                       entry)
                       :latest-extension-state (fn [_handle _owner] nil)
                       :close (fn [_handle] nil)
                       :load (fn [_ref] [])
                       :find (fn [_cwd _target] nil)
                       :list (fn [_cwd _limit] [])
                       :latest (fn [_cwd] nil)}
              backend-api (ext-api.make-runtime-api :backend nil {:privileged? true})
              api (ext-api.make-runtime-api :goal)
              first {:id "first"}
              second {:id "second"}]
          (backend-api.register :session-backend backend)
          (session-reg.set-active! :memory)
          (session-reg.set-info! {:id "first"} first)
          (api.session.append-state! {:ok true})
          (session-reg.set-info! {:id "second"} second)
          (api.session.append-state! {:ok true})
          (assert.are.equal first (. seen-handles 1))
          (assert.are.equal second (. seen-handles 2))
          (assert.has_error (fn [] (api.session.append-state! {:bad (fn [] nil)})))
          (assert.has_error (fn [] (api.session.append-state! "scalar")))
          (assert.has_error (fn [] (api.session.append-state! {:ok true} 1.5)))))))

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
          (let [p (provider-reg.find :openai)]
            (assert.are.equal :openai p.name)
            (assert.are.equal :ext-a p.__owner)
            (assert.are.equal complete p.complete))
          (assert.is_nil (provider-reg.find :openai-completions))
          (let [lst (register-registry.list :providers)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :openai (. lst 1 :name))
            (assert.are.equal :openai-completions (. lst 1 :api))))))

    (it "replaces duplicate provider names"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :provider {:name :p :api :old :complete (fn [])})
          (api.register :provider {:name :p :api :new :complete (fn [])})
          (assert.are.equal :new (. (provider-reg.find :p) :api)))))

    (it "stores auth backends and unregisters both kinds by owner"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :provider {:name :p :api :p-api :complete (fn [])})
          (api.register :auth-backend {:name :auth
                                       :configured? (fn [] true)
                                       :get-fresh-creds! (fn [] {})})
          (assert.is_truthy (provider-reg.find :p))
          (assert.is_truthy (auth-reg.find :auth))
          (register-registry.unregister-by-owner :ext-a)
          (assert.is_nil (provider-reg.find :p))
          (assert.is_nil (auth-reg.find :auth)))))))

(describe "core.extensions on/emit"
  (fn []
    (it "fires handlers registered for a specific event type"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :tool-call (fn [ev] (table.insert seen ev)))
          (events.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :bash (. seen 1 :name)))))

    (it "fires :* wildcard subscribers for every event"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :* (fn [ev] (table.insert seen ev.type)))
          (events.emit {:type :llm-start})
          (events.emit {:type :tool-call :name :bash :id "1"})
          (assert.are.same [:llm-start :tool-call] seen))))

    (it "does not skip the next handler when one unsubscribes itself"
      (fn []
        (var off nil)
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (set off (api.on :ping
                           (fn [_]
                             (table.insert seen :first)
                             (off))))
          (api.on :ping (fn [_] (table.insert seen :second)))
          (events.emit {:type :ping})
          (assert.are.same [:first :second] seen))))

    (it "skips all handlers removed by unregister-by-owner but keeps others"
      (fn []
        (let [remover (ext-api.make-runtime-api :remover)
              removed (ext-api.make-runtime-api :removed)
              remaining (ext-api.make-runtime-api :remaining)
              seen []]
          (remover.on :ping
                      (fn [_]
                        (register-registry.unregister-by-owner :removed)
                        (table.insert seen :remover)))
          (removed.on :ping (fn [_] (table.insert seen :removed-one)))
          (removed.on :ping (fn [_] (table.insert seen :removed-two)))
          (remaining.on :ping (fn [_] (table.insert seen :remaining)))
          (events.emit {:type :ping})
          (assert.are.same [:remover :remaining] seen))))

    (it "skips a handler removed by an earlier handler"
      (fn []
        (var off-third nil)
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :ping
                  (fn [_]
                    (table.insert seen :first)
                    (off-third)))
          (api.on :ping (fn [_] (table.insert seen :second)))
          (set off-third (api.on :ping (fn [_] (table.insert seen :third))))
          (events.emit {:type :ping})
          (assert.are.same [:first :second] seen))))

    (it "defers handlers added during dispatch until the next emit"
      (fn []
        (var added? false)
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.on :ping
                  (fn [_]
                    (table.insert seen :first)
                    (when (not added?)
                      (set added? true)
                      (api.on :ping (fn [_] (table.insert seen :added))))))
          (api.on :ping (fn [_] (table.insert seen :second)))
          (events.emit {:type :ping})
          (assert.are.same [:first :second] seen)
          (events.emit {:type :ping})
          (assert.are.same [:first :second :first :second :added] seen))))

    (it "does not dispatch wildcard handlers for typeless emits"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.on :* (fn [_] (error "wildcard should not run")))
          (events.emit nil)
          (events.emit {})
          (assert.are.equal 0 (length (events.list-errors))))))

    (it "isolates handlers via pcall — a throwing handler does not block siblings"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              fired []]
          (api.on :error (fn [_] (error "boom")))
          (api.on :error (fn [ev] (table.insert fired ev.error)))
          (events.emit {:type :error :error "real"})
          (assert.are.same ["real"] fired))))

    (it "adds runtime metadata to persisted error diagnostics"
      (fn []
        (diagnostics.set-runtime-info! {:version "test-version" :source "test"})
        (events.emit {:type :error :error "real"})
        (let [rec (. (events.list-errors) 1)]
          (assert.is_table rec.runtime)
          (assert.are.equal "test-version" rec.runtime.version)
          (assert.are.equal "test" rec.runtime.source))))

    (it "emits extension-error diagnostics for throwing handlers"
      (fn []
        (let [bad (ext-api.make-runtime-api :bad-ext)
              diag (ext-api.make-runtime-api :diag-ext)
              seen []]
          (bad.on :ping (fn [_] (error "boom")))
          (diag.on :extension-error (fn [ev] (table.insert seen ev)))
          (events.emit {:type :ping})
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
          (events.emit {:type :extension-error
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
          (events.emit {:type :ping})
          (unsub)
          (events.emit {:type :ping})
          (assert.are.equal 1 (length fired)))))))

(describe "core.extensions prompt"
  (fn []
    (it "renders static text"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.prompt "hello extension")
          (assert.are.equal "hello extension"
                            (prompt-reg.render {})))))

    (it "joins multiple fragments with blank-line separator"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.prompt "first")
          (b.prompt "second")
          (assert.are.equal "first\n\nsecond"
                            (prompt-reg.render {})))))

    (it "evaluates dynamic (function) fragments at render time"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              counter {:n 0}]
          (api.prompt
            (fn []
              (set counter.n (+ counter.n 1))
              (.. "tick=" (tostring counter.n))))
          (assert.are.equal "tick=1" (prompt-reg.render {}))
          (assert.are.equal "tick=2" (prompt-reg.render {})))))

    (it "degrades a failing dynamic fragment to an HTML comment"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.prompt (fn [] (error "broke")))
          (let [text (prompt-reg.render {})]
            (assert.is_truthy (string.find text "extension ext%-a failed"))
            (assert.is_truthy (string.find text "broke"))))))))

(describe "core.extensions register :hook + run-before-tool"
  (fn []
    (it "no hooks → not blocked"
      (fn []
        (let [r (hook-reg.run-before-tool {:name :bash :arguments {}})]
          (assert.is_false r.block?))))

    (it "veto from a hook stops the chain and reports reason"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :hook
                        {:before-tool
                         (fn [ctx]
                           (when (= ctx.name :bash)
                             {:block true :reason "no shell"}))})
          (let [r (hook-reg.run-before-tool {:name :bash :arguments {:cmd "ls"}})]
            (assert.is_true r.block?)
            (assert.are.equal "no shell" r.reason)))))

    (it "subsequent hooks after a veto are skipped"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              second-fired? {:n false}]
          (api.register :hook
                        {:before-tool (fn [_] {:block true :reason "x"})})
          (api.register :hook
                        {:before-tool (fn [_] (set second-fired?.n true))})
          (hook-reg.run-before-tool {:name :bash :arguments {}})
          (assert.is_false second-fired?.n))))))

(describe "core.extensions register :input-handler + handle-input"
  (fn []
    (it "no handlers → implicit :continue with input unchanged"
      (fn []
        (let [r (ext-input.handle {:kind :user-input :text "hi"} {})]
          (assert.are.equal :continue r.action)
          (assert.are.equal "hi" (. r :input :text)))))

    (it "a handler can start a turn"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :input-handler
                        {:name :starter
                         :handle (fn [input _] {:action :start :text input.text})})
          (let [r (ext-input.handle
                    {:kind :user-input :text "go"} {:busy? false})]
            (assert.are.equal :start r.action)
            (assert.are.equal "go" r.text)))))

    (it "runs handlers in ascending order and threads :continue transforms"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              seen []]
          (api.register :input-handler
                        {:name :late
                         :order 1000
                         :handle (fn [input _]
                                   (table.insert seen input.text)
                                   {:action :start :text input.text})})
          (api.register :input-handler
                        {:name :early
                         :order 10
                         :handle (fn [input _]
                                   (table.insert seen input.text)
                                   {:action :continue
                                    :input {:kind :user-input
                                            :text (.. input.text "!")}})})
          (let [r (ext-input.handle
                    {:kind :user-input :text "x"} {})]
            (assert.are.equal :start r.action)
            (assert.are.equal "x!" r.text)
            (assert.are.same ["x" "x!"] seen)))))

    (it "the first resolving action stops the chain"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              second-fired? {:n false}]
          (api.register :input-handler
                        {:name :consume :order 10
                         :handle (fn [_ _] {:action :consumed})})
          (api.register :input-handler
                        {:name :after :order 20
                         :handle (fn [_ _] (set second-fired?.n true)
                                   {:action :start :text "nope"})})
          (let [r (ext-input.handle {:kind :user-input :text "x"} {})]
            (assert.are.equal :consumed r.action)
            (assert.is_false second-fired?.n)))))

    (it "explicit :ignore stops the chain without falling through"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              second-fired? {:n false}]
          (api.register :input-handler
                        {:name :ignore :order 10
                         :handle (fn [_ _] {:action :ignore})})
          (api.register :input-handler
                        {:name :after :order 20
                         :handle (fn [_ _] (set second-fired?.n true)
                                   {:action :start :text "nope"})})
          (let [r (ext-input.handle {:kind :user-input :text "x"} {})]
            (assert.are.equal :ignore r.action)
            (assert.is_false second-fired?.n)))))

    (it "a throwing handler is skipped, not fatal"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :input-handler
                        {:name :boom :order 10
                         :handle (fn [_ _] (error "boom"))})
          (api.register :input-handler
                        {:name :ok :order 20
                         :handle (fn [input _] {:action :start :text input.text})})
          (let [r (ext-input.handle {:kind :user-input :text "x"} {})]
            (assert.are.equal :start r.action)
            (assert.are.equal "x" r.text)))))

    (it "requires name and handle"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.has_error (fn [] (api.register :input-handler {:name :x})))
          (assert.has_error
            (fn [] (api.register :input-handler {:handle (fn [] nil)}))))))

    (it ":input-handlers list is order-sorted and hides handler fns"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :input-handler
                        {:name :b :order 20 :handle (fn [] nil)})
          (api.register :input-handler
                        {:name :a :order 10 :handle (fn [] nil)})
          (let [lst (api.list :input-handlers)]
            (assert.are.equal 2 (length lst))
            (assert.are.equal :a (. lst 1 :name))
            (assert.are.equal :b (. lst 2 :name))
            (assert.are.equal nil (. lst 1 :handle))))))

    (it "unregister-by-owner drops the owner's handlers"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :input-handler
                        {:name :a :handle (fn [] nil)})
          (register-registry.unregister-by-owner :ext-a)
          (assert.are.equal 0 (length (api.list :input-handlers))))))

    (it "lazily creates the state bucket for hot-reloaded sessions"
      (fn []
        (let [state (require :fen.core.extensions.state)
              api (ext-api.make-runtime-api :ext-a)]
          (set state.input-handlers nil)
          (api.register :input-handler
                        {:name :a
                         :handle (fn [input _] {:action :start :text input.text})})
          (let [r (ext-input.handle {:kind :user-input :text "x"} {})]
            (assert.are.equal :start r.action)
            (assert.are.equal "x" r.text)))))))

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
          (register-registry.unregister-by-owner :ext-a)
          (let [tools (tool-reg.merged [])
                handlers (register-registry.list :event-handlers)
                ping-bucket (. handlers :ping)]
            (assert.are.equal 1 (length tools))
            (assert.are.equal :b-tool (. tools 1 :name))
            (let [commands (register-registry.list :commands)
                  names {}]
              (each [_ cmd (ipairs commands)]
                (tset names cmd.name cmd))
              (assert.is_nil (. names :a-cmd))
              (assert.is_not_nil (. names :b-cmd)))
            (let [statuses (register-registry.list :status)]
              (assert.are.equal 1 (length statuses))
              (assert.are.equal :b-status (. statuses 1 :name)))
            (assert.are.equal "from-b" (prompt-reg.render {}))
            (assert.are.equal 1 (length ping-bucket))
            (assert.are.equal :ext-b (. ping-bucket 1 :owner))))))))

(describe "core.extensions ui slot"
  (fn []
    (it "has-ui? false when no presenter is registered"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (assert.is_false (api.ui.has-ui?)))))

    (it "prompt/select fall back to nil without reading stdin when no presenter is active"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)
              orig-read io.read
              orig-stderr io.stderr
              warnings []]
          (var read-called false)
          (tset io :read (fn [...] (set read-called true) nil))
          (tset io :stderr {:write (fn [self text]
                                     (table.insert warnings text)
                                     self)})
          (let [(ok prompt-result select-result)
                (pcall (fn []
                         (values (api.ui.prompt {:label "name"})
                                 (api.ui.select {:label "pick"
                                                 :choices ["a" "b"]}))))]
            (tset io :read orig-read)
            (tset io :stderr orig-stderr)
            (assert.is_true ok)
            (assert.is_false read-called)
            (assert.is_nil prompt-result)
            (assert.is_nil select-result)
            (assert.are.equal 2 (length warnings))
            (assert.is_not_nil (string.find (. warnings 1) "no active presenter" 1 true))))))

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
          (let [(init-ok? init-err) (presenter-reg.init-active-presenter {:label "x"})
                (run-ok? run-err) (presenter-reg.run-active-presenter {:label "x"})
                (shutdown-ok? shutdown-err)
                (presenter-reg.shutdown-active-presenter {:label "x"})]
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
          (let [(ok? err) (presenter-reg.run-active-presenter {})]
            (assert.is_false ok?)
            (assert.is_truthy (string.find (tostring err) "has no run"))))))))
)
(describe "core.extensions list memoization"
  (fn []
    (it "returns the same frozen snapshot while the registry is unchanged"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :status {:name :s :render (fn [_] {:text "s"})})
          (let [l1 (register-registry.list :status)
                l2 (register-registry.list :status)]
            (assert.is_true (= l1 l2))))))

    (it "rebuilds the snapshot after register and unregister"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :status {:name :s1 :render (fn [_] {:text "1"})})
          (let [l1 (register-registry.list :status)
                handle (api.register :status {:name :s2 :render (fn [_] {:text "2"})})
                l2 (register-registry.list :status)]
            (assert.is_false (= l1 l2))
            (assert.are.equal 2 (length l2))
            (handle.unregister)
            (let [l3 (register-registry.list :status)]
              (assert.are.equal 1 (length l3))
              (assert.are.equal :s1 (. l3 1 :name)))))))

    (it "rebuilds the snapshot after unregister-by-owner"
      (fn []
        (let [a (ext-api.make-runtime-api :ext-a)
              b (ext-api.make-runtime-api :ext-b)]
          (a.register :panel {:name :pa :height (fn [_] 1) :render (fn [_] [])})
          (b.register :panel {:name :pb :height (fn [_] 1) :render (fn [_] [])})
          (assert.are.equal 2 (length (register-registry.list :panels)))
          (register-registry.unregister-by-owner :ext-a)
          (let [lst (register-registry.list :panels)]
            (assert.are.equal 1 (length lst))
            (assert.are.equal :pb (. lst 1 :name))))))

    (it "list-raw shares one unfrozen table per registry version"
      (fn []
        (let [api (ext-api.make-runtime-api :ext-a)]
          (api.register :status {:name :s :render (fn [_] {:text "s"})})
          (let [r1 (register-registry.list-raw :status)
                r2 (register-registry.list-raw :status)]
            (assert.is_true (rawequal r1 r2))
            (assert.are.equal :s (. r1 1 :name))
            (assert.is_nil (getmetatable r1))))))))
