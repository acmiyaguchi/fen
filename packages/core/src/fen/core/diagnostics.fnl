;; Durable diagnostics metadata; fen.main injects it so core never reaches upward for build info.

(local state (require :fen.core.extensions.state))

(local M {})

(local bool #(if $1 true false))

(local RUNTIME-FIELDS
  [[:version tostring]
   [:gitRev tostring]
   [:gitShortRev tostring]
   [:dirty bool]
   [:source tostring]
   [:targetSystem tostring]
   [:buildSystem tostring]
   [:lastModified nil]])

(fn sanitize-runtime-info [info]
  (when (= (type info) :table)
    (let [out {}]
      (each [_ [key coerce] (ipairs RUNTIME-FIELDS)]
        (let [v (. info key)]
          (when (not= v nil)
            (tset out key (if coerce (coerce v) v)))))
      (when (next out) out))))

(fn M.set-runtime-info! [info]
  "Inject sanitized runtime/build metadata for later diagnostics."
  (set state.runtime-info (sanitize-runtime-info info))
  state.runtime-info)

(fn M.runtime-info []
  "Return sanitized runtime/build metadata, or nil if unavailable."
  state.runtime-info)

M
