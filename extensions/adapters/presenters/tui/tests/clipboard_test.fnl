;; Tests for OSC 52 clipboard export.

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)

(local base64 (require :fen.util.base64))
(local clipboard (require :fen.extensions.tui.clipboard))

(describe "tui clipboard OSC 52"
  (fn []
    (var saved-write clipboard.write!)
    (var saved-max clipboard.max-bytes)
    (before_each (fn []
                   (set clipboard.write! saved-write)
                   (set clipboard.max-bytes saved-max)))
    (after_each (fn []
                  (set clipboard.write! saved-write)
                  (set clipboard.max-bytes saved-max)))

    (it "builds a BEL-terminated OSC 52 set-clipboard sequence"
      (fn []
        (let [seq (clipboard.osc52 "hello")]
          (assert.are.equal (.. "\27]52;c;" (base64.encode-standard "hello") "\a")
                            seq))))

    (it "returns nil for empty text"
      (fn []
        (assert.is_nil (clipboard.osc52 ""))))

    (it "returns nil when over the byte cap"
      (fn []
        (set clipboard.max-bytes 4)
        (assert.is_nil (clipboard.osc52 "hello"))))

    (it "copies through the injectable writer and reports bytes"
      (fn []
        (var captured nil)
        (set clipboard.write! (fn [s] (set captured s)))
        (let [result (clipboard.copy "abc")]
          (assert.is_true result.ok?)
          (assert.are.equal 3 result.bytes)
          (assert.are.equal (clipboard.osc52 "abc") captured))))

    (it "skips empty selections without writing"
      (fn []
        (var wrote? false)
        (set clipboard.write! (fn [_] (set wrote? true)))
        (let [result (clipboard.copy "")]
          (assert.is_false result.ok?)
          (assert.are.equal :empty result.reason)
          (assert.is_false wrote?))))

    (it "refuses oversized selections without writing"
      (fn []
        (set clipboard.max-bytes 2)
        (var wrote? false)
        (set clipboard.write! (fn [_] (set wrote? true)))
        (let [result (clipboard.copy "abcd")]
          (assert.is_false result.ok?)
          (assert.are.equal :too-large result.reason)
          (assert.are.equal 4 result.bytes)
          (assert.is_false wrote?))))

    (it "reports write-error when the writer throws"
      (fn []
        (set clipboard.write! (fn [_] (error "boom")))
        (let [result (clipboard.copy "abc")]
          (assert.is_false result.ok?)
          (assert.are.equal :write-error result.reason))))

    (it "round-trips utf-8 content through base64"
      (fn []
        (let [text "café ✓ 日本語"
              seq (clipboard.osc52 text)
              payload (string.match seq "^\27]52;c;(.-)\a$")]
          (assert.are.equal text (base64.decode-standard payload)))))))
