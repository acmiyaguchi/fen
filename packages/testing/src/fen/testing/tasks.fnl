;; Test helpers for fen.core.tasks: hold the session the way production does
;; (an offer the scheduler starts, or a requested exclusive job), so every
;; holder id in a test has its coroutine registered in the job table.

(local tasks (require :fen.core.tasks))

(local M {})

(fn idle-body []
  (fn [] (while true (coroutine.yield))))

;; @doc fen.testing.tasks.hold-turn!
;; kind: function
;; signature: (hold-turn! ?text ?body) -> co hid n
;; summary: Start a turn through offer-start! (?body, default: yield forever) and return its coroutine, holder id, and turn number. The holder stays until the coroutine finishes or tasks.reset!.
;; tags: testing tasks
(fn M.hold-turn! [?text ?body]
  (let [r (tasks.offer-start! (or ?text "test turn")
                              {:make-turn (fn [] (or ?body (idle-body)))})]
    (assert r.started? (.. "hold-turn!: no turn started: " (tostring r.error)))
    (values r.co r.hid r.turn)))

;; @doc fen.testing.tasks.hold-exclusive!
;; kind: function
;; signature: (hold-exclusive! ?run) -> co hid
;; summary: Start an exclusive job through request-job! (?run (fn [hid]), default: yield forever) and return its coroutine and holder id.
;; tags: testing tasks
(fn M.hold-exclusive! [?run]
  (let [r (tasks.request-job! {:run (or ?run
                                        (fn [] (while true (coroutine.yield))))})]
    (assert r.started? "hold-exclusive!: the job did not start")
    (values r.co r.hid)))

;; @doc fen.testing.tasks.run-turn
;; kind: function
;; signature: (run-turn f ?text) -> ok? ...
;; summary: Start a turn whose body is f and resume it to completion; returns the resume results.
;; tags: testing tasks
(fn M.run-turn [f ?text]
  (let [co (M.hold-turn! ?text f)]
    (var result (table.pack (coroutine.resume co)))
    (while (and (. result 1) (not= (coroutine.status co) :dead))
      (set result (table.pack (coroutine.resume co))))
    (table.unpack result 1 result.n)))

M
