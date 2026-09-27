;; Persistent decide state. Not reloadable.
;;
;; Holds the api handle from the most recent register (settings, logs, and the
;; provider registry resolve through it at call time) and the pending
;; `ask-async!` tasks. Tasks belong to one loaded extension instance: every
;; register (first load, /reload, re-enable) finishes leftovers with nil, so
;; a task never outlives the instance that started it.

{:api nil
 ;; [{:co coroutine :on-done fn}] resumed once per :runtime-tick.
 :tasks []}
