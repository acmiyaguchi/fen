;; Cryptographic-RNG wrapper for fen.
;;
;; The random surface is routed through an injectable backend
;; (fen.util.random.backend). The default backend
;; (fen.util.random.backends.native) wraps the project-owned `fen_random.so` C
;; module, which handles platform dispatch (getrandom on Linux, arc4random_buf
;; on macOS/BSD, BCryptGenRandom on Windows). Tests and hosts swap the backend
;; by pre-loading `package.loaded["fen.util.random.backend"]` before requiring
;; this module (see fen.testing.stub-random!); a host without fen_random (WASM,
;; a runtime with its own CSPRNG) ships a different backend exposing the same
;; `bytes` surface. This mirrors the fen.util.http and fen.util.path seams: one
;; mechanism, current behavior as the default. See docs/architecture.md.

;; Resolved once at load, mirroring fen.util.http / fen.util.path. On /reload
;; the module re-requires the backend, and tests swap it by pre-loading
;; package.loaded before requiring this module.
(local backend (require :fen.util.random.backend))

(local M {})

;; @doc fen.util.random.bytes
;; kind: function
;; signature: (bytes n) -> string
;; summary: Return n cryptographically random raw bytes from the platform RNG through the injectable random backend.
;; tags: util random crypto
(fn M.bytes [n]
  "Return `n` cryptographically-random raw bytes as a Lua string. Errors
   if the OS RNG is unavailable or if `n` is non-positive / too large."
  (backend.bytes n))

M
