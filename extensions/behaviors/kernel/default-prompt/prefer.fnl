;; Saving durable user preferences to instruction files.
;;
;; Provides the /prefer command to append preferences to either project-level
;; or user-level instruction files (AGENTS.md / CLAUDE.md) that default-prompt
;; loads, and remembers candidate preferences suggested by decide.

(local path (require :fen.util.path))
(local text (require :fen.util.text))
(local subcommands (require :fen.util.subcommands))

(local M {})

(local state (require :fen.extensions.default_prompt.state))

(fn read-file [file-path]
  (let [(f _err) (io.open file-path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn first-existing-file [dir names]
  (var found nil)
  (each [_ name (ipairs names)]
    (let [candidate (.. dir "/" name)]
      (when (and (not found) (path.file-exists? candidate))
        (set found candidate))))
  found)

;; @doc fen.extensions.default_prompt.prefer.resolve-user-file
;; kind: function
;; signature: (resolve-user-file) -> string
;; summary: Resolve the target instruction file for user-scoped preferences, preferring existing user files.
;; tags: prompt prefer user
(fn M.resolve-user-file []
  (var hit nil)
  (each [_ dir (ipairs [(.. (path.home) "/.pi/agent") (path.config-dir :fen)])
         &until hit]
    (set hit (first-existing-file dir ["AGENTS.md" "CLAUDE.md"])))
  (or hit (.. (path.config-dir :fen) "/AGENTS.md")))

;; @doc fen.extensions.default_prompt.prefer.resolve-project-file
;; kind: function
;; signature: (resolve-project-file ?start-cwd) -> string
;; summary: Resolve the target instruction file for project-scoped preferences, checking ancestors leaf-to-root.
;; tags: prompt prefer project
(fn M.resolve-project-file [?start-cwd]
  (let [start (or ?start-cwd (path.cwd))
        ancestors (path.ancestors-root-to-leaf start)]
    (var hit nil)
    (for [i (length ancestors) 1 -1 &until hit]
      (let [dir (. ancestors i)]
        (set hit (first-existing-file dir ["AGENTS.md" "CLAUDE.md"]))))
    (or hit (.. start "/AGENTS.md"))))

;; @doc fen.extensions.default_prompt.prefer.format-entry
;; kind: function
;; signature: (format-entry existing pref-text) -> string
;; summary: Format markdown content appending pref-text as a bullet under Preferences.
;; tags: prompt prefer format
(fn M.format-entry [existing pref-text]
  (let [trimmed (text.trim (or pref-text ""))
        bullet (if (string.match trimmed "^[%-*]%s+")
                   trimmed
                   (.. "- " trimmed))]
    (if (or (= existing nil) (= existing ""))
        (.. "# Preferences\n\n" bullet "\n")
        (let [needs-leading-nl? (not (string.match existing "\n$"))
              has-heading? (string.match existing "[Pp]references")
              prefix (if needs-leading-nl? "\n" "")]
          (if has-heading?
              (.. existing prefix bullet "\n")
              (.. existing prefix "\n## Preferences\n\n" bullet "\n"))))))

;; @doc fen.extensions.default_prompt.prefer.save-preference!
;; kind: function
;; signature: (save-preference! target-path pref-text) -> (boolean, string)
;; summary: Append a preference bullet to the target markdown file, creating the file or section if absent.
;; tags: prompt prefer storage
(fn M.save-preference! [target-path pref-text]
  (let [dir (path.dirname target-path)]
    (path.ensure-dir! dir)
    (let [existing (read-file target-path)
          new-content (M.format-entry existing pref-text)
          (f err) (io.open target-path :w)]
      (if (not f)
          (values false (.. "cannot write to " target-path ": " (tostring err)))
          (do
            (f:write new-content)
            (f:close)
            (values true target-path))))))

;; @doc fen.extensions.default_prompt.prefer.get-candidate
;; kind: function
;; signature: (get-candidate) -> string|nil
;; summary: Return the pending suggested preference candidate, if any.
;; tags: prompt prefer candidate
(fn M.get-candidate []
  state.candidate-preference)

;; @doc fen.extensions.default_prompt.prefer.set-candidate!
;; kind: function
;; signature: (set-candidate! ?text) -> nil
;; summary: Set or clear the pending suggested preference candidate.
;; tags: prompt prefer candidate
(fn M.set-candidate! [?text]
  (set state.candidate-preference ?text)
  nil)

(fn execute! [scope raw-text api ?get-loader]
  (let [trimmed (when raw-text (text.trim raw-text))
        pref (if (and trimmed (not= trimmed ""))
                 trimmed
                 state.candidate-preference)]
    (if (or (= pref nil) (= pref ""))
        (api.emit {:type :error
                   :error "prefer: specify a preference to save (e.g. /prefer [project|user] <text>)"})
        (let [target (if (= scope :user)
                         (M.resolve-user-file)
                         (M.resolve-project-file (path.cwd)))
              (ok? res) (M.save-preference! target pref)]
          (if (not ok?)
              (api.emit {:type :error :error (.. "prefer: " (tostring res))})
              (do
                (set state.candidate-preference nil)
                (when ?get-loader
                  (let [loader (?get-loader)]
                    (when (and loader loader.reload)
                      (loader:reload))))
                (api.emit {:type :info
                           :text (.. "saved preference to " target)})))))))

;; @doc fen.extensions.default_prompt.prefer.register!
;; kind: function
;; signature: (register! api ?get-loader) -> true
;; summary: Register the /prefer command, observe :hint suggestions, and clear stale candidates.
;; tags: prompt prefer command register
(fn M.register! [api ?get-loader]
  (api.on :hint
          (fn [ev]
            (when (and (= ev.text "save as preference? · /prefer")
                       ev.preference)
              (set state.candidate-preference ev.preference))))
  (api.on :user (fn [ev]
                  (when (not (string.find (or (?. ev :text) "") "^/prefer"))
                    (set state.candidate-preference nil))))
  (api.on :reset-conversation
          (fn [_ev]
            (set state.candidate-preference nil)))
  (let [sub (subcommands.build {:name :prefer
                                :emit api.emit
                                :summary "Save a durable user preference to project or user instructions"
                                :usage "/prefer [project|user] <preference>"
                                :default-takes-args? true
                                :default (fn [args _state]
                                           (execute! :project args api
                                                     ?get-loader))
                                :subcommands {:project {:description "append preference to project AGENTS.md/CLAUDE.md"
                                                        :handler (fn [args
                                                                      _state]
                                                                   (execute! :project
                                                                             args
                                                                             api
                                                                             ?get-loader))}
                                              :user {:description "append preference to user AGENTS.md/CLAUDE.md"
                                                     :handler (fn [args _state]
                                                                (execute! :user
                                                                          args
                                                                          api
                                                                          ?get-loader))}
                                              :global {:description "alias for user scope"
                                                       :handler (fn [args
                                                                     _state]
                                                                  (execute! :user
                                                                            args
                                                                            api
                                                                            ?get-loader))}}})]
    (api.register :command {:name :prefer
                            :description "Save a durable user preference: /prefer [project|user] <text>"
                            :usage sub.usage
                            :subcommands sub.descriptor
                            :handler sub.handler
                            :complete sub.complete}))
  true)

(set M.register M.register!)

M
