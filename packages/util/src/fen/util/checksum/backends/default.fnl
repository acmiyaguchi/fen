;; Default fingerprint backend: package.searchpath + io.open; not cryptographic; modules from custom package.searchers are invisible (nil forces reload-all).

;; @doc fen.util.checksum.backends.default.file-fingerprint
;; kind: function
;; signature: (file-fingerprint path) -> table|nil
;; summary: Compute a small non-cryptographic checksum/size fingerprint for a file via io.open, used by reload-change diagnostics.
;; tags: util checksum reload backend
(fn file-fingerprint [path]
  (let [(f _err) (io.open path :rb)]
    (when f
      ;; Native string compare beats a per-byte Lua checksum loop; overlays are small enough to snapshot whole.
      (let [contents (f:read "*a")]
        (f:close)
        (when contents
          {:path path :size (length contents)
           :fingerprint contents})))))

(var fnl-path-cache nil)

(fn fnl-path-from-lua-path [lua-path]
  "Build the .fnl analogue of package.path used by fen's dev-path searcher.
   Memoized on the last package.path since reload fingerprints every module."
  (if (and fnl-path-cache (= fnl-path-cache.lua-path lua-path))
      fnl-path-cache.fnl-path
      (let [parts []]
        (each [seg (string.gmatch (or lua-path "") "([^;]+)")]
          (when (= (string.sub seg -4) ".lua")
            (table.insert parts (.. (string.sub seg 1 -5) ".fnl"))))
        (let [fnl-path (table.concat parts ";")]
          (set fnl-path-cache {:lua-path lua-path :fnl-path fnl-path})
          fnl-path))))

(fn split-colon [s]
  (let [out []]
    (each [part (string.gmatch (or s "") "([^:]+)")]
      (table.insert out part))
    out))

(var flat-map-cache nil)

(fn flat-extension-path [modname]
  "Resolve first-party flat extension sources installed by FEN_EXTENSION_ROOT.
   These modules are found by a custom package.searchers entry, not by
   package.path, so package.searchpath cannot see them. The manifest walk is
   memoized per roots value and rebuilt on a miss, so reload diagnostics do
   not rescan the whole tree for every module yet still see new extensions."
  (when (string.match (tostring modname) "^fen%.extensions%.")
    (let [env (os.getenv :FEN_FIRST_PARTY_EXTENSIONS_PATH)
          roots (split-colon env)]
      (when (> (length roots) 0)
        (let [flat (require :fen.util.flat_extensions)
              name (tostring modname)
              cached (and flat-map-cache (= flat-map-cache.env env)
                          (flat.resolve-fnl flat-map-cache.map name))]
          (or cached
              (let [map (flat.build-map roots)]
                (set flat-map-cache {:env env :map map})
                (flat.resolve-fnl map name))))))))

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
