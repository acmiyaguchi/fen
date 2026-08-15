;; Native transcript selection: coordinates are 0-based absolute screen cells
;; (termbox event space), columns counted in UTF-8 codepoints
;; (one column per codepoint, matching draw.utf8-prefix-cols).
;; Hot-reload: RELOADABLE; selection + paint snapshot live in state so /reload
;; mid-drag does not drop the selection.

(local state (require :fen.extensions.tui.state))

(local M {})

(fn M.ensure-defaults! []
  "Ensure the selection paint snapshot has a concrete table. state.selection
   intentionally remains nil when no selection is active."
  (when (= state.selection-paint nil)
    (set state.selection-paint {:rows {} :min-y nil :max-y nil})))

(fn codepoints [s]
  "Split a UTF-8 string into a list of single-codepoint strings. Byte-length
   driven, matching draw.utf8-prefix-cols' column model."
  (let [out []
        n (length (or s ""))]
    (var i 1)
    (while (<= i n)
      (let [b (string.byte s i)
            step (if (< b 128) 1 (< b 224) 2 (< b 240) 3 4)]
        (table.insert out (string.sub s i (+ i step -1)))
        (set i (+ i step))))
    out))

;; @doc fen.extensions.tui.selection.row-cols
;; kind: function
;; signature: (row-cols text) -> number
;; summary: Return the display-column width of a row's plain text in UTF-8 codepoints.
;; tags: tui selection utf8 layout
(fn M.row-cols [text]
  (length (codepoints text)))

(fn slice-cols [text from to]
  "Return the substring of `text` covering 0-based inclusive column range
   [from, to], codepoint-aware. Empty when the range is degenerate."
  (let [cps (codepoints text)
        n (length cps)
        lo (math.max 0 from)
        hi (math.min (- n 1) to)
        out []]
    (when (and (>= n 1) (<= lo hi))
      (for [i lo hi]
        (table.insert out (. cps (+ i 1)))))
    (table.concat out)))

;; @doc fen.extensions.tui.selection.active?
;; kind: function
;; signature: (active?) -> boolean
;; summary: Whether a transcript selection is currently anchored.
;; tags: tui selection state
(fn M.active? []
  (if (and state.selection state.selection.anchor state.selection.cursor)
      true
      false))

(fn M.has-span? []
  "A selection whose anchor and cursor are the same cell is a plain click,
   not a drag; treat that as no span so it copies nothing."
  (if (M.active?)
      (let [a state.selection.anchor
            c state.selection.cursor]
        (not (and (= a.x c.x) (= a.y c.y))))
      false))

;; @doc fen.extensions.tui.selection.clear!
;; kind: function
;; signature: (clear!) -> boolean
;; summary: Drop any active selection, returning whether one was present so callers can decide to repaint.
;; tags: tui selection state
(fn M.clear! []
  (let [had? (not= state.selection nil)]
    (set state.selection nil)
    had?))

;; @doc fen.extensions.tui.selection.start!
;; kind: function
;; signature: (start! x y) -> nil
;; summary: Begin a selection with the anchor and cursor at screen cell (x, y).
;; tags: tui selection mouse
(fn M.start! [x y]
  (set state.selection {:anchor {:x x :y y}
                        :cursor {:x x :y y}
                        :dragging? true}))

(fn snapshot-row [snapshot y]
  (when (and snapshot snapshot.rows)
    (. snapshot.rows y)))

(fn snapshot-bounds [snapshot]
  (when (and snapshot snapshot.rows)
    (values snapshot.min-y snapshot.max-y)))

(fn M.selectable-cell? [x y snapshot]
  "True only when (x, y) is inside text recorded by paint-transcript.
   This prevents clicks in the status bar, panels, input box, or empty space
   to the right of a short transcript row from starting a copy selection."
  (let [text (snapshot-row snapshot y)]
    (if text
        (let [cols (M.row-cols text)]
          (and (>= x 0) (> cols 0) (< x cols)))
        false)))

(fn M.clamp-to-snapshot [x y snapshot]
  "Clamp drag/release coordinates to the currently painted transcript band.
   Starting a selection is stricter (M.selectable-cell?) but once a drag is
   active, leaving the transcript region should extend to the nearest visible
   transcript edge rather than copying status/input rows or adding blank
   rows from outside the viewport."
  (let [(min-y max-y) (snapshot-bounds snapshot)]
    (when (and min-y max-y)
      (let [cy (math.max min-y (math.min y max-y))
            text (or (snapshot-row snapshot cy) "")
            cols (M.row-cols text)
            cx (if (> cols 0)
                   (math.max 0 (math.min x (- cols 1)))
                   0)]
        {:x cx :y cy}))))

;; @doc fen.extensions.tui.selection.start-if-selectable!
;; kind: function
;; signature: (start-if-selectable! x y) -> boolean
;; summary: Begin a selection only when the mouse press lands on currently painted transcript text.
;; tags: tui selection mouse transcript
(fn M.start-if-selectable! [x y]
  (if (M.selectable-cell? x y state.selection-paint)
      (do (M.start! x y) true)
      false))

;; @doc fen.extensions.tui.selection.update-clamped!
;; kind: function
;; signature: (update-clamped! x y) -> boolean
;; summary: Move the selection cursor after clamping to the visible transcript snapshot; return false when no snapshot exists.
;; tags: tui selection mouse transcript
(fn M.update-clamped! [x y]
  (let [pt (M.clamp-to-snapshot x y state.selection-paint)]
    (if pt
        (do (M.update! pt.x pt.y) true)
        false)))

;; @doc fen.extensions.tui.selection.update!
;; kind: function
;; signature: (update! x y) -> nil
;; summary: Move the selection cursor to screen cell (x, y) during a drag.
;; tags: tui selection mouse
(fn M.update! [x y]
  (when state.selection
    (set state.selection.cursor {:x x :y y})))

;; @doc fen.extensions.tui.selection.finish!
;; kind: function
;; signature: (finish!) -> nil
;; summary: Mark the in-progress drag complete while keeping the selection highlighted until cleared.
;; tags: tui selection mouse
(fn M.finish! []
  (when state.selection
    (set state.selection.dragging? false)))

(fn M.normalized [sel]
  "Return the selection ordered so start precedes end in reading order
   (row-major: earlier row first, then earlier column). nil when incomplete."
  (when (and sel sel.anchor sel.cursor)
    (let [a sel.anchor
          c sel.cursor
          swap? (or (> a.y c.y) (and (= a.y c.y) (> a.x c.x)))]
      (if swap?
          {:start {:x c.x :y c.y} :end {:x a.x :y a.y}}
          {:start {:x a.x :y a.y} :end {:x c.x :y c.y}}))))

(fn M.row-range [sel y row-cols]
  "Inclusive [from, to] column range selected on screen row `y`. Middle rows
   of a multi-row selection extend to the row's last column. Returns nil when
   the row is outside the selection or has no width."
  (let [norm (M.normalized sel)]
    (when (and norm (> row-cols 0) (>= y norm.start.y) (<= y norm.end.y))
      (let [last-col (- row-cols 1)
            from (if (= y norm.start.y) norm.start.x 0)
            to (if (= y norm.end.y) norm.end.x last-col)
            from* (math.max 0 (math.min from last-col))
            to* (math.max 0 (math.min to last-col))]
        (when (<= from* to*)
          (values from* to*))))))

(fn M.row-highlight [sel y text]
  "For painting: return (from-col, selected-substring) for screen row `y`
   given the row's plain `text`, or nil when the row has no selected cells."
  (let [norm (M.normalized sel)]
    ;; Row-band check first: avoids codepoint-splitting every painted row.
    (when (and norm (>= y norm.start.y) (<= y norm.end.y))
      (let [cols (M.row-cols text)]
        (when (> cols 0)
          (let [(from to) (M.row-range sel y cols)]
            (when from
              (values from (slice-cols text from to)))))))))

;; @doc fen.extensions.tui.selection.begin-paint!
;; kind: function
;; signature: (begin-paint!) -> nil
;; summary: Reset the per-frame transcript paint snapshot before rows are recorded for later selection extraction.
;; tags: tui selection paint snapshot
(fn M.begin-paint! []
  (set state.selection-paint {:rows {} :min-y nil :max-y nil}))

;; @doc fen.extensions.tui.selection.record-row!
;; kind: function
;; signature: (record-row! y text) -> nil
;; summary: Record the plain text painted at screen row y so a later copy can extract the selected substring.
;; tags: tui selection paint snapshot
(fn M.record-row! [y text]
  (when state.selection-paint
    (tset state.selection-paint.rows y (or text ""))
    (when (or (= state.selection-paint.min-y nil) (< y state.selection-paint.min-y))
      (set state.selection-paint.min-y y))
    (when (or (= state.selection-paint.max-y nil) (> y state.selection-paint.max-y))
      (set state.selection-paint.max-y y))))

(fn M.extract [sel snapshot]
  "Pure extraction: return the text covered by `sel` given a paint `snapshot`
   ({:rows {screen-y -> plain-text}}). Rows are joined with \\n; screen rows
   with no recorded text contribute an empty line so blank gaps are preserved
   between selected content rows."
  (let [norm (M.normalized sel)
        rows (and snapshot snapshot.rows)]
    (if (or (not norm) (not rows))
        ""
        (let [out []]
          (for [y norm.start.y norm.end.y]
            (let [text (or (. rows y) "")
                  cols (M.row-cols text)]
              (if (= cols 0)
                  (table.insert out "")
                  (let [(from to) (M.row-range sel y cols)]
                    (if from
                        (table.insert out (slice-cols text from to))
                        (table.insert out ""))))))
          (table.concat out "\n")))))

;; @doc fen.extensions.tui.selection.selected-text
;; kind: function
;; signature: (selected-text) -> string
;; summary: Return the currently selected transcript text using the live paint snapshot.
;; tags: tui selection copy
(fn M.selected-text []
  (if (M.active?)
      (M.extract state.selection state.selection-paint)
      ""))

M
