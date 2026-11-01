;; Module-level tables that are only read, set up at load time, or are the
;; module's own export table, plus function-local state.
(local LIMITS {:max 3})
(local setup {})
(tset setup :at-load true)
(var at-load 0)
(set at-load 1)
(local M {})
(fn M.get [k]
  (let [acc {}]
    (tset acc k (. LIMITS :max))
    (set M.last k)
    acc))

M
