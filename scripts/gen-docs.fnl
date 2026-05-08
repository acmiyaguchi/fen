#!/usr/bin/env fennel
;; Generate Fen API docs and the searchable api-index.
;;
;; Outputs (under docs/generated/):
;;   core.md          — exported functions grouped by module, with
;;                      summary/signature/tags from inline @doc blocks.
;;   contracts.md     — register kinds, events, canonical types, and
;;                      provider/auth/session backend interfaces.
;;   extensions.md    — first-party register sites discovered in source.
;;   api-index.jsonl  — one record per public surface item (search input).
;;   api-index.json   — same records as a JSON array.
;;
;; This script does not execute application code; the scanner is a
;; lightweight text walker. Contracts are loaded as data.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path
         ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"))

(local scanner (require :docs.scanner))
(local json (require :docs.json))

(local OUT-DIR "docs/generated")

(fn write-file [path text]
  (os.execute (.. "mkdir -p " (string.match path "^(.+)/[^/]+$")))
  (let [f (assert (io.open path :w))]
    (f:write text)
    (f:close)))

(fn keyword [v] (if v (.. ":" (tostring v)) ""))

;; ---------------------------------------------------------------------------
;; Markdown rendering
;; ---------------------------------------------------------------------------

(fn group-by-module [exports]
  (let [groups {}
        order []]
    (each [_ e (ipairs exports)]
      (let [m (or e.module "(unknown)")]
        (when (not (. groups m))
          (table.insert order m)
          (tset groups m []))
        (table.insert (. groups m) e)))
    (table.sort order)
    (values groups order)))

(fn doc-summary [doc]
  (or (and doc doc.summary) ""))

(fn doc-signature [doc fallback]
  (or (and doc doc.signature) fallback))

(fn doc-tags [doc]
  (and doc doc.tags))

(fn data-kind? [e] (= e.kind :data))

(fn documented-export? [e]
  (and e.doc e.doc.summary))

(fn visible-export? [e]
  "Public generated-doc item: exported functions/unknowns plus data exports
   that have an explicit @doc. Undocumented data exports are usually
   state-table aliases or implementation plumbing, so render them as a
   compact omitted list instead of as empty API entries."
  (not (and (data-kind? e)
            (not (documented-export? e)))))

(fn render-omitted-data-line [out omitted]
  (when (> (# omitted) 0)
    (let [names []]
      (each [_ e (ipairs omitted)]
        (table.insert names (.. "`" e.id "`")))
      (table.insert out
                    (.. "_Undocumented data/state re-exports omitted from the public API listing:_ "
                        (table.concat names ", ")))
      (table.insert out ""))))

(fn render-core-md [exports]
  (let [(groups order) (group-by-module exports)
        out ["# Fen core API"
             ""
             "Generated from Fennel sources. Each module section lists exported"
             "public functions and documented data values in source order. Items"
             "with an inline `;; @doc` block include their summary and signature;"
             "undocumented functions show their name only. Undocumented data/state"
             "re-exports are folded into an omitted note per module."
             ""
             "Run `make docs` to regenerate."
             ""]]
    (each [_ m (ipairs order)]
      (let [items (. groups m)
            visible []
            omitted-data []]
        (each [_ e (ipairs items)]
          (if (visible-export? e)
              (table.insert visible e)
              (data-kind? e)
              (table.insert omitted-data e)))
        (when (or (> (# visible) 0) (> (# omitted-data) 0))
          (table.insert out (.. "## " m))
          (table.insert out "")
          (each [_ e (ipairs visible)]
            (let [sig (doc-signature e.doc nil)
                  summary (doc-summary e.doc)
                  line (or (and e.doc e.doc.line) e.line "?")]
              (table.insert out (.. "### `" e.id "`"))
              (when sig
                (table.insert out (.. "`" sig "`")))
              (when (not= summary "")
                (table.insert out summary))
              (let [tags (doc-tags e.doc)]
                (when (and tags (> (# tags) 0))
                  (table.insert out (.. "*tags:* " (table.concat tags ", ")))))
              (table.insert out (.. "_" e.path ":" line "_"))
              (table.insert out "")))
          (render-omitted-data-line out omitted-data))))
    (table.concat out "\n")))

(fn render-field-row [fname fdef]
  (let [type (or fdef.type
                 (and fdef.const (.. ":" (tostring fdef.const)))
                 (and fdef.enum
                      (.. "enum " (table.concat
                                    (icollect [_ v (ipairs fdef.enum)]
                                      (.. ":" (tostring v)))
                                    " | ")))
                 "any")
        req (if fdef.required " (required)" "")
        summary (or fdef.summary "")]
    (.. "- `:" fname "` `" type "`" req
        (if (= summary "") "" (.. " — " summary)))))

(fn render-contract-entry [name body]
  (let [out [(.. "### `" name "`")
             (or body.summary "")]]
    (when body.fields
      (let [keys []]
        (each [k _ (pairs body.fields)] (table.insert keys k))
        (table.sort keys)
        (table.insert out "")
        (each [_ k (ipairs keys)]
          (table.insert out (render-field-row k (. body.fields k))))))
    (when body.variants
      (table.insert out "")
      (table.insert out (.. "Variants: "
                            (table.concat
                              (icollect [_ v (ipairs body.variants)]
                                (.. "`" (tostring v) "`"))
                              " | "))))
    (when body.enum
      (table.insert out "")
      (table.insert out (.. "Values: "
                            (table.concat
                              (icollect [_ v (ipairs body.enum)]
                                (.. "`:" (tostring v) "`"))
                              " | "))))
    (when body.methods
      (table.insert out "")
      (table.insert out (.. "Required methods: "
                            (table.concat
                              (icollect [_ m (ipairs body.methods)]
                                (.. "`:" (tostring m) "`"))
                              ", "))))
    (when body.optional-methods
      (table.insert out (.. "Optional methods: "
                            (table.concat
                              (icollect [_ m (ipairs body.optional-methods)]
                                (.. "`:" (tostring m) "`"))
                              ", "))))
    (table.insert out "")
    (table.concat out "\n")))

(fn render-contracts-md [contracts]
  (let [out ["# Fen contracts"
             ""
             "The non-function public surface: canonical types, extension"
             "register kinds, event-bus shapes, and provider/auth/session"
             "interfaces."
             ""]
        sections [{:key :register-kinds :label "Register kinds"}
                  {:key :events :label "Events"}
                  {:key :types :label "Canonical types"}
                  {:key :interfaces :label "Interfaces"}]]
    (each [_ s (ipairs sections)]
      (let [bucket (. contracts s.key)]
        (when bucket
          (table.insert out (.. "## " s.label))
          (table.insert out "")
          (let [keys []]
            (each [k _ (pairs bucket)] (table.insert keys (tostring k)))
            (table.sort keys)
            (each [_ k (ipairs keys)]
              (table.insert out (render-contract-entry k (. bucket k))))))))
    (table.concat out "\n")))

(fn render-extensions-md [register-sites]
  (let [groups {}
        order []]
    (each [_ r (ipairs register-sites)]
      (let [k (or r.kind "unknown")]
        (when (not (. groups k))
          (table.insert order k)
          (tset groups k []))
        (table.insert (. groups k) r)))
    (table.sort order)
    (let [out ["# Fen extension contributions"
               ""
               "Discovered `(api.register :kind {...})` sites across the"
               "first-party extensions and core. Names extracted from"
               "literal `:name` fields; dynamic registrations show the"
               "source path with the name omitted."
               ""]]
      (each [_ k (ipairs order)]
        (table.insert out (.. "## :" k))
        (table.insert out "")
        (let [items (. groups k)]
          (each [_ r (ipairs items)]
            (let [name-str (if r.name (.. "`" r.name "`") "_(dynamic)_")
                  desc (or r.description "")
                  loc (.. r.path ":" (tostring (or r.line "?")))]
              (table.insert out (.. "- " name-str " — " desc " — _" loc "_"))))
          (table.insert out "")))
      (table.concat out "\n"))))

;; ---------------------------------------------------------------------------
;; Index records
;; ---------------------------------------------------------------------------

(fn export-record [e]
  (let [doc e.doc
        rec {:id e.id
             :kind (or (and doc doc.kind) "function")
             :path e.path
             :line (or (and doc doc.line) e.line 0)}]
    (when doc
      (when doc.summary (tset rec :summary doc.summary))
      (when doc.signature (tset rec :signature doc.signature))
      (when (and doc.tags (> (# doc.tags) 0)) (tset rec :tags doc.tags))
      (when doc.see-also (tset rec :see-also doc.see-also)))
    rec))

(fn contract-records [contracts]
  (let [out []
        push (fn [prefix kind bucket]
               (when bucket
                 (let [keys []]
                   (each [k _ (pairs bucket)] (table.insert keys (tostring k)))
                   (table.sort keys)
                   (each [_ k (ipairs keys)]
                     (let [body (. bucket k)
                           rec {:id (.. prefix ":" k)
                                :kind kind
                                :summary (or body.summary "")}]
                       (when body.fields
                         (let [fkeys []]
                           (each [fk _ (pairs body.fields)] (table.insert fkeys fk))
                           (table.sort fkeys)
                           (tset rec :fields fkeys)))
                       (when body.enum (tset rec :enum body.enum))
                       (when body.variants (tset rec :variants body.variants))
                       (when body.methods (tset rec :methods body.methods))
                       (when body.optional-methods
                         (tset rec :optional-methods body.optional-methods))
                       (table.insert out rec))))))]
    (push :register-kind :register-kind contracts.register-kinds)
    (push :event :event contracts.events)
    (push :type :type contracts.types)
    (push :interface :interface contracts.interfaces)
    out))

(fn extension-records [register-sites]
  (let [out []]
    (each [_ r (ipairs register-sites)]
      (let [name (or r.name "(dynamic)")
            id (.. "register-site:" r.kind ":" name)]
        (table.insert out
          {:id id
           :kind (.. "register-site:" r.kind)
           :name name
           :description (or r.description "")
           :path r.path
           :line (or r.line 0)})))
    out))

(fn write-index [records]
  (let [lines []
        all []]
    (each [_ r (ipairs records)]
      (table.insert lines (json.encode r))
      (table.insert all r))
    (write-file (.. OUT-DIR "/api-index.jsonl")
                (.. (table.concat lines "\n") "\n"))
    (write-file (.. OUT-DIR "/api-index.json")
                (.. (json.encode all) "\n"))))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(fn main []
  (let [tree (scanner.scan-tree)
        agg (scanner.aggregate tree)
        contracts (scanner.read-contracts)]
    (write-file (.. OUT-DIR "/core.md") (render-core-md agg.exports))
    (write-file (.. OUT-DIR "/contracts.md") (render-contracts-md contracts))
    (write-file (.. OUT-DIR "/extensions.md")
                (render-extensions-md agg.register-sites))
    (let [records []]
      (each [_ e (ipairs agg.exports)]
        (when (visible-export? e)
          (table.insert records (export-record e))))
      (each [_ r (ipairs (contract-records contracts))]
        (table.insert records r))
      (each [_ r (ipairs (extension-records agg.register-sites))]
        (table.insert records r))
      (write-index records)
      (print (.. "Wrote " OUT-DIR "/core.md, contracts.md, extensions.md"
                 " (+ api-index.{json,jsonl}) — "
                 (# records) " records, " (# tree.sources) " sources scanned.")))))

(main)
