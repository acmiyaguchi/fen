;; Default fingerprint backend for fen.util.checksum.
;;
;; Small pure-Lua file/module fingerprint helpers for reload diagnostics.
;; Not cryptographic. The checksum only needs to answer "did this runtime file
;; differ from the snapshot we saw before?" without shelling out.
;;
;; This is the seam's default backend (see fen.util.checksum.backend). It
;; resolves a module to its on-disk source via package.searchpath + io.open,
;; exactly as before. Modules loaded through a custom package.searchers entry
;; (a host's in-VM compiler) are invisible to searchpath, so module-fingerprint
;; returns nil for them and the reload loader is forced to reload-all every
;; time. A host with such a loader ships a different backend module whose
;; module-fingerprint supplies a version/etag, restoring change detection.
;; Mirrors fen.util.path.backend / fen.util.clock.backend: one mechanism, the
;; injectable backend, with the current io.open/searchpath behavior as default.

;; @doc fen.util.checksum.backends.default.file-fingerprint
;; kind: function
;; signature: (file-fingerprint path) -> table|nil
;; summary: Compute a small non-cryptographic checksum/size fingerprint for a file via io.open, used by reload-change diagnostics.
;; tags: util checksum reload backend
(fn file-fingerprint [path]
  (let [(f _err) (io.open path :rb)]
    (when f
      ;; Reading and comparing Lua strings is implemented in native code. It is
      ;; substantially cheaper than running a Lua checksum loop for every byte,
      ;; remains exact for same-sized edits, and source overlays are small
      ;; enough for the persistent reload snapshot to retain one string each.
      (let [contents (f:read "*a")]
        (f:close)
        (when contents
          {:path path :size (length contents)
           :fingerprint contents})))))

(fn fnl-path-from-lua-path [lua-path]
  "Build the .fnl analogue of package.path used by fen's dev-path searcher."
  (let [parts []]
    (each [seg (string.gmatch (or lua-path "") "([^;]+)")]
      (when (= (string.sub seg -4) ".lua")
        (table.insert parts (.. (string.sub seg 1 -5) ".fnl"))))
    (table.concat parts ";")))

(fn split-colon [s]
  (let [out []]
    (each [part (string.gmatch (or s "") "([^:]+)")]
      (table.insert out part))
    out))

(fn flat-extension-path [modname]
  "Resolve first-party flat extension sources installed by FEN_EXTENSION_ROOT.
   These modules are found by a custom package.searchers entry, not by
   package.path, so package.searchpath cannot see them."
  (when (string.match (tostring modname) "^fen%.extensions%.")
    (let [roots (split-colon (os.getenv :FEN_FIRST_PARTY_EXTENSIONS_PATH))]
      (when (> (length roots) 0)
        (let [flat (require :fen.util.flat_extensions)
              map (flat.build-map roots)]
          (flat.resolve-fnl map (tostring modname)))))))

;; @doc fen.util.checksum.backends.default.module-path
;; kind: function
;; signature: (module-path modname) -> string|nil
;; summary: Resolve a module name through package.path or its .fnl dev-path analogue so reload diagnostics can fingerprint the active source file.
;; tags: util checksum modules backend
(fn module-path [modname]
  (let [name (tostring modname)
        (lua-path _lua-err) (package.searchpath name package.path)]
    (or lua-path
        (let [fnl-search-path (fnl-path-from-lua-path package.path)
              (fnl-path _fnl-err) (package.searchpath name fnl-search-path)]
          (or fnl-path
              (flat-extension-path name))))))

;; @doc fen.util.checksum.backends.default.module-fingerprint
;; kind: function
;; signature: (module-fingerprint modname) -> table|nil
;; summary: Resolve and fingerprint a Lua module source file via searchpath+io.open, returning nil when the module has no discoverable source file.
;; tags: util checksum modules reload backend
(fn module-fingerprint [modname]
  (let [path (module-path modname)]
    (when path
      (file-fingerprint path))))

{:file-fingerprint file-fingerprint
 :module-path module-path
 :module-fingerprint module-fingerprint}
