;; Re-exports fen_random.so `bytes`; the C side owns platform dispatch.

(local fen-random (require :fen_random))

(local M {})

;; @doc fen.util.random.backends.native.bytes
;; kind: function
;; signature: (bytes n) -> string
;; summary: Return n cryptographically random raw bytes from the fen_random native binding.
;; tags: util random crypto native
(fn M.bytes [n]
  (fen-random.bytes n))

M
