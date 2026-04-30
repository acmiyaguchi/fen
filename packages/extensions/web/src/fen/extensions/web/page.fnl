;; Static browser page generated from a tiny Hiccup-style HTML s-expression.
;; Kept web-local until another package needs it.

(local M {})

(fn escape-html [s]
  ;; string.gsub returns (new-string, replacement-count); keep only the
  ;; string so callers like table.insert don't receive a stray numeric arg.
  (let [s0 (tostring (or s ""))
        s1 (string.gsub s0 "&" "&amp;")
        s2 (string.gsub s1 "<" "&lt;")
        s3 (string.gsub s2 ">" "&gt;")
        s4 (string.gsub s3 "\"" "&quot;")]
    s4))

(fn attr-name [k]
  (let [s (tostring k)]
    (if (= s :className) :class s)))

(fn render-attrs [attrs]
  (let [parts []]
    (each [k v (pairs (or attrs {}))]
      (when (and v (not= v false))
        (table.insert parts
                      (if (= v true)
                          (.. " " (attr-name k))
                          (.. " " (attr-name k) "=\"" (escape-html v) "\"")))))
    (table.concat parts "")))

(local VOID-TAGS
  {:area true :base true :br true :col true :embed true :hr true :img true
   :input true :link true :meta true :param true :source true :track true
   :wbr true})

(fn attrs-table? [x]
  (and (= (type x) :table)
       (= (. x 1) nil)))

(fn render-node [node]
  (if (= node nil) ""
      (or (= (type node) :string) (= (type node) :number))
      (escape-html node)
      (not= (type node) :table)
      (escape-html (tostring node))
      (let [tag (. node 1)]
        (if (= tag :raw)
            (tostring (or (. node 2) ""))
            (= tag :!doctype)
            (.. "<!doctype " (tostring (or (. node 2) "html")) ">")
            (let [attrs (if (attrs-table? (. node 2)) (. node 2) nil)
                  first-child (if attrs 3 2)
                  name (tostring tag)
                  out [(.. "<" name (render-attrs attrs) ">")]]
              (when (not (. VOID-TAGS tag))
                (for [i first-child (length node)]
                  (table.insert out (render-node (. node i))))
                (table.insert out (.. "</" name ">")))
              (table.concat out ""))))))

(fn render [doc]
  (let [out []]
    (each [_ node (ipairs doc)]
      (table.insert out (render-node node)))
    (table.concat out "\n")))

(local CSS
":root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
body { margin: 0; background: #111; color: #ddd; height: 100vh; overflow: hidden; }
#app { display: grid; grid-template-rows: auto 1fr auto auto; height: 100vh; }
#status { display: flex; justify-content: space-between; gap: 1rem; padding: .35rem .6rem; background: #ddd; color: #111; white-space: pre; }
#transcript { overflow: auto; padding: .6rem; }
#panels { border-top: 1px solid #333; }
.panel { padding: .25rem .6rem; border-bottom: 1px solid #333; background: #181818; }
.row { white-space: pre-wrap; word-break: break-word; line-height: 1.35; }
#inputbar { display: flex; gap: .5rem; padding: .5rem; border-top: 1px solid #444; background: #181818; }
#input { flex: 1; min-height: 3rem; resize: vertical; background: #0b0b0b; color: #eee; border: 1px solid #555; padding: .4rem; font: inherit; }
button { background: #333; color: #eee; border: 1px solid #666; padding: .35rem .7rem; font: inherit; }
.style-dim { color: #888; }
.style-error { color: #ff6b6b; font-weight: bold; }
.style-keyword { color: #9cdcfe; }
.style-status { color: inherit; }
.style-user { color: #4fc3f7; }
.style-assistant { color: #8bc34a; }
.style-tool { color: #ffd54f; }")

(local JS
"const $ = id => document.getElementById(id);
function cls(style) { return 'style-' + String(style || 'normal').replace(/^:/, '').replace(/[^a-zA-Z0-9_-]/g, '-'); }
function rowEl(row) {
  const div = document.createElement('div');
  div.className = 'row ' + cls(row.style);
  if (Array.isArray(row.segments) && row.segments.length) {
    for (const seg of row.segments) {
      const span = document.createElement('span');
      span.className = cls(seg.style || row.style);
      span.textContent = seg.text || '';
      div.appendChild(span);
    }
  } else {
    div.textContent = row.text || '';
  }
  return div;
}
function render(layout) {
  const status = Array.isArray(layout.status_fragments) ? layout.status_fragments : [];
  $('status-left').textContent = status.filter(x => (x.side || 'left') === 'left').map(x => x.text).join('  ') || 'fen';
  $('status-right').textContent = status.filter(x => x.side === 'right').map(x => x.text).join('  ');
  const transcript = $('transcript');
  const nearBottom = transcript.scrollTop + transcript.clientHeight >= transcript.scrollHeight - 20;
  transcript.replaceChildren(...(Array.isArray(layout.transcript) ? layout.transcript : []).map(rowEl));
  if (nearBottom) transcript.scrollTop = transcript.scrollHeight;
  const panels = $('panels');
  const children = [];
  for (const p of (Array.isArray(layout.panels) ? layout.panels : [])) {
    const div = document.createElement('div');
    div.className = 'panel placement-' + String(p.placement || 'above-input');
    for (const r of (Array.isArray(p.rows) ? p.rows : [])) div.appendChild(rowEl(r));
    children.push(div);
  }
  panels.replaceChildren(...children);
}
async function submitInput() {
  const input = $('input');
  const text = input.value;
  if (!text.trim()) return;
  input.value = '';
  await fetch('/input', {method: 'POST', headers: {'Content-Type': 'text/plain; charset=utf-8'}, body: text});
}
$('inputbar').addEventListener('submit', ev => { ev.preventDefault(); submitInput(); });
$('input').addEventListener('keydown', ev => {
  if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); submitInput(); }
});
const es = new EventSource('/events');
es.addEventListener('layout', ev => render(JSON.parse(ev.data)));
es.onerror = () => { $('status-right').textContent = 'disconnected'; };")

(fn M.html []
  (render
    [[:!doctype :html]
     [:html
      [:head
       [:meta {:charset :utf-8}]
       [:meta {:name :viewport :content "width=device-width, initial-scale=1"}]
       [:title "fen"]
       [:style [:raw CSS]]]
      [:body
       [:div {:id :app}
        [:div {:id :status}
         [:div {:id :status-left} "fen"]
         [:div {:id :status-right}]]
        [:div {:id :transcript}]
        [:div {:id :panels}]
        [:form {:id :inputbar}
         [:textarea {:id :input :autofocus true
                     :placeholder "Type a message. Enter submits, Shift+Enter inserts newline."}]
         [:button {:type :submit} "Send"]]]
       [:script [:raw JS]]]]]))

M
