;; Tests for extensions.skills against an injected fen.util.path VFS backend
;; (issue #477). These exercise two host-coupling fixes:
;;   1. Discovery/enumeration is driven entirely by the injected backend
;;      (getenv/stat/list-dir/pwd-physical) with no real filesystem, popen, or
;;      `ls` — proving skill discovery routes through the path seam.
;;   2. The discover cache key is derived from path-seam values (cwd/home/XDG),
;;      so an env-less host whose backend supplies distinct identities gets
;;      distinct cache keys instead of the collapsed os.getenv strings the old
;;      code produced.

(local h (require :fen.testing))

;; --- path helpers matching fen.util.path's grammar -------------------------

(fn dirname [p]
  (let [d (string.match p "^(.*)/[^/]+$")]
    (if (not d) "."
        (= d "") "/"
        d)))

(fn basename [p]
  (or (string.match p "([^/]+)/?$") p))

;; Build an in-memory VFS backend from an env table and a list of file paths.
;; Directories and directory children are derived from the file paths.
(fn build-vfs [env file-paths]
  (let [dirs {"/" true}
        files {}
        children {}]
    (fn add-child [parent name]
      (let [lst (or (. children parent) [])]
        (tset children parent lst)
        (var seen false)
        (each [_ n (ipairs lst)] (when (= n name) (set seen true)))
        (when (not seen) (table.insert lst name))))
    (each [_ fp (ipairs (or file-paths []))]
      (tset files fp true)
      (var node fp)
      (var first? true)
      (while (and node (not= node "/"))
        (let [parent (dirname node)
              name (basename node)]
          (add-child parent name)
          (when (not first?) (tset dirs node true))
          (set first? false)
          (set node (if (= parent node) "/" parent)))))
    {:getenv (fn [name] (. env name))
     :stat (fn [p] (if (. dirs p) :directory (. files p) :file nil))
     :list-dir (fn [d] (or (. children d) []))
     :pwd-physical (fn [d] d)}))

;; Stub frontmatter parsing so an in-memory SKILL.md path yields metadata
;; without a real file read (frontmatter content is out of the path seam's
;; scope; this isolates the traversal under test).
(fn stub-frontmatter! [meta-by-path]
  (tset package.loaded :fen.util.frontmatter
        {:parse-file (fn [p]
                       (let [m (. meta-by-path p)]
                         (if m (values m nil nil)
                             (values nil :missing "no frontmatter"))))}))

(fn restore-frontmatter! []
  (tset package.loaded :fen.util.frontmatter nil))

;; Install a VFS backend + frontmatter stub and reload the skills modules so
;; their captured `path`/`frontmatter` bindings pick up the stubs.
(fn load-skills-with-vfs [backend meta-by-path]
  (h.stub-path-vfs! backend)
  (stub-frontmatter! meta-by-path)
  (h.reload-module :fen.extensions.skills.state)
  (h.reload-module :fen.extensions.skills.ignore)
  (h.reload-module :fen.extensions.skills))

(fn teardown-vfs []
  (restore-frontmatter!)
  (h.restore-path-vfs!)
  ;; Rebind path-dependent skills submodules to the restored POSIX backend so
  ;; later test files don't inherit the stub-bound `path` reference.
  (h.reload-module :fen.extensions.skills.state)
  (h.reload-module :fen.extensions.skills.ignore)
  (h.reload-module :fen.extensions.skills))

(describe "extensions.skills injected VFS backend"
  (fn []
    (after_each teardown-vfs)

    (it "drives discovery from the path seam with no real filesystem"
      (fn []
        (let [env {:HOME "/home/vuser"
                   :XDG_CONFIG_HOME "/home/vuser/.config"
                   :XDG_DATA_HOME "/home/vuser/.local/share"
                   :PWD "/proj"
                   :FEN_DISABLE_BUNDLED_SKILLS "1"}
              skill-path "/home/vuser/.config/fen/skills/greeter/SKILL.md"
              backend (build-vfs env [skill-path])
              skills-mod (load-skills-with-vfs
                           backend
                           {skill-path {:name "greeter"
                                        :description "Greets"}})
              found (skills-mod.discover [])]
          (assert.are.equal 1 (length found))
          (assert.are.equal "greeter" (. found 1 :name))
          (assert.are.equal "Greets" (. found 1 :description))
          (assert.are.equal :user (. found 1 :scope))
          (assert.are.equal skill-path (. found 1 :path)))))

    (it "discovers nothing when the injected tree is empty"
      (fn []
        (let [env {:HOME "/home/vuser"
                   :XDG_CONFIG_HOME "/home/vuser/.config"
                   :XDG_DATA_HOME "/home/vuser/.local/share"
                   :PWD "/proj"
                   :FEN_DISABLE_BUNDLED_SKILLS "1"}
              backend (build-vfs env [])
              skills-mod (load-skills-with-vfs backend {})
              found (skills-mod.discover [])]
          (assert.are.equal 0 (length found)))))))

(describe "extensions.skills discover cache key"
  (fn []
    (after_each teardown-vfs)

    (it "yields distinct keys for distinct injected VFS identities"
      (fn []
        ;; Env-less host: os.getenv would return nil for all of these, so the
        ;; old cache key collapsed to one string. The backend supplies the
        ;; identity, so path.cwd/home/config-home diverge and keys differ.
        (let [env-a {:HOME "/home/a" :PWD "/proj/a"
                     :XDG_CONFIG_HOME "/home/a/.config"
                     :XDG_DATA_HOME "/home/a/.local/share"}
              env-b {:HOME "/home/b" :PWD "/proj/b"
                     :XDG_CONFIG_HOME "/home/b/.config"
                     :XDG_DATA_HOME "/home/b/.local/share"}
              mod-a (load-skills-with-vfs (build-vfs env-a []) {})
              key-a (mod-a._discover-cache-key [])
              key-a2 (mod-a._discover-cache-key [])]
          (teardown-vfs)
          (let [mod-b (load-skills-with-vfs (build-vfs env-b []) {})
                key-b (mod-b._discover-cache-key [])]
            (assert.is_string key-a)
            (assert.is_string key-b)
            ;; Stable within one identity...
            (assert.are.equal key-a key-a2)
            ;; ...distinct across identities (the #477 collapse bug).
            (assert.are_not.equal key-a key-b)))))

    (it "includes extra skill paths in the key"
      (fn []
        (let [env {:HOME "/home/a" :PWD "/proj/a"
                   :XDG_CONFIG_HOME "/home/a/.config"
                   :XDG_DATA_HOME "/home/a/.local/share"}
              mod (load-skills-with-vfs (build-vfs env []) {})
              base (mod._discover-cache-key [])
              with-extra (mod._discover-cache-key ["/extra/skills"])]
          (assert.are_not.equal base with-extra))))))
