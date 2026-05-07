(local json (require :fen.util.json))
(local tb (require :termbox2))
(local http (require :fen_http))
(local proc (require :fen_process))

(assert (= (json.encode {:ok true}) "{\"ok\":true}"))
(assert (= (type tb.version) :function))
(assert (= (type http.request) :function))
(assert (= (type proc.read) :function))

(print :FEN-NATIVE-SMOKE-OK)
