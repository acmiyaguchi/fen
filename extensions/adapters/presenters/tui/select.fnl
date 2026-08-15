;; fzf-style overlay for api.ui.select with its own inner termbox event loop.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local paint (require :fen.extensions.tui.paint))
(local draw (require :fen.extensions.tui.draw))
(local fuzzy (require :fen.util.fuzzy))

(local M {})

(local OVERLAY-MAX-ROWS 12)

(local SC
  {:border (bor tb.WHITE tb.DIM)
   :title  (bor tb.WHITE tb.BOLD)
   :item   tb.DEFAULT
   :sel    (bor tb.CYAN tb.REVERSE)
   :hint   (bor tb.WHITE tb.DIM)
   :normal tb.DEFAULT})

;; State machine takes synthetic key descriptors so tests can drive it
;; without termbox2.

(fn choice-texts [choice]
  [(or choice.label "") (or choice.description "")])

;; @doc fen.extensions.tui.select.filtered
;; kind: function
;; signature: (filtered state) -> [Choice]
;; summary: Return choices whose label or description fuzzy-match the current selector filter text, ranked best first.
;; tags: tui select filter choices fuzzy
(fn M.filtered [s]
  (fuzzy.ranked s.filter-text s.choices choice-texts))

(fn clamp-cursor [s]
  (let [n (length (M.filtered s))]
    (if (= n 0) (set s.cursor 1)
        (set s.cursor (math.max 1 (math.min s.cursor n))))))

;; @doc fen.extensions.tui.select.replace-choices!
;; kind: function
;; signature: (replace-choices! state choices) -> SelectState
;; summary: Replace choices in an open selector while preserving the highlighted label when possible.
;; tags: tui select choices async refresh
(fn M.replace-choices! [s choices]
  (let [old-items (M.filtered s)
        selected (?. old-items s.cursor :label)]
    (set s.choices (or choices []))
    (set s.cursor 1)
    (when selected
      (each [i choice (ipairs (M.filtered s))]
        (when (= choice.label selected)
          (set s.cursor i))))
    (clamp-cursor s)
    s))

;; @doc fen.extensions.tui.select.visible-window
;; kind: function
;; signature: (visible-window state max-rows) -> first-index item-count total-count
;; summary: Compute the visible selector slice so the cursor stays on-screen while moving through long choice lists.
;; tags: tui select viewport scroll choices
(fn M.visible-window [s max-rows]
  (let [items (M.filtered s)
        n (length items)
        max-rows (math.max 1 (math.floor (or max-rows 1)))
        item-h (math.min max-rows (math.max 1 n))
        cursor (if (= n 0) 1 (math.max 1 (math.min s.cursor n)))
        last-first (math.max 1 (+ 1 (- n item-h)))
        first (if (<= n item-h)
                  1
                  (math.max 1 (math.min last-first (+ 1 (- cursor item-h)))))]
    (values first item-h n)))

;; @doc fen.extensions.tui.select.make-state
;; kind: function
;; signature: (make-state opts) -> SelectState
;; summary: Create selector state, initializing its filter from the optional opts.initial-query value.
;; tags: tui select state
(fn M.make-state [opts]
  (let [opts (or opts {})
        s {:label (or opts.label "")
           :choices (or opts.choices [])
           :filter-text (tostring (or opts.initial-query ""))
           :cursor 1
           :done? false
           :result nil}]
    s))

;; @doc fen.extensions.tui.select.step!
;; kind: function
;; signature: (step! state key) -> SelectState
;; summary: Apply one synthetic selector key to filtering, cursor movement, selection, or cancellation state.
;; tags: tui select state keyboard
(fn M.step! [s key]
  (when (not s.done?)
    (case key.kind
      :up    (do (set s.cursor (- s.cursor 1)) (clamp-cursor s))
      :down  (do (set s.cursor (+ s.cursor 1)) (clamp-cursor s))
      :enter (let [picks (M.filtered s)
                   pick (. picks s.cursor)]
               (when pick
                 (set s.result pick))
               (set s.done? true))
      :esc   (do (set s.result nil) (set s.done? true))
      :bs    (do
               (when (> (length s.filter-text) 0)
                 (set s.filter-text
                      (string.sub s.filter-text 1
                                  (- (length s.filter-text) 1))))
               (set s.cursor 1))
      :char  (do
               (set s.filter-text (.. s.filter-text (or key.text "")))
               (set s.cursor 1))))
  s)

(fn termbox->key [ev]
  (if (not= ev.type tb.EVENT_KEY) nil
      (= ev.key tb.KEY_ENTER) {:kind :enter}
      (= ev.key tb.KEY_CTRL_C) {:kind :esc}
      (or (= ev.key tb.KEY_BACKSPACE) (= ev.key tb.KEY_BACKSPACE2))
      {:kind :bs}
      (= ev.key tb.KEY_ARROW_UP) {:kind :up}
      (= ev.key tb.KEY_ARROW_DOWN) {:kind :down}
      (= ev.key tb.KEY_CTRL_P) {:kind :up}
      (= ev.key tb.KEY_CTRL_N) {:kind :down}
      ;; termbox quirk: ev.key=0/ev.ch=0 means "no key we care about".
      (and ev.ch (> ev.ch 0))
      {:kind :char :text (or ev.text (string.char ev.ch))}
      ;; Some termbox builds only set ev.text for printable input.
      (and ev.text (not= ev.text ""))
      {:kind :char :text ev.text}
      nil))

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w hint]
  (let [tail (.. "─ " hint " ┘")
        tail-cols (+ 4 (length hint))
        fill-cols (math.max 0 (- w tail-cols 1))]
    (.. "└" (string.rep "─" fill-cols) tail)))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn paint-overlay [s lay]
  (let [w lay.w
        items (M.filtered s)
        ;; Short terminals: allow row 0 rather than drawing over the input.
        y1 (math.max 0 (- lay.input-y0 1))
        top-min (if (< y1 3) 0 1)
        max-item-rows (math.max 1 (- y1 top-min 1))
        item-cap (math.min OVERLAY-MAX-ROWS max-item-rows)
        (first-visible item-h n-items) (M.visible-window s item-cap)
        rows (+ 2 item-h)
        y0 (math.max top-min (- y1 rows -1))
        title (.. s.label
                  (if (not= s.filter-text "")
                      (.. " > " s.filter-text)
                      ""))
        more-prefix? (> first-visible 1)
        more-suffix? (> n-items (+ first-visible item-h -1))
        hint (if (or more-prefix? more-suffix?)
                 (.. "↑↓ " first-visible "-" (math.min n-items (+ first-visible item-h -1))
                     "/" n-items " · enter select · esc cancel")
                 "enter select · esc cancel · type to filter")]
    (draw.fill-row y0 0 (- w 1) 32 SC.normal SC.normal)
    (draw.put-clipped 0 y0 SC.title SC.normal (box-top w title) w)
    (for [i 1 item-h]
      (let [idx (+ first-visible i -1)
            y (+ y0 i)
            choice (. items idx)
            selected? (and choice (= idx s.cursor))
            attr (if selected? SC.sel
                     choice SC.item
                     SC.hint)
            marker (if selected? "> "
                       (and (= i 1) more-prefix?) "↑ "
                       (and (= i item-h) more-suffix?) "↓ "
                       "  ")
            text (if choice
                     (.. marker (or choice.label ""))
                     (if (= i 1) "(no matches)" ""))]
        (draw.fill-row y 0 (- w 1) 32 SC.normal SC.normal)
        (draw.put-clipped 0 y attr SC.normal (box-side w text) w)))
    (draw.fill-row y1 0 (- w 1) 32 SC.normal SC.normal)
    (draw.put-clipped 0 y1 SC.hint SC.normal (box-bottom w hint) w)))

(fn run-overlay [opts]
  (let [s (M.make-state opts)]
    (clamp-cursor s)
    (while (not s.done?)
      (paint.advance-spinner-if-due!)
      ;; Paint base frame into the back buffer without presenting, else each
      ;; tick flashes the normal UI under the overlay on slow terminals/tmux.
      (paint.paint-frame!)
      (let [lay (paint.layout)]
        (paint-overlay s lay))
      (tb.hide_cursor)
      (tb.present)
      (let [ev (tb.peek_event 30)]
        (when ev
          (let [k (termbox->key ev)]
            (when k (M.step! s k)))))
      ;; Cooperative tick: keep coroutines/steering/HTTP drains advancing
      ;; while this modal loop owns the foreground.
      (when state.on-tick
        (let [(_ok _err) (pcall state.on-tick)]
          nil))
      ;; opts.on-tick may refresh choices (e.g. dynamic model discovery).
      (when (and (not s.done?) opts.on-tick)
        (let [(ok? update) (pcall opts.on-tick s)]
          (when (and ok? (= (type update) :table))
            (when update.label (set s.label update.label))
            (when update.choices
              (M.replace-choices! s update.choices))))))
    (paint.invalidate-full!)
    s.result))

;; @doc fen.extensions.tui.select.tui-select
;; kind: function
;; signature: (tui-select opts) -> Choice|nil
;; summary: Run the interactive TUI select overlay when termbox is initialized and return the chosen record.
;; tags: tui select overlay presenter
(fn M.tui-select [opts]
  (if state.tb-initialized?
      (run-overlay opts)
      nil))

M
