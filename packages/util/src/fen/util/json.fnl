(local cjson (require :cjson))

;; Required cjson API surface (contract).
;;
;; fen.util.json is the single JSON seam shared by providers, sessions, and docs
;; tooling. Callers depend on more of lua-cjson than encode/decode. Any embedded
;; host that substitutes cjson (see docs/architecture.md, milestone
;; embedding-seams) MUST provide the full surface below; a partial substitute
;; degrades *silently* — a naive encode test passes while decode corrupts
;; array-vs-object shapes and drops explicit nulls. See issue #470.
;;
;; The contract is exercised by packages/util/tests/json_contract_test.fnl;
;; run that suite against any substitute before shipping it.
;;
;;   cjson.encode(value) -> string
;;     Serialize a Lua value to JSON. Must serialize `cjson.null` as `null`,
;;     `cjson.empty_array` (and any table carrying `cjson.array_mt`) as `[]`,
;;     and an empty plain table as `{}`.
;;
;;   cjson.decode(text) -> value
;;     Parse JSON text. `null` must decode to `cjson.null` (not Lua nil, which
;;     would silently drop the key). With array-mt decoding enabled (below),
;;     JSON arrays — including `[]` — must decode to tables carrying
;;     `cjson.array_mt` so they re-encode as arrays, never `{}`.
;;
;;   cjson.null            (sentinel)
;;     A unique value distinct from Lua nil, preserved across decode→encode so
;;     explicit JSON nulls survive round-tripping.
;;
;;   cjson.empty_array     (sentinel)
;;     A value that always encodes as `[]`, never `{}`. Used where a wire
;;     payload needs a literal empty array (e.g. OpenAI Responses
;;     `content[].annotations`).
;;
;;   cjson.array_mt        (metatable)
;;     The metatable tagging a table as a JSON array so it encodes as `[]`/`[…]`
;;     rather than an object.
;;
;;   cjson.decode_array_with_array_mt(enable)
;;     Enables tagging decoded arrays with `cjson.array_mt`. Without it, cjson
;;     decodes `[]` as `{}` (an empty table indistinguishable from an object),
;;     which corrupts round-tripping of OpenAI tool_calls / messages payloads.
;;     Substitutes that always tag arrays on decode may treat this as a no-op
;;     but must still expose it callable.
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
