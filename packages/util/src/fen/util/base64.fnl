;; Pure-Lua base64 / base64url codec.
;;
;; Used to decode the JWT payload of a ChatGPT/Codex access token (so we
;; can extract the chatgpt_account_id claim) and to encode the PKCE
;; verifier and challenge for the Codex OAuth login flow. We deliberately
;; do not pull in luaossl or shell out to `openssl base64`: the codec is
;; short, the inputs are trusted, and adding a crypto dep for a small
;; lookup table is not the right tradeoff for a small-device target.

(local CHARS "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(local LOOKUP {})
(for [i 1 (length CHARS)]
  (tset LOOKUP (string.byte CHARS i) (- i 1)))

(local PAD-BYTE 61) ; ASCII '='

(fn lookup-byte [b]
  (or (. LOOKUP b) 0))

(fn decode-standard [s]
  "Decode a standard base64 string (with optional `=` padding) to its raw
   byte string. Invalid characters silently map to 0 — the caller has
   already screened the input shape (JWT segment, base64url-converted)."
  (let [out []
        len (length s)]
    (var i 1)
    (while (<= i (- len 3))
      (let [b1 (string.byte s i)
            b2 (string.byte s (+ i 1))
            b3 (string.byte s (+ i 2))
            b4 (string.byte s (+ i 3))
            v1 (lookup-byte b1)
            v2 (lookup-byte b2)
            v3 (if (= b3 PAD-BYTE) 0 (lookup-byte b3))
            v4 (if (= b4 PAD-BYTE) 0 (lookup-byte b4))
            n (+ (* v1 262144) (* v2 4096) (* v3 64) v4)]
        (table.insert out (string.char (math.floor (/ n 65536))))
        (when (not= b3 PAD-BYTE)
          (table.insert out (string.char (% (math.floor (/ n 256)) 256))))
        (when (and (not= b3 PAD-BYTE) (not= b4 PAD-BYTE))
          (table.insert out (string.char (% n 256)))))
      (set i (+ i 4)))
    (table.concat out)))

(fn decode-url [s]
  "Decode a base64url string (no padding required, uses `-` and `_`)
   to its raw byte string."
  (when s
    (let [step1 (string.gsub s "%-" "+")
          step2 (string.gsub step1 "_" "/")
          rem (% (length step2) 4)
          padding (if (= rem 0) "" (string.rep "=" (- 4 rem)))]
      (decode-standard (.. step2 padding)))))

(fn char-at [index]
  (string.sub CHARS (+ index 1) (+ index 1)))

(fn encode-standard [bytes]
  "Encode a raw byte string as standard base64 with `=` padding."
  (let [out []
        len (length bytes)
        full (math.floor (/ len 3))]
    (for [block 0 (- full 1)]
      (let [i (+ (* block 3) 1)
            b1 (string.byte bytes i)
            b2 (string.byte bytes (+ i 1))
            b3 (string.byte bytes (+ i 2))
            n (+ (* b1 65536) (* b2 256) b3)]
        (table.insert out (char-at (math.floor (/ n 262144))))
        (table.insert out (char-at (% (math.floor (/ n 4096)) 64)))
        (table.insert out (char-at (% (math.floor (/ n 64)) 64)))
        (table.insert out (char-at (% n 64)))))
    (let [rem (- len (* full 3))]
      (when (= rem 1)
        (let [b1 (string.byte bytes (+ (* full 3) 1))
              n (* b1 65536)]
          (table.insert out (char-at (math.floor (/ n 262144))))
          (table.insert out (char-at (% (math.floor (/ n 4096)) 64)))
          (table.insert out "==")))
      (when (= rem 2)
        (let [b1 (string.byte bytes (+ (* full 3) 1))
              b2 (string.byte bytes (+ (* full 3) 2))
              n (+ (* b1 65536) (* b2 256))]
          (table.insert out (char-at (math.floor (/ n 262144))))
          (table.insert out (char-at (% (math.floor (/ n 4096)) 64)))
          (table.insert out (char-at (% (math.floor (/ n 64)) 64)))
          (table.insert out "="))))
    (table.concat out)))

(fn encode-url [bytes]
  "Encode a raw byte string as base64url: standard alphabet with `+`→`-`,
   `/`→`_`, and the trailing `=` padding stripped (RFC 7636 PKCE form)."
  (when bytes
    (let [std (encode-standard bytes)
          step1 (string.gsub std "%+" "-")
          step2 (string.gsub step1 "/" "_")
          step3 (string.gsub step2 "=" "")]
      step3)))

{: decode-standard
 : decode-url
 : encode-standard
 : encode-url}
