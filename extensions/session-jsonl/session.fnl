;; Session persistence — append-only JSONL transcripts.
;;
;; Mirrors a small subset of pi-mono's session-manager.ts shape so the files
;; could be parsed by a more featureful reader later. Line 1 is a session
;; header; subsequent lines are message entries.
;;
;;   {:type "session" :version 1 :id "..." :timestamp "..." :cwd "..."}
;;   {:type "message" :timestamp "..." :message <canonical AgentMessage>}
;;
;; What we deliberately skip vs pi-mono: parentId / branching tree, fork,
;; compaction summaries, model_change / thinking_level_change entries,
;; UUIDv7 (we use 16 random hex chars). The format is forward-compatible —
;; readers can ignore unknown :type values.

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))

(local VERSION 1)

;; ----------------------------------------------------------------
;; Path helpers
;; ----------------------------------------------------------------

(fn state-dir []
  (path.state-dir :fen))

(fn cwd-slug [cwd]
  ;; Mirror pi-mono's `--<encoded-cwd>--` pattern: replace `/` with `-`,
  ;; strip leading `-`, sandwich with `--`. Single-user, single-host —
  ;; collisions don't matter.
  (let [trimmed (string.gsub cwd "^/" "")
        dashed (string.gsub trimmed "/" "-")]
    (.. "--" dashed "--")))

(fn sessions-root [cwd]
  (.. (state-dir) "/sessions/" (cwd-slug cwd)))

(fn iso-timestamp []
  (os.date "!%Y-%m-%dT%H-%M-%S"))

;; Seed best-effort at module load. Lua's math.random isn't crypto, but we
;; only need uniqueness across human-paced runs. Seeding per-call would just
;; reset the PRNG state on every id, defeating its sequence.
(math.randomseed (+ (os.time) (math.floor (* (os.clock) 1000000))))

(fn random-id []
  (let [parts []]
    (for [_ 1 16]
      (table.insert parts (string.format "%x" (math.random 0 15))))
    (table.concat parts)))

(fn ensure-dir [dir]
  (os.execute (.. "mkdir -p " (path.shell-quote dir))))

;; ----------------------------------------------------------------
;; Open / append / close
;; ----------------------------------------------------------------

(fn id-from-path [p]
  (or (string.match (path.basename p) "_([A-Za-z0-9%-]+)%.jsonl$")
      (string.match (path.basename p) "([^/%.]+)%.jsonl$")))

(fn open-file [p cwd id]
  (let [(f open-err) (io.open p :a)]
    (if (not f)
        (do (log.warn (.. "session: cannot open " p ": " (tostring open-err)))
            nil)
        (do
          (f:setvbuf :line)
          {:id (or id (id-from-path p)) :path p :cwd cwd :file f
           :header-written? true}))))

(fn open [cwd]
  "Pick a future session path under sessions-root(cwd), but do not create the
   file yet. The header is written lazily on the first appended message, which
   mirrors pi-mono and avoids header-only 0-message sessions when the user
   opens/quits the TUI without completing a turn."
  (let [dir (sessions-root cwd)
        ts (iso-timestamp)
        id (random-id)
        p (.. dir "/" ts "_" id ".jsonl")]
    {:id id
     :path p
     :cwd cwd
     :file nil
     :header {:type :session :version VERSION : id :timestamp ts : cwd}
     :header-written? false}))

(fn ensure-open! [session]
  (if session.file
      true
      (do
        (ensure-dir (path.dirname session.path))
        (let [(f open-err) (io.open session.path :a)]
          (if (not f)
              (do (log.warn (.. "session: cannot open " session.path ": "
                              (tostring open-err)))
                  false)
              (do
                (f:setvbuf :line)
                (set session.file f)
                (when (not session.header-written?)
                  (session.file:write (.. (json.encode session.header) "\n"))
                  (set session.header-written? true))
                true))))))

(fn append [session msg]
  "Append one canonical AgentMessage as a :message entry."
  (when (and session (ensure-open! session))
    (let [entry {:type :message :timestamp (iso-timestamp) :message msg}
          (ok? err) (pcall #(session.file:write (.. (json.encode entry) "\n")))]
      (when (not ok?)
        (log.warn (.. "session: append failed: " (tostring err)))))))

(fn close [session]
  (when (and session session.file)
    (session.file:close)
    (set session.file nil)))

;; ----------------------------------------------------------------
;; Discovery / replay
;; ----------------------------------------------------------------

(fn message-count [p]
  (let [(f _open-err) (io.open p :r)]
    (if (not f)
        0
        (do
          ;; Skip header.
          (f:read :*l)
          (var n 0)
          (each [line (f:lines)]
            (when (not= line "")
              (let [(ok? entry) (pcall json.decode line)]
                (when (and ok? entry (= entry.type :message))
                  (set n (+ n 1))))))
          (f:close)
          n))))

(fn latest-for-cwd [cwd]
  "Return the newest non-empty session path for `cwd`, or nil if none. Uses
   `ls -1t` so we don't depend on a Lua FS lib."
  (let [dir (sessions-root cwd)
        cmd (.. "ls -1t " (path.shell-quote dir) " 2>/dev/null")
        pipe (io.popen cmd :r)]
    (if (not pipe)
        nil
        (do
          (var found nil)
          (var done? false)
          (while (not done?)
            (let [name (pipe:read :*l)]
              (if (or (not name) (= name ""))
                  (set done? true)
                  (when (string.match name "%.jsonl$")
                    (let [p (.. dir "/" name)]
                      (when (> (message-count p) 0)
                        (set found p)
                        (set done? true)))))))
          (pipe:close)
          found))))

(fn header [p]
  "Read and decode the first JSONL header entry from `p`, or nil."
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        (do (log.warn (.. "session: cannot read header " p ": " (tostring open-err)))
            nil)
        (let [line (f:read :*l)]
          (f:close)
          (when (and line (not= line ""))
            (let [(ok? entry) (pcall json.decode line)]
              (if (and ok? entry (= entry.type :session))
                  entry
                  nil)))))))

(fn first-text [msg]
  (if (= (type (?. msg :content)) :string)
      msg.content
      (= (type (?. msg :content)) :table)
      (let [parts []]
        (each [_ block (ipairs msg.content)]
          (when (and (= (?. block :type) :text) block.text)
            (table.insert parts block.text)))
        (when (> (length parts) 0)
          (table.concat parts " ")))))

(fn scan-summary [p]
  "Return lightweight transcript metadata: title text and message count."
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        (do (log.warn (.. "session: cannot read summary " p ": " (tostring open-err)))
            {:title nil :message-count 0})
        (do
          ;; Skip header.
          (f:read :*l)
          (var fallback nil)
          (var found nil)
          (var message-count 0)
          (each [line (f:lines)]
            (when (not= line "")
              (let [(ok? entry) (pcall json.decode line)
                    msg (and ok? entry (= entry.type :message) entry.message)]
                (when msg
                  (set message-count (+ message-count 1))
                  (when (not found)
                    (let [text (first-text msg)]
                      (when text
                        (if (= msg.role :user)
                            (set found text)
                            (when (not fallback)
                              (set fallback text))))))))))
          (f:close)
          {:title (or found fallback) :message-count message-count}))))

(fn title [p]
  "Return a human title for a transcript: first user text, falling back to
   first assistant text, then nil."
  (. (scan-summary p) :title))

(fn short-title [s]
  (when s
    (let [one-line (string.gsub s "%s+" " ")]
      (if (> (length one-line) 80)
          (.. (string.sub one-line 1 77) "...")
          one-line))))

(fn session-record [p]
  (let [h (header p)
        summary (scan-summary p)]
    {:path p
     :id (or (?. h :id) (id-from-path p))
     :cwd (?. h :cwd)
     :timestamp (or (?. h :timestamp)
                    (string.match (path.basename p) "^([^_]+)"))
     :title (short-title summary.title)
     :message-count summary.message-count
     :version (?. h :version)}))

(fn list-for-cwd [cwd limit]
  "Return recent session metadata records for `cwd`, newest first."
  (let [dir (sessions-root cwd)
        max-count (or limit 20)
        cmd (.. "ls -1t " (path.shell-quote dir) " 2>/dev/null")
        pipe (io.popen cmd :r)
        out []]
    (when pipe
      (var done? false)
      (while (not done?)
        (let [name (pipe:read :*l)]
          (if (or (not name) (= name "") (>= (length out) max-count))
              (set done? true)
              (when (string.match name "%.jsonl$")
                (let [rec (session-record (.. dir "/" name))]
                  (when (> (or rec.message-count 0) 0)
                    (table.insert out rec)))))))
      (pipe:close))
    out))

(fn open-existing [p]
  "Open an existing session JSONL for append without writing a duplicate
   header. Returns nil if the path is not a regular file."
  (if (not (path.file-exists? p))
      (do (log.warn (.. "session: cannot resume missing file " p)) nil)
      (let [h (header p)]
        (open-file p (?. h :cwd) (?. h :id)))))

(fn find [cwd target]
  "Resolve a session target for `cwd`. Target may be nil/latest, a 0-based
   reverse-chronological list index, an existing path, an exact id, or a
   unique id/path prefix among cwd sessions."
  (let [t (or target :latest)]
    (if (or (= t "") (= t :latest) (= t "latest"))
        (latest-for-cwd cwd)
        (let [idx (tonumber t)
              sessions (list-for-cwd cwd 200)]
          (if (and idx (>= idx 0) (< idx (length sessions)))
              (. sessions (+ idx 1) :path)
              (path.file-exists? t)
              t
              (let [matches []]
                (each [_ rec (ipairs sessions)]
                  (when (or (= rec.id t)
                            (= rec.path t)
                            (and rec.id (= (string.sub rec.id 1 (length t)) t))
                            (= (string.sub rec.path 1 (length t)) t))
                    (table.insert matches rec.path)))
                (if (= (length matches) 1)
                    (. matches 1)
                    nil)))))))

(fn load [path]
  "Read the JSONL at `path` and return the canonical message list (the
   contents of every :message entry, in file order). Header and unknown
   entry types are skipped silently."
  (let [(f open-err) (io.open path :r)
        msgs []]
    (if (not f)
        (do (log.warn (.. "session: cannot read " path ": " (tostring open-err)))
            msgs)
        (do
          (each [line (f:lines)]
            (when (not= line "")
              (let [(ok? entry) (pcall json.decode line)]
                (if (not ok?)
                    (log.warn (.. "session: skipping malformed line in " path))
                    (and entry (= entry.type :message) entry.message)
                    (table.insert msgs entry.message)))))
          (f:close)
          msgs))))

{:open open
 :open-existing open-existing
 :append append
 :close close
 :latest-for-cwd latest-for-cwd
 :list-for-cwd list-for-cwd
 :header header
 :title title
 :message-count message-count
 :find find
 :load load
 :sessions-root sessions-root
 :cwd-slug cwd-slug
 :VERSION VERSION}
