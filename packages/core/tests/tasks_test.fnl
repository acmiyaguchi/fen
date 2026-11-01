;; fen.core.tasks: the session holder and mailbox (spec/core/tasks/proofs/holder).

(local tasks (require :fen.core.tasks))
(local events (require :fen.core.extensions.events))

(local hold (require :fen.testing.tasks))

(fn initial [] (tasks.initial-machine))

(fn run [m inputs]
  "Fold inputs through the pure step; return the final machine and all
   outputs. {:hid :current} names the holder at that point."
  (var cur m)
  (let [all []]
    (each [_ input (ipairs inputs)]
      (let [input (if (= input.hid :current)
                      (collect [k v (pairs input)]
                        k
                        (if (= k :hid) (?. cur :holder :hid) v))
                      input)
            (m2 outs) (tasks.step cur input)]
        (set cur m2)
        (each [_ o (ipairs outs)] (table.insert all o))))
    (values cur all)))

(fn kind [m] (if m.holder m.holder.kind :none))

(fn cancel? [m] (= true (?. m :holder :cancel?)))

(fn of-type [outs typ]
  (icollect [_ o (ipairs outs)] (when (= o.type typ) o)))

(fn texts [items]
  (icollect [_ i (ipairs items)] i.text))

;; A turn starts only from a line (offer + scheduler); an exclusive job only
;; through a request the scheduler starts.
(local TURN {:type :offer-start :text "turn"})
(local EXCL {:type :request-job :spec {} :start-now? true})
(local REL {:type :release :hid :current})

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
            (it "never replaces a holder: work waits for the scheduler instead"
                (fn []
                  (let [(m outs) (run (initial) [TURN TURN EXCL])]
                    (assert.are.equal :turn (kind m))
                    (assert.are.equal 1 m.n)
                    (assert.are.equal 1 (length (of-type outs :spawn)))
                    (assert.are.same ["turn"] (texts m.steer)
                                     "the second line steers the running turn")
                    (assert.are.equal 1 (length m.jobs) "the job waits"))
                  (let [(m outs) (run (initial) [EXCL TURN])]
                    (assert.are.equal :exclusive (kind m))
                    (assert.is_nil m.holder.n
                                   "an exclusive holder has no turn number")
                    (assert.are.equal 0 m.n "only turns consume a number")
                    (assert.are.equal 1 (length (of-type outs :spawn)))
                    (assert.is_true m.start?
                                    "the line behind the job asks for a turn"))))
            (it "a pending turn start goes before a requested exclusive job"
                (fn []
                  (let [(m outs) (run (initial) [(offer "go") EXCL])]
                    (assert.are.equal :none (kind m))
                    (assert.are.equal 1 (length m.jobs))
                    (assert.are.equal 0 (length (of-type outs :spawn))))
                  (let [(m _) (run (initial)
                                   [(offer "go") EXCL {:type :next-job}])]
                    (assert.are.equal :turn (kind m))
                    (let [(m2 outs) (run m [REL {:type :next-job}])]
                      (assert.are.equal :exclusive (kind m2))
                      (assert.are.equal 0 (length m2.jobs))
                      (assert.are.equal 1 (length (of-type outs :job-started)))))))
            (it "a local line behind an exclusive job starts its turn when the job ends (e)"
                (fn []
                  (let [(m _) (run (initial)
                                   [EXCL
                                    (offer "typed during compaction")
                                    (offer "explicit" {:follow-up? true})
                                    REL
                                    (offer "later prompt")
                                    {:type :next-job}])]
                    (assert.are.equal :turn (kind m))
                    (assert.are.same ["explicit" "later prompt"]
                                     (texts m.follow-up)
                                     "the stranded line started first"))))
            (it "release! with nil or a stale hid is a no-op (f)"
                (fn []
                  (let [(m outs) (run (initial)
                                      [TURN
                                       {:type :release :hid nil}
                                       {:type :release :hid 99}])]
                    (assert.are.equal :turn (kind m))
                    (assert.are.equal 0 (length (of-type outs :released))))))
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
                    (assert.are.equal :turn (kind m))
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
                  ;; exclusive holds: local queues and asks for the turn after the job
                  (let [(m _) (run (initial) [EXCL (offer "x")])]
                    (assert.are.same ["x"] (texts m.follow-up))
                    (assert.are.same [] m.steer)
                    (assert.is_true m.start?))
                  ;; ... but an explicit follow-up still just waits
                  (let [(m _) (run (initial)
                                   [EXCL (offer "f" {:follow-up? true})])]
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
                        ;; the TURN prefix admits (and consumes) its own line
                        (assert.are.equal (if (= (. prefix 1) TURN) 2 1)
                                          (length (of-type outs :admitted))))))
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
                    (assert.are.same [1 2 3 4]
                                     (icollect [_ a (ipairs adm)] a.seq)
                                     "TURN's own line is seq 1")
                    (assert.are.same [5 5] (icollect [_ a (ipairs adm)] a.tag)))))
            (it "release hands unread steering back with the turn number"
                (fn []
                  (let [(m outs) (run (initial)
                                      [TURN
                                       (offer "late" {:tag 3})
                                       (offer "f" {:follow-up? true})
                                       REL
                                       (offer "idle")])
                        rel (. (of-type outs :released) 1)]
                    (assert.are.equal 1 rel.turn)
                    (assert.are.same ["late"] (texts rel.items))
                    (assert.are.equal 3 (. rel.items 1 :tag))
                    (assert.are.equal :none (kind m))
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
                    (assert.are.equal :turn (kind m))
                    (assert.are.equal 2 m.n)
                    (assert.are.same ["keep"] (texts m.steer))
                    (assert.are.equal 1 (length (of-type outs :released))))))
            (it "fences cancel on the holder id, for turns and exclusive jobs"
                (fn []
                  (let [(m outs) (run (initial)
                                      [{:type :cancel :hid 0}
                                       TURN
                                       {:type :cancel :hid 2}])]
                    (assert.is_false (cancel? m))
                    (assert.are.same [false false]
                                     (icollect [_ o (ipairs (of-type outs
                                                                     :cancel))]
                                       o.accepted?)))
                  (let [(m _) (run (initial) [TURN {:type :cancel :hid 1}])]
                    (assert.is_true (cancel? m))
                    (let [(m2 _) (run m [REL])]
                      (assert.is_false (cancel? m2) "release clears cancel")))
                  (let [(m _) (run (initial) [EXCL {:type :cancel :hid 1}])]
                    (assert.is_true (cancel? m) "exclusive jobs cancel too"))
                  ;; a fresh hid per acquire: the old one is stale for the next holder
                  (let [(m _) (run (initial)
                                   [EXCL REL TURN {:type :cancel :hid 1}])]
                    (assert.are.equal 2 m.hid)
                    (assert.is_false (cancel? m)))))
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
            (it "next-job starts the line that asked first, holding the turn in the same step"
                (fn []
                  (let [(m outs) (run (initial)
                                      [(offer "a" {:follow-up? true})
                                       {:type :next-job}
                                       (offer "b")
                                       (offer "c")
                                       {:type :next-job}
                                       {:type :next-job}])
                        started (of-type outs :started)]
                    (assert.are.equal 1 (length started))
                    (assert.are.equal "b" (. started 1 :item :text)
                                      "the typed line starts, ahead of the leftover")
                    (assert.are.equal 1 (. started 1 :turn))
                    (assert.are.equal :turn (kind m))
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
                        (_ outs) (tasks.step m {:type :next-job})]
                    (assert.are.equal "old"
                                      (. (of-type outs :started) 1 :item :text)))
                  (let [(_ outs) (run (initial)
                                      [EXCL
                                       (offer "x" {:turn 0})
                                       {:type :next-job}])]
                    (assert.are.equal 0 (length (of-type outs :started))
                                      "busy: :turn 0 refused, nothing starts"))))
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
                                    REL
                                    {:type :clear}
                                    TURN])]
                    (assert.are.equal :all m.modes.steering))))
            (it "keeps its invariants: steer only under a turn, start only idle with a follow-up"
                (fn []
                  (let [(m _) (run (initial)
                                   [(offer "a")
                                    {:type :next-job}
                                    TURN
                                    (offer "s")
                                    REL])]
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
                                          {:type :next-job})]
                    (assert.are.equal 5 m.n
                                      "the migrated start request opens turn 5")
                    (assert.are.equal :turn (kind m))
                    (assert.are.equal :all m.modes.steering)
                    (assert.are.same [] m.follow-up))))
            (it "rejects unknown inputs without changing state"
                (fn []
                  (let [(m outs) (tasks.step (initial) {:type :bogus})]
                    (assert.are.same (initial) m)
                    (assert.are.equal :rejected (. outs 1 :type)))))))

(describe "fen.core.tasks interpreter and job table"
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
                    (hold.run-turn (fn []
                                     (assert.is_true (. (tasks.offer! "x"
                                                                      {:tag 9})
                                                        :ok))))
                    (let [ret (icollect [_ e (ipairs seen)]
                                (when (= e.type :steering-returned) e))]
                      (assert.are.equal 1 (length ret))
                      (assert.are.same ["x"] (. ret 1 :texts))
                      (assert.are.same [9] (. ret 1 :tags))
                      (assert.are.equal 1 (. ret 1 :turn)))
                    (events.unregister-by-owner :tasks-test))))
            (it "a body releases on return, on error, and passes cancel markers through"
                (fn []
                  (let [(ok? v) (hold.run-turn #:done)]
                    (assert.is_true ok?)
                    (assert.are.equal :done v))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (let [(ok? err) (hold.run-turn #(error "boom"))]
                    (assert.is_false ok?)
                    (assert.is_truthy (string.find (tostring err) "boom" 1 true)))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (let [marker {}
                        (ok? err) (hold.run-turn #(error marker))]
                    (assert.is_false ok?)
                    (assert.are.equal marker err))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (assert.is_nil (next (. (require :fen.core.tasks.state) :jobs))
                                 "the job table is empty again")))
            (it "every holder id is registered with its coroutine before anything else runs"
                (fn []
                  (let [st (require :fen.core.tasks.state)
                        seen []]
                    (events.on :set-status-info
                               (fn [_]
                                 (let [h (tasks.holder)]
                                   (when (not= h.kind :none)
                                     (table.insert seen
                                                   (not= nil (. st.jobs h.hid))))))
                               :reg-test)
                    (let [co (hold.hold-turn!)]
                      (events.unregister-by-owner :reg-test)
                      (assert.are.same [true] seen)
                      (assert.are.equal co (. (tasks.current-job) :co))))))
            (it "a body builder that throws releases the holder (a)"
                (fn []
                  (let [r (tasks.offer-start! "go"
                                              {:make-turn (fn []
                                                            (error "builder"))})]
                    (assert.is_true r.started?)
                    (let [(ok? err) (coroutine.resume r.co)]
                      (assert.is_false ok?)
                      (assert.is_truthy (string.find (tostring err) "builder" 1
                                                     true)))
                    (assert.are.equal :none (. (tasks.holder) :kind))
                    (assert.is_nil (tasks.current-job)))))
            (it "a failing adopter is fed back as :spawn-failed and releases"
                (fn []
                  (let [errors []]
                    (events.on :error #(table.insert errors $1.error)
                               :spawn-test)
                    (let [r (tasks.offer-start! "go"
                                                {:make-turn (fn [] (fn [] nil))
                                                 :on-turn (fn []
                                                            (error "adopt"))})]
                      (events.unregister-by-owner :spawn-test)
                      (assert.is_false r.ok)
                      (assert.are.equal :none (. (tasks.holder) :kind))
                      (assert.is_nil (tasks.current-job))
                      (assert.are.equal 1 (length errors))))))
            (it "resume-current! resumes the job and forgets it when done; drop-current! abandons"
                (fn []
                  (hold.hold-turn! nil (fn [] (coroutine.yield) :fin))
                  (let [(ok? _ done?) (tasks.resume-current!)]
                    (assert.is_true ok?)
                    (assert.is_false done?))
                  (let [(ok? v done?) (tasks.resume-current!)]
                    (assert.is_true ok?)
                    (assert.are.equal :fin v)
                    (assert.is_true done?))
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (hold.hold-exclusive!)
                  (tasks.offer! "unread")
                  (tasks.drop-current!)
                  (assert.are.equal :none (. (tasks.holder) :kind))
                  (assert.is_nil (tasks.current-job))))
            (it "abandonment across /reload: a re-required tasks module still releases"
                (fn []
                  (let [co (hold.hold-exclusive! (fn [] (coroutine.yield)))]
                    (coroutine.resume co)
                    (tset package.loaded :fen.core.tasks nil)
                    (let [fresh (require :fen.core.tasks)]
                      (assert.are.equal :exclusive (. (fresh.holder) :kind))
                      (coroutine.resume co)
                      (assert.are.equal :none (. (fresh.holder) :kind)))
                    (tset package.loaded :fen.core.tasks tasks))))
            (it "request-job! starts now when idle, else waits behind running work and a pending turn"
                (fn []
                  (let [r (tasks.request-job! {:run (fn [] (coroutine.yield))})]
                    (assert.is_true r.started?)
                    (assert.are.equal :exclusive (. (tasks.holder) :kind))
                    (let [r2 (tasks.request-job! {:run (fn [] nil) :key :k})
                          r3 (tasks.request-job! {:run (fn [] nil) :key :k})]
                      (assert.is_false r2.started?)
                      (assert.are.equal r2.requested r3.requested "coalesced")
                      (assert.are.equal 1 (. (tasks.snapshot) :jobs))))
                  (tasks.drop-current!)
                  (tasks.offer! "turn first")
                  (let [r (tasks.next-job! {:make-turn (fn [] (fn [] nil))})]
                    (assert.are.equal :turn r.kind))))
            (it "run-exclusive! runs inline inside the current exclusive job's coroutine"
                (fn []
                  (var inner nil)
                  (let [co (hold.hold-exclusive! (fn [hid]
                                                   (set inner
                                                        (tasks.run-exclusive! {:run (fn [h]
                                                                                      [:ran
                                                                                       h])}))
                                                   (assert.is_true (tasks.in-exclusive-job?))
                                                   hid))]
                    (coroutine.resume co)
                    (assert.is_true inner.inline?)
                    (assert.are.equal :ran (. inner.result 1))
                    (assert.is_false (tasks.in-exclusive-job?)))))
            (it "take! returns texts and tagged items"
                (fn []
                  (hold.run-turn (fn []
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
                  ((. (require :fen.testing.tasks) :hold-turn!))
                  (tasks.offer! "unread")
                  (tasks.turn-end! 7)
                  (assert.are.equal :turn (. (tasks.holder) :kind)
                                    "wrong turn: no-op")
                  (assert.are.same ["unread"] (tasks.turn-end! 1))
                  (assert.are.equal :none (. (tasks.holder) :kind))))))

(describe "fen.core.tasks cancel fenced on the holder id"
          (fn []
            (before_each (fn [] (tasks.reset!)))
            (after_each (fn [] (tasks.reset!)))
            (it "a Ctrl-C read for turn N lands after N released: turn N+1 is not cancelled"
                (fn []
                  (let [co1 (hold.hold-turn! nil (fn [] (coroutine.yield)))
                        pressed-for (. (tasks.holder) :hid)]
                    (coroutine.resume co1)
                    (coroutine.resume co1)
                    (let [(_co2 hid2) (hold.hold-turn!)]
                      (assert.is_false (tasks.cancel! pressed-for))
                      (assert.is_false (tasks.cancel-requested? hid2))
                      (assert.is_false (. (tasks.holder) :cancel?))))))
            (it "a Ctrl-C meant for an exclusive job does not cancel the following turn"
                (fn []
                  (let [(co hid) (hold.hold-exclusive! (fn [] (coroutine.yield)))]
                    (coroutine.resume co)
                    (coroutine.resume co)
                    (let [(_ hid2) (hold.hold-turn!)]
                      (assert.is_false (tasks.cancel! hid))
                      (assert.is_false (tasks.cancel-requested? hid2))))))
            (it "cancel! arms the current turn or exclusive job; a stale hid is a no-op"
                (fn []
                  (assert.is_false (tasks.cancel! 0) "nothing holds")
                  (let [(_ hid) (hold.hold-exclusive!)]
                    (assert.is_false (tasks.cancel! (+ hid 1)))
                    (assert.is_true (tasks.cancel-current!))
                    (assert.is_true (tasks.cancel-requested? hid))
                    (tasks.release! hid)
                    (assert.is_false (tasks.cancel-requested? hid)))))
            (it "maps a pre-holder closure's state flag onto cancel! of the polling holder"
                (fn []
                  (let [(_ hid) (hold.hold-turn!)
                        st {:cancel-requested? true}]
                    (assert.is_true (tasks.cancel-requested? hid st))
                    (assert.is_nil st.cancel-requested?))))))
