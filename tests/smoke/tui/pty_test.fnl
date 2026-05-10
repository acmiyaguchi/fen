(local pty (require :fen.testing.pty))
(local h (require :fen.testing))

(fn repo-root []
  (let [pipe (io.popen "pwd" :r)
        path (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (assert path)))

(fn write-models [dir]
  (h.write-file
    (.. dir "/config/fen/models.json")
    "{\"providers\":{\"pty-smoke\":{\"api\":\"openai-completions\",\"baseUrl\":\"http://127.0.0.1:9/v1\",\"apiKey\":\"dummy\",\"models\":[{\"id\":\"pty-smoke\"}]}}}\n"))

(fn fixture-extension [root]
  (.. root "/packages/testing/tests/fixtures/pty-driver"))

(fn make-session [scenario opts]
  (let [root (repo-root)
        tmp (h.make-tmpdir)
        cols 100
        rows 32
        artifacts (pty.artifact-dir scenario)
        raw-path (.. artifacts "/raw.ansi")
        cast-path (.. artifacts "/session.cast")
        env {:TERM "xterm-256color"
             :HOME (.. tmp "/home")
             :XDG_CONFIG_HOME (.. tmp "/config")
             :XDG_STATE_HOME (.. tmp "/state")
             :LINES false
             :COLUMNS false
             :COLORTERM false
             :FEN_LOG "error"}
        argv ["/bin/sh" "./scripts/fen-dev"
              "--provider" "pty-smoke"
              "--model" "pty-smoke"
              "--presenter" "tui"
              "--no-session"]]
    (when (and opts opts.extension)
      (table.insert argv "--extension")
      (table.insert argv opts.extension))
    (h.write-file (.. tmp "/home/.keep") "")
    (h.write-file (.. tmp "/state/.keep") "")
    (write-models tmp)
    (pty.write-file raw-path "")
    (pty.cast-start cast-path cols rows {:TERM "xterm-256color"})
    (let [session {:scenario scenario
                   :tmp tmp
                   :cols cols
                   :rows rows
                   :artifacts artifacts
                   :raw-path raw-path
                   :cast-path cast-path
                   :metrics-path (.. artifacts "/metrics.json")
                   :started (pty.now)
                   :bytes-read 0
                   :bytes-written 0
                   :output ""
                   :markers {}
                   :child nil}]
      (tset session :child
            (assert (pty.spawn {:argv argv :cwd root :env env :cols cols :rows rows})))
      session)))

(fn on-chunk [session chunk]
  (set session.bytes-read (+ session.bytes-read (length chunk)))
  (set session.output (.. (or session.output "") chunk))
  (pty.append-file session.raw-path chunk)
  (pty.cast-event session.cast-path (- (pty.now) session.started) "o" chunk))

(fn write-input [session bytes]
  (set session.bytes-written (+ session.bytes-written (length bytes)))
  (pty.cast-event session.cast-path (- (pty.now) session.started) "i" bytes)
  (assert (session.child:write bytes)))

(fn wait-marker [session marker timeout-ms start-at]
  (if (string.find (or session.output "") marker (or start-at 1) true)
      (do
        (tset session.markers marker (math.floor (* (- (pty.now) session.started) 1000)))
        session.output)
      (let [(out captured) (pty.read-until session.child marker (or timeout-ms 3000)
                           {:on-chunk (fn [chunk] (on-chunk session chunk))})]
        (when (not out)
          (error (.. "marker not seen for " session.scenario ": " marker
                     "; captured " (tostring (length (or captured "")))
                     " bytes in " session.artifacts)))
        (tset session.markers marker (math.floor (* (- (pty.now) session.started) 1000)))
        out)))

(fn wait-first-paint [session]
  (wait-marker session "ctrl-d to quit" 5000))

(fn close-with-ctrl-d [session]
  (write-input session "\004")
  (pty.drain session.child 500 {:on-chunk (fn [chunk] (on-chunk session chunk))})
  (let [(status wait-err) (session.child:wait 3000)]
    (when (not status)
      (session.child:kill)
      (session.child:close)
      (error (.. "fen did not exit after Ctrl-D: " (tostring wait-err))))
    (session.child:close)
    status))

(fn write-metrics [session status]
  (pty.write-file session.metrics-path
    (.. (pty.encode-json {:scenario session.scenario
                          :cols session.cols
                          :rows session.rows
                          :elapsed_ms (math.floor (* (- (pty.now) session.started) 1000))
                          :markers session.markers
                          :bytes_read session.bytes-read
                          :bytes_written session.bytes-written
                          :exit_code (and status status.code)
                          :exit_signal (and status status.signal)
                          :artifacts session.artifacts})
        "\n")))

(fn with-session [scenario f opts]
  (let [session (make-session scenario opts)]
    (var status nil)
    (let [(ok? err) (xpcall
                      (fn []
                        (wait-first-paint session)
                        (set status (f session))
                        (when (not status)
                          (set status (close-with-ctrl-d session)))
                        (assert.are.equal true status.exited)
                        (assert.are.equal 0 status.code))
                      debug.traceback)]
      (when (not ok?)
        (when session.child
          (session.child:kill)
          (session.child:close)))
      (write-metrics session status)
      (h.rmtree session.tmp)
      (when (not ok?)
        (error err)))))

(describe "TUI PTY smoke"
  (fn []
    (it "paints the TUI in a real PTY and exits on Ctrl-D"
      (fn []
        (with-session :startup (fn [_session] nil))))

    (it "runs provider-free slash command workflows"
      (fn []
        (with-session :commands
          (fn [session]
            (write-input session "/help\r")
            (wait-marker session "/cancel-all" 3000)

            (write-input session "/markdown off\r")
            (wait-marker session "markdown rendering: off" 3000)
            (write-input session "/markdown on\r")
            (wait-marker session "markdown rendering: on" 3000)

            (write-input session "/expand on\r")
            (wait-marker session "tool results: expanded" 3000)
            (write-input session "/expand off\r")
            (wait-marker session "tool results: collapsed" 3000)

            (write-input session "/animations off\r")
            (wait-marker session "animations: off" 3000)
            (write-input session "/thinking off\r")
            (wait-marker session "thinking blocks: hidden" 3000)

            (write-input session "/reload\r")
            (wait-marker session "/reload core" 5000)
            nil))))

    (it "handles real input editing keys before submitting commands"
      (fn []
        (with-session :editing
          (fn [session]
            ;; Ctrl-C clears a non-empty input without exiting; /help should
            ;; still submit normally afterward.
            (write-input session "abc\003/help\r")
            (wait-marker session "/cancel-all" 3000)

            ;; Ambiguous slash completion prints command hints.
            (write-input session "/\009")
            (wait-marker session "commands: " 3000)
            (write-input session "\003")
            nil))))

    (it "submits commands after edit chords mutate the input buffer"
      (fn []
        (let [root (repo-root)]
          (with-session :editing-chords
            (fn [session]
              ;; Backspace fixes the command argument before submission.
              (write-input session "/smoke-emit markx\127down\r")
              (wait-marker session "smoke-emit markdown done" 3000)

              ;; Ctrl-W deletes the trailing word while preserving the command.
              (let [after-backspace (+ (length session.output) 1)]
                (write-input session "/smoke-emit markdown junk\023\r")
                (wait-marker session "smoke-emit markdown done" 3000 after-backspace))

              ;; Ctrl-U clears an accidental line prefix before command entry.
              (let [after-ctrl-w (+ (length session.output) 1)]
                (write-input session "junk\021/smoke-emit markdown\r")
                (wait-marker session "smoke-emit markdown done" 3000 after-ctrl-w))

              ;; Arrow-left insertion verifies cursor motion before submit.
              (let [after-ctrl-u (+ (length session.output) 1)]
                (write-input session "/smoke-emit markown\027[D\027[D\027[Dd\r")
                (wait-marker session "smoke-emit markdown done" 3000 after-ctrl-u))
              nil)
            {:extension (fixture-extension root)}))))

    (it "repaints after a PTY resize"
      (fn []
        (with-session :resize
          (fn [session]
            (let [after-first-paint (+ (length session.output) 1)]
              (assert (session.child:resize 60 20))
              (wait-marker session "pty-smoke:pty-smoke" 3000 after-first-paint))
            (let [after-first-resize (+ (length session.output) 1)]
              (assert (session.child:resize 120 40))
              (wait-marker session "pty-smoke:pty-smoke" 3000 after-first-resize))
            nil))))

    (it "exits cleanly after the idle Ctrl-C confirmation chord"
      (fn []
        (with-session :ctrl-c-exit
          (fn [session]
            (write-input session "\003")
            (wait-marker session "again" 3000)
            (write-input session "\003")
            (let [(status wait-err) (session.child:wait 3000)]
              (when (not status)
                (error (.. "fen did not exit after Ctrl-C chord: " (tostring wait-err))))
              (session.child:close)
              status)))))

    (it "renders fixture-driven tool results and expanded bodies"
      (fn []
        (let [root (repo-root)]
          (with-session :fixture-tool
            (fn [session]
              (write-input session "/smoke-emit tool\r")
              (wait-marker session "tool> read README.md" 3000)
              (wait-marker session "tool< read" 3000)
              (write-input session "/expand on\r")
              (wait-marker session "tool results: expanded" 3000)
              (wait-marker session "smoke tool body line one" 3000)
              nil)
            {:extension (fixture-extension root)}))))

    (it "surfaces fixture errors in the TUI errors panel"
      (fn []
        (let [root (repo-root)]
          (with-session :fixture-error-panel
            (fn [session]
              (write-input session "/smoke-emit error\r")
              (wait-marker session "smoke fixture error" 3000)
              (write-input session "/errors on\r")
              (wait-marker session "Errors" 3000)
              (wait-marker session "deterministic error from pty-driver" 3000)
              (write-input session "/errors clear\r")
              (wait-marker session "errors: cleared" 3000)
              nil)
            {:extension (fixture-extension root)}))))

    (it "scrolls through fixture-driven long transcript content"
      (fn []
        (let [root (repo-root)]
          (with-session :fixture-scroll
            (fn [session]
              (write-input session "/smoke-emit long 80\r")
              (wait-marker session "smoke-emit long 80 done" 5000)
              (write-input session "\27[5~")
              (wait-marker session "scrolled:" 3000)
              (write-input session "\27[6~")
              ;; The exact status after PageDown depends on viewport height;
              ;; clean shutdown below proves the TUI remains responsive after
              ;; processing scroll input.
              nil)
            {:extension (fixture-extension root)}))))

    (it "summarizes bracketed paste without submitting provider input"
      (fn []
        (with-session :paste
          (fn [session]
            (let [pasted "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve"]
              (write-input session (.. "\27[200~" pasted "\27[201~"))
              ;; PTY raw bytes include cursor movement rather than a final
              ;; screen grid; assert one contiguous marker fragment.
              (wait-marker session "lines]" 3000)
              ;; Clear the unsent paste marker so Ctrl-D can quit cleanly.
              (write-input session "\003")
              nil)))))

    (it "recalls prior slash commands through input history"
      (fn []
        (let [root (repo-root)]
          (with-session :history
            (fn [session]
              (write-input session "/smoke-emit markdown\r")
              (wait-marker session "smoke-emit markdown done" 3000)
              (let [after-submit (+ (length session.output) 1)]
                (write-input session "\27[A")
                (wait-marker session "markdown" 3000 after-submit))
              (write-input session "\003")
              nil)
            {:extension (fixture-extension root)}))))

    (it "scrolls long transcript content with mouse wheel input"
      (fn []
        (let [root (repo-root)]
          (with-session :mouse-scroll
            (fn [session]
              (write-input session "/smoke-emit long 80\r")
              (wait-marker session "smoke-emit long 80 done" 5000)
              ;; Xterm SGR mouse wheel-up at column 10,row 10.
              (write-input session "\27[<64;10;10M")
              (wait-marker session "scrolled:" 3000)
              nil)
            {:extension (fixture-extension root)}))))

    (it "drives the TUI select overlay"
      (fn []
        (let [root (repo-root)]
          (with-session :select
            (fn [session]
              (write-input session "/smoke-select\r")
              (wait-marker session "smoke select" 3000)
              (write-input session "be\r")
              (wait-marker session "smoke-select picked: beta" 3000)
              nil)
            {:extension (fixture-extension root)}))))))
