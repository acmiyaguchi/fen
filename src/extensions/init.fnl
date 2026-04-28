;; First-party extension bootstrap.
;;
;; This is intentionally tiny until the external-extension loader lands (#15
;; Step 5). main.fnl should not know which presenter is bundled by default;
;; it asks this module to load local built-ins, and those modules register
;; themselves through core.extensions.

(local M {})

(local BUILTIN-EXTENSIONS
  [:extensions.tui])

(fn M.load-builtins! []
  (each [_ modname (ipairs BUILTIN-EXTENSIONS)]
    (require modname))
  nil)

M
