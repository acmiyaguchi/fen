;; Shared helpers for Fennel tests.
;; Keep temp path cleanup centralized and shell-quoted; individual tests should
;; not hand-roll `rm -rf` strings.

;; @doc fen.testing.shellquote
;; kind: function
;; signature: (shellquote s) -> string
;; summary: Quote a string for POSIX shell commands used by test filesystem helpers.
;; tags: testing shell paths
(fn shellquote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn parent-dir [path]
  (string.match path "(.*)/"))

(local owned-temp-roots {})
(local owned-temp-files {})
;; Captured when fen.testing is loaded by the busted helper, before tests
;; install their own stubs. getenv stubs intentionally do not stack: call
;; restore-getenv! before installing another one.
(local original-getenv os.getenv)

;; @doc fen.testing.stub-getenv!
;; kind: function
;; signature: (stub-getenv! resolver) -> nil
;; summary: Replace os.getenv in tests with a resolver that can delegate to the original environment lookup.
;; tags: testing env stubs
(fn stub-getenv! [resolver]
  "Monkey-patch os.getenv for a test. `resolver` receives (name, original-getenv)
   and should return the desired value or delegate to original-getenv. Stubs do
   not stack; pair with restore-getenv! in after_each."
  (set os.getenv (fn [name] (resolver name original-getenv))))

;; @doc fen.testing.restore-getenv!
;; kind: function
;; signature: (restore-getenv!) -> nil
;; summary: Restore the original os.getenv captured before tests installed any environment stubs.
;; tags: testing env stubs
(fn restore-getenv! []
  (set os.getenv original-getenv))

;; @doc fen.testing.reload-module
;; kind: function
;; signature: (reload-module name) -> any
;; summary: Clear package.loaded for one module and require it again so tests can observe module initialization behavior.
;; tags: testing reload modules
(fn reload-module [name]
  (tset package.loaded name nil)
  (require name))

;; @doc fen.testing.stub-http!
;; kind: function
;; signature: (stub-http! responder) -> nil
;; summary: Replace fen.util.http's backend with a test responder and clear the cached frontend module.
;; tags: testing http stubs
(fn stub-http! [responder]
  "Replace fen.util.http's backend with a stub for the duration of a test.
   `responder` is a function (opts) -> response-table; it receives the
   exact opts table the caller passed to http.request and must return a
   table shaped like {:status N :body string} or {:error string}.
   Pair with restore-http! in after_each."
  (tset package.loaded :fen.util.http.backend {:request responder})
  (tset package.loaded :fen.util.http nil))

;; @doc fen.testing.restore-http!
;; kind: function
;; signature: (restore-http!) -> nil
;; summary: Remove the stubbed HTTP backend and cached frontend so later tests reload the normal transport.
;; tags: testing http stubs
(fn restore-http! []
  (tset package.loaded :fen.util.http.backend nil)
  (tset package.loaded :fen.util.http nil))

;; @doc fen.testing.make-tmpdir
;; kind: function
;; signature: (make-tmpdir) -> string
;; summary: Create and register ownership of a temporary directory that rmtree is allowed to remove.
;; tags: testing temp files
(fn make-tmpdir []
  (let [pipe (io.popen "mktemp -d" :r)
        path (and pipe (pipe:read :*l))]
    (when pipe (pipe:close))
    (assert (and path (not= path "")) "mktemp -d failed")
    (tset owned-temp-roots path true)
    path))

;; @doc fen.testing.rmtree
;; kind: function
;; signature: (rmtree path) -> nil
;; summary: Remove an owned temporary directory tree, refusing arbitrary or unsafe paths.
;; tags: testing temp files safety
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


;; @doc fen.testing.write-file
;; kind: function
;; signature: (write-file path content) -> path
;; summary: Create parent directories as needed and write content to a test fixture file.
;; tags: testing files fixtures
(fn write-file [path content]
  (let [dir (parent-dir path)]
    (when (and dir (not= dir ""))
      (assert (os.execute (.. "mkdir -p -- " (shellquote dir))))))
  (let [f (assert (io.open path :w))]
    (f:write (or content ""))
    (f:close))
  path)

;; @doc fen.testing.append-file
;; kind: function
;; signature: (append-file path content) -> path
;; summary: Append content to a test fixture file and return the path for fluent setup code.
;; tags: testing files fixtures
(fn append-file [path content]
  (let [f (assert (io.open path :a))]
    (f:write (or content ""))
    (f:close))
  path)

;; @doc fen.testing.read-file
;; kind: function
;; signature: (read-file path) -> string|nil
;; summary: Read a file if it exists, returning nil instead of failing for optional fixture paths.
;; tags: testing files fixtures
(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [content (f:read :*a)]
        (f:close)
        content))))

;; @doc fen.testing.read-file!
;; kind: function
;; signature: (read-file! path) -> string
;; summary: Read a required fixture file and fail the test immediately if it cannot be opened.
;; tags: testing files fixtures
(fn read-file! [path]
  (let [f (assert (io.open path :r))
        content (f:read :*a)]
    (f:close)
    content))

;; @doc fen.testing.make-tmpfile
;; kind: function
;; signature: (make-tmpfile content) -> string
;; summary: Create an owned temporary file, write initial content, and return its path for the test.
;; tags: testing temp files
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

;; @doc fen.testing.rm-file
;; kind: function
;; signature: (rm-file path) -> nil
;; summary: Remove an owned temporary file and refuse paths that were not created by make-tmpfile.
;; tags: testing temp files safety
(fn rm-file [path]
  (when path
    (assert (. owned-temp-files path)
            (.. "refusing to remove unowned temp file: " (tostring path)))
    (let [(ok? err) (os.remove path)]
      (assert ok? (.. "failed to remove temp file " (tostring path) ": " (tostring err))))
    (tset owned-temp-files path nil)))

;; @doc fen.testing.assert-no-leaks!
;; kind: function
;; signature: (assert-no-leaks!) -> nil
;; summary: Assert that all owned temporary roots and files have been cleaned up by the test suite.
;; tags: testing temp safety
(fn assert-no-leaks! []
  (let [root (next owned-temp-roots)
        file (next owned-temp-files)]
    (assert (not root) (.. "leaked temp root: " (tostring root)))
    (assert (not file) (.. "leaked temp file: " (tostring file)))))


{: shellquote
 : stub-getenv!
 : restore-getenv!
 : reload-module
 : stub-http!
 : restore-http!
 : make-tmpdir
 : rmtree
 : write-file
 : append-file
 : read-file
 : read-file!
 : make-tmpfile
 : rm-file
 : assert-no-leaks!}
