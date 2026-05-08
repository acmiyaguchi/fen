;; Small synchronous assistant-event stream helper.
;;
;; This is a Fennel/Lua-sized analogue of pi-mono's AssistantMessageEventStream:
;; providers push fine-grained events, consumers can observe them immediately,
;; and the final result is the AssistantMessage carried by :done or :error.
;; It is deliberately simple and synchronous; cooperative providers still use
;; util.http's curl-multi/yield-fn loop for scheduling.

;; @doc fen.core.llm.event_stream.terminal-event?
;; kind: function
;; signature: (terminal-event? ev) -> boolean
;; summary: Return true when an assistant stream event terminates the stream with either :done or :error.
;; tags: llm events stream
(fn terminal-event? [ev]
  (or (= (?. ev :type) :done)
      (= (?. ev :type) :error)))

;; @doc fen.core.llm.event_stream.event-result
;; kind: function
;; signature: (event-result ev) -> AssistantMessage|string|nil
;; summary: Extract the final AssistantMessage or error payload carried by a terminal assistant stream event.
;; tags: llm events stream
(fn event-result [ev]
  (if (= ev.type :done)
      ev.message
      (= ev.type :error)
      (or ev.message ev.error)
      nil))

;; @doc fen.core.llm.event_stream.new-stream
;; kind: function
;; signature: (new-stream on-event) -> AssistantEventStream
;; summary: Create a synchronous assistant-event sink that records events, forwards them to an observer, and captures the final result.
;; tags: llm events stream
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

{: new-stream
 : terminal-event?
 : event-result}
