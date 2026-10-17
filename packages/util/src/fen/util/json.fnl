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
;; @doc fen.util.json.encode-deterministic
;; kind: function
;; signature: (encode-deterministic value) -> string
;; summary: Encode a Lua value to JSON with object keys sorted lexicographically for cache-friendly wire payloads.
;; tags: util json cache
(fn is-array? [t]
  (or (= t cjson.empty_array) (= (getmetatable t) cjson.array_mt)
      (let [n (length t)]
        (when (> n 0)
          (var ok? true)
          (var count 0)
          (each [k _ (pairs t)]
            (set count (+ count 1))
            (when (or (not= (type k) :number) (< k 1) (> k n)
                      (not= k (math.floor k)))
              (set ok? false)))
          (and ok? (= count n))))))

(fn encode-deterministic [v]
  (if (or (= v nil) (= v cjson.null))
      "null"
      (= v cjson.empty_array)
      "[]"
      (let [tv (type v)]
        (if (or (= tv :boolean) (= tv :number) (= tv :string))
            (cjson.encode v)
            (= tv :table)
            (if (is-array? v)
                (let [parts []]
                  (for [i 1 (length v)]
                    (table.insert parts (encode-deterministic (. v i))))
                  (.. "[" (table.concat parts ",") "]"))
                (let [keys []]
                  (each [k _ (pairs v)]
                    (table.insert keys k))
                  (table.sort keys (fn [a b] (< (tostring a) (tostring b))))
                  (let [parts []]
                    (each [_ k (ipairs keys)]
                      (table.insert parts
                                    (.. (cjson.encode (tostring k)) ":"
                                        (encode-deterministic (. v k)))))
                    (.. "{" (table.concat parts ",") "}"))))
            (error (.. "json: unsupported type: " tv))))))

;; @doc fen.util.json.empty-array
;; kind: data
;; signature: cjson.empty_array
;; summary: Sentinel table that serializes as [] instead of {}, used when provider wire payloads require literal empty arrays.
;; tags: util json
{:encode cjson.encode
 :encode-deterministic encode-deterministic
 :decode cjson.decode
 :null cjson.null
 :null? null?
 ;; Sentinel that always encodes as `[]`; a bare {} is indistinguishable from an empty object.
 :empty-array cjson.empty_array}
