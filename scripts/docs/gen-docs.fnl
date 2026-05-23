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

(fn read-file [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)] (table.insert out line))
    (p:close)
    out))

(fn keyword [v] (if v (.. ":" (tostring v)) ""))

(fn slug [s]
  (let [s (string.lower (tostring s))
        s (string.gsub s "[^%w]+" "-")
        s (string.gsub s "^-+" "")
        s (string.gsub s "-+$" "")]
    (if (= s "") "item" s)))

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

(fn export-anchor [e]
  (let [id (string.gsub (string.gsub e.id "!" "-bang") "%?" "-q")]
    (slug (.. id "-" (or e.path "unknown") "-" (or e.line 0)))))

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
    (table.insert out "## Table of contents")
    (table.insert out "")
    (each [_ m (ipairs order)]
      (let [items (. groups m)]
        (var has-visible? false)
        (each [_ e (ipairs items)]
          (when (or (visible-export? e) (data-kind? e))
            (set has-visible? true)))
        (when has-visible?
          (table.insert out (.. "- [" m "](#" (slug m) ")")))))
    (table.insert out "")
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
          (table.insert out (.. "## <a id=\"" (slug m) "\"></a>" m))
          (table.insert out "")
          (each [_ e (ipairs visible)]
            (let [sig (doc-signature e.doc nil)
                  summary (doc-summary e.doc)
                  line (or (and e.doc e.doc.line) e.line "?")]
              (table.insert out (.. "### <a id=\"" (export-anchor e) "\"></a>`" e.id "`"))
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

(fn field-type [fdef]
  (or fdef.type
      (and fdef.const (.. ":" (tostring fdef.const)))
      (and fdef.enum
           (.. "enum " (table.concat
                         (icollect [_ v (ipairs fdef.enum)]
                           (.. ":" (tostring v)))
                         " | ")))
      "any"))

(fn contract-field-anchor [prefix name field-name]
  (slug (.. "contract-field-" (tostring prefix) "-" (tostring name) "-" (tostring field-name))))

(fn contract-member-anchor [prefix name category value]
  (slug (.. "contract-member-" (tostring prefix) "-" (tostring name) "-" category "-" (tostring value))))

(fn contract-member-label [category value]
  (if (or (= category "enum") (= category "method") (= category "optional-method"))
      (.. ":" (tostring value))
      (tostring value)))

(fn contract-member-summary [entry-name category value]
  (let [label (contract-member-label category value)]
    (if (= category "variant")
        (.. label " is a " (tostring entry-name) " union variant.")
        (= category "enum")
        (.. label " is a " (tostring entry-name) " enum value.")
        (= category "method")
        (.. label " is a required " (tostring entry-name) " interface method.")
        (= category "optional-method")
        (.. label " is an optional " (tostring entry-name) " interface method.")
        (.. label " is a " (tostring entry-name) " contract member."))))

(fn contract-entry-anchor [prefix name]
  (slug (.. "contract-entry-" (tostring prefix) "-" (tostring name))))

(fn render-field-row [prefix cname fname fdef]
  (let [type (field-type fdef)
        req (if fdef.required " (required)" "")
        summary (or fdef.summary "")]
    (.. "- <a id=\"" (contract-field-anchor prefix cname fname) "\"></a>`:" fname "` `" type "`" req
        (if (= summary "") "" (.. " — " summary)))))

(fn render-member-row [prefix cname category value]
  (.. "- <a id=\"" (contract-member-anchor prefix cname category value) "\"></a>`"
      (contract-member-label category value) "` `" category "` — "
      (contract-member-summary cname category value)))

(fn render-contract-entry [prefix name body]
  (let [out [(.. "### <a id=\"" (contract-entry-anchor prefix name) "\"></a>`" name "`")
             (or body.summary "")]]
    (when body.fields
      (let [keys []]
        (each [k _ (pairs body.fields)] (table.insert keys k))
        (table.sort keys)
        (table.insert out "")
        (each [_ k (ipairs keys)]
          (table.insert out (render-field-row prefix name k (. body.fields k))))))
    (let [member-rows []]
      (each [_ v (ipairs (or body.variants []))]
        (table.insert member-rows (render-member-row prefix name "variant" v)))
      (each [_ v (ipairs (or body.enum []))]
        (table.insert member-rows (render-member-row prefix name "enum" v)))
      (each [_ m (ipairs (or body.methods []))]
        (table.insert member-rows (render-member-row prefix name "method" m)))
      (each [_ m (ipairs (or body.optional-methods []))]
        (table.insert member-rows (render-member-row prefix name "optional-method" m)))
      (when (> (# member-rows) 0)
        (table.insert out "")
        (each [_ row (ipairs member-rows)]
          (table.insert out row))))
    (table.insert out "")
    (table.concat out "\n")))

(fn render-contracts-md [contracts]
  (let [out ["# Fen contracts"
             ""
             "The non-function public surface: canonical types, extension"
             "register kinds, event-bus shapes, and provider/auth/session"
             "interfaces."
             ""]
        sections [{:key :register-kinds :prefix :register-kind :label "Register kinds"}
                  {:key :events :prefix :event :label "Events"}
                  {:key :types :prefix :type :label "Canonical types"}
                  {:key :interfaces :prefix :interface :label "Interfaces"}]]
    (table.insert out "## Table of contents")
    (table.insert out "")
    (each [_ s (ipairs sections)]
      (when (. contracts s.key)
        (table.insert out (.. "- [" s.label "](#" (slug (.. "contract-section-" s.label)) ")"))))
    (table.insert out "")
    (each [_ s (ipairs sections)]
      (let [bucket (. contracts s.key)]
        (when bucket
          (table.insert out (.. "## <a id=\"" (slug (.. "contract-section-" s.label)) "\"></a>" s.label))
          (table.insert out "")
          (let [keys []]
            (each [k _ (pairs bucket)] (table.insert keys (tostring k)))
            (table.sort keys)
            (each [_ k (ipairs keys)]
              (table.insert out (render-contract-entry s.prefix k (. bucket k))))))))
    (table.concat out "\n")))

(fn register-site-anchor [r name]
  (slug (.. "register-site-" (tostring (or r.kind "unknown")) "-" name "-"
           (or r.path "unknown") "-" (or r.line 0))))

(fn register-site-summary [r name]
  (or r.description
      (let [kind (tostring (or r.kind "contribution"))
            label (tostring (or name "(dynamic)"))]
        (if (= kind :status)
            (.. "Registered " label " status-line item contribution.")
            (= kind :presenter)
            (.. "Registered " label " presenter contribution.")
            (= kind :hook)
            (.. "Registered " label " extension hook contribution.")
            (.. "Registered " label " " kind " contribution.")))))

(fn scan-extension-manifests []
  (let [items []]
    (each [_ path (ipairs (command-lines "find extensions -name manifest.fnl -type f | sort"))]
      (let [text (read-file path)
            name (or (string.match text ":name%s+:([%w_%-]+)")
                     (string.match text ":name%s+\"([^\"]+)\"")
                     (string.match path "extensions/([^/]+)/manifest%.fnl$"))
            description (or (string.match text ":description%s+\"([^\"]*)\"")
                            (.. "First-party " name " extension manifest."))]
        (table.insert items {:kind "extension"
                             :name name
                             :description description
                             :path path
                             :line 1})))
    items))

(fn render-extensions-md [register-sites]
  (let [groups {}
        order []]
    (fn add-site! [r]
      (let [k (or r.kind "unknown")]
        (when (not (. groups k))
          (table.insert order k)
          (tset groups k []))
        (table.insert (. groups k) r)))
    (each [_ r (ipairs register-sites)]
      (add-site! r))
    (each [_ r (ipairs (scan-extension-manifests))]
      (add-site! r))
    (table.sort order)
    (let [out ["# Fen extension contributions"
               ""
               "Discovered `(api.register :kind {...})` sites across the"
               "first-party extensions and core. Names extracted from"
               "literal `:name` fields; dynamic registrations show the"
               "source path with the name omitted."
               ""]]
      (table.insert out "## Table of contents")
      (table.insert out "")
      (each [_ k (ipairs order)]
        (table.insert out (.. "- [:" k "](#" (slug (.. "extension-kind-" k)) ")")))
      (table.insert out "")
      (each [_ k (ipairs order)]
        (table.insert out (.. "## <a id=\"" (slug (.. "extension-kind-" k)) "\"></a>:" k))
        (table.insert out "")
        (let [items (. groups k)]
          (each [_ r (ipairs items)]
            (let [name-str (if r.name (.. "`" r.name "`") "_(dynamic)_")
                  name (or r.name "(dynamic)")
                  anchor (register-site-anchor r name)
                  desc (register-site-summary r name)
                  loc (.. r.path ":" (tostring (or r.line "?")))]
              (table.insert out (.. "- <a id=\"" anchor "\"></a>" name-str " — " desc " — _" loc "_"))))
          (table.insert out "")))
      (table.concat out "\n"))))

;; ---------------------------------------------------------------------------
;; Index records
;; ---------------------------------------------------------------------------

(fn normalize-tag [tag]
  (let [s0 (string.lower (tostring (or tag "")))
        s1 (string.gsub s0 "^:" "")
        s2 (string.gsub s1 "_" "-")]
    s2))

(fn add-tag! [out seen tag]
  (let [s (normalize-tag tag)]
    (when (and (not= s "") (not (. seen s)))
      (tset seen s true)
      (table.insert out s))))

(fn add-tag-tokens! [out seen text]
  (each [tok (string.gmatch (tostring (or text "")) "[%w_%-]+")]
    (add-tag! out seen tok)))

(fn index-tags [...]
  (let [out []
        seen {}]
    (each [_ v (ipairs [...])]
      (add-tag-tokens! out seen v))
    out))

(fn export-record [e]
  (let [doc e.doc
        rec {:id e.id
             :kind (or (and doc doc.kind) "function")
             :path e.path
             :line (or (and doc doc.line) e.line 0)
             :href (.. "core.html#" (export-anchor e))}]
    (when doc
      (when doc.summary (tset rec :summary doc.summary))
      (when doc.signature (tset rec :signature doc.signature))
      (when (and doc.tags (> (# doc.tags) 0)) (tset rec :tags doc.tags))
      (when doc.see-also (tset rec :see-also doc.see-also)))
    rec))

(fn contract-page [prefix]
  (if (= prefix :register-kind) "register-kinds.html"
      (= prefix :event) "events.html"
      (= prefix :type) "types.html"
      (= prefix :interface) "interfaces.html"
      "contracts.html"))

(fn contract-field-record [prefix kind parent-name field-name field]
  (let [ty (field-type field)]
    {:id (.. prefix ":" parent-name "." (tostring field-name))
     :kind "contract-field"
     :summary (or field.summary "")
     :signature (.. ":" (tostring field-name) " " ty)
     :tags (index-tags :contracts kind :field parent-name field-name ty)
     :href (.. (contract-page prefix) "#" (contract-field-anchor prefix parent-name field-name))
     :parent (.. prefix ":" parent-name)
     :field (.. ":" (tostring field-name))}))

(fn contract-member-record [prefix kind parent-name category value]
  {:id (.. prefix ":" parent-name ":" category ":" (tostring value))
   :kind "contract-member"
   :name (contract-member-label category value)
   :summary (contract-member-summary parent-name category value)
   :signature (contract-member-label category value)
   :tags (index-tags :contracts kind :member category parent-name value)
   :href (.. (contract-page prefix) "#" (contract-member-anchor prefix parent-name category value))
   :parent (.. prefix ":" parent-name)
   :member (contract-member-label category value)
   :category category})

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
                                :summary (or body.summary "")
                                :tags (index-tags :contracts kind k)
                                :href (.. (contract-page prefix) "#" (slug (.. "contract-entry-" prefix "-" k)))}]
                       (when body.fields
                         (let [fkeys []]
                           (each [fk _ (pairs body.fields)] (table.insert fkeys fk))
                           (table.sort fkeys)
                           (tset rec :fields fkeys)
                           (each [_ fk (ipairs fkeys)]
                             (table.insert out
                                           (contract-field-record prefix kind k fk (. body.fields fk))))))
                       (when body.enum
                         (tset rec :enum body.enum)
                         (each [_ v (ipairs body.enum)]
                           (table.insert out (contract-member-record prefix kind k "enum" v))))
                       (when body.variants
                         (tset rec :variants body.variants)
                         (each [_ v (ipairs body.variants)]
                           (table.insert out (contract-member-record prefix kind k "variant" v))))
                       (when body.methods
                         (tset rec :methods body.methods)
                         (each [_ m (ipairs body.methods)]
                           (table.insert out (contract-member-record prefix kind k "method" m))))
                       (when body.optional-methods
                         (tset rec :optional-methods body.optional-methods)
                         (each [_ m (ipairs body.optional-methods)]
                           (table.insert out (contract-member-record prefix kind k "optional-method" m))))
                       (table.insert out rec))))))]
    (push :register-kind :register-kind contracts.register-kinds)
    (push :event :event contracts.events)
    (push :type :type contracts.types)
    (push :interface :interface contracts.interfaces)
    out))

(local REGISTER-KIND-PAGES
  {:auth-backend "auth-backends.html"
   :command "commands.html"
   :control "controls.html"
   :hook "contributions.html"
   :panel "panels.html"
   :presenter "presenters.html"
   :prompt-fragment "prompt-fragments.html"
   :provider "providers.html"
   :session-backend "session-backends.html"
   :status "status.html"
   :tool "tools.html"})

(fn register-kind-page [kind]
  (or (. REGISTER-KIND-PAGES kind)
      (.. (slug kind) ".html")))

(fn extension-records [register-sites]
  (let [out []]
    (each [_ r (ipairs register-sites)]
      (let [name (or r.name "(dynamic)")
            desc (register-site-summary r name)
            source-key (slug (.. (or r.path "unknown") "-" (or r.line 0)))
            id (.. "register-site:" r.kind ":" name ":" source-key)]
        (table.insert out
          {:id id
           :kind (.. "register-site:" r.kind)
           :name name
           :summary desc
           :description desc
           :tags (index-tags :extensions :register-site r.kind name)
           :href (.. (register-kind-page r.kind) "#"
                     (register-site-anchor r name))
           :path r.path
           :line (or r.line 0)})))
    out))

(fn extension-manifest-records []
  (let [out []]
    (each [_ r (ipairs (scan-extension-manifests))]
      (let [name r.name
            desc r.description]
        (table.insert out
          {:id (.. "extension:" name)
           :kind "extension"
           :name name
           :summary desc
           :description desc
           :tags (index-tags :extensions :extension name)
           :href (.. "extensions.html#" (register-site-anchor r name))
           :path r.path
           :line 1})))
    out))

(fn generated-page-records []
  [{:id "generated:core"
    :kind "generated-page"
    :name "Core API"
    :summary "Generated reference for exported Fennel modules, functions, and documented data values."
    :tags (index-tags :generated :core :api)
    :href "core.html"
    :path "docs/generated/core.md"
    :line 1}
   {:id "generated:contracts"
    :kind "generated-page"
    :name "Contracts"
    :summary "Generated reference for register kinds, events, canonical types, interfaces, fields, and members."
    :tags (index-tags :generated :contracts :api)
    :href "contracts.html"
    :path "docs/generated/contracts.md"
    :line 1}
   {:id "generated:extensions"
    :kind "generated-page"
    :name "Extension contributions"
    :summary "Generated reference for first-party extension manifests and registered commands, tools, providers, panels, status items, and presenters."
    :tags (index-tags :generated :extensions :contributions)
    :href "contributions.html"
    :path "docs/generated/extensions.md"
    :line 1}])

(fn doc-page-summary [lines]
  (var in-code? false)
  (var done? false)
  (let [summary-lines []]
    (each [_ line (ipairs lines)]
      (when (not done?)
        (if (string.match line "^```")
            (set in-code? (not in-code?))
            in-code?
            nil
            (string.match line "^#+%s+")
            nil
            (string.match line "^%s*$")
            (when (> (# summary-lines) 0)
              (set done? true))
            (do
              (table.insert summary-lines line)))))
    (table.concat summary-lines " ")))

(fn doc-page-records []
  (let [out []]
    (each [_ path (ipairs (command-lines "find docs -maxdepth 1 -name '*.md' -type f | sort"))]
      (let [base (string.match path "([^/]+)%.md$")
            page (.. "doc-" (slug base) ".html")
            lines []]
        (each [line (string.gmatch (.. (read-file path) "\n") "([^\n]*)\n")]
          (table.insert lines line))
        (table.insert out
          {:id (.. "doc:" base)
           :kind "doc-page"
           :name base
           :summary (doc-page-summary lines)
           :tags (index-tags :docs base)
           :href page
           :path path
           :line 1})))
    out))

(fn trim [s]
  (let [s (string.gsub (or s "") "^%s+" "")
        s (string.gsub s "%s+$" "")]
    s))

(fn split-table-cells [line]
  (let [line (string.gsub (string.gsub (or line "") "^%s*|" "") "|%s*$" "")
        cells []]
    (each [cell (string.gmatch (.. line "|") "([^|]*)|")]
      (let [cell (trim (string.gsub cell "`([^`]+)`" "%1"))]
        (when (not= cell "")
          (table.insert cells cell))))
    cells))

(fn table-summary-fragment [line]
  (let [cells (split-table-cells line)]
    (if (> (# cells) 0)
        (.. "Reference table covering " (table.concat cells ", ") ".")
        "Reference table.")))

(fn doc-heading-summary [base heading lines start-index]
  (var in-code? false)
  (var done? false)
  (let [summary-lines []]
    (for [i (+ start-index 1) (# lines)]
      (when (not done?)
        (let [line (. lines i)]
          (if (string.match line "^```")
              (set done? true)
              in-code?
              nil
              (string.match line "^#+%s+")
              (set done? true)
              (string.match line "^%s*$")
              (when (> (# summary-lines) 0)
                (set done? true))
              (string.match line "^%s*|")
              (do
                (table.insert summary-lines (table-summary-fragment line))
                (set done? true))
              (string.match line "^%s*[-*]%s+(.+)$")
              (let [item (string.match line "^%s*[-*]%s+(.+)$")]
                (if (> (# summary-lines) 0)
                    (set done? true)
                    (table.insert summary-lines item)))
              (table.insert summary-lines line)))))
    (if (> (# summary-lines) 0)
        (.. base " / " heading " — " (table.concat summary-lines " "))
        (.. base " / " heading))))

(fn doc-heading-records []
  (let [out []]
    (each [_ path (ipairs (command-lines "find docs -maxdepth 1 -name '*.md' -type f | sort"))]
      (let [base (string.match path "([^/]+)%.md$")
            page (.. "doc-" (slug base) ".html")
            seen {}
            lines []]
        (each [line (string.gmatch (.. (read-file path) "\n") "([^\n]*)\n")]
          (table.insert lines line))
        (var in-code? false)
        (each [line-no line (ipairs lines)]
          (if (string.match line "^```")
              (set in-code? (not in-code?))
              (not in-code?)
              (let [(marks text) (string.match line "^(#+)%s+(.+)$")]
                (when marks
                  (let [base-id (slug (.. "doc-heading-" text))
                        count (or (. seen base-id) 0)
                        anchor (if (= count 0) base-id (.. base-id "-" (+ count 1)))]
                    (tset seen base-id (+ count 1))
                    (table.insert out
                      {:id (.. "doc:" base "#" anchor)
                       :kind "doc-heading"
                       :name text
                       :summary (doc-heading-summary base text lines line-no)
                       :tags (index-tags :docs base text)
                       :href (.. page "#" anchor)
                       :path path
                       :line line-no}))))))))
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
      (each [_ r (ipairs (extension-manifest-records))]
        (table.insert records r))
      (each [_ r (ipairs (generated-page-records))]
        (table.insert records r))
      (each [_ r (ipairs (doc-page-records))]
        (table.insert records r))
      (each [_ r (ipairs (doc-heading-records))]
        (table.insert records r))
      (write-index records)
      (print (.. "Wrote " OUT-DIR "/core.md, contracts.md, extensions.md"
                 " (+ api-index.{json,jsonl}) — "
                 (# records) " records, " (# tree.sources) " sources scanned.")))))

(main)
