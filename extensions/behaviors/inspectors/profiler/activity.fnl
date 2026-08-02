;; Reloadable, private semantic annotations for the opt-in profiler.
;; State retains only bounded records and never captures this module's behavior.

(local state (require :fen.extensions.profiler.state))

(local M {})

(fn M.enabled? [] state.enabled?)

(fn M.span-begin! [name ?metadata]
  (when state.enabled? (state.span-begin! name ?metadata)))

(fn M.span-end! [token]
  (when state.enabled? (state.span-end! token)))

(fn M.activity! [name ?metadata]
  (when state.enabled?
    (let [token (M.span-begin! name ?metadata)]
      (when token (M.span-end! token))
      token)))

(fn M.counter-add! [name ?amount]
  (when state.enabled? (state.counter-add! name ?amount)))

M
