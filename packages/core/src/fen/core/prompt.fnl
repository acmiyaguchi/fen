;; Generic system prompt assembly.
;;
;; Policy-specific prompt text is contributed by extensions through ordered
;; system-prompt fragments. Core only builds the minimal render context and
;; joins the rendered fragments.

(local extensions (require :fen.core.extensions))

(local M {})

(fn M.build-context [opts tools]
  {:opts (or opts {})
   :tools (or tools [])})

(fn M.build [opts tools]
  (or (extensions.render-prompt (M.build-context opts tools))
      ""))

M
