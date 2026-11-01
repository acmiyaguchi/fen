;; Holder conformance: Quint traces of spec/core/tasks/proofs/holder
;; `holderSpec` are replayed through the real pure step, `fen.core.tasks.step`.
;; Each model action becomes the matching machine input(s); after every step
;; the code's holder kind, turn number, steer and follow-up seqs, start
;; request and the line it starts first (firstUp), cancel flag, and drain modes must equal the model's, and every
;; issued line's disposition (taken, started, released, refused, cleared) and
;; the turn it is attributed to must equal the model's `why`/`whyN`.
;; At every state the replay also probes transitions the model forbids there
;; (replacing a holder, an exclusive holder while a turn start is pending,
;; take! without a turn, a follow-up while a steer line waits) and requires
;; the code to refuse them. Run by spec/core/tasks/conform.sh, which generates
;; the traces and sets FEN_SPEC_ITF_INDEX; not part of `make test`.

(local json (require :fen.util.json))
(local tasks (require :fen.core.tasks))

;; --negative: drop every body exit (a leaked holder), so a harness that
;; cannot see a missing release makes the check fail.
(local CORRUPT? (= (os.getenv :FEN_SPEC_CONFORM_CORRUPT) :1))

;; holderSpec bounds (see proofs/holder/model.qnt).
(local MAX-N 3)
(local MAX-BODY 4)
(local MAX-IDLE 2)

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn set-of [v]
  "ITF set -> sorted list of ints."
  (let [out (icollect [_ x (ipairs (or (?. v "#set") []))]
              (int x))]
    (table.sort out)
    out))

(fn map-of [v]
  (let [out {}]
    (each [_ [k x] (ipairs (or (?. v "#map") []))]
      (tset out (int k) (if (= (type x) :table) (int x) x)))
    out))

(fn pick [st name]
  (let [p (?. st "mbt::nondetPicks" name)]
    (when (and p (= p.tag :Some))
      (if (= (type p.value) :table) (int p.value) p.value))))

(local MODE {:one :one-at-a-time :all :all})

(fn seqs [items]
  "Code seqs are 1-based; the model's are 0-based."
  (let [out (icollect [_ item (ipairs items)] (- item.seq 1))]
    (table.sort out)
    out))

(fn same-list? [a b]
  (and (= (length a) (length b))
       (accumulate [ok true i x (ipairs a)]
         (and ok (= x (. b i))))))

(fn show [l]
  (.. "[" (table.concat (icollect [_ x (ipairs l)] (tostring x)) ",") "]"))

(fn waiting? [st]
  (and (= st.kind :none) st.start (> (length (set-of st.followUp)) 0)
       (< (int st.n) MAX-N)))

(fn forced-action [prev]
  "The step relation forces a move when a fairness bound is reached; the
   trace then labels it `step`. Recover which one from the previous state."
  (if (and prev.body (>= (int prev.heldFor) MAX-BODY)) :doBodyExit
      (and (waiting? prev) (>= (int prev.waitedFor) MAX-IDLE))
      ;; waiting? is startGuard here, so the forced tick starts the turn.
      :doStartTurn :unknown))

(fn find-out [outs typ]
  (var found nil)
  (each [_ o (ipairs outs)]
    (when (and (not found) (= o.type typ)) (set found o)))
  found)

(fn replay-trace [path]
  "Returns nil, or a mismatch description."
  (let [itf (with-open [f (assert (io.open path :r))]
              (json.decode (f:read :a)))
        why {}
        why-n {}]
    (var m (tasks.initial-machine))
    (var err nil)

    (fn dispose! [items w turn]
      (each [_ item (ipairs (or items []))]
        (tset why (- item.seq 1) w)
        (tset why-n (- item.seq 1) turn)))

    (fn record! [outs]
      (each [_ o (ipairs outs)]
        (case o.type
          :taken (dispose! o.items :taken o.turn)
          :started (dispose! [o.item] :started o.turn)
          :released (dispose! o.items :released o.turn)
          :refused (dispose! [o] :refused o.turn)
          :cleared (dispose! o.items :cleared o.turn))))

    (fn run! [input]
      (let [(m2 outs) (tasks.step m input)]
        (set m m2)
        (record! outs)
        outs))

    (fn probe [input]
      (let [(_ outs) (tasks.step m input)] outs))

    (each [i st (ipairs itf.states) &until err]
      (let [prev (. itf.states (- i 1))
            label (. st "mbt::actionTaken")
            action (if (= label :step) (forced-action prev) label)]
        (case action
          :doStartTurn (run! {:type :next-start})
          :doStartExclusive (run! {:type :acquire :kind :exclusive})
          :doBodyExit (when (not CORRUPT?) (run! {:type :release :hid m.hid}))
          :doOffer (let [t (pick st :t)]
                     (run! {:type :offer
                            :text (.. "line" (int prev.nextSeq))
                            :tag (pick st :g)
                            :turn (when (not= t -1) t)
                            :follow-up? (pick st :f)}))
          :doTakeSteer (run! {:type :take :queue :steering})
          :doTakeFollowUp (run! {:type :take :queue :follow-up})
          :doCancel (run! {:type :cancel :turn (pick st :m)})
          :doClearSteer (run! {:type :clear :queue :steering})
          :doClearFollowUp (run! {:type :clear :queue :follow-up})
          :doSetMode (run! {:type :set-mode
                            :queue (if (= (pick st :which) :steer) :steering
                                       :follow-up)
                            :mode (. MODE (pick st :mode))})
          :doStarved nil
          :init nil
          other (set err (.. path ": unmapped action " (tostring other))))
        (when (not err)
          (let [checks [[:kind st.kind m.kind]
                        [:n (int st.n) m.n]
                        [:start st.start m.start?]
                        [:firstUp
                         (int st.firstUp)
                         (if m.first-up (- m.first-up 1) -1)]
                        [:cancel st.cancel m.cancel?]
                        [:steerMode (. MODE st.steerMode) m.modes.steering]
                        [:followMode (. MODE st.followMode) m.modes.follow-up]]
                model-why (map-of st.why)
                model-why-n (map-of st.whyN)]
            (when (not (same-list? (set-of st.steer) (seqs m.steer)))
              (table.insert checks
                            [:steer
                             (show (set-of st.steer))
                             (show (seqs m.steer))]))
            (when (not (same-list? (set-of st.followUp) (seqs m.follow-up)))
              (table.insert checks
                            [:followUp
                             (show (set-of st.followUp))
                             (show (seqs m.follow-up))]))
            (for [q 0 (- (int st.nextSeq) 1)]
              (table.insert checks
                            [(.. "why[" q "]")
                             (. model-why q)
                             (or (. why q) "")])
              (when (not= (. model-why q) "")
                (table.insert checks
                              [(.. "whyN[" q "]")
                               (. model-why-n q)
                               (. why-n q)])))
            ;; Forbidden transitions, probed on the pure step (state unchanged).
            (when (not= st.kind :none)
              (each [_ kind (ipairs [:turn :exclusive])]
                (table.insert checks
                              [(.. "neverReplace:" kind)
                               true
                               (not= nil
                                     (find-out (probe {:type :acquire : kind})
                                               :hold-refused))])))
            (when (and (= st.kind :none) st.start
                       (> (length (set-of st.followUp)) 0))
              (table.insert checks
                            [:startBeatsExclusive
                             true
                             (not= nil
                                   (find-out (probe {:type :acquire
                                                     :kind :exclusive})
                                             :hold-refused))]))
            (when (not= st.kind :turn)
              (each [_ q (ipairs [:steering :follow-up])]
                (table.insert checks
                              [(.. "noTakeWithoutTurn:" q)
                               0
                               (length (. (find-out (probe {:type :take
                                                            :queue q})
                                                    :taken)
                                          :items))])))
            (when (and (= st.kind :turn) (> (length (set-of st.steer)) 0))
              (table.insert checks
                            [:steeringWins
                             0
                             (length (. (find-out (probe {:type :take
                                                          :queue :follow-up})
                                                  :taken)
                                        :items))]))
            (each [_ [name want got] (ipairs checks) &until err]
              (when (not= want got)
                (set err
                     (string.format "%s step %d (%s): %s model %s, code %s"
                                    path (- i 1) (tostring action) name
                                    (tostring want) (tostring got)))))))))
    err))

(describe "holder conformance (spec/core/tasks/proofs/holder holderSpec)"
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
