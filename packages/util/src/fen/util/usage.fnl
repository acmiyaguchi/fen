;; Canonical token-usage field list and accumulation arithmetic.
;;
;; Consolidated from the subagent behavior (`init.fnl`, `state.fnl`) and the TUI
;; presenters (`workspaces.fnl`, `side_chat.fnl`), which had copy-pasted the
;; field list, add/subtract/accumulate helpers, and total-derivation guards
;; (issue #449). This is a pure consolidation: behavior is unchanged. Callers
;; resolve these functions at call time (`usage.fn`) to stay hot-reload safe.

(local M {})

;; @doc fen.util.usage.USAGE-FIELDS
;; kind: value
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

;; @doc fen.util.usage.canonical-usage
;; kind: function
;; signature: (canonical-usage usage) -> Usage|nil
;; summary: Extract canonical token fields from a provider usage table, tolerating Fennel-cased and provider snake_case keys and ignoring non-token fields; returns nil when nothing usable is present.
;; tags: usage tokens
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

;; @doc fen.util.usage.usage-provenance
;; kind: function
;; signature: (usage-provenance usage ?source) -> {keyword source}
;; summary: Per-field provenance for a usage table; reported fields take ?source (default :provider-reported) and a total derived from input+output is flagged :estimated.
;; tags: usage tokens provenance
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

;; @doc fen.util.usage.add-usage
;; kind: function
;; signature: (add-usage a b) -> Usage
;; summary: Field-wise sum of two canonical usage tables, keeping only positive totals.
;; tags: usage tokens
(fn M.add-usage [a b]
  (let [out {}]
    (each [_ k (ipairs USAGE-FIELDS)]
      (let [s (+ (or (and a (. a k)) 0) (or (and b (. b k)) 0))]
        (when (> s 0) (tset out k s))))
    out))

;; @doc fen.util.usage.subtract-usage
;; kind: function
;; signature: (subtract-usage a b) -> Usage
;; summary: Field-wise difference of two canonical usage tables, keeping only positive results.
;; tags: usage tokens
(fn M.subtract-usage [a b]
  (let [out {}]
    (each [_ k (ipairs USAGE-FIELDS)]
      (let [d (- (or (and a (. a k)) 0) (or (and b (. b k)) 0))]
        (when (> d 0) (tset out k d))))
    out))

;; @doc fen.util.usage.merge-provenance
;; kind: function
;; signature: (merge-provenance prior blob-prov fields) -> {keyword source}
;; summary: Merge two provenance tables over a field set, treating any :estimated contribution as sticky.
;; tags: usage tokens provenance
(fn M.merge-provenance [prior blob-prov fields]
  (let [out {}]
    (each [k _ (pairs (or fields {}))]
      (let [p (or (. blob-prov k) (. prior k) :provider-reported)]
        (tset out k (if (or (= (. blob-prov k) :estimated)
                            (= (. prior k) :estimated))
                        :estimated
                        p))))
    out))

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
;; summary: Shallow-copy a run usage accumulator (totals/current/provenance plus scalar turns/source), or nil.
;; tags: usage tokens
(fn M.copy-usage-acc [acc]
  (when acc
    {:totals (shallow-copy acc.totals)
     :current (shallow-copy acc.current)
     :provenance (shallow-copy acc.provenance)
     :turns acc.turns
     :source acc.source}))

M
