;; Provider-neutral summary helpers for completed agent turns.

(local M {})

(fn M.last-assistant [messages]
  (var found nil)
  (for [i (length (or messages [])) 1 -1 &until found]
    (let [message (. messages i)]
      (when (= message.role :assistant)
        (set found message))))
  found)

(fn M.failed? [ok? messages]
  (let [assistant (M.last-assistant messages)]
    (or (not ok?)
        (not assistant)
        (= assistant.stop-reason :error)
        (= assistant.stop-reason :tool-use)
        (= assistant.stop-reason :aborted))))

(fn M.sum-usage [messages]
  (let [total {}]
    (var any? false)
    (each [_ message (ipairs (or messages []))]
      (when (and (= message.role :assistant) message.usage)
        (set any? true)
        (each [key value (pairs message.usage)]
          (when (= (type value) :number)
            (tset total key (+ (or (. total key) 0) value))))))
    (when any? total)))

M
