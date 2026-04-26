(local agent-mod (require :core.agent))
(local session-mod (require :core.session))
(local skills-mod (require :core.skills))
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
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skills DIR         Additional directory to scan for SKILL.md (repeatable)
  -h, --help           Show this help

Environment:
  OPENAI_API_KEY       Required when --provider=openai
  ANTHROPIC_API_KEY    Required when --provider=anthropic
  AGENT_FENNEL_LOG     debug | info | warn | error (default: info)
  XDG_STATE_HOME       Sessions dir (default: ~/.local/state/agent-fennel)
  XDG_CONFIG_HOME      User skills dir (default: ~/.config/agent-fennel)
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
  (let [opts {:provider :openai :max-tokens 1024 :extra-skill-dirs []}]
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
            (= a :--continue)
            (do (set opts.continue? true) (set i (+ i 1)))
            (= a :--no-session)
            (do (set opts.no-session? true) (set i (+ i 1)))
            (= a :--skills)
            (do (table.insert opts.extra-skill-dirs (. argv (+ i 1)))
                (set i (+ i 2)))
            (do (io.stderr:write (.. "unknown arg: " a "\n")) (os.exit 2)))))
    opts))

(fn resolve-provider [opts]
  (let [api (. PROVIDER-API opts.provider)]
    (when (not api)
      (io.stderr:write (.. "unknown --provider: " (tostring opts.provider) "\n"))
      (os.exit 2))
    api))

(fn build-system-prompt [opts skills]
  "Combine the user's --system value with a discovered-skills section.
   Returns nil when both are absent so the agent record stores nil and
   providers omit the system field entirely."
  (let [skill-text (skills-mod.system-prompt-section skills)]
    (if (and opts.system skill-text) (.. opts.system "\n\n" skill-text)
        opts.system opts.system
        skill-text skill-text
        nil)))

(fn make-agent-from-opts [opts api-key on-event skills]
  (let [provider-options {}]
    (when opts.thinking-budget
      (set provider-options.thinking-budget opts.thinking-budget))
    (agent-mod.make-agent
      {:provider-api (resolve-provider opts)
       :model (or opts.model (. DEFAULT-MODELS opts.provider))
       :system (build-system-prompt opts skills)
       :api-key api-key
       :max-tokens opts.max-tokens
       : provider-options
       : on-event})))

(fn cwd []
  ;; PWD is what the user thinks of as cwd (preserves symlinks); fall back to
  ;; pwd shell builtin if not set. We slug this for the session dir, so it
  ;; just needs to be stable per-project.
  (or (os.getenv :PWD)
      (let [pipe (io.popen "pwd")
            out (and pipe (pipe:read :*l))]
        (when pipe (pipe:close))
        (or out "/"))))

(fn open-session [opts]
  "Open a transcript file for this run, unless --no-session is set."
  (if opts.no-session?
      nil
      (session-mod.open (cwd))))

(fn maybe-resume [opts agent]
  "If --continue, replay the latest session's messages into agent.messages
   so the next step has full prior context. Returns the count of replayed
   messages so the session writer can skip re-saving them."
  (if (not opts.continue?)
      0
      (let [path (session-mod.latest-for-cwd (cwd))]
        (if (not path)
            (do (log.warn "session: --continue but no prior session found")
                0)
            (let [msgs (session-mod.load path)]
              (each [_ m (ipairs msgs)]
                (table.insert agent.messages m))
              (length msgs))))))

(fn make-flush [agent session]
  "Returns a closure that appends any messages added since the last call.
   Tracks `last-saved` across invocations."
  (var last-saved 0)
  (fn []
    (when session
      (while (< last-saved (length agent.messages))
        (set last-saved (+ last-saved 1))
        (session-mod.append session (. agent.messages last-saved))))))

(fn run-print [opts api-key skills]
  (let [agent (make-agent-from-opts
                opts api-key
                (fn [ev]
                  (when (= ev.type :error)
                    (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
                skills)
        session (open-session opts)
        replayed (maybe-resume opts agent)
        flush (make-flush agent session)]
    ;; Replayed messages came from disk — mark them already-saved so we don't
    ;; re-write them.
    (when (> replayed 0) (flush))
    (let [(ok? result) (xpcall #(agent-mod.step agent opts.print) debug.traceback)]
      (flush)
      (session-mod.close session)
      (if ok?
          (print result)
          (do (io.stderr:write (.. "agent crashed: " (tostring result) "\n"))
              (os.exit 1))))))

(fn run-interactive [opts api-key skills]
  (let [tui (require :tui.tui)
        agent (make-agent-from-opts
                opts api-key (fn [ev] (tui.append-event ev)) skills)
        session (open-session opts)
        replayed (maybe-resume opts agent)
        flush (make-flush agent session)]
    (when (> replayed 0) (flush))
    (tui.init!)
    (let [(ok? err) (xpcall
                      #(tui.run (fn [line]
                                  (let [r (agent-mod.step agent line)]
                                    (flush)
                                    r)))
                      debug.traceback)]
      (tui.shutdown)
      (session-mod.close session)
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
      (let [skills (skills-mod.discover opts.extra-skill-dirs)]
        (if opts.print
            (run-print opts api-key skills)
            (run-interactive opts api-key skills))))))

(main arg)
