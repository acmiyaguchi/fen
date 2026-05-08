;; Tiny LuaSocket HTTP/SSE server for the web presenter.

(local json (require :fen.util.json))
(local web-state (require :fen.extensions.web.state))
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

;; @doc fen.extensions.web.server.parse-request
;; kind: function
;; signature: (parse-request buf) -> Request|nil
;; summary: Parse a buffered HTTP request once headers and the declared body length have arrived.
;; tags: web server http parse
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

(fn finish-select! [state body]
  (let [sel state.active-select
        body (or body "")]
    (when (and sel (not sel.done?))
      (if (= body "cancel")
          (set sel.result nil)
          (let [idx (tonumber body)]
            (when (and idx (>= idx 1) (<= idx (length (or sel.choices []))))
              (set sel.result (. sel.choices idx)))))
      (set sel.done? true))))

(fn emit! [_ctx ev]
  ;; Use the extension bus directly. Going through ctx.state.on-event works
  ;; only after the full presenter run context is installed; direct emit keeps
  ;; HTTP presenter controls valid during init/reload edge cases too.
  (web-state.api.emit ev))

(local DISMISS-COMMANDS
  {:status "/status"
   :queue "/queue"
   :prompt "/prompt"
   :extensions "/extensions"
   :mem "/mem"})

(fn active-panel-names [ctx]
  (let [out {}
        panel-ctx {:w 100}]
    (each [_ p (ipairs (web-state.api.list :panels))]
      (let [(ok? h) (pcall p.height panel-ctx)]
        (when (and ok? (> (or h 0) 0))
          (tset out p.name true))))
    out))

(fn any-still-active? [before after]
  (var found? false)
  (each [name _ (pairs before)]
    (when (. after name)
      (set found? true)))
  found?)

(fn dismiss-panels! [ctx]
  ;; Normal path: panels subscribe to :dismiss and close themselves. If a
  ;; stale/reloaded handler misses the event, fall back to the built-in toggle
  ;; commands for still-visible first-party panels so browser state and command
  ;; state cannot diverge.
  (let [before (active-panel-names ctx)]
    (emit! ctx {:type :dismiss :announce? true})
    (let [after (active-panel-names ctx)]
      (when (any-still-active? before after)
        (each [name _ (pairs after)]
          (let [cmd (. DISMISS-COMMANDS name)]
            (when (and cmd (. before name) (?. ctx :state))
              (web-state.api.commands.dispatch cmd ctx.state))))))))

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
      (and (= req.method :POST) (= req.path "/select"))
      (do (finish-select! state (or req.body ""))
          (queue! c (no-content))
          (set c.close-after? true)
          :close)
      (and (= req.method :POST) (= req.path "/dismiss"))
      (do (dismiss-panels! ctx)
          ;; Force the next tick to push a fresh layout even if the regular
          ;; broadcast throttle would otherwise make the click feel inert.
          (set state.last-snapshot nil)
          (set state.last-broadcast 0)
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

;; @doc fen.extensions.web.server.broadcast!
;; kind: function
;; signature: (broadcast! state ctx) -> nil
;; summary: Queue a layout SSE frame to connected clients when the rendered browser snapshot changes.
;; tags: web server sse broadcast
(fn M.broadcast! [state ctx]
  (broadcast! state ctx))

;; @doc fen.extensions.web.server.init
;; kind: function
;; signature: (init ctx state) -> nil
;; summary: Start the nonblocking LuaSocket HTTP server for the web presenter if it is not already listening.
;; tags: web server lifecycle socket
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

;; @doc fen.extensions.web.server.shutdown
;; kind: function
;; signature: (shutdown ctx state) -> nil
;; summary: Stop the web server, close HTTP and SSE clients, clear queues, and mark the presenter as quitting.
;; tags: web server lifecycle socket
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

;; @doc fen.extensions.web.server.tick
;; kind: function
;; signature: (tick socket state ctx) -> nil
;; summary: Service accepts, HTTP requests, pending inputs, cooperative ticks, SSE broadcasts, flushes, and pacing sleep once.
;; tags: web server loop sse
(fn M.tick [socket state ctx]
  (accept-clients! socket state)
  (drain-clients! socket state ctx)
  (flush-list! state.clients)
  (flush-list! state.sse-clients)
  (when (not state.active-select)
    (drain-inputs! state ctx))
  (when ctx.on-tick
    (let [(ok? err) (pcall ctx.on-tick)]
      (when (not ok?)
        (io.stderr:write (.. "on-tick: " (tostring err) "\n")))))
  (let [t (now socket)]
    (when (> (- t (or state.last-broadcast 0)) 0.15)
      (set state.last-broadcast t)
      (broadcast! state ctx)))
  (flush-list! state.sse-clients)
  (socket.sleep 0.03))

;; @doc fen.extensions.web.server.wait-select
;; kind: function
;; signature: (wait-select ctx state opts) -> Choice|nil
;; summary: Publish an active browser select prompt, service the web loop until a reply arrives, and return the chosen choice.
;; tags: web server select ui
(fn M.wait-select [ctx state opts]
  (let [socket (load-socket)
        opts (or opts {})]
    (when (not state.server)
      (M.init ctx state))
    (set state.select-seq (+ (or state.select-seq 0) 1))
    (let [sel {:id (.. "select-" (tostring state.select-seq))
               :label (tostring (or opts.label "select"))
               :choices (or opts.choices [])
               :done? false
               :result nil}]
      (set state.active-select sel)
      (broadcast! state ctx)
      (while (and (not state.quit?) (not sel.done?))
        (M.tick socket state ctx))
      (set state.active-select nil)
      (broadcast! state ctx)
      sel.result)))

;; @doc fen.extensions.web.server.run
;; kind: function
;; signature: (run ctx state) -> nil
;; summary: Run the web server loop until shutdown sets the persistent quit flag.
;; tags: web server loop lifecycle
(fn M.run [ctx state]
  (let [socket (load-socket)]
    (when (not state.server)
      (M.init ctx state))
    (while (not state.quit?)
      (M.tick socket state ctx))))

M
