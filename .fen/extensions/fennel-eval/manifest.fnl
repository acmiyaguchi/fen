{:name :fennel_eval
 :description "Dev-only in-process Fennel evaluation tool"
 ;; Inert for project-local specs: the loader always enables .fen/extensions
 ;; drop-ins, so the real gate is the FEN_FENNEL_EVAL check in init.fnl.
 :enabled-by-default false
 :first-party? false
 :entry "init.fnl"}
