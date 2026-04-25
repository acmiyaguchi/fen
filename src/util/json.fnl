(local cjson (require :cjson))

;; cjson by default decodes [] as {} (an empty table indistinguishable from
;; an object). Setting decode_array_with_array_mt makes round-tripping arrays
;; safe — important for the OpenAI tool_calls / messages payloads.
(when cjson.decode_array_with_array_mt
  (cjson.decode_array_with_array_mt true))

{:encode cjson.encode
 :decode cjson.decode
 :null cjson.null}
