;; Shared helpers for Fennel tests.
;; Keep temp path cleanup centralized and shell-quoted; individual tests should
;; not hand-roll `rm -rf` strings.

(fn shellquote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn parent-dir [path]
  (string.match path "(.*)/"))

(local owned-temp-roots {})
(local owned-temp-files {})

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
  (let [path (os.tmpname)]
    (write-file path content)
    (tset owned-temp-files path true)
    path))

(fn rm-file [path]
  (when path
    (assert (. owned-temp-files path)
            (.. "refusing to remove unowned temp file: " (tostring path)))
    (os.remove path)
    (tset owned-temp-files path nil)))


{: shellquote
 : make-tmpdir
 : rmtree
 : write-file
 : append-file
 : read-file
 : read-file!
 : make-tmpfile
 : rm-file}
