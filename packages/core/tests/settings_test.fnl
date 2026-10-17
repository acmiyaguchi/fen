(local h (require :fen.testing))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)
(local read-file h.read-file)

(describe "core.settings"
          (fn []
            (var tmp nil)
            (var settings nil)
            (before_each (fn []
                           (set tmp (make-tmpdir))
                           (h.stub-getenv! (fn [name orig]
                                             (if (= name :XDG_CONFIG_HOME) tmp
                                                 (= name :HOME) tmp
                                                 (orig name))))
                           (set settings (h.reload-module :fen.core.settings))))
            (after_each (fn []
                          (h.restore-getenv!)
                          (when tmp (rmtree tmp))))
            (it "returns an empty normalized record when settings.json is missing"
                (fn []
                  (let [out (settings.load)]
                    (assert.is_table out)
                    (assert.is_nil out.default-provider)
                    (assert.is_nil out.default-model)
                    (assert.is_nil out.default-thinking))))
            (it "returns an empty normalized record for malformed JSON"
                (fn []
                  (write-file (.. tmp "/fen/settings.json") "{not valid json")
                  (let [out (settings.load)]
                    (assert.is_table out)
                    (assert.is_nil out.default-provider)
                    (assert.is_nil out.default-model)
                    (assert.is_nil out.default-thinking))))
            (it "inherits defaults and recursively overlays mutable objects"
                (fn []
                  (write-file (.. tmp "/fen/defaults.json")
                              "{\"defaultProvider\":\"openai\",\"defaultThinking\":\"high\",\"extensions\":{\"decide\":{\"enabled\":true,\"nested\":{\"a\":1,\"b\":2},\"items\":[1,2],\"flag\":true}}}")
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultThinking\":\"low\",\"extensions\":{\"decide\":{\"enabled\":false,\"nested\":{\"a\":3},\"items\":[],\"flag\":false}}}")
                  (let [out (settings.load)]
                    (assert.are.equal :openai out.default-provider)
                    (assert.are.equal :low out.default-thinking)
                    (assert.is_false out.extensions.decide.enabled)
                    (assert.are.same {:nested {:a 3 :b 2}
                                      :items []
                                      :flag false}
                                     (settings.extension :decide)))))
            (it "replaces arrays and object/scalar type changes wholesale"
                (fn []
                  (write-file (.. tmp "/fen/defaults.json")
                              "{\"pinnedTools\":[\"read\",\"edit\"],\"extensions\":{\"decide\":{\"items\":[1,2],\"scalar\":{\"x\":1},\"object\":false,\"nullable\":{\"x\":1}}}}")
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"pinnedTools\":[],\"extensions\":{\"decide\":{\"items\":[3],\"scalar\":false,\"object\":{\"x\":2},\"nullable\":null}}}")
                  (let [out (settings.load)
                        json (require :fen.util.json)]
                    (assert.are.same [] out.pinned-tools)
                    (assert.are.same [3] out.extensions.decide.items)
                    (assert.is_false out.extensions.decide.scalar)
                    (assert.are.same {:x 2} out.extensions.decide.object)
                    (assert.is_true (json.null? out.extensions.decide.nullable)))))
            (it "reads defaults without mutable settings and tolerates either malformed file"
                (fn []
                  (write-file (.. tmp "/fen/defaults.json")
                              "{\"defaultProvider\":\"anthropic\"}")
                  (assert.are.equal :anthropic
                                    (. (settings.load) :default-provider))
                  (write-file (.. tmp "/fen/settings.json") "{broken")
                  (assert.are.equal :anthropic
                                    (. (settings.load) :default-provider))
                  (write-file (.. tmp "/fen/defaults.json") "{broken")
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultProvider\":\"openai\"}")
                  (assert.are.equal :openai
                                    (. (settings.load) :default-provider))))
            (it "never materializes inherited keys through any settings writer"
                (fn []
                  (let [json (require :fen.util.json)
                        defaults "{\"defaultProvider\":\"anthropic\",\"defaultModel\":\"inherited\",\"defaultThinking\":\"high\",\"pinnedTools\":[],\"extensions\":{\"decide\":{\"enabled\":true,\"model\":\"inherited\"}},\"unknown\":42}"]
                    (write-file (.. tmp "/fen/defaults.json") defaults)
                    (assert.is_false (settings.adopt-default-if-unset! :openai
                                                                       :new))
                    (assert.is_nil (read-file (.. tmp "/fen/settings.json")))
                    (settings.set-extension-enabled! :decide false)
                    (assert.are.same {:extensions {:decide {:enabled false}}}
                                     (json.decode (read-file (.. tmp
                                                                 "/fen/settings.json"))))
                    (settings.set-thinking-default! :low)
                    (settings.set-defaults! :openai :saved)
                    (assert.are.same {:extensions {:decide {:enabled false}}
                                      :defaultThinking :low
                                      :defaultProvider :openai
                                      :defaultModel :saved}
                                     (json.decode (read-file (.. tmp
                                                                 "/fen/settings.json"))))
                    (assert.are.equal defaults
                                      (read-file (.. tmp "/fen/defaults.json")))
                    ;; Removing mutable keys restores inheritance on the next read.
                    (write-file (.. tmp "/fen/settings.json") "{}")
                    (assert.are.equal :anthropic
                                      (. (settings.load) :default-provider))
                    (assert.is_true (. (settings.load) :extensions :decide
                                       :enabled)))))
            (it "normalizes pi-mono-compatible camelCase keys"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultProvider\":\"openai-codex\",\"defaultModel\":\"gpt-5.5\",\"defaultThinking\":\"high\"}")
                  (let [out (settings.load)]
                    (assert.are.equal "openai-codex" out.default-provider)
                    (assert.are.equal "gpt-5.5" out.default-model)
                    (assert.are.equal "high" out.default-thinking))))
            (it "normalizes defaultWebSearch verbatim for the CLI to validate"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultWebSearch\":\"cached\"}")
                  (assert.are.equal "cached"
                                    (. (settings.load) :default-web-search))
                  (write-file (.. tmp "/fen/settings.json") "{}")
                  (assert.is_nil (. (settings.load) :default-web-search))))
            (it "writes default provider/model atomically and can read them back"
                (fn []
                  (settings.set-defaults! :openai-codex :gpt-5.5)
                  (assert.is_nil (read-file (.. tmp "/fen/settings.json.tmp")))
                  (let [out (settings.load)]
                    (assert.are.equal :openai-codex out.default-provider)
                    (assert.are.equal :gpt-5.5 out.default-model))))
            (it "adopts provider/model as the default when nothing is selected yet"
                (fn []
                  (assert.is_true (settings.adopt-default-if-unset! :openai-codex
                                                                    :gpt-5.5))
                  (let [out (settings.load)]
                    (assert.are.equal :openai-codex out.default-provider)
                    (assert.are.equal :gpt-5.5 out.default-model))))
            (it "leaves an existing default provider untouched on adoption"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultProvider\":\"anthropic\",\"defaultModel\":\"claude-haiku-4-5\"}")
                  (assert.is_false (settings.adopt-default-if-unset! :openai-codex
                                                                     :gpt-5.5))
                  (let [out (settings.load)]
                    (assert.are.equal "anthropic" out.default-provider)
                    (assert.are.equal "claude-haiku-4-5" out.default-model))))
            (it "writes default thinking atomically and can read it back"
                (fn []
                  (settings.set-thinking-default! :high)
                  (assert.is_nil (read-file (.. tmp "/fen/settings.json.tmp")))
                  (let [out (settings.load)]
                    (assert.are.equal :high out.default-thinking))))
            (it "preserves unknown top-level keys when saving defaults"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"theme\":\"dark\",\"defaultProvider\":\"openai\"}")
                  (settings.set-defaults! :anthropic :claude-sonnet-4-6)
                  (let [raw (read-file (.. tmp "/fen/settings.json"))]
                    (assert.is_truthy (string.find raw "\"theme\":\"dark\"" 1
                                                   true)))
                  (let [out (settings.load)]
                    (assert.are.equal :anthropic out.default-provider)
                    (assert.are.equal :claude-sonnet-4-6 out.default-model))))
            (it "preserves provider/model when saving default thinking"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-5.5\"}")
                  (settings.set-thinking-default! :medium)
                  (let [out (settings.load)]
                    (assert.are.equal "openai" out.default-provider)
                    (assert.are.equal "gpt-5.5" out.default-model)
                    (assert.are.equal :medium out.default-thinking))))
            (it "returns nil pinned-tools when the key is absent"
                (fn []
                  (assert.is_nil (. (settings.load) :pinned-tools))))
            (it "parses and de-duplicates pinnedTools into an array"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"pinnedTools\":[\"todo_write\",\"subagent\",\"todo_write\"]}")
                  (assert.are.same ["todo_write" "subagent"]
                                   (. (settings.load) :pinned-tools))))
            (it "preserves an explicit empty pinnedTools array (disables pinning)"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"pinnedTools\":[]}")
                  (assert.are.same [] (. (settings.load) :pinned-tools))))
            (it "ignores non-string pinnedTools entries"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"pinnedTools\":[\"todo_write\",5,\"\"]}")
                  (assert.are.same ["todo_write"]
                                   (. (settings.load) :pinned-tools))))
            (it "preserves the extensions key when saving defaults"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"extensions\":{\"decide\":{\"enabled\":true,\"model\":\"m1\"}}}")
                  (settings.set-defaults! :anthropic :claude-sonnet-4-6)
                  (assert.are.same {:decide {:enabled true :model "m1"}}
                                   (. (settings.load) :extensions))))
            (it "returns one extension's settings without the enabled flag"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"extensions\":{\"decide\":{\"enabled\":true,\"model\":\"m1\",\"timeout\":30},\"other\":{\"x\":1},\"bad\":5}}")
                  (assert.are.same {:model "m1" :timeout 30}
                                   (settings.extension :decide))
                  (assert.are.same {} (settings.extension :bad))
                  (assert.are.same {} (settings.extension :missing))
                  (assert.is_nil (. (settings.load) :extensions :bad))))
            (it "persists an extension enabled flag without clobbering other keys"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"theme\":\"dark\",\"defaultModel\":\"gpt-5.5\",\"extensions\":{\"decide\":{\"model\":\"m1\"},\"other\":{\"enabled\":true}}}")
                  (settings.set-extension-enabled! :decide false)
                  (settings.set-extension-enabled! :fresh true)
                  (let [out (settings.load)
                        raw (read-file (.. tmp "/fen/settings.json"))]
                    (assert.is_truthy (string.find raw "\"theme\":\"dark\"" 1
                                                   true))
                    (assert.are.equal "gpt-5.5" out.default-model)
                    (assert.are.same {:decide {:enabled false :model "m1"}
                                      :other {:enabled true}
                                      :fresh {:enabled true}}
                                     out.extensions))))
            (it "replaces a malformed extensions value when persisting a flag"
                (fn []
                  (write-file (.. tmp "/fen/settings.json")
                              "{\"extensions\":[]}")
                  (settings.set-extension-enabled! :decide true)
                  (assert.are.same {:decide {:enabled true}}
                                   (. (settings.load) :extensions))))))
