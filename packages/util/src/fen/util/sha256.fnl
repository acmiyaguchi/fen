;; Pure-Lua SHA-256 (FIPS 180-4).
;;
;; Used by the Codex PKCE login flow to compute the code challenge
;; (`SHA-256(verifier)` then base64url). We deliberately keep this
;; in pure Lua rather than pulling in luaossl: the function is small,
;; the input is a 32-byte verifier (so performance is irrelevant), and
;; staying pure-Lua keeps the static single-file binary (#71) free of
;; another linked C dependency.
;;
;; Lua 5.4 integers and bitwise operators are required.

(local K [0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5
          0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
          0xd807aa98 0x12835b01 0x243185be 0x550c7dc3
          0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
          0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc
          0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
          0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7
          0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
          0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13
          0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
          0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3
          0xd192e819 0xd6990624 0xf40e3585 0x106aa070
          0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5
          0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
          0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208
          0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2])

(local MASK32 0xFFFFFFFF)

(fn rotr [x n]
  (band MASK32 (bor (rshift x n) (lshift x (- 32 n)))))

(fn pad-message [msg]
  "Append the 1-bit, zero pad to (mod 64 = 56) bytes, then 64-bit length."
  (let [len (length msg)
        bit-len (* len 8)
        pad-needed (% (- 56 (% (+ len 1) 64)) 64)
        pad (.. "\x80" (string.rep "\0" pad-needed))
        ;; 64-bit big-endian length suffix. Lua's string.pack ">I8"
        ;; encodes an unsigned 8-byte big-endian — exactly the SHA-256
        ;; length suffix.
        len-bytes (string.pack ">I8" bit-len)]
    (.. msg pad len-bytes)))

(fn read-u32-be [msg offset]
  "Big-endian 32-bit read at 1-indexed offset."
  (let [b1 (string.byte msg offset)
        b2 (string.byte msg (+ offset 1))
        b3 (string.byte msg (+ offset 2))
        b4 (string.byte msg (+ offset 3))]
    (band MASK32 (bor (lshift b1 24) (lshift b2 16) (lshift b3 8) b4))))

(fn process-block [H msg offset]
  "Process one 512-bit (64-byte) block starting at 1-indexed offset.
   Mutates H in place."
  (let [W []]
    (for [t 1 16]
      (tset W t (read-u32-be msg (+ offset (* (- t 1) 4)))))
    (for [t 17 64]
      (let [w-15 (. W (- t 15))
            w-2 (. W (- t 2))
            s0 (bxor (rotr w-15 7) (rotr w-15 18) (rshift w-15 3))
            s1 (bxor (rotr w-2 17) (rotr w-2 19) (rshift w-2 10))]
        (tset W t (band MASK32 (+ (. W (- t 16)) s0 (. W (- t 7)) s1)))))
    (var a (. H 1))
    (var b (. H 2))
    (var c (. H 3))
    (var d (. H 4))
    (var e (. H 5))
    (var f (. H 6))
    (var g (. H 7))
    (var h (. H 8))
    (for [t 1 64]
      (let [S1 (bxor (rotr e 6) (rotr e 11) (rotr e 25))
            ch (bxor (band e f) (band (bnot e) g))
            temp1 (band MASK32 (+ h S1 ch (. K t) (. W t)))
            S0 (bxor (rotr a 2) (rotr a 13) (rotr a 22))
            maj (bxor (band a b) (band a c) (band b c))
            temp2 (band MASK32 (+ S0 maj))]
        (set h g)
        (set g f)
        (set f e)
        (set e (band MASK32 (+ d temp1)))
        (set d c)
        (set c b)
        (set b a)
        (set a (band MASK32 (+ temp1 temp2)))))
    (tset H 1 (band MASK32 (+ (. H 1) a)))
    (tset H 2 (band MASK32 (+ (. H 2) b)))
    (tset H 3 (band MASK32 (+ (. H 3) c)))
    (tset H 4 (band MASK32 (+ (. H 4) d)))
    (tset H 5 (band MASK32 (+ (. H 5) e)))
    (tset H 6 (band MASK32 (+ (. H 6) f)))
    (tset H 7 (band MASK32 (+ (. H 7) g)))
    (tset H 8 (band MASK32 (+ (. H 8) h)))))

;; @doc fen.util.sha256.digest
;; kind: function
;; signature: (digest bytes) -> string
;; summary: Compute SHA-256 for a Lua string and return the 32-byte raw digest used by PKCE challenge construction.
;; tags: util crypto sha256
(fn digest [bytes]
  "Compute SHA-256 of `bytes` (a Lua string) and return the 32 raw bytes."
  (let [H [0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
           0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19]
        padded (pad-message bytes)
        n (length padded)]
    (var offset 1)
    (while (<= offset n)
      (process-block H padded offset)
      (set offset (+ offset 64)))
    (string.pack ">I4I4I4I4I4I4I4I4"
                 (. H 1) (. H 2) (. H 3) (. H 4)
                 (. H 5) (. H 6) (. H 7) (. H 8))))

;; @doc fen.util.sha256.hex-digest
;; kind: function
;; signature: (hex-digest bytes) -> string
;; summary: Compute SHA-256 for a Lua string and return the lowercase 64-character hexadecimal digest.
;; tags: util crypto sha256
(fn hex-digest [bytes]
  "Return the SHA-256 of `bytes` as a 64-char lowercase hex string."
  (let [raw (digest bytes)
        out []]
    (for [i 1 (length raw)]
      (table.insert out (string.format "%02x" (string.byte raw i))))
    (table.concat out)))

{: digest
 : hex-digest}
