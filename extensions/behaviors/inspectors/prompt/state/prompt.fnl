;; Persistent /prompt panel state. Not reloadable.

;; @doc fen.extensions.prompt.state.prompt.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent /prompt panel that previews assembled system prompt fragments.
;; tags: builtin commands state prompt panel

;; @doc fen.extensions.prompt.state.prompt.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered /prompt panel rows reused while prompt content and terminal width remain stable.
;; tags: builtin commands state prompt cache

;; @doc fen.extensions.prompt.state.prompt.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the /prompt panel cache, used to avoid rebuilding prompt rows on every repaint.
;; tags: builtin commands state prompt cache

;; @doc fen.extensions.prompt.state.prompt.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached /prompt rows so resize events rebuild wrapped preview text.
;; tags: builtin commands state prompt cache

{:visible? false
 :cached-rows nil
 :cached-at 0
 :cached-w 0}
