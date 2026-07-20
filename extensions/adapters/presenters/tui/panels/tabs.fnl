;; Compact tab bar for presenter workspaces.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local workspaces (require :fen.extensions.tui.workspaces))

(local M {})

(local TC
  {:inactive (bor tb.WHITE tb.DIM)
   ;; Reverse video follows the terminal theme while giving only the selected
   ;; tab a contrasting background.
   :active (bor tb.WHITE tb.REVERSE)
   :separator tb.DEFAULT})

(fn closable? [ws]
  (= ws.kind :subagent-job))

(fn tab-parts [ws]
  (let [activity (or ws.activity-count 0)
        unread (if (> activity 0) (.. " +" (tostring activity)) "")
        title (or ws.title (tostring ws.id))]
    (if (closable? ws)
        {:prefix (.. " " title unread " ") :close "x" :suffix " "}
        {:prefix (.. " " title unread " ") :close nil :suffix ""})))

(fn tab-text [ws]
  (let [parts (tab-parts ws)]
    (.. parts.prefix (or parts.close "") (or parts.suffix ""))))

(fn M.height [_ctx]
  ;; Keep the main-session frame byte-for-byte compatible until a second
  ;; workspace exists.
  (if (> (length (workspaces.list)) 1) 1 0))

(fn M.layout [width]
  "Build the visible tab segments and click regions from one geometry model."
  (let [w (math.max 0 (or width state.tb-cols 0))
        segments []
        hits []]
    (var x 0)
    (each [i ws (ipairs (workspaces.list))]
      (when (< x w)
        (when (> i 1)
          (table.insert segments {:text " " :attr TC.separator})
          (set x (+ x 1)))
        (when (< x w)
          (let [parts (tab-parts ws)
                text (.. parts.prefix (or parts.close "") (or parts.suffix ""))
                visible (math.min (length text) (- w x))
                active? (= ws.id state.active-workspace-id)
                attr (if active? TC.active TC.inactive)
                close-x (and parts.close (+ x (length parts.prefix)))]
            (table.insert segments {:text text :attr attr})
            (when (> visible 0)
              (table.insert hits {:x0 x :x1 (+ x visible -1)
                                  :workspace-id ws.id
                                  :action :activate})
              (when (and close-x (< close-x (+ x visible)))
                (table.insert hits {:x0 close-x :x1 close-x
                                    :workspace-id ws.id
                                    :action :close})))
            (set x (+ x (length text)))))))
    {:segments segments :hits hits}))

(fn M.action-at [x width]
  (var action nil)
  (each [_ hit (ipairs (. (M.layout width) :hits))]
    (when (and (>= x hit.x0) (<= x hit.x1))
      (set action {:workspace-id hit.workspace-id
                   :action (or hit.action :activate)})))
  action)

(fn M.tab-at [x width]
  (let [hit (M.action-at x width)]
    (and hit hit.workspace-id)))

(fn M.render [ctx]
  (let [model (M.layout (math.max 1 (or ctx.w state.tb-cols 1)))]
    [{:segments model.segments}]))

(fn M.spec []
  {:name :tabs :placement :below-status :order 5
   :height M.height :render M.render})

M
