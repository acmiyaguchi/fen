;; Capstone host contract: boot the core in an env-less VM with every relevant
;; backend supplied through package.loaded, then complete a tool-using turn.
(local h (require :fen.testing))
(local types (require :fen.core.types))
(local extensions (require :fen.core.extensions.test_api))
(local register (require :fen.core.extensions.register))
(local session-backend (require :fen.core.extensions.register.session_backend))
(local tool-registry (require :fen.core.extensions.register.tool))

(fn event-types [events]
  (let [out []]
    (each [_ event (ipairs events)]
      (when (not= event.type :message-appended)
        (table.insert out event.type)))
    out))

(fn session-spec []
  {:name :host-memory
   :open (fn [] {:id "opened"})
   :open-existing (fn [] {:id "existing"})
   :append (fn [] nil)
   :close (fn [] nil)
   :load (fn [] [])
   :find (fn [] nil)
   :list (fn [] [])
   :latest (fn [] nil)})

(describe "embedding host headless boot"
  (fn []
    (local original-getenv os.getenv)
    (local original-popen io.popen)

    (before_each
      (fn []
        (extensions.reset!)
        ;; All host-facing defaults are supplied before the first core boot.
        (h.stub-path-vfs!
          {:getenv (fn [name]
                     (if (= name :HOME) "/host"
                         (= name :XDG_CONFIG_HOME) "/host/config"
                         nil))
           :stat (fn [_] nil)
           :list-dir (fn [_] [])
           :pwd-physical (fn [_] "/host")})
        (h.stub-clock! {:monotonic-ms (fn [] 100) :sleep-ms (fn [_] nil)})
        (h.stub-process! {:setenv (fn [] (values true nil nil))})
        (h.stub-random! {:bytes (fn [n] (string.rep "r" n))})
        (h.stub-checksum! {:file-fingerprint (fn [_] nil)
                           :module-path (fn [_] nil)
                           :module-fingerprint (fn [_] {:fingerprint "host-etag"})})
        (h.stub-storage! {:read (fn [_] nil) :write! (fn [] nil)})
        (h.stub-discover-enumeration! {:enumerate (fn [] [])})
        ;; Force reloadable modules that capture these seams to boot after injection.
        (tset package.loaded :fen.util.text nil)
        (tset package.loaded :fen.core.agent nil)))

    (after_each
      (fn []
        (set os.getenv original-getenv)
        (set io.popen original-popen)
        (session-backend.set-info! nil)
        (extensions.reset!)
        (h.restore-http!)
        (h.restore-path-vfs!)
        (h.restore-clock!)
        (h.restore-process!)
        (h.restore-random!)
        (h.restore-checksum!)
        (h.restore-storage!)
        (h.restore-discover-enumeration!)
        (tset package.loaded :fen.core.agent nil)))

    (it "needs no OS environment, popen, or filesystem for boot plus one complete turn"
      (fn []
        (local provider-calls [])
        (local tool-calls [])
        (local events [])
        ;; Registration is the same public route used by a host extension.
        (let [api (extensions.make-runtime-api :host)
              _ (api.register :session-backend (session-spec))
              _ (api.register :tool
                              {:name :host_echo :description "host echo"
                               :parameters {:type :object
                                            :properties {:value {:type :string}}
                                            :required [:value]}
                               :execute (fn [args ctx]
                                          (table.insert tool-calls {:args args :ctx ctx})
                                          {:content [(types.text-block (.. "echo:" args.value))]
                                           :is-error? false})})
              _ (api.register :provider
                              {:name :host-provider :api :host
                               :complete
                               (fn [model context options]
                                 (table.insert provider-calls
                                               {:model model :context context :options options})
                                 (if (= (length provider-calls) 1)
                                     (types.assistant-message
                                       {:api :host :provider :host-provider :model model
                                        :content [(types.tool-call-block "host-call" :host_echo
                                                                          {:value "ok"})]
                                        :stop-reason :tool-use})
                                     (types.assistant-message
                                       {:api :host :provider :host-provider :model model
                                        :content [(types.text-block "host reply")]
                                        :stop-reason :stop})))})]
          ;; Poison direct host APIs immediately before the first agent require.
          (set os.getenv (fn [_] (error "unexpected os.getenv")))
          (set io.popen (fn [_] (error "unexpected io.popen")))
          (let [agent-mod (require :fen.core.agent)
                _ (session-backend.set-active! :host-memory)
                _ (session-backend.set-info! {:id "host-session"})
                agent (agent-mod.make-agent
                        {:provider-name :host-provider :model "host-model"
                         :api-key "unused"
                         :tools (tool-registry.merged [])
                         :on-event (fn [event] (table.insert events event))})
                reply (agent-mod.step agent "hello")]
            (assert.are.equal "host reply" reply)
            (assert.are.equal 2 (length provider-calls))
            (assert.are.equal "host-session" (. provider-calls 1 :options :prompt-cache-key))
            (assert.are.equal 1 (length tool-calls))
            (assert.are.equal "ok" (. tool-calls 1 :args :value))
            (assert.are.same [:llm-start :llm-end :tool-call :tool-result
                              :llm-start :llm-end :assistant-text]
                             (event-types events))
            (assert.are.equal :user (. agent.messages 1 :role))
            (assert.are.equal :tool-result (. agent.messages 3 :role))
            (assert.are.equal "host-call" (. agent.messages 3 :tool-call-id))
            (assert.are.equal :assistant (. agent.messages 4 :role))))))))
