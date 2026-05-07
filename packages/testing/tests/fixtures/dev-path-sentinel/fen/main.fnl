;; Stand-in for fen.main used by flake.nix#fenOverlaySmoke. When this dir
;; is passed via --dev-path, the launcher's overlay should resolve
;; (require :fen.main) here instead of the embedded fen.main, proving
;; that .fnl from a dev-path shadows the embedded archive.
(io.write "DEV-PATH-OK\n")
(os.exit 0)
