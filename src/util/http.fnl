;; Small HTTP transport helpers shared by providers.
;;
;; The blocking provider path still uses `easy:perform` for print mode and
;; tests. Interactive `agent.step` (running inside a coroutine) calls provider
;; `complete-coop`, which drives an easy handle through curl multi one
;; nonblocking `perform` step at a time and yields back to the TUI between
;; steps.

(local log (require :util.log))

(fn safe-remove! [multi easy label]
  (let [(ok? err) (pcall #(multi:remove_handle easy))]
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
          ;; Unexpected handle from this multi; remove it so it cannot keep the
          ;; loop alive forever.
          (safe-remove! multi completed-e "unexpected"))))
  (values done? ok? err))

(fn perform-coop [easy yield-fn]
  "Perform a configured cURL easy handle cooperatively.

   Returns (values true nil) on transport success, or (values false err) on
   cURL/multi failure. The caller remains responsible for reading response
   bytes from its writefunction, checking HTTP status, and closing `easy`.

   Important: do not use `multi:iperform` here. lua-cURL's iterator calls
   `multi:wait()` internally, which can still block the Lua VM while the
   server is thinking. Calling `multi:perform()` once per resume keeps each
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

{: perform-coop}
