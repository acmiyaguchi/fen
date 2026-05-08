;; Persistent /extensions panel state. Not reloadable.

;; @doc fen.extensions.extensions_inspector.state.extensions.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent /extensions panel, kept across hot reloads until dismissed or toggled.
;; tags: builtin commands state extensions panel

;; @doc fen.extensions.extensions_inspector.state.extensions.selected-name
;; kind: data
;; signature: string|nil
;; summary: Currently selected extension name used by the /extensions panel to keep focus stable while rows refresh.
;; tags: builtin commands state extensions selection

;; @doc fen.extensions.extensions_inspector.state.extensions.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered /extensions panel rows reused between paints when width and selection have not changed.
;; tags: builtin commands state extensions cache

;; @doc fen.extensions.extensions_inspector.state.extensions.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the /extensions panel row cache, allowing throttled refreshes of registry-derived content.
;; tags: builtin commands state extensions cache

;; @doc fen.extensions.extensions_inspector.state.extensions.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached /extensions rows so resizes invalidate wrapped panel content.
;; tags: builtin commands state extensions cache

;; @doc fen.extensions.extensions_inspector.state.extensions.cached-selected-name
;; kind: data
;; signature: string|nil
;; summary: Extension selection value associated with cached rows so focus changes trigger a panel rerender.
;; tags: builtin commands state extensions cache selection

{:visible? false
 :selected-name nil
 :cached-rows nil
 :cached-at 0
 :cached-w 0
 :cached-selected-name nil}
