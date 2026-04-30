(local sse (require :fen.util.sse))

(describe "util.sse"
  (fn []
    (it "parses basic data frames"
      (fn []
        (let [events (sse.parse "data: hello\n\ndata: world\n\n")]
          (assert.are.equal 2 (length events))
          (assert.are.equal "message" (. events 1 :event))
          (assert.are.equal "hello" (. events 1 :data))
          (assert.are.equal "world" (. events 2 :data)))))

    (it "parses event names and multiline data"
      (fn []
        (let [events (sse.parse "event: response.output_text.delta\ndata: {\ndata: \"x\"\ndata: }\n\n")]
          (assert.are.equal 1 (length events))
          (assert.are.equal "response.output_text.delta" (. events 1 :event))
          (assert.are.equal "{\n\"x\"\n}" (. events 1 :data)))))

    (it "ignores comments and supports CRLF"
      (fn []
        (let [events (sse.parse ": keepalive\r\ndata: ok\r\n\r\n")]
          (assert.are.equal 1 (length events))
          (assert.are.equal "ok" (. events 1 :data)))))

    (it "preserves partial lines across chunks"
      (fn []
        (let [events []
              parser (sse.new-parser #(table.insert events $1))]
          (parser.feed "ev")
          (parser.feed "ent: x\nda")
          (parser.feed "ta: he")
          (parser.feed "llo\n\n")
          (assert.are.equal 1 (length events))
          (assert.are.equal "x" (. events 1 :event))
          (assert.are.equal "hello" (. events 1 :data)))))

    (it "flushes a final unterminated frame on finish"
      (fn []
        (let [events []
              parser (sse.new-parser #(table.insert events $1))]
          (parser.feed "data: tail")
          (parser.finish)
          (assert.are.equal 1 (length events))
          (assert.are.equal "tail" (. events 1 :data)))))

    (it "json-decodes non-DONE payloads"
      (fn []
        (let [events (sse.json-events "data: {\"x\":1}\n\ndata: [DONE]\n\n")]
          (assert.are.equal 1 (length events))
          (assert.are.equal 1 (. events 1 :x)))))))
