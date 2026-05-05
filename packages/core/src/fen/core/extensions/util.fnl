(local M {})

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
                         :__newindex
                         (fn [_ k _]
                           (error (.. "frozen: cannot set " (tostring k))))
                         :__metatable false})
          proxy)
        v))
  (freeze-value t))

(fn M.remove-where [t pred]
  "Mutate `t` in place, dropping entries where `(pred entry index)` is true."
  (for [i (length t) 1 -1]
    (when (pred (. t i) i)
      (table.remove t i))))

(fn M.clear-table [t]
  (each [k _ (pairs t)] (tset t k nil)))

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
