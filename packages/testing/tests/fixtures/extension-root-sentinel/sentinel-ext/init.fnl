;; Body that runs when the launcher's flat-extension searcher resolves
;; fen.extensions.sentinel_ext. The smoke stub fen.main `require`s this
;; module; the side-effect prints the marker and the stub then exits.
(io.write "EXT-ROOT-OK\n")
{}
