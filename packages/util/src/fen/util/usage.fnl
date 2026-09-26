;; Canonical token-usage fields and arithmetic (consolidated, #449); resolve via `usage.fn` at call time for reload safety.

(local M {})

;; @doc fen.util.usage.USAGE-FIELDS
;; kind: constant
;; signature: USAGE-FIELDS -> [keyword]
;; summary: Canonical token fields in display order; `total-tokens` conventionally excludes cache tokens (input+output), matching provider adapters.
;; tags: usage tokens
(local USAGE-FIELDS [:input :output :cache-read :cache-write :reasoning
                     :total-tokens])
(set M.USAGE-FIELDS USAGE-FIELDS)

(fn num [v]
  (and (= (type v) :number) v))

(fn shallow-copy [t]
  (let [out {}]
    (when (= (type t) :table)
      (each [k v (pairs t)] (tset out k v)))
    out))

(fn pick [usage keys]
  (var found nil)
  (each [_ k (ipairs keys)]
    (when (= found nil)
      (let [v (num (. usage k))]
        (when v (set found v)))))
  found)

(fn M.canonical-usage [usage]
  "Extract canonical token fields from a provider usage table, tolerating both
   Fennel-cased and provider snake_case keys. Returns a table with any present
   numeric fields plus a derived total, or nil when nothing usable is present.
   Non-token fields such as latency-ms are intentionally ignored."
  (when (= (type usage) :table)
    (let [input (pick usage [:input :input_tokens :input-tokens
                             :prompt_tokens :prompt-tokens])
          output (pick usage [:output :output_tokens :output-tokens
                              :completion_tokens :completion-tokens])
          cache-read (pick usage [:cache-read :cache_read :cached_tokens
                                  :cache_read_input_tokens])
          cache-write (pick usage [:cache-write :cache_write
                                   :cache_creation_input_tokens])
          reasoning (pick usage [:reasoning :reasoning_tokens :reasoning-tokens])
          reported-total (pick usage [:total-tokens :total_tokens :total])
          total (or reported-total
                    (when (or input output)
                      (+ (or input 0) (or output 0))))
          out {}]
      (when input (set out.input input))
      (when output (set out.output output))
      (when cache-read (set out.cache-read cache-read))
      (when cache-write (set out.cache-write cache-write))
      (when reasoning (set out.reasoning reasoning))
      (when total (set out.total-tokens total))
      (when (next out) out))))

;; @doc fen.util.usage.explicit-total?
;; kind: function
;; signature: (explicit-total? usage) -> boolean
;; summary: True when a usage table carries an explicit provider-reported total (not one derived from input+output).
;; tags: usage tokens
(fn M.explicit-total? [usage]
  (and (= (type usage) :table)
       (not= nil (pick usage [:total-tokens :total_tokens :total]))))

(fn M.usage-provenance [usage ?source]
  "Per-field provenance for a usage table. Reported fields take ?source (default
   :provider-reported); a total we had to derive from input+output is flagged
   :estimated."
  (let [canon (M.canonical-usage usage)
        source (or ?source :provider-reported)
        prov {}]
    (when canon
      (each [k _ (pairs canon)] (tset prov k source))
      (when (and (. canon :total-tokens) (not (M.explicit-total? usage)))
        (tset prov :total-tokens :estimated)))
    prov))

;; @doc fen.util.usage.add-usage!
;; kind: function
;; signature: (add-usage! totals usage) -> nil
;; summary: Accumulate the numeric canonical fields of a provider usage report into a mutable totals table; does not derive total-tokens.
;; tags: usage tokens
(fn M.add-usage! [totals usage]
  (when (= (type usage) :table)
    (each [_ k (ipairs USAGE-FIELDS)]
      (let [v (num (. usage k))]
        (when v (tset totals k (+ (or (. totals k) 0) v)))))))

;; @doc fen.util.usage.ensure-total!
;; kind: function
;; signature: (ensure-total! totals) -> totals
;; summary: Derive total-tokens in place from input+output when absent; returns the totals table.
;; tags: usage tokens
(fn M.ensure-total! [totals]
  (when (and totals
             (not (. totals :total-tokens))
             (or totals.input totals.output))
    (set totals.total-tokens (+ (or totals.input 0) (or totals.output 0))))
  totals)

;; @doc fen.util.usage.usage-total
;; kind: function
;; signature: (usage-total usage) -> number|nil
;; summary: Total tokens for a usage table, preferring a reported total-tokens and otherwise deriving input+output; nil when unusable.
;; tags: usage tokens
(fn M.usage-total [usage]
  (when usage
    (or (num (. usage :total-tokens))
        (and (or (num usage.input) (num usage.output))
             (+ (or (num usage.input) 0) (or (num usage.output) 0))))))

;; @doc fen.util.usage.copy-usage-acc
;; kind: function
;; signature: (copy-usage-acc acc) -> acc|nil
;; summary: Shallow-copy a run usage accumulator (totals/provenance plus scalar turns/source), or nil.
;; tags: usage tokens
(fn M.copy-usage-acc [acc]
  (when acc
    {:totals (shallow-copy acc.totals)
     :provenance (shallow-copy acc.provenance)
     :turns acc.turns
     :source acc.source}))

M
