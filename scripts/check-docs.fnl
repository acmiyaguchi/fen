#!/usr/bin/env fennel
;; Validate inline `;; @doc` blocks across the tree.
;;
;; Checks:
;;   - block has a :summary line (else: contributes nothing to the index)
;;   - all keys are recognized
;;   - :kind is one of an allowed set
;;   - :id resolves to an inferred export OR a contract entry
;;   - no two @doc blocks claim the same :id
;;
;; Exits non-zero on any error. Warnings are printed but do not fail.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path
         ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"))

(local scanner (require :docs.scanner))

(local ALLOWED-KEYS
  {:id true :kind true :signature true :summary true
   :tags true :see-also true :since true})

(local ALLOWED-KINDS
  {:function true :constant true :data true
   :type true :event true :register-kind true :interface true})

(fn line [s] (print s))

(fn build-known-ids [tree contracts]
  "Set of every id that a @doc block is allowed to claim."
  (let [known {}]
    (each [_ file (ipairs tree.files)]
      (each [_ e (ipairs file.exports)]
        (when e.id (tset known e.id true)))
      (each [_ r (ipairs file.register-sites)]
        (when (and r.kind r.name)
          (tset known (.. "register-site:" r.kind ":" r.name) true))))
    (each [k _ (pairs (or contracts.types {}))]
      (tset known (.. "type:" k) true))
    (each [k _ (pairs (or contracts.events {}))]
      (tset known (.. "event:" k) true))
    (each [k _ (pairs (or contracts.register-kinds {}))]
      (tset known (.. "register-kind:" k) true))
    (each [k _ (pairs (or contracts.interfaces {}))]
      (tset known (.. "interface:" k) true))
    known))

(fn collect-doc-blocks [tree]
  "Flatten every @doc block from the tree, attaching the source path."
  (let [out []]
    (each [_ file (ipairs tree.files)]
      (each [_ d (ipairs file.doc-blocks)]
        (let [copy {}]
          (each [k v (pairs d)] (tset copy k v))
          (tset copy :path file.path)
          (table.insert out copy))))
    out))

(fn validate-block [block known-ids errors warnings]
  (let [loc (.. block.path ":" block.line)
        push-error (fn [msg]
                     (table.insert errors (.. loc ": " msg)))
        push-warn (fn [msg]
                    (table.insert warnings (.. loc ": " msg)))]
    ;; Keys
    (each [k _ (pairs block)]
      (let [k-str (tostring k)]
        (when (and (not (. ALLOWED-KEYS k-str))
                   ;; internal scanner fields
                   (not (or (= k-str :line) (= k-str :end-line)
                            (= k-str :path))))
          (push-warn (.. "unknown @doc key `" k-str "`")))))
    ;; Required summary
    (when (or (not block.summary) (= block.summary ""))
      (push-error (.. "@doc " (or block.id "?") " is missing :summary")))
    ;; Recognized kind
    (when (and block.kind (not (. ALLOWED-KINDS block.kind)))
      (push-warn (.. "@doc " (or block.id "?")
                     " kind=`" block.kind "` not recognized; allowed: "
                     (table.concat
                       (let [ks []]
                         (each [k _ (pairs ALLOWED-KINDS)]
                           (table.insert ks (tostring k)))
                         (table.sort ks)
                         ks)
                       ", "))))
    ;; ID resolves
    (when (and block.id (not (. known-ids block.id)))
      (push-error (.. "@doc id `" block.id
                      "` does not resolve to any export or contract entry")))))

(fn check-duplicate-ids [blocks errors]
  (let [seen {}]
    (each [_ b (ipairs blocks)]
      (when b.id
        (let [prior (. seen b.id)]
          (if prior
              (table.insert errors
                (.. b.path ":" b.line ": duplicate @doc id `" b.id
                    "` — first declared at " prior))
              (tset seen b.id (.. b.path ":" b.line))))))))

(fn main []
  (let [tree (scanner.scan-tree)
        contracts (scanner.read-contracts)
        known-ids (build-known-ids tree contracts)
        blocks (collect-doc-blocks tree)
        errors []
        warnings []]
    (each [_ b (ipairs blocks)]
      (validate-block b known-ids errors warnings))
    (check-duplicate-ids blocks errors)
    (when (> (# warnings) 0)
      (line (.. "warnings (" (# warnings) "):"))
      (each [_ w (ipairs warnings)] (line (.. "  " w))))
    (when (> (# errors) 0)
      (line (.. "errors (" (# errors) "):"))
      (each [_ e (ipairs errors)] (line (.. "  " e))))
    (line (.. "Checked " (# blocks) " @doc blocks across "
              (# tree.sources) " sources."))
    (if (> (# errors) 0)
        (do (line (.. "FAIL: " (# errors) " error"
                      (if (= (# errors) 1) "" "s")))
            (os.exit 1))
        (line "OK"))))

(main)
