;; Swap point for the manifest-enumeration seam: replace this module (or pre-populate
;; package.loaded) to inject an alternate `enumerate`; discover applies shared dedupe/version
;; annotations on top. Mirrors fen.util.path.backend / fen.util.process.backend.

(require :fen.core.extensions.loader.discover.backends.posix)
