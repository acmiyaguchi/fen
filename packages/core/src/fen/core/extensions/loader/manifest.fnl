;; Extension manifest reading + entry-file loading.

(local path (require :fen.util.path))

(local M {})

(fn M.strip-ext [name]
  (or (string.match name "^(.*)%.fnl$")
      (string.match name "^(.*)%.lua$")
      name))

(fn load-fnl-file [file-path]
  (let [(ok? fennel) (pcall require :fennel)]
    (if (not ok?)
        (values nil (.. "cannot load Fennel extension without fennel module: "
                        (tostring fennel)))
        (let [(ok2 result) (pcall fennel.dofile file-path)]
          (if ok2 (values result nil) (values nil result))))))

(fn load-lua-file [file-path]
  (let [(ok? result) (pcall dofile file-path)]
    (if ok? (values result nil) (values nil result))))

(fn M.load-file [file-path]
  "Run a .fnl/.lua file as a script and return its return value (or nil + err)."
  (if (string.match file-path "%.fnl$")
      (load-fnl-file file-path)
      (load-lua-file file-path)))

(fn M.manifest-path [dir]
  (let [fnl-path (.. dir "/manifest.fnl")
        lua-path (.. dir "/manifest.lua")]
    (if (path.file-exists? fnl-path) fnl-path
        (path.file-exists? lua-path) lua-path
        nil)))

(fn M.entry-path-for-dir [dir]
  (let [fnl-path (.. dir "/init.fnl")
        lua-path (.. dir "/init.lua")]
    (if (path.file-exists? fnl-path) fnl-path
        (path.file-exists? lua-path) lua-path
        nil)))

(fn M.read-manifest [file-path]
  (if file-path
      (let [(m err) (M.load-file file-path)]
        (if (and (not err) (= (type m) :table)) m {}))
      {}))

(fn M.entry-module-of [manifest]
  (?. manifest :entry-module))

(fn M.entry-of [manifest]
  (?. manifest :entry))

(fn M.interactive-only? [manifest]
  (or (?. manifest :interactive-only?) false))

(fn M.presenter-of [manifest]
  (?. manifest :presenter))

(fn M.first-party? [manifest]
  (or (?. manifest :first-party?) false))

(fn M.reload-modules [manifest fallback]
  (or manifest.reload-modules fallback []))

(fn M.reload-exclude [manifest]
  (or manifest.reload-exclude []))

(fn M.enabled? [spec]
  (or spec.explicit?
      spec.project-local?
      spec.first-party?
      (= spec.manifest.enabled-by-default true)))

(fn M.entry-register [entry]
  "Return the register fn from an extension entry: the entry itself when it is
   a function, else its :register field. Nil when the entry has neither."
  (if (= (type entry) :function) entry
      (= (type entry) :table) entry.register
      nil))

(fn M.requires-modules [manifest]
  (or (?. manifest :requires-modules) []))

(fn M.requires-shared-libs [manifest]
  (or (?. manifest :requires-shared-libs) []))

(fn M.missing-requires-modules [manifest]
  "Return all manifest-declared Lua modules that cannot be required."
  (let [missing []]
    (each [_ mod (ipairs (M.requires-modules manifest))]
      (let [(ok? _err) (pcall require mod)]
        (when (not ok?)
          (table.insert missing (tostring mod)))))
    missing))

M
