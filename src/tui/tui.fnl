;; ANSI-based TUI: raw-mode stdin, colored stdout. No C extension required.
;; This is a line-printer-style transcript with a single editable input line —
;; not a full-screen curses app. Suitable for any terminal that speaks ANSI.

(local ESC "\27[")
(local RESET (.. ESC "0m"))
(local CYAN   (.. ESC "36m"))
(local GREEN  (.. ESC "32m"))
(local YELLOW (.. ESC "33m"))
(local RED    (.. ESC "31m"))
(local DIM    (.. ESC "2m"))

(var raw-active? false)
(var saved-stty nil)

(fn capture-stty []
  (let [pipe (io.popen "stty -g 2>/dev/null")]
    (when pipe
      (set saved-stty (pipe:read :*l))
      (pipe:close))))

(fn enter-raw! []
  (when (not raw-active?)
    (capture-stty)
    (os.execute "stty raw -echo isig 2>/dev/null")
    (set raw-active? true)))

(fn leave-raw! []
  (when raw-active?
    (if saved-stty
        (os.execute (.. "stty " saved-stty " 2>/dev/null"))
        (os.execute "stty sane 2>/dev/null"))
    (set raw-active? false)))

(fn writeln [s]
  (io.write s)
  ;; In raw mode, "\n" alone won't return the carriage; emit CRLF.
  (io.write "\r\n")
  (io.flush))

(fn color-line [color label text]
  (writeln (.. color label RESET " " (or text ""))))

(fn append-event [ev]
  (if (= ev.type :user)
      (color-line CYAN   "you>" ev.text)
      (= ev.type :assistant-text)
      (color-line GREEN  "ai> " ev.text)
      (= ev.type :tool-call)
      (color-line YELLOW "tool>" (.. ev.name " " (or ev.arguments "{}")))
      (= ev.type :tool-result)
      (let [out (or (?. ev :result :output) "")
            preview (string.sub out 1 1024)
            indented (string.gsub preview "\n" "\r\n     ")]
        (writeln (.. DIM "     " indented RESET)))
      (= ev.type :error)
      (color-line RED    "err>" (tostring ev.error))
      (= ev.type :llm-start)
      (writeln (.. DIM "...thinking" RESET))
      nil))

(fn redraw-prompt [buf]
  (io.write "\r")
  (io.write (.. ESC "2K"))    ; clear current line
  (io.write (.. CYAN "> " RESET buf))
  (io.flush))

(fn read-key []
  (io.read 1))

(fn read-line []
  (var buf "")
  (var done? false)
  (var quit? false)
  (redraw-prompt buf)
  (while (not done?)
    (let [ch (read-key)]
      (if (= ch nil)
          (do (set quit? true) (set done? true))           ; EOF
          (or (= ch "\n") (= ch "\r"))
          (do (writeln "") (set done? true))
          (or (= ch "\8") (= ch "\127"))                   ; backspace / DEL
          (do (set buf (string.sub buf 1 -2)) (redraw-prompt buf))
          (= ch "\3")                                      ; ctrl-c
          (do (writeln "") (set quit? true) (set done? true))
          (= ch "\4")                                      ; ctrl-d
          (do (writeln "") (set quit? true) (set done? true))
          (let [b (string.byte ch)]
            (when (and b (>= b 32) (< b 127))
              (set buf (.. buf ch))
              (redraw-prompt buf))))))
  (values buf quit?))

(fn init! [] (enter-raw!))

(fn shutdown [] (leave-raw!))

(fn run [on-submit]
  (var running? true)
  (writeln (.. DIM "agent-fennel — ctrl-c or ctrl-d to quit" RESET))
  (while running?
    (let [(line quit?) (read-line)]
      (if quit?
          (set running? false)
          (and line (not= line ""))
          (do (append-event {:type :user :text line})
              (on-submit line))
          nil))))

{: init! : shutdown : append-event : run}
