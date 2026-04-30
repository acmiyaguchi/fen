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

(fn conn [client kind]
  (client:settimeout 0)
  {:socket client :kind (or kind :http) :buf "" :out "" :close-after? false})

(fn remove-at [t i]
  (table.remove t i))

(fn queue! [c data]
  (set c.out (.. (or c.out "") (or data ""))))

(fn flush! [c]
  (if (= (or c.out "") "")
      true
      (let [(sent err last) (c.socket:send c.out)]
        (if sent
            (do (set c.out (string.sub c.out (+ sent 1))) true)
            (= err :timeout)
            (do (when (and last (> last 0))
                  (set c.out (string.sub c.out (+ last 1))))
                true)
            false))))

(fn close! [c]
  (when c.socket (c.socket:close)))

(fn flush-list! [list]
  (var i (length list))
  (while (> i 0)
    (let [c (. list i)
          ok? (flush! c)]
      (when (or (not ok?)
                (and c.close-after? (= (or c.out "") "")))
        (close! c)
        (remove-at list i)))
    (set i (- i 1))))

(fn response [status ctype body]
  (let [body (or body "")]
    (.. "HTTP/1.1 " status "\r\n"
        "Content-Type: " ctype "\r\n"
        "Content-Length: " (length body) "\r\n"
        "Connection: close\r\n\r\n"
        body)))

(fn no-content []
  "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

(fn sse-frame [event data]
  (.. "event: " event "\ndata: " data "\n\n"))

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

(fn accept-clients! [_socket state]
  (var n 0)
  (while (< n 16)
    (let [(client _err) (state.server:accept)]
      (if client
          (do (table.insert state.clients (conn client :http))
              (set n (+ n 1)))
          (lua "break")))))

(fn add-sse! [state c ctx]
  (set c.kind :sse)
  (set c.buf "")
  (queue! c (.. "HTTP/1.1 200 OK\r\n"
               "Content-Type: text/event-stream\r\n"
               "Cache-Control: no-cache\r\n"
               "Connection: keep-alive\r\n"
               "X-Accel-Buffering: no\r\n\r\n"))
  (queue! c (sse-frame "layout" (json.encode (layout.html-snapshot ctx))))
  (table.insert state.sse-clients c))

(fn ensure-queues! [state]
  (when (= state.pending-inputs nil)
    (set state.pending-inputs [])))

(fn enqueue-input! [state text]
  (ensure-queues! state)
  (when (not= (or text "") "")
    (table.insert state.pending-inputs text)))

(fn handle-request! [req c ctx state]
  (if (and (= req.method :GET) (= req.path "/"))
      (do (queue! c (response "200 OK" "text/html; charset=utf-8" (page.html)))
          (set c.close-after? true)
          :close)
      (and (= req.method :GET) (= req.path "/events"))
      (do (add-sse! state c ctx)
          :sse)
      (and (= req.method :POST) (= req.path "/input"))
      (do (enqueue-input! state (or req.body ""))
          (queue! c (no-content))
          (set c.close-after? true)
          :close)
      (do (queue! c (response "404 Not Found" "text/plain; charset=utf-8" "not found\n"))
          (set c.close-after? true)
          :close)))

(fn drain-clients! [_socket state ctx]
  (var i (length state.clients))
  (while (> i 0)
    (let [c (. state.clients i)]
      (if c.close-after?
          nil
          (let [(chunk err part) (c.socket:receive 4096)]
            (when (or chunk part)
              (set c.buf (.. c.buf (or chunk part))))
            (let [req (M.parse-request c.buf)]
              (if req
                  (let [action (handle-request! req c ctx state)]
                    (when (= action :sse)
                      (remove-at state.clients i)))
                  (and err (not (= err :timeout)))
                  (do (close! c)
                      (remove-at state.clients i)))))))
    (set i (- i 1))))

(fn drain-inputs! [state ctx]
  (ensure-queues! state)
  (var n 0)
  (while (and (< n 1) (> (length state.pending-inputs) 0))
    (let [text (table.remove state.pending-inputs 1)]
      ;; Keep the existing browser-local echo, but do it outside the HTTP
      ;; handler so socket service stays fast and cooperative.
      (ingest.append-event {:type :user :text text})
      (when ctx.on-submit (ctx.on-submit text)))
    (set n (+ n 1))))

(fn broadcast! [state ctx]
  (let [snap (json.encode (layout.html-snapshot ctx))]
    (when (not= snap state.last-snapshot)
      (set state.last-snapshot snap)
      (let [frame (sse-frame "layout" snap)]
        (each [_ c (ipairs state.sse-clients)]
          (queue! c frame))))))

(fn M.init [_ctx state]
  (let [socket (load-socket)]
    (when (not state.server)
      (let [server (assert (socket.bind state.host state.port))]
        (server:settimeout 0)
        (set state.server server)
        (ensure-queues! state)
        (set state.quit? false)
        (io.stderr:write (.. "fen web presenter: http://" state.host ":"
                            (tostring state.port) "/\n"))))))

(fn M.shutdown [_ctx state]
  (set state.quit? true)
  (each [_ c (ipairs state.clients)] (close! c))
  (each [_ c (ipairs state.sse-clients)] (close! c))
  (set state.clients [])
  (set state.sse-clients [])
  (set state.pending-inputs [])
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
      (flush-list! state.clients)
      (flush-list! state.sse-clients)
      (drain-inputs! state ctx)
      (when ctx.on-tick
        (let [(ok? err) (pcall ctx.on-tick)]
          (when (not ok?)
            (io.stderr:write (.. "on-tick: " (tostring err) "\n")))))
      (let [t (now socket)]
        (when (> (- t (or state.last-broadcast 0)) 0.15)
          (set state.last-broadcast t)
          (broadcast! state ctx)))
      (flush-list! state.sse-clients)
      (socket.sleep 0.03))))

M
