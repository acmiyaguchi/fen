(local M {})

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

;; @doc fen.core.extensions.util.freeze
;; kind: function
;; signature: (freeze t) -> table
;; summary: Return a recursive read-only proxy around a copied table for safe extension-facing introspection lists.
;; tags: extensions registry introspection
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
                         :__newindex
                         (fn [_ k _]
                           (error (.. "frozen: cannot set " (tostring k))))
                         :__metatable false})
          proxy)
        v))
  (freeze-value t))

;; @doc fen.core.extensions.util.remove-where
;; kind: function
;; signature: (remove-where t pred) -> nil
;; summary: Mutate an array-like table in place, removing entries whose predicate returns true while iterating from the end.
;; tags: extensions registry util
(fn M.remove-where [t pred]
  "Mutate `t` in place, dropping entries where `(pred entry index)` is true."
  (for [i (length t) 1 -1]
    (when (pred (. t i) i)
      (table.remove t i))))

;; @doc fen.core.extensions.util.clear-table
;; kind: function
;; signature: (clear-table t) -> nil
;; summary: Delete every key from an existing table so long-lived state table identity survives reloads and resets.
;; tags: extensions reload state
(fn M.clear-table [t]
  (each [k _ (pairs t)] (tset t k nil)))

;; @doc fen.core.extensions.util.add-tagged!
;; kind: function
;; signature: (add-tagged! list spec owner) -> record, unregister-fn
;; summary: Append a deep-copied owner-tagged contribution to an array registry and return the record plus identity-based unregister closure.
;; tags: extensions registry owner
(fn M.add-tagged! [list spec owner]
  "Append a deep-copied contribution to list, tag it with core-reserved
   :__owner, and return (record, unregister-fn). Stale unregister closures are
   safe because removal is by record identity."
  (let [record (M.deep-copy spec)]
    (tset record :__owner owner)
    (table.insert list record)
    (values record
            (fn []
              (M.remove-where list (fn [entry _] (= entry record)))))))

;; @doc fen.core.extensions.util.set-tagged!
;; kind: function
;; signature: (set-tagged! dict name spec owner) -> record, unregister-fn
;; summary: Install a deep-copied owner-tagged singleton registry entry and return a stale-safe unregister closure.
;; tags: extensions registry owner
(fn M.set-tagged! [dict name spec owner]
  "Set a deep-copied singleton contribution in dict[name], tagged with
   core-reserved :__owner, and return (record, unregister-fn). Stale
   unregister closures are safe because they only remove the same record they
   installed."
  (let [record (M.deep-copy spec)]
    (tset record :__owner owner)
    (tset dict name record)
    (values record
            (fn []
              (when (= (. dict name) record)
                (tset dict name nil))))))

M
