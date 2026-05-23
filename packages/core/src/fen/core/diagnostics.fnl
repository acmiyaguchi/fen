;; Shared helpers for durable diagnostics.
;;
;; Keep this module dependency-light and best-effort: diagnostic paths should
;; never fail because runtime/build metadata is unavailable or malformed.

(local M {})

(fn put! [out k v ?coerce]
  (when (not= v nil)
    (tset out k (if ?coerce (?coerce v) v))
    true))

(fn sanitize-runtime-info [info]
  (when (= (type info) :table)
    (let [out {}
          string! tostring]
      (var any? false)
      (when (put! out :version info.version string!) (set any? true))
      (when (put! out :gitRev info.gitRev string!) (set any? true))
      (when (put! out :gitShortRev info.gitShortRev string!) (set any? true))
      (when (put! out :dirty info.dirty #(if $1 true false)) (set any? true))
      (when (put! out :source info.source string!) (set any? true))
      (when (put! out :targetSystem info.targetSystem string!) (set any? true))
      (when (put! out :buildSystem info.buildSystem string!) (set any? true))
      (when (put! out :lastModified info.lastModified) (set any? true))
      (when any? out))))

;; @doc fen.core.diagnostics.runtime-info
;; kind: function
;; signature: (runtime-info) -> table|nil
;; summary: Best-effort sanitized fen.version.info metadata for durable error/provider diagnostics.
;; tags: diagnostics version runtime
(fn M.runtime-info []
  "Return sanitized runtime/build metadata, or nil if unavailable."
  (let [(ok? version) (pcall require :fen.version)]
    (when (and ok? version (= (type version.info) :function))
      (let [(info-ok? info) (pcall (fn [] (version.info)))]
        (when info-ok?
          (sanitize-runtime-info info))))))

M
