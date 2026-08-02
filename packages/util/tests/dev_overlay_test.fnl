;; Focused runtime worktree-overlay tests.

(local h (require :fen.testing))
(local state (require :fen.core.extensions.state))

(describe "fen.util.dev_overlay"
  (fn []
    (var tmp nil)
    (var old-path nil)
    (var old-cpath nil)
    (var old-overlay nil)
    (var old-process nil)
    (var old-flat nil)
    (var installs nil)
    (var environment nil)

    (fn make-worktree! [root]
      (each [_ dir (ipairs ["packages/core/src" "packages/util/src"
                            "packages/fen/src" "extensions"])]
        (h.write-file (.. root "/" dir "/.keep") "")))

    (before_each
      (fn []
        (set tmp (h.make-tmpdir))
        (set old-path package.path)
        (set old-cpath package.cpath)
        (set old-overlay state.dev-overlay)
        (set old-process (. package.loaded :fen.util.process))
        (set old-flat (. package.loaded :fen.util.flat_extensions))
        (set installs [])
        (set environment {})
        ;; The overlay owns search-path policy; mock its mutable seams through
        ;; package.loaded rather than changing the process search paths.
        (tset package.loaded :fen.util.process
              {:setenv! (fn [name value] (tset environment name value))})
        (tset package.loaded :fen.util.flat_extensions
              {:install! (fn [opts] (table.insert installs opts) :searcher)})
        (tset package.loaded :fen.util.dev_overlay nil)))

    (after_each
      (fn []
        (set package.path old-path)
        (set package.cpath old-cpath)
        (set state.dev-overlay old-overlay)
        (tset package.loaded :fen.util.process old-process)
        (tset package.loaded :fen.util.flat_extensions old-flat)
        (tset package.loaded :fen.util.dev_overlay nil)
        (when tmp (h.rmtree tmp))))

    (it "rejects a directory missing the required fen source roots"
      (fn []
        (let [overlay (require :fen.util.dev_overlay)
              (_roots err) (overlay.validate-worktree tmp)]
          (assert.is_truthy (string.find err "missing required directories" 1 true))
          (assert.is_truthy (string.find err "packages/core/src" 1 true))
          (assert.is_truthy (string.find err "extensions" 1 true)))))

    (it "replaces module and first-party extension overlays on each switch"
      (fn []
        (let [one (.. tmp "/one")
              two (.. tmp "/two")]
          (make-worktree! one)
          (make-worktree! two)
          (let [overlay (require :fen.util.dev_overlay)
                (first first-err) (overlay.switch-worktree! one)
                (second second-err) (overlay.switch-worktree! two)]
            (assert.is_nil first-err)
            (assert.is_nil second-err)
            (assert.are.equal (.. two "/extensions") second.extension-root)
            (assert.is_truthy (string.find package.path
                                           (.. two "/packages/core/src/?.lua") 1 true))
            (assert.is_nil (string.find package.path
                                         (.. one "/packages/core/src/?.lua") 1 true))
            (assert.are.same [two (.. two "/extensions")]
                             [second.worktree second.extension-root])
            (assert.are.equal :dev-worktree-overlay (. installs 2 :tag))
            (assert.are.same [(.. two "/extensions")]
                             (. installs 2 :roots))
            (assert.are.equal (.. two "/extensions")
                              (. environment :FEN_FIRST_PARTY_EXTENSIONS_PATH))))))))
