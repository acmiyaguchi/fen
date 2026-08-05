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
(local package-loaded-nil-sentinel {})
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

;; @doc fen.testing.package-loaded-snapshot
;; kind: function
;; signature: (package-loaded-snapshot names) -> table
;; summary: Capture package.loaded entries so tests that stub modules can restore them reliably, including nil entries.
;; tags: testing modules stubs package-loaded
(fn package-loaded-snapshot [names]
  (let [snapshot {}]
    (each [_ name (ipairs (or names []))]
      (let [current (. package.loaded name)]
        (tset snapshot name (if (= current nil) package-loaded-nil-sentinel current))))
    snapshot))

;; @doc fen.testing.restore-package-loaded!
;; kind: function
;; signature: (restore-package-loaded! snapshot) -> nil
;; summary: Restore a package.loaded snapshot captured by package-loaded-snapshot.
;; tags: testing modules stubs package-loaded
(fn restore-package-loaded! [snapshot]
  (each [name value (pairs (or snapshot {}))]
    (tset package.loaded name (if (= value package-loaded-nil-sentinel) nil value))))

;; @doc fen.testing.with-package-loaded
;; kind: function
;; signature: (with-package-loaded stubs thunk) -> any
;; summary: Temporarily replace package.loaded entries while running a test thunk, then restore them even on failure.
;; tags: testing modules stubs package-loaded
(fn with-package-loaded [stubs thunk]
  (let [names []]
    (each [name _ (pairs (or stubs {}))]
      (table.insert names name))
    (let [snapshot (package-loaded-snapshot names)]
      (each [name value (pairs (or stubs {}))]
        (tset package.loaded name value))
      (let [(ok? result) (pcall thunk)]
        (restore-package-loaded! snapshot)
        (if ok? result (error result))))))

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

;; @doc fen.testing.stub-path-vfs!
;; kind: function
;; signature: (stub-path-vfs! backend) -> nil
;; summary: Replace fen.util.path's filesystem/env backend with a test double and clear the cached frontend module.
;; tags: testing path vfs stubs
(fn stub-path-vfs! [backend]
  "Replace fen.util.path's backend with a stub for the duration of a test.
   `backend` is a table exposing getenv/stat/list-dir/pwd-physical; missing
   fields simply won't be exercised by the helpers under test. Pair with
   restore-path-vfs! in after_each."
  (tset package.loaded :fen.util.path.backend backend)
  (tset package.loaded :fen.util.path nil))

;; @doc fen.testing.restore-path-vfs!
;; kind: function
;; signature: (restore-path-vfs!) -> nil
;; summary: Remove the stubbed path backend and cached frontend so later tests reload the default POSIX backend.
;; tags: testing path vfs stubs
(fn restore-path-vfs! []
  (tset package.loaded :fen.util.path.backend nil)
  (tset package.loaded :fen.util.path.backends.posix nil)
  (tset package.loaded :fen.util.path nil))

;; @doc fen.testing.stub-clock!
;; kind: function
;; signature: (stub-clock! backend) -> nil
;; summary: Replace fen.util.clock's backend with a test double and clear the cached frontend module.
;; tags: testing clock stubs
(fn stub-clock! [backend]
  "Replace fen.util.clock's backend with a stub for the duration of a test.
   `backend` is a table exposing monotonic-ms/sleep-ms; missing fields simply
   won't be exercised by the code under test. Pair with restore-clock! in
   after_each."
  (tset package.loaded :fen.util.clock.backend backend)
  (tset package.loaded :fen.util.clock nil))

;; @doc fen.testing.restore-clock!
;; kind: function
;; signature: (restore-clock!) -> nil
;; summary: Remove the stubbed clock backend and cached frontend so later tests reload the default native clock.
;; tags: testing clock stubs
(fn restore-clock! []
  (tset package.loaded :fen.util.clock.backend nil)
  (tset package.loaded :fen.util.clock.backends.native nil)
  (tset package.loaded :fen.util.clock nil))

;; @doc fen.testing.stub-process!
;; kind: function
;; signature: (stub-process! backend) -> nil
;; summary: Replace fen.util.process's subprocess backend with a test double and clear the cached frontend module.
;; tags: testing process stubs
(fn stub-process! [backend]
  "Replace fen.util.process's backend with a stub for the duration of a test.
   `backend` is a table exposing the subprocess primitives the code under test
   exercises (fileno/set_nonblock/read/close_fd, spawn/spawn_shell/wait_pid/
   kill_process_group, setenv, and EAGAIN/EWOULDBLOCK/SIGTERM/SIGKILL); missing
   fields simply won't be exercised. Pair with restore-process! in after_each."
  (tset package.loaded :fen.util.process.backend backend)
  (tset package.loaded :fen.util.process nil))

;; @doc fen.testing.restore-process!
;; kind: function
;; signature: (restore-process!) -> nil
;; summary: Remove the stubbed process backend and cached frontend so later tests reload the default POSIX subprocess backend.
;; tags: testing process stubs
(fn restore-process! []
  (tset package.loaded :fen.util.process.backend nil)
  (tset package.loaded :fen.util.process.backends.posix nil)
  (tset package.loaded :fen.util.process nil))

;; @doc fen.testing.stub-random!
;; kind: function
;; signature: (stub-random! backend) -> nil
;; summary: Replace fen.util.random's CSPRNG backend with a test double and clear the cached frontend module.
;; tags: testing random stubs
(fn stub-random! [backend]
  "Replace fen.util.random's backend with a stub for the duration of a test.
   `backend` is a table exposing `bytes`. Pair with restore-random! in
   after_each."
  (tset package.loaded :fen.util.random.backend backend)
  (tset package.loaded :fen.util.random nil))

;; @doc fen.testing.restore-random!
;; kind: function
;; signature: (restore-random!) -> nil
;; summary: Remove the stubbed random backend and cached frontend so later tests reload the default native CSPRNG.
;; tags: testing random stubs
(fn restore-random! []
  (tset package.loaded :fen.util.random.backend nil)
  (tset package.loaded :fen.util.random.backends.native nil)
  (tset package.loaded :fen.util.random nil))

;; @doc fen.testing.stub-checksum!
;; kind: function
;; signature: (stub-checksum! backend) -> nil
;; summary: Replace fen.util.checksum's fingerprint-provider backend with a test double and clear the cached frontend module.
;; tags: testing checksum stubs
(fn stub-checksum! [backend]
  "Replace fen.util.checksum's backend with a stub for the duration of a test.
   `backend` is a table exposing file-fingerprint/module-path/module-fingerprint;
   missing fields simply won't be exercised by the code under test. Pair with
   restore-checksum! in after_each."
  (tset package.loaded :fen.util.checksum.backend backend)
  (tset package.loaded :fen.util.checksum nil))

;; @doc fen.testing.restore-checksum!
;; kind: function
;; signature: (restore-checksum!) -> nil
;; summary: Remove the stubbed checksum backend and cached frontend so later tests reload the default io.open/searchpath backend.
;; tags: testing checksum stubs
(fn restore-checksum! []
  (tset package.loaded :fen.util.checksum.backend nil)
  (tset package.loaded :fen.util.checksum.backends.default nil)
  (tset package.loaded :fen.util.checksum nil))

;; @doc fen.testing.stub-storage!
;; kind: function
;; signature: (stub-storage! backend) -> nil
;; summary: Replace fen.core.storage's config-document backend with a test double and clear the cached frontend module.
;; tags: testing storage config stubs
(fn stub-storage! [backend]
  "Replace fen.core.storage's backend with a stub for the duration of a test.
   `backend` is a table exposing read/write!; missing fields simply won't be
   exercised by the code under test. This lets a test round-trip settings and
   serve models.json entirely in memory, with no filesystem. Pair with
   restore-storage! in after_each."
  (tset package.loaded :fen.core.storage.backend backend)
  (tset package.loaded :fen.core.storage nil))

;; @doc fen.testing.restore-storage!
;; kind: function
;; signature: (restore-storage!) -> nil
;; summary: Remove the stubbed storage backend and cached frontend so later tests reload the default XDG-file backend.
;; tags: testing storage config stubs
(fn restore-storage! []
  (tset package.loaded :fen.core.storage.backend nil)
  (tset package.loaded :fen.core.storage.backends.default nil)
  (tset package.loaded :fen.core.storage nil))

;; @doc fen.testing.stub-discover-enumeration!
;; kind: function
;; signature: (stub-discover-enumeration! backend) -> nil
;; summary: Replace extension discovery's manifest-enumeration backend with a test double and clear the cached discover frontend module.
;; tags: testing extensions loader discovery stubs
(fn stub-discover-enumeration! [backend]
  "Replace fen.core.extensions.loader.discover's enumeration backend with a
   stub for the duration of a test. `backend` is a table exposing `enumerate`
   (explicit-paths ?yield-fn) -> [spec]; this lets a test supply the
   discovered-manifest list with no filesystem or subprocess access. Pair with
   restore-discover-enumeration! in after_each."
  (tset package.loaded :fen.core.extensions.loader.discover.backend backend)
  (tset package.loaded :fen.core.extensions.loader.discover nil))

;; @doc fen.testing.restore-discover-enumeration!
;; kind: function
;; signature: (restore-discover-enumeration!) -> nil
;; summary: Remove the stubbed discovery backend and cached frontend so later tests reload the default POSIX enumeration.
;; tags: testing extensions loader discovery stubs
(fn restore-discover-enumeration! []
  (tset package.loaded :fen.core.extensions.loader.discover.backend nil)
  (tset package.loaded :fen.core.extensions.loader.discover.backends.posix nil)
  (tset package.loaded :fen.core.extensions.loader.discover nil))

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
 : package-loaded-snapshot
 : restore-package-loaded!
 : with-package-loaded
 : reload-module
 : stub-http!
 : restore-http!
 : stub-path-vfs!
 : restore-path-vfs!
 : stub-clock!
 : restore-clock!
 : stub-process!
 : restore-process!
 : stub-random!
 : restore-random!
 : stub-checksum!
 : restore-checksum!
 : stub-storage!
 : restore-storage!
 : stub-discover-enumeration!
 : restore-discover-enumeration!
 : make-tmpdir
 : rmtree
 : write-file
 : append-file
 : read-file
 : read-file!
 : make-tmpfile
 : rm-file
 : assert-no-leaks!}
