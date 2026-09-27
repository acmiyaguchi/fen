;; Persistent handoff suggestion state. Not reloadable, so an answer that
;; arrives after /reload still compares against the latest submitted prompt.

;; @doc fen.extensions.handoff.state.pending
;; kind: data
;; signature: table|nil
;; summary: Identity token of the prompt whose topic-shift decision may still surface a hint; replaced on each prompt and cleared by any later user message or conversation reset.
;; tags: handoff state hint decide

{:pending nil}
