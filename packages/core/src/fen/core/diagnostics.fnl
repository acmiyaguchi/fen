;; Shared helpers for durable diagnostics.
;;
;; The core package should not reach upward into the CLI/runtime package for
;; build metadata. fen.main injects sanitized version info at startup; core and
;; first-party providers only read the cached diagnostic metadata here.

(local state (require :fen.core.extensions.state))

(local M {})

(local bool #(if $1 true false))

;; Fields copied from fen.version.info into diagnostics, with a coercion to
;; apply when present. nil coerce keeps the value as-is.
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

;; @doc fen.core.diagnostics.set-runtime-info!
;; kind: function
;; signature: (set-runtime-info! info) -> table|nil
;; summary: Store sanitized runtime/build metadata for durable error/provider diagnostics.
;; tags: diagnostics version runtime
(fn M.set-runtime-info! [info]
  "Inject sanitized runtime/build metadata for later diagnostics."
  (set state.runtime-info (sanitize-runtime-info info))
  state.runtime-info)

;; @doc fen.core.diagnostics.runtime-info
;; kind: function
;; signature: (runtime-info) -> table|nil
;; summary: Return runtime/build metadata previously injected by fen.main, if available.
;; tags: diagnostics version runtime
(fn M.runtime-info []
  "Return sanitized runtime/build metadata, or nil if unavailable."
  state.runtime-info)

M
