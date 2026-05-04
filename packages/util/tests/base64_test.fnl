(local base64 (require :fen.util.base64))

(describe "util.base64"
  (fn []
    (it "decodes standard base64 with full padding"
      (fn []
        ;; "hello" → "aGVsbG8="
        (assert.are.equal "hello" (base64.decode-standard "aGVsbG8="))
        ;; "hi" → "aGk="
        (assert.are.equal "hi" (base64.decode-standard "aGk="))
        ;; "" → ""
        (assert.are.equal "" (base64.decode-standard ""))))

    (it "decodes base64url without padding"
      (fn []
        ;; "hello" → "aGVsbG8" (no `=` pad)
        (assert.are.equal "hello" (base64.decode-url "aGVsbG8"))
        ;; "subjects?" → "c3ViamVjdHM/" → url form "c3ViamVjdHM_"
        (assert.are.equal "subjects?" (base64.decode-url "c3ViamVjdHM_"))))

    (it "decodes a JSON object payload (the JWT case)"
      (fn []
        ;; Precomputed: base64url of {"sub":"u","aud":"x"}
        (let [payload-b64 "eyJzdWIiOiJ1IiwiYXVkIjoieCJ9"
              decoded (base64.decode-url payload-b64)]
          (assert.are.equal "{\"sub\":\"u\",\"aud\":\"x\"}" decoded))))

    (it "round-trips arbitrary binary across decode-standard"
      (fn []
        ;; "any carnal pleasur" → "YW55IGNhcm5hbCBwbGVhc3Vy"
        (assert.are.equal "any carnal pleasur"
                          (base64.decode-standard "YW55IGNhcm5hbCBwbGVhc3Vy"))))

    (it "encodes standard base64 with full padding"
      (fn []
        (assert.are.equal "" (base64.encode-standard ""))
        (assert.are.equal "Zg==" (base64.encode-standard "f"))
        (assert.are.equal "Zm8=" (base64.encode-standard "fo"))
        (assert.are.equal "Zm9v" (base64.encode-standard "foo"))
        (assert.are.equal "Zm9vYg==" (base64.encode-standard "foob"))
        (assert.are.equal "Zm9vYmE=" (base64.encode-standard "fooba"))
        (assert.are.equal "Zm9vYmFy" (base64.encode-standard "foobar"))))

    (it "encodes base64url without padding and with `-`/`_`"
      (fn []
        ;; subjects? has both `+` and `/` triggers; standard form is c3ViamVjdHM/
        (assert.are.equal "c3ViamVjdHM_" (base64.encode-url "subjects?"))
        ;; simple input that produces neither `+` nor `/` — just no padding
        (assert.are.equal "Zm9vYg" (base64.encode-url "foob"))))

    (it "round-trips arbitrary binary through encode-url / decode-url"
      (fn []
        (let [raw (string.char 0 1 2 3 251 252 253 254 255 128 64 32 16 8 4 2 1)]
          (assert.are.equal raw (base64.decode-url (base64.encode-url raw))))))

    (it "encode-url maps + and / to - and _"
      (fn []
        ;; bytes 0xfb 0xff 0xbf encode standard as `+/+/` (mostly)... use a known case:
        ;; bytes 0xff 0xff 0xff -> standard "////" -> url "____"
        (assert.are.equal "____"
                          (base64.encode-url (string.char 255 255 255)))
        ;; bytes 0xfb 0xef 0xff -> standard "+++/" -> url "---_"... let's test a real case
        ;; bytes 0xfb 0xff 0xbf -> standard "+/+/" -> url "-_-_"
        (assert.are.equal "-_-_"
                          (base64.encode-url (string.char 0xfb 0xff 0xbf)))))))
