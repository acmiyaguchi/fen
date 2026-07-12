;; Compact tab bar for presenter workspaces.

(local state (require :fen.extensions.tui.state))
(local workspaces (require :fen.extensions.tui.workspaces))

(local M {})

(fn fit [s width]
  (let [s (tostring (or s ""))]
    (if (<= (length s) width) s
        (if (> width 1) (.. (string.sub s 1 (- width 1)) "…") "…"))))

(fn tab-label [ws active?]
  (let [title (or ws.title (tostring ws.id))
        activity (or ws.activity-count 0)
        dirty? ws.dirty?
        suffix (.. (if (> activity 0) (.. "*" (tostring activity)) "")
                   (if dirty? "!" ""))]
    (.. (if active? "[" " ") title suffix (if active? "]" " "))))

(fn M.height [_ctx]
  ;; Keep the main-session frame byte-for-byte compatible until a second
  ;; workspace exists.
  (if (> (length (workspaces.list)) 1) 1 0))

(fn M.render [ctx]
  (let [w (math.max 1 (or ctx.w state.tb-cols 1))
        labels []]
    (each [_ ws (ipairs (workspaces.list))]
      (table.insert labels (tab-label ws (= ws.id state.active-workspace-id))))
    [{:text (fit (table.concat labels " ") w) :style :dim}]))

(fn M.spec []
  {:name :tabs :placement :below-status :order 5
   :height M.height :render M.render})

M
