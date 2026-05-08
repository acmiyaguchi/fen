;; TUI redraw scheduling state.
;;
;; This tiny leaf module owns dirty/full-redraw flags and spinner defaults.
;; It depends only on persistent TUI state so input, ingest, and paint can
;; schedule repaints without depending on the full frame painter.

(local state (require :fen.extensions.tui.state))

(local M {})

;; @doc fen.extensions.tui.redraw.ensure-defaults!
;; kind: function
;; signature: (ensure-defaults!) -> nil
;; summary: Backfill persistent redraw and spinner scheduling fields after reloads.
;; tags: tui redraw state reload
(fn M.ensure-defaults! []
  (when (= state.dirty? nil) (set state.dirty? true))
  (when (= state.force-redraw? nil) (set state.force-redraw? false))
  (when (= state.spinner-ticks nil) (set state.spinner-ticks 0))
  (when (= state.spinner-interval-ticks nil) (set state.spinner-interval-ticks 8))
  (when (= state.animations? nil) (set state.animations? true)))

;; @doc fen.extensions.tui.redraw.invalidate!
;; kind: function
;; signature: (invalidate!) -> nil
;; summary: Mark the TUI dirty so the next presenter-loop pass repaints the terminal.
;; tags: tui redraw dirty
(fn M.invalidate! []
  "Mark the TUI as needing a repaint on the next presenter-loop pass."
  (M.ensure-defaults!)
  (set state.dirty? true))

;; @doc fen.extensions.tui.redraw.invalidate-full!
;; kind: function
;; signature: (invalidate-full!) -> nil
;; summary: Request a cache-clearing repaint for resize, reload, and display toggles that invalidate wrapped rows.
;; tags: tui redraw cache
(fn M.invalidate-full! []
  "Request a cache-clearing repaint. Used for resize/reload/display toggles
   where wrapped transcript rows or termbox front-buffer assumptions may be stale."
  (M.ensure-defaults!)
  (set state.force-redraw? true)
  (set state.dirty? true))

M
