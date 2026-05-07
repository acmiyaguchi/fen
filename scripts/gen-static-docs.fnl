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
.nav{border-bottom:1px solid #ccc;padding:.6em 1em;background:#f7f7f7}\n\
.nav a{display:inline-block;margin:0 1em .2em 0;text-decoration:none}\n\
.nav a.active{font-weight:bold;color:#111}\n\
.main{max-width:60em;width:100%;box-sizing:border-box;margin:0 auto;padding:1em;overflow-wrap:anywhere}\n\
h1,h2,h3{line-height:1.25;overflow-wrap:anywhere}\n\
h2{border-top:1px solid #ddd;padding-top:1em;margin-top:1.5em}\n\
.card{border:1px solid #ccc;background:#fafafa;margin:.8em 0;padding:.8em;box-sizing:border-box}\n\
table{border-collapse:collapse;width:100%;max-width:100%;display:block;overflow-x:auto;margin:1em 0}\n\
th,td{border:1px solid #ccc;padding:.35em .5em;text-align:left;vertical-align:top;overflow-wrap:anywhere;word-break:break-word}\n\
code,pre{font-family:monospace}\n\
code{background:#f3f3f3;padding:.05em .2em;white-space:normal;overflow-wrap:anywhere;word-break:break-word}\n\
pre{background:#f3f3f3;border:1px solid #ccc;padding:1em;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;box-sizing:border-box;max-width:100%}\n\
.muted,.source{color:#666}\n\
.source{font-size:.9em;overflow-wrap:anywhere;word-break:break-word}\n\
@media(max-width:640px){body{font-size:15px}.main{padding:.7em}.nav{padding:.5em}.nav a{display:block;margin:.2em 0}table{font-size:.9em}}\n")

(fn render-page [title body ?section]
  (let [nav [["index.html" "Home"]
             ["core.html" "Core API"]
             ["contributions.html" "Extension contributions"]
             ["contracts.html" "Contracts"]
             ["docs.html" "Docs"]]
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
        body "\n</div></body></html>\n")))

(fn markdown-inline [s]
  (let [s (html-escape s)]
    (string.gsub s "`([^`]+)`" "<code>%1</code>")))

(fn flush-paragraph [out para]
  (when (> (# para) 0)
    (table.insert out (.. "<p>" (markdown-inline (table.concat para " ")) "</p>"))
    (while (> (# para) 0) (table.remove para))))

(fn markdown-to-html [md]
  "Small markdown renderer for repository docs: headings, paragraphs, lists, and fences."
  (let [out [] para []]
    (var in-code? false)
    (var code-lines [])
    (var list-open? false)
    (each [_ line (ipairs (split-lines md))]
      (let [fence (string.match line "^```")]
        (if in-code?
            (if fence
                (do
                  (table.insert out (.. "<pre><code>" (html-escape (table.concat code-lines "\n")) "</code></pre>"))
                  (set code-lines [])
                  (set in-code? false))
                (table.insert code-lines line))
            fence
            (do
              (flush-paragraph out para)
              (when list-open? (table.insert out "</ul>") (set list-open? false))
              (set in-code? true)
              (set code-lines []))
            (string.match line "^%s*$")
            (do
              (flush-paragraph out para)
              (when list-open? (table.insert out "</ul>") (set list-open? false)))
            (let [(marks text) (string.match line "^(#+)%s+(.+)$")]
              (if marks
                  (do
                    (flush-paragraph out para)
                    (when list-open? (table.insert out "</ul>") (set list-open? false))
                    (let [level (math.min 6 (# marks))]
                      (table.insert out (.. "<h" level ">" (markdown-inline text) "</h" level ">"))))
                  (let [item (string.match line "^%s*[-*]%s+(.+)$")]
                    (if item
                        (do
                          (flush-paragraph out para)
                          (when (not list-open?)
                            (table.insert out "<ul>")
                            (set list-open? true))
                          (table.insert out (.. "<li>" (markdown-inline item) "</li>")))
                        (table.insert para line))))))))
    (when in-code?
      (table.insert out (.. "<pre><code>" (html-escape (table.concat code-lines "\n")) "</code></pre>")))
    (flush-paragraph out para)
    (when list-open? (table.insert out "</ul>"))
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
    (each [_ path (ipairs (command-lines "find extensions -maxdepth 2 -name manifest.fnl -type f | sort"))]
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

(fn render-register-topic [topic items]
  (let [rows []]
    (if (= (# items) 0)
        (table.insert rows "<p class=\"muted\">No source-scanned registrations.</p>")
        (do
          (table.sort items (fn [a b]
                              (< (tostring (or a.name "")) (tostring (or b.name "")))))
          (table.insert rows "<table><thead><tr><th>Name</th><th>Description</th><th>Source</th></tr></thead><tbody>")
          (each [_ r (ipairs items)]
            (table.insert rows
              (.. "<tr><td><code>" (html-escape (or r.name "(dynamic)")) "</code></td><td>"
                  (html-escape (or r.description "")) "</td><td class=\"source\">"
                  (html-escape (.. r.path ":" (tostring (or r.line "?")))) "</td></tr>")))
          (table.insert rows "</tbody></table>")))
    (.. "<h1>" (html-escape (tostring topic.name)) "</h1><p>" (html-escape topic.summary) "</p>"
        (table.concat rows "\n"))))

(fn render-field-table [fields]
  (let [rows ["<table><thead><tr><th>Field</th><th>Type</th><th>Required</th><th>Summary</th></tr></thead><tbody>"]]
    (each [_ k (ipairs (sorted-keys fields))]
      (let [f (. fields k)
            ty (or f.type (and f.const (.. ":" (tostring f.const)))
                   (and f.enum (.. "enum " (table.concat (icollect [_ v (ipairs f.enum)] (.. ":" (tostring v))) " | ")))
                   "any")]
        (table.insert rows
          (.. "<tr><td><code>:" (html-escape k) "</code></td><td><code>" (html-escape ty)
              "</code></td><td>" (if f.required "yes" "") "</td><td>" (html-escape (or f.summary "")) "</td></tr>"))))
    (table.insert rows "</tbody></table>")
    (table.concat rows "\n")))

(fn render-contract-topic [topic contracts]
  (let [bucket (. contracts topic.key)
        out [(.. "<h1>" (html-escape (tostring topic.name)) "</h1><p>" (html-escape topic.summary) "</p>")]]
    (each [_ name (ipairs (sorted-keys bucket))]
      (let [body (. bucket name)]
        (table.insert out (.. "<h2 id=\"" (slug name) "\"><code>" (html-escape name) "</code></h2>"))
        (when body.summary (table.insert out (.. "<p>" (html-escape body.summary) "</p>")))
        (when body.fields (table.insert out (render-field-table body.fields)))
        (when body.variants
          (table.insert out (.. "<p><strong>Variants:</strong> "
                              (html-escape (table.concat (icollect [_ v (ipairs body.variants)] (tostring v)) " | ")) "</p>")))
        (when body.enum
          (table.insert out (.. "<p><strong>Values:</strong> "
                              (html-escape (table.concat (icollect [_ v (ipairs body.enum)] (.. ":" (tostring v))) " | ")) "</p>")))
        (when body.methods
          (table.insert out (.. "<p><strong>Required methods:</strong> "
                              (html-escape (table.concat (icollect [_ v (ipairs body.methods)] (.. ":" (tostring v))) ", ")) "</p>")))
        (when body.optional-methods
          (table.insert out (.. "<p><strong>Optional methods:</strong> "
                              (html-escape (table.concat (icollect [_ v (ipairs body.optional-methods)] (.. ":" (tostring v))) ", ")) "</p>")))))
    (table.concat out "\n")))

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
        (table.insert out (.. "<h2 id=\"" (slug m) "\">" (html-escape m) "</h2>"))
        (each [_ e (ipairs (. groups m))]
          (let [doc e.doc]
            (table.insert out (.. "<h3><code>" (html-escape e.id) "</code></h3>"))
            (when (or e.signature (and doc doc.signature))
              (table.insert out (.. "<p><code>" (html-escape (or (and doc doc.signature) e.signature)) "</code></p>")))
            (when (and doc doc.summary) (table.insert out (.. "<p>" (html-escape doc.summary) "</p>")))
            (table.insert out (.. "<p class=\"source\">" (html-escape (.. e.path ":" (tostring (or (and doc doc.line) e.line "?")))) "</p>")))))
      (table.concat out "\n"))))

(fn render-doc-index [doc-paths]
  (let [out ["<h1>Repository docs</h1><p>Hand-written markdown pages from <code>docs/</code>.</p><ul>"]]
    (each [_ path (ipairs doc-paths)]
      (let [base (string.match path "([^/]+)%.md$")]
        (table.insert out (.. "<li>" (link (.. "doc-" (slug base) ".html") base) " <span class=\"source\">" (html-escape path) "</span></li>"))))
    (table.insert out "</ul>")
    (table.concat out "\n")))

(fn render-home [register-groups contracts doc-paths]
  (let [cards []]
    (each [_ t (ipairs RUNTIME-TOPICS)]
      (let [n (# (or (. register-groups t.kind) []))]
        (table.insert cards (.. "<div class=\"card\"><h3>" (link (.. (slug t.name) ".html") (tostring t.name)) "</h3><p>" (html-escape t.summary) "</p><p class=\"muted\">" n " records</p></div>"))))
    (each [_ t (ipairs CONTRACT-TOPICS)]
      (let [n (# (sorted-keys (. contracts t.key)))]
        (table.insert cards (.. "<div class=\"card\"><h3>" (link (.. (slug t.name) ".html") (tostring t.name)) "</h3><p>" (html-escape t.summary) "</p><p class=\"muted\">" n " records</p></div>"))))
    (.. "<h1>Fen documentation</h1>"
        "<p>Static documentation generated from Fennel source, extension registration sites, structured contracts, and hand-written <code>docs/</code> markdown.</p>"
        "<div class=\"grid\">" (table.concat cards "\n") "</div>"
        "<h2>Other pages</h2><ul>"
        "<li>" (link "core.html" "Core API") "</li>"
        "<li>" (link "contributions.html" "All extension contributions") "</li>"
        "<li>" (link "contracts.html" "All contracts") "</li>"
        "<li>" (link "docs.html" (.. "Repository docs (" (# doc-paths) ")")) "</li>"
        "</ul>")))

(fn write-doc-pages [doc-paths]
  (each [_ path (ipairs doc-paths)]
    (let [base (string.match path "([^/]+)%.md$")
          html (markdown-to-html (read-file path))]
      (write-file (.. OUT-DIR "/doc-" (slug base) ".html")
                  (render-page (.. "Fen docs: " base) html "Docs")))))

(fn main []
  (let [tree (scanner.scan-tree)
        agg (scanner.aggregate tree)
        contracts (scanner.read-contracts)
        register-groups (add-register-sites! (group-register-sites agg.register-sites)
                                             (scan-extension-manifests))
        doc-paths (command-lines "find docs -maxdepth 1 -name '*.md' -type f | sort")]
    (write-file (.. OUT-DIR "/style.css") SITE-CSS)
    (write-file (.. OUT-DIR "/index.html")
                (render-page "Fen documentation" (render-home register-groups contracts doc-paths) nil))
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
                                     (.. "<h2>" (link (.. (slug topic.name) ".html") (tostring topic.name)) "</h2>"
                                         (render-register-topic topic (or (. register-groups topic.kind) []))))
                                   "\n"))
                             "Extension contributions"))
    (write-file (.. OUT-DIR "/contracts.html")
                (render-page "Fen contracts"
                             (.. "<h1>Fen contracts</h1>"
                                 (table.concat
                                   (icollect [_ topic (ipairs CONTRACT-TOPICS)]
                                     (.. "<h2>" (link (.. (slug topic.name) ".html") (tostring topic.name)) "</h2>"
                                         (render-contract-topic topic contracts)))
                                   "\n"))
                             "Contracts"))
    (write-file (.. OUT-DIR "/docs.html")
                (render-page "Fen repository docs" (render-doc-index doc-paths) "Docs"))
    (write-doc-pages doc-paths)
    (print (.. "Wrote static HTML docs to " OUT-DIR "/index.html"))))

(main)
