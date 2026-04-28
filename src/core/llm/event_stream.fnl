;; Small synchronous assistant-event stream helper.
;;
;; This is a Fennel/Lua-sized analogue of pi-mono's AssistantMessageEventStream:
;; providers push fine-grained events, consumers can observe them immediately,
;; and the final result is the AssistantMessage carried by :done or :error.
;; It is deliberately simple and synchronous; cooperative providers still use
;; util.http's curl-multi/yield-fn loop for scheduling.

(fn terminal-event? [ev]
  (or (= (?. ev :type) :done)
      (= (?. ev :type) :error)))

(fn event-result [ev]
  (if (= ev.type :done)
      ev.message
      (= ev.type :error)
      (or ev.message ev.error)
      nil))

(fn new-stream [on-event]
  "Create a stream sink.

   Fields:
   - push(ev): record and optionally forward an event.
   - end(result): mark done when no terminal event was pushed.
   - events: recorded event array.
   - result(): final AssistantMessage or explicit end result.
   - done?(): true after :done/:error/end."
  (let [events []]
    (var done? false)
    (var result nil)
    (fn push [ev]
      (when (not done?)
        (table.insert events ev)
        (when on-event (on-event ev))
        (when (terminal-event? ev)
          (set done? true)
          (set result (event-result ev)))))
    (fn end [final-result]
      (when (not done?)
        (set done? true)
        (when (not= final-result nil)
          (set result final-result))))
    {:events events
     :push push
     :end end
     :result (fn [] result)
     :done? (fn [] done?)}))

(fn push! [stream ev]
  (stream.push ev))

(fn end! [stream result]
  (stream.end result))

(fn result [stream]
  (stream.result))

{: new-stream
 : terminal-event?
 : event-result
 : push!
 : end!
 : result}
