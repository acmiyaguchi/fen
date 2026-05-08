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

;; @doc fen.extensions.tui.draw.in-bounds?
;; kind: function
;; signature: (in-bounds? x y) -> boolean
;; summary: Return whether a zero-based terminal coordinate is inside the current termbox dimensions.
;; tags: tui draw bounds termbox
(fn M.in-bounds? [x y]
  (and (>= x 0) (< x state.tb-cols)
       (>= y 0) (< y state.tb-rows)))

;; @doc fen.extensions.tui.draw.fill-row
;; kind: function
;; signature: (fill-row y x0 x1 ch fg bg) -> nil
;; summary: Fill a clipped horizontal row segment with one termbox print call to reduce Lua-to-C overhead.
;; tags: tui draw termbox performance
(fn M.fill-row [y x0 x1 ch fg bg]
  "Fill a row segment. Use one tb.print call instead of one set_cell call per
   column; row fills happen on every frame and Lua→C call count matters on slow
   ARM terminals."
  (when (and (>= y 0) (< y state.tb-rows))
    (let [x0* (math.max 0 x0)
          x1* (math.min (- state.tb-cols 1) x1)]
      (when (<= x0* x1*)
        (tb.print x0* y fg bg (string.rep (string.char (or ch 32))
                                          (+ 1 (- x1* x0*))))))))

;; @doc fen.extensions.tui.draw.utf8-prefix-cols
;; kind: function
;; signature: (utf8-prefix-cols s cols) -> string
;; summary: Return a display-column-limited UTF-8 prefix without cutting multibyte characters in the middle.
;; tags: tui draw utf8 clipping
(fn M.utf8-prefix-cols [s cols]
  "Return a prefix of s containing at most cols UTF-8 codepoints. Still
   approximates wide CJK and combining marks at one column each, but
   avoids cutting box-drawing/bullet characters mid-byte."
  (let [text (or s "")
        limit (math.max 0 (or cols 0))]
    ;; Common case: short ASCII/status strings fit as-is. If an ASCII string
    ;; needs clipping, byte length equals display columns, so string.sub is
    ;; enough. Fall back to UTF-8-aware clipping only for non-ASCII overflow.
    (if (<= (length text) limit)
        text
        (not (string.find text "[\128-\255]"))
        (string.sub text 1 limit)
        (do
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
          (string.sub text 1 end)))))

;; @doc fen.extensions.tui.draw.put-clipped
;; kind: function
;; signature: (put-clipped x y fg bg s width-cap) -> nil
;; summary: Print clipped text at an in-bounds coordinate while respecting both terminal width and caller cap.
;; tags: tui draw termbox clipping
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
