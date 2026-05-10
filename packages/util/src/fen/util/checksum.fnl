;; Small pure-Lua file/module fingerprint helpers for reload diagnostics.
;;
;; Not cryptographic. The checksum only needs to answer "did this runtime file
;; differ from the snapshot we saw before?" without shelling out.

;; @doc fen.util.checksum.file-fingerprint
;; kind: function
;; signature: (file-fingerprint path) -> table|nil
;; summary: Compute a small non-cryptographic checksum/size fingerprint for a file used by reload-change diagnostics.
;; tags: util checksum reload
(fn file-fingerprint [path]
  (let [(f _err) (io.open path :rb)]
    (when f
      (var sum 0)
      (var size 0)
      (var done? false)
      (while (not done?)
        (let [chunk (f:read 4096)]
          (if chunk
              (do
                (set size (+ size (length chunk)))
                (for [i 1 (length chunk)]
                  ;; djb2-ish rolling checksum, kept inside 32 bits so Lua's
                  ;; double number representation stays exact for our ops.
                  (set sum (% (+ (* sum 33) (string.byte chunk i)) 4294967296))))
              (set done? true))))
      (f:close)
      {:path path :size size :checksum sum
       :fingerprint (.. (tostring sum) ":" (tostring size))})))

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

;; @doc fen.util.checksum.module-path
;; kind: function
;; signature: (module-path modname) -> string|nil
;; summary: Resolve a module name through package.path or its .fnl dev-path analogue so reload diagnostics can fingerprint the active source file.
;; tags: util checksum modules
(fn module-path [modname]
  (let [name (tostring modname)
        (lua-path _lua-err) (package.searchpath name package.path)]
    (or lua-path
        (let [fnl-search-path (fnl-path-from-lua-path package.path)
              (fnl-path _fnl-err) (package.searchpath name fnl-search-path)]
          (or fnl-path
              (flat-extension-path name))))))

;; @doc fen.util.checksum.module-fingerprint
;; kind: function
;; signature: (module-fingerprint modname) -> table|nil
;; summary: Resolve and fingerprint a Lua module source file, returning nil when the module has no package.path file.
;; tags: util checksum modules reload
(fn module-fingerprint [modname]
  (let [path (module-path modname)]
    (when path
      (file-fingerprint path))))

{:file-fingerprint file-fingerprint
 :module-path module-path
 :module-fingerprint module-fingerprint}
