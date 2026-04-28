;; Shared helpers for Fennel tests.
;; Keep temp path cleanup centralized and shell-quoted; individual tests should
;; not hand-roll `rm -rf` strings.

(fn shellquote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn parent-dir [path]
  (string.match path "(.*)/"))

(local owned-temp-roots {})
(local owned-temp-files {})
;; Captured when test_helpers is loaded by the busted helper, before tests
;; install their own stubs. getenv stubs intentionally do not stack: call
;; restore-getenv! before installing another one.
(local original-getenv os.getenv)

(fn stub-getenv! [resolver]
  "Monkey-patch os.getenv for a test. `resolver` receives (name, original-getenv)
   and should return the desired value or delegate to original-getenv. Stubs do
   not stack; pair with restore-getenv! in after_each."
  (set os.getenv (fn [name] (resolver name original-getenv))))

(fn restore-getenv! []
  (set os.getenv original-getenv))

(fn reload-module [name]
  (tset package.loaded name nil)
  (require name))

(fn make-tmpdir []
  (let [pipe (io.popen "mktemp -d" :r)
        path (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (assert (and path (not= path "")) "mktemp -d failed")
    (tset owned-temp-roots path true)
    path))

(fn rmtree [path]
  "Remove a temp directory tree created by make-tmpdir.
   This intentionally refuses arbitrary paths; tests should not have a general
   rm -rf primitive. Call make-tmpdir/with-tmpdir, then clean up that exact
   owned root."
  (when (and path (not= path ""))
    (assert (. owned-temp-roots path)
            (.. "refusing to remove unowned temp root: " (tostring path)))
    (assert (not= path "/") "refusing to remove /")
    (assert (string.find path "/" 1 true) "refusing to remove a bare name")
    (assert (os.execute (.. "rm -rf -- " (shellquote path))))
    (tset owned-temp-roots path nil)))


(fn write-file [path content]
  (let [dir (parent-dir path)]
    (when (and dir (not= dir ""))
      (assert (os.execute (.. "mkdir -p -- " (shellquote dir))))))
  (let [f (assert (io.open path :w))]
    (f:write (or content ""))
    (f:close))
  path)

(fn append-file [path content]
  (let [f (assert (io.open path :a))]
    (f:write (or content ""))
    (f:close))
  path)

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [content (f:read :*a)]
        (f:close)
        content))))

(fn read-file! [path]
  (let [f (assert (io.open path :r))
        content (f:read :*a)]
    (f:close)
    content))

(fn make-tmpfile [content]
  (let [pipe (io.popen "mktemp" :r)
        path (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (assert (and path (not= path "")) "mktemp failed")
    ;; Register ownership before writing, so a failed write still leaves a path
    ;; the test can clean with rm-file.
    (tset owned-temp-files path true)
    (write-file path content)
    path))

(fn rm-file [path]
  (when path
    (assert (. owned-temp-files path)
            (.. "refusing to remove unowned temp file: " (tostring path)))
    (let [(ok? err) (os.remove path)]
      (assert ok? (.. "failed to remove temp file " (tostring path) ": " (tostring err))))
    (tset owned-temp-files path nil)))

(fn assert-no-leaks! []
  (let [root (next owned-temp-roots)
        file (next owned-temp-files)]
    (assert (not root) (.. "leaked temp root: " (tostring root)))
    (assert (not file) (.. "leaked temp file: " (tostring file)))))


{: shellquote
 : stub-getenv!
 : restore-getenv!
 : reload-module
 : make-tmpdir
 : rmtree
 : write-file
 : append-file
 : read-file
 : read-file!
 : make-tmpfile
 : rm-file
 : assert-no-leaks!}
