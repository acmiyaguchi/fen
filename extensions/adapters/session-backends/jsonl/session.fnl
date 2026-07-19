;; Session persistence — append-only JSONL transcripts.
;;
;; Mirrors a small subset of pi-mono's session-manager.ts shape so the files
;; could be parsed by a more featureful reader later. Line 1 is a session
;; header; subsequent lines are message entries.
;;
;;   {:type "session" :version 2 :id "..." :timestamp "..." :cwd "..."}
;;   {:type "message" :id "..." :parent-id "..." :timestamp "..."
;;    :message <canonical AgentMessage>}
;;
;; What we deliberately skip vs pi-mono: branching tree navigation, fork,
;; compaction summaries, model_change / thinking_level_change entries,
;; UUIDv7 dependency (we use an in-tree UUIDv7-shaped helper). The format is
;; forward-compatible — readers can ignore unknown :type values.

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))
(local id (require :fen.util.id))
(local types (require :fen.core.types))
(local process (require :fen.util.process))
(local cache-state (require :fen.extensions.session_jsonl.state))

(local VERSION 2)
(local LINES-BEFORE-YIELD 512)

(fn maybe-yield [?yield-fn]
  (when ?yield-fn (?yield-fn)))

;; ----------------------------------------------------------------
;; Path helpers
;; ----------------------------------------------------------------

(fn state-dir []
  (path.state-dir :fen))

;; @doc fen.extensions.session_jsonl.session.cwd-slug
;; kind: function
;; signature: (cwd-slug cwd) -> string
;; summary: Convert a cwd into the pi-mono-style session directory slug used under the fen sessions root.
;; tags: session jsonl paths
(fn cwd-slug [cwd]
  ;; Mirror pi-mono's `--<encoded-cwd>--` pattern: replace `/` with `-`,
  ;; strip leading `-`, sandwich with `--`. Single-user, single-host —
  ;; collisions don't matter.
  (let [trimmed (string.gsub cwd "^/" "")
        dashed (string.gsub trimmed "/" "-")]
    (.. "--" dashed "--")))

;; @doc fen.extensions.session_jsonl.session.sessions-root
;; kind: function
;; signature: (sessions-root cwd) -> string
;; summary: Return the state-directory path containing JSONL sessions for a specific cwd.
;; tags: session jsonl paths
(fn sessions-root [cwd]
  (.. (state-dir) "/sessions/" (cwd-slug cwd)))

(fn iso-timestamp []
  (os.date "!%Y-%m-%dT%H-%M-%S"))

(fn random-id []
  (id.uuidv7))

(fn ensure-dir [dir]
  (os.execute (.. "mkdir -p " (path.shell-quote dir))))

(var lfs-mod :unknown)

(fn lfs []
  (when (= lfs-mod :unknown)
    (let [(ok? mod) (pcall require :lfs)]
      (set lfs-mod (if ok? mod false))))
  (if lfs-mod lfs-mod nil))

(fn split-lines [s]
  (let [out []]
    (each [line (string.gmatch (or s "") "([^\n]+)")]
      (table.insert out line))
    out))

(fn command-output-lines [cmd ?yield-fn]
  (let [pipe (io.popen cmd :r)]
    (if pipe
        (split-lines (process.read-pipe-close pipe ?yield-fn))
        [])))

(fn file-signature [p]
  (let [l (lfs)]
    (when (and l l.attributes)
      (let [size (l.attributes p :size)
            mtime (l.attributes p :modification)]
        (when (and size mtime)
          {:size size :mtime mtime})))))

(fn cache-get [p sig]
  (let [rec (. cache-state.record-cache p)]
    (when (and rec sig (= rec.size sig.size) (= rec.mtime sig.mtime))
      rec)))

(fn cache-put! [p sig rec]
  (when (and p sig rec)
    (tset cache-state.record-cache p
          (let [out {}]
            (each [k v (pairs rec)] (tset out k v))
            (set out.size sig.size)
            (set out.mtime sig.mtime)
            out))))

(fn cache-invalidate! [p]
  (when p
    (tset cache-state.record-cache p nil)))

(fn session-files-newest [dir ?yield-fn]
  "Return JSONL filenames in newest-first order, preferring lfs over shell ls."
  (let [l (lfs)]
    (if (and l l.dir l.attributes)
        (let [items []]
          (when (path.dir-exists? dir)
            (fn scan! []
              (each [name (l.dir dir)]
                (when (string.match name "%.jsonl$")
                  (let [p (.. dir "/" name)
                        mtime (or (l.attributes p :modification) 0)]
                    (table.insert items {:name name :mtime mtime})
                    (maybe-yield ?yield-fn)))))
            (if ?yield-fn
                (scan!)
                (let [(ok? err) (xpcall scan! debug.traceback)]
                  (when (not ok?)
                    (log.warn (.. "session: cannot list " dir ": " (tostring err)))))))
          (table.sort items (fn [a b]
                              (if (= a.mtime b.mtime)
                                  (> a.name b.name)
                                  (> a.mtime b.mtime))))
          (let [out []]
            (each [_ item (ipairs items)]
              (table.insert out item.name))
            out))
        (command-output-lines (.. "ls -1t " (path.shell-quote dir) " 2>/dev/null") ?yield-fn))))

;; ----------------------------------------------------------------
;; Open / append / close
;; ----------------------------------------------------------------

(fn id-from-path [p]
  (or (string.match (path.basename p) "_([A-Za-z0-9%-]+)%.jsonl$")
      (string.match (path.basename p) "([^/%.]+)%.jsonl$")))

(fn read-entries [p ?yield-fn]
  "Read JSONL entries, skipping malformed lines with a warning."
  (let [(f open-err) (io.open p :r)
        entries []]
    (if (not f)
        (do (log.warn (.. "session: cannot read " p ": " (tostring open-err)))
            entries)
        (let [(ok? err)
              (xpcall
                (fn []
                  (var scanned 0)
                  (each [line (f:lines)]
                    (when (not= line "")
                      (let [(ok? entry) (pcall json.decode line)]
                        (if (and ok? (= (type entry) :table))
                            (table.insert entries entry)
                            (log.warn (.. "session: skipping malformed line in " p)))))
                    (set scanned (+ scanned 1))
                    (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
                      (set scanned 0)
                      (?yield-fn))))
                debug.traceback)]
          (f:close)
          (if ok? entries (error err))))))

(fn last-entry-id [p ?yield-fn]
  "Return the last persisted entry id in a JSONL session, if present."
  (var last nil)
  (each [_ entry (ipairs (read-entries p ?yield-fn))]
    (when entry.id
      (set last entry.id))
    (maybe-yield ?yield-fn))
  last)

(fn open-file [p cwd id ?yield-fn ?last-entry-id]
  (let [(f open-err) (io.open p :a)]
    (if (not f)
        (do (log.warn (.. "session: cannot open " p ": " (tostring open-err)))
            nil)
        (do
          (f:setvbuf :line)
          {:id (or id (id-from-path p)) :path p :cwd cwd :file f
           :last-entry-id (if (not= ?last-entry-id nil)
                              ?last-entry-id
                              (last-entry-id p ?yield-fn))
           :header-written? true}))))

;; @doc fen.extensions.session_jsonl.session.open
;; kind: function
;; signature: (open cwd) -> Session
;; summary: Allocate a future append-only JSONL session path for cwd without creating the file until the first appended message.
;; tags: session jsonl open
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
     :last-entry-id nil
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

;; @doc fen.extensions.session_jsonl.session.create
;; kind: function
;; signature: (create cwd) -> Session|nil
;; summary: Create a durable header-only session which can be addressed before its first turn.
;; tags: session jsonl create
(fn create [cwd]
  (let [session (open cwd)]
    (when (ensure-open! session)
      ;; A machine-created session must survive this process even when no turn
      ;; has been submitted yet. Interactive `open` remains lazy.
      (session.file:flush)
      session)))

;; @doc fen.extensions.session_jsonl.session.append-entry
;; kind: function
;; signature: (append-entry session entry) -> entry|nil
;; summary: Lazily open the session file and append one JSONL entry with stable id, parent-id, and timestamp metadata.
;; tags: session jsonl append entries ids
(fn append-entry [session entry]
  "Append one JSONL session entry. Missing :id, :parent-id, and :timestamp
   fields are filled here so entry identity stays backend-owned."
  (when (and session entry entry.type (ensure-open! session))
    (let [out {}]
      (each [k v (pairs entry)]
        (tset out k v))
      (when (not out.id)
        (set out.id (id.uuidv7)))
      (when (and (= (. out :parent-id) nil) session.last-entry-id)
        (tset out :parent-id session.last-entry-id))
      (when (not out.timestamp)
        (set out.timestamp (iso-timestamp)))
      (let [(ok? err) (pcall #(session.file:write (.. (json.encode out) "\n")))]
        (if ok?
            (do (set session.last-entry-id out.id)
                (cache-invalidate! session.path)
                out)
            (do (log.warn (.. "session: append failed: " (tostring err)))
                nil))))))

;; @doc fen.extensions.session_jsonl.session.append
;; kind: function
;; signature: (append session msg) -> nil
;; summary: Lazily open the session file if needed and append one canonical AgentMessage as a JSONL :message entry.
;; tags: session jsonl append
(fn clone-message-for-storage [msg]
  "Copy a message while dropping in-memory session metadata fields."
  (let [out {}]
    (each [k v (pairs msg)]
      (when (not= (string.sub (tostring k) 1 2) "__")
        (tset out k v)))
    out))

(fn append [session msg]
  "Append one canonical AgentMessage as a :message entry."
  (let [entry (append-entry session {:type :message
                                     :message (clone-message-for-storage msg)})]
    (when (and entry msg)
      (tset msg :__session-entry-id entry.id))
    entry))

;; @doc fen.extensions.session_jsonl.session.close
;; kind: function
;; signature: (close session) -> nil
;; summary: Close an open session file handle and clear it from the mutable session record.
;; tags: session jsonl close
(fn close [session]
  (when (and session session.file)
    (session.file:close)
    (set session.file nil)))

;; ----------------------------------------------------------------
;; Discovery / replay
;; ----------------------------------------------------------------

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

(fn valid-extension-state-entry? [entry]
  (and (= entry.type :extension-state)
       entry.extension
       (= (type entry.version) :number)
       (= entry.version (math.floor entry.version))
       (>= entry.version 1)
       (= (type entry.state) :table)))

(fn replayable-entry? [entry]
  (or (and (= entry.type :message) (= (type entry.message) :table))
      (valid-extension-state-entry? entry)))

(fn scan-metadata [p ?yield-fn]
  "Scan one JSONL file once and return lightweight metadata for list/find/open."
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        (do (log.warn (.. "session: cannot read metadata " p ": " (tostring open-err)))
            {:path p :id (id-from-path p) :message-count 0})
        (let [rec {:path p
                   :id (id-from-path p)
                   :timestamp (string.match (path.basename p) "^([^_]+)")
                   :message-count 0
                   :raw-entry-count 0
                   :extension-state-entries {}}
              (ok? err)
              (xpcall
                (fn []
                  (let [header-line (f:read :*l)]
                    (when (and header-line (not= header-line ""))
                      (let [(ok? h) (pcall json.decode header-line)]
                        (when (and ok? (= (type h) :table) (= h.type :session))
                          (set rec.id (or h.id rec.id))
                          (set rec.cwd h.cwd)
                          (set rec.timestamp (or h.timestamp rec.timestamp))
                          (set rec.version h.version)))))
                  (var fallback nil)
                  (var found nil)
                  (var scanned 0)
                  (each [line (f:lines)]
                    (when (not= line "")
                      (let [(ok? entry) (pcall json.decode line)]
                        (when (and ok? (= (type entry) :table))
                          (set rec.raw-entry-count (+ rec.raw-entry-count 1))
                          (when (replayable-entry? entry)
                            (set rec.entry-count (+ (or rec.entry-count 0) 1)))
                          (when (and (= entry.type :extension-state) entry.extension)
                            (let [owner (tostring entry.extension)
                                  entries (or (. rec.extension-state-entries owner) [])]
                              (table.insert entries entry)
                              (tset rec.extension-state-entries owner entries)))
                          (when entry.id
                            (set rec.last-entry-id entry.id))
                          (let [msg (and (= entry.type :message)
                                         (= (type entry.message) :table)
                                         entry.message)]
                            (when msg
                              (set rec.message-count (+ rec.message-count 1))
                              (when (not found)
                                (let [text (first-text msg)]
                                  (when text
                                    (if (= msg.role :user)
                                        (set found text)
                                        (when (not fallback)
                                          (set fallback text)))))))))))
                    (set scanned (+ scanned 1))
                    (when (and ?yield-fn (>= scanned LINES-BEFORE-YIELD))
                      (set scanned 0)
                      (?yield-fn)))
                  (set rec.title (or found fallback)))
                debug.traceback)]
          (f:close)
          (if ok? rec (error err))))))

(fn cached-record [p ?yield-fn]
  (let [sig (file-signature p)
        cached (cache-get p sig)]
    (if cached
        cached
        (let [rec (scan-metadata p ?yield-fn)]
          (cache-put! p sig rec)
          rec))))

;; @doc fen.extensions.session_jsonl.session.message-count
;; kind: function
;; signature: (message-count p) -> number
;; summary: Count valid :message entries in a session JSONL file while skipping the header and malformed lines.
;; tags: session jsonl inspect
(fn message-count [p ?yield-fn]
  (or (?. (cached-record p ?yield-fn) :message-count) 0))

;; @doc fen.extensions.session_jsonl.session.latest-for-cwd
;; kind: function
;; signature: (latest-for-cwd cwd) -> string|nil
;; summary: Return the newest non-empty session JSONL path for cwd by scanning the cwd session directory newest first.
;; tags: session jsonl discovery
(fn latest-for-cwd [cwd ?yield-fn]
  "Return the newest non-empty session path for `cwd`, or nil if none."
  (let [dir (sessions-root cwd)
        names (session-files-newest dir ?yield-fn)]
    (var found nil)
    (each [_ name (ipairs names) &until found]
      (let [p (.. dir "/" name)]
        (when (> (or (?. (cached-record p ?yield-fn) :entry-count) 0) 0)
          (set found p)))
      (maybe-yield ?yield-fn))
    found))

;; @doc fen.extensions.session_jsonl.session.header
;; kind: function
;; signature: (header p) -> table|nil
;; summary: Read and decode the first JSONL header entry from a session file, returning nil for unreadable or non-session headers.
;; tags: session jsonl inspect
(fn header [p ?yield-fn]
  "Read and decode the first JSONL header entry from `p`, or nil."
  (maybe-yield ?yield-fn)
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        (do (log.warn (.. "session: cannot read header " p ": " (tostring open-err)))
            nil)
        (let [line (f:read :*l)]
          (f:close)
          (when (and line (not= line ""))
            (let [(ok? entry) (pcall json.decode line)]
              (if (and ok? (= (type entry) :table) (= entry.type :session))
                  entry
                  nil)))))))

(fn scan-summary [p ?yield-fn]
  "Return lightweight transcript metadata: title text and message count."
  (let [rec (cached-record p ?yield-fn)]
    {:title rec.title :message-count (or rec.message-count 0)}))

;; @doc fen.extensions.session_jsonl.session.title
;; kind: function
;; signature: (title p) -> string|nil
;; summary: Return a human-readable transcript title from the first user text, falling back to the first assistant text.
;; tags: session jsonl inspect
(fn title [p ?yield-fn]
  "Return a human title for a transcript: first user text, falling back to
   first assistant text, then nil."
  (. (scan-summary p ?yield-fn) :title))

(fn short-title [s]
  (when s
    (let [one-line (string.gsub s "%s+" " ")]
      (if (> (length one-line) 80)
          (.. (string.sub one-line 1 77) "...")
          one-line))))

(fn session-record [p ?yield-fn]
  (let [rec (cached-record p ?yield-fn)]
    {:path p
     :id (or rec.id (id-from-path p))
     :cwd rec.cwd
     :timestamp (or rec.timestamp
                    (string.match (path.basename p) "^([^_]+)"))
     :title (short-title rec.title)
     :message-count (or rec.message-count 0)
     :version rec.version}))

;; @doc fen.extensions.session_jsonl.session.list-for-cwd
;; kind: function
;; signature: (list-for-cwd cwd limit) -> [SessionInfo]
;; summary: Return recent non-empty session metadata records for cwd in reverse chronological order, capped by limit.
;; tags: session jsonl discovery
(fn list-for-cwd [cwd limit ?yield-fn]
  "Return recent session metadata records for `cwd`, newest first. Durable
   header-only sessions created by the control CLI are included."
  (let [dir (sessions-root cwd)
        max-count (or limit 20)
        out []]
    (each [_ name (ipairs (session-files-newest dir ?yield-fn)) &until (>= (length out) max-count)]
      (let [rec (session-record (.. dir "/" name) ?yield-fn)]
        (when (and (= rec.cwd cwd)
                   (or (> (or (?. (cached-record rec.path ?yield-fn) :entry-count) 0) 0)
                       (= (or (?. (cached-record rec.path ?yield-fn) :raw-entry-count) 0) 0)))
          (table.insert out rec)))
      (maybe-yield ?yield-fn))
    out))

;; @doc fen.extensions.session_jsonl.session.get
;; kind: function
;; signature: (get cwd id) -> SessionInfo|nil
;; summary: Resolve only a complete session id in the requested cwd.
;; tags: session jsonl exact discovery
(fn get [cwd target ?yield-fn]
  (var found nil)
  (each [_ name (ipairs (session-files-newest (sessions-root cwd) ?yield-fn)) &until found]
    (let [rec (session-record (.. (sessions-root cwd) "/" name) ?yield-fn)]
      (when (and (= rec.cwd cwd) (= (tostring rec.id) (tostring target)))
        (set found rec)))
    (maybe-yield ?yield-fn))
  found)

;; @doc fen.extensions.session_jsonl.session.acquire-lock
;; kind: function
;; signature: (acquire-lock SessionInfo) -> release-fn|nil
;; summary: Atomically acquire a per-session mutation lock, returning nil when another process owns it.
;; tags: session jsonl concurrency
(fn acquire-lock [info]
  (let [lock-path (.. info.path ".lock")
        ok? (os.execute (.. "mkdir " (path.shell-quote lock-path) " 2>/dev/null"))]
    (when ok?
      (let [owner (io.open (.. lock-path "/owner") :w)]
        (when owner
          (owner:write (tostring (or (os.getenv :PPID) "unknown")))
          (owner:close)))
      (var released? false)
      (fn []
        (when (not released?)
          (set released? true)
          (os.remove (.. lock-path "/owner"))
          (os.execute (.. "rmdir " (path.shell-quote lock-path) " 2>/dev/null")))))))

;; @doc fen.extensions.session_jsonl.session.open-existing
;; kind: function
;; signature: (open-existing p) -> Session|nil
;; summary: Open an existing session JSONL for append without writing a duplicate header, preserving header id and cwd.
;; tags: session jsonl resume
(fn open-existing [p ?yield-fn]
  "Open an existing session JSONL for append without writing a duplicate
   header. Returns nil if the path is not a regular file."
  (if (not (path.file-exists? p))
      (do (log.warn (.. "session: cannot resume missing file " p)) nil)
      (let [rec (cached-record p ?yield-fn)]
        (open-file p rec.cwd rec.id ?yield-fn rec.last-entry-id))))

;; @doc fen.extensions.session_jsonl.session.find
;; kind: function
;; signature: (find cwd target) -> string|nil
;; summary: Resolve a resume target as latest, list index, existing path, exact id, or unique id/path prefix within cwd sessions.
;; tags: session jsonl resume
(fn find [cwd target ?yield-fn]
  "Resolve a session target for `cwd`. Target may be nil/latest, a 0-based
   reverse-chronological list index, an existing path, an exact id, or a
   unique id/path prefix among cwd sessions."
  (let [t (or target :latest)]
    (if (or (= t "") (= t :latest) (= t "latest"))
        (latest-for-cwd cwd ?yield-fn)
        (let [idx (tonumber t)
              sessions (list-for-cwd cwd 200 ?yield-fn)]
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
                    (table.insert matches rec.path))
                  (maybe-yield ?yield-fn))
                (if (= (length matches) 1)
                    (. matches 1)
                    nil)))))))

(fn compaction-summary-message [entry]
  {:role :user
   :content (.. "Compaction summary of earlier fen session context. Use this as context for the continuing conversation; do not ask me to restate it.\n\n"
                entry.summary)
   ;; Session entry timestamps are ISO strings, but canonical message
   ;; timestamps are numeric milliseconds.
   :timestamp (types.now-ms)
   :__compaction-entry-id entry.id})

(fn message-entries [entries]
  (let [out []]
    (each [_ entry (ipairs entries)]
      (when (and (= entry.type :message) entry.message)
        (tset entry.message :__session-entry-id entry.id)
        (table.insert out entry)))
    out))

;; @doc fen.extensions.session_jsonl.session.latest-extension-state
;; kind: function
;; signature: (latest-extension-state session extension ?yield-fn ?accept) -> entry|nil
;; summary: Return the latest accepted extension-owned state entry from cooperatively cached session metadata, warning and ignoring malformed entries.
;; tags: session jsonl extensions state replay
(fn latest-extension-state [session extension ?yield-fn ?accept]
  (let [p (or (?. session :path) session)
        rec (cached-record p ?yield-fn)
        entries (or (. (or rec.extension-state-entries {}) (tostring extension)) [])]
    (var found nil)
    (for [i (length entries) 1 -1 &until found]
      (let [entry (. entries i)]
        (if (not (valid-extension-state-entry? entry))
            (log.warn "session: ignoring malformed extension-state entry")
            (if (or (not ?accept) (?accept entry.state entry))
                (set found entry)
                (log.warn "session: ignoring rejected extension-state entry"))))
      (maybe-yield ?yield-fn))
    found))

(fn latest-valid-compaction [entries messages]
  (var found nil)
  (each [_ entry (ipairs entries)]
    (when (= entry.type :compaction)
      (if (or (not entry.summary) (not entry.first-kept-entry-id))
          (log.warn "session: ignoring malformed compaction entry")
          (do
            (var idx nil)
            (each [i m-entry (ipairs messages)]
              (when (= m-entry.id entry.first-kept-entry-id)
                (set idx i)))
            (if idx
                (set found {:entry entry :index idx})
                (log.warn "session: ignoring compaction with unresolved first-kept-entry-id"))))))
  found)

;; @doc fen.extensions.session_jsonl.session.transcript
;; kind: function
;; signature: (transcript path) -> [Message]
;; summary: Return persisted canonical messages without applying replay compaction.
;; tags: session jsonl inspect
(fn transcript [p ?yield-fn]
  (let [out []]
    (each [_ entry (ipairs (read-entries p ?yield-fn))]
      (when (and (= entry.type :message) (= (type entry.message) :table))
        (table.insert out (clone-message-for-storage entry.message)))
      (maybe-yield ?yield-fn))
    out))

;; @doc fen.extensions.session_jsonl.session.load
;; kind: function
;; signature: (load path) -> [Message]
;; summary: Read a session JSONL file and return replayable canonical messages, applying the latest valid compaction entry when present.
;; tags: session jsonl replay compaction
(fn load [path ?yield-fn]
  "Read the JSONL at `path` and return replayable canonical messages. Header
   and unknown entry types are skipped. If the session contains a valid latest
   :compaction entry, synthesize its summary message and replay only messages
   from :first-kept-entry-id onward."
  (let [entries (read-entries path ?yield-fn)
        msg-entries (message-entries entries)
        compact (latest-valid-compaction entries msg-entries)
        out []]
    (if compact
        (do
          (table.insert out (compaction-summary-message compact.entry))
          (for [i compact.index (length msg-entries)]
            (table.insert out (. msg-entries i :message))
            (maybe-yield ?yield-fn)))
        (each [_ entry (ipairs msg-entries)]
          (table.insert out entry.message)
          (maybe-yield ?yield-fn)))
    out))

;; @doc fen.extensions.session_jsonl.session.VERSION
;; kind: data
;; signature: number
;; summary: Current JSONL session format version written into new session headers.
;; tags: session jsonl metadata
{:open open
 :create create
 :open-existing open-existing
 :append append
 :append-entry append-entry
 :latest-extension-state latest-extension-state
 :close close
 :latest-for-cwd latest-for-cwd
 :list-for-cwd list-for-cwd
 :get get
 :acquire-lock acquire-lock
 :header header
 :title title
 :message-count message-count
 :find find
 :transcript transcript
 :load load
 :sessions-root sessions-root
 :cwd-slug cwd-slug
 :VERSION VERSION}
