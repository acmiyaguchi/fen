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

(set M.render render)
(set M.render-node render-node)

(local CSS
":root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
body { margin: 0; background: #111; color: #ddd; height: 100vh; overflow: hidden; }
#app { display: grid; grid-template-rows: auto 1fr auto auto; height: 100vh; }
#status { display: flex; justify-content: space-between; gap: 1rem; padding: .35rem .6rem; background: #ddd; color: #111; white-space: pre; }
#transcript { overflow: auto; padding: .6rem; }
#panels-wrap { display: none; position: relative; border-top: 1px solid #333; }
#panels-wrap.visible { display: block; }
#dismiss-panels { position: absolute; right: .5rem; top: .3rem; z-index: 2; padding: .15rem .45rem; background: #252525; }
#panels { padding-top: 1.9rem; }
.panel { padding: .25rem .6rem; border-bottom: 1px solid #333; background: #181818; }
.row { white-space: pre-wrap; word-break: break-word; line-height: 1.35; }
#inputbar { display: flex; gap: .5rem; padding: .5rem; border-top: 1px solid #444; background: #181818; }
#input { flex: 1; min-height: 3rem; resize: vertical; background: #0b0b0b; color: #eee; border: 1px solid #555; padding: .4rem; font: inherit; }
button { background: #333; color: #eee; border: 1px solid #666; padding: .35rem .7rem; font: inherit; }
#select-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.55); align-items: center; justify-content: center; z-index: 10; }
#select-box { width: min(900px, 92vw); max-height: 80vh; background: #181818; border: 1px solid #666; box-shadow: 0 1rem 4rem #000; display: flex; flex-direction: column; }
#select-title { padding: .55rem .7rem; border-bottom: 1px solid #444; font-weight: bold; }
#select-filter { margin: .55rem .7rem; background: #0b0b0b; color: #eee; border: 1px solid #555; padding: .4rem; font: inherit; }
#select-list { overflow: auto; margin: 0; padding: 0 0 .4rem 0; list-style: none; }
.select-choice { padding: .35rem .7rem; cursor: pointer; }
.select-choice.active { background: #264f78; color: #fff; }
.select-desc { color: #888; margin-left: .75rem; }
#select-hint { padding: .4rem .7rem; border-top: 1px solid #333; color: #888; }
.style-dim { color: #888; }
.style-error { color: #ff6b6b; font-weight: bold; }
.style-keyword { color: #9cdcfe; }
.style-status { color: inherit; }
.style-user { color: #4fc3f7; }
.style-assistant { color: #8bc34a; }
.style-tool { color: #ffd54f; }")

(local JS
"const $ = id => document.getElementById(id);
let currentSelect = null;
let currentSelectId = null;
let selectCursor = 0;
let selectPosting = false;
let dismissPosting = false;
let clientReloadSeq = null;
function html(id, value) { $(id).innerHTML = value || ''; }
function escapeText(s) { return String(s || '').replace(/[&<>\"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c])); }
function selectMatches(choice, q) {
  q = String(q || '').toLowerCase();
  if (!q) return true;
  return String(choice.label || '').toLowerCase().includes(q) || String(choice.description || '').toLowerCase().includes(q);
}
function filteredChoices() {
  const q = $('select-filter').value;
  return (currentSelect?.choices || []).filter(c => selectMatches(c, q));
}
function paintSelectList() {
  const list = $('select-list');
  const choices = filteredChoices();
  if (selectCursor >= choices.length) selectCursor = Math.max(0, choices.length - 1);
  list.innerHTML = choices.length ? choices.map((c, i) => `<li class='select-choice ${i === selectCursor ? 'active' : ''}' data-index='${c.index}'>${escapeText(c.label)}${c.description ? `<span class='select-desc'>${escapeText(c.description)}</span>` : ''}</li>`).join('') : `<li class='select-choice'>(no matches)</li>`;
  [...list.querySelectorAll('[data-index]')].forEach((el, i) => {
    el.addEventListener('mouseenter', () => { selectCursor = i; paintSelectList(); });
    el.addEventListener('click', () => postSelect(el.dataset.index));
  });
}
async function postSelect(value) {
  if (selectPosting) return;
  selectPosting = true;
  await fetch('/select', {method: 'POST', headers: {'Content-Type': 'text/plain; charset=utf-8'}, body: String(value)});
}
async function postDismiss(ev) {
  if (ev?.preventDefault) ev.preventDefault();
  if (ev?.stopPropagation) ev.stopPropagation();
  if (dismissPosting) return;
  dismissPosting = true;
  // Hide immediately for responsiveness, but block input until the server has
  // processed the dismiss. Otherwise a fast follow-up like `/status` can race
  // with the still-open server-side panel and toggle it off.
  $('panels-wrap').classList.remove('visible');
  html('panels', '');
  if (!currentSelect) $('input').disabled = true;
  try {
    await fetch('/dismiss', {method: 'POST'});
  } finally {
    dismissPosting = false;
    if (!currentSelect) $('input').disabled = false;
  }
}
function renderSelect(sel) {
  const overlay = $('select-overlay');
  if (!sel) {
    currentSelect = null;
    currentSelectId = null;
    selectPosting = false;
    overlay.style.display = 'none';
    $('input').disabled = dismissPosting;
    return;
  }
  overlay.style.display = 'flex';
  $('input').disabled = true;
  if (currentSelectId !== sel.id) {
    currentSelect = sel;
    currentSelectId = sel.id;
    selectCursor = 0;
    $('select-title').textContent = sel.label || 'select';
    $('select-filter').value = '';
    paintSelectList();
    $('select-filter').focus();
  }
}
function render(layout) {
  if (clientReloadSeq === null) clientReloadSeq = layout.client_reload_seq || 0;
  else if ((layout.client_reload_seq || 0) !== clientReloadSeq) { location.reload(); return; }
  const transcript = $('transcript');
  const nearBottom = transcript.scrollTop + transcript.clientHeight >= transcript.scrollHeight - 20;
  html('status-left', layout.status_left_html || 'fen');
  html('status-right', layout.status_right_html || '');
  html('transcript', layout.transcript_html || '');
  const panelsHtml = layout.panels_html || '';
  html('panels', panelsHtml);
  $('panels-wrap').classList.toggle('visible', !!panelsHtml && !dismissPosting);
  renderSelect(layout.select);
  if (nearBottom) transcript.scrollTop = transcript.scrollHeight;
}
async function submitInput() {
  if (currentSelect || dismissPosting) return;
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
$('select-filter').addEventListener('input', () => { selectCursor = 0; paintSelectList(); });
function handleSelectKey(ev) {
  if (!currentSelect) return false;
  const choices = filteredChoices();
  if (ev.key === 'Escape') { ev.preventDefault(); postSelect('cancel'); return true; }
  if (ev.key === 'ArrowDown') { ev.preventDefault(); selectCursor = Math.min(choices.length - 1, selectCursor + 1); paintSelectList(); return true; }
  if (ev.key === 'ArrowUp') { ev.preventDefault(); selectCursor = Math.max(0, selectCursor - 1); paintSelectList(); return true; }
  if (ev.key === 'Enter') { ev.preventDefault(); if (choices[selectCursor]) postSelect(choices[selectCursor].index); return true; }
  return false;
}
$('select-filter').addEventListener('keydown', handleSelectKey);
$('dismiss-panels').addEventListener('click', postDismiss);
document.addEventListener('keydown', ev => {
  if (currentSelect && ev.target !== $('select-filter')) handleSelectKey(ev);
  else if (!currentSelect && ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); postDismiss(); }
}, true);
$('select-overlay').addEventListener('click', ev => { if (ev.target === $('select-overlay')) postSelect('cancel'); });
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
        [:div {:id :panels-wrap}
         [:button {:id :dismiss-panels :type :button
                   :title "Dismiss panels (Esc)"} "Dismiss"]
         [:div {:id :panels}]]
        [:form {:id :inputbar}
         [:textarea {:id :input :autofocus true
                     :placeholder "Type a message. Enter submits, Shift+Enter inserts newline."}]
         [:button {:type :submit} "Send"]]
        [:div {:id :select-overlay}
         [:div {:id :select-box}
          [:div {:id :select-title} "select"]
          [:input {:id :select-filter :type :text :placeholder "type to filter"}]
          [:ul {:id :select-list}]
          [:div {:id :select-hint} "enter/click select · esc cancel · type to filter"]]]]
       [:script [:raw JS]]]]]))

M
