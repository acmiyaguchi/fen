;; Low-level termbox2 drawing primitives. The bottom of the TUI
;; dependency graph: takes only state + termbox; consumed by paint, input,
;; panel renderers, and the select overlay.
;;
;; Splitting these out (instead of leaving them on paint) is what lets
;; input depend on draw without cycling back through paint, so paint's
;; redraw orchestration can call into input.paint-input cleanly.

(local state (require :fen.extensions.tui.state))
(local tb (require :termbox2))

(local M {})

(fn M.in-bounds? [x y]
  (and (>= x 0) (< x state.tb-cols)
       (>= y 0) (< y state.tb-rows)))

(fn M.fill-row [y x0 x1 ch fg bg]
  (when (and (>= y 0) (< y state.tb-rows))
    (let [x0* (math.max 0 x0)
          x1* (math.min (- state.tb-cols 1) x1)]
      (when (<= x0* x1*)
        (for [x x0* x1*]
          (tb.set_cell x y ch fg bg))))))

(fn M.utf8-prefix-cols [s cols]
  "Return a prefix of s containing at most cols UTF-8 codepoints. Still
   approximates wide CJK and combining marks at one column each, but
   avoids cutting box-drawing/bullet characters mid-byte."
  (let [text (or s "")
        limit (math.max 0 (or cols 0))]
    (var i 1)
    (var used 0)
    (var end 0)
    (while (and (<= i (length text)) (< used limit))
      (let [b (string.byte text i)
            step (if (< b 128) 1
                     (< b 224) 2
                     (< b 240) 3
                     4)
            next-i (+ i step)]
        (when (<= (- next-i 1) (length text))
          (set end (- next-i 1))
          (set used (+ used 1)))
        (set i next-i)))
    (string.sub text 1 end)))

(fn M.put-clipped [x y fg bg s width-cap]
  "Print s starting at x,y but cap at width-cap columns. tb_print returns
   OUT_OF_BOUNDS when the starting coordinate is off-screen, so guard
   here; this matters during very small terminal resize events."
  (when (and (> (or width-cap 0) 0) (M.in-bounds? x y))
    (let [remaining (- state.tb-cols x)
          cap (math.max 0 (math.min width-cap remaining))
          s* (M.utf8-prefix-cols s cap)]
      (when (> cap 0)
        (tb.print x y fg bg s*)))))

M
