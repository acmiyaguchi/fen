;; Tests for external extension loader (issue #15 Step 5).

(local h (require :test_helpers))
(local extensions (require :core.extensions))
(local tools (require :core.tools))
(local system-prompt (require :core.system_prompt))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(describe "extensions loader"
  (fn []
    (var tmp nil)
    (var loader nil)

    (fn clear-tui-modules! []
      ;; Keep tests independent: built-in extension loading uses normal Lua
      ;; module caching, so clear both the entry and its behavior modules.
      (each [_ mod (ipairs [:extensions.agent_state
                            :extensions.agent_state.tool
                            :extensions.agent_state.manifest
                            :extensions.tui
                            :extensions.tui.manifest
                            :extensions.tui.markdown
                            :extensions.tui.paint
                            :extensions.tui.input])]
        (tset package.loaded mod nil)
        (tset package.preload mod nil))
      (tset package.loaded :termbox2 nil))

    (before_each
      (fn []
        (set tmp (make-tmpdir))
        (extensions.reset!)
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_CONFIG_HOME) tmp
                (= name :FEN_EXTENSIONS_PATH) nil
                (= name :HOME) tmp
                (orig name))))
        (set loader (h.reload-module :core.extension_loader))))

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
              tools (extensions.merged-tools [])]
          (assert.are.equal 1 (length items))
          (assert.are.equal :agent_state (. items 1 :name))
          (assert.are.equal :loaded (. items 1 :status))
          (assert.are.equal 1 (length tools))
          (assert.are.equal :agent_state (. tools 1 :name))
          (assert.is_nil (extensions.active-presenter)))))

    (it "includes first-party extension tools in prompt inputs"
      (fn []
        (loader.load! {:extension-paths []} {:interactive? false})
        (let [all-tools (extensions.merged-tools tools.registry)
              text (system-prompt.build {:system "body" :current-date "2026-04-28"}
                                        {:cwd "/repo"}
                                        all-tools)]
          (assert.is_truthy (string.find text "- agent_state: Inspect read%-only agent state"))
          (assert.is_truthy (string.find text "Use agent_state" 1 true)))))

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
        (loader.load-builtins!)
        (tset package.loaded :termbox2 nil)
        (let [items (extensions.list :extensions)]
          (assert.are.equal 2 (length items))
          (let [by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.is_true (. by-name :agent_state :first-party?))
            (assert.are.equal :loaded (. by-name :tui :status))
            (assert.is_true (. by-name :tui :first-party?)))
          (assert.is_not_nil (extensions.active-presenter)))))

    (it "fails fast and cleans partial first-party extension load failures"
      (fn []
        (clear-tui-modules!)
        ;; Force a module-load error after a partial side-effect registration.
        ;; The loader should record the real error, remove the partial
        ;; contribution, and raise a useful first-party failure.
        (tset package.preload :extensions.tui
              (fn []
                (let [ext (require :core.extensions)
                      api (ext.make-api :tui)]
                  (api.register :presenter
                                {:name :tui :active? true
                                 :run (fn [_] nil)})
                  (error "boom while loading tui"))))
        (let [(ok? err) (pcall loader.load-builtins!)]
          (assert.is_false ok?)
          (assert.is_not_nil (string.find (tostring err)
                                          "first%-party extension load failed"))
          (assert.is_not_nil (string.find (tostring err) "tui"))
          (assert.is_nil (extensions.active-presenter))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 2 (length items))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :error (. by-name :tui :status))
            (assert.is_true (. by-name :tui :first-party?))))))

    (it "loads an explicit Lua extension file"
      (fn []
        (let [path (write-file
                     (.. tmp "/hello.lua")
                     "return function(api)\n  api.register('command', { name = 'hello', handler = function() end })\nend\n")]
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.is_not_nil (. extensions.commands-extra "hello"))
          (assert.are.equal "hello" (. extensions.commands-extra "hello" :name))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 2 (length items))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :loaded (. by-name "hello" :status))))))

    (it "cleans partial external registrations when registration fails"
      (fn []
        (let [path (write-file
                     (.. tmp "/bad.lua")
                     "return function(api)\n  api.register('command', { name = 'bad-cmd', handler = function() end })\n  error('boom during register')\nend\n")]
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.is_nil (. extensions.commands-extra "bad-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 2 (length items))
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
            (assert.are.equal 2 (length tools))
            (assert.is_true (. names :agent_state))
            (assert.is_true (. names "auto-tool"))))))

    (it "records but does not load discovered extensions that are not enabled by default"
      (fn []
        (let [dir (.. tmp "/fen/extensions/off")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'off' }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('command', { name = 'off-cmd', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.is_nil (. extensions.commands-extra "off-cmd"))
          (let [items (extensions.list :extensions)
                by-name {}]
            (each [_ item (ipairs items)]
              (tset by-name item.name item))
            (assert.are.equal 2 (length items))
            (assert.are.equal :loaded (. by-name :agent_state :status))
            (assert.are.equal :disabled (. by-name "off" :status))))))

    (it "reloads an already loaded explicit extension"
      (fn []
        (let [path (.. tmp "/flip.lua")]
          (write-file path
                      "return function(api)\n  api.register('command', { name = 'flip', description = 'one', handler = function() end })\nend\n")
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.are.equal "one" (. extensions.commands-extra "flip" :description))
          (write-file path
                      "return function(api)\n  api.register('command', { name = 'flip', description = 'two', handler = function() end })\nend\n")
          (let [(ok? err) (loader.reload-extension! "flip")]
            (assert.is_true ok?)
            (assert.is_nil err)
            (assert.are.equal "two" (. extensions.commands-extra "flip" :description))))))))
