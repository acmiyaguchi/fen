;; reload/state: a reloadable module keeps no state across calls. A module-level
;; `var`, or a module-level table literal, that a function body mutates is state
;; /reload silently resets; it belongs in a non-reloadable state module.
;; The module's returned table (`M`) is its export surface and is exempt.

(local fennel (require :fennel))

(local M {})

(local FUNCTION-HEADS {:fn true :lambda true "λ" true :hashfn true})
(local MUTATORS {:table.insert true :table.remove true :table.sort true})

(fn head [form]
  (and (fennel.list? form) (fennel.sym? (. form 1)) (tostring (. form 1))))

(fn root-name [form]
  "Base binding a set/tset target refers to: `x`, `x.y`, `(. x k)` -> x."
  (if (fennel.sym? form) (string.match (tostring form) "^([^.:]+)")
      (= (head form) ".") (root-name (. form 2))))

(fn table-literal? [form]
  (and (= :table (type form)) (not (fennel.list? form))
       (not (fennel.sym? form)) (not (fennel.varg? form))))

(fn line-of [form fallback]
  (or (?. (fennel.ast-source form) :line) fallback))

(fn mutated-binding [form]
  "Name of the binding `form` mutates, or nil."
  (let [h (head form)]
    (if (= h :set) (root-name (. form 2))
        (= h :tset) (root-name (. form 2))
        (. MUTATORS (or h "")) (root-name (. form 2)))))

(fn M.scan [source]
  "Module-level bindings mutated inside a function body, as [{:name :line
   :kind}] at the first such site. `source` is Fennel text; the returned
   module table is exempt."
  (let [forms (icollect [ok? form (fennel.parser source) &until (not ok?)]
                form)
        candidates {}
        reported {}
        out []
        returned (let [last (. forms (length forms))]
                   (and (fennel.sym? last) (tostring last)))]
    (each [_ form (ipairs forms)]
      (let [h (head form)]
        (when (and (or (= h :var) (= h :local)) (fennel.sym? (. form 2)))
          (let [name (tostring (. form 2))]
            (when (and (not= name returned)
                       (or (= h :var) (table-literal? (. form 3))))
              (tset candidates name (if (= h :var) :var :table)))))))

    (fn walk [form in-fn? line]
      (when (= :table (type form))
        (let [line (line-of form line)
              in-fn? (or in-fn?
                         (not= nil (. FUNCTION-HEADS (or (head form) ""))))
              name (and in-fn? (mutated-binding form))]
          (when (and name (. candidates name) (not (. reported name)))
            (tset reported name true)
            (table.insert out {: name : line :kind (. candidates name)}))
          (when (not (fennel.sym? form))
            (each [_ child (pairs form)]
              (walk child in-fn? line))))))

    (each [_ form (ipairs forms)]
      (walk form false 1))
    out))

(fn M.check [facts]
  "facts: {:files [{:path :reloadable? :source}]}"
  (let [findings []]
    (each [_ f (ipairs facts.files)]
      (when f.reloadable?
        (each [_ hit (ipairs (M.scan f.source))]
          (table.insert findings
                        {:rule :reload/state
                         :path f.path
                         :line hit.line
                         :message (.. "module-level "
                                      (if (= hit.kind :var) "var" "table") " `"
                                      hit.name
                                      "` is mutated at call time in a reloadable module; /reload resets it")}))))
    findings))

M
