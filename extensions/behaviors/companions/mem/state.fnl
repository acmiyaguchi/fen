;; Persistent memory diagnostics state. Not reloadable.

;; @doc fen.extensions.mem.state.samples
;; kind: data
;; signature: [number]
;; summary: Rolling Lua heap samples used by the memory diagnostics panel to render its history sparkline.
;; tags: mem state samples panel

;; @doc fen.extensions.mem.state.max-samples
;; kind: data
;; signature: number
;; summary: Maximum number of memory samples retained for the diagnostics panel history window.
;; tags: mem state samples config

;; @doc fen.extensions.mem.state.peak-kb
;; kind: data
;; signature: number
;; summary: Largest observed Lua heap size in kilobytes, used for peak reporting and sparkline scaling.
;; tags: mem state samples peak

;; @doc fen.extensions.mem.state.visible?
;; kind: data
;; signature: boolean
;; summary: Visibility flag for the persistent memory diagnostics panel toggled by the /mem command.
;; tags: mem state panel

;; @doc fen.extensions.mem.state.run-state
;; kind: data
;; signature: table|nil
;; summary: Last presenter run-state snapshot used by the memory panel to display agent and session details.
;; tags: mem state runtime panel

;; @doc fen.extensions.mem.state.cached-rows
;; kind: data
;; signature: [PresenterRow]|nil
;; summary: Cached rendered memory panel rows reused between paints to avoid noisy heap recomputation.
;; tags: mem state cache panel

;; @doc fen.extensions.mem.state.cached-at
;; kind: data
;; signature: number
;; summary: Timestamp for the memory panel cache, supporting its one-hertz refresh throttle.
;; tags: mem state cache panel

;; @doc fen.extensions.mem.state.cached-w
;; kind: data
;; signature: number
;; summary: Terminal width associated with cached memory rows so resize events rebuild the bordered panel.
;; tags: mem state cache panel

{:samples []
 :max-samples 24
 :peak-kb 0
 :visible? false
 :run-state nil
 :cached-rows nil
 :cached-at 0
 :cached-w 0}
