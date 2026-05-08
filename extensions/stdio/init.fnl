;; Stdio presenter extension: append-only line-mode conversation over
;; ordinary stdin/stdout. No termbox2, no cursor addressing, no redraw loop.

(local extensions (require :fen.core.extensions))
(local json (require :fen.util.json))

(local M {})

(local stream-state {:kind nil})

(local ANSI
  {:reset "\27[0m"
   :bold-cyan "\27[1;36m"
   :bold-green "\27[1;32m"
   :bold-yellow "\27[1;33m"
   :bold-blue "\27[1;34m"
   :bold-red "\27[1;31m"
   :dim "\27[2m"})

(local PREFIX-STYLES
  {"you> " ANSI.bold-cyan
   "ai> " ANSI.bold-green
   "tool> " ANSI.bold-yellow
   "tool< " ANSI.bold-blue
   "info> " ANSI.dim
   "err> " ANSI.bold-red
   "> " ANSI.dim})

(fn status-ok? [ok how code]
  (or (= ok true)
      (= ok 0)
      (and (= how :exit) (= code 0))))

(fn tty-fd? [fd]
  (status-ok? (os.execute (.. "test -t " (tostring fd) " >/dev/null 2>&1"))))

(fn color-enabled? [stream]
  (let [override (os.getenv :FEN_COLOR)
        no-color (os.getenv :NO_COLOR)
        term (or (os.getenv :TERM) "")]
    (if (= override :never) false
        (= override :always) true
        (and (not no-color)
             (not= term :dumb)
             (if (= stream :stderr) (tty-fd? 2) (tty-fd? 1))))))

(fn styled-prefix [prefix stream]
  (let [style (. PREFIX-STYLES prefix)]
    (if (and style (color-enabled? stream))
        (.. style prefix ANSI.reset)
        prefix)))

(fn safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

(fn choice-label [choice]
  (if (= (type choice) :table)
      (tostring (or choice.label choice.name choice.value choice))
      (tostring choice)))

(fn text-blocks->text [content]
  (if (= content nil)
      ""
      (= (type content) :string)
      content
      (let [parts []]
        (each [_ block (ipairs content)]
          (if (= block.type :text)
              (table.insert parts (or block.text ""))
              (= block.type :thinking)
              (table.insert parts (or block.thinking ""))
              (table.insert parts (safe-json block))))
        (table.concat parts "\n"))))

(fn write-line [out prefix text stream]
  (let [s (tostring (or text ""))
        p (styled-prefix prefix stream)]
    (if (= s "")
        (out:write p "\n")
        (each [line (string.gmatch (.. s "\n") "([^\n]*)\n")]
          (out:write p line "\n"))))
  (out:flush))

(fn stdout-line [prefix text]
  (write-line io.stdout prefix text :stdout))

(fn stderr-line [prefix text]
  (write-line io.stderr prefix text :stderr))

(fn finish-stream! []
  (when stream-state.kind
    (io.stdout:write "\n")
    (io.stdout:flush)
    (set stream-state.kind nil)))

(fn stream-delta! [kind prefix delta]
  (when (not= stream-state.kind kind)
    (finish-stream!)
    (io.stdout:write (styled-prefix prefix :stdout))
    (set stream-state.kind kind))
  (io.stdout:write (tostring (or delta "")))
  (io.stdout:flush))

(fn tool-call-text [ev]
  (.. (tostring (or ev.name "tool"))
      (if ev.arguments (.. " " (safe-json ev.arguments)) "")))

(fn tool-result-text [ev]
  (let [body (text-blocks->text (?. ev :result :content))
        head (.. (tostring (or ev.name ev.tool-name "tool"))
                 (if ev.id (.. " " (tostring ev.id)) ""))]
    (if (= body "") head (.. head "\n" body))))

;; @doc fen.extensions.stdio.render-event
;; kind: function
;; signature: (render-event ev) -> nil
;; summary: Render one event to stdio with prefixes, optional ANSI color, streaming delta coalescing, and stderr errors.
;; tags: stdio presenter events
(fn M.render-event [ev]
  (when ev
    (if (or (= ev.type :assistant-text) (= ev.type :assistant-thinking)
            (= ev.type :tool-call) (= ev.type :tool-result)
            (= ev.type :info) (= ev.type :queued)
            (= ev.type :steering-injected) (= ev.type :follow-up-injected)
            (= ev.type :cancelled) (= ev.type :error)
            (= ev.type :provider-retry) (= ev.type :user))
        (finish-stream!))
    (case ev.type
      :user (when (not ev.stdio-local?)
              (stdout-line "you> " ev.text))
      :assistant-text (stdout-line "ai> " ev.text)
      :assistant-thinking (stdout-line "ai> " ev.text)
      :assistant-text-delta (stream-delta! :assistant-text "ai> " ev.delta)
      :assistant-thinking-delta (stream-delta! :assistant-thinking "ai> " ev.delta)
      :assistant-stream-end (finish-stream!)
      :tool-call (stdout-line "tool> " (tool-call-text ev))
      :tool-result (stdout-line "tool< " (tool-result-text ev))
      :queued (stdout-line "info> "
                           (.. "queued " (tostring (or ev.queue "message"))
                               ": " (tostring (or ev.text ""))))
      :steering-injected (stdout-line "you> " ev.text)
      :follow-up-injected (stdout-line "you> " ev.text)
      :cancelled (stdout-line "info> cancelled")
      :provider-retry (stdout-line "info> "
                                   (.. "provider retry "
                                       (tostring (or ev.attempt "?")) "/"
                                       (tostring (or ev.max-attempts "?"))
                                       (if ev.reason (.. ": " (tostring ev.reason)) "")))
      :info (stdout-line "info> " ev.text)
      :error (stderr-line "err> " ev.error)
      _ nil)))

;; @doc fen.extensions.stdio.stdin-tty?
;; kind: function
;; signature: (stdin-tty?) -> boolean
;; summary: Return whether stdin is an interactive terminal for prompt-prefix and line-mode behavior.
;; tags: stdio presenter tty
(fn M.stdin-tty? []
  (tty-fd? 0))

(fn sleep-tick []
  ;; GNU/coreutils and BusyBox sleep accept fractional seconds on the targets
  ;; we support. Failure is harmless; it only prevents a CPU-relief pause
  ;; between ticks.
  (os.execute "sleep 0.03 >/dev/null 2>&1")
  nil)

;; @doc fen.extensions.stdio.drain-turn
;; kind: function
;; signature: (drain-turn ctx) -> nil
;; summary: Drive cooperative on-tick callbacks until the active agent turn completes in stdio mode.
;; tags: stdio presenter loop
(fn M.drain-turn [ctx]
  (while (and ctx.is-busy? (ctx.is-busy?))
    (when ctx.on-tick
      (let [(ok? err) (pcall ctx.on-tick)]
        (when (not ok?)
          (extensions.emit {:type :error
                            :error (.. "on-tick: " (tostring err))}))))
    (when (and ctx.is-busy? (ctx.is-busy?))
      (sleep-tick))))

;; @doc fen.extensions.stdio.submit-line
;; kind: function
;; signature: (submit-line ctx line interactive?) -> nil
;; summary: Echo and submit one user line, then drain the resulting turn or emit a submit error.
;; tags: stdio presenter input
(fn M.submit-line [ctx line interactive?]
  (when (not= line "")
    (extensions.emit {:type :user :text line :stdio-local? interactive?})
    (let [(ok? err) (pcall ctx.on-submit line)]
      (if ok?
          (M.drain-turn ctx)
          (extensions.emit {:type :error
                            :error (.. "submit: " (tostring err))})))))

;; @doc fen.extensions.stdio.run
;; kind: function
;; signature: (run ctx) -> nil
;; summary: Run the line-oriented stdio presenter loop until EOF, prompting interactively when stdin is a TTY.
;; tags: stdio presenter run
(fn M.run [ctx]
  (let [interactive? (M.stdin-tty?)]
    (stdout-line "info> " "fen stdio — Ctrl-D/EOF to quit")
    (var done? false)
    (while (not done?)
      (when interactive?
        (io.stdout:write (styled-prefix "you> " :stdout))
        (io.stdout:flush))
      (let [line (io.read "*l")]
        (if (= line nil)
            (set done? true)
            (M.submit-line ctx line interactive?))))
    (finish-stream!)))

;; @doc fen.extensions.stdio.notify
;; kind: function
;; signature: (notify text opts?) -> nil
;; summary: Implement the stdio UI notify hook by printing an informational line.
;; tags: stdio presenter ui notify
(fn M.notify [text _opts]
  (stdout-line "info> " text))

;; @doc fen.extensions.stdio.prompt
;; kind: function
;; signature: (prompt opts) -> string|nil
;; summary: Implement the stdio UI prompt hook by printing a label and reading one line from stdin.
;; tags: stdio presenter ui prompt
(fn M.prompt [opts]
  (let [opts (or opts {})]
    (io.stdout:write (.. (tostring (or opts.label "prompt")) ": "))
    (io.stdout:flush)
    (io.read "*l")))

;; @doc fen.extensions.stdio.select
;; kind: function
;; signature: (select opts) -> Choice|nil
;; summary: Implement the stdio UI select hook by listing choices and returning the numbered selection.
;; tags: stdio presenter ui select
(fn M.select [opts]
  (let [opts (or opts {})
        choices (or opts.choices [])]
    (stdout-line "info> " (or opts.label "select"))
    (each [i choice (ipairs choices)]
      (io.stdout:write (.. "  " (tostring i) ". " (choice-label choice) "\n")))
    (io.stdout:write (styled-prefix "> " :stdout))
    (io.stdout:flush)
    (let [line (io.read "*l")
          n (and line (tonumber line))]
      (when (and n (>= n 1) (<= n (length choices)))
        (. choices n)))))

(local PRESENTER-CONTROL-EVENTS
  {:message-appended true
   :set-status-info true
   :reset-conversation true
   :reinit-presenter true
   :redraw true
   :dismiss true})

(fn M.register [api]
  (api.on :*
          (fn [ev]
            (when (not (. PRESENTER-CONTROL-EVENTS ev.type))
              (M.render-event ev))))

  (api.on :reset-conversation
          (fn [_]
            (stdout-line "info> " "new conversation")))
  (api.on :reinit-presenter
          (fn [_]
            (stdout-line "info> " "stdio presenter reloaded")))
  (api.on :set-status-info
          (fn [ev]
            (let [info (or ev.info {})]
              (when (or info.provider info.model)
                (stdout-line "info> "
                             (.. "model " (tostring (or info.provider "?"))
                                 ":" (tostring (or info.model "?"))))))))

  (api.register :presenter
                {:name :stdio
                 :active? true
                 :init (fn [_ctx] nil)
                 :shutdown (fn [_ctx] (finish-stream!))
                 :run (fn [ctx] (M.run ctx))
                 :ui {:notify (fn [text opts] (M.notify text opts))
                      :prompt (fn [opts] (M.prompt opts))
                      :select (fn [opts] (M.select opts))}})
  true)

M
