;; Compact single-row tab bar for presenter workspaces.

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
  (workspaces.closable? ws))

(fn active? [ws]
  (= ws.id state.active-workspace-id))

(fn has-activity? [ws]
  (and (not (active? ws))
       (or ws.dirty? (> (or ws.activity-count 0) 0))))

(fn truncate [text width]
  (let [s (tostring (or text ""))
        width (math.max 0 width)]
    (if (<= (length s) width) s
        (<= width 0) ""
        (= width 1) "~"
        (.. (string.sub s 1 (- width 1)) "~"))))

(fn desired-width [ws]
  (+ 2 (length (or ws.title (tostring ws.id)))
     (if (has-activity? ws) 1 0)
     (if (closable? ws) 2 0)))

(fn tab-model [ws max-width]
  (let [max-width (math.max 3 max-width)]
    (var activity? (has-activity? ws))
    (var close? (and (closable? ws) (>= max-width 6)))
    (var fixed (+ 2 (if activity? 1 0) (if close? 2 0)))
    ;; Preserve at least one title cell; on very narrow rows activity wins over
    ;; the mouse-only close glyph because Ctrl-W remains available.
    (when (< (- max-width fixed) 1)
      (set close? false)
      (set fixed (+ 2 (if activity? 1 0))))
    (when (< (- max-width fixed) 1)
      (set activity? false)
      (set fixed 2))
    (let [title (truncate (or ws.title (tostring ws.id)) (- max-width fixed))
          text (.. "[" title (if activity? "*" "")
                   (if close? " x" "") "]")
          close-pos (and close? (string.find text " x]" 1 true))]
      {:text text
       ;; close-pos is the 0-based column of x because string.find points at
       ;; the preceding space using Lua's 1-based index.
       :close-offset close-pos})))

(fn visible-workspaces [width]
  (let [all (workspaces.list)
        n (length all)]
    (if (or (<= n 1) (>= width (- (* 4 n) 1)))
        all
        (let [active (workspaces.active)
              main (workspaces.find :main-session)]
          (if (and main (not= active.id main.id) (>= width 7))
              [main active]
              [active])))))

(fn M.height [_ctx]
  ;; Keep the one-main-tab frame byte-for-byte compatible.
  (if (> (length (workspaces.list)) 1) 1 0))

(fn M.layout [width]
  "Build width-bounded tab segments and click regions from one model."
  (let [w (math.max 0 (or width state.tb-cols 0))
        tabs (visible-workspaces w)
        n (length tabs)
        segments []
        hits []]
    (var x 0)
    (each [i ws (ipairs tabs)]
      (when (< x w)
        (when (> i 1)
          (table.insert segments {:text " " :attr TC.separator})
          (set x (+ x 1)))
        (when (< x w)
          (let [left (- n i)
                ;; Reserve three cells plus separators for each later tab.
                reserve (+ (* left 3) left)
                budget (math.max 3 (- w x reserve))
                model (tab-model ws (math.min budget (desired-width ws)))
                text model.text
                visible (math.min (length text) (- w x))
                attr (if (active? ws) TC.active TC.inactive)]
            (table.insert segments {:text text :attr attr})
            (when (> visible 0)
              (table.insert hits {:x0 x :x1 (+ x visible -1)
                                  :workspace-id ws.id
                                  :action :activate})
              (when (and model.close-offset
                         (< model.close-offset visible))
                (table.insert hits {:x0 (+ x model.close-offset)
                                    :x1 (+ x model.close-offset)
                                    :workspace-id ws.id
                                    :action :close})))
            (set x (+ x visible))))))
    {:segments segments :hits hits :width x}))

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
