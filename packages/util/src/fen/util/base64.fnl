;; Pure-Lua base64 / base64url decoder.
;;
;; Used to decode the JWT payload of a ChatGPT/Codex access token so we
;; can extract the chatgpt_account_id claim. We deliberately do not pull
;; in luaossl or shell out to `openssl base64`: the function is short,
;; the input is trusted, and adding a crypto dep for a 30-line lookup
;; table is not the right tradeoff for a small-device target.

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

{: decode-standard
 : decode-url}
