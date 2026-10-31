(local state (require :fen.core.extensions.state))

(local M {})

(fn M.bump-registry-version! []
  "Called once per registry view rebuild (fen.core.extensions.contrib). List
   memoization compares this counter; a stale bump is harmless, a missed
   bump serves stale lists, so every bucket mutation flows through contrib."
  (set state.registry-version (+ (or state.registry-version 0) 1)))

;; @doc fen.core.extensions.util.deep-copy
;; kind: function
;; signature: (deep-copy v) -> any
;; summary: Recursively copy Lua tables so extension registry records cannot mutate caller-owned contribution specs.
;; tags: extensions registry util
(fn M.deep-copy [v]
  (if (= (type v) :table)
      (let [out {}]
        (each [k vv (pairs v)]
          (tset out k (M.deep-copy vv)))
        out)
      v))

(fn M.freeze [t]
  "Read-only recursive proxy. Existing keys and nested tables reject writes."
  (fn freeze-value [v]
    (if (= (type v) :table)
        (let [copy (M.deep-copy v)
              proxy {}]
          (each [k vv (pairs copy)]
            (tset copy k (freeze-value vv)))
          (setmetatable proxy
                        {:__index copy
                         :__len (fn [_] (length copy))
                         :__pairs (fn [_] (pairs copy))
                         :__newindex (fn [_ k _]
                                       (error (.. "frozen: cannot set "
                                                  (tostring k))))
                         :__metatable false})
          proxy)
        v))

  (freeze-value t))

;; @doc fen.core.extensions.util.clear-table
;; kind: function
;; signature: (clear-table t) -> nil
;; summary: Delete every key from an existing table so long-lived state table identity survives reloads and resets.
;; tags: extensions reload state
(fn M.clear-table [t]
  (var cleared? false)
  (each [k _ (pairs t)]
    (tset t k nil)
    (set cleared? true))
  (when cleared?
    (M.bump-registry-version!)))

M
