;; Extension manifest reading + entry-file loading.
;;
;; A manifest is a small Lua/Fennel table describing an extension's name,
;; reload behavior, dependencies, and the entry module. This file owns the
;; mechanics of finding manifest.{fnl,lua} / init.{fnl,lua} on disk, loading
;; the entry's exports, and answering manifest-shaped questions like
;; `enabled?` or `missing-deps`.
;;
;; loader.fnl, loader/discover.fnl, and loader/reload.fnl all read from here.

(local path (require :util.path))

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

(fn M.read-manifest-module [modname]
  (if modname
      (let [(ok? m) (pcall require modname)]
        (if (and ok? (= (type m) :table)) m {}))
      {}))

(fn M.reload-modules [manifest fallback]
  (or manifest.reload-modules
      manifest.reloadModules
      fallback
      []))

(fn M.reload-exclude [manifest]
  (or manifest.reload-exclude
      manifest.reloadExclude
      []))

(fn M.enabled? [spec]
  (or spec.explicit?
      (= spec.manifest.enabled-by-default true)))

(fn M.entry-register [entry]
  "An extension entry is either a register function or a table with :register."
  (if (= (type entry) :function) entry
      (= (type entry) :table) entry.register
      nil))

(fn command-output-line [cmd]
  (let [p (io.popen cmd)]
    (when p
      (let [out (p:read :*l)]
        (p:close)
        out))))

(fn command-exists? [cmd]
  (= (command-output-line
       (.. "command -v " (path.shell-quote cmd) " >/dev/null 2>&1 && printf yes"))
     "yes"))

(fn M.missing-deps [manifest]
  "Return a list of unsatisfied requires from the manifest, tagged by kind."
  (let [missing []
        req (or manifest.requires {})
        lua-req (or req.lua [])
        bin-req (or req.bin [])]
    (each [_ mod (ipairs lua-req)]
      (let [(ok? _err) (pcall require mod)]
        (when (not ok?)
          (table.insert missing (.. "lua:" (tostring mod))))))
    (each [_ bin (ipairs bin-req)]
      (when (not (command-exists? bin))
        (table.insert missing (.. "bin:" (tostring bin)))))
    missing))

M
