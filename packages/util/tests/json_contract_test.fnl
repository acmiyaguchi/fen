;; Conformance suite for the cjson API surface that fen.util.json depends on.
;;
;; This exercises the contract documented at the top of
;; packages/util/src/fen/util/json.fnl against *whatever* cjson is loaded. An
;; embedded host substituting cjson can run this same suite against its
;; substitute (set `package.loaded.cjson` to the substitute before requiring
;; fen.util.json, or point `require :cjson` at it) to confirm it provides the
;; full required surface rather than a partial one that degrades silently. See
;; issue #470.

(local cjson (require :cjson))
(local json (require :fen.util.json))

;; fen.util.json enables array-mt decoding on load; reassert it here so the
;; suite is order-independent when a host runs it standalone.
(when cjson.decode_array_with_array_mt
  (cjson.decode_array_with_array_mt true))

(fn array? [t]
  ;; A decoded JSON array is tagged with cjson.array_mt.
  (= (getmetatable t) cjson.array_mt))

(describe "util.json cjson contract"
  (fn []

    (describe "required surface is present"
      (fn []
        (it "exposes encode/decode functions"
          (fn []
            (assert.are.equal :function (type cjson.encode))
            (assert.are.equal :function (type cjson.decode))
            (assert.are.equal :function (type json.encode))
            (assert.are.equal :function (type json.decode))))

        (it "exposes null, empty-array, and array_mt sentinels"
          (fn []
            ;; null must be a value distinct from Lua nil.
            (assert.is_not_nil json.null)
            (assert.is_not_nil cjson.null)
            (assert.is_not_nil json.empty-array)
            (assert.is_not_nil cjson.empty_array)
            (assert.are.equal :table (type cjson.array_mt))))

        (it "exposes decode_array_with_array_mt as callable" ;
          (fn []
            (assert.are.equal :function (type cjson.decode_array_with_array_mt))))))

    (describe "null sentinel"
      (fn []
        (it "is truthy, distinct from nil and false"
          (fn []
            ;; Issue #482 relies on a decoded null being truthy so callers can
            ;; use `decoded.x` for presence checks. A substitute mapping null to
            ;; nil (key vanishes) or false (reads as absent/falsey) breaks this.
            (assert.is_true (not (not json.null)))
            (assert.is_not_nil json.null)
            (assert.is_false (= json.null false))))

        (it "decodes an explicit null to a truthy present field"
          (fn []
            (let [decoded (json.decode "{\"x\":null}")]
              ;; if-decoded.x-then-present: a decoded null must take the truthy
              ;; branch, distinguishing it from a missing key.
              (assert.is_true (if decoded.x true false))
              (assert.are.equal json.null decoded.x))))

        (it "json.null? recognizes the sentinel and rejects real values"
          (fn []
            ;; The single seam #482 mandates instead of scattered
            ;; `(not= x cjson.null)` comparisons. A decoded explicit null is
            ;; the sentinel; missing keys, real values, and Lua false/nil are
            ;; not.
            (assert.are.equal :function (type json.null?))
            (assert.is_true (json.null? json.null))
            (let [decoded (json.decode "{\"x\":null,\"y\":1,\"z\":false}")]
              (assert.is_true (json.null? decoded.x))
              (assert.is_false (json.null? decoded.y))
              (assert.is_false (json.null? decoded.z))
              ;; a missing key is Lua nil, not the sentinel
              (assert.is_false (json.null? decoded.missing)))
            (assert.is_false (json.null? nil))
            (assert.is_false (json.null? false))
            (assert.is_false (json.null? 0))
            (assert.is_false (json.null? ""))))

        (it "encodes json.null as literal null"
          (fn []
            (assert.are.equal "{\"x\":null}" (json.encode {:x json.null}))))

        (it "round-trips explicit null without dropping the key"
          (fn []
            ;; The failure mode a partial substitute hits: decode makes null a
            ;; Lua nil, the key vanishes, and re-encode loses the field.
            ;; Object key order is unspecified, so re-decode and compare shape.
            (let [decoded (json.decode "{\"x\":null,\"y\":1}")]
              (assert.are.equal json.null decoded.x)
              (assert.are.equal 1 decoded.y)
              (let [reparsed (json.decode (json.encode {:x decoded.x :y decoded.y}))]
                (assert.are.equal json.null reparsed.x)
                (assert.are.equal 1 reparsed.y)))))))

    (describe "empty-array vs empty-object distinction"
      (fn []
        (it "encodes the empty-array sentinel as []"
          (fn []
            (assert.are.equal "[]" (json.encode json.empty-array))))

        (it "encodes a bare empty table as {}"
          (fn []
            (assert.are.equal "{}" (json.encode {}))))

        (it "decodes [] to an array-tagged table, not an object"
          (fn []
            (let [decoded (json.decode "[]")]
              (assert.is_true (array? decoded))
              ;; and it re-encodes back to [], never {}.
              (assert.are.equal "[]" (json.encode decoded)))))

        (it "decodes {} to a plain object table"
          (fn []
            (let [decoded (json.decode "{}")]
              (assert.is_false (array? decoded))
              (assert.are.equal "{}" (json.encode decoded)))))))

    (describe "decode raises on malformed input"
      (fn []
        ;; Callers pcall decode to recover (e.g. agent-state tool.fnl reading a
        ;; session line). A substitute returning nil instead of erroring would
        ;; make malformed data indistinguishable from a decoded JSON null.
        (it "raises rather than returning nil on malformed input"
          (fn []
            (assert.has_error (fn [] (json.decode "{not valid json")))))))

    (describe "array_mt tagging on decode"
      (fn []
        (it "tags non-empty decoded arrays"
          (fn []
            (let [decoded (json.decode "[1,2,3]")]
              (assert.is_true (array? decoded))
              (assert.are.equal 3 (length decoded))
              (assert.are.equal "[1,2,3]" (json.encode decoded)))))

        (it "encodes a table carrying array_mt as an array"
          (fn []
            (let [t (setmetatable {} cjson.array_mt)]
              (assert.are.equal "[]" (json.encode t)))))))

    (describe "nested structures round-trip"
      (fn []
        (it "preserves array/object shapes through decode then encode"
          (fn []
            ;; Object key order is unspecified, so assert shape after a full
            ;; decode→encode→decode cycle rather than on the exact string.
            (let [text "{\"a\":[1,2],\"b\":{\"c\":[]},\"d\":[]}"
                  decoded (json.decode (json.encode (json.decode text)))]
              (assert.is_true (array? decoded.a))
              (assert.are.equal 2 (length decoded.a))
              (assert.is_false (array? decoded.b))
              (assert.is_true (array? decoded.b.c))
              (assert.are.equal 0 (length decoded.b.c))
              (assert.is_true (array? decoded.d))
              (assert.are.equal 0 (length decoded.d)))))))

    (describe "OpenAI tool_calls-shaped ambiguity"
      (fn []
        ;; The ambiguity json.fnl's comment names: a message whose tool_calls is
        ;; an empty array. Without array-mt decoding, `[]` decodes to `{}` and
        ;; re-encodes as an object, corrupting the OpenAI payload.
        (it "round-trips an empty tool_calls array as []"
          (fn []
            (let [text "{\"role\":\"assistant\",\"tool_calls\":[]}"
                  decoded (json.decode (json.encode (json.decode text)))]
              (assert.is_true (array? decoded.tool_calls))
              (assert.are.equal 0 (length decoded.tool_calls))
              (assert.are.equal "assistant" decoded.role))))

        (it "round-trips a populated tool_calls array"
          (fn []
            (let [text (.. "{\"tool_calls\":[{\"id\":\"call_1\","
                           "\"type\":\"function\","
                           "\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}")
                  decoded (json.decode (json.encode (json.decode text)))]
              (assert.is_true (array? decoded.tool_calls))
              (assert.are.equal 1 (length decoded.tool_calls))
              (assert.are.equal "call_1" (. decoded.tool_calls 1 :id))
              (assert.are.equal "f" (. decoded.tool_calls 1 :function :name)))))))))
