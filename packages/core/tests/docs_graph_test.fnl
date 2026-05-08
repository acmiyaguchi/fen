(local fennel (require :fennel))
(set fennel.path (.. "./scripts/?.fnl;./scripts/?/init.fnl;" fennel.path))

(local graph (require :docs.graph))
(local scanner (require :docs.scanner))

(describe "docs graph helpers" (fn []
  (it "escapes DOT strings" (fn []
    (assert.are.equal "a\\\"b\\\\c\\nd" (graph.dot-escape "a\"b\\c\nd"))))

  (it "finds strongly connected components" (fn []
    (let [components (graph.scc ["a" "b" "c"]
                                [{:from "a" :to "b"}
                                 {:from "b" :to "a"}
                                 {:from "b" :to "c"}])]
      (assert.are.equal 1 (# components))
      (assert.are.same ["a" "b"] (. components 1)))))

  (it "extracts literal require dependencies" (fn []
    (let [deps (scanner.scan-dependencies "(local agent (require :fen.core.agent))\n(import-macros :fen.testing.macros)\n")]
      (assert.are.equal 2 (# deps))
      (assert.are.equal "fen.core.agent" (. deps 1 :module))
      (assert.are.equal :require (. deps 1 :kind))
      (assert.are.equal "fen.testing.macros" (. deps 2 :module))
      (assert.are.equal :macro (. deps 2 :kind)))))

  (it "scanner aggregate includes dependency edges" (fn []
    (let [tree (scanner.scan-tree)
          agg (scanner.aggregate tree)]
      (assert.is_true (> (# agg.dependencies) 0))
      (var found? false)
      (each [_ dep (ipairs agg.dependencies)]
        (when (and (= dep.from "fen.core.agent")
                   (= dep.module "fen.core.llm"))
          (set found? true)))
      (assert.is_true found?))))

  (it "first-party extension runtime modules do not require the core extension facade" (fn []
    (let [tree (scanner.scan-tree)
          offenders []]
      (each [_ file (ipairs tree.files)]
        (when (= (?. file :module-info :scope) :extension)
          (each [_ dep (ipairs (or file.dependencies []))]
            (when (= dep.module "fen.core.extensions")
              (table.insert offenders file.path)))))
      (assert.are.same [] offenders)))))
)
