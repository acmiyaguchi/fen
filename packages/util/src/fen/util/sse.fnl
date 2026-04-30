;; Server-Sent Events parsing helpers.
;;
;; The parser is intentionally transport-agnostic: callers feed arbitrary byte
;; chunks (as received from curl's writefunction) and receive completed SSE
;; events. It preserves partial lines across chunks and implements the small
;; standard field set providers need: event, data, id, retry, comments, and
;; blank-line dispatch.

(local json (require :fen.util.json))

(fn strip-trailing-cr [s]
  (if (and (> (length s) 0)
           (= (string.sub s -1) "\r"))
      (string.sub s 1 (- (length s) 1))
      s))

(fn split-field [line]
  (let [idx (string.find line ":" 1 true)]
    (if idx
        (let [field (string.sub line 1 (- idx 1))
              raw-value (string.sub line (+ idx 1))
              value (if (= (string.sub raw-value 1 1) " ")
                        (string.sub raw-value 2)
                        raw-value)]
          (values field value))
        (values line ""))))

(fn new-parser [on-event]
  "Create an incremental SSE parser.

   Returned table fields:
   - feed(chunk): process arbitrary bytes and dispatch complete events.
   - finish(): flush a final unterminated line/event, if any.

   `on-event` receives an event table with :event, :data, and optional :id
   / :retry fields. The default event type follows the SSE spec: message."
  (let [state {:buffer ""
               :event nil
               :data-lines []
               :id nil
               :retry nil}]
    (fn reset-event! []
      (set state.event nil)
      (set state.data-lines [])
      (set state.id nil)
      (set state.retry nil))

    (fn dispatch! []
      (when (or (> (length state.data-lines) 0) state.event state.id state.retry)
        (let [ev {:event (or state.event "message")
                  :data (table.concat state.data-lines "\n")}]
          (when state.id (set ev.id state.id))
          (when state.retry (set ev.retry state.retry))
          (on-event ev)))
      (reset-event!))

    (fn process-line! [raw-line]
      (let [line (strip-trailing-cr raw-line)]
        (if (= line "")
            (dispatch!)
            (= (string.sub line 1 1) ":")
            nil
            (let [(field value) (split-field line)]
              (if (= field "event")
                  (set state.event value)
                  (= field "data")
                  (table.insert state.data-lines value)
                  (= field "id")
                  (set state.id value)
                  (= field "retry")
                  (let [n (tonumber value)]
                    (when n (set state.retry n)))
                  ;; Unknown fields are ignored per SSE spec.
                  nil)))))

    (fn feed [chunk]
      (when (and chunk (> (length chunk) 0))
        (set state.buffer (.. state.buffer chunk))
        (var idx (string.find state.buffer "\n" 1 true))
        (while idx
          (let [line (string.sub state.buffer 1 (- idx 1))]
            (set state.buffer (string.sub state.buffer (+ idx 1)))
            (process-line! line)
            (set idx (string.find state.buffer "\n" 1 true))))))

    (fn finish []
      (when (> (length state.buffer) 0)
        (process-line! state.buffer)
        (set state.buffer ""))
      (dispatch!))

    {: feed : finish}))

(fn parse [raw]
  "Parse a complete SSE string into an array of event tables."
  (let [events []
        parser (new-parser #(table.insert events $1))]
    (parser.feed (or raw ""))
    (parser.finish)
    events))

(fn json-events [raw]
  "Parse a complete SSE string and JSON-decode each non-[DONE] data payload."
  (let [out []]
    (each [_ ev (ipairs (parse raw))]
      (when (and (not= ev.data nil) (not= ev.data "") (not= ev.data "[DONE]"))
        (table.insert out (json.decode ev.data))))
    out))

{: new-parser
 : parse
 : json-events}
