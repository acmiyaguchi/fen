;; Sentinel manifest for flake.nix#fenExtRootSmoke. The launcher walks
;; this fixture as an --extension-root and the Fennel-side searcher
;; (fen.util.flat_extensions) maps fen.extensions.sentinel_ext back to
;; sentinel-ext/init.fnl. The smoke test pairs this with a --dev-path stub
;; for fen.main that requires the sentinel and writes the marker.
{:name :sentinel_ext
 :description "Smoke test sentinel for flat-extension searcher"
 :enabled-by-default true
 :entry-module :fen.extensions.sentinel_ext}
