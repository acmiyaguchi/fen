;; Swap point for the config-storage seam: tests/hosts pre-load
;; package.loaded["fen.core.storage.backend"] before requiring fen.core.storage.

(require :fen.core.storage.backends.default)
