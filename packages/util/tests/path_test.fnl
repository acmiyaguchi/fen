(local helpers (require :fen.testing))

;; A recording backend that satisfies the fen.util.path seam surface
;; (getenv/stat/list-dir/pwd-physical). Each call is logged so tests can assert
;; the public helpers route through the injected backend rather than the host.
(fn make-backend [overrides]
  (let [calls {:getenv [] :stat [] :list-dir [] :pwd-physical []}
        env (or (?. overrides :env) {})
        modes (or (?. overrides :modes) {})
        entries (or (?. overrides :entries) {})
        physical (or (?. overrides :physical) {})]
    {:calls calls
     :getenv (fn [name]
               (table.insert calls.getenv name)
               (. env name))
     :stat (fn [path]
             (table.insert calls.stat path)
             (. modes path))
     :list-dir (fn [dir]
                 (table.insert calls.list-dir dir)
                 (or (. entries dir) []))
     :pwd-physical (fn [dir]
                     (table.insert calls.pwd-physical dir)
                     (. physical dir))}))

(fn with-backend [overrides f]
  (let [backend (make-backend overrides)]
    (helpers.stub-path-vfs! backend)
    (f (require :fen.util.path) backend)))

(describe "util.path seam"
  (fn []
    (after_each (fn [] (helpers.restore-path-vfs!)))

    (it "home reads HOME through the backend, /tmp fallback"
      (fn []
        (with-backend {:env {:HOME "/home/tester"}}
          (fn [path backend]
            (assert.are.equal "/home/tester" (path.home))
            (assert.are.equal :HOME (. backend.calls.getenv 1))))
        (helpers.restore-path-vfs!)
        (with-backend {}
          (fn [path _]
            (assert.are.equal "/tmp" (path.home))))))

    (it "XDG helpers derive from the backend getenv"
      (fn []
        (with-backend {:env {:HOME "/h"
                             :XDG_CONFIG_HOME "/cfg"}}
          (fn [path _]
            (assert.are.equal "/cfg" (path.config-home))
            (assert.are.equal "/cfg/fen" (path.config-dir :fen))
            ;; Unset XDG_STATE_HOME/XDG_DATA_HOME fall back under home.
            (assert.are.equal "/h/.local/state" (path.state-home))
            (assert.are.equal "/h/.local/share/fen" (path.data-dir :fen))))))

    (it "cwd prefers PWD from the backend, else pwd-physical"
      (fn []
        (with-backend {:env {:PWD "/spelled/path"}
                       :physical {"." "/physical/path"}}
          (fn [path backend]
            (assert.are.equal "/spelled/path" (path.cwd))
            (assert.are.equal 0 (length backend.calls.pwd-physical))))
        (helpers.restore-path-vfs!)
        (with-backend {:physical {"." "/physical/path"}}
          (fn [path backend]
            (assert.are.equal "/physical/path" (path.cwd))
            (assert.are.equal "." (. backend.calls.pwd-physical 1))))))

    (it "file-exists?/dir-exists? flow through the backend stat"
      (fn []
        (with-backend {:modes {"/a/file" :file
                               "/a/dir" :directory}}
          (fn [path backend]
            (assert.is_true (path.file-exists? "/a/file"))
            (assert.is_false (path.file-exists? "/a/dir"))
            (assert.is_true (path.dir-exists? "/a/dir"))
            (assert.is_false (path.dir-exists? "/nope"))
            (assert.are.same ["/a/file" "/a/dir" "/a/dir" "/nope"]
                             backend.calls.stat)))))

    (it "list-dir flows through the backend"
      (fn []
        (with-backend {:entries {"/d" ["one" "two"]}}
          (fn [path backend]
            (assert.are.same ["one" "two"] (path.list-dir "/d"))
            (assert.are.same [] (path.list-dir "/empty"))
            (assert.are.same ["/d" "/empty"] backend.calls.list-dir)))))

    (it "pwd-physical/realpath route through the backend"
      (fn []
        (with-backend {:physical {"/x" "/real/x"}}
          (fn [path _]
            (assert.are.equal "/real/x" (path.pwd-physical "/x"))
            (assert.are.equal "/real/x/f.txt" (path.realpath "/x/f.txt"))))))

    (it "ancestors-root-to-leaf uses the backend physical path"
      (fn []
        (with-backend {:physical {"/a/b/c" "/a/b/c"}}
          (fn [path _]
            (assert.are.same ["/" "/a" "/a/b" "/a/b/c"]
                             (path.ancestors-root-to-leaf "/a/b/c"))))))))

;; Pure helpers need no backend; confirm they stay stable.
(describe "util.path pure helpers"
  (fn []
    (after_each (fn [] (helpers.restore-path-vfs!)))
    (it "dirname/basename/shell-quote"
      (fn []
        (let [path (require :fen.util.path)]
          (assert.are.equal "/a/b" (path.dirname "/a/b/c"))
          (assert.are.equal "/" (path.dirname "/x"))
          (assert.are.equal "." (path.dirname "bare"))
          (assert.are.equal "c" (path.basename "/a/b/c"))
          (assert.are.equal "c" (path.basename "/a/b/c/"))
          (assert.are.equal "'a'\\''b'" (path.shell-quote "a'b")))))))

;; The default (POSIX) backend must still work end to end on a real host.
(describe "util.path default POSIX backend"
  (fn []
    (var root nil)
    (before_each (fn []
                   (helpers.restore-path-vfs!)
                   (set root (helpers.make-tmpdir))))
    (after_each (fn []
                  (when root (helpers.rmtree root))
                  (set root nil)
                  (helpers.restore-path-vfs!)))

    (it "stat/list-dir observe a real directory tree"
      (fn []
        (let [path (require :fen.util.path)]
          (helpers.write-file (.. root "/f.txt") "hi")
          (assert (os.execute (.. "mkdir -p " (path.shell-quote (.. root "/sub")))))
          (assert.is_true (path.file-exists? (.. root "/f.txt")))
          (assert.is_false (path.file-exists? (.. root "/sub")))
          (assert.is_true (path.dir-exists? (.. root "/sub")))
          (assert.is_false (path.dir-exists? (.. root "/f.txt")))
          (assert.is_false (path.file-exists? (.. root "/missing")))
          (assert.is_false (path.dir-exists? (.. root "/missing")))
          (let [names (path.list-dir root)
                seen {}]
            (each [_ n (ipairs names)] (tset seen n true))
            (assert.is_true (. seen "f.txt"))
            (assert.is_true (. seen "sub")))
          (assert.are.same [] (path.list-dir (.. root "/missing"))))))

    (it "pwd-physical resolves a real directory"
      (fn []
        (let [path (require :fen.util.path)
              real (path.pwd-physical root)]
          (assert.is_string real)
          (assert.is_true (path.dir-exists? real)))))

    (it "home reflects the real HOME env"
      (fn []
        (let [path (require :fen.util.path)]
          (helpers.stub-getenv! (fn [name orig]
                                  (if (= name :HOME) "/home/real" (orig name))))
          (assert.are.equal "/home/real" (path.home))
          (helpers.restore-getenv!))))))
