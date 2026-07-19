(var llm nil)
(var models-mod nil)
(var thinking nil)
(var settings nil)
(var provider-registry nil)
(var auth-backend-registry nil)
(var extension-loader nil)
(var log nil)
(var rocks nil)
(var script-runner nil)
(var version-mod nil)
(var diagnostics nil)
(var provider-help nil)
(var interactive nil)
(var cli-discovery nil)
(var cli-help nil)
(var cli-flags nil)

(fn ensure-version! []
  (when (not version-mod)
    (set version-mod (require :fen.version)))
  version-mod)

(fn version-line []
  (let [v (ensure-version!)]
    (if (= (type v) :table)
        (if (= (type v.format) :function)
            (v.format)
            (.. "fen " (tostring (or v.version "unknown"))
                " (" (tostring (or v.source "unknown"))
                (if v.targetSystem (.. ", " (tostring v.targetSystem)) "")
                ")"))
        (.. "fen " (tostring (or v "unknown"))))))

(fn install-runtime-info! []
  (when diagnostics
    (let [v (ensure-version!)]
      (when (and (= (type v) :table) (= (type v.info) :function))
        (let [(ok? info) (pcall v.info)]
          (when ok?
            (diagnostics.set-runtime-info! info)))))))

(fn ensure-rocks! []
  (when (not rocks)
    (set rocks (require :fen.core.extensions.rocks)))
  rocks)

(fn ensure-script-runner! []
  (when (not script-runner)
    (set script-runner (require :fen.script_runner)))
  script-runner)

(fn ensure-provider-help! []
  (when (not provider-help)
    (set provider-help (require :fen.provider_help)))
  provider-help)

(fn ensure-cli-discovery! []
  (when (not cli-discovery)
    (set cli-discovery (require :fen.cli_discovery)))
  cli-discovery)

(fn ensure-cli-help! []
  (when (not cli-help)
    (set cli-help (require :fen.cli_help)))
  cli-help)

(fn ensure-cli-flags! []
  (when (not cli-flags)
    (set cli-flags (require :fen.cli_flags)))
  cli-flags)

(fn ensure-runtime! []
  "Load runtime modules lazily so `fen --help` can run from the single-file
   prototype without loading JSON/HTTP/TUI/provider C dependencies."
  (when (not llm)
    (set llm (require :fen.core.llm))
    (set models-mod (require :fen.core.llm.models))
    (set thinking (require :fen.core.thinking))
    (set settings (require :fen.core.settings))
    (set diagnostics (require :fen.core.diagnostics))
    (install-runtime-info!)
    (set provider-registry (require :fen.core.extensions.register.provider))
    (set auth-backend-registry (require :fen.core.extensions.register.auth_backend))
    (set extension-loader (require :fen.core.extensions.loader))
    (set log (require :fen.util.log))
    ;; fen.interactive pulls in the agent, tool/command/presenter registries,
    ;; and turn/session runtime as a side effect of its top-level requires.
    (set interactive (require :fen.interactive))))


(fn model-id-present? [provider id]
  (var found? false)
  (each [_ m (ipairs (or provider.models []))]
    (let [mid (if (= (type m) :table) m.id m)]
      (when (= (tostring mid) (tostring id))
        (set found? true))))
  found?)

(fn provider-default-model [provider]
  (or provider.default-model (models-mod.first-model-id provider)))

(var resolve-provider-config nil)

(fn fallback-from-settings! [opts reason]
  "A persisted default should not brick startup. Warn once, then fall back to
   the built-in provider default. If the built-in fallback is also unusable,
   resolve-provider-config will report the normal hard error on the second pass."
  (log.warn (.. "settings: " reason "; falling back to openai"))
  (set opts.provider :openai)
  (set opts.model nil)
  (set opts.provider-from-settings? false)
  (set opts.model-from-settings? false)
  (resolve-provider-config opts))

(fn fail-provider! [opts reason cli-message exit-code]
  "A persisted default warns and falls back; an explicit CLI value is a hard
   error. Both unusable-provider paths funnel through here so the
   settings-vs-CLI branch is written once."
  (if opts.provider-from-settings?
      (fallback-from-settings! opts reason)
      (do
        (io.stderr:write (.. cli-message "\n"))
        (os.exit exit-code))))

(set resolve-provider-config
  (fn [opts]
  "Returns a record describing the provider to use for this run:
   {:name :provider-name :model :api-key :base-url :compat}.

   Provider registry names are the dispatch contract. models.json providers
   are registered after first-party providers, so a custom provider with the
   same name overrides the built-in entry. Built-ins require their configured
   auth; custom providers may have no api-key at all (Ollama-style local
   servers)."
  (let [name opts.provider
        provider (provider-registry.find name)]
    (if (not provider)
        (fail-provider!
          opts
          (.. "defaultProvider " (tostring name) " is not configured")
          (let [help (ensure-provider-help!)]
            (help.unknown-provider-message name))
          2)
        (let [default-model (provider-default-model provider)
              model (if (and opts.model opts.model-from-settings?
                             default-model
                             (> (length (or provider.models [])) 0)
                             (not (model-id-present? provider opts.model)))
                        (do (log.warn (.. "settings: defaultModel "
                                          (tostring opts.model)
                                          " is not declared for provider "
                                          (tostring name)
                                          "; using " (tostring default-model)))
                            default-model)
                        (or opts.model default-model))]
          (if provider.auth-backend
              ;; Auth-backed providers resolve credentials through the
              ;; extension auth-backend registry so providers/auth can ship
              ;; outside core.
              (let [backend (auth-backend-registry.find provider.auth-backend)]
                (if (not backend)
                    (fail-provider!
                      opts
                      (.. "defaultProvider " (tostring name)
                          " has missing auth backend "
                          (tostring provider.auth-backend))
                      (.. "missing auth backend: "
                          (tostring provider.auth-backend))
                      1)
                    (let [(ok? creds) (pcall backend.get-fresh-creds!)]
                      (if (not ok?)
                          (fail-provider!
                            opts
                            (.. "defaultProvider " (tostring name)
                                " is unavailable: " (tostring creds))
                            (tostring creds)
                            1)
                          {:name name :provider-name provider.name :api provider.api
                           :api-key nil :model model :base-url provider.base-url
                           :compat provider.compat :creds creds}))))
              (let [key-var provider.api-key-var
                    env-key (and key-var (os.getenv key-var))]
                (if (and key-var (or (not env-key) (= env-key "")))
                    (fail-provider!
                      opts
                      (.. "defaultProvider " (tostring name)
                          " requires " (tostring key-var))
                      (let [help (ensure-provider-help!)
                            ;; `fail-provider!` always falls back to the
                            ;; built-in default when the settings-derived
                            ;; provider is missing creds, so by the time this
                            ;; message renders, the active provider is either
                            ;; explicit (--provider) or the built-in fallback.
                            source (if opts.provider-explicit? :explicit :default)]
                        (help.missing-provider-message name key-var source))
                      1)
                    {:name name :provider-name provider.name :api provider.api
                     :api-key (or env-key provider.api-key)
                     :model model
                     :base-url provider.base-url
                     :compat provider.compat}))))))))

(fn starts-with? [s prefix]
  (= (string.sub (tostring s) 1 (length prefix)) prefix))

(fn cli-context [goal-mode?]
  (if goal-mode? :goal :top))

(fn die-usage! [message]
  (io.stderr:write (.. message "\n"))
  (os.exit 2))

(fn option-token? [token]
  (starts-with? token "-"))

(fn consume-flag! [opts flag argv i]
  "Apply a declarative flag parse action and return the next argv index."
  (let [parse flag.parse
        action parse.action]
    (if (= action :help-all)
        (do
          (set opts.help? true)
          (set opts.help-all? true)
          (+ i 1))
        (= flag.arg :value)
        (let [value (. argv (+ i 1))]
          (when (or (not value)
                    (and parse.value-must-not-look-like-flag?
                         (option-token? value)))
            (die-usage! (or parse.missing-message
                            (.. flag.name " requires a value"))))
          (case action
            :set-value
            (tset opts parse.dest
                  (if (= parse.value-kind :number) (tonumber value) value))

            :append-value
            (table.insert (. opts parse.dest) value)

            :read-file
            (let [f (io.open value :r)]
              (when (not f)
                (die-usage! (.. (or parse.read-error
                                    (.. "cannot read " flag.name))
                                ": " value)))
              (tset opts parse.dest (f:read :*a))
              (f:close))

            _
            (error (.. "unsupported value flag action: " (tostring action))))
          (when parse.mark
            (tset opts parse.mark true))
          (+ i 2))
        (do
          (case action
            :set-true
            (tset opts parse.dest true)

            :set-const
            (tset opts parse.dest parse.const)

            _
            (error (.. "unsupported flag action: " (tostring action))))
          (when parse.mark
            (tset opts parse.mark true))
          (+ i 1)))))

(fn parse-args [argv ?start-index ?goal-mode]
  ;; Don't pre-fill :max-tokens here — keep it nil unless the user passes
  ;; --max-tokens, so the default lives in make-agent's `(or max-tokens N)`
  ;; fallback. That way /reload picks up a changed default without a
  ;; restart.
  (let [opts {:presenter :tui
              :extra-skill-paths [] :extension-paths []
              :dev-paths [] :extension-roots []
              :session-backend :jsonl}
        flags (ensure-cli-flags!)
        context (cli-context ?goal-mode)]
    (var i (or ?start-index 1))
    (var collecting-objective? false)
    (when ?goal-mode
      (set opts.goal? true)
      (set opts.presenter :goal-headless)
      (set opts.objective-parts []))
    (while (<= i (length argv))
      (let [a (. argv i)
            known-flag (and (option-token? a) (flags.find-any a))
            flag (and known-flag (flags.find a context))]
        (if flag
            (set i (consume-flag! opts flag argv i))
            known-flag
            (die-usage! (flags.invalid-message known-flag context))
            (and ?goal-mode (= a :--))
            (do (set collecting-objective? true) (set i (+ i 1)))
            (and ?goal-mode
                 (or collecting-objective?
                     (not (option-token? a))))
            (do (set collecting-objective? true)
                (table.insert opts.objective-parts (tostring a))
                (set i (+ i 1)))
            (option-token? a)
            (do (io.stderr:write (flags.unknown-message a context))
                (os.exit 2))
            (die-usage! (.. "unknown arg: " a)))))
    (when ?goal-mode
      (set opts.objective (table.concat opts.objective-parts " "))
      (set opts.objective-parts nil)
      (when (and (= opts.objective "") (not opts.help?))
        (io.stderr:write "usage: fen goal [options] <objective>\n")
        (os.exit 2))
      (when (and opts.max-iterations-given? (not opts.max-iterations))
        (io.stderr:write "--max-iterations must be an integer from 1 to 20\n")
        (os.exit 2))
      (set opts.max-iterations (or opts.max-iterations 3))
      (set opts.max-iterations-given? nil)
      (when (or (not= opts.max-iterations (math.floor opts.max-iterations))
                (< opts.max-iterations 1) (> opts.max-iterations 20))
        (io.stderr:write "--max-iterations must be an integer from 1 to 20\n")
        (os.exit 2)))
    (when (and opts.print opts.prompt-file)
      (io.stderr:write "--print and --prompt-file cannot be combined\n")
      (os.exit 2))
    (when opts.prompt-file
      (let [f (io.open opts.prompt-file :r)]
        (when (not f)
          (io.stderr:write (.. "cannot read --prompt-file: " opts.prompt-file "\n"))
          (os.exit 2))
        (set opts.print (f:read :*a))
        (f:close)))
    ;; Keep the `--print -` stdin sentinel explicit: it is a one-shot prompt
    ;; value convention, not generic flag value parsing.
    (when (= opts.print "-")
      (set opts.print (io.read :*a)))
    (when (and opts.no-tools? opts.tools)
      (io.stderr:write "--no-tools and --tools cannot be combined\n")
      (os.exit 2))
    (when (and opts.print (= opts.presenter :tui))
      ;; `--print` is a one-shot presenter selection, not an interactive
      ;; mode modifier. Default to the print presenter, but only when no
      ;; non-default presenter was requested explicitly (e.g. `--presenter
      ;; json --print TEXT` keeps json). Order-independent with `--presenter`.
      (set opts.presenter :print))
    (when opts.thinking
      (when (not thinking)
        (set thinking (require :fen.core.thinking)))
      (when (not (thinking.valid-level? opts.thinking))
        (io.stderr:write (.. "invalid --thinking: " (tostring opts.thinking)
                            " (expected " (thinking.level-list) ")\n"))
        (os.exit 2)))
    (when (and (not= opts.presenter :tui)
               (not= opts.presenter :stdio)
               (not= opts.presenter :web)
               (not= opts.presenter :print)
               (not= opts.presenter :json)
               (not= opts.presenter :goal-headless))
      (io.stderr:write (.. "unknown --presenter: " (tostring opts.presenter)
                          " (expected tui | stdio | web | print | json)\n"))
      (os.exit 2))
    (when (and (or (= opts.presenter :print) (= opts.presenter :json))
               (not opts.print))
      (io.stderr:write (.. "--presenter " (tostring opts.presenter)
                          " requires --print TEXT\n"))
      (os.exit 2))
    opts))

(fn apply-model-prefix! [opts]
  "Resolve a `--model provider/model` canonical id into an implied --provider
   plus a bare upstream model id, so discovery `canonical-id` values round-trip
   into invocation flags. Splits on the first `/` only; bare model ids (and
   values whose provider or id half is empty) pass through untouched. An
   explicit --provider that disagrees with the prefix is a hard error rather
   than a silent mismatch, and this runs order-independently after parsing so
   `--model X/Y --provider X` and `--provider X --model X/Y` behave alike."
  (when opts.model
    (let [(prefix bare) (models-mod.split-model-ref opts.model)]
      (when prefix
        (when (and opts.provider-explicit?
                   (not= (tostring opts.provider) prefix))
          (io.stderr:write
            (.. "--provider " (tostring opts.provider)
                " conflicts with --model provider prefix " prefix
                " (from " (tostring opts.model) ")\n"))
          (os.exit 2))
        (set opts.model bare)
        (set opts.provider prefix)
        (set opts.provider-explicit? true))))
  opts)

(fn apply-defaults [opts]
  "Apply persisted default provider/model after CLI parsing. CLI flags win;
   settings.json wins over the built-in openai fallback."
  (let [s (settings.load)]
    (if (not opts.provider)
        (if s.default-provider
            (do (set opts.provider s.default-provider)
                (set opts.provider-from-settings? true))
            (set opts.provider :openai)))
    (when (and (not opts.model)
               s.default-model
               (= (tostring opts.provider) (tostring s.default-provider)))
      (set opts.model s.default-model)
      (set opts.model-from-settings? true))
    (when (and (not opts.thinking)
               (not opts.thinking-budget)
               (not opts.reasoning-effort)
               s.default-thinking)
      (if (thinking.valid-level? s.default-thinking)
          (set opts.thinking s.default-thinking)
          (log.warn (.. "settings: defaultThinking "
                        (tostring s.default-thinking)
                        " is invalid; ignoring"))))
    opts))

(fn run-ext-subcommand [argv]
  (if (and (= (. argv 1) :ext) (= (. argv 2) :build) (. argv 3))
      (do
        (ensure-rocks!)
        (os.exit (rocks.build! (. argv 3))))
      (do
        (io.stderr:write "usage: fen ext build <dir>\n")
        (os.exit 2))))

(fn run-update-subcommand [argv]
  (let [update (require :fen.update)]
    (os.exit (update.run! argv))))

(fn run-provider-help-subcommand [argv]
  (let [help (ensure-provider-help!)
        (output code) (help.dispatch argv)]
    (io.write output)
    (os.exit code)))

(fn argv-has-help? [argv ?start-index]
  (let [help (ensure-cli-help!)]
    (var found? false)
    (for [i (or ?start-index 1) (length argv)]
      (when (help.help? (. argv i))
        (set found? true)))
    found?))

(fn write-subcommand-help-and-exit! [name]
  (let [help (ensure-cli-help!)]
    (help.write-subcommand-help! name)
    (os.exit 0)))

(fn write-top-level-help-and-exit! [?all?]
  (let [help (ensure-cli-help!)]
    (help.write-top-level-help! ?all?)
    (os.exit 0)))

(fn run-discovery-subcommand [argv]
  "Load the ordinary extension registry, then expose it without starting a
   presenter, session, or provider completion."
  (let [verb (. argv 1)
        context verb
        positional []
        flags (ensure-cli-flags!)
        parsed {:extension-paths []}]
    (var i 2)
    (while (<= i (length argv))
      (let [arg (. argv i)
            known-flag (and (option-token? arg) (flags.find-any arg))
            flag (and known-flag (flags.find arg context))]
        (if flag
            (set i (consume-flag! parsed flag argv i))
            known-flag
            (die-usage! (flags.invalid-message known-flag context))
            (option-token? arg)
            (do (io.stderr:write (flags.unknown-message arg context))
                (os.exit 2))
            (do (table.insert positional arg) (set i (+ i 1))))))
    (let [surface (. positional 1)
          name (. positional 2)
          json? parsed.json?
          provider parsed.provider
          extension-paths parsed.extension-paths]
      (when (or (> (length positional) (if (= verb :show) 2 1))
                (and (= verb :show) (or (not surface) (not name))))
        (io.stderr:write "usage: fen list [surface] [--json] [--provider NAME]\n       fen show <surface> <name> [--json] [--provider NAME]\n")
        (os.exit 2))
    (ensure-rocks!)
    (rocks.prepend-tree!)
    (ensure-runtime!)
    ;; Interactive mode is needed only so slash-command/presenter extensions
    ;; register their metadata; no presenter lifecycle is entered.
    (extension-loader.load! {:presenter :tui :extra-skill-paths []
                             :extension-paths extension-paths}
                            {:interactive? true})
    (models-mod.register-providers!)
    (let [discovery (ensure-cli-discovery!)
          opts {:provider provider}]
      (if (= verb :show)
          (let [(entry err) (discovery.show surface name opts)]
            (when (or err (not entry))
              (io.stderr:write (.. (or err (.. "entry not found: " (tostring surface)
                                                " " (tostring name))) "\n"))
              (os.exit 2))
            (io.write (.. (discovery.render {:surface surface :entry entry} json?) "\n")))
          surface
          (let [(items err) (discovery.list surface opts)]
            (when err
              (io.stderr:write (.. err "\n"))
              (os.exit 2))
            (io.write (.. (discovery.render {:surface surface :items items} json?) "\n")))
          (io.write (.. (discovery.render {:surfaces (discovery.surfaces)} json?) "\n")))
      (os.exit 0)))))

(fn provider-for-auth-backend [backend-name]
  "Find the provider wired to backend-name. Prefer an exact name match so
   adoption stays deterministic if several providers share an auth backend."
  (var exact nil)
  (var any nil)
  (each [_ p (ipairs (provider-registry.list))]
    (when (= p.auth-backend backend-name)
      (when (not any) (set any p))
      (when (= p.name backend-name) (set exact p))))
  (or exact any))

(fn adopt-default-after-login! [backend-name]
  "First-boot convenience: after a successful login, if no default provider is
   persisted yet, adopt the just-authenticated provider and its default model so
   the user need not run /model manually. Best-effort — a failure here must
   never mask a successful login."
  (let [p (provider-for-auth-backend backend-name)]
    (when (and p p.default-model)
      (let [(ok? wrote?) (pcall settings.adopt-default-if-unset!
                                p.name p.default-model)]
        (if (not ok?)
            (log.warn (.. "login: could not persist default provider: "
                          (tostring wrote?)))
            wrote?
            (io.write (.. "\nDefault provider set to " (tostring p.name)
                          " (" (tostring p.default-model)
                          "). Run `fen` to start.\n")))))))

(fn run-auth-action! [opts action method-key]
  "Dispatch --login/--logout to the named provider's auth-backend.
   action is the name string the user passed; method-key is :login!
   or :logout!. Returns the exit code."
  (let [backend (auth-backend-registry.find action)]
    (when (not backend)
      (io.stderr:write (.. "unknown auth backend: " (tostring action) "\n"))
      (os.exit 2))
    (let [method (. backend method-key)]
      (when (not method)
        (io.stderr:write (.. "auth backend " (tostring action)
                             " does not support " (tostring method-key) "\n"))
        (os.exit 2))
      (let [(ok? err) (pcall method)]
        (when (not ok?)
          (io.stderr:write (.. (tostring err) "\n"))
          (os.exit 1)))
      (when (= method-key :login!)
        (adopt-default-after-login! action))
      (os.exit 0))))

(fn main [argv]
  (when (= (. argv 1) :ext)
    (run-ext-subcommand argv))
  (when (= (. argv 1) :providers)
    (run-provider-help-subcommand argv))
  (when (or (= (. argv 1) :list) (= (. argv 1) :show))
    (when (argv-has-help? argv 2)
      (write-subcommand-help-and-exit! (. argv 1)))
    (run-discovery-subcommand argv))
  (when (= (. argv 1) :update)
    (run-update-subcommand argv))
  (ensure-rocks!)
  (rocks.prepend-tree!)
  (when (or (= (. argv 1) :run) (= (. argv 1) :eval))
    (let [runner (ensure-script-runner!)]
      (os.exit (if (= (. argv 1) :eval)
                   (runner.eval! argv)
                   (runner.run! argv)))))
  (let [goal-mode? (= (. argv 1) :goal)
        parsed (parse-args argv (if goal-mode? 2 1) goal-mode?)]
    (when parsed.help?
      (if goal-mode?
          (write-subcommand-help-and-exit! :goal)
          (write-top-level-help-and-exit! parsed.help-all?)))
    (when parsed.version? (io.write (.. (version-line) "\n")) (os.exit 0))
    (ensure-runtime!)
    (apply-model-prefix! parsed)
    (let [opts (apply-defaults parsed)]
      ;; Load non-interactive extensions before provider resolution so
      ;; extension-contributed providers/auth backends are selectable at
      ;; startup. Interactive-only extensions (notably TUI) are still loaded
      ;; later by interactive.run!.
      (extension-loader.load! opts {:interactive? false})
      (models-mod.register-providers!)
      ;; --login / --logout are one-shot operations that exit before the
      ;; TUI or any session is opened. They run after extension load so
      ;; the auth-backend registry is populated.
      (when opts.login (run-auth-action! opts opts.login :login!))
      (when opts.logout (run-auth-action! opts opts.logout :logout!))
      ;; Validate config + auth eagerly so misconfiguration fails before we
      ;; spin up the TUI or open a session file. The same call runs again
      ;; inside make-agent-from-opts; resolve-provider-config is cheap and
      ;; idempotent.
      (resolve-provider-config opts)
      (let [exit-code (interactive.run! opts resolve-provider-config)]
        (when (= (type exit-code) :number)
          (os.exit exit-code))))))

(main arg)
