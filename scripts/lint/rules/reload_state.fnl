;; reload/state: a reloadable module keeps no state across calls. A module-level
;; `var`, or a module-level table, that a function body mutates is state
;; /reload silently resets; it belongs in a non-reloadable state module.
;; The module's returned table (`M`, or the tables a returned literal refers
;; to) is its export surface and is exempt.
;;
;; Syntactic and scope-aware for fn/let/each/for bindings; mutation through an
;; alias (`(let [s state] (tset s ...))`) or a method call is not tracked.

(local fennel (require :fennel))

(local M {})

(local FUNCTION-HEADS {:fn true :lambda true "λ" true :hashfn true})
(local MUTATORS {:table.insert true :table.remove true :table.sort true})
;; Forms whose first argument is a binding vector scoping over the body.
(local BINDING-HEADS {:let true
                      :each true
                      :for true
                      :icollect true
                      :collect true
                      :accumulate true
                      :faccumulate true
                      :fcollect true
                      :with-open true})

(fn head [form]
  (and (fennel.list? form) (fennel.sym? (. form 1)) (tostring (. form 1))))

(fn root-name [form]
  "Base binding a set/tset target refers to: `x`, `x.y`, `(. x k)` -> x."
  (if (fennel.sym? form) (string.match (tostring form) "^([^.:]+)")
      (= (head form) ".") (root-name (. form 2))))

(fn table-literal? [form]
  (and (= :table (type form)) (not (fennel.list? form))
       (not (fennel.sym? form)) (not (fennel.varg? form))))

(fn table-value? [form]
  "A table literal, or `(setmetatable <table literal> ...)`."
  (or (table-literal? form)
      (and (= (head form) :setmetatable) (table-literal? (. form 2)))))

(fn line-of [form fallback]
  (or (?. (fennel.ast-source form) :line) fallback))

(fn mutated-binding [form]
  "Name of the binding `form` mutates, or nil."
  (let [h (head form)]
    (if (or (= h :set) (= h :tset) (. MUTATORS (or h "")))
        (root-name (. form 2)))))

(fn pattern-names [pat out]
  "Collect symbol names bound by a destructuring pattern into `out`."
  (if (fennel.sym? pat) (tset out (tostring pat) true) (= :table (type pat))
      (each [k v (pairs pat)]
        (when (fennel.sym? k)
          (tset out (tostring k) true))
        (pattern-names v out)))
  out)

(fn extend [shadowed names]
  (let [out (collect [k v (pairs shadowed)] (values k v))]
    (each [k (pairs names)]
      (tset out k true))
    out))

(fn binding-names [h form]
  "Names a scoping form binds for its body."
  (let [names {}]
    (if (. FUNCTION-HEADS h)
        (let [args (if (fennel.sym? (. form 2)) (. form 3) (. form 2))]
          (when (fennel.sequence? args)
            (pattern-names args names)))
        (. BINDING-HEADS h)
        (let [bindings (. form 2)]
          (when (fennel.sequence? bindings)
            (if (= h :let)
                (for [i 1 (length bindings) 2]
                  (pattern-names (. bindings i) names))
                ;; each/for/icollect…: every non-call binding before the iterator.
                (each [_ b (ipairs bindings)]
                  (when (not (fennel.list? b))
                    (pattern-names b names)))))))
    names))

(fn exported-names [last]
  "Binding names that form the module's export surface."
  (let [out {}]
    (if (fennel.sym? last) (tset out (tostring last) true)
        (table-literal? last)
        (each [_ v (pairs last)]
          (let [r (root-name v)]
            (when r (tset out r true)))))
    out))

(fn M.scan [source]
  "Module-level bindings mutated inside a function body, as [{:name :line
   :kind}] at the first such site. `source` is Fennel text. Raises on a
   parse error."
  (let [forms (icollect [_ form (fennel.parser source)] form)
        candidates {}
        reported {}
        out []
        exempt (exported-names (. forms (length forms)))]
    (each [_ form (ipairs forms)]
      (let [h (head form)]
        (when (and (or (= h :var) (= h :local)) (fennel.sym? (. form 2)))
          (let [name (tostring (. form 2))]
            (when (and (not (. exempt name))
                       (or (= h :var) (table-value? (. form 3))))
              (tset candidates name (if (= h :var) :var :table)))))))

    (fn note! [name line]
      (when (and name (. candidates name) (not (. reported name)))
        (tset reported name true)
        (table.insert out {: name : line :kind (. candidates name)})))

    (fn walk [form in-fn? shadowed line]
      (when (and (= :table (type form)) (not (fennel.sym? form)))
        (let [line (line-of form line)
              h (or (head form) "")
              in-fn? (or in-fn? (not= nil (. FUNCTION-HEADS h)))
              shadowed (if (or (. FUNCTION-HEADS h) (. BINDING-HEADS h))
                           (extend shadowed (binding-names h form))
                           shadowed)
              visible #(when (and $1 (not (. shadowed $1)))
                         $1)]
          (when in-fn?
            (note! (visible (mutated-binding form)) line)
            ;; (doto x (tset ...)) mutates x.
            (when (= h :doto)
              (let [target (visible (root-name (. form 2)))]
                (for [i 3 (length form)]
                  (let [ih (head (. form i))]
                    (when (or (= ih :tset) (= ih :set) (. MUTATORS (or ih "")))
                      (note! target line)))))))
          (each [_ child (pairs form)]
            (walk child in-fn? shadowed line)))))

    (each [_ form (ipairs forms)]
      (walk form false {} 1))
    out))

(fn M.check [facts]
  "facts: {:files [{:path :reloadable? :source}]}"
  (let [findings []]
    (each [_ f (ipairs facts.files)]
      (when f.reloadable?
        (let [(ok? hits) (pcall M.scan f.source)]
          (if (not ok?)
              (table.insert findings
                            {:rule :lint/parse
                             :path f.path
                             :line (or (tonumber (string.match (tostring hits)
                                                               ":(%d+):"))
                                       1)
                             :message (.. "cannot parse: " (tostring hits))})
              (each [_ hit (ipairs hits)]
                (table.insert findings
                              {:rule :reload/state
                               :path f.path
                               :line hit.line
                               :message (.. "module-level "
                                            (if (= hit.kind :var) "var" "table")
                                            " `" hit.name
                                            "` is mutated at call time in a reloadable module; /reload resets it")}))))))
    findings))

M
