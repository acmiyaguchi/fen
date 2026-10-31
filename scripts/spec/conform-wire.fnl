;; Conformance: the Quint wire model's decide/advance tables (spec/wire/conform.qnt,
;; exported as an ITF state) must agree with fen.util.wire_session pair by pair.
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

(print (string.format "wire conformance: %d pairs, %d mismatches" checked
                      failures))

(os.exit (if (= failures 0) 0 1))
