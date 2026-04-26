;; ANSI-based TUI: raw-mode stdin, colored stdout. No C extension required.
;; This is a line-printer-style transcript with a single editable input line —
;; not a full-screen curses app. Suitable for any terminal that speaks ANSI.
;;
;; Hot-reload note: every helper is a field on the module table `M`, and
;; internal calls go through `M.<name>` rather than bare names. That makes
;; the TUI eligible for /reload — when main.fnl mutates this module table
;; in place, the executing `M.run` loop body keeps running on the stack
;; with old upvalues, but each iteration's call to `M.read-line`,
;; `M.append-event`, etc. is a fresh table lookup and picks up new code.
;; Mutable terminal state lives in `tui.state`, which is *not* reloaded —
;; otherwise raw-mode bookkeeping would desync from the actual tty.

(local state (require :tui.state))
(local json (require :util.json))

(local ESC "\27[")
(local RESET (.. ESC "0m"))
(local CYAN   (.. ESC "36m"))
(local GREEN  (.. ESC "32m"))
(local YELLOW (.. ESC "33m"))
(local RED    (.. ESC "31m"))
(local DIM    (.. ESC "2m"))

(local M {})

(fn M.capture-stty []
  (let [pipe (io.popen "stty -g 2>/dev/null")]
    (when pipe
      (set state.saved-stty (pipe:read :*l))
      (pipe:close))))

(fn M.enter-raw! []
  (when (not state.raw-active?)
    (M.capture-stty)
    (os.execute "stty raw -echo isig 2>/dev/null")
    (set state.raw-active? true)))

(fn M.leave-raw! []
  (when state.raw-active?
    (if state.saved-stty
        (os.execute (.. "stty " state.saved-stty " 2>/dev/null"))
        (os.execute "stty sane 2>/dev/null"))
    (set state.raw-active? false)))

(fn M.writeln [s]
  ;; In raw mode, "\n" alone won't return the carriage. Normalize any
  ;; embedded LFs to CRLF, then terminate with one more CRLF.
  (let [normalized (string.gsub s "\r?\n" "\r\n")]
    (io.write normalized)
    (io.write "\r\n")
    (io.flush)))

(fn M.color-line [color label text]
  (M.writeln (.. color label RESET " " (or text ""))))

(fn M.args->string [args]
  (if (= (type args) :string) args
      (= args nil) "{}"
      (let [(ok? s) (pcall json.encode args)]
        (if ok? s "{}"))))

(fn M.content->text [content]
  "Concat all TextContent blocks of an AgentToolResult content list."
  (if (= content nil) ""
      (let [parts []]
        (each [_ b (ipairs content)]
          (when (= b.type :text)
            (table.insert parts (or b.text ""))))
        (table.concat parts ""))))

(fn M.append-event [ev]
  (if (= ev.type :user)
      (M.color-line CYAN   "you>" ev.text)
      (= ev.type :assistant-text)
      (M.color-line GREEN  "ai> " ev.text)
      (= ev.type :tool-call)
      (M.color-line YELLOW "tool>"
                    (.. (tostring ev.name) " " (M.args->string ev.arguments)))
      (= ev.type :tool-result)
      (let [out (M.content->text (?. ev :result :content))
            preview (string.sub out 1 1024)
            indented (string.gsub preview "\n" "\r\n     ")]
        (M.writeln (.. DIM "     " indented RESET)))
      (= ev.type :error)
      (M.color-line RED    "err>" (tostring ev.error))
      (= ev.type :llm-start)
      (M.writeln (.. DIM "...thinking" RESET))
      nil))

(fn M.redraw-prompt [buf]
  (io.write "\r")
  (io.write (.. ESC "2K"))    ; clear current line
  (io.write (.. CYAN "> " RESET buf))
  (io.flush))

(fn M.read-key []
  (io.read 1))

(fn M.read-line []
  (var buf "")
  (var done? false)
  (var quit? false)
  (M.redraw-prompt buf)
  (while (not done?)
    (let [ch (M.read-key)]
      (if (= ch nil)
          (do (set quit? true) (set done? true))           ; EOF
          (or (= ch "\n") (= ch "\r"))
          (do (M.writeln "") (set done? true))
          (or (= ch "\8") (= ch "\127"))                   ; backspace / DEL
          (do (set buf (string.sub buf 1 -2)) (M.redraw-prompt buf))
          (= ch "\3")                                      ; ctrl-c
          (do (M.writeln "") (set quit? true) (set done? true))
          (= ch "\4")                                      ; ctrl-d
          (do (M.writeln "") (set quit? true) (set done? true))
          (let [b (string.byte ch)]
            (when (and b (>= b 32) (< b 127))
              (set buf (.. buf ch))
              (M.redraw-prompt buf))))))
  (values buf quit?))

(fn M.init! [] (M.enter-raw!))

(fn M.shutdown [] (M.leave-raw!))

(fn M.run [on-submit]
  (var running? true)
  (M.writeln (.. DIM "agent-fennel — ctrl-c or ctrl-d to quit" RESET))
  (while running?
    (let [(line quit?) (M.read-line)]
      (if quit?
          (set running? false)
          (and line (not= line ""))
          (do (M.append-event {:type :user :text line})
              (on-submit line))
          nil))))

M
