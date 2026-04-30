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
                          (base64.decode-standard "YW55IGNhcm5hbCBwbGVhc3Vy"))))))
