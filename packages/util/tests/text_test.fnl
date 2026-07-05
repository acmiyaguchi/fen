(local text-util (require :fen.util.text))

(fn raw-unsafe-count [s]
  (var n 0)
  (for [i 1 (length s)]
    (let [b (string.byte s i)]
      (when (or (and (< b 32) (not (or (= b 9) (= b 10) (= b 13))))
                (= b 127))
        (set n (+ n 1)))))
  n)

(describe "util.text"
  (fn []
    (it "truncates lines with an ellipsis when over budget"
      (fn []
        (assert.are.equal "hello" (text-util.truncate-line "hello" 5))
        (assert.are.equal "hel…" (text-util.truncate-line "hello" 4))
        (assert.are.equal "…" (text-util.truncate-line "hello" 1))
        (assert.are.equal "…" (text-util.truncate-line "hello" 0))))

    (it "leaves clean ASCII and allowed whitespace unchanged"
      (fn []
        (let [s "hello\nthere\tfriend\r\n"
              out (text-util.scrub-tool-text s {:max-bytes 100})]
          (assert.are.equal s out.text)
          (assert.is_false out.changed?)
          (assert.is_nil out.note))))

    (it "preserves valid UTF-8 text"
      (fn []
        (let [s (.. "snowman " (string.char 226 152 131) " emoji "
                    (string.char 240 159 152 128))
              out (text-util.scrub-tool-text s {:max-bytes 100})]
          (assert.are.equal s out.text)
          (assert.is_false out.changed?))))

    (it "escapes NUL, C0 controls, and DEL as visible ASCII"
      (fn []
        (let [s (.. "a" (string.char 0) "b" (string.char 5) "c"
                    (string.char 127) "d")
              out (text-util.scrub-tool-text s {:max-bytes 100})]
          (assert.is_true out.changed?)
          (assert.are.equal 3 out.unsafe-count)
          (assert.are.equal 0 (raw-unsafe-count out.text))
          (assert.is_truthy (string.find out.text "\\x00" 1 true))
          (assert.is_truthy (string.find out.text "\\x05" 1 true))
          (assert.is_truthy (string.find out.text "\\x7F" 1 true))
          (assert.is_truthy (string.find out.text "tool output sanitized" 1 true)))))

    (it "escapes invalid UTF-8 bytes"
      (fn []
        (let [s (.. "a" (string.char 255) "b" (string.char 128) "c")
              out (text-util.scrub-tool-text s {:max-bytes 100})]
          (assert.is_true out.changed?)
          (assert.are.equal 2 out.invalid-count)
          (assert.are.equal 0 (raw-unsafe-count out.text))
          (assert.is_truthy (string.find out.text "\\xFF" 1 true))
          (assert.is_truthy (string.find out.text "\\x80" 1 true)))))

    (it "escapes valid UTF-8 C1 control codepoints"
      (fn []
        ;; U+0085 encoded as C2 85 should not cross the provider boundary.
        (let [s (.. "a" (string.char 194 133) "b")
              out (text-util.scrub-tool-text s {:max-bytes 100})]
          (assert.is_true out.changed?)
          (assert.are.equal 1 out.unsafe-count)
          (assert.is_truthy (string.find out.text "\\x85" 1 true)))))

    (it "caps oversized text without splitting UTF-8"
      (fn []
        (let [s (.. "abc" (string.char 226 152 131) "defghij")
              out (text-util.scrub-tool-text s {:max-bytes 6})]
          ;; 3 ASCII bytes + one 3-byte snowman fit exactly; the following d
          ;; does not fit in the kept prefix.
          (assert.is_true out.truncated?)
          (assert.are.equal (.. "abc" (string.char 226 152 131))
                            (string.sub out.text 1 6))
          (assert.is_truthy (string.find out.text "tool output truncated" 1 true))
          (assert.is_truthy (string.find out.text "kept 6" 1 true)))))))
