;; Parent side of the wire channel to a live child (#516).
;;
;; `send!` appends control lines to the private control file and `poll` reads
;; the child's event file. The channel is plain data kept on the run's job, so
;; it survives /reload; `fen.util.wire` owns the schema and
;; `fen.util.wire_session` the state table the mirror follows. The mirrored
;; `status` derives only from received events.

(local text (require :fen.util.text))
(local wire (require :fen.util.wire))
(local wire-session (require :fen.util.wire_session))

(local M {})

;; @doc fen.extensions.subagent.channel.open
;; kind: function
;; signature: (open run control-path event-path) -> channel
;; summary: Return parent channel state for RUN over the control and event files. The control file must already exist with private permissions.
;; tags: subagent wire
(fn M.open [run control-path event-path]
  {: run
   : control-path
   : event-path
   :sender (wire.sender :control run)
   :receiver (wire.receiver :event)
   :reader (wire.line-reader event-path)
   :status :starting
   ;; seq -> {:type :text} for controls not yet acknowledged.
   :unacked {}
   :result nil
   :exit nil
   :error nil})

;; @doc fen.extensions.subagent.channel.send!
;; kind: function
;; signature: (send! channel type ?payload) -> seq|nil, reason
;; summary: Stamp, validate, and append one control line with a strictly increasing seq; returns the seq, or nil plus a reason.
;; tags: subagent wire
(fn M.send! [ch typ ?payload]
  (let [(line rej) (wire.next! ch.sender typ ?payload)]
    (if (not line)
        (values nil (tostring (?. rej :reason)))
        (let [(f err) (io.open ch.control-path :a)]
          (if (not f)
              (values nil (tostring err))
              (let [(ok? werr) (pcall #(f:write line "\n"))]
                (f:close)
                (if ok?
                    (do (tset ch.unacked ch.sender.seq
                              {:type typ :text (?. ?payload :text)})
                        ch.sender.seq)
                    (values nil (tostring werr)))))))))

(fn mirror-ack! [ch msg]
  (let [sent (. ch.unacked msg.ref)]
    (when sent
      (tset ch.unacked msg.ref nil)
      (when (not= msg.status :rejected)
        (let [entry (wire-session.decide ch.status sent.type)]
          (when entry.next (set ch.status entry.next)))))
    sent))

(fn mirror! [ch msg]
  "Advance the mirrored run state for one received event. Returns the
   control record an ack answers, if any."
  (let [typ msg.type]
    (if (= typ :ready)
        (when (= ch.status :starting) (set ch.status :ready))
        (= typ :control-ack)
        (mirror-ack! ch msg)
        (= typ :turn-started)
        (when (= ch.status :ready) (set ch.status :running))
        (= typ :turn-complete)
        ;; Terminal states arrive only through `exit`.
        (let [entry (wire-session.advance ch.status :turn-done)]
          (when (and entry (not (wire-session.terminal? entry.next)))
            (set ch.status entry.next)))
        (= typ :result)
        (set ch.result msg)
        (= typ :exit)
        (do (set ch.exit msg)
            (set ch.status msg.status)))))

;; @doc fen.extensions.subagent.channel.poll
;; kind: function
;; signature: (poll channel) -> [message], [error]
;; summary: Read a bounded batch of child events, validate each against the wire schema and increasing seq, and advance the mirrored status. Returns the valid messages (a `control-ack` carries the answered control as `:control`) and per-line errors; a version mismatch, foreign run, or truncated file sets `channel.error`.
;; tags: subagent wire
(fn M.poll [ch]
  (let [(lines status) (wire.read-lines! ch.reader)
        out []
        errors []]
    (when (and (= status :truncated) (not ch.error))
      (set ch.error "event file truncated"))
    (each [_ line (ipairs lines)]
      (when (and (not= line "") (not ch.exit))
        (let [(msg rej) (wire.receive! ch.receiver line)]
          (if (and msg (not= msg.run ch.run))
              (do (set ch.error (.. "event for foreign run " (tostring msg.run)))
                  (table.insert errors {:line (text.truncate-line line 120)
                                        :error ch.error}))
              msg
              (let [control (mirror! ch msg)]
                (when (= msg.type :control-ack) (set msg.control control))
                (table.insert out msg))
              (do (when (and rej.fatal? (not ch.error)) (set ch.error rej.reason))
                  (table.insert errors {:line (text.truncate-line line 120)
                                        :error rej.reason}))))))
    (values out errors)))

;; @doc fen.extensions.subagent.channel.idle?
;; kind: function
;; signature: (idle? channel) -> boolean
;; summary: True when the child is `ready` with every control acknowledged, so its task turn is done; a steer the child still holds queued there is reported dropped when the run closes.
;; tags: subagent wire
(fn M.idle? [ch]
  (and (= ch.status :ready) (= nil (next ch.unacked))))

(fn M.close! [ch]
  (wire.close-reader! ch.reader))

M
