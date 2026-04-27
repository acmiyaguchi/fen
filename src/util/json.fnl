(local cjson (require :cjson))

;; cjson by default decodes [] as {} (an empty table indistinguishable from
;; an object). Setting decode_array_with_array_mt makes round-tripping arrays
;; safe — important for the OpenAI tool_calls / messages payloads.
(when cjson.decode_array_with_array_mt
  (cjson.decode_array_with_array_mt true))

{:encode cjson.encode
 :decode cjson.decode
 :null cjson.null
 ;; A sentinel table that always serializes as `[]`, never `{}`.
 ;; cjson cannot tell an empty Lua table apart from an empty array, so
 ;; payloads needing a literal `[]` (e.g. OpenAI Responses
 ;; `content[].annotations`) must use this rather than a bare `{}`.
 :empty-array cjson.empty_array}
