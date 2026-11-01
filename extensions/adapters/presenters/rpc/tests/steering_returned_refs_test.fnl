;; Steering the turn mailbox hands back (the turn ended before reading it) is
;; reported to the parent with its control refs, and those refs leave the
;; pending FIFO so later steers keep their own refs. A steer the mailbox
;; refuses is reported the same way instead of leaving a phantom ref.

(local wire (require :fen.util.wire))
(local tasks (require :fen.core.tasks))
(local rpc (require :fen.extensions.rpc))

(fn make-ch []
  (let [lines []]
    {:pending {:steering [] :follow-up []}
     :run "run-1"
     :sender (wire.sender :event "run-1")
     : lines
     :out {:write (fn [_ s] (when (not= s "\n") (table.insert lines s)))
           :flush (fn [] nil)}}))

(fn infos [ch]
  (icollect [_ line (ipairs ch.lines)]
    (when (string.find line "\"info\"" 1 true) line)))

(describe "rpc child: returned steering keeps refs aligned"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "drops returned lines' refs and names them in one info"
                (fn []
                  (let [ch (make-ch)]
                    (table.insert ch.pending.steering {:ref 4 :text "a"})
                    (table.insert ch.pending.steering {:ref 5 :text "b"})
                    (rpc.forward! ch {:type :steering-returned :texts ["b"]})
                    (assert.are.same [{:ref 4 :text "a"}] ch.pending.steering)
                    (let [out (infos ch)]
                      (assert.are.equal 1 (length out))
                      (assert.is_truthy (string.find (. out 1) "\"refs\":[5]" 1
                                                     true))))))
            (it "a returned line followed by a new steer with the same text keeps the new ref"
                (fn []
                  (let [ch (make-ch)]
                    (table.insert ch.pending.steering {:ref 4 :text "same"})
                    (rpc.forward! ch {:type :steering-returned :texts ["same"]})
                    (table.insert ch.pending.steering {:ref 9 :text "same"})
                    (rpc.forward! ch {:type :steering-injected :text "same"})
                    (assert.are.same [] ch.pending.steering)
                    (let [injected (icollect [_ l (ipairs ch.lines)]
                                     (when (string.find l "steering-injected" 1
                                                        true)
                                       l))]
                      (assert.is_truthy (string.find (. injected 1) "\"ref\":9"
                                                     1 true))))))))
