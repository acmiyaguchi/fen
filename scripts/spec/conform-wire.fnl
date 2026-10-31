;; Conformance: the Quint wire model's decide/advance tables (spec/wire/conform.qnt,
;; exported as an ITF state) must agree with fen.util.wire_session pair by pair,
;; and must cover every state, control, and event the code's tables define.
;; Usage: fennel --add-fennel-path 'packages/util/src/?.fnl;packages/util/src/?/init.fnl' \
;;          scripts/spec/conform-wire.fnl <itf.json>
(local json (require :fen.util.json))
(local ws (require :fen.util.wire_session))

(local itf-path (. arg 1))
(local itf (with-open [f (assert (io.open itf-path :r))]
             (json.decode (f:read :a))))

(local state (. itf.states 1))

;; --negative (conform.sh): flip one model row so the comparison must fail.
(when (= (os.getenv :FEN_SPEC_CONFORM_CORRUPT) :1)
  (let [row (. state.decideRows 1)]
    (set row.next (.. row.next "-corrupted"))
    (set row.status :accepted)))

;; The model folds follow-up into steer and both queue actions into "queue".
(local CODE-KINDS {:steer [:steer :follow-up]})
(local CODE-ACTS {:queue {:queue-steering true :queue-follow-up true}})

(fn act-matches? [model-act code-act]
  (let [alts (. CODE-ACTS model-act)]
    (if alts (= true (. alts code-act)) (= model-act code-act))))

(var failures 0)
(var checked 0)
(fn fail! [msg]
  (set failures (+ failures 1))
  (print (.. "  mismatch: " msg)))

(each [_ row (ipairs state.decideRows)]
  (each [_ kind (ipairs (or (. CODE-KINDS row.kind) [row.kind]))]
    (set checked (+ checked 1))
    (let [entry (ws.decide row.st kind)
          where (.. "decide(" row.st ", " kind ")")]
      (when (not= entry.status row.status)
        (fail! (.. where " status: model " row.status ", code "
                   (tostring entry.status))))
      (when (and (not= row.status :rejected) (= entry.status row.status))
        (when (not (act-matches? row.act (tostring entry.action)))
          (fail! (.. where " action: model " row.act ", code "
                     (tostring entry.action))))
        (when (not= row.next entry.next)
          (fail! (.. where " next: model " row.next ", code "
                     (tostring entry.next))))))))

(each [_ row (ipairs state.advanceRows)]
  (set checked (+ checked 1))
  (let [entry (ws.advance row.st row.ev)
        where (.. "advance(" row.st ", " row.ev ")")]
    (if (not row.ok)
        (when entry
          (fail! (.. where ": model has no transition, code -> "
                     (tostring entry.next))))
        (not entry)
        (fail! (.. where ": model -> " row.next ", code has no transition"))
        (do
          (when (not (act-matches? row.act (tostring entry.action)))
            (fail! (.. where " action: model " row.act ", code "
                       (tostring entry.action))))
          (when (not= row.next entry.next)
            (fail! (.. where " next: model " row.next ", code "
                       (tostring entry.next))))))))

;; Completeness: every state, control, and internal event the code's tables
;; know must be covered by the model's lists, so a code-only row (e.g. a new
;; event) cannot escape the pairwise comparison above.
(fn covered [rows field]
  (let [seen {}]
    (each [_ row (ipairs rows)]
      (each [_ v (ipairs (or (. CODE-KINDS (. row field)) [(. row field)]))]
        (tset seen v true)))
    seen))

(let [model-states (covered state.decideRows :st)
      model-kinds (covered state.decideRows :kind)
      model-events (covered state.advanceRows :ev)
      advance-states (covered state.advanceRows :st)
      need! (fn [seen what name]
              (set checked (+ checked 1))
              (when (not (. seen name))
                (fail! (.. "code " what " " (tostring name)
                           " is not covered by the model"))))]
  (each [_ st (ipairs ws.STATES)]
    (need! model-states :state st)
    (need! advance-states "state (advance)" st))
  (each [st row (pairs ws.TRANSITIONS)]
    (need! model-states :state st)
    (each [kind _ (pairs row)]
      (need! model-kinds :control kind)))
  (each [_ kind (ipairs ws.CONTROLS)]
    (need! model-kinds :control kind))
  (each [st row (pairs ws.EVENTS)]
    (need! advance-states "state (advance)" st)
    (each [e _ (pairs row)]
      (need! model-events :event e))))

(print (string.format "wire conformance: %d pairs, %d mismatches" checked
                      failures))

(os.exit (if (= failures 0) 0 1))
