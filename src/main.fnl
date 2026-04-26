(local agent-mod (require :core.agent))
(local session-mod (require :core.session))
(local skills-mod (require :core.skills))
(local commands (require :core.commands))
(local log (require :util.log))

(local USAGE
"agent-fennel — minimal Lua/Fennel coding agent

Usage:
  agent-fennel [options]
  agent-fennel --print \"your prompt\"

Options:
  --provider NAME      openai | anthropic (default: openai)
  --model NAME         Model id (default: gpt-5.5 for openai,
                       claude-sonnet-4-6 for anthropic)
  --system TEXT        System prompt
  --max-tokens N       Reply token cap (default: 16384). Reasoning models
                       (gpt-5*, o1, o3) charge their thinking against this
                       cap, so 1024 leaves nothing for visible output.
  --thinking-budget N  Anthropic only: enable extended thinking with N tokens
  --print TEXT         One-shot mode; prints final assistant text and exits
  --continue           Resume the most recent session for the current cwd
  --no-session         Do not write a transcript to disk
  --skills DIR         Additional directory to scan for SKILL.md (repeatable)
  -h, --help           Show this help

Slash commands (interactive mode):
  /new                 Reset the current conversation and start a fresh session.
  /reload              Hot-reload core modules (run `make build` first).
                       Session messages are preserved.
  /help                Show available commands

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
  {:openai :gpt-5.5
   :anthropic :claude-sonnet-4-6})

(local API-KEY-VARS
  {:openai :OPENAI_API_KEY
   :anthropic :ANTHROPIC_API_KEY})

(fn parse-args [argv]
  ;; Don't pre-fill :max-tokens here — keep it nil unless the user passes
  ;; --max-tokens, so the default lives in make-agent's `(or max-tokens N)`
  ;; fallback. That way /reload picks up a changed default without a
  ;; restart.
  (let [opts {:provider :openai :extra-skill-dirs []}]
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

;; Modules eligible for in-process /reload. Excludes :tui.state (mutable
;; terminal bookkeeping that must survive reloads — see src/tui/state.fnl)
;; and main (we are it). Reloadable behavior should live behind module-table
;; lookups, e.g. `commands.handle` or `tui.append-event`, so in-place module
;; mutation is visible on the next loop iteration. Edits to the executing
;; run-interactive loop body itself still need a restart, since that invocation
;; is already on the stack.
(local RELOADABLE
  [:core.types :core.llm :core.tools :core.agent
   :core.session :core.skills :core.commands
   :providers.openai_completions :providers.anthropic_messages
   :tui.tui
   :util.json :util.log])

(fn manual-reload! [modname]
  "Re-require modname and copy its new exports onto the original module
   table in place, so any prior `(local foo (require modname))` capture
   sees the new functions. Mirrors fennel.reload's mutation trick but
   works on already-compiled `dist/*.lua` modules too."
  (let [old (. package.loaded modname)]
    (tset package.loaded modname nil)
    (let [(ok? new) (pcall require modname)]
      (if (not ok?)
          (do (tset package.loaded modname old)
              (values false new))
          (do
            (when (and (= (type old) :table) (= (type new) :table))
              (each [k _ (pairs old)] (tset old k nil))
              (each [k v (pairs new)] (tset old k v))
              (tset package.loaded modname old))
            (values true nil))))))

(fn reload-modules! []
  (var ok-count 0)
  (let [failures []]
    (each [_ m (ipairs RELOADABLE)]
      (when (. package.loaded m)
        (let [(ok? err) (manual-reload! m)]
          (if ok?
              (set ok-count (+ ok-count 1))
              (table.insert failures (.. m ": " (tostring err)))))))
    (values ok-count failures)))

(fn run-interactive [opts api-key skills]
  (let [tui (require :tui.tui)
        on-event (fn [ev] (tui.append-event ev))
        agent (make-agent-from-opts opts api-key on-event skills)
        session (open-session opts)
        replayed (maybe-resume opts agent)
        flush (make-flush agent session)
        ;; Mutable container so reloadable command handlers can swap the agent
        ;; record after /reload or replace the session after /new while the
        ;; on-submit closure keeps a live view.
        state {: opts : api-key : skills : on-event : agent : session : flush
               : make-agent-from-opts
               :open-session open-session
               :make-flush make-flush
               :reload-modules reload-modules!}]
    (when (> replayed 0) (state.flush))
    (tui.init!)
    (let [(ok? err) (xpcall
                      #(tui.run (fn [line]
                                  (if (= (string.sub line 1 1) "/")
                                      (commands.handle line state)
                                      (let [r (agent-mod.step state.agent line)]
                                        (state.flush)
                                        r))))
                      debug.traceback)]
      (tui.shutdown)
      (session-mod.close state.session)
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
