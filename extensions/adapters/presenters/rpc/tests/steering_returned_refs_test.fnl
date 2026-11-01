;; Every queued control line carries its wire seq as the mailbox tag, and the
;; mailbox hands the tag back: steering the turn ended without reading is
;; reported with its refs, an injected line names its own control, and a steer
;; the mailbox refuses is reported at once. No ref bookkeeping lives in rpc.

(local wire (require :fen.util.wire))
(local tasks (require :fen.core.tasks))
(local events (require :fen.core.extensions.events))
(local rpc (require :fen.extensions.rpc))

(fn make-ch []
  (let [lines []]
    {:run "run-1"
     :sender (wire.sender :event "run-1")
     : lines
     :out {:write (fn [_ s] (when (not= s "\n") (table.insert lines s)))
           :flush (fn [] nil)}}))

(fn infos [ch]
  (icollect [_ line (ipairs ch.lines)]
    (when (string.find line "\"info\"" 1 true) line)))

(describe "rpc child: mailbox tags carry wire refs"
          (fn []
            (var ch nil)
            (before_each (fn []
                           (tasks.reset!)
                           (set ch (make-ch))
                           (events.on :* #(rpc.forward! ch $1) :rpc-refs-test)))
            (after_each (fn []
                          (events.unregister-by-owner :rpc-refs-test)
                          (tasks.reset!)))
            (it "names a released turn's unread steering by ref"
                (fn []
                  (tasks.with-holder :turn
                    (fn []
                      (tasks.offer! "a" {:tag 4 :turn 1})
                      (tasks.offer! "b" {:tag 5 :turn 1})
                      (let [(_ items) (tasks.take! :steering)]
                        (assert.are.equal 4 (. items 1 :tag)))))
                  (let [out (infos ch)]
                    (assert.are.equal 1 (length out))
                    (assert.is_truthy (string.find (. out 1) "\"refs\":[5]" 1
                                                   true)))))
            (it "an injected line names its own control even with repeated text"
                (fn []
                  (rpc.forward! ch {:type :steering-injected
                                    :text "same"
                                    :tag 9})
                  (let [injected (icollect [_ l (ipairs ch.lines)]
                                   (when (string.find l "steering-injected" 1
                                                      true)
                                     l))]
                    (assert.is_truthy (string.find (. injected 1) "\"ref\":9" 1
                                                   true)))))
            (it "a refused steer comes back with its tag"
                (fn []
                  (let [r (tasks.offer! "late" {:tag 7 :turn 3})]
                    (assert.is_false r.ok)
                    (assert.is_true r.refused?)
                    (assert.are.equal 7 r.tag))))
            (it "a started line's tag reaches turn-started; a leftover follow-up keeps its own ref"
                (fn []
                  (tasks.offer! "leftover" {:tag 6 :follow-up? true})
                  (let [r (tasks.offer-start! "prompt" {:tag 8}
                                              (fn [_item _n] (fn [] nil)))]
                    (assert.are.equal 8 r.item.tag)
                    (assert.are.equal 8 ch.started-ref)
                    (let [(_ items) (tasks.take! :follow-up)]
                      (assert.are.equal 6 (. items 1 :tag))
                      (rpc.forward! ch
                                    {:type :follow-up-injected
                                     :text (. items 1 :text)
                                     :tag (. items 1 :tag)}))
                    (let [inj (icollect [_ l (ipairs ch.lines)]
                                (when (string.find l "follow-up-injected" 1
                                                   true)
                                  l))]
                      (assert.is_truthy (string.find (. inj 1) "\"ref\":6" 1
                                                     true)))
                    (coroutine.resume r.co))))))
