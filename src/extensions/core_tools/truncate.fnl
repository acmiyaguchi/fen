;; Shared output-size truncation helpers for tool outputs.

(local DEFAULT-MAX-LINES 2000)
(local DEFAULT-MAX-BYTES (* 50 1024))

(fn count-lines [s]
  (var n 1)
  (each [_ (string.gmatch s "\n")] (set n (+ n 1)))
  n)

(fn fmt-kb [n]
  (string.format "%dKB" (math.floor (/ n 1024))))

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn tool-output-dir []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel/tool-output")
        (.. (home) "/.local/state/agent-fennel/tool-output"))))

(fn spill-id []
  (math.randomseed (+ (os.time) (math.floor (* (os.clock) 1000000))))
  (let [parts []]
    (for [_ 1 8]
      (table.insert parts (string.format "%x" (math.random 0 15))))
    (table.concat parts)))

(fn spill-full-output [content]
  "Write content to a file under the tool-output dir and return its path."
  (let [dir (tool-output-dir)
        _ (os.execute (.. "mkdir -p '"
                          (string.gsub dir "'" "'\\''") "'"))
        ts (os.date "!%Y%m%dT%H%M%S")
        path (.. dir "/" ts "_" (spill-id) ".txt")
        (f open-err) (io.open path :w)]
    (if (not f)
        (do (io.stderr:write "agent-fennel: tool-output spill failed: "
                              (tostring open-err) "\n")
            nil)
        (do (f:write (or content ""))
            (f:close)
            path))))

(fn truncation-tag [kept-lines total-lines kept-bytes total-bytes head? full-path]
  (let [kind (if head? "head" "tail")
        base (string.format "[truncated: kept %s %d/%d lines, %s/%s"
                            kind kept-lines total-lines
                            (fmt-kb kept-bytes) (fmt-kb total-bytes))]
    (if full-path
        (.. base " — full output: " full-path "]")
        (.. base "]"))))

(fn truncate-head [s opts]
  "Keep the first lines of s up to maxLines / maxBytes."
  (let [s (or s "")
        max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
        max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
        total-bytes (length s)
        total-lines (count-lines s)]
    (if (and (<= total-lines max-lines) (<= total-bytes max-bytes))
        (values s false)
        (let [out []]
          (var bytes 0)
          (var lines 0)
          (var done? false)
          (each [line (string.gmatch (.. s "\n") "([^\n]*)\n") &until done?]
            (let [llen (+ (length line) 1)]
              (if (or (>= lines max-lines)
                      (> (+ bytes llen) max-bytes))
                  (set done? true)
                  (do (table.insert out line)
                      (set lines (+ lines 1))
                      (set bytes (+ bytes llen))))))
          (let [content (table.concat out "\n")
                full-path (spill-full-output s)
                tag (truncation-tag lines total-lines (length content)
                                    total-bytes true full-path)]
            (values (.. content "\n" tag) true))))))

(fn truncate-tail [s opts]
  "Keep the last lines of s up to maxLines / maxBytes."
  (let [s (or s "")
        max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
        max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
        total-bytes (length s)
        total-lines (count-lines s)]
    (if (and (<= total-lines max-lines) (<= total-bytes max-bytes))
        (values s false)
        (let [lines []]
          (each [line (string.gmatch (.. s "\n") "([^\n]*)\n")]
            (table.insert lines line))
          (let [out []]
            (var bytes 0)
            (var taken 0)
            (var idx (length lines))
            (var done? false)
            (while (and (> idx 0) (not done?))
              (let [line (. lines idx)
                    llen (+ (length line) 1)]
                (if (or (>= taken max-lines)
                        (> (+ bytes llen) max-bytes))
                    (set done? true)
                    (do (table.insert out 1 line)
                        (set taken (+ taken 1))
                        (set bytes (+ bytes llen))
                        (set idx (- idx 1))))))
            (let [content (table.concat out "\n")
                  full-path (spill-full-output s)
                  tag (truncation-tag taken total-lines (length content)
                                      total-bytes false full-path)]
              (values (.. tag "\n" content) true)))))))

{: DEFAULT-MAX-LINES
 : DEFAULT-MAX-BYTES
 : truncate-head
 : truncate-tail}
