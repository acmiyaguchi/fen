;; Build presenter-neutral layout snapshots for the browser UI.

(local extensions (require :fen.core.extensions))
(local state (require :fen.extensions.web.state))
(local json (require :fen.util.json))

(local M {})

(fn arr [t]
  (if (> (length t) 0) t json.empty-array))

(fn row [text style]
  {:text (tostring (or text "")) :style (or style :normal)})

(fn safe-call [f ctx fallback]
  (let [(ok? r) (pcall f ctx)]
    (if ok? r fallback)))

(fn rendered-status [side ctx]
  (let [out []]
    (each [_ item (ipairs (extensions.list :status))]
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
    (each [_ p (ipairs (extensions.list :panels))]
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
     :busy (if ctx.is-busy? (ctx.is-busy?) false)}))

M
