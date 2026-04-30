;; Tiny LuaSocket HTTP/SSE server for the web presenter.

(local json (require :fen.util.json))
(local layout (require :fen.extensions.web.layout))
(local page (require :fen.extensions.web.page))
(local ingest (require :fen.extensions.web.ingest))

(local M {})

(fn now [socket]
  (if socket.gettime (socket.gettime) (os.time)))

(fn load-socket []
  (let [(ok? socket) (pcall require :socket)]
    (if ok? socket (error "web presenter requires luasocket"))))

(fn remove-at [t i]
  (table.remove t i))

(fn send-all [client data]
  (let [(sent err last) (client:send data)]
    (or sent (= err :timeout))))

(fn response [status ctype body]
  (let [body (or body "")]
    (.. "HTTP/1.1 " status "\r\n"
        "Content-Type: " ctype "\r\n"
        "Content-Length: " (length body) "\r\n"
        "Connection: close\r\n\r\n"
        body)))

(fn no-content []
  "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

(fn M.parse-request [buf]
  (let [header-end (or (string.find buf "\r\n\r\n" 1 true)
                       (string.find buf "\n\n" 1 true))]
    (when header-end
      (let [sep-len (if (= (string.sub buf header-end (+ header-end 3)) "\r\n\r\n") 4 2)
            header (string.sub buf 1 (- header-end 1))
            body-start (+ header-end sep-len)
            body (string.sub buf body-start)
            lines []]
        (each [line (string.gmatch header "[^\r\n]+")]
          (table.insert lines line))
        (let [(method path) (string.match (or (. lines 1) "") "^(%S+)%s+(%S+)")
              headers {}]
          (for [i 2 (length lines)]
            (let [(k v) (string.match (. lines i) "^([^:]+):%s*(.*)$")]
              (when k
                (tset headers (string.lower k) v))))
          (let [content-length (or (tonumber (. headers "content-length")) 0)]
            (when (>= (length body) content-length)
              {:method method :path path :headers headers
               :body (string.sub body 1 content-length)})))))))

(fn accept-clients! [socket state]
  (while true
    (let [(client err) (state.server:accept)]
      (if client
          (do (client:settimeout 0)
              (table.insert state.clients {:socket client :buf ""}))
          (lua "break")))))

(fn add-sse! [state client]
  (send-all client (.. "HTTP/1.1 200 OK\r\n"
                       "Content-Type: text/event-stream\r\n"
                       "Cache-Control: no-cache\r\n"
                       "Connection: keep-alive\r\n"
                       "X-Accel-Buffering: no\r\n\r\n"))
  (table.insert state.sse-clients client))

(fn handle-request! [req client ctx state]
  (if (and (= req.method :GET) (= req.path "/"))
      (send-all client (response "200 OK" "text/html; charset=utf-8" (page.html)))
      (and (= req.method :GET) (= req.path "/events"))
      (do (add-sse! state client)
          (let [snap (json.encode (layout.snapshot ctx))]
            (send-all client (.. "event: layout\ndata: " snap "\n\n")))
          ;; Ownership transferred to sse-clients; do not close below.
          (values true :keep-open))
      (and (= req.method :POST) (= req.path "/input"))
      (do (let [text (or req.body "")]
            ;; The core agent records the initial UserMessage but does not
            ;; emit a transcript event for it; TUI gets an immediate visual
            ;; echo from its input widget. The browser needs the same local
            ;; echo so POST /input visibly changes the layout before/while the
            ;; agent turn runs.
            (when (not= text "")
              (ingest.append-event {:type :user :text text}))
            (when ctx.on-submit (ctx.on-submit text)))
          (send-all client (no-content)))
      (send-all client (response "404 Not Found" "text/plain; charset=utf-8" "not found\n"))))

(fn drain-clients! [socket state ctx]
  (var i (length state.clients))
  (while (> i 0)
    (let [rec (. state.clients i)
          client rec.socket
          (chunk err part) (client:receive 4096)]
      (when (or chunk part)
        (set rec.buf (.. rec.buf (or chunk part))))
      (let [req (M.parse-request rec.buf)]
        (if req
            (let [(_ keep) (handle-request! req client ctx state)]
              (when (not (= keep :keep-open))
                (client:close))
              (remove-at state.clients i))
            (and err (not (= err :timeout)))
            (do (client:close)
                (remove-at state.clients i)))))
    (set i (- i 1))))

(fn broadcast! [state ctx]
  (let [snap (json.encode (layout.snapshot ctx))]
    (when (not= snap state.last-snapshot)
      (set state.last-snapshot snap)
      (let [frame (.. "event: layout\ndata: " snap "\n\n")]
        (var i (length state.sse-clients))
        (while (> i 0)
          (let [client (. state.sse-clients i)
                ok? (send-all client frame)]
            (when (not ok?)
              (client:close)
              (remove-at state.sse-clients i)))
          (set i (- i 1)))))))

(fn M.init [ctx state]
  (let [socket (load-socket)]
    (when (not state.server)
      (let [server (assert (socket.bind state.host state.port))]
        (server:settimeout 0)
        (set state.server server)
        (set state.quit? false)
        (io.stderr:write (.. "fen web presenter: http://" state.host ":"
                            (tostring state.port) "/\n"))))))

(fn M.shutdown [_ctx state]
  (set state.quit? true)
  (each [_ c (ipairs state.clients)]
    (when c.socket (c.socket:close)))
  (each [_ c (ipairs state.sse-clients)]
    (c:close))
  (set state.clients [])
  (set state.sse-clients [])
  (when state.server
    (state.server:close)
    (set state.server nil)))

(fn M.run [ctx state]
  (let [socket (load-socket)]
    (when (not state.server)
      (M.init ctx state))
    (while (not state.quit?)
      (accept-clients! socket state)
      (drain-clients! socket state ctx)
      (when ctx.on-tick
        (let [(ok? err) (pcall ctx.on-tick)]
          (when (not ok?)
            (io.stderr:write (.. "on-tick: " (tostring err) "\n")))))
      (let [t (now socket)]
        (when (> (- t (or state.last-broadcast 0)) 0.15)
          (set state.last-broadcast t)
          (broadcast! state ctx)))
      (socket.sleep 0.03))))

M
