;; Read-only and load-time tables, shadowing parameters/locals, function-local
;; state, and the exported table (here returned through a literal).
(local LIMITS {:max 3})
(local setup {})
(tset setup :at-load true)
(var at-load 0)
(set at-load 1)
(local state {})
(local M {})
(fn M.get [k]
  (let [acc {}]
    (tset acc k (. LIMITS :max))
    (set M.last k)
    acc))

(fn M.shadow [state] (tset state :a 1))
(fn M.rebind []
  (let [state {}] (tset state :b 2) state))

(fn M.loop [xs]
  (each [_ state (ipairs xs)] (tset state :c 3)))

{:get M.get :shadow M.shadow :rebind M.rebind :loop M.loop}
