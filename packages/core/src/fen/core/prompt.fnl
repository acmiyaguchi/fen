;; Generic system prompt assembly.
;;
;; Policy-specific prompt text is contributed by extensions through ordered
;; system-prompt fragments. Core only builds the minimal render context and
;; joins the rendered fragments.

(local prompt-registry (require :fen.core.extensions.register.prompt))

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
  (or (prompt-registry.render (M.build-context opts tools))
      ""))

;; @doc fen.core.prompt.stats
;; kind: function
;; signature: (stats opts tools) -> [PromptFragmentStat]
;; summary: Return per-fragment rendered-size metadata (bytes and approximate tokens) for the opts/tools context without exposing fragment text.
;; tags: prompt extensions introspection
(fn M.stats [opts tools]
  (prompt-registry.stats (M.build-context opts tools)))

M
