;; Web presenter extension: local browser UI over LuaSocket + SSE.

(local state (require :fen.extensions.web.state))
(local server (require :fen.extensions.web.server))
(local ingest (require :fen.extensions.web.ingest))

(local M {})

(fn fmt-tokens [n]
  (let [n (or n 0)]
    (if (>= n 1000000) (.. (string.format "%.1f" (/ n 1000000)) "M")
        (>= n 1000) (.. (string.format "%.1f" (/ n 1000)) "k")
        (tostring n))))

(local SPINNER ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(fn spin-char []
  (let [s state.status-info
        frame (or s.spin-frame 0)
        idx (+ (% frame (length SPINNER)) 1)]
    (or (. SPINNER idx) "⠋")))

(fn busy-label []
  (let [s state.status-info]
    (or s.running-label (if s.thinking? "thinking" ""))))

(fn busy? []
  (not= (busy-label) ""))

(fn busy-height [_ctx]
  (if (busy?) 1 0))

(fn busy-render [_ctx]
  (if (busy?)
      (let [s state.status-info
            start (or s.turn-start 0)
            elapsed (if (= start 0) "" (.. (tostring (- (os.time) start)) "s"))]
        (set s.spin-frame (+ (or s.spin-frame 0) 1))
        [{:text (.. "  " (spin-char) " " (busy-label)
                    (if (not= elapsed "") (.. "  " elapsed) ""))
          :style :dim}])
      []))

(fn choice-label [choice]
  (if (= (type choice) :table)
      (tostring (or choice.label choice.name choice.value choice))
      (tostring choice)))

(fn web-select [opts]
  (if state.presenter-ctx
      (server.wait-select state.presenter-ctx state opts)
      ;; If select is invoked before the presenter run loop has published its
      ;; context, degrade to the old transcript-only hint instead of hanging.
      (let [opts (or opts {})
            label (tostring (or opts.label "select"))
            lines [(.. label ":")]]
        (each [i choice (ipairs (or opts.choices []))]
          (table.insert lines (.. "  " (tostring (- i 1)) ". " (choice-label choice))))
        (table.insert lines "")
        (table.insert lines "Enter a slash command with an index or name to choose, e.g. /model 0")
        (ingest.append-event {:type :assistant-text
                              :text (table.concat lines "\n")
                              :final? true})
        nil)))

(fn web-prompt [opts]
  (let [label (tostring (or (?. opts :label) "prompt"))]
    (ingest.append-event {:type :assistant-text
                          :text (.. label ": web prompt input is not implemented yet")
                          :final? true})
    nil))

;; @doc fen.extensions.web.init!
;; kind: function
;; signature: (init! ctx) -> nil
;; summary: Store the presenter context and initialize the web server listener for browser clients.
;; tags: web presenter lifecycle server
(fn M.init! [ctx]
  (set state.presenter-ctx ctx)
  (server.init ctx state))
;; @doc fen.extensions.web.shutdown
;; kind: function
;; signature: (shutdown ctx) -> nil
;; summary: Clear the web presenter context and close server/client resources during presenter shutdown.
;; tags: web presenter lifecycle server
(fn M.shutdown [ctx]
  (set state.presenter-ctx nil)
  (server.shutdown ctx state))
;; @doc fen.extensions.web.run
;; kind: function
;; signature: (run ctx) -> nil
;; summary: Run the web presenter server loop with the current context until the presenter is asked to quit.
;; tags: web presenter lifecycle server
(fn M.run [ctx]
  (set state.presenter-ctx ctx)
  (server.run ctx state))

(fn M.register [api]

(local PRESENTER-CONTROL-EVENTS
  {:dismiss true
   :reinit-presenter true})

(api.on :*
        (fn [ev]
          (when (not (. PRESENTER-CONTROL-EVENTS ev.type))
            (ingest.append-event ev))))

(api.on :reinit-presenter
        (fn [ev]
          (set state.client-reload-seq (+ (or state.client-reload-seq 0) 1))
          (M.init! ev)))

(api.register :status
              {:name :model
               :side :left
               :order 10
               :render (fn [_ctx]
                         (let [s state.status-info]
                           {:text (.. (or s.provider "?") ":" (tostring (or s.model "?")))
                            :style :status}))})

(api.register :status
              {:name :context
               :side :left
               :order 20
               :render (fn [_ctx]
                         {:text (.. "ctx:~" (fmt-tokens (or state.status-info.approx-context
                                                          state.status-info.last-input)))
                          :style :status})})

(api.register :status
              {:name :steering-queue
               :side :left
               :order 30
               :render (fn [_ctx]
                         (let [n (or state.status-info.steering-queued 0)]
                           (when (> n 0)
                             {:text (.. "steer:" (tostring n))
                              :style :status})))})

(api.register :status
              {:name :follow-up-queue
               :side :left
               :order 40
               :render (fn [_ctx]
                         (let [n (or state.status-info.follow-up-queued 0)]
                           (when (> n 0)
                             {:text (.. "follow:" (tostring n))
                              :style :status})))})

(api.register :status
              {:name :attention
               :side :right
               :order 10
               :render (fn [_ctx]
                         (let [text (if state.status-info.cancelling? "cancelling…" "")]
                           (when (not= text "")
                             {:text text :style :status})))})

(api.register :panel
              {:name :busy
               :description "Web presenter spinner row shown while the agent is busy."
               :placement :above-input
               :order 10
               :height busy-height
               :render busy-render})

(api.register :presenter
              {:name :web
               :active? true
               :init (fn [ctx] (M.init! ctx))
               :shutdown (fn [ctx] (M.shutdown ctx))
               :run (fn [ctx] (M.run ctx))
               :ui {:notify (fn [text _opts]
                              (ingest.append-event {:type :info :text (tostring text)}))
                    :prompt web-prompt
                    :select web-select}})

  true)

M
