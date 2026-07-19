;; Reusable blocking control plane for explicitly addressed durable sessions.

(local agent-mod (require :fen.core.agent))
(local events (require :fen.core.extensions.events))
(local session-backends (require :fen.core.extensions.register.session_backend))
(local turn-result (require :fen.util.turn_result))
(local interactive (require :fen.interactive))
(local session-lifecycle (require :fen.session_lifecycle))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local turn-submit (require :fen.turn_submit))

(local M {})

(fn failure [code message exit-code]
  (values {:ok false :error {:code code :message (tostring message)}}
          (or exit-code 2)))

(fn backend-for [opts]
  (let [name (or opts.session-backend :jsonl)
        backend (session-backends.find name)]
    (if backend
        (do (session-backends.set-active! name) backend)
        nil)))

(fn session-info [backend value]
  (let [info (if (and value value.path)
                 (or (and backend.info (backend.info value)) value)
                 value)]
    (when info
      (let [out {}]
        (each [key item (pairs info)]
          (when (not= key :file) (tset out key item)))
        (set out.backend (or out.backend backend.name))
        out))))

(fn require-backend [opts capabilities]
  (let [backend (backend-for opts)]
    (if (not backend)
        (failure :unknown_session_backend
                 (.. "unknown session backend: " (tostring opts.session-backend)) 2)
        (do
          (each [_ capability (ipairs capabilities)]
            (when (not= (type (. backend capability)) :function)
              (error (.. "session backend " (tostring backend.name)
                         " does not support " (tostring capability)))))
          (values backend nil)))))

(fn exact-record [backend cwd session-id]
  (when (and session-id (not= (tostring session-id) ""))
    (backend.get cwd (tostring session-id))))

(fn array-or-empty [items] items)

(fn M.new [opts]
  (let [(backend err) (require-backend opts [:create])]
    (if err
        (values backend err)
        (let [session (backend.create (session-lifecycle.cwd))]
          (if (not session)
              (failure :session_create_failed "session backend could not create a durable session" 1)
              (let [info (session-info backend session)]
                (backend.close session)
                (values {:ok true :session info} 0)))))))

(fn M.list [opts]
  (let [(backend err) (require-backend opts [])]
    (if err
        (values backend err)
        (let [cwd (session-lifecycle.cwd)
              items (backend.list cwd (or opts.limit 1000))]
          (each [_ item (ipairs items)]
            (set item.backend (or item.backend backend.name))
            (set item.cwd (or item.cwd cwd)))
          (values {:ok true :cwd cwd :sessions (array-or-empty items)} 0)))))

(fn M.show [session-id opts]
  (let [(backend err) (require-backend opts [:get])]
    (if err
        (values backend err)
        (let [cwd (session-lifecycle.cwd)
              (info lookup-error) (exact-record backend cwd session-id)]
          (if (= lookup-error :ambiguous)
              (failure :ambiguous_session
                       (.. "session " (tostring session-id)
                           " has multiple exact matches") 2)
              (not info)
              (failure :session_not_found
                       (.. "session " (tostring session-id)
                           " was not found for the current cwd") 2)
              (not= info.cwd cwd)
              (failure :session_cwd_mismatch
                       (.. "session " (tostring session-id)
                           " belongs to a different cwd") 2)
              (let [read-messages (or backend.messages-strict backend.messages
                                      backend.load-strict backend.load)
                    (ok? messages) (pcall read-messages info.path)]
                (if (not ok?)
                    (failure :malformed_session messages 2)
                    (let [tail opts.tail
                          shown []
                          first (if tail (math.max 1 (+ (- (length messages) tail) 1)) 1)]
                      (for [i first (length messages)]
                        (table.insert shown (. messages i)))
                      (values {:ok true
                               :session (session-info backend info)
                               :messages (array-or-empty shown)} 0)))))))))

(fn copy-suffix [messages first]
  (let [out []]
    (for [i first (length messages)]
      (table.insert out (. messages i)))
    (array-or-empty out)))

(fn run-turn! [backend info prompt opts resolve-provider-config]
  (let [release (backend.acquire-lock info)]
    (if (not release)
        (failure :session_busy
                 (.. "session " (tostring info.id) " is already being mutated") 2)
        (do
          (var session nil)
          (var installed? false)
          (var result nil)
          (var exit-code 1)
          (var loading? true)
          (let [(ok? thrown)
                (xpcall
                (fn []
                  ;; Re-read after locking so a prior writer's complete turn is
                  ;; always part of this process's context.
                  (let [read-messages (or backend.load-strict backend.load)
                        messages (read-messages info.path)]
                    (set loading? false)
                    (set session (backend.open-existing info.path))
                    (when (not session)
                      (error "session transcript could not be opened"))
                    (when (not= session.cwd (session-lifecycle.cwd))
                      (error "session cwd changed while acquiring its lock"))
                    (let [agent (interactive.make-agent-from-opts
                                  resolve-provider-config opts events.emit {})
                          replayed (length messages)]
                      (each [_ message (ipairs messages)]
                        (table.insert agent.messages message))
                      (session-backends.set-info! (session-info backend session) session)
                      (let [state {:agent agent :turn-id 0 :busy? false
                                   :cancel-requested? false}
                            flush (session-lifecycle.make-flush backend agent session replayed)]
                        (set state.flush flush)
                        (session-lifecycle.install! state)
                        (set installed? true)
                        (let [submitted (turn-submit.submit! state prompt nil agent-mod.step events.emit)]
                          (when (not submitted.ok)
                            (error submitted.error)))
                        (var turn-ok? true)
                        (var value nil)
                        (while state.turn
                          (events.emit {:type :runtime-tick :busy? true :agent agent})
                          (let [(resumed? resumed-value) (coroutine.resume state.turn)]
                            (when (or (not resumed?) (= (coroutine.status state.turn) :dead))
                              (set turn-ok? resumed?)
                              (set value resumed-value)
                              (set state.turn nil)
                              (set state.busy? false))))
                        (flush)
                        (let [complete (turn-lifecycle.emit-complete! state turn-ok? value)
                              turn-messages (copy-suffix agent.messages (+ replayed 1))
                              assistant (turn-result.last-assistant turn-messages)
                              failed? (turn-result.failed? turn-ok? turn-messages)]
                          (set result
                               {:ok (not failed?)
                                :session (session-info backend session)
                                :turn {:result (if failed? nil value)
                                       :status (if failed? :error complete.status)
                                       :stop-reason (?. assistant :stop-reason)
                                       :usage (turn-result.sum-usage turn-messages)
                                       :messages turn-messages}})
                          (when failed?
                            (set result.error
                                 {:code :turn_failed
                                  :message (tostring (or complete.error value "turn failed"))}))
                          (set exit-code (if failed? 1 0)))))))
                debug.traceback)]
          (when installed? (session-lifecycle.uninstall!))
          (when session (session-lifecycle.close! backend session))
          (release)
          (if ok?
              (values result exit-code)
              loading?
              (failure :malformed_session thrown 2)
              (failure :runtime_failure thrown 1)))))))

(fn M.send [session-id prompt opts resolve-provider-config]
  (let [(backend err) (require-backend opts [:get :acquire-lock])]
    (if err
        (values backend err)
        (let [cwd (session-lifecycle.cwd)
              (info lookup-error) (exact-record backend cwd session-id)]
          (if (= lookup-error :ambiguous)
              (failure :ambiguous_session
                       (.. "session " (tostring session-id)
                           " has multiple exact matches") 2)
              (not info)
              (failure :session_not_found
                       (.. "session " (tostring session-id)
                           " was not found for the current cwd") 2)
              (not= info.cwd cwd)
              (failure :session_cwd_mismatch
                       (.. "session " (tostring session-id)
                           " belongs to a different cwd") 2)
              (run-turn! backend info prompt opts resolve-provider-config))))))

M
