(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register (require :fen.core.extensions.register))
(local session-backend-registry
       (require :fen.core.extensions.register.session_backend))
(local session-lifecycle (require :fen.session_lifecycle))
(local path (require :fen.util.path))

(fn make-backend [?opts]
  (let [opts (or ?opts {})
        calls {:opened [] :opened-existing [] :closed [] :appended []}
        backend {:name :fake}]
    (set backend.open
         (fn [cwd]
           (let [s {:id :new :path (.. cwd "/new.jsonl") :cwd cwd
                    :appended []}]
             (table.insert calls.opened s)
             s)))
    (set backend.open-existing
         (fn [ref ?yield]
           (when ?yield (?yield))
           (let [s {:id :existing :path ref :cwd :resumed :appended []}]
             (table.insert calls.opened-existing s)
             s)))
    (set backend.append
         (fn [session msg]
           (table.insert session.appended msg)
           (table.insert calls.appended msg)
           msg))
    (set backend.close
         (fn [session]
           (set session.closed? true)
           (table.insert calls.closed session)))
    (set backend.load (fn [_path] (or opts.messages [])))
    (set backend.find (fn [_cwd target ?yield]
                        (when ?yield (?yield))
                        target))
    (set backend.list (fn [_cwd _limit ?yield]
                        (when ?yield (?yield))
                        []))
    (set backend.latest (fn [_cwd] opts.latest-path))
    {:backend backend :calls calls}))

(fn register-backend [backend]
  (register.register :session-backend backend :session-lifecycle-test))

(describe "fen.session_lifecycle"
  (fn []
    (before_each (fn [] (test-api.reset!)))
    (after_each (fn [] (session-lifecycle.uninstall!)))

    (it "uses the physical process cwd rather than caller-controlled PWD"
      (fn []
        (let [old path.pwd-physical]
          (set path.pwd-physical (fn [dir]
                                   (assert.are.equal "." dir)
                                   "/physical/project"))
          (assert.are.equal "/physical/project" (session-lifecycle.cwd))
          (set path.pwd-physical old))))

    (it "resolves, opens, publishes info, and closes the selected backend"
      (fn []
        (let [fixture (make-backend)
              backend fixture.backend]
          (register-backend backend)
          (let [resolved (session-lifecycle.resolve-backend {:session-backend :fake})
                session (session-lifecycle.open {} resolved)]
            (assert.are.equal backend.open resolved.open)
            (assert.are.equal :fake resolved.name)
            (assert.are.equal :fake (. (session-backend-registry.active) :name))
            (assert.are.equal session.path (. (session-backend-registry.info) :path))
            (session-lifecycle.close! resolved session)
            (assert.is_true session.closed?)
            (assert.is_nil (session-backend-registry.info))))))

    (it "keeps backend discovery active but suppresses writes for no-session"
      (fn []
        (let [fixture (make-backend)
              backend fixture.backend]
          (register-backend backend)
          (let [resolved (session-lifecycle.resolve-backend
                           {:session-backend :fake :no-session? true})]
            (assert.are.equal backend.open resolved.open)
            (assert.are.equal :fake (. (session-backend-registry.active) :name))
            (assert.is_nil (session-backend-registry.info))
            (assert.is_nil (session-lifecycle.open {:no-session? true} resolved))
            (assert.are.equal 0 (length fixture.calls.opened))))))

    (it "replays --continue messages and appends to the existing session"
      (fn []
        (let [messages [{:role :user :content "old"}
                        {:role :assistant :content [{:type :text :text "ok"}]}]
              fixture (make-backend {:messages messages
                                     :latest-path "/tmp/fen-session.jsonl"})
              backend fixture.backend
              agent {:messages []}]
          (register-backend backend)
          (let [(session replayed)
                (session-lifecycle.start! {:session-backend :fake :continue? true}
                                          agent backend)]
            (assert.are.equal 2 replayed)
            (assert.are.equal "/tmp/fen-session.jsonl" session.path)
            (assert.are.equal 1 (length fixture.calls.opened-existing))
            (assert.are.equal :user (. agent.messages 1 :role))
            (assert.are.equal :assistant (. agent.messages 2 :role))))))

    (it "replays --continue without opening a writer when no-session is set"
      (fn []
        (let [messages [{:role :user :content "old"}]
              fixture (make-backend {:messages messages
                                     :latest-path "/tmp/fen-session.jsonl"})
              backend fixture.backend
              agent {:messages []}]
          (register-backend backend)
          (let [(session replayed)
                (session-lifecycle.start! {:session-backend :fake
                                           :continue? true
                                           :no-session? true}
                                          agent backend)]
            (assert.is_nil session)
            (assert.are.equal 1 replayed)
            (assert.are.equal 0 (length fixture.calls.opened-existing))
            (assert.are.equal :user (. agent.messages 1 :role))))))

    (it "holds user-only messages until an assistant message exists"
      (fn []
        (let [fixture (make-backend)
              backend fixture.backend
              session {:appended []}
              agent {:messages []}
              flush (session-lifecycle.make-flush backend agent session 0)]
          (table.insert agent.messages {:role :user :content "hi"})
          (flush)
          (assert.are.equal 0 (length session.appended))
          (table.insert agent.messages {:role :assistant :content "hello"})
          (flush)
          (assert.are.equal 2 (length session.appended))
          (table.insert agent.messages {:role :tool-result :content "done"})
          (flush)
          (assert.are.equal 3 (length session.appended))
          (assert.are.equal :tool-result (. session.appended 3 :role)))))

    (it "skips replayed messages when building a flush closure"
      (fn []
        (let [fixture (make-backend)
              backend fixture.backend
              session {:appended []}
              agent {:messages [{:role :user :content "old"}
                                {:role :assistant :content "old answer"}]}
              flush (session-lifecycle.make-flush backend agent session 2)]
          (table.insert agent.messages {:role :user :content "new"})
          (flush)
          (assert.are.equal 1 (length session.appended))
          (assert.are.equal "new" (. session.appended 1 :content)))))

    (it "bridges message-appended events to the current state flush"
      (fn []
        (let [agent {:messages []}
              other {:messages []}
              seen {:flush 0 :status 0}
              state {:agent agent
                     :flush (fn [] (set seen.flush (+ seen.flush 1)))
                     :update-queue-status
                     (fn [] (set seen.status (+ seen.status 1)))}]
          (session-lifecycle.install! state)
          (events.emit {:type :message-appended :agent other})
          (assert.are.equal 0 seen.flush)
          (events.emit {:type :message-appended :agent agent})
          (assert.are.equal 1 seen.flush)
          (assert.are.equal 1 seen.status)
          (session-lifecycle.uninstall!)
          (events.emit {:type :message-appended :agent agent})
          (assert.are.equal 1 seen.flush))))))
