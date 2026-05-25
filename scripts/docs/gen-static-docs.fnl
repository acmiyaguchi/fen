#!/usr/bin/env fennel
;; Generate static HTML documentation under docs/generated/html/.
;;
;; This mirrors the broad topic shape of the in-agent /docs extension, but is
;; source-scanned and also renders hand-written docs/*.md pages.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path
         ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"))

(local scanner (require :docs.scanner))

(local OUT-DIR "docs/generated/html")

;; Generated Markdown/JSON artifacts published next to the HTML, as
;; [filename link-label] pairs. Declared once so the home-page links and the
;; self-contained-site copy step can't drift out of sync.
(local GENERATED-ARTIFACTS
  [[:core.md "Generated core Markdown"]
   [:contracts.md "Generated contracts Markdown"]
   [:extensions.md "Generated extensions Markdown"]
   [:api-index.json "API index JSON"]
   [:api-index.jsonl "API index JSONL"]])

(fn write-file [path text]
  (os.execute (.. "mkdir -p " (string.match path "^(.+)/[^/]+$")))
  (let [f (assert (io.open path :w))]
    (f:write text)
    (f:close)))

(fn run! [cmd]
  "Run a shell command, erroring out if it fails. Asset copies must be fatal:
a silently failed copy would publish a broken site. (os.execute returns true
on Lua 5.4, 0 on 5.1; accept either.)"
  (let [ok (os.execute cmd)]
    (assert (or (= ok true) (= ok 0)) (.. "command failed: " cmd))))

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

(fn split-lines [text]
  (let [out []]
    (each [line (string.gmatch (.. (or text "") "\n") "([^\n]*)\n")]
      (table.insert out line))
    out))

(fn html-escape [s]
  (let [s (tostring (or s ""))
        s (string.gsub s "&" "&amp;")
        s (string.gsub s "<" "&lt;")
        s (string.gsub s ">" "&gt;")
        s (string.gsub s "\"" "&quot;")]
    s))

(fn attr-escape [s] (html-escape s))

(fn slug [s]
  (let [s (string.lower (tostring s))
        s (string.gsub s "[^%w]+" "-")
        s (string.gsub s "^-+" "")
        s (string.gsub s "-+$" "")]
    (if (= s "") "item" s)))

(fn link [href text]
  (.. "<a href=\"" (attr-escape href) "\">" (html-escape text) "</a>"))

(local SITE-CSS
"html,body{max-width:100%;overflow-x:hidden}\n\
body{font:16px/1.5 sans-serif;margin:0;color:#111;background:#fff}\n\
a{color:#0645ad;overflow-wrap:anywhere}\n\
.permalink{font-size:.8em;text-decoration:none;color:#777;margin-left:.35em}\n\
.nav{border-bottom:1px solid #ccc;padding:.6em 1em;background:#f7f7f7}\n\
.nav a{display:inline-block;margin:0 1em .2em 0;text-decoration:none}\n\
.nav a.active{font-weight:bold;color:#111}\n\
.main{max-width:60em;width:100%;box-sizing:border-box;margin:0 auto;padding:1em;overflow-wrap:anywhere}\n\
h1,h2,h3{line-height:1.25;overflow-wrap:anywhere}\n\
h2{border-top:1px solid #ddd;padding-top:1em;margin-top:1.5em}\n\
.card{border:1px solid #ccc;background:#fafafa;margin:.8em 0;padding:.8em;box-sizing:border-box}\n\
table{border-collapse:collapse;width:100%;max-width:100%;display:block;overflow-x:auto;margin:1em 0}\n\
caption{font-weight:bold;text-align:left;margin:.2em 0}\n\
th,td{border:1px solid #ccc;padding:.35em .5em;text-align:left;vertical-align:top;overflow-wrap:anywhere;word-break:break-word}\n\
code,pre{font-family:monospace}\n\
code{background:#f3f3f3;padding:.05em .2em;white-space:normal;overflow-wrap:anywhere;word-break:break-word}\n\
pre{background:#f3f3f3;border:1px solid #ccc;padding:1em;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;box-sizing:border-box;max-width:100%}\n\
.muted,.source{color:#666}\n\
.source{font-size:.9em;overflow-wrap:anywhere;word-break:break-word}\n\
.tags{font-size:.9em;color:#666}\n\
.toc{border:1px solid #ddd;background:#fafafa;padding:.7em 1em;margin:0 0 1em 0}\n\
.toc-title{font-weight:bold;margin-bottom:.3em}\n\
.toc ul{margin:.2em 0 0 1.2em;padding:0}\n\
.graph-preview{border:1px solid #ddd;background:#fff;margin:.7em 0;padding:.5em;overflow:auto}\n\
.graph-preview img{max-width:100%;height:auto}\n\
.artifact-list{columns:2;column-gap:2em}\n\
@media(max-width:640px){body{font-size:15px}.main{padding:.7em}.nav{padding:.5em}.nav a{display:block;margin:.2em 0}table{font-size:.9em}.artifact-list{columns:1}}\n")

(fn strip-tags [s]
  (let [s (string.gsub (or s "") "<a class=\"permalink\".-</a>" "")
        s (string.gsub s "<[^>]+>" "")]
    s))

(fn section-toc [body]
  (let [items []]
    (each [id inner (string.gmatch body "<h2 id=\"([^\"]+)\"[^>]*>(.-)</h2>")]
      (table.insert items (.. "<li><a href=\"#" (attr-escape id) "\">" (strip-tags inner) "</a></li>")))
    (if (>= (# items) 4)
        (.. "<nav class=\"toc\" aria-label=\"Section table of contents\"><div class=\"toc-title\">On this page</div><ul>"
            (table.concat items "")
            "</ul></nav>\n")
        "")))

(fn render-page [title body ?section]
  (let [nav [["index.html" "Home"]
             ["docs.html" "Docs"]
             ["reference.html" "Reference"]
             ["core.html" "Core API"]
             ["contributions.html" "Extension contributions"]
             ["contracts.html" "Contracts"]
             ["graphs.html" "Graphs"]]
        nav-html (table.concat
                   (icollect [_ item (ipairs nav)]
                     (let [href (. item 1) label (. item 2)]
                       (.. "<a" (if (= label ?section) " class=\"active\"" "")
                           " href=\"" href "\">" label "</a>")))
                   "")]
    (.. "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        "<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
        "<title>" (html-escape title) "</title>\n"
        "<link rel=\"stylesheet\" href=\"style.css\">\n"
        "</head>\n<body><div class=\"nav\">" nav-html "</div><div class=\"main\">\n"
        (section-toc body) body "\n</div></body></html>\n")))

(fn permalink [id]
  (.. " <a class=\"permalink\" href=\"#" (attr-escape id) "\" aria-label=\"Link to this section\">#</a>"))

(fn aggregate-section-heading [topic]
  (let [id (slug (.. "aggregate-section-" (tostring topic.name)))]
    (.. "<h2 id=\"" (attr-escape id) "\">"
        (link (.. (slug topic.name) ".html") (tostring topic.name))
        (permalink id)
        "</h2>")))

(fn markdown-inline [s]
  (let [s (html-escape s)
        s (string.gsub s "%!%[([^%]]*)%]%(([^%)]+)%)"
                       "<img src=\"%2\" alt=\"%1\" style=\"max-width:100%%;height:auto\">")
        s (string.gsub s "%[([^%]]+)%]%(([^%)]+)%)"
                       "<a href=\"%2\">%1</a>")
        s (string.gsub s "`([^`]+)`" "<code>%1</code>")
        s (string.gsub s "%*%*([^*]+)%*%*" "<strong>%1</strong>")
        s (string.gsub s "%*([^*<>]+)%*" "<em>%1</em>")]
    s))

(fn trim [s]
  (let [s (string.gsub (or s "") "^%s+" "")
        s (string.gsub s "%s+$" "")]
    s))

(fn table-separator-row? [line]
  (and (string.match line "^%s*|")
       (string.match line "^%s*|?[%s|%-%:]+|?%s*$")))

(fn split-table-row [line]
  (let [line (string.gsub (string.gsub line "^%s*|" "") "|%s*$" "")
        cells []]
    (each [cell (string.gmatch (.. line "|") "([^|]*)|")]
      (table.insert cells (trim cell)))
    cells))

(fn render-table [rows ?caption]
  (let [out ["<table>"]
        header (split-table-row (. rows 1))]
    (when ?caption
      (table.insert out (.. "<caption>" (markdown-inline ?caption) " table</caption>")))
    (table.insert out "<thead><tr>")
    (each [_ cell (ipairs header)]
      (table.insert out (.. "<th scope=\"col\">" (markdown-inline cell) "</th>")))
    (table.insert out "</tr></thead><tbody>")
    (for [i 3 (# rows)]
      (table.insert out "<tr>")
      (each [_ cell (ipairs (split-table-row (. rows i)))]
        (table.insert out (.. "<td>" (markdown-inline cell) "</td>")))
      (table.insert out "</tr>"))
    (table.insert out "</tbody></table>")
    (table.concat out "")))

(fn flush-paragraph [out para ?table-caption]
  (when (> (# para) 0)
    (if (and (>= (# para) 2)
             (string.match (. para 1) "^%s*|")
             (table-separator-row? (. para 2)))
        (table.insert out (render-table para (or ?table-caption "Reference")))
        (table.insert out (.. "<p>" (markdown-inline (table.concat para " ")) "</p>")))
    (while (> (# para) 0) (table.remove para))))

(fn markdown-to-html [md]
  "Small markdown renderer for repository docs: headings, paragraphs, lists, and fences."
  (let [out [] para [] heading-seen {}]
    (var in-code? false)
    (var current-heading nil)
    (var code-lines [])
    (var code-language nil)
    (var list-kind nil)
    (var pending-item nil)
    (var pending-subitems [])
    (fn flush-list-item []
      (when pending-item
        (var body (markdown-inline pending-item))
        (when (> (# pending-subitems) 0)
          (set body (.. body "<ul class=\"nested-list\">"
                        (table.concat
                          (icollect [_ item (ipairs pending-subitems)]
                            (.. "<li class=\"nested-list-item\">" (markdown-inline item) "</li>"))
                          "")
                        "</ul>")))
        (table.insert out (.. "<li>" body "</li>"))
        (while (> (# pending-subitems) 0) (table.remove pending-subitems))
        (set pending-item nil)))
    (fn close-list []
      (when list-kind
        (flush-list-item)
        (table.insert out (.. "</" list-kind ">"))
        (set list-kind nil)))
    (each [_ line (ipairs (split-lines md))]
      (let [fence (string.match line "^```")]
        (if in-code?
            (if fence
                (do
                  (let [class-attr (if code-language
                                        (.. " class=\"language-" (attr-escape (slug code-language)) "\"")
                                        "")]
                    (table.insert out (.. "<pre><code" class-attr ">" (html-escape (table.concat code-lines "\n")) "</code></pre>")))
                  (set code-lines [])
                  (set code-language nil)
                  (set in-code? false))
                (table.insert code-lines line))
            fence
            (do
              (flush-paragraph out para current-heading)
              (close-list)
              (set in-code? true)
              (set code-language (string.match line "^```%s*([%w_%-]+)"))
              (set code-lines []))
            (string.match line "^%s*$")
            (do
              (flush-paragraph out para current-heading)
              (close-list))
            (let [(marks text) (string.match line "^(#+)%s+(.+)$")]
              (if marks
                  (do
                    (flush-paragraph out para current-heading)
                    (close-list)
                    (set current-heading text)
                    (let [level (math.min 6 (# marks))
                          base-id (slug (.. "doc-heading-" text))
                          seen (or (. heading-seen base-id) 0)
                          id (if (= seen 0) base-id (.. base-id "-" (+ seen 1)))]
                      (tset heading-seen base-id (+ seen 1))
                      (table.insert out (.. "<h" level " id=\"" (attr-escape id) "\">" (markdown-inline text) (permalink id) "</h" level ">"))))
                  (let [nested-unordered-item (string.match line "^%s+[-*]%s+(.+)$")
                        unordered-item (string.match line "^[-*]%s+(.+)$")
                        ordered-item (string.match line "^%d+%.%s+(.+)$")
                        continuation (string.match line "^%s+(.+)$")
                        item (or unordered-item ordered-item)
                        new-kind (if ordered-item "ol" "ul")]
                    (if (and list-kind pending-item nested-unordered-item)
                        (table.insert pending-subitems nested-unordered-item)
                        item
                        (do
                          (flush-paragraph out para current-heading)
                          (when (and list-kind (not= list-kind new-kind))
                            (close-list))
                          (when (not list-kind)
                            (table.insert out (.. "<" new-kind ">"))
                            (set list-kind new-kind))
                          (flush-list-item)
                          (set pending-item item))
                        (and list-kind pending-item continuation)
                        (if (> (# pending-subitems) 0)
                            (tset pending-subitems (# pending-subitems)
                                  (.. (. pending-subitems (# pending-subitems)) " " continuation))
                            (set pending-item (.. pending-item " " continuation)))
                        (do
                          (close-list)
                          (table.insert para line)))))))))
    (when in-code?
      (let [class-attr (if code-language
                          (.. " class=\"language-" (attr-escape (slug code-language)) "\"")
                          "")]
        (table.insert out (.. "<pre><code" class-attr ">" (html-escape (table.concat code-lines "\n")) "</code></pre>"))))
    (flush-paragraph out para current-heading)
    (close-list)
    (table.concat out "\n")))

(local RUNTIME-TOPICS
  [{:name :commands :kind :command :summary "Registered slash commands."}
   {:name :tools :kind :tool :summary "Registered agent tools."}
   {:name :providers :kind :provider :summary "Registered LLM providers."}
   {:name :auth-backends :kind :auth-backend :summary "Registered auth backends."}
   {:name :session-backends :kind :session-backend :summary "Registered session persistence backends."}
   {:name :presenters :kind :presenter :summary "Registered interactive presenters."}
   {:name :controls :kind :control :summary "Registered keyboard/UI controls."}
   {:name :status :kind :status :summary "Registered status-line items."}
   {:name :panels :kind :panel :summary "Registered presenter panels."}
   {:name :prompt-fragments :kind :prompt-fragment :summary "Registered system-prompt fragments."}
   {:name :extensions :kind :extension :summary "First-party extension manifests."}])

(local CONTRACT-TOPICS
  [{:name :events :key :events :summary "Event-bus shapes."}
   {:name :types :key :types :summary "Canonical message/tool types."}
   {:name :register-kinds :key :register-kinds :summary "Extension API register kinds."}
   {:name :interfaces :key :interfaces :summary "Provider/auth/session interface records."}])

(fn sorted-keys [t]
  (let [keys []]
    (each [k _ (pairs (or t {}))] (table.insert keys (tostring k)))
    (table.sort keys)
    keys))

(fn group-register-sites [sites]
  (let [groups {}]
    (each [_ r (ipairs sites)]
      (let [k (or r.kind "unknown")]
        (when (not (. groups k)) (tset groups k []))
        (table.insert (. groups k) r)))
    groups))

(fn add-register-sites! [groups sites]
  (each [_ r (ipairs sites)]
    (let [k (or r.kind "unknown")]
      (when (not (. groups k)) (tset groups k []))
      (table.insert (. groups k) r)))
  groups)

(fn scan-extension-manifests []
  (let [items []]
    (each [_ path (ipairs (command-lines "find extensions -name manifest.fnl -type f | sort"))]
      (let [text (read-file path)
            name (or (string.match text ":name%s+:([%w_%-]+)")
                     (string.match text ":name%s+\"([^\"]+)\""))
            description (or (string.match text ":description%s+\"([^\"]*)\"") "")]
        (table.insert items {:kind :extension
                             :name name
                             :description description
                             :path path
                             :line 1})))
    items))

(fn register-summary [r]
  (or r.description
      (let [kind (tostring (or r.kind "contribution"))
            name (tostring (or r.name "(dynamic)"))]
        (if (= kind :status)
            (.. "Registered " name " status-line item contribution.")
            (= kind :presenter)
            (.. "Registered " name " presenter contribution.")
            (= kind :hook)
            (.. "Registered " name " extension hook contribution.")
            (.. "Registered " name " " kind " contribution.")))))

(fn register-site-anchor [r name]
  (slug (.. "register-site-" (tostring (or r.kind "unknown")) "-" name "-"
           (or r.path "unknown") "-" (or r.line 0))))

(fn render-register-topic [topic items ?embedded?]
  (let [rows []]
    (if (= (# items) 0)
        (table.insert rows "<p class=\"muted\">No source-scanned registrations.</p>")
        (do
          (table.sort items (fn [a b]
                              (< (tostring (or a.name "")) (tostring (or b.name "")))))
          (table.insert rows (.. "<table><caption>" (html-escape (.. (tostring topic.name) " contributions")) "</caption><thead><tr><th scope=\"col\">Name</th><th scope=\"col\">Description</th><th scope=\"col\">Source</th></tr></thead><tbody>"))
          (each [_ r (ipairs items)]
            (let [name (or r.name "(dynamic)")
                  row-id (register-site-anchor r name)]
              (table.insert rows
                (.. "<tr id=\"" (attr-escape row-id) "\"><td><code>" (html-escape name) "</code>" (permalink row-id) "</td><td>"
                    (markdown-inline (register-summary r)) "</td><td class=\"source\">"
                    (html-escape (.. r.path ":" (tostring (or r.line "?")))) "</td></tr>"))))
          (table.insert rows "</tbody></table>")))
    (if ?embedded?
        (.. "<p>" (markdown-inline topic.summary) "</p>" (table.concat rows "\n"))
        (.. "<h1>" (html-escape (tostring topic.name)) "</h1><p>" (markdown-inline topic.summary) "</p>"
            (table.concat rows "\n")))))

(fn field-type [f]
  (or f.type
      (and f.const (.. ":" (tostring f.const)))
      (and f.enum (.. "enum " (table.concat (icollect [_ v (ipairs f.enum)] (.. ":" (tostring v))) " | ")))
      "any"))

(fn contract-prefix [topic-key]
  (if (= topic-key :register-kinds) "register-kind"
      (= topic-key :events) "event"
      (= topic-key :types) "type"
      (= topic-key :interfaces) "interface"
      (tostring topic-key)))

(fn contract-field-anchor [prefix name field-name]
  (slug (.. "contract-field-" prefix "-" (tostring name) "-" (tostring field-name))))

(fn contract-member-anchor [prefix name category value]
  (slug (.. "contract-member-" prefix "-" (tostring name) "-" category "-" (tostring value))))

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

(fn render-field-table [topic-key name fields]
  (let [prefix (contract-prefix topic-key)
        rows [(.. "<table><caption>Fields for " (html-escape (tostring name)) " " (html-escape prefix) " contract</caption><thead><tr><th scope=\"col\">Field</th><th scope=\"col\">Type</th><th scope=\"col\">Required</th><th scope=\"col\">Summary</th></tr></thead><tbody>")]]
    (each [_ k (ipairs (sorted-keys fields))]
      (let [f (. fields k)
            ty (field-type f)
            row-id (contract-field-anchor prefix name k)]
        (table.insert rows
          (.. "<tr id=\"" (attr-escape row-id) "\"><td><code>:" (html-escape k) "</code>" (permalink row-id) "</td><td><code>" (html-escape ty)
              "</code></td><td>" (if f.required "yes" "") "</td><td>" (markdown-inline (or f.summary "")) "</td></tr>"))))
    (table.insert rows "</tbody></table>")
    (table.concat rows "\n")))

(fn render-member-table [topic-key name body]
  (let [prefix (contract-prefix topic-key)
        rows []
        add-members (fn [category vals]
                      (each [_ value (ipairs (or vals []))]
                        (let [row-id (contract-member-anchor prefix name category value)]
                          (table.insert rows
                            (.. "<tr id=\"" (attr-escape row-id) "\"><td><code>" (html-escape (contract-member-label category value))
                                "</code>" (permalink row-id) "</td><td>" (html-escape category) "</td><td>"
                                (markdown-inline (contract-member-summary name category value)) "</td></tr>")))))]
    (add-members "variant" body.variants)
    (add-members "enum" body.enum)
    (add-members "method" body.methods)
    (add-members "optional-method" body.optional-methods)
    (when (> (# rows) 0)
      (.. "<table><caption>Members for " (html-escape (tostring name)) " " (html-escape (contract-prefix topic-key)) " contract</caption><thead><tr><th scope=\"col\">Member</th><th scope=\"col\">Kind</th><th scope=\"col\">Summary</th></tr></thead><tbody>"
          (table.concat rows "\n")
          "</tbody></table>"))))

(fn render-contract-topic [topic contracts ?embedded?]
  (let [bucket (. contracts topic.key)
        out [(if ?embedded?
                 (.. "<p>" (markdown-inline topic.summary) "</p>")
                 (.. "<h1>" (html-escape (tostring topic.name)) "</h1><p>" (markdown-inline topic.summary) "</p>"))]]
    (each [_ name (ipairs (sorted-keys bucket))]
      (let [body (. bucket name)]
        (let [id (slug (.. "contract-entry-" (contract-prefix topic.key) "-" name))]
          (table.insert out (.. "<h2 id=\"" id "\"><code>" (html-escape name) "</code>" (permalink id) "</h2>")))
        (when body.summary (table.insert out (.. "<p>" (markdown-inline body.summary) "</p>")))
        (when body.fields (table.insert out (render-field-table topic.key name body.fields)))
        (let [members (render-member-table topic.key name body)]
          (when members (table.insert out members)))))
    (table.concat out "\n")))

(fn export-anchor [e]
  (let [id (string.gsub (string.gsub e.id "!" "-bang") "%?" "-q")]
    (slug (.. id "-" (or e.path "unknown") "-" (or e.line 0)))))

(fn module-graph-slug [mod]
  (let [s (string.gsub (tostring mod) "[^%w_%-]+" "-")
        s (string.gsub s "^-+" "")
        s (string.gsub s "-+$" "")]
    (if (= s "") "module" s)))

(fn file-exists? [path]
  (let [f (io.open path :r)]
    (if f (do (f:close) true) false)))

(fn module-graph-html [mod]
  (let [slug (module-graph-slug mod)
        disk (.. "docs/generated/graphs/modules/" slug ".svg")
        rel (.. "graphs/modules/" slug)]
    (if (file-exists? disk)
        (.. "<p class=\"source\">Module neighborhood graph: "
            (link (.. rel ".dot") "DOT") " · "
            (link (.. rel ".svg") "SVG") "</p>"
            "<div class=\"graph-preview\"><a href=\"" (attr-escape (.. rel ".svg")) "\">"
            "<img src=\"" (attr-escape (.. rel ".svg")) "\" alt=\"" (attr-escape (.. mod " module graph")) "\">"
            "</a></div>")
        "")))

(fn render-core [exports]
  (let [groups {} order []]
    (each [_ e (ipairs exports)]
      (let [m (or e.module "(unknown)")]
        (when (not (. groups m))
          (tset groups m [])
          (table.insert order m))
        (table.insert (. groups m) e)))
    (table.sort order)
    (let [out ["<h1>Fen core API</h1><p>Exported Fennel surfaces discovered from source. Inline <code>@doc</code> blocks provide summaries and signatures where present.</p>"]]
      (each [_ m (ipairs order)]
        (let [id (slug (.. "core-module-" m))]
          (table.insert out (.. "<h2 id=\"" id "\">" (html-escape m) (permalink id) "</h2>"))
          (table.insert out (module-graph-html m)))
        (each [_ e (ipairs (. groups m))]
          (let [doc e.doc]
            (let [id (export-anchor e)]
              (table.insert out (.. "<h3 id=\"" id "\"><code>" (html-escape e.id) "</code>" (permalink id) "</h3>")))
            (when (or e.signature (and doc doc.signature))
              (table.insert out (.. "<p><code>" (html-escape (or (and doc doc.signature) e.signature)) "</code></p>")))
            (when (and doc doc.summary) (table.insert out (.. "<p>" (markdown-inline doc.summary) "</p>")))
            (when (and doc doc.tags (> (# doc.tags) 0))
              (table.insert out
                (.. "<p class=\"tags\"><span class=\"muted\">tags:</span> "
                    (html-escape (table.concat doc.tags ", "))
                    "</p>")))
            (table.insert out (.. "<p class=\"source\">" (html-escape (.. e.path ":" (tostring (or (and doc doc.line) e.line "?")))) "</p>")))))
      (table.concat out "\n"))))

(fn doc-page-summary [path]
  (var in-code? false)
  (var done? false)
  (let [summary-lines []]
    (each [_ line (ipairs (split-lines (read-file path)))]
      (when (not done?)
        (if (string.match line "^```")
            (set in-code? (not in-code?))
            in-code?
            nil
            (string.match line "^%s*$")
            (when (> (# summary-lines) 0)
              (set done? true))
            (or (string.match line "^#+%s+")
                (string.match line "^%s*[-*]%s+"))
            (when (> (# summary-lines) 0)
              (set done? true))
            (table.insert summary-lines line))))
    (if (> (# summary-lines) 0)
        (table.concat summary-lines " ")
        "Repository documentation page.")))

(fn render-doc-index [doc-paths]
  (let [out ["<h1>Repository docs</h1><p>Hand-written markdown pages from <code>docs/</code>.</p><ul>"]]
    (each [_ path (ipairs doc-paths)]
      (let [base (string.match path "([^/]+)%.md$")
            summary (doc-page-summary path)]
        (table.insert out
          (.. "<li>" (link (.. "doc-" (slug base) ".html") base)
              " <span class=\"source\">" (html-escape path) "</span>"
              "<p class=\"doc-summary\">" (markdown-inline summary) "</p></li>"))))
    (table.insert out "</ul>")
    (table.concat out "\n")))

(fn rewrite-doc-links [html doc-bases]
  "Rewrite relative `*.md` links to their generated `doc-*.html` pages.
  Hand-written docs link to sibling markdown (e.g. `architecture.md`) so they
  resolve when browsed on GitHub; on the static site those become `doc-*.html`.
  Only basenames matching a known docs/ page are rewritten; external and
  unknown links pass through unchanged."
  (string.gsub html "href=\"([^\"]+)\""
    (fn [href]
      (let [file (string.match href "^([^#]*)")
            frag (string.match href "(#[^\"]*)$")
            base (string.match (or file "") "([^/]+)%.md$")]
        (if (and base (. doc-bases base))
            (.. "href=\"doc-" (slug base) ".html" (or frag "") "\"")
            (.. "href=\"" href "\""))))))

(fn render-home [register-groups contracts doc-paths]
  (let [cards []]
    (each [_ t (ipairs RUNTIME-TOPICS)]
      (let [n (# (or (. register-groups t.kind) []))]
        (table.insert cards (.. "<div class=\"card\"><h3>" (link (.. (slug t.name) ".html") (tostring t.name)) "</h3><p>" (markdown-inline t.summary) "</p><p class=\"muted\">" n " records</p></div>"))))
    (each [_ t (ipairs CONTRACT-TOPICS)]
      (let [n (# (sorted-keys (. contracts t.key)))]
        (table.insert cards (.. "<div class=\"card\"><h3>" (link (.. (slug t.name) ".html") (tostring t.name)) "</h3><p>" (markdown-inline t.summary) "</p><p class=\"muted\">" n " records</p></div>"))))
    (.. "<h1>Generated reference</h1>"
        "<p>Reference scanned from Fennel source, extension registration sites, and structured contracts. See <a href=\"index.html\">Home</a> and <a href=\"docs.html\">Docs</a> for the hand-written guides.</p>"
        "<div class=\"grid\">" (table.concat cards "\n") "</div>"
        "<h2>Other pages</h2><ul>"
        "<li>" (link "core.html" "Core API") "</li>"
        "<li>" (link "contributions.html" "All extension contributions") "</li>"
        "<li>" (link "contracts.html" "All contracts") "</li>"
        "<li>" (link "graphs.html" "Generated graphs") "</li>"
        "<li>" (link "docs.html" (.. "Repository docs (" (# doc-paths) ")")) "</li>"
        "</ul>"
        "<h2>Generated artifacts</h2>"
        "<p>Markdown references are useful for review, while the API indexes are machine-readable inputs for search and agent tooling.</p>"
        "<ul>"
        (table.concat (icollect [_ [name label] (ipairs GENERATED-ARTIFACTS)]
                        (.. "<li>" (link name label) "</li>")) "")
        "<li>" (link "graphs/subsystems.dot" "Subsystem graph DOT") "</li>"
        "<li>" (link "graphs/subsystems.svg" "Subsystem graph SVG") "</li>"
        "<li>" (link "graphs/modules.dot" "Module graph DOT") "</li>"
        "<li>" (link "graphs/modules.svg" "Module graph SVG") "</li>"
        "<li>" (link "graphs/modules-clustered.dot" "Clustered module graph DOT") "</li>"
        "<li>" (link "graphs/modules-clustered.svg" "Clustered module graph SVG") "</li>"
        "<li>" (link "graphs/summary.md" "Generated graph summary Markdown") "</li>"
        "</ul>")))

(fn write-doc-pages [doc-paths]
  (each [_ path (ipairs doc-paths)]
    (let [base (string.match path "([^/]+)%.md$")
          html (markdown-to-html (read-file path))]
      (write-file (.. OUT-DIR "/doc-" (slug base) ".html")
                  (render-page (.. "Fen docs: " base) html "Docs")))))

(fn basename [path]
  (or (string.match (tostring path) "([^/]+)$") (tostring path)))

(fn strip-ext [path]
  (or (string.match (basename path) "^(.+)%.%w+$") (basename path)))

(fn graph-artifact-links [base-path label]
  (let [dot (.. base-path ".dot")
        svg (.. base-path ".svg")]
    (.. (link dot (.. label " DOT")) " · " (link svg (.. label " SVG")))))

(fn graph-preview [base-path label]
  (.. "<section class=\"card\"><h2 id=\"" (attr-escape (slug (.. "graph-" label))) "\">"
      (html-escape label) (permalink (slug (.. "graph-" label))) "</h2>"
      "<p>" (graph-artifact-links base-path label) "</p>"
      "<div class=\"graph-preview\"><a href=\"" (attr-escape (.. base-path ".svg")) "\">"
      "<img src=\"" (attr-escape (.. base-path ".svg")) "\" alt=\"" (attr-escape label) " graph\">"
      "</a></div></section>"))

(fn render-graphs-page []
  (let [extension-dots (command-lines "find docs/generated/graphs/extensions -name '*.dot' -type f | sort")
        extension-items []
        summary (read-file "docs/generated/graphs/summary.md")
        out ["<h1>Generated graphs</h1>"
             "<p>Graphviz artifacts generated by <code>make graphs</code>. Use these alongside the API and contract pages to navigate module dependencies, subsystem boundaries, and first-party extension contributions.</p>"
             "<h2 id=\"graph-overview\">Overview graphs</h2>"
             (graph-preview "graphs/subsystems" "Subsystem graph")
             (graph-preview "graphs/modules" "Module graph")
             (graph-preview "graphs/modules-clustered" "Clustered module graph")
             "<h2 id=\"contribution-graphs\">Extension contribution graph</h2>"
             (graph-preview "graphs/contributions" "Extension contribution graph")
             "<h2 id=\"graph-summary\">Summary</h2>"
             (markdown-to-html summary)
             "<h2 id=\"extension-graphs\">Extension graphs</h2>"]]
    (each [_ dot-path (ipairs extension-dots)]
      (let [base (string.gsub dot-path "%.dot$" "")
            rel-base (string.match base "^docs/generated/(.+)$")
            label (strip-ext dot-path)]
        (table.insert extension-items
                      (.. "<li>" (graph-artifact-links rel-base label) "</li>"))))
    (if (> (# extension-items) 0)
        (table.insert out (.. "<ul class=\"artifact-list\">" (table.concat extension-items "\n") "</ul>"))
        (table.insert out "<p class=\"muted\">No per-extension graph artifacts found. Run <code>make graphs</code>.</p>"))
    (table.concat out "\n")))

(fn copy-site-assets! []
  "Copy referenced graph artifacts and generated Markdown/JSON into OUT-DIR so
the emitted site is self-contained — every link resolves locally, with no
parent-directory references that would break when served as a root."
  (run! (.. "mkdir -p " OUT-DIR "/graphs"))
  ;; Generated graphs (contributions, summary, per-module, per-extension) first,
  ;; then the tracked overview graphs whose .dot sources only live in docs/graphs.
  (run! (.. "cp -R docs/generated/graphs/. " OUT-DIR "/graphs/"))
  (run! (.. "cp -R docs/graphs/. " OUT-DIR "/graphs/"))
  (each [_ [name] (ipairs GENERATED-ARTIFACTS)]
    (run! (.. "cp docs/generated/" name " " OUT-DIR "/"))))

(fn main []
  (let [tree (scanner.scan-tree)
        agg (scanner.aggregate tree)
        contracts (scanner.read-contracts)
        register-groups (add-register-sites! (group-register-sites agg.register-sites)
                                             (scan-extension-manifests))
        ;; docs/README.md is the hand-written documentation home, not a topic
        ;; page; keep it out of the topic list so it is not double-listed or
        ;; rendered as a doc-*.html sub-page.
        all-doc-paths (command-lines "find docs -maxdepth 1 -name '*.md' -type f | sort")
        doc-paths (icollect [_ p (ipairs all-doc-paths)]
                    (when (not (string.match p "/README%.md$")) p))
        doc-bases (collect [_ p (ipairs doc-paths)]
                    (string.match p "([^/]+)%.md$") true)]
    (write-file (.. OUT-DIR "/style.css") SITE-CSS)
    (write-file (.. OUT-DIR "/index.html")
                (render-page "Fen documentation"
                             (rewrite-doc-links (markdown-to-html (read-file "docs/README.md")) doc-bases)
                             "Home"))
    (write-file (.. OUT-DIR "/reference.html")
                (render-page "Fen generated reference"
                             (render-home register-groups contracts doc-paths)
                             "Reference"))
    (write-file (.. OUT-DIR "/core.html")
                (render-page "Fen core API" (render-core agg.exports) "Core API"))
    (each [_ topic (ipairs RUNTIME-TOPICS)]
      (write-file (.. OUT-DIR "/" (slug topic.name) ".html")
                  (render-page (.. "Fen docs: " (tostring topic.name))
                               (render-register-topic topic (or (. register-groups topic.kind) []))
                               nil)))
    (each [_ topic (ipairs CONTRACT-TOPICS)]
      (write-file (.. OUT-DIR "/" (slug topic.name) ".html")
                  (render-page (.. "Fen docs: " (tostring topic.name))
                               (render-contract-topic topic contracts)
                               "Contracts")))
    (write-file (.. OUT-DIR "/contributions.html")
                (render-page "Fen extension contributions"
                             (.. "<h1>Fen extension contributions</h1>"
                                 (table.concat
                                   (icollect [_ topic (ipairs RUNTIME-TOPICS)]
                                     (.. (aggregate-section-heading topic)
                                         (render-register-topic topic (or (. register-groups topic.kind) []) true)))
                                   "\n"))
                             "Extension contributions"))
    (write-file (.. OUT-DIR "/contracts.html")
                (render-page "Fen contracts"
                             (.. "<h1>Fen contracts</h1>"
                                 (table.concat
                                   (icollect [_ topic (ipairs CONTRACT-TOPICS)]
                                     (.. (aggregate-section-heading topic)
                                         (render-contract-topic topic contracts true)))
                                   "\n"))
                             "Contracts"))
    (write-file (.. OUT-DIR "/docs.html")
                (render-page "Fen repository docs" (render-doc-index doc-paths) "Docs"))
    (write-file (.. OUT-DIR "/graphs.html")
                (render-page "Fen generated graphs" (render-graphs-page) "Graphs"))
    (write-doc-pages doc-paths)
    (copy-site-assets!)
    (print (.. "Wrote static HTML docs to " OUT-DIR "/index.html"))))

(main)
