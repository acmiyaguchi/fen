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

(describe "TUI PTY smoke"
  (fn []
    (it "paints the TUI in a real PTY and exits on Ctrl-D"
      (fn []
        (let [root (repo-root)
              tmp (h.make-tmpdir)
              cols 100
              rows 32
              artifacts (pty.artifact-dir :startup)
              raw-path (.. artifacts "/raw.ansi")
              cast-path (.. artifacts "/session.cast")
              metrics-path (.. artifacts "/metrics.json")
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
          (h.write-file (.. tmp "/home/.keep") "")
          (h.write-file (.. tmp "/state/.keep") "")
          (write-models tmp)
          (pty.write-file raw-path "")
          (pty.cast-start cast-path cols rows {:TERM "xterm-256color"})
          (let [started (pty.now)
                bytes-read {:n 0}
                bytes-written {:n 0}
                child (assert (pty.spawn {:argv argv :cwd root :env env :cols cols :rows rows}))
                on-chunk (fn [chunk]
                           (set bytes-read.n (+ bytes-read.n (length chunk)))
                           (pty.append-file raw-path chunk)
                           (pty.cast-event cast-path (- (pty.now) started) "o" chunk))
                (first err-out) (pty.read-until child "ctrl-d to quit" 5000 {:on-chunk on-chunk})]
            (when (not first)
              (child:kill)
              (child:close)
              (error (.. "TUI first-paint marker not seen; captured "
                         (tostring (length (or err-out "")))
                         " bytes in " artifacts)))
            (let [startup-ms (math.floor (* (- (pty.now) started) 1000))
                  quit "\004"]
              (set bytes-written.n (+ bytes-written.n (length quit)))
              (pty.cast-event cast-path (- (pty.now) started) "i" quit)
              (assert (child:write quit))
              (pty.drain child 500 {:on-chunk on-chunk})
              (let [(status wait-err) (child:wait 3000)]
                (when (not status)
                  (child:kill)
                  (child:close)
                  (error (.. "fen did not exit after Ctrl-D: " (tostring wait-err))))
                (child:close)
                (pty.write-file metrics-path
                  (.. (pty.encode-json {:scenario "startup"
                                        :cols cols
                                        :rows rows
                                        :startup_to_first_paint_ms startup-ms
                                        :bytes_read bytes-read.n
                                        :bytes_written bytes-written.n
                                        :exit_code status.code
                                        :exit_signal status.signal
                                        :artifacts artifacts})
                      "\n"))
                (h.rmtree tmp)
                (assert.are.equal true status.exited)
                (assert.are.equal 0 status.code)))))))))
