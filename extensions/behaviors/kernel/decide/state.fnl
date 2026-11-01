;; Persistent decide state. Not reloadable.
;;
;; Holds the api handle from the most recent register (settings, logs, and the
;; provider registry resolve through it at call time) and the pending
;; `ask-async!` tasks. Tasks belong to one loaded extension instance: every
;; register (first load, /reload, re-enable) finishes leftovers with nil, so
;; a task never outlives the instance that started it.
;;
;; The input consumers keep small records here so they survive /reload: the
;; identity tokens of the prompts whose idle answers may still surface a hint.

{:api nil
 ;; [{:co coroutine :on-done fn}] resumed once per :runtime-tick.
 :tasks []
 ;; Replaced on each prompt; cleared by any later user line or reset.
 :topic-pending nil
 :preference-pending nil}
