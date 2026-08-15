(local cjson (require :cjson))

;; Single JSON seam. Any cjson substitute MUST provide the full surface; a partial
;; one degrades silently (array-vs-object corruption, dropped nulls). Contract is
;; exercised by packages/util/tests/json_contract_test.fnl (#470):
;;   encode: cjson.null -> null; array_mt/empty_array -> []; empty table -> {}.
;;   decode: null -> truthy cjson.null sentinel (never nil/false, #482); arrays
;;     keep array_mt so [] re-encodes as []; malformed input must RAISE.
;;   json.null? is the one predicate for decoded-null checks: the sentinel is
;;     truthy and indexing it raises, so bare truthiness tests misfire (#482).
;;   decode_array_with_array_mt must exist and be callable.
(when cjson.decode_array_with_array_mt
  (cjson.decode_array_with_array_mt true))

(fn null? [value]
  "True iff `value` is the decoded JSON null sentinel (cjson.null). The
   sentinel is truthy and errors when indexed, so callers that must treat an
   explicit JSON null as absent route the check through this one predicate
   instead of scattering `(not= x cjson.null)` comparisons. See issue #482."
  (= value cjson.null))

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
;; @doc fen.util.json.null?
;; kind: function
;; signature: (null? value) -> boolean
;; summary: True when value is the decoded JSON null sentinel (cjson.null); the single seam for treating an explicit JSON null as absent without scattering sentinel comparisons.
;; tags: util json
;; @doc fen.util.json.empty-array
;; kind: data
;; signature: cjson.empty_array
;; summary: Sentinel table that serializes as [] instead of {}, used when provider wire payloads require literal empty arrays.
;; tags: util json
{:encode cjson.encode
 :decode cjson.decode
 :null cjson.null
 :null? null?
 ;; Sentinel that always encodes as `[]`; a bare {} is indistinguishable from an empty object.
 :empty-array cjson.empty_array}
