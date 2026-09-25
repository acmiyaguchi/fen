;; Stable facade over fen.core.extensions.register.input for non-slash input dispatch.

(local registry (require :fen.core.extensions.register.input))

(local M {})

;; @doc fen.core.extensions.input.handle
;; kind: function
;; signature: (handle input ctx) -> action
;; summary: Dispatch non-slash user input through the ordered input-handler pipeline.
;; tags: extensions input dispatch
(fn M.handle [input ctx]
  (registry.handle input ctx))

M
