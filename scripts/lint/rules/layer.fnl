;; layer/deps: a literal require of a module owned by another rock in the tree
;; must be reachable through the requiring rock's rockspec dependencies.
;; Transitive: luarocks installs the closure, so only an undeclared path breaks.
;; A rockspec-less extension is a bundled-only pseudo-rock named "bundled:<dir>":
;; it ships inside the binary alongside everything else, so it may require any
;; module, but no published rock can depend on it.

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

(fn bundled? [rock]
  (= (string.sub rock 1 (length "bundled:")) "bundled:"))

(fn M.check [facts]
  "facts: {:files [{:path :rock :dependencies [{:kind :module :line}]}]
           :owners {module rock} :deps {rock [rock]}}"
  (let [findings []
        reach {}]
    (each [_ f (ipairs facts.files)]
      (when (and f.rock (not (bundled? f.rock)))
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
                             :message (if (bundled? owner)
                                          (.. f.rock " requires " d.module
                                              ", which is bundled-only ("
                                              (string.sub owner
                                                          (+ 1
                                                             (length "bundled:")))
                                              " has no rockspec), so a LuaRocks install cannot resolve it")
                                          (.. f.rock " requires " d.module
                                              " (rock " owner
                                              ") without declaring it in its rockspec dependencies"))}))))))
    findings))

M
