;; Opt-in development statistical profiler.

(local commands (require :fen.extensions.profiler.commands))
(local state (require :fen.extensions.profiler.state))

(fn env-number [name fallback]
  (let [n (tonumber (os.getenv name))]
    (if (and n (> n 0)) n fallback)))

(fn start-from-environment! []
  (when (and (= (os.getenv :FEN_PROFILE) "1")
             (not state.env-started?))
    (set state.env-started? true)
    (state.start! {:period (env-number :FEN_PROFILE_PERIOD 25000)
                   :wall-gap-ms (env-number :FEN_PROFILE_WALL_GAP_MS 25)})))

(local M {})

(fn M.register [api]
  ;; Runs once at extension bootstrap; state owns the stable hook/data across
  ;; subsequent /reload calls.
  (start-from-environment!)
  (commands.register api)
  true)

M
