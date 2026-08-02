;; Reloadable, private semantic annotations for the opt-in profiler.
;; State retains only bounded records and never captures this module's behavior.

(local state (require :fen.extensions.profiler.state))

(local M {})

(fn M.span-begin! [name ?metadata]
  (state.span-begin! name ?metadata))

(fn M.span-end! [token]
  (state.span-end! token))

(fn M.activity! [name ?metadata]
  (let [token (M.span-begin! name ?metadata)]
    (when token (M.span-end! token))
    token))

(fn M.counter-add! [name ?amount]
  (state.counter-add! name ?amount))

M
