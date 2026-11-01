;; fen.core.tasks: the session holder and mailbox (spec/core/tasks/proofs/holder).

(local tasks (require :fen.core.tasks))
(local events (require :fen.core.extensions.events))

(fn initial [] (tasks.initial-machine))

(fn run [m inputs]
  "Fold inputs through the pure step; return the final machine and all outputs."
  (var cur m)
  (let [all []]
    (each [_ input (ipairs inputs)]
      (let [(m2 outs) (tasks.step cur input)]
        (set cur m2)
        (each [_ o (ipairs outs)] (table.insert all o))))
    (values cur all)))

(fn of-type [outs typ]
  (icollect [_ o (ipairs outs)] (when (= o.type typ) o)))

(fn texts [items]
  (icollect [_ i (ipairs items)] i.text))

(local TURN {:type :acquire :kind :turn})
(local EXCL {:type :acquire :kind :exclusive})

(fn offer [text ?opts]
  (let [o (or ?opts {})]
    {:type :offer : text :tag o.tag :turn o.turn :follow-up? o.follow-up?}))

(describe "fen.core.tasks.step"
          (fn []
            (it "is pure: the input machine is never mutated"
                (fn []
                  (let [m (initial)
                        (m2 _) (tasks.step m TURN)
                        (m3 _) (tasks.step m2 (offer "x"))]
                    (assert.are.same (initial) m)
                    (assert.are.equal 0 (length m2.steer))
                    (assert.are.equal 1 (length m3.steer)))))
            (it "never replaces a holder"
                (fn []
                  (let [(m outs) (run (initial) [TURN TURN EXCL])]
                    (assert.are.equal :turn m.kind)
                    (assert.are.equal 1 m.n)
                    (assert.are.equal 1 (length (of-type outs :held)))
                    (assert.are.equal 2 (length (of-type outs :hold-refused))))
                  (let [(m outs) (run (initial) [EXCL TURN])]
                    (assert.are.equal :exclusive m.kind)
                    (assert.are.equal 0 m.n "only turns consume a number")
                    (assert.are.equal 1 (length (of-type outs :hold-refused))))))
            (it "refuses an exclusive holder while a turn start is pending"
                (fn []
                  (let [(m outs) (run (initial) [(offer "go") EXCL])]
                    (assert.are.equal :none m.kind)
                    (assert.is_truthy (string.find (. (of-type outs
                                                               :hold-refused)
                                                      1 :reason)
                                                   "queued turn" 1 true)))
                  ;; once the start is taken, exclusive may hold again later
                  (let [(m _) (run (initial)
                                   [(offer "go")
                                    {:type :next-start}
                                    TURN
                                    {:type :release}
                                    EXCL])]
                    (assert.are.equal :exclusive m.kind))))
            (it "a plain turn acquire never jumps a requested start"
                (fn []
                  (let [(m outs) (run (initial) [(offer "go") TURN])]
                    (assert.are.equal :none m.kind)
                    (assert.is_true m.start?)
                    (assert.are.equal 1 (length (of-type outs :hold-refused))))))
            (it "offer-start starts the offered line in one step and marks it consumed"
                (fn []
                  (let [(m outs) (run (initial)
                                      [(offer "left" {:follow-up? true})
                                       {:type :offer-start
                                        :text "typed"
                                        :tag 3}])
                        adm (. (of-type outs :admitted) 2)
                        st (. (of-type outs :started) 1)]
                    (assert.is_true adm.consumed?)
                    (assert.are.equal "typed" st.item.text)
                    (assert.are.equal 3 st.item.tag)
                    (assert.are.equal :turn m.kind)
                    (assert.are.same ["left"] (texts m.follow-up)))
                  ;; an earlier start request wins; the new line stays queued
                  (let [(_ outs) (run (initial)
                                      [(offer "first" {:turn 0})
                                       {:type :offer-start :text "second"}])
                        adm (. (of-type outs :admitted) 2)]
                    (assert.is_nil adm.consumed?)
                    (assert.are.equal "first"
                                      (. (of-type outs :started) 1 :item :text)))))
            (it "keeps start? iff first-up is set, and first-up queued"
                (fn []
                  (let [(m _) (run (initial) [(offer "a") (offer "b")])]
                    (assert.is_true m.start?)
                    (assert.are.equal 1 m.first-up))
                  (let [(m _) (run (initial)
                                   [(offer "a")
                                    {:type :clear :queue :follow-up}])]
                    (assert.is_false m.start?)
                    (assert.is_nil m.first-up))))
            (it "routes offers by :turn, :follow-up?, and the holder"
                (fn []
                  ;; idle, local: follow-up + start request
                  (let [(m _) (run (initial) [(offer "a")])]
                    (assert.are.same ["a"] (texts m.follow-up))
                    (assert.is_true m.start?))
                  ;; turn holds: local steers; t = n steers; other t refused
                  (let [(m outs) (run (initial)
                                      [TURN
                                       (offer "s1")
                                       (offer "s2" {:turn 1})
                                       (offer "stale" {:turn 2 :tag 7})
                                       (offer "t0" {:turn 0 :tag 8})
                                       (offer "f" {:follow-up? true})])
                        refused (of-type outs :refused)]
                    (assert.are.same ["s1" "s2"] (texts m.steer))
                    (assert.are.same ["f"] (texts m.follow-up))
                    (assert.is_false m.start?)
                    (assert.are.same [7 8]
                                     (icollect [_ r (ipairs refused)] r.tag))
                    (assert.are.same [1 1]
                                     (icollect [_ r (ipairs refused)] r.turn)))
                  ;; exclusive holds: local becomes a follow-up, no start
                  (let [(m _) (run (initial) [EXCL (offer "x")])]
                    (assert.are.same ["x"] (texts m.follow-up))
                    (assert.are.same [] m.steer)
                    (assert.is_false m.start?))
                  ;; idle, t > 0: refused; t = 0: follow-up + start
                  (let [(m outs) (run (initial)
                                      [(offer "no" {:turn 1})
                                       (offer "yes" {:turn 0})])]
                    (assert.are.equal 1 (length (of-type outs :refused)))
                    (assert.are.same ["yes"] (texts m.follow-up))
                    (assert.is_true m.start?))))
            (it "never refuses a local offer, whatever holds"
                (fn []
                  (each [_ prefix (ipairs [[] [TURN] [EXCL]])]
                    (let [inputs (icollect [_ i (ipairs prefix)] i)]
                      (table.insert inputs (offer "local"))
                      (let [(_ outs) (run (initial) inputs)]
                        (assert.are.equal 0 (length (of-type outs :refused)))
                        (assert.are.equal 1 (length (of-type outs :admitted))))))
                  (let [(_ outs) (run (initial) [(offer "")])]
                    (assert.are.equal 1 (length (of-type outs :rejected))))))
            (it "issues increasing seqs and carries tags opaquely"
                (fn []
                  (let [(_ outs) (run (initial)
                                      [TURN
                                       (offer "a" {:tag 5})
                                       (offer "b" {:tag 5})
                                       (offer "c")])
                        adm (of-type outs :admitted)]
                    (assert.are.same [1 2 3]
                                     (icollect [_ a (ipairs adm)] a.seq))
                    (assert.are.same [5 5] (icollect [_ a (ipairs adm)] a.tag)))))
            (it "release hands unread steering back with the turn number"
                (fn []
                  (let [(m outs) (run (initial)
                                      [TURN
                                       (offer "late" {:tag 3})
                                       (offer "f" {:follow-up? true})
                                       {:type :release}
                                       (offer "idle")])
                        rel (. (of-type outs :released) 1)]
                    (assert.are.equal 1 rel.turn)
                    (assert.are.same ["late"] (texts rel.items))
                    (assert.are.equal 3 (. rel.items 1 :tag))
                    (assert.are.equal :none m.kind)
                    (assert.are.same [] m.steer)
                    (assert.are.same ["f" "idle"] (texts m.follow-up)
                                     "follow-ups survive the release"))))
            (it "fences release on the holder id"
                (fn []
                  (let [(m outs) (run (initial)
                                      [TURN
                                       {:type :release :hid 1}
                                       TURN
                                       (offer "keep")
                                       {:type :release :hid 1}])]
                    (assert.are.equal :turn m.kind)
                    (assert.are.equal 2 m.n)
                    (assert.are.same ["keep"] (texts m.steer))
                    (assert.are.equal 1 (length (of-type outs :released))))))
            (it "fences cancel on the running turn's number"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :cancel :turn 0}
                                       TURN
                                       {:type :cancel :turn 2}])]
                    (assert.is_false m.cancel?)
                    (assert.are.same [false false]
                                     (icollect [_ o (ipairs (of-type outs
                                                                     :cancel))]
                                       o.accepted?)))
                  (let [(m _) (run (initial) [TURN {:type :cancel :turn 1}])]
                    (assert.is_true m.cancel?)
                    (let [(m2 _) (run m [{:type :release}])]
                      (assert.is_false m2.cancel? "release clears cancel")))
                  (let [(m _) (run (initial) [EXCL {:type :cancel :turn 0}])]
                    (assert.is_false m.cancel?))))
            (it "takes by mode, only while a turn holds"
                (fn []
                  (let [(m outs) (run (initial)
                                      [(offer "a" {:follow-up? true})
                                       {:type :take :queue :follow-up}
                                       TURN
                                       (offer "s1")
                                       (offer "s2")
                                       (offer "s3")
                                       {:type :take :queue :steering}
                                       {:type :set-mode
                                        :queue :steering
                                        :mode :all}
                                       {:type :take :queue :steering}])
                        taken (of-type outs :taken)]
                    (assert.are.same [[] ["s1"] ["s2" "s3"]]
                                     (icollect [_ t (ipairs taken)]
                                       (texts t.items)))
                    (assert.are.same ["a"] (texts m.follow-up)))
                  (let [(_ outs) (run (initial)
                                      [TURN
                                       (offer "a" {:follow-up? true})
                                       (offer "b" {:follow-up? true})
                                       (offer "c" {:follow-up? true})
                                       {:type :take :queue :follow-up}
                                       {:type :set-mode
                                        :queue :follow-up
                                        :mode :all}
                                       {:type :take :queue :follow-up}])]
                    (assert.are.same [["a"] ["b" "c"]]
                                     (icollect [_ t (ipairs (of-type outs
                                                                     :taken))]
                                       (texts t.items))))))
            (it "steering wins: no follow-up while a steer line waits"
                (fn []
                  (let [(m outs) (run (initial)
                                      [TURN
                                       (offer "f" {:follow-up? true})
                                       (offer "s")
                                       {:type :take :queue :follow-up}
                                       {:type :take :queue :steering}
                                       {:type :take :queue :follow-up}])]
                    (assert.are.same [[] ["s"] ["f"]]
                                     (icollect [_ t (ipairs (of-type outs
                                                                     :taken))]
                                       (texts t.items)))
                    (assert.are.same [] m.follow-up))))
            (it "next-start! starts the line that asked first, holding the turn in the same step"
                (fn []
                  (let [(m outs) (run (initial)
                                      [(offer "a" {:follow-up? true})
                                       {:type :next-start}
                                       (offer "b")
                                       (offer "c")
                                       {:type :next-start}
                                       {:type :next-start}])
                        started (of-type outs :started)]
                    (assert.are.equal 1 (length started))
                    (assert.are.equal "b" (. started 1 :item :text)
                                      "the typed line starts, ahead of the leftover")
                    (assert.are.equal 1 (. started 1 :turn))
                    (assert.are.equal :turn m.kind)
                    (assert.are.equal 1 m.n)
                    (assert.are.equal (. started 1 :hid) m.hid)
                    (assert.are.same ["a" "c"] (texts m.follow-up)
                                     "leftovers stay FIFO for natural stops")
                    (assert.is_false m.start?)
                    (assert.is_nil m.first-up))
                  ;; without a first-up (migrated machine), the oldest starts
                  (let [m (doto (initial)
                            (tset :follow-up
                                  [{:seq 1 :text "old"} {:seq 2 :text "new"}])
                            (tset :start? true))
                        (_ outs) (tasks.step m {:type :next-start})]
                    (assert.are.equal "old"
                                      (. (of-type outs :started) 1 :item :text)))
                  (let [(_ outs) (run (initial)
                                      [EXCL
                                       (offer "x" {:turn 0})
                                       {:type :next-start}])]
                    (assert.are.equal 0 (length (of-type outs :started))))))
            (it "clear drops lines and, for follow-ups, the start request"
                (fn []
                  (let [(m outs) (run (initial)
                                      [(offer "f")
                                       {:type :clear :queue :follow-up}])]
                    (assert.are.same [] m.follow-up)
                    (assert.is_false m.start?)
                    (assert.are.same ["f"]
                                     (texts (. (of-type outs :cleared) 1 :items))))))
            (it "keeps modes across turns, releases, and clears"
                (fn []
                  (let [(m _) (run (initial)
                                   [{:type :set-mode
                                     :queue :steering
                                     :mode :all}
                                    TURN
                                    {:type :release}
                                    {:type :clear}
                                    TURN])]
                    (assert.are.equal :all m.modes.steering))))
            (it "keeps its invariants: steer only under a turn, start only idle with a follow-up"
                (fn []
                  (let [(m _) (run (initial)
                                   [(offer "a")
                                    {:type :next-start}
                                    TURN
                                    (offer "s")
                                    {:type :release}])]
                    (assert.are.same [] m.steer)
                    (assert.is_false m.start?))))
            (it "migrates a pre-holder machine left by /reload"
                (fn []
                  (let [(m _) (tasks.step {:turn 4
                                           :running? false
                                           :mailbox []
                                           :follow-ups [{:id 1 :text "f"}]
                                           :modes {:steering :all
                                                   :follow-up :one-at-a-time}
                                           :next-id 2
                                           :idle-start? true}
                                          {:type :next-start})]
                    (assert.are.equal 5 m.n
                                      "the migrated start request opens turn 5")
                    (assert.are.equal :turn m.kind)
                    (assert.are.equal :all m.modes.steering)
                    (assert.are.same [] m.follow-up))))
            (it "rejects unknown inputs without changing state"
                (fn []
                  (let [(m outs) (tasks.step (initial) {:type :bogus})]
                    (assert.are.same (initial) m)
                    (assert.are.equal :rejected (. outs 1 :type)))))))

(describe "fen.core.tasks shell"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "emits :queued, status counts, and :steering-returned on the bus"
                (fn []
                  (let [seen []]
                    (each [_ t (ipairs [:queued
                                        :set-status-info
                                        :steering-returned])]
                      (events.on t #(table.insert seen $1) :tasks-test))
                    (tasks.with-holder :turn
                      (fn []
                        (assert.is_true (. (tasks.offer! "x" {:tag 9}) :ok))))
                    (let [ret (icollect [_ e (ipairs seen)]
                                (when (= e.type :steering-returned) e))]
                      (assert.are.equal 1 (length ret))
                      (assert.are.same ["x"] (. ret 1 :texts))
                      (assert.are.same [9] (. ret 1 :tags))
                      (assert.are.equal 1 (. ret 1 :turn)))
                    (events.unregister-by-owner :tasks-test))))
            (it "with-holder releases on return and on error"
                (fn []
                  (let [(ok? v) (tasks.with-holder :turn #:done)]
                    (assert.is_true ok?)
                    (assert.are.equal :done v))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (let [(ok? err) (pcall tasks.with-holder :exclusive
                                         #(error "boom"))]
                    (assert.is_false ok?)
                    (assert.is_truthy (string.find (tostring err) "boom" 1 true)))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  ;; error objects (cancel markers) pass through untouched
                  (let [marker {}
                        (ok? err) (pcall tasks.with-holder :turn
                                         #(error marker))]
                    (assert.is_false ok?)
                    (assert.are.equal marker err))
                  (assert.are.equal :none (. (tasks.holder) :kind))))
            (it "with-holder refuses, without running f, when the session is held"
                (fn []
                  (tasks.with-holder :turn
                    (fn []
                      (var ran? false)
                      (let [(ok? why) (tasks.with-holder :exclusive
                                        #(set ran? true))]
                        (assert.is_false ok?)
                        (assert.is_string why)
                        (assert.is_false ran?))
                      (assert.are.equal :turn (. (tasks.holder) :kind))))
                  (assert.are.equal :none (. (tasks.holder) :kind))))
            (it "spawn-held holds from creation and releases when the body finishes"
                (fn []
                  (let [(co hid n) (tasks.spawn-held :turn
                                                     (fn []
                                                       (coroutine.yield)
                                                       :ok))]
                    (assert.are.equal 1 n)
                    (assert.are.equal hid (. (tasks.holder) :hid))
                    (assert.are.equal :turn (. (tasks.holder) :kind))
                    (coroutine.resume co)
                    (assert.are.equal :turn (. (tasks.holder) :kind))
                    (coroutine.resume co)
                    (assert.are.equal :dead (coroutine.status co))
                    (assert.are.equal :none (. (tasks.holder) :kind)))))
            (it "spawn-held releases when the body errors inside a resume"
                (fn []
                  (let [(co _) (tasks.spawn-held :turn
                                                 (fn []
                                                   (coroutine.yield)
                                                   (error "crash")))]
                    (coroutine.resume co)
                    (let [(ok? _) (coroutine.resume co)]
                      (assert.is_false ok?))
                    (assert.are.equal :none (. (tasks.holder) :kind)))))
            (it "abandonment: a dropped, never-finished coroutine is released by release!"
                (fn []
                  (let [(_co hid) (tasks.spawn-held :exclusive
                                                    #(coroutine.yield))]
                    (assert.are.equal :exclusive (. (tasks.holder) :kind))
                    (tasks.release! hid)
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    ;; the abandoned body's stale release cannot touch a newer holder
                    (let [(co2 hid2) (tasks.spawn-held :turn #(coroutine.yield))]
                      (tasks.release! hid)
                      (assert.are.equal hid2 (. (tasks.holder) :hid))
                      (coroutine.resume co2)
                      (coroutine.resume co2)
                      (assert.are.equal :none (. (tasks.holder) :kind))))))
            (it "abandonment across /reload: a re-required tasks module still releases"
                (fn []
                  (let [(co _) (tasks.spawn-held :exclusive #(coroutine.yield))]
                    (coroutine.resume co)
                    (tset package.loaded :fen.core.tasks nil)
                    (let [fresh (require :fen.core.tasks)]
                      (assert.are.equal :exclusive (. (fresh.holder) :kind))
                      (coroutine.resume co)
                      (assert.are.equal :none (. (fresh.holder) :kind)))
                    (tset package.loaded :fen.core.tasks tasks))))
            (it "take! returns texts and tagged items"
                (fn []
                  (tasks.with-holder :turn
                    (fn []
                      (tasks.offer! "s" {:tag 4})
                      (let [(ts items) (tasks.take! :steering)]
                        (assert.are.same ["s"] ts)
                        (assert.are.equal 4 (. items 1 :tag)))))))))

(describe "fen.core.tasks deprecated shims (closures from a872c57 after /reload)"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "idle-tick! pops the start line without holding the session"
                (fn []
                  (tasks.offer! "left" {:follow-up? true})
                  (tasks.offer! "typed")
                  (assert.are.equal "typed" (tasks.idle-tick!))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (assert.is_false (tasks.start-pending?))
                  (assert.is_nil (tasks.idle-tick!))
                  (assert.are.same ["left"] (. (tasks.snapshot) :follow-up))))
            (it "queue! and steer-or-follow-up! route through offer!"
                (fn []
                  (assert.is_false (. (tasks.queue! :steering "s") :ok)
                                   "no turn runs")
                  (assert.is_true (. (tasks.queue! :follow-up "f") :ok))
                  (assert.is_true (. (tasks.queue! :follow-up "g"
                                                   {:start-if-idle? true})
                                     :start-pending?))
                  (assert.is_true (. (tasks.steer-or-follow-up! "h") :ok))
                  (assert.are.same ["f" "g" "h"]
                                   (. (tasks.snapshot) :follow-up))
                  (assert.is_false (. (tasks.queue! :bogus "x") :ok))))
            (it "turn-start! is a no-op with one restart notice; turn-end! releases turn n"
                (fn []
                  (let [infos []]
                    (events.on :info #(table.insert infos $1.text) :shim-test)
                    (assert.are.equal 0 (tasks.turn-start!))
                    (tasks.turn-start!)
                    (events.unregister-by-owner :shim-test)
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    (assert.is_true (<= (length infos) 1)))
                  (tasks.spawn-held :turn #(coroutine.yield))
                  (tasks.offer! "unread")
                  (tasks.turn-end! 7)
                  (assert.are.equal :turn (. (tasks.holder) :kind)
                                    "wrong turn: no-op")
                  (assert.are.same ["unread"] (tasks.turn-end! 1))
                  (assert.are.equal :none (. (tasks.holder) :kind))))))
