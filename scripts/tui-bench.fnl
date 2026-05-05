;; Lightweight TUI transcript performance harness.
;;
;; Run with:
;;   fennel scripts/tui-bench.fnl
;;   make bench-tui
;;
;; It avoids initializing the real terminal by installing a termbox2 stub before
;; loading TUI modules. Timings use os.clock CPU seconds, so compare relative
;; numbers on the same machine rather than treating them as absolute limits.

(local fennel (require :fennel))

(fn prepend-fennel-paths! []
  (let [paths ["./scripts/?.fnl" "./tests/support/?.fnl"]]
    (let [p (io.popen "find packages -path '*/src' -type d | sort")]
      (when p
        (each [dir (p:lines)]
          (table.insert paths (.. dir "/?.fnl"))
          (table.insert paths (.. dir "/?/init.fnl")))
        (p:close)))
    (set fennel.path (.. (table.concat paths ";") ";" fennel.path))
    (fennel.install)))

(prepend-fennel-paths!)

(local flat-ext (require :fen.util.flat_extensions))
(flat-ext.install! {:roots ["extensions"] :fennel fennel :position 2})

(tset package.loaded :termbox2
  {:DEFAULT 0 :CYAN 6 :GREEN 2 :YELLOW 3 :RED 1 :WHITE 7
   :BLACK 0 :MAGENTA 5
   :BOLD 1 :DIM 2 :REVERSE 4 :UNDERLINE 8 :ITALIC 16 :STRIKEOUT 32})

(local state (require :fen.extensions.tui.state))
(local transcript (require :fen.extensions.tui.panels.transcript))

(fn reset! []
  (set state.tb-cols 100)
  (set state.tb-rows 32)
  (set state.transcript [])
  (set state.streaming-assistant-rows {})
  (set state.transcript-layout-cache nil)
  (set state.scroll-offset 0)
  (set state.markdown? true)
  (set state.expand-tool-results? false)
  (set state.hide-thinking-block? false)
  (transcript.ensure-defaults!))

(fn paragraph [i]
  (.. "## Heading " (tostring i) "\n"
      "This is a markdown paragraph with **bold**, *italic*, `code`, and a [link](https://example.invalid). "
      "It is long enough to wrap across several terminal rows on smaller displays.\n"
      "- bullet one\n- bullet two\n\n"
      "```lua\nprint('hello from benchmark " (tostring i) "')\n```"))

(fn seed! [n]
  (for [i 1 n]
    (table.insert state.transcript
                  {:type (if (= (% i 7) 0) :user :assistant-text)
                   :text (if (= (% i 7) 0)
                             (.. "user prompt " (tostring i))
                             (paragraph i))})))

(fn bench [name n f]
  ;; Warm once so caches are populated when measuring repeated steady-state
  ;; redraw paths; cold-cache behavior is covered by explicit cache-clear cases.
  (f)
  (let [t0 (os.clock)]
    (for [_ 1 n] (f))
    (let [dt (- (os.clock) t0)
          per-ms (* (/ dt n) 1000)]
      (print (string.format "%-34s %8.3f ms/op  (%d iters)" name per-ms n))
      per-ms)))

(fn clear-all! []
  (transcript.clear-render-caches!))

(fn main []
  (let [events (tonumber (or (. arg 1) "1000"))
        width (tonumber (or (. arg 2) "100"))
        height (tonumber (or (. arg 3) "24"))]
    (reset!)
    (set state.tb-cols width)
    (set state.tb-rows (+ height 2))
    (seed! events)
    (print (string.format "TUI transcript benchmark: events=%d width=%d viewport=%d" events width height))
    (bench "viewport tail cached" 300 #(transcript.viewport-lines width height))
    (set state.scroll-offset 500)
    (bench "viewport scrolled cached" 300 #(transcript.viewport-lines width height))
    (bench "max-scroll cached" 50 #(transcript.max-scroll 1))
    (bench "viewport tail cold-cache" 30
           #(do (set state.scroll-offset 0)
                (clear-all!)
                (transcript.viewport-lines width height)))
    (let [ev {:type :assistant-text
              :text ""
              :text-chunks []
              :text-dirty? false
              :text-version 0
              :streaming? true}]
      (set state.transcript [ev])
      (set state.scroll-offset 0)
      (bench "streaming delta redraw" 1000
             #(do (table.insert ev.text-chunks " token")
                  (set ev.text-dirty? true)
                  (set ev.text-version (+ (or ev.text-version 0) 1))
                  (transcript.clear-event-render-cache! ev)
                  (transcript.viewport-lines width height))))))

(main)
