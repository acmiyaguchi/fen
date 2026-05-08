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

;; @doc fen.util.checksum.module-path
;; kind: function
;; signature: (module-path modname) -> string|nil
;; summary: Resolve a Lua module name through package.path so reload diagnostics can fingerprint its source file.
;; tags: util checksum modules
(fn module-path [modname]
  (let [name (tostring modname)
        (path _err) (package.searchpath name package.path)]
    path))

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
