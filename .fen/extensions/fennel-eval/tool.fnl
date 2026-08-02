;; Dev-only in-process Fennel evaluation for a live fen agent.
;;
;; This is deliberately not sandboxed: the operator enables it explicitly via
;; FEN_FENNEL_EVAL=1, and evaluated code has the same process access as fen.

(local fennel (require :fennel))
(local types (require :fen.core.types))

(local MAX-BYTES 8192)

(fn result [text is-error?]
  {:content [(types.text-block (or text ""))]
   :is-error? (or is-error? false)})

(fn truncate [s max-bytes]
  (let [cap (or max-bytes MAX-BYTES)]
    (if (> (length s) cap)
        (.. (string.sub s 1 cap) "\n[truncated: kept " (tostring cap) " bytes]")
        s)))

(fn live-env [ctx extensions]
  "Expose the ordinary process globals plus live runtime handles to eval."
  (let [env {}]
    (each [k v (pairs _G)]
      (tset env k v))
    (tset env :agent (?. ctx :agent))
    (tset env :state (?. ctx :state))
    (tset env :extensions extensions)
    (tset env :ctx ctx)
    env))

(fn execute [args ctx extensions ?yield-fn]
  (if (or (not args) (not args.expr))
      (result "error: missing expr" true)
      (do
        (when ?yield-fn (?yield-fn))
        (let [(ok? value-or-err)
              (pcall
                (fn []
                  (let [value (fennel.eval args.expr
                                           {:env (live-env ctx extensions)
                                            :filename "fennel_eval"})]
                    (truncate (fennel.view value {:one-line? false
                                                  :max-sparse-gap 3})
                              args.max_bytes)))) ]
          (if ok?
              (result value-or-err false)
              (result (.. "error: " (tostring value-or-err)) true))))))

(fn register [api]
  (api.register :tool
                {:name :fennel_eval
                 :label "Fennel Eval"
                 :description "Evaluate a Fennel expression against the live agent runtime. Dev-only escape hatch when agent_state is too narrow. Result is rendered via fennel.view and truncated."
                 :parameters {:type :object
                              :properties {:expr {:type :string}
                                           :max_bytes {:type :integer}}
                              :required [:expr]}
                 :execute (fn [args ctx ?yield-fn]
                            (execute args ctx api ?yield-fn))})
  true)

{:register register
 :execute execute
 :live-env live-env}
