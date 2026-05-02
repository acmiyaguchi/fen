;; Extension manifest reading + entry-file loading.
;;
;; A manifest is a small Lua/Fennel table describing an extension's name,
;; reload behavior, dependencies, and the entry module/file. This file owns
;; the mechanics of finding manifest.{fnl,lua} / init.{fnl,lua} on disk,
;; loading the entry's exports, and answering manifest-shaped questions like
;; `enabled?` or `missing-deps`.
;;
;; Manifest entry-point fields:
;;   :entry-module  — Lua module name resolved through the searcher chain.
;;                    Used by rock-shaped extensions (first-party and any
;;                    third-party that publishes through luarocks).
;;   :entry         — file path relative to the manifest dir. Used by
;;                    path-shaped extensions (project drop-ins, single-file).
;;
;; If neither is set, the loader falls back to <dir>/init.{fnl,lua} as the
;; path-shaped entry.
;;
;; loader.fnl, loader/discover.fnl, and loader/reload.fnl all read from here.

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
  (or (?. manifest :entry-module)
      (?. manifest :entryModule)))

(fn M.entry-of [manifest]
  (or (?. manifest :entry)
      (?. manifest :entryFile)))

(fn M.interactive-only? [manifest]
  (or (?. manifest :interactive-only?)
      (?. manifest :interactiveOnly)
      false))

(fn M.presenter-of [manifest]
  (?. manifest :presenter))

(fn M.first-party? [manifest]
  (or (?. manifest :first-party?)
      (?. manifest :firstParty)
      false))

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
      spec.first-party?
      (= spec.manifest.enabled-by-default true)))

(fn M.entry-register [entry]
  "An extension entry returned by dofile is either a register function or a
   table with :register. Self-registering modules return nil here and their
   side effects are assumed to have run during dofile."
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

(fn M.requires-modules [manifest]
  (or (?. manifest :requires-modules)
      (?. manifest :requiresModules)
      (?. manifest :requires :lua)
      []))

(fn M.requires-shared-libs [manifest]
  (or (?. manifest :requires-shared-libs)
      (?. manifest :requiresSharedLibs)
      []))

(fn M.missing-requires-modules [manifest]
  "Return all manifest-declared Lua modules that cannot be required."
  (let [missing []]
    (each [_ mod (ipairs (M.requires-modules manifest))]
      (let [(ok? _err) (pcall require mod)]
        (when (not ok?)
          (table.insert missing (tostring mod)))))
    missing))

(fn M.missing-deps [manifest]
  "Return legacy unsatisfied requires from the manifest, tagged by kind.
   Prefer :requires-modules for Lua dependencies; this keeps older
   :requires {:bin [...]} diagnostics working without making them the load
   gate for extension rocks."
  (let [missing []
        req (or manifest.requires {})
        bin-req (or req.bin [])]
    (each [_ bin (ipairs bin-req)]
      (when (not (command-exists? bin))
        (table.insert missing (.. "bin:" (tostring bin)))))
    missing))

M
