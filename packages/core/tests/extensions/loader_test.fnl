;; Tests for external extension loader (issue #15 Step 5).

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local register-registry (require :fen.core.extensions.register))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local hook-registry (require :fen.core.extensions.register.hook))
(local prompt-registry (require :fen.core.extensions.register.prompt))
(local presenter-registry (require :fen.core.extensions.register.presenter))
(local provider-registry (require :fen.core.extensions.register.provider))
(local auth-backend-registry (require :fen.core.extensions.register.auth_backend))
(local session-backend-registry (require :fen.core.extensions.register.session_backend))
(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})
(local extensions
  {:reset! test-api.reset!
   :emit events.emit
   :on events.on
   :register register-registry.register
   :unregister-by-owner register-registry.unregister-by-owner
   :list register-registry.list
   :dispatch-command command-registry.dispatch
   :merged-tools tool-registry.merged
   :run-before-tool hook-registry.run-before-tool
   :prompt (fn [text-or-fn ?opts owner]
             (prompt-registry.contribute text-or-fn ?opts owner handle-result))
   :render-prompt prompt-registry.render
   :active-presenter presenter-registry.active-presenter
   :init-active-presenter presenter-registry.init-active-presenter
   :run-active-presenter presenter-registry.run-active-presenter
   :shutdown-active-presenter presenter-registry.shutdown-active-presenter
   :find-provider provider-registry.find
   :find-auth-backend auth-backend-registry.find
   :find-session-backend session-backend-registry.find
   :set-active-session-backend! session-backend-registry.set-active!
   :active-session-backend session-backend-registry.active
   :set-session-info! session-backend-registry.set-info!
   :session-info session-backend-registry.info})
(local ext-api (require :fen.core.extensions.test_api))
(local system-prompt (require :fen.core.prompt))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(fn command [name]
  (var found nil)
  (each [_ cmd (ipairs (extensions.list :commands))]
    (when (= cmd.name name)
      (set found cmd)))
  found)

(fn command-description [name]
  (?. (command name) :description))

(describe "extensions loader"
  (fn []
    (var tmp nil)
    (var project-pwd nil)
    (var loader nil)

    (fn clear-tui-modules! []
      ;; Keep tests independent: built-in extension loading uses normal Lua
      ;; module caching, so clear both the entry and its behavior modules.
      (each [_ mod (ipairs [:fen.extensions.default_prompt
                            :fen.extensions.default_prompt.manifest
                            :fen.extensions.provider_openai
                            :fen.extensions.provider_openai.manifest
                            :fen.extensions.provider_anthropic
                            :fen.extensions.provider_anthropic.manifest
                            :fen.extensions.skills
                            :fen.extensions.skills.ignore
                            :fen.extensions.skills.manifest
                            :fen.extensions.builtin_tools
                            :fen.extensions.builtin_tools.manifest
                            :fen.extensions.essentials
                            :fen.extensions.essentials.manifest
                            :fen.extensions.sessions
                            :fen.extensions.sessions.manifest
                            :fen.extensions.status
                            :fen.extensions.status.manifest
                            :fen.extensions.queue
                            :fen.extensions.queue.manifest
                            :fen.extensions.prompt
                            :fen.extensions.prompt.manifest
                            :fen.extensions.extensions_inspector
                            :fen.extensions.extensions_inspector.manifest
                            :fen.extensions.docs
                            :fen.extensions.docs.manifest
                            :fen.extensions.docs.state
                            :fen.extensions.handoff
                            :fen.extensions.handoff.manifest
                            :fen.extensions.agent_state
                            :fen.extensions.agent_state.tool
                            :fen.extensions.agent_state.manifest
                            :fen.extensions.mem
                            :fen.extensions.mem.manifest
                            :fen.extensions.mem.state
                            :fen.extensions.plan
                            :fen.extensions.plan.manifest
                            :fen.extensions.plan.state
                            :fen.extensions.todo
                            :fen.extensions.todo.manifest
                            :fen.extensions.todo.state
                            :fen.extensions.tui
                            :fen.extensions.tui.manifest
                            :fen.extensions.tui.markdown
                            :fen.extensions.tui.paint
                            :fen.extensions.tui.input])]
        (tset package.loaded mod nil)
        (tset package.preload mod nil))
      (tset package.loaded :termbox2 nil))

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (set project-pwd nil)
        (extensions.reset!)
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :FEN_EXTENSIONS_PATH) nil
                (= name :FEN_FIRST_PARTY_EXTENSIONS_PATH) nil
                (= name :HOME) tmp
                (= name :PWD) (or project-pwd (orig name))
                (orig name))))
        (set loader (h.reload-module :fen.core.extensions.loader))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (extensions.reset!)
        (clear-tui-modules!)
        (when tmp (rmtree tmp))))

    (it "loads always-on built-ins but skips interactive-only built-ins in non-interactive mode"
      (fn []
        (loader.load! {:extension-paths []} {:interactive? false})
        (let [items (extensions.list :extensions)
              by-name {}
              tools (extensions.merged-tools [])
              tool-names {}]
          (each [_ item (ipairs items)]
            (tset by-name item.name item))
          (each [_ t (ipairs tools)]
            (tset tool-names t.name true))
          (assert.are.equal 23 (length items))
          (assert.are.equal :loaded (. by-name :default_prompt :status))
          (assert.are.equal :loaded (. by-name :skills :status))
          (assert.are.equal :loaded (. by-name :builtin_tools :status))
          (assert.are.equal :loaded (. by-name :essentials :status))
          (assert.are.equal :loaded (. by-name :sessions :status))
          (assert.are.equal :loaded (. by-name :status :status))
          (assert.are.equal :loaded (. by-name :queue :status))
          (assert.are.equal :loaded (. by-name :prompt :status))
          (assert.are.equal :loaded (. by-name :extensions_inspector :status))
          (assert.are.equal :loaded (. by-name :docs :status))
          (assert.are.equal :loaded (. by-name :handoff :status))
          (assert.are.equal :loaded (. by-name :agent_state :status))
          (assert.are.equal :loaded (. by-name :mem :status))
          (assert.are.equal :loaded (. by-name :plan :status))
          (assert.are.equal :loaded (. by-name :todo :status))
          (assert.are.equal :loaded (. by-name :session_jsonl :status))
          (assert.are.equal 11 (length tools))
          (assert.is_true (. tool-names :bash))
          (assert.is_true (. tool-names :agent_state))
          (assert.is_true (. tool-names :todo_write))
          (assert.is_nil (extensions.active-presenter)))))

    (it "includes first-party extension tools in prompt inputs"
      (fn []
        (loader.load! {:extension-paths []} {:interactive? false})
        (let [all-tools (extensions.merged-tools [])
              text (system-prompt.build {:system "body" :current-date "2026-04-28"}
                                        all-tools)]
          (assert.is_truthy (string.find text "- agent_state: Inspect read-only agent state" 1 true))
          (assert.is_truthy (string.find text "- todo_write: Update the structured todo list" 1 true))
          (assert.is_truthy (string.find text "Use agent_state" 1 true))
          (assert.is_truthy (string.find text "Use the todo_write tool" 1 true)))))

    (it "records first-party built-in extensions"
      (fn []
        ;; Loading the real TUI extension requires the vendored termbox2
        ;; binding. Tests only need registration side effects, so stub the
        ;; tiny surface required at module load time.
        (tset package.loaded :termbox2
              {:DEFAULT 0 :CYAN 6 :GREEN 2 :RED 1 :YELLOW 3 :WHITE 7
               :MAGENTA 5 :BOLD 1 :DIM 2 :REVERSE 4 :UNDERLINE 8
               :ITALIC 16 :STRIKEOUT 32
               :KEY_ENTER 13 :KEY_CTRL_C 3 :KEY_CTRL_D 4
               :KEY_CTRL_J 10 :KEY_CTRL_O 15 :KEY_CTRL_T 20
               :KEY_CTRL_A 1 :KEY_CTRL_E 5 :KEY_CTRL_B 2 :KEY_CTRL_F 6
               :KEY_CTRL_P 16 :KEY_CTRL_N 14 :KEY_CTRL_W 23 :KEY_CTRL_U 21
               :KEY_BACKSPACE 8 :KEY_BACKSPACE2 127
               :KEY_HOME 1 :KEY_END 6
               :KEY_ARROW_LEFT 0 :KEY_ARROW_RIGHT 0
               :KEY_ARROW_UP 0 :KEY_ARROW_DOWN 0
               :KEY_PGUP 0 :KEY_PGDN 0
               :KEY_MOUSE_WHEEL_UP 0 :KEY_MOUSE_WHEEL_DOWN 0
               :KEY_SPACE 32 :MOD_ALT 0
               :EVENT_KEY 1 :EVENT_RESIZE 2 :EVENT_MOUSE 3
               :OUTPUT_NORMAL 1 :INPUT_ALT 1 :INPUT_MOUSE 2
               :ERR_NO_EVENT 0
               :init (fn [] 0)
               :shutdown (fn [] nil)
               :width (fn [] 80)
               :height (fn [] 24)
               :set_input_mode (fn [_] nil)
               :set_output_mode (fn [_] nil)
               :set_cell (fn [] nil)
               :set_cursor (fn [] nil)
               :hide_cursor (fn [] nil)
               :print (fn [] nil)
               :clear (fn [] nil)
               :present (fn [] nil)
               :peek_event (fn [] nil)})
        (loader.load! {:extension-paths []} {:interactive? true})
        (tset package.loaded :termbox2 nil)
        (let [items (extensions.list :extensions)]
          (assert.are.equal 24 (length items))
          (let [by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :loaded (. by-name :builtin_tools :status))
            (assert.is_true (. by-name :builtin_tools :first-party?))
            (assert.are.equal :loaded (. by-name :essentials :status))
            (assert.is_true (. by-name :essentials :first-party?))
            (assert.are.equal :loaded (. by-name :sessions :status))
            (assert.is_true (. by-name :sessions :first-party?))
            (assert.are.equal :loaded (. by-name :status :status))
            (assert.is_true (. by-name :status :first-party?))
            (assert.are.equal :loaded (. by-name :queue :status))
            (assert.is_true (. by-name :queue :first-party?))
            (assert.are.equal :loaded (. by-name :steering :status))
            (assert.is_true (. by-name :steering :first-party?))
            (assert.are.equal :loaded (. by-name :prompt :status))
            (assert.is_true (. by-name :prompt :first-party?))
            (assert.are.equal :loaded (. by-name :extensions_inspector :status))
            (assert.is_true (. by-name :extensions_inspector :first-party?))
            (assert.are.equal :loaded (. by-name :docs :status))
            (assert.is_true (. by-name :docs :first-party?))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.is_true (. by-name :agent_state :first-party?))
            (assert.are.equal :loaded (. by-name :mem :status))
            (assert.is_true (. by-name :mem :first-party?))
            (assert.are.equal :loaded (. by-name :plan :status))
            (assert.is_true (. by-name :plan :first-party?))
            (assert.are.equal :loaded (. by-name :todo :status))
            (assert.is_true (. by-name :todo :first-party?))
            (assert.are.equal :loaded (. by-name :session_jsonl :status))
            (assert.is_true (. by-name :session_jsonl :first-party?))
            (assert.are.equal :loaded (. by-name :tui :status))
            (assert.is_true (. by-name :tui :first-party?)))
          (assert.is_not_nil (extensions.active-presenter)))))

    (it "fails fast and cleans partial first-party extension load failures"
      (fn []
        (clear-tui-modules!)
        ;; Force a module-load error after a partial side-effect registration.
        ;; The loader should record the real error, remove the partial
        ;; contribution, and raise a useful first-party failure.
        (tset package.preload :fen.extensions.tui
              (fn []
                (let [ext extensions
                      api (ext-api.make-runtime-api :tui)]
                  (api.register :presenter
                                {:name :tui :active? true
                                 :run (fn [_] nil)})
                  (error "boom while loading tui"))))
        (let [(ok? err) (pcall loader.load!
                               {:extension-paths []}
                               {:interactive? true})]
          (assert.is_false ok?)
          (assert.is_not_nil (string.find (tostring err)
                                          "first%-party extension load failed"))
          (assert.is_not_nil (string.find (tostring err) "tui"))
          (assert.is_nil (extensions.active-presenter))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 24 (length items))
            (assert.are.equal :loaded (. by-name :builtin_tools :status))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :error (. by-name :tui :status))
            (assert.is_true (. by-name :tui :first-party?))))))

    (it "loads an explicit Lua extension file"
      (fn []
        (let [path (write-file
                     (.. tmp "/hello.lua")
                     "return function(api)\n  api.register('command', { name = 'hello', handler = function() end })\nend\n")]
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.is_not_nil (command "hello"))
          (assert.are.equal "hello" (. (command "hello") :name))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 24 (length items))
            (assert.are.equal :loaded (. by-name :builtin_tools :status))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :loaded (. by-name "hello" :status))))))

    (it "cleans partial external registrations when registration fails"
      (fn []
        (let [path (write-file
                     (.. tmp "/bad.lua")
                     "return function(api)\n  api.register('command', { name = 'bad-cmd', handler = function() end })\n  error('boom during register')\nend\n")]
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.is_nil (command "bad-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 24 (length items))
            (assert.are.equal :loaded (. by-name :builtin_tools :status))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :error (. by-name "bad" :status))))))

    (it "discovers enabled extensions under XDG fen/extensions"
      (fn []
        (let [dir (.. tmp "/fen/extensions/auto")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'auto', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('tool', { name = 'auto-tool', execute = function() return { content = 'ok' } end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [tools (extensions.merged-tools [])
                names {}]
            (each [_ t (ipairs tools)]
              (tset names t.name true))
            (assert.are.equal 12 (length tools))
            (assert.is_true (. names :bash))
            (assert.is_true (. names :agent_state))
            (assert.is_true (. names :todo_write))
            (assert.is_true (. names "auto-tool"))))))

    (it "does not auto-discover non-dot project fen/extensions paths"
      (fn []
        (set project-pwd (.. tmp "/not-dot-project"))
        (write-file (.. project-pwd "/.git/keep") "")
        (let [dir (.. project-pwd "/fen/extensions/not-dot")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'not-dot', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('command', { name = 'not-dot-cmd', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.is_nil (command "not-dot-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.is_nil (. by-name "not-dot"))))))

    (it "records but does not load discovered extensions that are not enabled by default"
      (fn []
        (let [dir (.. tmp "/fen/extensions/off")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'off' }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('command', { name = 'off-cmd', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.is_nil (command "off-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 24 (length items))
            (assert.are.equal :loaded (. by-name :builtin_tools :status))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :disabled (. by-name "off" :status))))))

    (it "auto-discovers project-local directory extensions enabled by default"
      (fn []
        (set project-pwd (.. tmp "/project"))
        (write-file (.. project-pwd "/.git/keep") "")
        (let [dir (.. project-pwd "/.fen/extensions/local")]
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('command', { name = 'local-cmd', description = 'project', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.are.equal "project"
                            (command-description "local-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :loaded (. by-name "local" :status))
            (assert.are.equal :project (. by-name "local" :source))))))

    (it "discovers project-local single-file Fennel extensions"
      (fn []
        (set project-pwd (.. tmp "/single"))
        (write-file (.. project-pwd "/.git/keep") "")
        (write-file (.. project-pwd "/.fen/extensions/tiny.fnl")
                    "(fn [api]\n  (api.register :command {:name :tiny-cmd :description \"fnl file\" :handler (fn [] nil)}))\n")
        (loader.load! {:extension-paths []} {:interactive? false})
        (assert.are.equal "fnl file"
                          (command-description :tiny-cmd))))

    (it "silently skips hidden and underscored project-local entries"
      (fn []
        (set project-pwd (.. tmp "/skip"))
        (write-file (.. project-pwd "/.git/keep") "")
        (write-file (.. project-pwd "/.fen/extensions/_disabled/manifest.lua")
                    "return { name = 'disabled' }\n")
        (write-file (.. project-pwd "/.fen/extensions/_disabled/init.lua")
                    "return function(api)\n  api.register('command', { name = 'disabled-cmd', handler = function() end })\nend\n")
        (write-file (.. project-pwd "/.fen/extensions/.hidden.lua")
                    "return function(api)\n  api.register('command', { name = 'hidden-cmd', handler = function() end })\nend\n")
        (loader.load! {:extension-paths []} {:interactive? false})
        (assert.is_nil (command "disabled-cmd"))
        (assert.is_nil (command "hidden-cmd"))
        (let [items (extensions.list :extensions)
              by-name {}]
          (each [_ item (ipairs items)]
            (tset by-name item.name item))
          (assert.is_nil (. by-name "disabled"))
          (assert.is_nil (. by-name "hidden")))))

    (it "walks ancestor project-local roots up to the worktree marker"
      (fn []
        (let [root (.. tmp "/ancestor")
              child (.. root "/a/b")]
          (set project-pwd child)
          (write-file (.. root "/.git/keep") "")
          (write-file (.. root "/.fen/extensions/rooted/manifest.lua")
                      "return { name = 'rooted' }\n")
          (write-file (.. root "/.fen/extensions/rooted/init.lua")
                      "return function(api)\n  api.register('command', { name = 'rooted-cmd', description = 'ancestor', handler = function() end })\nend\n")
          (write-file (.. child "/keep") "")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.are.equal "ancestor"
                            (command-description "rooted-cmd")))))

    (it "prefers a project-local directory over a same-basename file"
      (fn []
        (set project-pwd (.. tmp "/collision"))
        (write-file (.. project-pwd "/.git/keep") "")
        (write-file (.. project-pwd "/.fen/extensions/dupe.lua")
                    "return function(api)\n  api.register('command', { name = 'dupe-file', handler = function() end })\nend\n")
        (write-file (.. project-pwd "/.fen/extensions/dupe/manifest.lua")
                    "return { name = 'dupe' }\n")
        (write-file (.. project-pwd "/.fen/extensions/dupe/init.lua")
                    "return function(api)\n  api.register('command', { name = 'dupe-dir', description = 'directory wins', handler = function() end })\nend\n")
        (loader.load! {:extension-paths []} {:interactive? false})
        (assert.is_nil (command "dupe-file"))
        (assert.are.equal "directory wins"
                          (command-description "dupe-dir"))))

    (it "reloads an already loaded explicit extension"
      (fn []
        (let [path (.. tmp "/flip.lua")]
          (write-file path
                      "return function(api)\n  api.register('command', { name = 'flip', description = 'one', handler = function() end })\nend\n")
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.are.equal "one" (command-description "flip"))
          (write-file path
                      "return function(api)\n  api.register('command', { name = 'flip', description = 'two', handler = function() end })\nend\n")
          (let [(ok? err) (loader.reload-extension! "flip")]
            (assert.is_true ok?)
            (assert.is_nil err)
            (assert.are.equal "two" (command-description "flip"))))))

    (it "honors :entry pointing at a sibling file relative to the manifest dir"
      (fn []
        (let [dir (.. tmp "/fen/extensions/cookie")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'cookie', ['enabled-by-default'] = true, entry = 'register.lua' }\n")
          (write-file (.. dir "/register.lua")
                      "return function(api)\n  api.register('command', { name = 'cookie-cmd', description = 'sweet', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.are.equal "sweet"
                            (command-description "cookie-cmd")))))

    (it "exposes api.load to import sibling files relative to the manifest dir"
      (fn []
        (let [dir (.. tmp "/fen/extensions/scoop")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'scoop', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/util.lua")
                      "return { describe = function() return 'from sibling' end }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  local util = api.load('util')\n  api.register('command', { name = 'scoop-cmd', description = util.describe(), handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.are.equal "from sibling"
                            (command-description "scoop-cmd")))))

    (it "trusts launcher first-party flat overlays before embedded specs"
      (fn []
        (let [root (.. tmp "/first-party-overlays")
              dir (.. root "/provider-openai")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'provider_openai', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('provider', { name = 'overlay-openai', api = 'openai-completions', models = { 'm' }, complete = function() end })\nend\n")
          (h.stub-getenv!
            (fn [name orig]
              (if (= name :XDG_CONFIG_HOME) tmp
                  (= name :FEN_EXTENSIONS_PATH) nil
                  (= name :FEN_FIRST_PARTY_EXTENSIONS_PATH) root
                  (= name :HOME) tmp
                  (= name :PWD) (or project-pwd (orig name))
                  (orig name))))
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :loaded (. by-name "provider_openai" :status))
            (assert.is_true (. by-name "provider_openai" :first-party?))
            (assert.are.equal :first-party (. by-name "provider_openai" :source))
            (assert.are.equal 2 (. by-name "provider_openai" :version-count))
            (assert.is_not_nil (extensions.find-provider :overlay-openai))))))

    (it "does not trust external manifests that claim first-party privilege"
      (fn []
        (let [dir (.. tmp "/fen/extensions/fakecore")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'fakecore', ['enabled-by-default'] = true, ['first-party?'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('provider', { name = 'fake', api = 'openai-completions' })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :error (. by-name "fakecore" :status))
            (assert.is_not_nil
              (string.find (. by-name "fakecore" :error)
                           "cannot register privileged kind provider" 1 true))
            (assert.is_nil (extensions.find-provider :fake))))))

    (it "preserves an :entry-module extension's registrations across :reload?"
      (fn []
        ;; Regression: load-module-spec! used to call unregister-by-owner
        ;; AFTER clear-reload-modules! had already re-required the body
        ;; (which itself self-unregistered and re-registered). The post-
        ;; re-require unregister wiped the just-installed contributions,
        ;; and the subsequent require was a package.loaded no-op, so /reload
        ;; left state.presenters / commands-extra empty. This test pins
        ;; the order: a contribution registered by the body must survive
        ;; a reload pass.
        (let [dir (.. tmp "/fen/extensions/persist")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'persist', ['enabled-by-default'] = true, ['entry-module'] = 'thirdparty.persist', ['reload-modules'] = { 'thirdparty.persist' } }\n")
          (tset package.preload "thirdparty.persist"
                (fn []
                  (let [ext extensions
                        api (ext-api.make-runtime-api :persist)]
                    (api.register :command
                                  {:name :persist-cmd
                                   :description "kept across reload"
                                   :handler (fn [] nil)})
                    {})))
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.is_not_nil (command :persist-cmd)
                             "command missing after initial load")
          (loader.load! {:extension-paths []} {:interactive? false :reload? true})
          (tset package.preload "thirdparty.persist" nil)
          (tset package.loaded "thirdparty.persist" nil)
          (assert.is_not_nil (command :persist-cmd)
                             "command wiped by reload — loader's unregister-by-owner fires AFTER the body re-registers"))))

    (it "discovers a manifest with :entry-module and uses the convention namespace"
      (fn []
        ;; Manifests that set :entry-module are loaded via require, so the
        ;; module's body runs once and self-registers. Mirrors first-party
        ;; behavior for any rock-shaped extension that opts in to it.
        (let [dir (.. tmp "/fen/extensions/sprinkles")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'sprinkles', ['enabled-by-default'] = true, ['entry-module'] = 'thirdparty.sprinkles' }\n")
          ;; Stub the entry module via package.preload so we don't have to
          ;; touch package.path for this test.
          (tset package.preload "thirdparty.sprinkles"
                (fn []
                  (let [ext extensions
                        api (ext-api.make-runtime-api :sprinkles)]
                    (api.register :command
                                  {:name :sprinkles-cmd
                                   :description "from entry-module"
                                   :handler (fn [] nil)})
                    {})))
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.are.equal "from entry-module"
                            (command-description :sprinkles-cmd))
          (tset package.preload "thirdparty.sprinkles"
                (fn []
                  (let [ext extensions
                        api (ext-api.make-runtime-api :sprinkles)]
                    (api.register :command
                                  {:name :sprinkles-cmd
                                   :description "after reload-extension"
                                   :handler (fn [] nil)})
                    {})))
          (let [(ok? err) (loader.reload-extension! :sprinkles)]
            (assert.is_true ok?)
            (assert.is_nil err)
            (assert.are.equal "after reload-extension"
                              (command-description :sprinkles-cmd)))
          (tset package.preload "thirdparty.sprinkles" nil)
          (tset package.loaded "thirdparty.sprinkles" nil))))

    (it "reports missing load-time module with fen ext build when rockspec exists"
      (fn []
        (let [dir (.. tmp "/fen/extensions/needrock")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'needrock', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/needrock-1-1.rockspec")
                      "package = 'needrock'\nversion = '1-1'\n")
          (write-file (.. dir "/init.lua")
                      "require('definitely_missing_needrock_dep')\nreturn function(api) end\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :error (. by-name "needrock" :status))
            (assert.is_not_nil
              (string.find (. by-name "needrock" :error)
                           "missing Lua module 'definitely_missing_needrock_dep'" 1 true))
            (assert.is_not_nil
              (string.find (. by-name "needrock" :error)
                           (.. "fen ext build '" dir "'") 1 true))))))

    (it "reports missing load-time module with manual install when no rockspec exists"
      (fn []
        (let [dir (.. tmp "/fen/extensions/needmanual")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'needmanual', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "require('definitely_missing_manual_dep')\nreturn function(api) end\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :error (. by-name "needmanual" :status))
            (assert.is_not_nil
              (string.find (. by-name "needmanual" :error)
                           "install module definitely_missing_manual_dep" 1 true))
            (assert.is_not_nil
              (string.find (. by-name "needmanual" :error)
                           "luarocks install --tree" 1 true))))))

    (it "probes manifest :requires-modules and reports all missing modules"
      (fn []
        (let [dir (.. tmp "/fen/extensions/declared")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'declared', ['enabled-by-default'] = true, ['requires-modules'] = { 'missing_declared_one', 'missing_declared_two' } }\n")
          (write-file (.. dir "/declared-1-1.rockspec")
                      "package = 'declared'\nversion = '1-1'\n")
          (write-file (.. dir "/init.lua")
                      "error('should not load when declared deps are missing')\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (let [err (. by-name "declared" :error)]
              (assert.are.equal :error (. by-name "declared" :status))
              (assert.is_not_nil (string.find err "missing_declared_one" 1 true))
              (assert.is_not_nil (string.find err "missing_declared_two" 1 true))
              (assert.is_not_nil (string.find err (.. "fen ext build '" dir "'") 1 true)))))))))
