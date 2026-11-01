(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local prefer (require :fen.extensions.default_prompt.prefer))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(fn read-file [path]
  (let [(f _err) (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn find-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (and (not found) (= ev.type type-key))
      (set found ev)))
  found)

(describe "default_prompt.prefer"
          (fn []
            (var tmp nil)
            (var api nil)
            (var seen nil)
            (var reloaded? false)
            (local mock-loader {:reload (fn [self] (set reloaded? true) self)})
            (before_each (fn []
                           (set tmp (make-tmpdir))
                           (set reloaded? false)
                           (h.stub-getenv! (fn [name orig]
                                             (if (= name :HOME) tmp
                                                 (= name :XDG_CONFIG_HOME)
                                                 (.. tmp "/.config")
                                                 (= name :PWD)
                                                 (.. tmp "/repo/sub")
                                                 (orig name))))
                           (test-api.reset!)
                           (set seen [])
                           (events.on :* (fn [ev] (table.insert seen ev))
                                      :prefer-test)
                           (set api (test-api.make-runtime-api :default_prompt))
                           (prefer.set-candidate! nil)
                           (prefer.register! api (fn [] mock-loader))))
            (after_each (fn []
                          (h.restore-getenv!)
                          (when tmp (rmtree tmp))
                          (test-api.reset!)))
            (describe "target file resolution"
                      (fn []
                        (it "resolves user file preferring existing AGENTS/CLAUDE in ~/.pi/agent or ~/.config/fen"
                            (fn []
                              ;; Default when none exist
                              (assert.are.equal (.. tmp
                                                    "/.config/fen/AGENTS.md")
                                                (prefer.resolve-user-file))
                              ;; When ~/.config/fen/CLAUDE.md exists
                              (write-file (.. tmp "/.config/fen/CLAUDE.md")
                                          "# Global Claude")
                              (assert.are.equal (.. tmp
                                                    "/.config/fen/CLAUDE.md")
                                                (prefer.resolve-user-file))
                              ;; When ~/.pi/agent/AGENTS.md exists (checked before config dir)
                              (write-file (.. tmp "/.pi/agent/AGENTS.md")
                                          "# Pi Agents")
                              (assert.are.equal (.. tmp "/.pi/agent/AGENTS.md")
                                                (prefer.resolve-user-file))))
                        (it "resolves project file checking cwd and ancestors leaf-to-root"
                            (fn []
                              (let [cwd (.. tmp "/repo/sub")]
                                ;; Default when none exist
                                (assert.are.equal (.. cwd "/AGENTS.md")
                                                  (prefer.resolve-project-file cwd))
                                ;; Ancestor repo has CLAUDE.md
                                (write-file (.. tmp "/repo/CLAUDE.md")
                                            "# Repo Claude")
                                (assert.are.equal (.. tmp "/repo/CLAUDE.md")
                                                  (prefer.resolve-project-file cwd))
                                ;; Cwd sub has AGENTS.md (leaf wins over ancestor)
                                (write-file (.. cwd "/AGENTS.md")
                                            "# Sub Agents")
                                (assert.are.equal (.. cwd "/AGENTS.md")
                                                  (prefer.resolve-project-file cwd)))))))
            (describe "formatting and file storage"
                      (fn []
                        (it "keeps the pending candidate across a reload of the prefer module"
                            (fn []
                              (prefer.set-candidate! "use tabs")
                              (let [reloaded (h.reload-module :fen.extensions.default_prompt.prefer)]
                                (assert.are.equal "use tabs"
                                                  (reloaded.get-candidate))
                                (reloaded.set-candidate! nil))))
                        (it "formats new file content with # Preferences header"
                            (fn []
                              (let [formatted (prefer.format-entry nil
                                                                   "always use pytest")]
                                (assert.are.equal "# Preferences\n\n- always use pytest\n"
                                                  formatted))))
                        (it "appends bullet under existing Preferences section without repeating header"
                            (fn []
                              (let [existing "# Preferences\n\n- first preference\n"
                                    formatted (prefer.format-entry existing
                                                                   "second preference")]
                                (assert.are.equal "# Preferences\n\n- first preference\n- second preference\n"
                                                  formatted))))
                        (it "appends ## Preferences section when file has existing content without preferences"
                            (fn []
                              (let [existing "# My Project\n\nProject instructions.\n"
                                    formatted (prefer.format-entry existing
                                                                   "always format code")]
                                (assert.are.equal "# My Project\n\nProject instructions.\n\n## Preferences\n\n- always format code\n"
                                                  formatted))))
                        (it "preserves pre-existing bullet markers and handles missing trailing newline"
                            (fn []
                              (let [existing "# Preferences\n\n- first"
                                    formatted (prefer.format-entry existing
                                                                   "- second")]
                                (assert.are.equal "# Preferences\n\n- first\n- second\n"
                                                  formatted))))
                        (it "creates directories and file when writing preference"
                            (fn []
                              (let [target (.. tmp "/newdir/AGENTS.md")
                                    (ok? res) (prefer.save-preference! target
                                                                       "never use unwrap()")]
                                (assert.is_true ok?)
                                (assert.are.equal target res)
                                (assert.are.equal "# Preferences\n\n- never use unwrap()\n"
                                                  (read-file target)))))
                        (it "returns error on unwritable target path"
                            (fn []
                              ;; Using an illegal path that cannot be written (a file used as parent dir)
                              (let [blocker (.. tmp "/blocker")
                                    _ (write-file blocker "not a directory")
                                    (ok? err) (prefer.save-preference! (.. blocker
                                                                           "/sub/AGENTS.md")
                                                                       "preference")]
                                (assert.is_false ok?)
                                (assert.is_truthy (string.find (tostring err)
                                                               "cannot write to"
                                                               1 true)))))))
            (describe "/prefer command dispatch"
                      (fn []
                        (it "appends to project file by default, triggers loader reload, and emits info"
                            (fn []
                              (let [target (.. tmp "/repo/sub/AGENTS.md")]
                                (command-registry.dispatch "/prefer always use pytest"
                                                           {})
                                (assert.is_true reloaded?)
                                (assert.are.equal "# Preferences\n\n- always use pytest\n"
                                                  (read-file target))
                                (let [ev (find-event seen :info)]
                                  (assert.is_not_nil ev)
                                  (assert.is_truthy (string.find ev.text
                                                                 "saved preference to"
                                                                 1 true))
                                  (assert.is_truthy (string.find ev.text target
                                                                 1 true))))))
                        (it "supports explicit project and user scopes"
                            (fn []
                              (let [proj-target (.. tmp "/repo/sub/AGENTS.md")
                                    user-target (.. tmp
                                                    "/.config/fen/AGENTS.md")]
                                (command-registry.dispatch "/prefer project use 2 spaces"
                                                           {})
                                (assert.are.equal "# Preferences\n\n- use 2 spaces\n"
                                                  (read-file proj-target))
                                (command-registry.dispatch "/prefer user never commit secrets"
                                                           {})
                                (assert.are.equal "# Preferences\n\n- never commit secrets\n"
                                                  (read-file user-target))
                                (command-registry.dispatch "/prefer global prefer fnlfmt"
                                                           {})
                                (assert.are.equal "# Preferences\n\n- never commit secrets\n- prefer fnlfmt\n"
                                                  (read-file user-target))))))
                      (describe "error handling"
                                (fn []
                                  (it "emits error when invoked with no text and no candidate"
                                      (fn []
                                        (command-registry.dispatch "/prefer" {})
                                        (let [ev (find-event seen :error)]
                                          (assert.is_not_nil ev)
                                          (assert.is_truthy (string.find ev.error
                                                                         "specify a preference"
                                                                         1 true)))))
                                  (it "emits error when scope given with no text and no candidate"
                                      (fn []
                                        (command-registry.dispatch "/prefer user"
                                                                   {})
                                        (let [ev (find-event seen :error)]
                                          (assert.is_not_nil ev)
                                          (assert.is_truthy (string.find ev.error
                                                                         "specify a preference"
                                                                         1 true)))))))
                      (describe "candidate suggestions from :hint"
                                (fn []
                                  (it "saves candidate on bare /prefer after hint suggestion"
                                      (fn []
                                        (api.emit {:type :hint
                                                   :text "save as preference? · /prefer"
                                                   :key "prefer:test"
                                                   :preference "always write tests in busted"})
                                        (assert.are.equal "always write tests in busted"
                                                          (prefer.get-candidate))
                                        (command-registry.dispatch "/prefer" {})
                                        (assert.is_nil (prefer.get-candidate))
                                        (assert.is_true reloaded?)
                                        (let [target (.. tmp
                                                         "/repo/sub/AGENTS.md")]
                                          (assert.are.equal "# Preferences\n\n- always write tests in busted\n"
                                                            (read-file target)))))
                                  (it "saves candidate with user scope via /prefer user"
                                      (fn []
                                        (api.emit {:type :hint
                                                   :text "save as preference? · /prefer"
                                                   :key "prefer:test"
                                                   :preference "prefer dark mode"})
                                        (command-registry.dispatch "/prefer user"
                                                                   {})
                                        (let [target (.. tmp
                                                         "/.config/fen/AGENTS.md")]
                                          (assert.are.equal "# Preferences\n\n- prefer dark mode\n"
                                                            (read-file target)))))
                                  (it "clears candidate on non-prefer user message or reset"
                                      (fn []
                                        (api.emit {:type :hint
                                                   :text "save as preference? · /prefer"
                                                   :key "prefer:test"
                                                   :preference "candidate preference"})
                                        (assert.are.equal "candidate preference"
                                                          (prefer.get-candidate))
                                        ;; A /prefer command does not clear candidate before execution
                                        (api.emit {:type :user :text "/prefer"})
                                        (assert.are.equal "candidate preference"
                                                          (prefer.get-candidate))
                                        ;; Other user prompt clears it
                                        (api.emit {:type :user
                                                   :text "regular prompt"})
                                        (assert.is_nil (prefer.get-candidate))
                                        ;; Reset clears it
                                        (prefer.set-candidate! "another candidate")
                                        (api.emit {:type :reset-conversation})
                                        (assert.is_nil (prefer.get-candidate)))))))))
