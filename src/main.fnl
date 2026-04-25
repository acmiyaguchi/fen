(local agent-mod (require :core.agent))
(local log (require :util.log))

(local USAGE
"agent-fennel — minimal Lua/Fennel coding agent

Usage:
  agent-fennel [options]
  agent-fennel --print \"your prompt\"

Options:
  --model NAME       OpenAI model id (default: gpt-4o-mini)
  --system TEXT      System prompt
  --max-tokens N     Reply token cap (default: 1024)
  --print TEXT       One-shot mode; prints final assistant text and exits
  -h, --help         Show this help

Environment:
  OPENAI_API_KEY     Required.
  AGENT_FENNEL_LOG   debug | info | warn | error (default: info)
")

(fn parse-args [argv]
  (let [opts {:model :gpt-4o-mini :max-tokens 1024}]
    (var i 1)
    (while (<= i (length argv))
      (let [a (. argv i)]
        (if (or (= a :-h) (= a :--help))
            (do (set opts.help? true) (set i (+ i 1)))
            (= a :--model)
            (do (set opts.model (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--system)
            (do (set opts.system (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--max-tokens)
            (do (set opts.max-tokens (tonumber (. argv (+ i 1)))) (set i (+ i 2)))
            (= a :--print)
            (do (set opts.print (. argv (+ i 1))) (set i (+ i 2)))
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    opts))

(fn run-print [opts api-key]
  (let [agent (agent-mod.make-agent
                {:model opts.model
                 :system opts.system
                 :api-key api-key
                 :max-tokens opts.max-tokens
                 :on-event (fn [ev]
                             (when (= ev.type :error)
                               (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))})
        result (agent-mod.step agent opts.print)]
    (print result)))

(fn run-interactive [opts api-key]
  (let [tui (require :tui.tui)
        agent (agent-mod.make-agent
                {:model opts.model
                 :system opts.system
                 :api-key api-key
                 :max-tokens opts.max-tokens
                 :on-event (fn [ev] (tui.append-event ev))})]
    (tui.init!)
    (let [(ok? err) (xpcall #(tui.run (fn [line] (agent-mod.step agent line)))
                            debug.traceback)]
      (tui.shutdown)
      (when (not ok?)
        (io.stderr:write (.. "tui crashed: " (tostring err) "\n"))
        (os.exit 1)))))

(fn main [argv]
  (let [opts (parse-args argv)]
    (when opts.help? (io.write USAGE) (os.exit 0))
    (let [api-key (os.getenv :OPENAI_API_KEY)]
      (when (or (not api-key) (= api-key ""))
        (io.stderr:write "OPENAI_API_KEY not set\n")
        (os.exit 1))
      (if opts.print
          (run-print opts api-key)
          (run-interactive opts api-key)))))

(main arg)
