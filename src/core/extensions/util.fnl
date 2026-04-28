(local M {})

(fn M.deep-copy [v]
  (if (= (type v) :table)
      (let [out {}]
        (each [k vv (pairs v)]
          (tset out k (M.deep-copy vv)))
        out)
      v))

(fn M.freeze [t]
  "Read-only view: deep-copy then attach __newindex that errors on write."
  (let [copy (M.deep-copy t)]
    (when (= (type copy) :table)
      (setmetatable copy
                    {:__newindex
                     (fn [_ k _]
                       (error (.. "frozen: cannot set " (tostring k))))}))
    copy))

(fn M.remove-where [t pred]
  "Mutate `t` in place, dropping entries where `(pred entry index)` is true."
  (for [i (length t) 1 -1]
    (when (pred (. t i) i)
      (table.remove t i))))

(fn M.clear-table [t]
  (each [k _ (pairs t)] (tset t k nil)))

M
