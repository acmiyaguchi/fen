;; layer/deps: a literal require of a module owned by another rock in the tree
;; must be reachable through the requiring rock's rockspec dependencies.
;; Transitive: luarocks installs the closure, so only an undeclared path breaks.

(local M {})

(fn closure [deps rock]
  "Every rock reachable from `rock` through `deps` (rock -> [rock])."
  (let [seen {}]
    (fn visit [r]
      (each [_ d (ipairs (or (. deps r) []))]
        (when (not (. seen d))
          (tset seen d true)
          (visit d))))

    (visit rock)
    seen))

(fn M.check [facts]
  "facts: {:files [{:path :rock :dependencies [{:kind :module :line}]}]
           :owners {module rock} :deps {rock [rock]}}"
  (let [findings []
        reach {}]
    (each [_ f (ipairs facts.files)]
      (when f.rock
        (when (not (. reach f.rock))
          (tset reach f.rock (closure facts.deps f.rock)))
        (each [_ d (ipairs f.dependencies)]
          (let [owner (. facts.owners d.module)]
            (when (and owner (not= owner f.rock)
                       (not= d.kind :optional-require)
                       (not (. reach f.rock owner)))
              (table.insert findings
                            {:rule :layer/deps
                             :path f.path
                             :line d.line
                             :message (.. f.rock " requires " d.module
                                          " (rock " owner
                                          ") without declaring it in its rockspec dependencies")}))))))
    findings))

M
