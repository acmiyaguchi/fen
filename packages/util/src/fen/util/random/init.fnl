;; CSPRNG behind the injectable fen.util.random.backend seam; hosts supply their own `bytes`.

;; Backend resolved once at load; /reload re-requires it; tests pre-load package.loaded first.
(local backend (require :fen.util.random.backend))

(local M {})

(fn M.bytes [n]
  "Return `n` cryptographically-random raw bytes as a Lua string. Errors
   if the OS RNG is unavailable or if `n` is non-positive / too large."
  (backend.bytes n))

M
