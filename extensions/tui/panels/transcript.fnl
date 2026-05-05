;; Transcript: scrolling conversation surface owned by the TUI presenter.
;; Not a registered :panel — has scroll state, fills variable height, and
;; renders events lazily from the tail. Lives in panels/ for symmetry with
;; the other regions.
;;
;; Owns: tool-call/tool-result formatters, line wrapping, lines-for-event
;; (event-to-row dispatch), viewport-lines (lazy tail rendering),
;; max-scroll, paint-transcript, and the per-event md-cache invalidation.

(local state (require :fen.extensions.tui.state))
(local json (require :fen.util.json))
(local md (require :fen.extensions.tui.markdown))
(local tb (require :termbox2))

(local M {})

(local TOOL-RESULT-PREVIEW-BYTES 1024)
(set M.TOOL-RESULT-PREVIEW-BYTES TOOL-RESULT-PREVIEW-BYTES)

(fn M.ensure-defaults! []
  "Backfill transcript-region state fields that may be missing on a
   live state table predating their introduction (e.g. after /reload)."
  (when (= state.transcript nil) (set state.transcript []))
  (when (= state.streaming-assistant-rows nil) (set state.streaming-assistant-rows {}))
  (when (= state.transcript-layout-cache nil) (set state.transcript-layout-cache nil))
  (when (= state.scroll-offset nil) (set state.scroll-offset 0))
  (when (= state.expand-tool-results? nil) (set state.expand-tool-results? false))
  (when (= state.markdown? nil) (set state.markdown? true))
  (when (= state.hide-thinking-block? nil) (set state.hide-thinking-block? false)))

;; Color presets used by row attrs. Kept here so transcript rendering is
;; self-contained; paint.fnl owns its own copy for the rest of the chrome.
(local C
  {:user      (bor (or tb.BLACK tb.DEFAULT) tb.BOLD)
   :user-bg   tb.CYAN
   :assistant tb.GREEN
   :tool      tb.YELLOW
   :err       (bor tb.RED tb.BOLD)
   :dim       (bor tb.WHITE tb.DIM)
   :normal    tb.DEFAULT})

;; ---------- formatting helpers ----------

(fn M.args->string [args]
  (if (= (type args) :string) args
      (= args nil) "{}"
      (let [(ok? s) (pcall json.encode args)]
        (if ok? s "{}"))))

(fn M.content->text [content]
  "Concatenate text blocks of an AgentToolResult content list."
  (if (= content nil) ""
      (let [parts []]
        (each [_ b (ipairs content)]
          (when (= b.type :text)
            (table.insert parts (or b.text ""))))
        (table.concat parts ""))))

(fn M.truncate [s n]
  (if (<= (length s) n) s
      (.. (string.sub s 1 n) " …(truncated)")))

(fn M.count-lines [s]
  "Count \\n-terminated lines plus a trailing partial line if present."
  (if (or (= s nil) (= s "")) 0
      (do (var n 0)
          (var i 1)
          (let [len (length s)]
            (while (<= i len)
              (let [j (string.find s "\n" i true)]
                (set n (+ n 1))
                (if j
                    (set i (+ j 1))
                    (set i (+ len 1))))))
          n)))

(fn fmt-bytes [n]
  (let [n (or n 0)]
    (if (< n 1024) (.. (tostring n) "B")
        (< n (* 1024 1024)) (string.format "%.1fKB" (/ n 1024))
        (string.format "%.1fMB" (/ n (* 1024 1024))))))

(fn fmt-duration [seconds]
  (let [s (tonumber seconds)]
    (if (= s nil) ""
        (<= s 0) "<1s"
        (< s 60) (.. (tostring (math.floor s)) "s")
        (string.format "%dm%02ds" (math.floor (/ s 60)) (% (math.floor s) 60)))))

(fn M.lookup-tool-call [tool-call-id]
  "Walk back through state.transcript to find the matching :tool-call
   event for a result. Transcript is small; linear scan is fine."
  (when tool-call-id
    (var found nil)
    (var i (length state.transcript))
    (while (and (> i 0) (= found nil))
      (let [ev (. state.transcript i)]
        (when (and (= ev.type :tool-call)
                   (or (= ev.id tool-call-id)
                       (= ev.tool-call-id tool-call-id)))
          (set found ev)))
      (set i (- i 1)))
    found))

;; ---------- line wrapping ----------

(fn split-lines [s]
  (let [out []]
    (var i 1)
    (let [n (length s)]
      (while (<= i n)
        (let [j (string.find s "\n" i true)]
          (if j
              (do (table.insert out (string.sub s i (- j 1)))
                  (set i (+ j 1)))
              (do (table.insert out (string.sub s i n))
                  (set i (+ n 1))))))
      (when (or (= n 0) (= (string.sub s n n) "\n"))
        (table.insert out "")))
    out))

(set M.split-lines split-lines)

(fn hard-wrap-line [line width]
  (let [width* (math.max 1 width)]
    (if (= line "")
        [""]
        (let [out []
              n (length line)]
          (var i 1)
          (while (<= i n)
            (table.insert out (string.sub line i (+ i width* -1)))
            (set i (+ i width*)))
          out))))

(fn wrap-text [s width]
  (let [out []]
    (each [_ line (ipairs (split-lines s))]
      (each [_ chunk (ipairs (hard-wrap-line line width))]
        (table.insert out chunk)))
    out))

;; ---------- per-tool short-form formatters ----------

(fn fmt-read [a]
  (let [path (or a.path "?")
        off a.offset
        lim a.limit]
    (if (or off lim)
        (let [start (or off 1)
              end (if lim (+ start lim -1) "")]
          (.. "read " path ":" (tostring start) "-" (tostring end)))
        (.. "read " path))))

(fn fmt-bash [a]
  (.. "$ " (or a.cmd "")
      (if a.timeout (.. " (timeout " (tostring a.timeout) "s)") "")))

(fn fmt-edit [a] (.. "edit " (or a.path "?")))
(fn fmt-write [a] (.. "write " (or a.path "?")))

(fn fmt-ls [a]
  (.. "ls " (or a.path ".")
      (if a.limit (.. " (limit " (tostring a.limit) ")") "")))

(fn fmt-grep [a]
  (.. "grep /" (or a.pattern "") "/ in " (or a.path ".")
      (if a.glob (.. " (" a.glob ")") "")
      (if a.limit (.. " limit " (tostring a.limit)) "")))

(fn fmt-find [a]
  (.. "find " (or a.pattern "") " in " (or a.path ".")
      (if a.limit (.. " limit " (tostring a.limit)) "")))

(fn M.tool-call-short [name args]
  (let [a (or args {})
        n (string.lower (tostring (or name "")))]
    (if (= n :bash) (fmt-bash a)
        (= n :read) (fmt-read a)
        (= n :write) (fmt-write a)
        (= n :edit) (fmt-edit a)
        (= n :ls) (fmt-ls a)
        (= n :grep) (fmt-grep a)
        (= n :find) (fmt-find a)
        nil)))

(fn tool-result-summary [ev]
  (let [name (string.lower (tostring (or ev.tool-name "tool")))
        bytes (or ev.body-bytes 0)
        lines (or ev.body-lines 0)
        duration (fmt-duration ev.duration-seconds)
        suffix (if (not= duration "") (.. ", " duration) "")
        err? ev.is-error?
        path ev.tool-path]
    (if (or (= name :edit) (= name :write))
        (.. name (if path (.. " " path) "") (if err? " ✗" " ✓") suffix)
        (.. name " (" (tostring lines) " lines, " (fmt-bytes bytes) suffix ")"))))

;; ---------- transcript event → display rows ----------

(fn M.event-text [ev]
  "Return an event's display text. Streaming rows keep delta chunks to avoid
   O(n²) append-time string concatenation; materialize lazily when rendering or
   when tests/inspection ask for `ev.text` after stream end."
  (if (and ev.text-dirty? ev.text-chunks)
      (do (set ev.text (table.concat ev.text-chunks ""))
          (set ev.text-dirty? false)
          ev.text)
      (or ev.text "")))

(fn render-lines-for-event [ev width]
  (let [rows []
        push (fn [text attr indent? bg]
               (each [_ chunk (ipairs (wrap-text text width))]
                 (table.insert rows {:text (if indent? (.. "     " chunk) chunk)
                                     :attr attr
                                     :bg bg})))
        push-hanging (fn [prefix text attr]
                       (let [p (or prefix "")
                             body-w (math.max 1 (- width (length p)))
                             cont (string.rep " " (length p))]
                         (var first? true)
                         (each [_ chunk (ipairs (wrap-text (or text "") body-w))]
                           (table.insert rows
                                         {:text (.. (if first? p cont) chunk)
                                          :attr attr})
                           (set first? false))))]
    (if (= ev.type :user)
        (push (.. "you> " (or ev.text "")) C.user false C.user-bg)

        (= ev.type :assistant-text)
        (do
          (if state.markdown?
              (let [body-w width
                    text (M.event-text ev)]
                (when (or (not ev.md-cache-lines)
                          (not= ev.md-cache-width body-w))
                  (set ev.md-cache-width body-w)
                  (set ev.md-cache-lines (md.render-text text body-w)))
                (var i 0)
                (each [_ ml (ipairs ev.md-cache-lines)]
                  (set i (+ i 1))
                  (let [prefix (if (= i 1) "ai>  " "")
                        attr (or ml.attr C.assistant)]
                    (if ml.segments
                        (let [segments []]
                          (when (not= prefix "")
                            (table.insert segments {:text prefix :attr attr}))
                          (each [_ seg (ipairs ml.segments)]
                            (table.insert segments seg))
                          (table.insert rows
                                        {:text (.. prefix (or ml.text ""))
                                         :attr attr
                                         :segments segments}))
                        (table.insert rows
                                      {:text (.. prefix (or ml.text ""))
                                       :attr attr})))))
              (push (.. "ai>  " (M.event-text ev)) C.assistant false))
          (when ev.spacer-after?
            (table.insert rows {:text "" :attr C.dim})))

        (= ev.type :assistant-thinking)
        (do
          (if state.hide-thinking-block?
              (push "…   Thinking..." C.dim false)
              state.markdown?
              (let [body-w width
                    text (M.event-text ev)]
                (when (or (not ev.md-cache-lines)
                          (not= ev.md-cache-width body-w))
                  (set ev.md-cache-width body-w)
                  (set ev.md-cache-lines (md.render-text text body-w)))
                (var i 0)
                (each [_ ml (ipairs ev.md-cache-lines)]
                  (set i (+ i 1))
                  (let [prefix (if (= i 1) "…   " "")]
                    (table.insert rows
                                  {:text (.. prefix (or ml.text ""))
                                   :attr C.dim}))))
              (push (.. "…   " (M.event-text ev)) C.dim false))
          (when ev.spacer-after?
            (table.insert rows {:text "" :attr C.dim})))

        (= ev.type :info)
        (push (or ev.text "") C.dim false)

        (= ev.type :queued)
        (push (.. "queued> " (tostring (or ev.queue "")) ": " (or ev.text "")) C.dim false)

        (= ev.type :steering-injected)
        (push (.. "steer> " (or ev.text "")) C.user false C.user-bg)

        (= ev.type :follow-up-injected)
        (push (.. "next> " (or ev.text "")) C.user false C.user-bg)

        (= ev.type :tool-call)
        (push-hanging "tool> "
                      (or ev.short
                          (.. (tostring ev.name) " " (or ev.args-pretty "{}")))
                      C.tool)

        (= ev.type :tool-result)
        (if (or state.expand-tool-results? ev.expanded?)
            (push (or ev.body-pretty "") C.dim true)
            (push-hanging "tool< " (tool-result-summary ev) C.dim))

        (= ev.type :error)
        (push (.. "err> " (tostring ev.error)) C.err false)

        (= ev.type :cancelled)
        (push "⊘  cancelled by user" C.dim false)

        (= ev.type :extension-loaded)
        (push (.. "extension-loaded: " (tostring (or ev.name ""))) C.dim false)

        (push (.. (tostring ev.type) ": "
                  (tostring (or ev.text ev.error ev.name "")))
              C.dim false))
    rows))

(fn cache-key [ev width]
  {:width width
   :markdown? state.markdown?
   :hide-thinking-block? state.hide-thinking-block?
   :expand-tool-results? state.expand-tool-results?
   :expanded? ev.expanded?
   :text ev.text
   :text-version ev.text-version
   :body-pretty ev.body-pretty
   :short ev.short
   :args-pretty ev.args-pretty})

(fn same-cache-key? [a b]
  (and a b
       (= a.width b.width)
       (= a.markdown? b.markdown?)
       (= a.hide-thinking-block? b.hide-thinking-block?)
       (= a.expand-tool-results? b.expand-tool-results?)
       (= a.expanded? b.expanded?)
       (= a.text b.text)
       (= a.text-version b.text-version)
       (= a.body-pretty b.body-pretty)
       (= a.short b.short)
       (= a.args-pretty b.args-pretty)))

(fn M.invalidate-layout-cache! []
  "Drop the transcript-wide row-count/index cache. Call when events are
   appended, removed, or a visible event's rendered row count may change."
  (set state.transcript-layout-cache nil))

(fn M.clear-event-render-cache! [ev]
  "Drop all cached transcript rows for one event. Streaming delta ingestion
   calls this for the mutating row; forced redraws clear every event."
  (when ev
    (set ev.md-cache-lines nil)
    (set ev.md-cache-width nil)
    (set ev.render-cache-lines nil)
    (set ev.render-cache-key nil)
    (M.invalidate-layout-cache!)))

(fn lines-for-event [ev width]
  "Render one transcript event to display rows, cached per event/width/toggle.
   The TUI asks for these rows on every frame and while computing scroll
   bounds; caching keeps long transcripts and streaming deltas from reparsing
   Markdown or rewrapping stable historical events."
  (let [key (cache-key ev width)]
    (if (and ev.render-cache-lines (same-cache-key? ev.render-cache-key key))
        ev.render-cache-lines
        (let [rows (render-lines-for-event ev width)]
          (set ev.render-cache-key key)
          (set ev.render-cache-lines rows)
          rows))))

(set M.lines-for-event lines-for-event)

;; ---------- viewport composition ----------

(local LAZY-VIEWPORT-ROW-BUDGET 500)

(fn viewport-lines-lazy [width region-h]
  "Cheap tail-oriented viewport path. It walks backward only until it has the
   visible rows plus scroll offset, so a cold tail render does not build a
   whole-transcript row index."
  (let [h (math.max 0 (or region-h 0))
        need (+ h state.scroll-offset)
        collected-rev []]
    (var idx (length state.transcript))
    (while (and (> idx 0) (< (length collected-rev) need))
      (let [ev (. state.transcript idx)
            rows (lines-for-event ev width)]
        (var i (length rows))
        (while (> i 0)
          (table.insert collected-rev (. rows i))
          (set i (- i 1))))
      (set idx (- idx 1)))
    (let [total (length collected-rev)
          start-idx (+ state.scroll-offset 1)
          end-idx (math.min total (+ state.scroll-offset h))
          out []]
      (when (and (> h 0) (>= end-idx start-idx))
        (var i end-idx)
        (while (>= i start-idx)
          (table.insert out (. collected-rev i))
          (set i (- i 1))))
      out)))

(fn layout-cache-key [width]
  {:width width
   :markdown? state.markdown?
   :hide-thinking-block? state.hide-thinking-block?
   :expand-tool-results? state.expand-tool-results?
   :events (length state.transcript)})

(fn same-layout-key? [a b]
  (and a b
       (= a.width b.width)
       (= a.markdown? b.markdown?)
       (= a.hide-thinking-block? b.hide-thinking-block?)
       (= a.expand-tool-results? b.expand-tool-results?)
       (= a.events b.events)))

(fn build-layout-cache [width]
  (let [counts []
        starts []]
    (var total 0)
    (each [i ev (ipairs state.transcript)]
      (let [n (length (lines-for-event ev width))]
        (tset counts i n)
        (tset starts i (+ total 1))
        (set total (+ total n))))
    {:key (layout-cache-key width)
     :counts counts
     :starts starts
     :total total}))

(fn layout-cache [width]
  (let [key (layout-cache-key width)
        c state.transcript-layout-cache]
    (if (and c (same-layout-key? c.key key))
        c
        (let [fresh (build-layout-cache width)]
          (set state.transcript-layout-cache fresh)
          fresh))))

(fn find-event-for-row [cache row]
  "Find the first transcript event whose rendered row span intersects `row`."
  (let [starts cache.starts
        counts cache.counts
        n (length starts)]
    (var lo 1)
    (var hi n)
    (var found (+ n 1))
    (while (<= lo hi)
      (let [mid (math.floor (/ (+ lo hi) 2))
            start (. starts mid)
            finish (+ start (. counts mid) -1)]
        (if (>= finish row)
            (do (set found mid)
                (set hi (- mid 1)))
            (set lo (+ mid 1)))))
    found))

(fn viewport-lines-indexed [width region-h]
  "Deep-scroll viewport path. Uses the transcript layout cache to map scroll
   offsets to event ranges without walking from the tail through all skipped
   rows on every frame."
  (let [h (math.max 0 (or region-h 0))
        cache (layout-cache width)
        total cache.total
        end-row (- total state.scroll-offset)
        start-row (math.max 1 (- end-row h -1))
        out []]
    (when (and (> h 0) (> end-row 0) (>= end-row start-row))
      (var idx (find-event-for-row cache start-row))
      (while (and (<= idx (length state.transcript)) (< (length out) h))
        (let [ev (. state.transcript idx)
              rows (lines-for-event ev width)
              ev-start (. cache.starts idx)
              from (math.max 1 (+ (- start-row ev-start) 1))
              to (math.min (length rows) (+ (- end-row ev-start) 1))]
          (when (>= to from)
            (for [i from to]
              (when (< (length out) h)
                (table.insert out (. rows i))))))
        (set idx (+ idx 1))))
    out))

(fn M.viewport-lines [width region-h]
  "Returns up to region-h display rows ending at the tail of the transcript.
   Near-tail views use the lazy cold-cache path; deep scroll uses the indexed
   path so cost does not grow with scroll depth."
  (let [h (math.max 0 (or region-h 0))
        need (+ h state.scroll-offset)]
    (if (<= need LAZY-VIEWPORT-ROW-BUDGET)
        (viewport-lines-lazy width h)
        (viewport-lines-indexed width h))))

(fn M.max-scroll [input-rows]
  "Maximum useful scroll-offset given current state — total wrapped line
   count minus the visible region. Caller passes input-rows so this
   module doesn't reach back into paint.fnl for layout numbers."
  (let [w state.tb-cols
        h (- state.tb-rows 1 input-rows)
        cache (layout-cache w)]
    (math.max 0 (- cache.total (math.max 1 h)))))

(fn M.clear-render-caches! []
  "Drop cached rendered rows so a forced repaint recomputes all transcript
   presentation with the currently loaded renderer."
  (each [_ ev (ipairs state.transcript)]
    (M.clear-event-render-cache! ev)))

;; paint-transcript needs put-row from paint.fnl. To keep paint.fnl as the
;; integration point that wires viewport-lines → put-row, the actual paint
;; step stays in paint.fnl. This module owns rendering logic; paint.fnl
;; owns terminal output.

M
