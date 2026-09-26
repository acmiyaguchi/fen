;; Parent channel: control sends, event validation, and the mirrored state.

(local channel (require :fen.extensions.subagent.channel))
(local wire (require :fen.util.wire))

(fn open-pair []
  (let [control (os.tmpname)
        event (os.tmpname)]
    {:ch (channel.open "run-7" control event)
     :child (wire.sender :event "run-7")
     : control : event}))

(fn close-pair! [p]
  (channel.close! p.ch)
  (os.remove p.control)
  (os.remove p.event))

(fn emit! [p typ ?payload]
  (let [f (assert (io.open p.event :a))]
    (f:write (assert (wire.next! p.child typ ?payload)) "\n")
    (f:close)))

(fn raw! [p line]
  (let [f (assert (io.open p.event :a))]
    (f:write line "\n")
    (f:close)))

(fn controls [p]
  (let [out []]
    (each [line (io.lines p.control)]
      (let [msg (wire.decode line :control)]
        (table.insert out msg)))
    out))

(describe "subagent channel"
  (fn []
    (it "sends validated controls with strictly increasing seqs"
      (fn []
        (let [p (open-pair)]
          (assert.are.equal 1 (channel.send! p.ch :prompt {:text "task"}))
          (assert.are.equal 2 (channel.send! p.ch :steer {:text "focus"}))
          (let [(seq err) (channel.send! p.ch :steer {})]
            (assert.is_nil seq)
            (assert.is_truthy (string.find err "text" 1 true)))
          (assert.are.equal 3 (channel.send! p.ch :close))
          (let [sent (controls p)]
            (assert.are.same [:prompt :steer :close]
                             (icollect [_ m (ipairs sent)] m.type))
            (assert.are.same [1 2 3] (icollect [_ m (ipairs sent)] m.seq)))
          (close-pair! p))))

    (it "mirrors the run state from events and acks alone"
      (fn []
        (let [p (open-pair)
              ch p.ch]
          (channel.send! ch :prompt {:text "task"})
          (emit! p :ready {})
          (channel.poll ch)
          (assert.are.equal :ready ch.status)
          ;; The prompt is unacknowledged, so the run is not idle yet.
          (assert.is_false (channel.idle? ch))
          (emit! p :control-ack {:ref 1 :status :accepted})
          (emit! p :turn-started {:turn 1})
          (let [(msgs) (channel.poll ch)]
            (assert.are.equal :prompt (. msgs 1 :control :type)))
          (assert.are.equal :running ch.status)
          (channel.send! ch :steer {:text "more"})
          (emit! p :control-ack {:ref 2 :status :accepted})
          (emit! p :turn-complete {:turn 1 :stop-reason "stop"})
          (channel.poll ch)
          (assert.are.equal :ready ch.status)
          (assert.is_true (channel.idle? ch))
          (channel.send! ch :finalize {:note "wrap up"})
          (emit! p :control-ack {:ref 3 :status :accepted})
          (emit! p :turn-complete {:turn 2 :stop-reason "stop"})
          (channel.poll ch)
          ;; A turn end while finalizing stays there until `exit`.
          (assert.are.equal :finalizing ch.status)
          (emit! p :result {:final-text "done" :stop-reason "stop" :context :complete})
          (emit! p :exit {:status :done})
          (channel.poll ch)
          (assert.are.equal :done ch.status)
          (assert.are.equal "done" ch.result.final-text)
          (assert.are.equal :done ch.exit.status)
          (close-pair! p))))

    (it "keeps the mirror on a rejected control"
      (fn []
        (let [p (open-pair)
              ch p.ch]
          (emit! p :ready {})
          (channel.send! ch :close)
          (emit! p :control-ack {:ref 1 :status :rejected :reason "nope"})
          (let [(msgs) (channel.poll ch)]
            (assert.are.equal :close (. msgs 2 :control :type)))
          (assert.are.equal :ready ch.status)
          (close-pair! p))))

    (it "reports malformed, out-of-order, and foreign lines without stopping"
      (fn []
        (let [p (open-pair)
              ch p.ch]
          (raw! p "not json")
          (emit! p :ready {})
          (raw! p "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"run\":\"run-7\"}")
          (let [(msgs errors) (channel.poll ch)]
            (assert.are.equal 1 (length msgs))
            (assert.are.equal 2 (length errors))
            (assert.is_nil ch.error))
          (raw! p "{\"v\":1,\"seq\":9,\"type\":\"ready\",\"run\":\"other\"}")
          (channel.poll ch)
          (assert.is_truthy (string.find ch.error "foreign run" 1 true))
          (close-pair! p))))

    (it "treats a wire version mismatch as a channel error"
      (fn []
        (let [p (open-pair)
              ch p.ch]
          (raw! p "{\"v\":2,\"seq\":1,\"type\":\"ready\",\"run\":\"run-7\"}")
          (let [(_msgs errors) (channel.poll ch)]
            (assert.are.equal 1 (length errors)))
          (assert.is_truthy (string.find ch.error "wire version 2" 1 true))
          (close-pair! p))))

    (it "ignores lines after exit"
      (fn []
        (let [p (open-pair)
              ch p.ch]
          (emit! p :exit {:status :cancelled})
          (emit! p :ready {})
          (let [(msgs) (channel.poll ch)]
            (assert.are.equal 1 (length msgs)))
          (assert.are.equal :cancelled ch.status)
          (close-pair! p))))))
