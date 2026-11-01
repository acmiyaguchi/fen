;; Turn-mailbox conformance: Quint traces of spec/core/tasks requestsSpec are
;; replayed through the real pure step, `fen.core.tasks.step`. Each model
;; action becomes the matching machine input; after every step the code's
;; turn, running flag, queue lengths, and idle-start request must equal the
;; model's, and the code's outputs (:inject, :returned, :start-turn, accepted
;; acks, clears) must account for every line exactly as the model's ghost
;; counters do (steeringConservedInv, followUpsConservedInv).
;; At every state the replay also probes the transitions the model forbids
;; there (steer or take while idle, follow-up while steering is queued) and
;; requires the code to refuse them. Request actions (open/answer/tick/
;; reload/resolver) and the /reload-/handoff busy flag do not touch the
;; mailbox and are skipped. Run by spec/core/tasks/conform.sh, which generates the
;; traces and sets FEN_SPEC_ITF_INDEX; not part of `make test`.

(local json (require :fen.util.json))
(local tasks (require :fen.core.tasks))

;; --negative: drop every turn end, so a harness that cannot see a turn's
;; leftovers being handed back makes the check fail.
(local CORRUPT? (= (os.getenv :FEN_SPEC_CONFORM_CORRUPT) :1))

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn pick [st name]
  (let [p (?. st "mbt::nondetPicks" name)]
    (when (and p (= p.tag :Some)) p.value)))

(fn initial []
  {:turn 0
   :running? false
   :mailbox []
   :follow-ups []
   :modes {:steering :one-at-a-time :follow-up :one-at-a-time}
   :next-id 1
   :idle-start? false})

(fn find-out [outs typ ?queue]
  (var found nil)
  (each [_ o (ipairs outs)]
    (when (and (not found) (= o.type typ)
               (or (= ?queue nil) (= o.queue ?queue)))
      (set found o)))
  found)

(fn replay-trace [path]
  "Returns nil, or a mismatch description."
  (let [itf (with-open [f (assert (io.open path :r))]
              (json.decode (f:read :a)))
        g {:sAcc 0 :sInj 0 :sRet 0 :sDrop 0 :fAcc 0 :fInj 0 :fStart 0 :fDrop 0}]
    (var m (initial))
    (var err nil)

    (fn run! [input]
      (let [(m2 outs) (tasks.step m input)]
        (set m m2)
        outs))

    (fn accepted? [outs]
      (= :accepted (?. (find-out outs :ack) :status)))

    (each [i st (ipairs itf.states) &until err]
      (let [action (. st "mbt::actionTaken")
            prev (. itf.states (- i 1))]
        (case action
          :doStartTurn (run! {:type :turn-start})
          :doEndTurn (when (not CORRUPT?)
                       (let [r (find-out (run! {:type :turn-end}) :returned)]
                         (set g.sRet (+ g.sRet (length (or (?. r :texts) []))))))
          :doQueueSteer (when (accepted? (run! {:type :steer
                                                :text (.. "s" g.sAcc)}))
                          (set g.sAcc (+ g.sAcc 1)))
          :doInjectSteer (do
                           (run! {:type :set-mode
                                  :queue :steering
                                  :mode (if (pick st :allMode) :all
                                            :one-at-a-time)})
                           (let [o (find-out (run! {:type :take-steering})
                                             :inject)]
                             (set g.sInj (+ g.sInj (length o.texts)))))
          :doQueueFollowUp (let [start? (and (pick st :hr)
                                             (not (. prev :running)))]
                             (when (accepted? (run! {:type :follow-up
                                                     :text (.. "f" g.fAcc)
                                                     :start-if-idle? start?}))
                               (set g.fAcc (+ g.fAcc 1))))
          :doInjectFollowUp (do
                              (run! {:type :set-mode
                                     :queue :follow-up
                                     :mode (if (pick st :allMode) :all
                                               :one-at-a-time)})
                              (let [o (find-out (run! {:type :take-follow-up})
                                                :inject)]
                                (set g.fInj (+ g.fInj (length o.texts)))))
          :doIdleStart (when (find-out (run! {:type :idle-tick}) :start-turn)
                         (set g.fStart (+ g.fStart 1)))
          :doTypedBusy (if m.running?
                           (when (accepted? (run! {:type :steer
                                                   :text (.. "s" g.sAcc)}))
                             (set g.sAcc (+ g.sAcc 1)))
                           (when (accepted? (run! {:type :follow-up
                                                   :text (.. "f" g.fAcc)}))
                             (set g.fAcc (+ g.fAcc 1))))
          :doClearSteering (do
                             (set g.sDrop (+ g.sDrop (length m.mailbox)))
                             (run! {:type :clear :queue :steering}))
          :doClearFollowUps (do
                              (set g.fDrop (+ g.fDrop (length m.follow-ups)))
                              (run! {:type :clear :queue :follow-up})))
        (let [checks [[:running (. st :running) m.running?]
                      [:turnNo (int st.turnNo) m.turn]
                      [:sLen (int st.sLen) (length m.mailbox)]
                      [:fLen (int st.fLen) (length m.follow-ups)]
                      [:idleStart (. st :idleStart) m.idle-start?]]]
          (each [k _ (pairs g)]
            (table.insert checks [k (int (. st k)) (. g k)]))
          ;; Forbidden transitions: where the model's guard is false, the code
          ;; must refuse too (probed on the pure step, state unchanged).
          (let [running? (. st :running)
                steering-left? (> (int st.sLen) 0)
                (_ steer-outs) (tasks.step m {:type :steer :text "probe"})
                (_ take-s) (tasks.step m {:type :take-steering})
                (_ take-f) (tasks.step m {:type :take-follow-up})]
            (when (not running?)
              (table.insert checks
                            [:steerRefusedWhenIdle
                             :rejected
                             (?. (find-out steer-outs :ack) :status)])
              (table.insert checks
                            [:noSteeringInjectWhenIdle
                             0
                             (length (. (find-out take-s :inject) :texts))]))
            (when (or (not running?) steering-left?)
              (table.insert checks
                            [:followUpGuard
                             0
                             (length (. (find-out take-f :inject) :texts))])))
          (each [_ [name want got] (ipairs checks) &until err]
            (when (not= want got)
              (set err
                   (string.format "%s step %d (%s): %s model %s, code %s" path
                                  (- i 1) (tostring action) name (tostring want)
                                  (tostring got))))))))
    err))

(describe "turn mailbox conformance (spec/core/tasks requestsSpec)"
          (fn []
            (it "fen.core.tasks.step follows every replayed model trace"
                (fn []
                  (let [index (os.getenv :FEN_SPEC_ITF_INDEX)]
                    (if (not index)
                        (pending "set FEN_SPEC_ITF_INDEX (spec/core/tasks/conform.sh)")
                        (let [failures []]
                          (var n 0)
                          (each [line (io.lines index)]
                            (set n (+ n 1))
                            (let [e (replay-trace line)]
                              (when e (table.insert failures e))))
                          (print (string.format "tasks conformance: %d traces, %d mismatched"
                                                n (length failures)))
                          (each [_ e (ipairs failures)] (print (.. "  " e)))
                          (assert.are.equal 0 (length failures)))))))))
