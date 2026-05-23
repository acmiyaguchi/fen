;; Shared output-size truncation helpers for tool outputs.

;; @doc fen.extensions.builtin_tools.truncate.DEFAULT-MAX-LINES
;; kind: data
;; signature: number
;; summary: Default maximum number of tool-output lines kept inline before truncation spills the full output.
;; tags: builtin tools truncate defaults
(local DEFAULT-MAX-LINES 2000)

;; @doc fen.extensions.builtin_tools.truncate.DEFAULT-MAX-BYTES
;; kind: data
;; signature: number
;; summary: Default maximum number of tool-output bytes kept inline before truncation writes a spill file.
;; tags: builtin tools truncate defaults
(local DEFAULT-MAX-BYTES (* 50 1024))

(local LINES-BEFORE-YIELD 512)
(local WRITE-CHUNK-SIZE 16384)

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

(fn count-lines [s ?yield-fn]
  (var n 1)
  (var scanned 0)
  (each [_ (string.gmatch s "\n")]
    (set n (+ n 1))
    (set scanned (+ scanned 1))
    (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
      (set scanned 0)
      (?yield-fn)))
  n)

(fn fmt-kb [n]
  (string.format "%dKB" (math.floor (/ n 1024))))

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn tool-output-dir []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/fen/tool-output")
        (.. (home) "/.local/state/fen/tool-output"))))

(fn spill-id []
  (math.randomseed (+ (os.time) (math.floor (* (os.clock) 1000000))))
  (let [parts []]
    (for [_ 1 8]
      (table.insert parts (string.format "%x" (math.random 0 15))))
    (table.concat parts)))

(fn write-string-chunks [f content ?yield-fn]
  (let [s (or content "")
        total (length s)]
    (if (= total 0)
        (f:write "")
        (do
          (var i 1)
          (while (<= i total)
            (let [j (math.min total (+ i WRITE-CHUNK-SIZE -1))]
              (f:write (string.sub s i j))
              (set i (+ j 1))
              (maybe-yield ?yield-fn)))))))

(fn spill-full-output [content ?yield-fn]
  "Write content to a file under the tool-output dir and return its path."
  (let [dir (tool-output-dir)
        _ (maybe-yield ?yield-fn)
        _mkdir (os.execute (.. "mkdir -p '"
                              (string.gsub dir "'" "'\\''") "'"))
        _ (maybe-yield ?yield-fn)
        ts (os.date "!%Y%m%dT%H%M%S")
        path (.. dir "/" ts "_" (spill-id) ".txt")
        (f open-err) (io.open path :w)]
    (if (not f)
        (do (io.stderr:write "fen: tool-output spill failed: "
                              (tostring open-err) "\n")
            nil)
        (let [(ok? err) (xpcall #(write-string-chunks f content ?yield-fn)
                                debug.traceback)]
          (f:close)
          (if ok?
              path
              (error err))))))

(fn truncation-tag [kept-lines total-lines kept-bytes total-bytes head? full-path]
  (let [kind (if head? "head" "tail")
        base (string.format "[truncated: kept %s %d/%d lines, %s/%s"
                            kind kept-lines total-lines
                            (fmt-kb kept-bytes) (fmt-kb total-bytes))]
    (if full-path
        (.. base " — full output: " full-path "]")
        (.. base "]"))))

;; @doc fen.extensions.builtin_tools.truncate.truncate-head
;; kind: function
;; signature: (truncate-head s opts? yield-fn?) -> string, truncated?
;; summary: Keep the beginning of tool output within max-lines/max-bytes, yielding during scans and full-output spills when cooperative.
;; tags: tools output truncate
(fn truncate-head [s opts ?yield-fn]
  "Keep the first lines of s up to maxLines / maxBytes."
  (let [s (or s "")
        max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
        max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
        total-bytes (length s)
        total-lines (count-lines s ?yield-fn)]
    (if (and (<= total-lines max-lines) (<= total-bytes max-bytes))
        (values s false)
        (let [out []]
          (var bytes 0)
          (var lines 0)
          (var scanned 0)
          (var done? false)
          (each [line (string.gmatch (.. s "\n") "([^\n]*)\n") &until done?]
            (set scanned (+ scanned 1))
            (let [llen (+ (length line) 1)]
              (if (or (>= lines max-lines)
                      (> (+ bytes llen) max-bytes))
                  (set done? true)
                  (do (table.insert out line)
                      (set lines (+ lines 1))
                      (set bytes (+ bytes llen)))))
            (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
              (set scanned 0)
              (?yield-fn)))
          (let [content (table.concat out "\n")
                full-path (spill-full-output s ?yield-fn)
                tag (truncation-tag lines total-lines (length content)
                                    total-bytes true full-path)]
            (values (.. content "\n" tag) true))))))

;; @doc fen.extensions.builtin_tools.truncate.truncate-tail
;; kind: function
;; signature: (truncate-tail s opts? yield-fn?) -> string, truncated?
;; summary: Keep the end of tool output within max-lines/max-bytes, yielding during scans and full-output spills when cooperative.
;; tags: tools output truncate
(fn truncate-tail [s opts ?yield-fn]
  "Keep the last lines of s up to maxLines / maxBytes."
  (let [s (or s "")
        max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
        max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
        total-bytes (length s)
        total-lines (count-lines s ?yield-fn)]
    (if (and (<= total-lines max-lines) (<= total-bytes max-bytes))
        (values s false)
        (let [lines []]
          (var scanned 0)
          (each [line (string.gmatch (.. s "\n") "([^\n]*)\n")]
            (table.insert lines line)
            (set scanned (+ scanned 1))
            (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
              (set scanned 0)
              (?yield-fn)))
          (let [out []]
            (var bytes 0)
            (var taken 0)
            (var idx (length lines))
            (var done? false)
            (var scanned-tail 0)
            (while (and (> idx 0) (not done?))
              (let [line (. lines idx)
                    llen (+ (length line) 1)]
                (if (or (>= taken max-lines)
                        (> (+ bytes llen) max-bytes))
                    (set done? true)
                    (do (table.insert out 1 line)
                        (set taken (+ taken 1))
                        (set bytes (+ bytes llen))
                        (set idx (- idx 1)))))
              (set scanned-tail (+ scanned-tail 1))
              (when (and ?yield-fn (>= scanned-tail LINES-BEFORE-YIELD))
                (set scanned-tail 0)
                (?yield-fn)))
            (let [content (table.concat out "\n")
                  full-path (spill-full-output s ?yield-fn)
                  tag (truncation-tag taken total-lines (length content)
                                      total-bytes false full-path)]
              (values (.. tag "\n" content) true)))))))

{: DEFAULT-MAX-LINES
 : DEFAULT-MAX-BYTES
 : truncate-head
 : truncate-tail}
