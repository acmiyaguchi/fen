;; Persistent decide state. Not reloadable.
;;
;; Holds the api handle from the most recent register (settings, logs, and the
;; provider registry resolve through it at call time) and the pending
;; `ask-async!` tasks. Tasks belong to one loaded extension instance: every
;; register (first load, /reload, re-enable) finishes leftovers with nil, so
;; a task never outlives the instance that started it.
;;
;; The input consumers keep two small records here so they survive /reload:
;; the identity token of the prompt whose topic-shift answer may still
;; surface a hint, and the last busy line moved to follow-up for /decide undo.

{:api nil
 ;; [{:co coroutine :on-done fn}] resumed once per :runtime-tick.
 :tasks []
 ;; Replaced on each prompt; cleared by any later user line or reset.
 :topic-pending nil
 ;; string|nil; cleared once the follow-up queue is empty.
 :reclassified nil}
