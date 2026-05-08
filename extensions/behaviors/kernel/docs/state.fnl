;; Persistent /docs panel state. Not reloadable.

;; @doc fen.extensions.docs.state.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent /docs panel that lists generated API and contract entries.
;; tags: docs state panel

;; @doc fen.extensions.docs.state.selected-topic
;; kind: data
;; signature: string|nil
;; summary: Current /docs topic selection used to keep the active group stable across row refreshes.
;; tags: docs state selection

;; @doc fen.extensions.docs.state.selected-name
;; kind: data
;; signature: string|nil
;; summary: Current /docs entry selection within the active topic for keyboard focus and detail rendering.
;; tags: docs state selection

;; @doc fen.extensions.docs.state.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered /docs panel rows reused while topic, selection, and terminal width are unchanged.
;; tags: docs state cache

;; @doc fen.extensions.docs.state.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the /docs panel cache, allowing registry documentation to be refreshed predictably.
;; tags: docs state cache

;; @doc fen.extensions.docs.state.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached /docs rows so resize events rebuild wrapped documentation text.
;; tags: docs state cache

;; @doc fen.extensions.docs.state.cached-selected-topic
;; kind: data
;; signature: string|nil
;; summary: Topic selection value associated with cached /docs rows so topic changes invalidate the panel cache.
;; tags: docs state cache selection

;; @doc fen.extensions.docs.state.cached-selected-name
;; kind: data
;; signature: string|nil
;; summary: Entry selection value associated with cached /docs rows so focus changes invalidate detail rendering.
;; tags: docs state cache selection

{:visible? false
 :selected-topic nil
 :selected-name nil
 :cached-rows nil
 :cached-at 0
 :cached-w 0
 :cached-selected-topic nil
 :cached-selected-name nil}
