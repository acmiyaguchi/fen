;; Host-side PTY helpers for opt-in TUI smoke tests.
;; Native syscalls live in fen_pty; scenario logic and artifacts stay in Fennel.

(local native (require :fen_pty))
(local h (require :fen.testing))

(fn now []
  (let [(ok? socket) (pcall require :socket)]
    (assert (and ok? socket.gettime)
            "fen.testing.pty requires luasocket for wall-clock timeouts")
    (socket.gettime)))

(fn encode-json [x]
  (let [(ok? cjson) (pcall require :cjson)]
    (if ok?
        (cjson.encode x)
        (do
          ;; Minimal fallback for the simple artifact records written here.
          (fn esc [s]
            (.. "\"" (string.gsub (string.gsub (string.gsub (tostring s) "\\" "\\\\") "\n" "\\n") "\"" "\\\"") "\""))
          (fn enc [v]
            (case (type v)
              :string (esc v)
              :number (tostring v)
              :boolean (if v "true" "false")
              :table (let [array? (not= (. v 1) nil)
                           parts []]
                       (if array?
                           (do
                             (each [_ item (ipairs v)] (table.insert parts (enc item)))
                             (.. "[" (table.concat parts ",") "]"))
                           (do
                             (each [k item (pairs v)]
                               (table.insert parts (.. (esc k) ":" (enc item))))
                             (.. "{" (table.concat parts ",") "}"))))
              _ (if (= v nil) "null" (esc v))))
          (enc x)))))

(fn ensure-dir [path]
  (assert (os.execute (.. "mkdir -p -- " (h.shellquote path))))
  path)

(fn artifact-dir [scenario]
  (let [root (or (os.getenv :FEN_TUI_PTY_ARTIFACTS) "tmp/tui-pty")
        stamp (os.date "!%Y%m%dT%H%M%SZ")
        path (.. root "/" stamp "-" scenario)]
    (ensure-dir path)))

(fn write-file [path content mode]
  (let [f (assert (io.open path (or mode :w)))]
    (f:write (or content ""))
    (f:close))
  path)

(fn append-file [path content]
  (write-file path content :a))

(fn cast-start [path cols rows env]
  (write-file path (.. (encode-json {:version 2
                                     :width cols
                                     :height rows
                                     :timestamp (os.time)
                                     :env (or env {:TERM "xterm-256color"})})
                       "\n")))

(fn cast-event [path t kind data]
  (append-file path (.. (encode-json [t kind data]) "\n")))

(fn spawn [opts]
  (native.spawn opts))

(fn read-until [child marker timeout-ms opts]
  (let [deadline (+ (now) (/ (or timeout-ms 1000) 1000))
        max-bytes (or (and opts opts.max-bytes) 4096)
        on-chunk (and opts opts.on-chunk)
        chunks []]
    (var done? false)
    (while (and (not done?) (< (now) deadline))
      (let [remaining-ms (math.max 1 (math.floor (* (- deadline (now)) 1000)))
            (chunk err) (child:read (math.min remaining-ms 100) max-bytes)]
        (when chunk
          (if (= chunk "")
              (set done? true)
              (do
                (table.insert chunks chunk)
                (when on-chunk (on-chunk chunk))
                (when (string.find (table.concat chunks "") marker 1 true)
                  (set done? true)))))))
    (let [out (table.concat chunks "")]
      (if (string.find out marker 1 true)
          out
          (values nil out)))))

(fn drain [child timeout-ms opts]
  (var deadline (+ (now) (/ (or timeout-ms 200) 1000)))
  (let [max-bytes (or (and opts opts.max-bytes) 4096)
        on-chunk (and opts opts.on-chunk)
        chunks []]
    (while (< (now) deadline)
      (let [(chunk err) (child:read 20 max-bytes)]
        (if (and chunk (not= chunk ""))
            (do (table.insert chunks chunk)
                (when on-chunk (on-chunk chunk)))
            (set deadline 0))))
    (table.concat chunks "")))

{: spawn
 : read-until
 : drain
 : now
 : artifact-dir
 : ensure-dir
 : write-file
 : append-file
 : encode-json
 : cast-start
 : cast-event}
