(local agent-mod (require :core.agent))
(local log (require :util.log))

(local USAGE
"agent-fennel — minimal Lua/Fennel coding agent

Usage:
  agent-fennel [options]
  agent-fennel --print \"your prompt\"

Options:
  --provider NAME      openai | anthropic (default: openai)
  --model NAME         Model id (default: gpt-4o-mini for openai,
                       claude-sonnet-4-5-20250929 for anthropic)
  --system TEXT        System prompt
  --max-tokens N       Reply token cap (default: 1024)
  --thinking-budget N  Anthropic only: enable extended thinking with N tokens
  --print TEXT         One-shot mode; prints final assistant text and exits
  -h, --help           Show this help

Environment:
  OPENAI_API_KEY       Required when --provider=openai
  ANTHROPIC_API_KEY    Required when --provider=anthropic
  AGENT_FENNEL_LOG     debug | info | warn | error (default: info)
")

(local PROVIDER-API
  {:openai :openai-completions
   :anthropic :anthropic-messages})

(local DEFAULT-MODELS
  {:openai :gpt-4o-mini
   :anthropic :claude-sonnet-4-5-20250929})

(local API-KEY-VARS
  {:openai :OPENAI_API_KEY
   :anthropic :ANTHROPIC_API_KEY})

(fn parse-args [argv]
  (let [opts {:provider :openai :max-tokens 1024}]
    (var i 1)
    (while (<= i (length argv))
      (let [a (. argv i)]
        (if (or (= a :-h) (= a :--help))
            (do (set opts.help? true) (set i (+ i 1)))
            (= a :--provider)
            (do (set opts.provider (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--model)
            (do (set opts.model (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--system)
            (do (set opts.system (. argv (+ i 1))) (set i (+ i 2)))
            (= a :--max-tokens)
            (do (set opts.max-tokens (tonumber (. argv (+ i 1)))) (set i (+ i 2)))
            (= a :--thinking-budget)
            (do (set opts.thinking-budget (tonumber (. argv (+ i 1))))
                (set i (+ i 2)))
            (= a :--print)
            (do (set opts.print (. argv (+ i 1))) (set i (+ i 2)))
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    opts))

(fn resolve-provider [opts]
  (let [api (. PROVIDER-API opts.provider)]
    (when (not api)
      (io.stderr:write (.. "unknown --provider: " (tostring opts.provider) "\n"))
      (os.exit 2))
    api))

(fn make-agent-from-opts [opts api-key on-event]
  (let [provider-options {}]
    (when opts.thinking-budget
      (set provider-options.thinking-budget opts.thinking-budget))
    (agent-mod.make-agent
      {:provider-api (resolve-provider opts)
       :model (or opts.model (. DEFAULT-MODELS opts.provider))
       :system opts.system
       :api-key api-key
       :max-tokens opts.max-tokens
       : provider-options
       : on-event})))

(fn run-print [opts api-key]
  (let [agent (make-agent-from-opts
                opts api-key
                (fn [ev]
                  (when (= ev.type :error)
                    (io.stderr:write (.. "error: " (tostring ev.error) "\n")))))
        result (agent-mod.step agent opts.print)]
    (print result)))

(fn run-interactive [opts api-key]
  (let [tui (require :tui.tui)
        agent (make-agent-from-opts
                opts api-key (fn [ev] (tui.append-event ev)))]
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
    (let [key-var (. API-KEY-VARS opts.provider)
          api-key (os.getenv key-var)]
      (when (or (not api-key) (= api-key ""))
        (io.stderr:write (.. (tostring key-var) " not set\n"))
        (os.exit 1))
      (if opts.print
          (run-print opts api-key)
          (run-interactive opts api-key)))))

(main arg)
