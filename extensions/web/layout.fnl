;; Build presenter-neutral layout snapshots for the browser UI.

(local state (require :fen.extensions.web.state))
(local page (require :fen.extensions.web.page))
(local json (require :fen.util.json))

(local M {})

(fn arr [t]
  (if (> (length t) 0) t json.empty-array))

(fn list [t]
  (if (= (type t) :table) t []))

(fn row [text style]
  {:text (tostring (or text "")) :style (or style :normal)})

(fn safe-call [f ctx fallback]
  (let [(ok? r) (pcall f ctx)]
    (if ok? r fallback)))

(fn rendered-status [side ctx]
  (let [out []]
    (each [_ item (ipairs (state.api.list :status))]
      (when (= (or item.side :left) side)
        (let [(ok? r) (pcall item.render ctx)]
          (if (and ok? r r.text (not= r.text ""))
              (table.insert out {:name item.name
                                 :side side
                                 :text (tostring r.text)
                                 :style (or r.style :status)})
              (not ok?)
              (table.insert out {:name item.name
                                 :side side
                                 :text (.. "status-error:" (tostring item.name))
                                 :style :error})))))
    out))

(fn normalize-row [r]
  (if (= (type r) :table)
      {:text (tostring (or r.text ""))
       :style (or r.style :normal)
       :segments (or r.segments json.empty-array)}
      (row r :normal)))

(fn rendered-panels [ctx]
  (let [out []]
    (each [_ p (ipairs (state.api.list :panels))]
      (let [h (safe-call p.height ctx 0)]
        (when (> (or h 0) 0)
          (let [(ok? rows) (pcall p.render ctx)
                norm []]
            (if ok?
                (each [_ r (ipairs (or rows []))]
                  (table.insert norm (normalize-row r)))
                (table.insert norm (row (.. "panel-error:" (tostring p.name)) :error)))
            (table.insert out {:name p.name
                               :placement (or p.placement :above-input)
                               :order (or p.order 50)
                               :rows (arr norm)})))))
    out))

(fn truncate [s n]
  (let [s (tostring (or s ""))]
    (if (> (length s) n)
        (.. (string.sub s 1 n) "…")
        s)))

(fn transcript-row [ev]
  (if (= ev.type :user)
      (row (.. "> " (or ev.text ev.content "")) :user)
      (= ev.type :assistant-text)
      (row (or ev.text "") :assistant)
      (= ev.type :assistant-thinking)
      (row (.. "Thinking: " (or ev.text "")) :dim)
      (= ev.type :tool-call)
      (row (.. "tool " (tostring (or ev.name "?")) " "
               (truncate (or ev.args-pretty "") 500)) :tool)
      (= ev.type :tool-result)
      (row (.. "tool-result " (tostring (or ev.name ev.id "")) " "
               (truncate (or ev.body-pretty "") 1200)) :dim)
      (= ev.type :error)
      (row (tostring (or ev.error ev.text "error")) :error)
      (= ev.type :queued)
      (row (.. "queued " (tostring (or ev.queue "")) ": "
               (tostring (or ev.text ""))) :dim)
      (= ev.type :info)
      (row (or ev.text "") :dim)
      (row (.. (tostring (or ev.type :event)) ": "
               (tostring (or ev.text ev.delta ""))) :dim)))

(fn transcript []
  (let [out []]
    (each [_ ev (ipairs state.transcript)]
      (table.insert out (transcript-row ev)))
    out))

(fn select-snapshot []
  (let [sel state.active-select]
    (when (and sel (not sel.done?))
      (let [choices []]
        (each [i choice (ipairs (or sel.choices []))]
          (table.insert choices
                        {:index i
                         :label (if (= (type choice) :table)
                                    (tostring (or choice.label choice.name choice.value choice))
                                    (tostring choice))
                         :description (if (= (type choice) :table)
                                          (tostring (or choice.description ""))
                                          "")}))
        {:id sel.id
         :label sel.label
         :choices (arr choices)}))))

;; @doc fen.extensions.web.layout.snapshot
;; kind: function
;; signature: (snapshot ctx?) -> table
;; summary: Build the JSON-serializable browser layout snapshot from status fragments, panels, transcript rows, select state, and reload sequence.
;; tags: web layout snapshot json
(fn M.snapshot [ctx]
  (let [ctx (or ctx {})
        status-ctx {:status-info state.status-info :state state :w (or ctx.w 100)}
        left (rendered-status :left status-ctx)
        right (rendered-status :right status-ctx)
        status []]
    (each [_ x (ipairs left)] (table.insert status x))
    (each [_ x (ipairs right)] (table.insert status x))
    {:type :layout
     :status_fragments (arr status)
     :panels (arr (rendered-panels status-ctx))
     :transcript (arr (transcript))
     :select (or (select-snapshot) json.null)
     :client_reload_seq (or state.client-reload-seq 0)
     :busy (if ctx.is-busy? (ctx.is-busy?) false)}))

(fn class-token [x]
  (let [s0 (tostring (or x :normal))
        s1 (string.gsub s0 "^:" "")]
    (string.gsub s1 "[^%w_-]" "-")))

(fn style-class [style]
  (.. "style-" (class-token style)))

(fn placement-class [placement]
  (.. "placement-" (class-token (or placement :above-input))))

(fn render-fragment [nodes]
  (page.render (or nodes [])))

(fn row-node [r]
  (let [r (normalize-row r)
        base-class (.. "row " (style-class r.style))]
    (if (and (= (type r.segments) :table) (> (length r.segments) 0))
        (let [node [:div {:class base-class}]]
          (each [_ seg (ipairs r.segments)]
            (table.insert node
                          [:span {:class (style-class (or seg.style r.style))}
                           (or seg.text "")]))
          node)
        [:div {:class base-class} (or r.text "")])))

(fn status-html [snap side]
  (let [parts []]
    (each [_ item (ipairs (list snap.status_fragments))]
      (when (= (or item.side :left) side)
        (table.insert parts (tostring (or item.text "")))))
    (if (= (length parts) 0)
        (if (= side :left) "fen" "")
        (render-fragment [[:span (table.concat parts "  ")]]))))

(fn transcript-html [snap]
  (let [nodes []]
    (each [_ r (ipairs (list snap.transcript))]
      (table.insert nodes (row-node r)))
    (render-fragment nodes)))

(fn panels-html [snap]
  (let [nodes []]
    (each [_ p (ipairs (list snap.panels))]
      (let [panel [:div {:class (.. "panel " (placement-class p.placement))}]]
        (each [_ r (ipairs (list p.rows))]
          (table.insert panel (row-node r)))
        (table.insert nodes panel)))
    (render-fragment nodes)))

;; @doc fen.extensions.web.layout.html-snapshot
;; kind: function
;; signature: (html-snapshot ctx?) -> table
;; summary: Build a browser layout snapshot with pre-rendered HTML fragments for status, transcript, panels, and select state.
;; tags: web layout snapshot html
(fn M.html-snapshot [ctx]
  (let [snap (M.snapshot ctx)]
    {:type :layout-html
     :status_left_html (status-html snap :left)
     :status_right_html (status-html snap :right)
     :transcript_html (transcript-html snap)
     :panels_html (panels-html snap)
     :select snap.select
     :client_reload_seq snap.client_reload_seq
     :busy snap.busy}))

M
