;; Generic system prompt assembly.
;;
;; Policy-specific prompt text is contributed by extensions through ordered
;; system-prompt fragments. Core only builds the render context and joins the
;; rendered fragments.

(local extensions (require :fen.core.extensions))

(local M {})

(fn current-date []
  (os.date "%Y-%m-%d"))

(fn M.build-context [opts loader tools]
  (let [opts (or opts {})
        loader (or loader {})
        date (or opts.current-date (current-date))
        cwd (or loader.cwd ".")]
    {:opts opts
     :loader loader
     :tools (or tools [])
     :current-date date
     :cwd cwd}))

(fn M.build [opts loader tools]
  (or (extensions.render-prompt (M.build-context opts loader tools))
      ""))

M
