;; Declarative CLI flag catalogue shared by argument parsing and help rendering.
;;
;; Keep this module dependency-free. `fen --help` and focused subcommand help
;; must render before provider/runtime/extension modules are loaded.

(local M {})

(local FLAGS
  [{:name "--provider"
    :arg :value
    :placeholder "NAME"
    :description "Provider (openai, openai-codex, anthropic, sakana, ...)"
    :group :common
    :applies-to [:top :goal :list :show]
    :parse {:action :set-value :dest :provider :mark :provider-explicit?}
    :help {:top-short "Provider (openai, openai-codex, anthropic, sakana, ...)"
           :top-all ["openai | openai-responses | openai-codex |"
                     "anthropic | sakana | <custom from models.json>"
                     "(default: saved setting, else openai)."
                     "openai-codex uses your"
                     "ChatGPT subscription via OAuth — run"
                     "`fen --login openai-codex` once first."]
           :goal "Provider to use (openai, anthropic, sakana, custom, ...)"
           :list "Select the provider used for provider/model discovery"
           :show "Select the provider used for provider/model discovery"}}

   {:name "--model"
    :arg :value
    :placeholder "NAME"
    :description "Model id for the selected provider"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :model :mark :model-explicit?}
    :help {:top-short "Model id for the selected provider"
           :top-all ["Model id (default: saved setting when present;"
                     "otherwise gpt-5.4-nano for openai and"
                     "openai-responses, gpt-5.5 for openai-codex,"
                     "claude-haiku-4-5 for anthropic, fugu-ultra for"
                     "sakana; or the first model declared for a custom"
                     "provider). Accepts PROVIDER/MODEL canonical ids and"
                     "unambiguous substring/fuzzy matches against the"
                     "provider catalog; unknown ids fail fast with"
                     "suggestions."]
           :goal "Model id for the selected provider"}}

   {:name "--system"
    :arg :value
    :placeholder "TEXT"
    :description "System prompt"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :system}
    :help {:top-all "System prompt"}}

   {:name "--system-file"
    :arg :value
    :placeholder "PATH"
    :description "Read the system prompt from PATH"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :read-file :dest :system :read-error "cannot read --system-file"}
    :help {:top-all "Read the system prompt from PATH (overrides --system)"}}

   {:name "--max-iterations"
    :arg :value
    :placeholder "N"
    :description "Goal iteration cap"
    :group :common
    :applies-to [:goal]
    :invalid {:top "--max-iterations is valid only with `fen goal`"}
    :parse {:action :set-value :dest :max-iterations :value-kind :number
            :mark :max-iterations-given?}
    :help {:top-all ["Goal iteration cap (default: 3, maximum: 20)."
                     "Valid only with `fen goal`."]
           :goal "Iteration cap (default: 3, maximum: 20)"}}

   {:name "--max-tokens"
    :arg :value
    :placeholder "N"
    :description "Reply token cap"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :max-tokens :value-kind :number}
    :help {:top-all ["Reply token cap (default: 16384). Reasoning models"
                     "(gpt-5*, o1, o3) charge their thinking against this"
                     "cap, so 1024 leaves nothing for visible output."]
           :goal "Reply token cap (default: 16384)"}}

   {:name "--retries"
    :aliases ["--retry-max-attempts"]
    :arg :value
    :placeholder "N"
    :description "Provider HTTP attempts for transient failures"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :retry-max-attempts :value-kind :number}
    :suggest? false
    :help {:top-all ["Provider HTTP attempts for transient failures"
                     "(default: 4; use 1 to disable)"]
           :goal "Provider HTTP attempts for transient failures"}}

   {:name "--thinking"
    :arg :value
    :placeholder "LEVEL"
    :description "Provider-neutral thinking level"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :thinking}
    :help {:top-short "off | minimal | low | medium | high | xhigh"
           :top-all ["Provider-neutral thinking level: off | minimal | low |"
                     "medium | high | xhigh. Maps to Anthropic budgets or"
                     "OpenAI reasoning effort."]
           :goal "off | minimal | low | medium | high | xhigh"}}

   {:name "--thinking-budget"
    :arg :value
    :placeholder "N"
    :description "Anthropic extended-thinking token budget"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :thinking-budget :value-kind :number}
    :help {:top-all ["Anthropic only: enable extended thinking with N tokens"
                     "(exact override; wins over --thinking)"]
           :goal "Anthropic extended-thinking token budget"}}

   {:name "--reasoning-effort"
    :arg :value
    :placeholder "E"
    :description "OpenAI Responses/Codex effort override"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :reasoning-effort}
    :help {:top-all ["OpenAI Responses / Codex: minimal | low | medium |"
                     "high | xhigh. Exact override; wins over --thinking."
                     "Clamped per-model where the API refuses some values"
                     "(e.g. gpt-5.5 minimal → low)."]
           :goal "OpenAI Responses/Codex effort override"}}

   {:name "--print"
    :arg :value
    :placeholder "TEXT"
    :description "One-shot mode; print final assistant text and exit"
    :group :common
    :applies-to [:top]
    :invalid {:goal "--print cannot be used with `fen goal`"}
    :parse {:action :set-value :dest :print}
    :help {:top-short ["One-shot mode; print final assistant text and exit"
                       "(pass `-` to read the prompt from stdin)"]
           :top-all ["One-shot mode; defaults to the print presenter, prints"
                     "final assistant text, and exits. Pass `-` to read the"
                     "prompt from stdin. Combine with --presenter json for a"
                     "machine-readable result."]}}

   {:name "--prompt-file"
    :arg :value
    :placeholder "PATH"
    :description "Read a one-shot prompt from PATH"
    :group :common
    :applies-to [:top]
    :invalid {:goal "--prompt-file cannot be used with `fen goal`"}
    :parse {:action :set-value :dest :prompt-file}
    :help {:top-short "Read a one-shot prompt from PATH (no shell interpolation)"
           :top-all ["Read a one-shot prompt from PATH (like --print, without"
                     "shell interpolation); cannot be combined with --print."]}}

   {:name "--tools"
    :arg :value
    :placeholder "NAMES"
    :description "Comma-separated hard allowlist of agent tools"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :tools
            :value-must-not-look-like-flag? true
            :missing-message "--tools requires a comma-separated value"}
    :help {:top-short "Comma-separated hard allowlist of agent tools"
           :top-all "Comma-separated hard allowlist of agent tools."
           :goal "Comma-separated hard allowlist of agent tools"}}

   {:name "--no-tools"
    :arg :none
    :description "Disable every agent tool"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-true :dest :no-tools?}
    :help {:top-short "Disable every agent tool"
           :top-all "Disable every agent tool (conflicts with --tools)."
           :goal "Disable every agent tool"}}

   {:name "--presenter"
    :arg :value
    :placeholder "NAME"
    :description "Presenter selection"
    :group :common
    :applies-to [:top]
    :invalid {:goal "--presenter cannot be used with `fen goal`"}
    :parse {:action :set-value :dest :presenter}
    :help {:top-short "tui | stdio | web | print | json (default: tui)"
           :top-all ["Presenter: tui | stdio | web | print | json"
                     "(default: tui). json writes a structured result blob"
                     "(final-text, messages, usage, stop-reason) to"
                     "FEN_JSON_OUTPUT_PATH, or stdout when unset."]}}

   {:name "--session-backend"
    :arg :value
    :placeholder "N"
    :description "Session backend"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :set-value :dest :session-backend}
    :help {:top-all "Session backend (default: jsonl)"
           :goal "Session backend (default: jsonl)"}}

   {:name "--continue"
    :arg :none
    :description "Resume the most recent session for the current cwd"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-true :dest :continue?}
    :help {:top-short "Resume the most recent session for the current cwd"
           :top-all "Resume the most recent session for the current cwd"
           :goal "Resume the most recent session for the current cwd"}}

   {:name "--no-session"
    :arg :none
    :description "Do not write a transcript to disk"
    :group :common
    :applies-to [:top :goal]
    :parse {:action :set-true :dest :no-session?}
    :help {:top-short "Do not write a transcript to disk"
           :top-all "Do not write a transcript to disk"
           :goal "Do not write a transcript to disk"}}

   {:name "--skill"
    :arg :value
    :placeholder "PATH"
    :description "Additional skill file or directory"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :append-value :dest :extra-skill-paths}
    :help {:top-all "Additional skill file or directory (repeatable)"
           :goal "Additional skill file or directory (repeatable)"}}

   {:name "--skills"
    :arg :value
    :placeholder "DIR"
    :description "Backward-compatible alias for --skill"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :append-value :dest :extra-skill-paths}
    :help {:top-all "Backward-compatible alias for --skill DIR"}}

   {:name "--extension"
    :arg :value
    :placeholder "PATH"
    :description "Load an external extension file or directory"
    :group :advanced
    :applies-to [:top :goal :list :show]
    :parse {:action :append-value :dest :extension-paths}
    :help {:top-all ["Load an external extension file or directory"
                     "(repeatable; dir expects init.fnl or init.lua)"]
           :goal "Load an external extension file or directory (repeatable)"
           :list "Load an external extension before discovery (repeatable)"
           :show "Load an external extension before discovery (repeatable)"}}

   {:name "--login"
    :arg :value
    :placeholder "PROVIDER"
    :description "Run a provider's interactive login flow and exit"
    :group :advanced
    :applies-to [:top]
    :parse {:action :set-value :dest :login}
    :help {:top-all ["Run the provider's interactive login flow (e.g."
                     "openai-codex) and exit"]}}

   {:name "--logout"
    :arg :value
    :placeholder "PROVIDER"
    :description "Remove a provider's stored credentials and exit"
    :group :advanced
    :applies-to [:top]
    :parse {:action :set-value :dest :logout}
    :help {:top-all "Remove the provider's stored credentials and exit"}}

   {:name "--version"
    :arg :none
    :description "Print build/source version metadata and exit"
    :group :advanced
    :applies-to [:top]
    :parse {:action :set-true :dest :version?}
    :help {:top-all "Print build/source version metadata and exit"}}

   {:name "--dev-path"
    :suggest? false
    :arg :value
    :placeholder "DIR"
    :description "Single-file launcher module overlay root"
    :group :internal
    :applies-to [:top]
    :parse {:action :append-value :dest :dev-paths}
    :help {:top-all ["Single-file binary only: prepend a Lua module"
                     "root so .fnl/.lua in DIR shadow the embedded"
                     "archive (repeatable). Consumed by the launcher."]}}

   {:name "--extension-root"
    :suggest? false
    :arg :value
    :placeholder "DIR"
    :description "Single-file launcher trusted extension overlay root"
    :group :internal
    :applies-to [:top]
    :parse {:action :append-value :dest :extension-roots}
    :help {:top-all ["Single-file binary only: trusted first-party flat"
                     "extension overlay root (repeatable); consumed by the"
                     "launcher."]}}

   {:name "--all"
    :arg :none
    :description "Merge model catalogs across every available provider"
    :group :common
    :applies-to [:list]
    :parse {:action :set-true :dest :all?}
    :help {:list "Merge model catalogs across every available provider (models only)"}}

   {:name "--check"
    :arg :none
    :description "Explicitly verify provider connectivity"
    :group :common
    :applies-to [:list]
    :parse {:action :set-true :dest :check?}
    :help {:list "Contact each listed provider to verify connectivity (providers only)"}}

   {:name "--json"
    :arg :none
    :description "Emit stable JSON metadata for scripts"
    :group :common
    :applies-to [:list :show]
    :parse {:action :set-true :dest :json?}
    :help {:top-all "Emit stable JSON metadata for discovery subcommands"
           :list "Emit stable JSON metadata for scripts"
           :show "Emit stable JSON metadata for scripts"}}

   {:name "--lua"
    :arg :none
    :description "Run or evaluate input as Lua"
    :group :common
    :applies-to [:run :eval]
    :parse {:action :set-const :dest :language :const :lua}
    :help {:top-all "Run/evaluate input as Lua, overriding inference"
           :run "Run SCRIPT as Lua, overriding extension inference"}}

   {:name "--fennel"
    :arg :none
    :description "Run or evaluate input as Fennel"
    :group :common
    :applies-to [:run :eval]
    :parse {:action :set-const :dest :language :const :fennel}
    :help {:top-all "Run/evaluate input as Fennel, overriding inference"
           :run "Run SCRIPT as Fennel, overriding extension inference"}}

   {:name "--fnl"
    :arg :none
    :description "Alias for --fennel"
    :group :common
    :applies-to [:run :eval]
    :parse {:action :set-const :dest :language :const :fennel}
    :help {:top-all "Alias for --fennel"
           :run "Alias for --fennel"}}

   {:name "--"
    :arg :none
    :description "Stop parsing options"
    :group :common
    :applies-to [:run :eval]
    :flag? false
    :help {:run "Stop parsing fen run options; the next token is SCRIPT"}}

   {:name "--help"
    :aliases ["-h"]
    :display "-h, --help"
    :arg :none
    :description "Show help and exit"
    :group :common
    :applies-to [:top :goal :list :show :run :eval :providers]
    :parse {:action :set-true :dest :help?}
    :help {:top-short "Show this help (use --help-all for the full version)"
           :top-all "Show the short help"
           :goal "Show this help and exit"
           :list "Show this help and exit"
           :show "Show this help and exit"
           :run "Show this help and exit"
           :providers "Show this help and exit"}}

   {:name "--help-all"
    :arg :none
    :description "Show exhaustive help and exit"
    :group :advanced
    :applies-to [:top :goal]
    :parse {:action :help-all}
    :help {:top-all "Show this exhaustive help"}}

   {:name "name"
    :arg :none
    :description "Optional provider setup page to show"
    :group :common
    :applies-to [:providers]
    :flag? false
    :help {:providers "Optional provider setup page to show"}}])

(fn contains? [xs value]
  (var found? false)
  (each [_ x (ipairs (or xs []))]
    (when (= x value)
      (set found? true)))
  found?)

(fn M.all [] FLAGS)

(fn M.applies? [flag context]
  (or (not context)
      (contains? flag.applies-to context)))

(fn flag-name-matches? [flag name]
  (let [needle (tostring name)]
    (or (= needle flag.name)
        (do
          (var matched? false)
          (each [_ alias (ipairs (or flag.aliases []))]
            (when (= needle alias)
              (set matched? true)))
          matched?))))

(fn M.find-any [name]
  (var found nil)
  (each [_ flag (ipairs FLAGS)]
    (when (and (not found) (not= flag.flag? false) (flag-name-matches? flag name))
      (set found flag)))
  found)

(fn M.find [name context]
  (let [flag (M.find-any name)]
    (and flag (M.applies? flag context) flag)))

(fn M.invalid-message [flag context]
  (let [messages flag.invalid]
    (or (and messages (. messages context))
        (.. flag.name " is not valid here"))))

(fn M.label [flag]
  (or flag.display
      (if (= flag.arg :value)
          (.. flag.name " " (tostring (or flag.placeholder "VALUE")))
          flag.name)))

(fn help-lines [flag context]
  (let [help flag.help
        text (and help (. help context))]
    (if (= (type text) :table)
        text
        (and text [text]))))

(fn help-entries [context]
  (let [out []]
    (each [_ flag (ipairs FLAGS)]
      (when (help-lines flag context)
        (table.insert out flag)))
    out))

(fn M.help-entries [context]
  (help-entries context))

(fn max-label-width [entries]
  (var width 0)
  (each [_ flag (ipairs entries)]
    (set width (math.max width (length (M.label flag)))))
  width)

(fn push-option-line [lines flag context width]
  (let [label (M.label flag)
        descriptions (help-lines flag context)
        first-line (. descriptions 1)
        pad (string.rep " " (math.max 1 (+ (- width (length label)) 1)))
        cont-pad (string.rep " " (+ width 1))]
    (table.insert lines (.. "  " label pad first-line))
    (for [i 2 (length descriptions)]
      (table.insert lines (.. "  " cont-pad (. descriptions i))))))

(fn M.render-options [context ?opts]
  (let [entries (help-entries context)
        width (or (and ?opts ?opts.width) (max-label-width entries))
        title (or (and ?opts ?opts.title) "Options:")
        lines [title]]
    (each [_ flag (ipairs entries)]
      (push-option-line lines flag context width))
    (.. (table.concat lines "\n") "\n")))

(fn flag-names [?context]
  (let [names []]
    (each [_ flag (ipairs FLAGS)]
      (when (and (not= flag.flag? false)
                 (not= flag.suggest? false)
                 (or (not ?context) (M.applies? flag ?context)))
        (table.insert names flag.name)
        (each [_ alias (ipairs (or flag.aliases []))]
          (table.insert names alias))))
    names))

(fn all-flag-names []
  (let [names []]
    (each [_ flag (ipairs FLAGS)]
      (when (and (not= flag.flag? false)
                 (not= flag.suggest? false))
        (table.insert names flag.name)
        (each [_ alias (ipairs (or flag.aliases []))]
          (table.insert names alias))))
    names))

(fn levenshtein [a b]
  (let [a (tostring (or a ""))
        b (tostring (or b ""))
        la (length a)
        lb (length b)]
    (if (= la 0)
        lb
        (= lb 0)
        la
        (do
          (var prev {})
          (var cur {})
          (for [j 0 lb]
            (tset prev j j))
          (for [i 1 la]
            (tset cur 0 i)
            (for [j 1 lb]
              (let [cost (if (= (string.sub a i i) (string.sub b j j)) 0 1)
                    deletion (+ (. prev j) 1)
                    insertion (+ (. cur (- j 1)) 1)
                    substitution (+ (. prev (- j 1)) cost)]
                (tset cur j (math.min deletion (math.min insertion substitution)))))
            (set prev cur)
            (set cur {}))
          (. prev lb)))))

(fn nearest [needle names]
  (var best nil)
  (var best-distance nil)
  (each [_ name (ipairs names)]
    (let [distance (levenshtein needle name)]
      (when (or (not best-distance) (< distance best-distance))
        (set best name)
        (set best-distance distance))))
  best)

(fn M.nearest-flag [name ?context]
  (let [names (flag-names ?context)
        all-names (all-flag-names)
        context-match (nearest name names)
        any-match (nearest name all-names)]
    (or context-match any-match)))

(fn M.unknown-message [name ?context]
  (let [suggestion (M.nearest-flag name ?context)]
    (.. "unknown option: " (tostring name)
        (if suggestion (.. "\ndid you mean " suggestion "?") "")
        "\n")))

M
