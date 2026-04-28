;; Tests for external extension loader (issue #15 Step 5).

(local h (require :test_helpers))
(local extensions (require :core.extensions))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local write-file h.write-file)

(describe "extensions loader"
  (fn []
    (var tmp nil)
    (var loader nil)

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
        (when tmp (rmtree tmp))))

    (it "loads an explicit Lua extension file"
      (fn []
        (let [path (write-file
                     (.. tmp "/hello.lua")
                     "return function(api)\n  api.register('command', { name = 'hello', handler = function() end })\nend\n")]
          (loader.load! {:extension-paths [path]} {:interactive? false})
          (assert.is_not_nil (. extensions.commands-extra "hello"))
          (assert.are.equal "hello" (. extensions.commands-extra "hello" :name))
          (let [items (extensions.list :extensions)]
            (assert.are.equal 1 (length items))
            (assert.are.equal "hello" (. items 1 :name))
            (assert.are.equal :loaded (. items 1 :status))))))

    (it "discovers enabled extensions under XDG fen/extensions"
      (fn []
        (let [dir (.. tmp "/fen/extensions/auto")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'auto', ['enabled-by-default'] = true }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('tool', { name = 'auto-tool', execute = function() return { content = 'ok' } end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (let [tools (extensions.merged-tools [])]
            (assert.are.equal 1 (length tools))
            (assert.are.equal "auto-tool" (. tools 1 :name))))))

    (it "records but does not load discovered extensions that are not enabled by default"
      (fn []
        (let [dir (.. tmp "/fen/extensions/off")]
          (write-file (.. dir "/manifest.lua")
                      "return { name = 'off' }\n")
          (write-file (.. dir "/init.lua")
                      "return function(api)\n  api.register('command', { name = 'off-cmd', handler = function() end })\nend\n")
          (loader.load! {:extension-paths []} {:interactive? false})
          (assert.is_nil (. extensions.commands-extra "off-cmd"))
          (let [items (extensions.list :extensions)]
            (assert.are.equal 1 (length items))
            (assert.are.equal "off" (. items 1 :name))
            (assert.are.equal :disabled (. items 1 :status))))))

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
