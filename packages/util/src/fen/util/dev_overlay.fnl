;; Mutable source-worktree overlay support for the development helper.
;;
;; State lives in fen.core.extensions.state so it survives behavior reloads;
;; this module only owns validation and search-path/searcher mutation.

(local path (require :fen.util.path))
(local process (require :fen.util.process))
(local state (require :fen.core.extensions.state))
(local flat-extensions (require :fen.util.flat_extensions))

(local M {})

(fn path-prefix [roots suffix]
  (let [parts []]
    (each [_ root (ipairs roots)]
      (table.insert parts (.. root suffix)))
    (table.concat parts ";")))

(fn prepend [prefix existing]
  (if (= prefix "") existing (.. prefix ";" (or existing ""))))

(fn expected-roots [worktree]
  [{:label "packages/core/src" :path (.. worktree "/packages/core/src")}
   {:label "packages/util/src" :path (.. worktree "/packages/util/src")}
   {:label "packages/fen/src" :path (.. worktree "/packages/fen/src")}
   {:label "extensions" :path (.. worktree "/extensions")}])

;; @doc fen.util.dev_overlay.validate-worktree
;; kind: function
;; signature: (validate-worktree worktree) -> OverlayRoots|nil, string|nil
;; summary: Canonicalize a trusted development worktree and require its core, util, CLI, and extension source directories.
;; tags: util development reload overlay
(fn M.validate-worktree [worktree]
  (let [root (and (= (type worktree) :string)
                  (not= worktree "")
                  (or (path.pwd-physical worktree) worktree))]
    (if (or (not root) (not (path.dir-exists? root)))
        (values nil (.. "worktree is not a directory: " (tostring worktree)))
        (let [missing []]
          (each [_ item (ipairs (expected-roots root))]
            (when (not (path.dir-exists? item.path))
              (table.insert missing item.label)))
          (if (> (length missing) 0)
              (values nil
                      (.. "invalid fen worktree " root "; missing required directories: "
                          (table.concat missing ", ")))
              (values {:worktree root
                       :module-roots [(.. root "/packages/core/src")
                                      (.. root "/packages/util/src")
                                      (.. root "/packages/fen/src")]
                       :extension-root (.. root "/extensions")}
                      nil))))))

(fn snapshot-base-paths! []
  (when (not state.dev-overlay)
    (set state.dev-overlay
         {:package-path package.path
          :package-cpath package.cpath
          :fennel-path nil
          :fennel-macro-path nil
          :roots nil})))

(fn prepend-fennel-paths! [roots]
  ;; Source-checkout Fennel uses fennel.path; the single-file runtime's dev
  ;; searcher instead derives .fnl paths from package.path. Update both.
  (let [(ok? fennel) (pcall require :fennel)]
    (when ok?
      (when (= state.dev-overlay.fennel-path nil)
        (set state.dev-overlay.fennel-path fennel.path)
        (set state.dev-overlay.fennel-macro-path fennel.macro-path))
      (let [prefix (path-prefix roots "/?.fnl")
            init-prefix (path-prefix roots "/?/init.fnl")
            all-prefix (if (= prefix "") init-prefix (.. prefix ";" init-prefix))]
        ;; Keep ordinary module patterns before init patterns just as the
        ;; launcher does, and restore the pre-switch baseline on each change.
        (set fennel.path (prepend all-prefix state.dev-overlay.fennel-path))
        (set fennel.macro-path (prepend all-prefix state.dev-overlay.fennel-macro-path))))))

;; @doc fen.util.dev_overlay.switch-worktree!
;; kind: function
;; signature: (switch-worktree! worktree) -> OverlayRoots|nil, string|nil
;; summary: Validate and install a replaceable trusted worktree overlay for Lua/Fennel core modules and flat first-party extensions.
;; tags: util development reload overlay
(fn M.switch-worktree! [worktree]
  (let [(roots err) (M.validate-worktree worktree)]
    (if err
        (values nil err)
        (do
          (snapshot-base-paths!)
          (let [module-roots roots.module-roots
                lua-prefix (.. (path-prefix module-roots "/?.lua") ";"
                                (path-prefix module-roots "/?/init.lua"))
                c-prefix (.. (path-prefix module-roots "/?.so") ";"
                              (path-prefix module-roots "/?/init.so"))]
            (set package.path (prepend lua-prefix state.dev-overlay.package-path))
            (set package.cpath (prepend c-prefix state.dev-overlay.package-cpath))
            (prepend-fennel-paths! module-roots)
            (flat-extensions.install! {:roots [roots.extension-root]
                                       :tag :dev-worktree-overlay
                                       :position 2})
            ;; Discovery consumes this established launcher seam, keeping its
            ;; core runtime independent from this development-only helper.
            (process.setenv! :FEN_FIRST_PARTY_EXTENSIONS_PATH roots.extension-root)
            (set state.dev-overlay.roots roots)
            (values roots nil))))))

M
