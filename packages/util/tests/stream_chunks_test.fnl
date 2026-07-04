(local chunks (require :fen.util.stream_chunks))

(describe "fen.util.stream_chunks"
  (fn []
    (it "appends deltas without mutating the public string until materialized"
      (fn []
        (let [rec {:text "he"}]
          (chunks.append! rec :text :text-chunks "ll")
          (chunks.append! rec :text :text-chunks "o")
          (assert.are.equal "he" rec.text)
          (assert.are.equal "hello" (chunks.value rec :text :text-chunks))
          (assert.are.equal "hello" (chunks.materialize! rec :text :text-chunks))
          (assert.are.equal "hello" rec.text)
          (assert.is_nil rec.text-chunks))))

    (it "replaces pending chunks with final values"
      (fn []
        (let [rec {:partial "{"}]
          (chunks.append! rec :partial :partial-chunks "\"x\"")
          (assert.are.equal "{\"x\"" (chunks.value rec :partial :partial-chunks))
          (assert.are.equal "{}" (chunks.set! rec :partial :partial-chunks "{}"))
          (assert.are.equal "{}" rec.partial)
          (assert.is_nil rec.partial-chunks))))))
