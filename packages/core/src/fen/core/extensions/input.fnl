;; Public input-handler dispatcher facade.
;;
;; The per-kind registry implementation lives under
;; `fen.core.extensions.register.input` with the other register kinds. This
;; small facade is the stable call site for runtime code and extensions that
;; need to dispatch non-slash input through the ordered pipeline.

(local registry (require :fen.core.extensions.register.input))

(local M {})

;; @doc fen.core.extensions.input.handle
;; kind: function
;; signature: (handle input ctx) -> action
;; summary: Dispatch non-slash user input through the ordered input-handler pipeline.
;; tags: extensions input dispatch
(fn M.handle [input ctx]
  (registry.handle input ctx))

;; @doc fen.core.extensions.input.handle-input
;; kind: function
;; signature: (handle-input input ctx) -> action
;; summary: Alias for handle, matching the extension-level input dispatcher vocabulary.
;; tags: extensions input dispatch
(fn M.handle-input [input ctx]
  (M.handle input ctx))

M
