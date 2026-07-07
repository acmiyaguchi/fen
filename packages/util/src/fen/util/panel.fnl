;; Shared chrome for the above-input inspector panels (status, queue, prompt,
;; extensions). These panels all draw a titled box, cache their rows on a 1 Hz
;; throttle keyed by width, and toggle/dismiss the same way. The helpers here
;; are the mechanically identical pieces; panel-specific content and cache keys
;; stay in each extension.

(local M {})

;; @doc fen.util.panel.dim
;; kind: function
;; signature: (dim text) -> Row
;; summary: Build a dim-styled panel row from text.
;; tags: panel ui rows
(fn M.dim [text] {:text text :style :dim})

;; @doc fen.util.panel.heading
;; kind: function
;; signature: (heading text) -> Row
;; summary: Build an assistant-styled heading row from text.
;; tags: panel ui rows
(fn M.heading [text] {:text text :style :assistant})

;; @doc fen.util.panel.box-top
;; kind: function
;; signature: (box-top w title) -> string
;; summary: Render the titled top border of a panel box at width w.
;; tags: panel ui box
(fn M.box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

;; @doc fen.util.panel.box-bottom
;; kind: function
;; signature: (box-bottom w) -> string
;; summary: Render the bottom border of a panel box at width w.
;; tags: panel ui box
(fn M.box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

;; @doc fen.util.panel.box-side
;; kind: function
;; signature: (box-side w text) -> string
;; summary: Render one bordered content line, clipping and padding to width w.
;; tags: panel ui box
(fn M.box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

;; @doc fen.util.panel.bordered-rows
;; kind: function
;; signature: (bordered-rows w content title) -> [Row]
;; summary: Frame styled content rows in a titled box at width w, one content row per line.
;; tags: panel ui box
(fn M.bordered-rows [w content title]
  (let [out [{:text (M.box-top w title) :style :dim}]]
    (each [_ row (ipairs content)]
      (table.insert out {:text (M.box-side w row.text) :style row.style}))
    (table.insert out {:text (M.box-bottom w) :style :dim})
    out))

;; @doc fen.util.panel.invalidate-cache!
;; kind: function
;; signature: (invalidate-cache! state) -> nil
;; summary: Reset the base row-cache fields (cached-rows/at/w) on a panel state table.
;; tags: panel ui cache
(fn M.invalidate-cache! [state]
  (set state.cached-rows nil)
  (set state.cached-at 0)
  (set state.cached-w 0))

;; @doc fen.util.panel.throttled-rows
;; kind: function
;; signature: (throttled-rows state w title build-content) -> [Row]
;; summary: Return the panel's framed rows, rebuilding at most once per second or when width changes; build-content is a thunk returning styled content rows.
;; tags: panel ui cache
(fn M.throttled-rows [state w title build-content]
  (let [now (os.time)]
    (when (or (not state.cached-rows)
              (not= now state.cached-at)
              (not= w state.cached-w))
      (set state.cached-rows (M.bordered-rows w (build-content) title))
      (set state.cached-at now)
      (set state.cached-w w))
    state.cached-rows))

;; @doc fen.util.panel.toggle!
;; kind: function
;; signature: (toggle! state emit label) -> nil
;; summary: Toggle panel visibility; dismisses other panels when opening and emits an info "<label> panel: on|off" line.
;; tags: panel ui toggle
(fn M.toggle! [state emit label]
  (if state.visible?
      (do (set state.visible? false)
          (M.invalidate-cache! state)
          (emit {:type :info :text (.. label " panel: off")}))
      (do
        ;; Close any other open panel — panels are mutually exclusive.
        (emit {:type :dismiss})
        (set state.visible? true)
        (M.invalidate-cache! state)
        (emit {:type :info :text (.. label " panel: on")}))))

;; @doc fen.util.panel.dismissed!
;; kind: function
;; signature: (dismissed! state emit label ev) -> nil
;; summary: Handle a :dismiss event by hiding a visible panel and announcing "<label> panel: off" when ev.announce? is set.
;; tags: panel ui dismiss
(fn M.dismissed! [state emit label ev]
  (when state.visible?
    (set state.visible? false)
    (M.invalidate-cache! state)
    (when ev.announce?
      (emit {:type :info :text (.. label " panel: off")}))))

M
