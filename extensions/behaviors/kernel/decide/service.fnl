;; Advisory decision service backed by TypeSafe's Jev on OpenRouter.
;;
;; Consumers require this module, not the `fen.extensions.decide` entry: the
;; loader cache-busts entry modules on a fresh load!, while non-entry modules
;; keep one table identity that /reload mutates in place.
;;
;; Every decision is advisory. Any failure, including a disabled extension,
;; returns nil so callers keep their non-decide behavior. Errors raised by the
;; caller's yield function (cooperative cancellation) are the one exception:
;; they propagate unchanged.
;;
;; The api handle and pending async tasks live in the non-reloadable
;; `fen.extensions.decide.state`; this module is behavior only.

(local store (require :fen.extensions.decide.state))
(local jev (require :fen.extensions.decide.jev))
(local ext-state (require :fen.core.extensions.state))
(local coroutines (require :fen.util.coroutines))
(local clock (require :fen.util.clock))
(local path (require :fen.util.path))

(local M {})

(local DEFAULT-MODEL "~typesafe/jev-latest")
(local DEFAULT-TIMEOUT-MS 3000)
(local KEY-PROVIDER :openrouter)

;; @doc fen.extensions.decide.service.max-request-bytes
;; kind: data
;; signature: number
;; summary: Byte cap on one encoded decision request (state plus questions); larger requests are skipped and return nil, keeping input well under Jev's 32k-token context. Consumers split or truncate state to fit.
;; tags: decide service
(set M.max-request-bytes 60000)

;; @doc fen.extensions.decide.service.enabled?
;; kind: function
;; signature: (enabled?) -> boolean
;; summary: Whether the decide extension is currently loaded, resolved at call time from the loader's status record; false after it is disabled on /reload.
;; tags: decide service extensions
(fn M.enabled? []
  (and (not= store.api nil)
       (= (?. ext-state.extensions :decide :status) :loaded)))

(fn log! [level msg]
  (when store.api
    (store.api.log level msg)))

(fn fail [level msg]
  (log! level msg)
  nil)

(fn nonblank [s]
  (when (and (= (type s) :string) (not= s ""))
    s))

(fn string-map? [t]
  (and (= (type t) :table)
       (not= (next t) nil)
       (accumulate [ok? true k v (pairs t)]
         (and ok? (= (type k) :string) (= (type v) :string)))))

(fn valid-question? [q]
  (and (= (type q) :table)
       (or (= q.type :noul) (= q.type :choice))
       (nonblank q.instructions)
       (string-map? q.criteria)
       (or (not= q.type :noul)
           (and (. q.criteria :true) (. q.criteria :false)))))

(fn valid-questions? [questions]
  (and (= (type questions) :table)
       (not= (next questions) nil)
       (accumulate [ok? true id q (pairs questions)]
         (and ok? (= (type id) :string) (valid-question? q)))))

(fn read-settings []
  (let [(ok? s) (pcall store.api.settings.extension)
        s (if (and ok? (= (type s) :table)) s {})]
    {:model (or (nonblank s.model) DEFAULT-MODEL)
     :timeout-ms (if (and (= (type s.timeoutMs) :number) (> s.timeoutMs 0))
                     (math.floor s.timeoutMs)
                     DEFAULT-TIMEOUT-MS)}))

(fn api-key []
  "The OpenRouter provider's key, resolved the way the provider resolves it:
   a configured literal key, else its api-key-var from the environment."
  (accumulate [key nil _ p (ipairs (or (store.api.list :providers) []))]
    (or key
        (when (= p.name KEY-PROVIDER)
          (or (nonblank p.api-key)
              (and p.api-key-var (nonblank (path.getenv p.api-key-var))))))))

(fn post! [body key timeout-ms ?yield]
  "POST through jev, converting transport raises into {:error} while letting an
   error raised by the caller's yield propagate with its identity intact."
  (var yield-error nil)
  (let [wrapped (when ?yield
                  (fn []
                    (let [(ok? err) (pcall ?yield)]
                      (when (not ok?)
                        (set yield-error {:value err})
                        (error err 0)))))
        (ok? resp) (pcall jev.post body key timeout-ms wrapped)]
    (if ok?
        resp
        yield-error
        (error yield-error.value 0)
        {:error (tostring resp)})))

;; @doc fen.extensions.decide.service.ask
;; kind: function
;; signature: (ask state questions ?opts) -> answers|nil
;; summary: Ask Jev typed questions ({id {:type :noul|:choice :instructions str :criteria tbl}}) about one JSON-encodable state; cooperative when ?opts.yield is given, blocking otherwise. Returns answers keyed by id or nil on any failure; errors raised by ?opts.yield propagate.
;; tags: decide service
(fn M.ask [state questions ?opts]
  (if (not (M.enabled?))
      nil
      (not (valid-questions? questions))
      (fail :warn "decide: invalid questions; each needs :type :noul|:choice, :instructions, and string :criteria (noul: true/false)")
      (let [key (api-key)]
        (if (not key)
            (fail :warn "decide: no OpenRouter API key (the openrouter provider's OPENROUTER_API_KEY)")
            (let [settings (read-settings)
                  (encoded? body) (pcall jev.encode-request settings.model state questions)]
              (if (not encoded?)
                  (fail :warn (.. "decide: state is not JSON-encodable: " (tostring body)))
                  (> (length body) M.max-request-bytes)
                  (fail :debug (.. "decide: skipped a " (length body) "-byte request over the "
                                   M.max-request-bytes "-byte guard"))
                  (let [started (clock.monotonic-ms)
                        resp (post! body key settings.timeout-ms (?. ?opts :yield))
                        (answers info) (jev.parse-response resp questions)]
                    (if answers
                        (do
                          (log! :debug {:event :decision
                                        :model settings.model
                                        :elapsed-ms (- (clock.monotonic-ms) started)
                                        :request-bytes (length body)
                                        :usage (when (= (type info) :table) info)})
                          answers)
                        (fail (if (?. resp :error) :debug :warn) (.. "decide: " (tostring info)))))))))))

;; @doc fen.extensions.decide.service.ask-async!
;; kind: function
;; signature: (ask-async! state questions on-done) -> nil
;; summary: Run `ask` in a cooperative task advanced once per :runtime-tick and call (on-done answers-or-nil) at most once; immediately with nil when disabled. Presenters without ticks (--print, json) never run the task.
;; tags: decide service async
(fn M.ask-async! [state questions on-done]
  (if (not (M.enabled?))
      (on-done nil)
      (table.insert store.tasks
                    {:co (coroutines.create
                           (fn [] (M.ask state questions {:yield coroutine.yield})))
                     :on-done on-done}))
  nil)

(fn finish! [task answers]
  (let [(ok? err) (pcall task.on-done answers)]
    (when (not ok?)
      (log! :warn (.. "decide: on-done callback failed: " (tostring err))))))

(fn M.pump! []
  "Resume each pending async task once; finished tasks report and drop out.
   Callbacks that start new tasks land in the fresh list."
  (when (> (length store.tasks) 0)
    (let [tasks store.tasks]
      (set store.tasks [])
      (each [_ task (ipairs tasks)]
        (let [(ok? value) (coroutine.resume task.co)]
          (if (not ok?)
              (do (log! :warn (.. "decide: task failed: " (tostring value)))
                  (finish! task nil))
              (= (coroutine.status task.co) :dead)
              (finish! task value)
              (table.insert store.tasks task)))))))

M
