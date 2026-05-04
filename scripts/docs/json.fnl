;; Tiny JSON encoder for the generator. Intentionally minimal:
;; supports nil, boolean, number, string, sequential tables (arrays), and
;; map tables. Sequences vs maps detected by `is-array`. Raises on
;; unsupported types.
;;
;; Used instead of lua-cjson so the generator can run from a plain
;; `fennel` invocation without nix dev shell extras.

(local M {})

(fn is-array [t]
  (let [n (# t)]
    (var ok? true)
    (var keys 0)
    (each [k _ (pairs t)]
      (set keys (+ keys 1))
      (when (or (not (= (type k) "number"))
                (< k 1)
                (> k n)
                (not (= k (math.floor k))))
        (set ok? false)))
    (and ok? (= keys n) (> n 0))))

(fn empty-table? [t]
  (var n 0)
  (each [_ _ (pairs t)]
    (set n (+ n 1)))
  (= n 0))

(fn escape [s]
  (let [s (tostring s)
        out (string.gsub s "\\" "\\\\")
        out (string.gsub out "\"" "\\\"")
        out (string.gsub out "\n" "\\n")
        out (string.gsub out "\r" "\\r")
        out (string.gsub out "\t" "\\t")
        out (string.gsub out "[%c]"
                          (fn [c] (string.format "\\u%04x" (string.byte c))))]
    out))

(fn encode-value [v]
  (let [t (type v)]
    (if (= v nil) "null"
        (= t "boolean") (if v "true" "false")
        (= t "number") (tostring v)
        (= t "string") (.. "\"" (escape v) "\"")
        (= t "table")
        (if (empty-table? v) "{}"
            (is-array v)
            (let [parts []]
              (each [_ x (ipairs v)]
                (table.insert parts (encode-value x)))
              (.. "[" (table.concat parts ",") "]"))
            (let [keys []
                  parts []]
              (each [k _ (pairs v)]
                (table.insert keys (tostring k)))
              (table.sort keys)
              (each [_ k (ipairs keys)]
                (let [val (. v k)]
                  (table.insert parts
                    (.. "\"" (escape k) "\":" (encode-value val)))))
              (.. "{" (table.concat parts ",") "}")))
        (error (.. "json: unsupported type " t)))))

(set M.encode encode-value)
M
