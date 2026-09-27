;; Persistent decide state. Not reloadable.
;;
;; Holds the api handle from the most recent register (settings, logs, and the
;; provider registry resolve through it at call time) and the pending
;; `ask-async!` tasks, so in-flight decisions keep running across /reload.

{:api nil
 ;; [{:co coroutine :on-done fn}] resumed once per :runtime-tick.
 :tasks []}
