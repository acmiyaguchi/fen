;; Each binding below is module-level state mutated at call time.
(local cache {})
(var ready? false)
(local seen [])
(local M {})
(fn M.get [k]
  (tset cache k true)
  (set ready? true)
  #(table.insert seen k))

M
