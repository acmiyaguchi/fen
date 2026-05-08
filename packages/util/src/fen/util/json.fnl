(local cjson (require :cjson))

;; cjson by default decodes [] as {} (an empty table indistinguishable from
;; an object). Setting decode_array_with_array_mt makes round-tripping arrays
;; safe — important for the OpenAI tool_calls / messages payloads.
(when cjson.decode_array_with_array_mt
  (cjson.decode_array_with_array_mt true))

;; @doc fen.util.json.encode
;; kind: function
;; signature: (encode value) -> string
;; summary: Encode a Lua value to JSON using the configured cjson instance shared by providers, sessions, and docs tooling.
;; tags: util json
;; @doc fen.util.json.decode
;; kind: function
;; signature: (decode text) -> any
;; summary: Decode JSON text using cjson with empty-array metadata enabled so provider payload arrays round-trip safely.
;; tags: util json
;; @doc fen.util.json.null
;; kind: data
;; signature: cjson.null
;; summary: Re-export cjson.null for callers that need to preserve explicit JSON null values in Lua tables.
;; tags: util json
;; @doc fen.util.json.empty-array
;; kind: data
;; signature: cjson.empty_array
;; summary: Sentinel table that serializes as [] instead of {}, used when provider wire payloads require literal empty arrays.
;; tags: util json
{:encode cjson.encode
 :decode cjson.decode
 :null cjson.null
 ;; A sentinel table that always serializes as `[]`, never `{}`.
 ;; cjson cannot tell an empty Lua table apart from an empty array, so
 ;; payloads needing a literal `[]` (e.g. OpenAI Responses
 ;; `content[].annotations`) must use this rather than a bare `{}`.
 :empty-array cjson.empty_array}
