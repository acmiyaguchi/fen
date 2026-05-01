;; lua-curl backend for fen.util.http.
;;
;; This is the only module in the codebase that requires `cURL` directly.
;; Owns easy-handle setup, header conversion, body wiring, perform-path
;; selection (blocking via easy:perform, cooperative via curl multi),
;; status extraction, response accumulation, and error stringification.

(local log (require :fen.util.log))

(local DEFAULT-TIMEOUT-MS 600000)
(local DEFAULT-CONNECT-TIMEOUT-MS 30000)

(fn headers->array [headers]
  "Lua table {name value} → curl-style array [\"name: value\" ...]."
  (let [out []]
    (each [k v (pairs (or headers {}))]
      (table.insert out (.. (tostring k) ": " (tostring v))))
    out))

(fn safe-remove! [multi handle label]
  (let [(ok? err) (pcall #(multi:remove_handle handle))]
    (when (not ok?)
      (log.warn (.. "curl multi " label " remove_handle failed: "
                    (tostring err))))))

(fn add-handle! [multi easy]
  (let [(pcall-ok result err) (pcall #(multi:add_handle easy))]
    (if (not pcall-ok)
        (values false result)
        (not result)
        (values false err)
        (values true nil))))

(fn perform-once! [multi]
  (let [(ok? running-or-err) (pcall #(multi:perform))]
    (if ok?
        (values true running-or-err)
        (values false running-or-err))))

(fn drain-info! [multi target]
  "Drain curl multi completion messages.
   Returns (done? ok? err)."
  (var done? false)
  (var ok? true)
  (var err nil)
  (var polling? true)
  (while polling?
    (let [(completed-e transfer-ok transfer-err) (multi:info_read)]
      (if (or (= completed-e nil) (= completed-e 0))
          (set polling? false)
          (= completed-e target)
          (do
            (set done? true)
            (set polling? false)
            (safe-remove! multi target "completed")
            (when (not transfer-ok)
              (set ok? false)
              (set err transfer-err)))
          ;; Unexpected handle from this multi; remove it so it cannot keep
          ;; the loop alive forever.
          (safe-remove! multi completed-e "unexpected"))))
  (values done? ok? err))

(fn perform-coop! [easy yield-fn]
  "Drive a configured cURL easy handle cooperatively through curl.multi.

   Important: do not use multi:iperform here. lua-cURL's iterator calls
   multi:wait() internally, which can still block the Lua VM while the
   server is thinking. Calling multi:perform() once per resume keeps each
   tick short; the TUI controls sleep/pacing via its own event-loop timeout."
  (let [curl (require :cURL)
        multi (curl.multi)
        (added? add-err) (add-handle! multi easy)]
    (if (not added?)
        (values false add-err)
        (do
          (var done? false)
          (var ok? true)
          (var err nil)
          (while (and ok? (not done?))
            (let [(perform-ok perform-err) (perform-once! multi)]
              (if (not perform-ok)
                  (do
                    (set ok? false)
                    (set err perform-err)
                    (safe-remove! multi easy "perform-error"))
                  (let [(drain-done? drain-ok? drain-err) (drain-info! multi easy)]
                    (set done? drain-done?)
                    (when (not drain-ok?)
                      (set ok? false)
                      (set err drain-err))
                    (when (and ok? (not done?) yield-fn)
                      (yield-fn))))))
          (when (and ok? (not done?))
            (safe-remove! multi easy "cleanup"))
          (values ok? err)))))

(fn build-easy [opts]
  (let [curl (require :cURL)
        easy (curl.easy)
        method (or opts.method :GET)
        chunks []
        on-chunk opts.on-chunk
        write-fn (fn [chunk]
                   (table.insert chunks chunk)
                   (when on-chunk (on-chunk chunk))
                   (length chunk))]
    (easy:setopt_url opts.url)
    (when (= method :POST)
      (easy:setopt_post 1)
      (when opts.body
        (easy:setopt_postfields opts.body)))
    (easy:setopt_httpheader (headers->array opts.headers))
    (easy:setopt_timeout_ms (or opts.timeout-ms DEFAULT-TIMEOUT-MS))
    (easy:setopt_connecttimeout_ms
      (or opts.connect-timeout-ms DEFAULT-CONNECT-TIMEOUT-MS))
    (easy:setopt_writefunction write-fn)
    (values easy chunks)))

(fn request [opts]
  "Perform an HTTP request via lua-curl. See fen.util.http for the public
   contract. Returns {:status :body} on transport success (any HTTP
   status) or {:error string} on transport failure."
  (let [(easy chunks) (build-easy opts)
        yield-fn opts.yield
        (ok? err) (if yield-fn
                      (perform-coop! easy yield-fn)
                      (pcall #(easy:perform)))
        status (easy:getinfo_response_code)]
    (easy:close)
    (if (not ok?)
        {:error (tostring err)}
        {: status :body (table.concat chunks)})))

{: request}
