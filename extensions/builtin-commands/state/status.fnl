;; Persistent /status panel state. Not reloadable.

;; @doc fen.extensions.builtin_commands.state.status.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent /status panel showing runtime, model, session, and context details.
;; tags: builtin commands state status panel

;; @doc fen.extensions.builtin_commands.state.status.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered /status panel rows reused while status inputs and terminal width remain stable.
;; tags: builtin commands state status cache

;; @doc fen.extensions.builtin_commands.state.status.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the /status panel cache, used to throttle recomputation of derived runtime details.
;; tags: builtin commands state status cache

;; @doc fen.extensions.builtin_commands.state.status.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached /status rows so resize events rebuild aligned panel text.
;; tags: builtin commands state status cache

{:visible? false
 :cached-rows nil
 :cached-at 0
 :cached-w 0}
