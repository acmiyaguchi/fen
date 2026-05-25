#!/usr/bin/env fennel
;; Auto-record the "what is fen?" hero cast (issue #141).
;;
;; Drives a REAL fen session non-interactively via the host-side PTY helper
;; (fen.testing.pty + fen_pty.so): spawn fen with a real provider, type each
;; pinned prompt so fen makes genuine `read` tool calls on this repo, waiting
;; for each streamed answer to settle, then exit — writing an asciicast-v2 cast.
;; scripts/docs/record-hero-cast.sh wraps this (builds fen_pty.so, renders
;; GIF/SVG); `make hero-cast` is the entry point.
;;
;; This calls a real model, so it needs a provider key in the env and the result
;; varies run to run — re-run until you get a good take. Configure via env:
;;   FEN_BIN          path to the fen binary (required; the wrapper resolves it)
;;   FEN_HERO_PROVIDER provider id (default: openai)
;;   FEN_HERO_MODEL    optional model id
;;   FEN_HERO_PROMPT   record a single-turn take with this prompt instead of the
;;                     default two-turn (README overview, then core deep-dive)
;;   FEN_HERO_COLS/ROWS terminal geometry (default 80x20)
;;   FEN_HERO_CAST     output cast path (default: docs/assets/casts/what-is-fen.cast)

(local fennel (require :fennel))

;; Resolve in-tree Fennel sources and freshly built native .so modules the same
;; way scripts/test/busted-helper.lua does, but standalone (no busted).
(fn each-line [cmd f]
  (let [p (io.popen cmd :r)]
    (when p
      (each [line (p:lines)] (f line))
      (p:close))))

(each-line "find packages -path '*/src' -type d | sort"
           (fn [dir] (set fennel.path (.. dir "/?.fnl;" dir "/?/init.fnl;" fennel.path))))
(each-line "find packages extensions -path '*/dist' -type d | sort"
           (fn [dir] (set package.cpath (.. dir "/?.so;" package.cpath))))

(local pty (require :fen.testing.pty))

(local FEN-BIN (or (os.getenv :FEN_BIN) "fen"))
(local PROVIDER (or (os.getenv :FEN_HERO_PROVIDER) "openai"))
(local MODEL (os.getenv :FEN_HERO_MODEL))
;; The hero is a short two-turn working session: a README overview, then a
;; follow-up that sends the agent to read core and describe the design. Set
;; FEN_HERO_PROMPT to record a single-turn take instead.
(local PROMPTS
  (if (os.getenv :FEN_HERO_PROMPT)
      [(os.getenv :FEN_HERO_PROMPT)]
      ["read the README and tell me about fen"
       "now read the core module and describe its high-level design"]))
(local CAST (or (os.getenv :FEN_HERO_CAST) "docs/assets/casts/what-is-fen.cast"))
;; fen's TUI pins the input row to the terminal bottom, so a height taller than
;; the content leaves dead space between the answer and the prompt — the demo
;; then renders as a mostly-empty box. Keep rows near the content height (the
;; transcript follows the bottom, so a multi-turn session stays full); override
;; for a longer/shorter take.
(local COLS (tonumber (or (os.getenv :FEN_HERO_COLS) 80)))
(local ROWS (tonumber (or (os.getenv :FEN_HERO_ROWS) 20)))

;; Timing budget for the live turn (wall-clock seconds).
(local FIRST-TOKEN-S 90)   ; how long to wait for the first response byte
(local QUIET-S 4)          ; stop once the stream has been silent this long
(local MAX-S 240)          ; hard cap on the whole turn

(fn die [msg] (io.stderr:write (.. "record-hero-cast: " msg "\n")) (os.exit 1))

;; Build argv for a real fen TUI run. We spawn the production binary (not the
;; dev overlay) so the demo matches what users run; --no-session keeps HOME clean.
(local argv [FEN-BIN "--provider" PROVIDER "--presenter" :tui "--no-session"])
(when (and MODEL (not= MODEL ""))
  (table.insert argv "--model")
  (table.insert argv MODEL))

;; Child inherits the parent env (apply_env in fen_pty.c only overlays), so the
;; provider key / real HOME flow through. We only neutralize terminal-size hints
;; for a deterministic geometry and quiet logs.
(local env {:TERM "xterm-256color"
            :LINES false
            :COLUMNS false
            :COLORTERM false
            :FEN_LOG "error"})

(pty.ensure-dir (string.match CAST "^(.+)/[^/]+$"))
(pty.cast-start CAST COLS ROWS {:TERM "xterm-256color"})

(local started (pty.now))
(var bytes-read 0)
(fn on-chunk [chunk]
  (set bytes-read (+ bytes-read (length chunk)))
  (pty.cast-event CAST (- (pty.now) started) "o" chunk))

(local child (assert (pty.spawn {:argv argv :cwd "." :env env :cols COLS :rows ROWS})))

(fn write-input [bytes]
  (pty.cast-event CAST (- (pty.now) started) "i" bytes)
  (assert (child:write bytes)))

;; Wait for first paint so the prompt lands in a ready TUI.
(let [(out captured) (pty.read-until child "ctrl-d to quit" 8000
                       {:on-chunk on-chunk})]
  (when (not out)
    (child:kill) (child:close)
    (die (.. "fen did not reach first paint; got "
             (tostring (length (or captured ""))) " bytes (check FEN_BIN/provider)"))))

;; Record one live turn: poll in short drains, return once the stream has been
;; quiet for QUIET-S after producing output (or give up if no first token).
(fn wait-turn []
  (let [turn-start (pty.now)]
    (var last-data turn-start)
    (var seen 0)
    (var done? false)
    (while (not done?)
      (let [chunk (pty.drain child 500 {:on-chunk on-chunk})
            now (pty.now)]
        (if (not= chunk "")
            (do (set seen (+ seen (length chunk))) (set last-data now))
            (and (> seen 0) (>= (- now last-data) QUIET-S))
            (set done? true)
            (and (= seen 0) (>= (- now turn-start) FIRST-TOKEN-S))
            (do (io.stderr:write "record-hero-cast: WARNING no response (timeout)\n")
                (set done? true))
            (>= (- now turn-start) MAX-S)
            (do (io.stderr:write "record-hero-cast: WARNING hit max turn time\n")
                (set done? true)))))))

(each [_ prompt (ipairs PROMPTS)]
  (io.stderr:write (.. "record-hero-cast: typing prompt: " prompt "\n"))
  (write-input (.. prompt "\r"))
  (wait-turn))

;; Exit fen (Ctrl-D quits on an empty prompt) WITHOUT recording the shutdown:
;; the cast should end on the final answer, not fen's screen-clear on exit —
;; a looping demo must not flash an empty terminal.
(child:write "\004")
(pty.drain child 800 {})
(let [(status _) (child:wait 3000)]
  (when (not status) (child:kill))
  (child:close))

(io.stderr:write (.. "record-hero-cast: wrote " CAST " ("
                     (tostring bytes-read) " bytes captured)\n"))
