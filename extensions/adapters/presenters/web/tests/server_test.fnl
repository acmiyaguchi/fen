(local server (require :fen.extensions.web.server))
(local page (require :fen.extensions.web.page))
(local layout (require :fen.extensions.web.layout))
(local state (require :fen.extensions.web.state))

(describe :fen.extensions.web.server
  (fn []
    (it "parses a complete GET request"
      (fn []
        (let [parse (. server :parse-request)
              req (parse "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")]
          (assert.are.equal :GET req.method)
          (assert.are.equal "/events" req.path)
          (assert.are.equal "localhost" (. req.headers "host"))
          (assert.are.equal "" req.body))))

    (it "waits for a complete POST body"
      (fn []
        (assert.is_nil
          ((. server :parse-request) "POST /input HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe"))
        (let [req ((. server :parse-request) "POST /input HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")]
          (assert.are.equal :POST req.method)
          (assert.are.equal "/input" req.path)
          (assert.are.equal "hello" req.body))))

    (it "includes an active selector's initial query in browser state"
      (fn []
        (let [old-api state.api
              old-select state.active-select]
          (set state.api {:list (fn [_kind] [])})
          (set state.active-select
               {:id "select-1"
                :label "switch model"
                :initial-query "snt"
                :choices [{:label "sonnet"}]
                :done? false})
          (let [snapshot (layout.snapshot {})]
            (assert.are.equal "snt" snapshot.select.initial_query))
          (set state.api old-api)
          (set state.active-select old-select))))

    (it "generates the browser page with SSE and input endpoints"
      (fn []
        (let [html (page.html)]
          (assert.truthy (string.find html "EventSource" 1 true))
          (assert.truthy (string.find html "sel.initial_query" 1 true))
          (assert.truthy (string.find html "/events" 1 true))
          (assert.truthy (string.find html "/input" 1 true))
          (assert.truthy (string.find html "/dismiss" 1 true))
          (assert.truthy (string.find html "dismiss-panels" 1 true)))))))
