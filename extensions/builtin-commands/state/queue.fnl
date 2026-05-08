;; Persistent /queue panel state. Not reloadable.

;; @doc fen.extensions.builtin_commands.state.queue.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent /queue panel showing queued steering and follow-up input.
;; tags: builtin commands state queue panel

;; @doc fen.extensions.builtin_commands.state.queue.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered /queue panel rows reused while queue state and terminal width remain stable.
;; tags: builtin commands state queue cache

;; @doc fen.extensions.builtin_commands.state.queue.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the /queue panel cache, supporting throttled refreshes during frequent repaints.
;; tags: builtin commands state queue cache

;; @doc fen.extensions.builtin_commands.state.queue.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached /queue rows so resize events rebuild wrapped queue entries.
;; tags: builtin commands state queue cache

{:visible? false
 :cached-rows nil
 :cached-at 0
 :cached-w 0}
