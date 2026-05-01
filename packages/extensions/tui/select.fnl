;; TUI implementation of api.ui.select. Renders an fzf-style overlay band
;; above the input row, runs an inner termbox event loop until the user
;; picks (enter), cancels (esc / ctrl-c), and returns the chosen choice
;; record (or nil).
;;
;; Choices are tables shaped `{:label str :value any :description str?}`
;; per the issue's design comment. The whole choice record is returned.
;;
;; Filter is a substring match against `:label` (and optionally
;; `:description`). The cursor selects within the filtered list.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))
(local paint (require :fen.extensions.tui.paint))
(local draw (require :fen.extensions.tui.draw))

(local M {})

(local OVERLAY-MAX-ROWS 12)

(local SC
  {:border (bor tb.WHITE tb.DIM)
   :title  (bor tb.WHITE tb.BOLD)
   :item   tb.DEFAULT
   :sel    (bor tb.CYAN tb.REVERSE)
   :hint   (bor tb.WHITE tb.DIM)
   :normal tb.DEFAULT})

;; ---------- pure-logic state machine ----------
;;
;; Exported so tests can drive it without touching termbox2. step! receives
;; a synthetic key descriptor `{:kind :char|:up|:down|:enter|:esc|:bs}`
;; (and `:char` carries `.text`) so the state transitions can be tested
;; independent of termbox2 key codes.

(fn lower [s] (string.lower (or s "")))

(fn matches-filter? [choice filter-text]
  (if (= filter-text "") true
      (let [needle (lower filter-text)
            label (lower (or choice.label ""))
            descr (lower (or choice.description ""))]
        (or (string.find label needle 1 true)
            (string.find descr needle 1 true)))))

(fn M.filtered [s]
  (let [out []]
    (each [_ c (ipairs s.choices)]
      (when (matches-filter? c s.filter-text)
        (table.insert out c)))
    out))

(fn clamp-cursor [s]
  (let [n (length (M.filtered s))]
    (if (= n 0) (set s.cursor 1)
        (set s.cursor (math.max 1 (math.min s.cursor n))))))

(fn M.make-state [opts]
  (let [opts (or opts {})
        s {:label (or opts.label "")
           :choices (or opts.choices [])
           :filter-text ""
           :cursor 1
           :done? false
           :result nil}]
    s))

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

;; ---------- termbox key → state-machine key ----------

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
      ;; Esc on a key event without a key code: tb sets ev.key to 0 and
      ;; ev.ch may be 27 in some terminals. Treat ch=0 ev.key=0 as "no key
      ;; we care about" rather than swallowing.
      (and ev.ch (> ev.ch 0))
      {:kind :char :text (or ev.text (string.char ev.ch))}
      ;; Some termbox builds give us ev.text directly for printable input.
      (and ev.text (not= ev.text ""))
      {:kind :char :text ev.text}
      nil))

;; ---------- overlay paint ----------
;;
;; Panel-style chrome: full-width, bordered, title baked into the top
;; border, hint baked into the bottom border. Mirrors the box-drawing
;; style used by /mem, /status, etc. so the overlay reads as part of the
;; same visual language.

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
        n-items (length items)
        item-h (math.min OVERLAY-MAX-ROWS (math.max 1 n-items))
        rows (+ 2 item-h)
        y1 (- lay.input-y0 1)
        y0 (math.max 1 (- y1 rows -1))
        title (.. s.label
                  (if (not= s.filter-text "")
                      (.. " > " s.filter-text)
                      ""))
        hint "enter select · esc cancel · type to filter"]
    ;; Top border with title.
    (draw.fill-row y0 0 (- w 1) 32 SC.normal SC.normal)
    (draw.put-clipped 0 y0 SC.title SC.normal (box-top w title) w)
    ;; Item rows inside │ ... │.
    (for [i 1 item-h]
      (let [y (+ y0 i)
            choice (. items i)
            selected? (and choice (= i s.cursor))
            attr (if selected? SC.sel
                     choice SC.item
                     SC.hint)
            text (if choice
                     (.. (if selected? "> " "  ") (or choice.label ""))
                     (if (= i 1) "(no matches)" ""))]
        (draw.fill-row y 0 (- w 1) 32 SC.normal SC.normal)
        (draw.put-clipped 0 y attr SC.normal (box-side w text) w)))
    ;; Bottom border with hint.
    (draw.fill-row y1 0 (- w 1) 32 SC.normal SC.normal)
    (draw.put-clipped 0 y1 SC.hint SC.normal (box-bottom w hint) w)))

;; ---------- inner event loop ----------

(fn run-overlay [opts]
  (let [s (M.make-state opts)]
    (clamp-cursor s)
    (while (not s.done?)
      ;; Render under-screen first so the overlay sits on top.
      (paint.redraw!)
      (let [lay (paint.layout)]
        (paint-overlay s lay))
      (tb.hide_cursor)
      (tb.present)
      (let [ev (tb.peek_event 30)]
        (when ev
          (let [k (termbox->key ev)]
            (when k (M.step! s k)))))
      ;; Cooperative tick: keep agent coroutines, queued steering, and
      ;; HTTP drains advancing while the overlay holds the foreground.
      ;; The outer run loop publishes on-tick into tui state at start.
      (when state.on-tick
        (let [(_ok _err) (pcall state.on-tick)]
          nil)))
    ;; Clear overlay artifacts: a final redraw restores chrome.
    (paint.force-redraw!)
    s.result))

(fn M.tui-select [opts]
  (if state.tb-initialized?
      (run-overlay opts)
      nil))

M
