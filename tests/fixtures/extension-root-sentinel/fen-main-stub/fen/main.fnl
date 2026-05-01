;; Stand-in for fen.main used by flake.nix#singleExtRootSmoke. When this
;; dir is passed via --dev-path and tests/fixtures/extension-root-sentinel/
;; is passed via --extension-root, the launcher should:
;;   1. Resolve fen.main here (dev-path overlay).
;;   2. Resolve fen.extensions.sentinel_ext via the flat-extension searcher
;;      installed by fen.util.flat_extensions.
;; The require side-effect prints EXT-ROOT-OK; success exit follows.
(let [(ok err) (pcall require :fen.extensions.sentinel_ext)]
  (when (not ok) (io.write (.. "EXT-ROOT-FAIL: " (tostring err) "\n")))
  (os.exit (if ok 0 1)))
