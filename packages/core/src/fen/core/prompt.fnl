;; Generic system prompt assembly.
;;
;; Policy-specific prompt text is contributed by extensions through ordered
;; system-prompt fragments. Core only builds the minimal render context and
;; joins the rendered fragments.

(local extensions (require :fen.core.extensions))

(local M {})

;; @doc fen.core.prompt.build-context
;; kind: function
;; signature: (build-context opts tools) -> table
;; summary: Build the minimal context table passed to registered system-prompt fragment renderers.
;; tags: prompt extensions context
(fn M.build-context [opts tools]
  {:opts (or opts {})
   :tools (or tools [])})

;; @doc fen.core.prompt.build
;; kind: function
;; signature: (build opts tools) -> string
;; summary: Render all extension-contributed system-prompt fragments for opts/tools and return an empty string when none render.
;; tags: prompt extensions
(fn M.build [opts tools]
  (or (extensions.render-prompt (M.build-context opts tools))
      ""))

M
