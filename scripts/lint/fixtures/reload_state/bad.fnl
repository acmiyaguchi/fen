;; Each binding below is module-level state mutated at call time.
(local cache {})
(var ready? false)
(local seen [])
(local wrapped (setmetatable {} {}))
(local via-doto {})
(local queue [])
(local push #(table.insert queue 1))
(local M {})
(fn M.get [k]
  (tset cache k true)
  (set ready? true)
  (doto via-doto (tset k 1))
  #(table.insert seen k))

(fn M.wrap [k] (tset wrapped k k))
M
