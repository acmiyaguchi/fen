;; Explicit scoped runtime recovery for the extension registry layer.
;;
;; This deliberately mutates only listed recoverable buckets.  Session history,
;; active session metadata, persistent UI identity, diagnostics, logs, source
;; overlays, and the extension state table itself remain intact.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(local REGISTRY-BUCKETS
  [:handlers
   :tools-extra
   :commands-extra
   :controls-extra
   :status-extra
   :panel-extra
   :presenters
   :introspectors-extra
   :providers
   :auth-backends
   :session-backends
   :input-handlers
   :prompt-fragments
   :extensions
   :reload-fingerprints])

(fn copy-list [items]
  (let [out []]
    (each [_ item (ipairs items)]
      (table.insert out item))
    out))

;; @doc fen.runtime_recovery.supported-scopes
;; kind: function
;; signature: (supported-scopes) -> [keyword]
;; summary: Return the small explicit set of runtime recovery scopes accepted by deferred reload requests.
;; tags: reload recovery runtime
(fn M.supported-scopes [] [:registries])

;; @doc fen.runtime_recovery.recover!
;; kind: function
;; signature: (recover! scope) -> RecoveryResult|nil, error
;; summary: Reset only the declared registry buckets for scope and preserve session, UI table identity, logs, diagnostics, overlays, and other persistent extension state.
;; tags: reload recovery runtime extensions
(fn M.recover! [scope]
  (if (not= scope :registries)
      (values nil "unsupported recovery scope")
      (do
        (each [_ bucket (ipairs REGISTRY-BUCKETS)]
          (let [value (. state bucket)]
            (when (= (type value) :table)
              (util.clear-table value))))
        ;; `hooks` is a persistent container with a declared before-tool
        ;; bucket, so clear the bucket rather than its table shape.
        (when (and state.hooks state.hooks.before-tool)
          (util.clear-table state.hooks.before-tool))
        ;; The session's selected name/info/handle are persistent identity, but
        ;; the old backend implementation is registry-owned and must not be
        ;; reused after the known bootstrap path installs a fresh backend.
        (when state.session
          (set state.session.backend nil))
        ;; Preserve `state.ui` itself: extension API wrappers keep this table's
        ;; identity across reload.  Its active presenter slot is recoverable.
        (when state.ui
          (set state.ui.slot nil))
        {:scope :registries
         :buckets (copy-list (doto (copy-list REGISTRY-BUCKETS)
                               (table.insert :hooks)))
         :preserved [:session :ui :logs :errors :dev-overlay :runtime-info]})))

M
