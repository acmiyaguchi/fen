;; Which core modules /reload refreshes in place. Pure and dependency-free so
;; the reload loader and the static lint (scripts/lint) share one definition.

(local M {})

;; Persistent-identity modules must never reload in place; fen.extensions.*
;; modules reload through their manifest's reload-modules instead.
(local NON-RELOADABLE {:fen.main true
                       :fen.core.extensions.state true
                       :fen.core.tasks.state true
                       :fen.util.log_sink true
                       :fen.util.file_mutex_state true})

(fn M.core-reloadable? [modname]
  "True when `modname` is a core module that /reload refreshes in place."
  (and (= (type modname) :string) (not= nil (string.find modname "^fen%."))
       ;; Extension modules reload through their manifest's reload-modules.
       (= nil (string.find modname "^fen%.extensions%."))
       ;; *.backend selector modules are host injection points: reloading would clobber
       ;; an injected backend with the on-disk default. Concrete backends.* still reload.
       (= nil (string.find modname "%.backend$"))
       (not (. NON-RELOADABLE modname))))

M
