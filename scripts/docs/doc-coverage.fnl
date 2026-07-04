#!/usr/bin/env fennel
;; Documentation coverage report.
;;
;; Compares the scanner inventory (exported functions, registered kinds,
;; emitted events) against the documented surface (inline `;; @doc`
;; blocks and the contracts data module).
;;
;; Reports grouped totals and lists undocumented items.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path
         ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"
         ";./packages/util/src/?.fnl;./packages/util/src/?/init.fnl"))

(local scanner (require :docs.scanner))

;; Canonical register kinds — keep in sync with
;; packages/core/src/fen/core/extensions/register/init.fnl.
(local CANONICAL-REGISTER-KINDS
  ["auth-backend" "command" "control" "hook" "panel"
   "presenter" "prompt-fragment" "provider" "session-backend"
   "status" "tool"])

;; Modules whose "exports" are data tables, not callable functions —
;; they're documented through contracts.md, not core.md, so excluding
;; them from the function-coverage count keeps the percentage honest.
(local FN-COVERAGE-EXCLUDE-PREFIX
  ["fen.core.docs."])

(fn excluded-from-fn-coverage? [id]
  (var hit? false)
  (each [_ p (ipairs FN-COVERAGE-EXCLUDE-PREFIX)]
    (when (= (string.sub id 1 (# p)) p)
      (set hit? true)))
  hit?)

(fn pct [n total]
  (if (= total 0) "100.0%"
      (string.format "%.1f%%" (* 100 (/ n total)))))

(fn line [s] (print s))

(fn header [title]
  (line "")
  (line title)
  (line (string.rep "-" (# title))))

(fn function-kind? [e]
  (or (= e.kind :function) (= e.kind nil)))

(fn data-kind? [e] (= e.kind :data))

(fn core-fn? [e]
  (and e.path
       (string.match e.path "^packages/")
       (not (excluded-from-fn-coverage? e.id))
       (function-kind? e)))

(fn extension-fn? [e]
  (and e.path
       (string.match e.path "^extensions/")
       (function-kind? e)))

(fn report-fn-coverage-group [title exports include?]
  (var total 0)
  (var documented 0)
  (let [missing []]
    (each [_ e (ipairs exports)]
      (when (include? e)
        (set total (+ total 1))
        (if (and e.doc e.doc.summary)
            (set documented (+ documented 1))
            (table.insert missing e))))
    (header title)
    (line (.. "  " documented " / " total " documented  " (pct documented total)))
    (when (> (# missing) 0)
      (line (.. "  Missing @doc blocks (" (# missing) "):"))
      (each [i e (ipairs missing)]
        (when (<= i 20)
          (line (.. "    " e.id "  (" e.path ":" (or e.line "?") ")"))))
      (when (> (# missing) 20)
        (line (.. "    ... and " (- (# missing) 20) " more"))))))

(fn count-data-exports [exports]
  "Tally :data exports — split by package/extension and by whether a
   @doc block is attached. Documented data items (constants like
   SAFETY-CAP) are interesting; undocumented re-exports of state are
   background noise."
  (var pkg-total 0)
  (var pkg-doc 0)
  (var ext-total 0)
  (var ext-doc 0)
  (each [_ e (ipairs exports)]
    (when (data-kind? e)
      (let [doc? (and e.doc e.doc.summary)
            in-pkg? (string.match (or e.path "") "^packages/")]
        (if in-pkg?
            (do (set pkg-total (+ pkg-total 1))
                (when doc? (set pkg-doc (+ pkg-doc 1))))
            (do (set ext-total (+ ext-total 1))
                (when doc? (set ext-doc (+ ext-doc 1))))))))
  {:pkg-total pkg-total :pkg-doc pkg-doc
   :ext-total ext-total :ext-doc ext-doc})

(fn report-register-coverage [contracts]
  (let [documented {}
        missing []]
    (each [k _ (pairs contracts.register-kinds)]
      (tset documented (tostring k) true))
    (each [_ k (ipairs CANONICAL-REGISTER-KINDS)]
      (when (not (. documented k))
        (table.insert missing k)))
    (header "Extension register kinds")
    (let [doc-count (- (# CANONICAL-REGISTER-KINDS) (# missing))
          total (# CANONICAL-REGISTER-KINDS)]
      (line (.. "  " doc-count " / " total " documented  " (pct doc-count total)))
      (when (> (# missing) 0)
        (line "  Missing contracts.register-kinds entries:")
        (each [_ k (ipairs missing)]
          (line (.. "    :" k)))))))

(fn report-event-coverage [contracts emit-types]
  (let [documented {}
        all-types {}
        ordered []]
    (each [k _ (pairs contracts.events)]
      (tset documented (tostring k) true))
    ;; Union: events emitted in source + events declared in contracts.
    (each [k _ (pairs emit-types)]
      (when (not (. all-types k))
        (table.insert ordered k)
        (tset all-types k true)))
    (each [k _ (pairs contracts.events)]
      (let [s (tostring k)]
        (when (not (. all-types s))
          (table.insert ordered s)
          (tset all-types s true))))
    (table.sort ordered)
    (let [missing []]
      (each [_ k (ipairs ordered)]
        (when (not (. documented k))
          (table.insert missing k)))
      (header "Event shapes")
      (let [doc-count (- (# ordered) (# missing))]
        (line (.. "  " doc-count " / " (# ordered)
                  " documented  " (pct doc-count (# ordered))))
        (when (> (# missing) 0)
          (line "  Emitted but undocumented:")
          (each [_ k (ipairs missing)]
            (let [sites (. emit-types k)
                  loc (if (and sites (. sites 1))
                          (.. (. sites 1 :path) ":" (. sites 1 :line))
                          "(declared only)")]
              (line (.. "    :" k "  (" loc ")")))))))))

(fn report-type-coverage [contracts]
  (var n 0)
  (each [_ _ (pairs contracts.types)]
    (set n (+ n 1)))
  (header "Canonical types")
  (line (.. "  " n " / " n " documented  100.0%")))

;; Register kinds whose specs conventionally carry no :description
;; (status providers are short identifiers; presenter/hook are typed
;; by other fields). Coverage for these depends only on a literal :name.
(local DESCRIPTION-OPTIONAL-KINDS
  {:status true :presenter true :hook true})

(fn site-documented? [r]
  (and r.name
       (or (. DESCRIPTION-OPTIONAL-KINDS r.kind)
           r.has-description?)))

(fn site-indirect? [r]
  ;; Spec passed as a variable or function-call result — the static
  ;; scanner can't inspect it, so it's neither documented nor missing.
  (not r.name))

(fn report-extension-sites [register-sites]
  (let [groups {}
        order []]
    (each [_ r (ipairs register-sites)]
      (let [k (or r.kind "unknown")]
        (when (not (. groups k))
          (table.insert order k)
          (tset groups k {:total 0 :documented 0 :indirect 0
                          :missing []}))
        (let [b (. groups k)]
          (tset b :total (+ b.total 1))
          (if (site-indirect? r)
              (tset b :indirect (+ b.indirect 1))
              (site-documented? r)
              (tset b :documented (+ b.documented 1))
              (table.insert b.missing
                {:name r.name
                 :reason "no :description"
                 :path r.path
                 :line r.line})))))
    (table.sort order)
    (header "First-party register sites (per kind)")
    (each [_ k (ipairs order)]
      (let [b (. groups k)]
        (let [inspectable (- b.total b.indirect)
              tail (if (> b.indirect 0)
                       (.. "  (" b.indirect " indirect — dynamic spec)")
                       "")]
          (line (.. "  :" k ": " b.documented " / " inspectable
                    "  " (pct b.documented inspectable) tail)))
        (each [i m (ipairs b.missing)]
          (when (<= i 5)
            (line (.. "    - " m.name "  [" m.reason "]  ("
                      m.path ":" m.line ")"))))
        (when (> (# b.missing) 5)
          (line (.. "    ... and " (- (# b.missing) 5) " more")))))))

(fn main []
  (let [tree (scanner.scan-tree)
        agg (scanner.aggregate tree)
        contracts (scanner.read-contracts)]
    (line "Doc coverage")
    (line (string.rep "=" 12))
    (report-fn-coverage-group "Core exported functions"
                              agg.exports core-fn?)
    (report-fn-coverage-group "Extension exported functions"
                              agg.exports extension-fn?)
    (let [d (count-data-exports agg.exports)]
      (header "Data / value exports (informational)")
      (line (.. "  Core:       " d.pkg-doc " / " d.pkg-total
                " documented (document intentional constants; generated docs fold undocumented state re-exports)"))
      (line (.. "  Extensions: " d.ext-doc " / " d.ext-total
                " documented (informational; not a 100% target)")))
    (report-register-coverage contracts)
    (report-event-coverage contracts agg.emit-types)
    (report-type-coverage contracts)
    (report-extension-sites agg.register-sites)
    (line "")
    (line (.. "(" (# tree.sources) " Fennel sources scanned.)"))))

(main)
