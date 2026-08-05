;; Default (native) CSPRNG backend for fen.util.random.
;;
;; Thin Fennel binding over the project-owned `fen_random.so` C module. The C
;; side handles platform dispatch (getrandom on Linux, arc4random_buf on
;; macOS/BSD, BCryptGenRandom on Windows); this file just re-exports `bytes` so
;; callers can pull crypto-random byte strings without thinking about the
;; underlying API.
;;
;; This is the seam's default backend (see fen.util.random.backend). Keeping the
;; fen_random behavior here means the injectable seam changes nothing about
;; default CLI behavior; a host lacking fen_random supplies its own backend
;; exposing the same surface: bytes.

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
