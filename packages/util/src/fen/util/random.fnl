;; Cryptographic-RNG wrapper for fen.
;;
;; Thin Fennel binding over the project-owned `fen_random.so` C module.
;; The C side handles platform dispatch (getrandom on Linux,
;; arc4random_buf on macOS/BSD, BCryptGenRandom on Windows); this file
;; just re-exports `bytes` so callers can pull crypto-random byte strings
;; without thinking about the underlying API.

(local fen-random (require :fen_random))

;; @doc fen.util.random.bytes
;; kind: function
;; signature: (bytes n) -> string
;; summary: Return n cryptographically random raw bytes from the platform RNG through the fen_random native binding.
;; tags: util random crypto
(fn bytes [n]
  "Return `n` cryptographically-random raw bytes as a Lua string. Errors
   if the OS RNG is unavailable or if `n` is non-positive / too large."
  (fen-random.bytes n))

{: bytes}
