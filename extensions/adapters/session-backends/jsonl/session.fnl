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

(local VERSION 2)

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

;; ----------------------------------------------------------------
;; Open / append / close
;; ----------------------------------------------------------------

(fn id-from-path [p]
  (or (string.match (path.basename p) "_([A-Za-z0-9%-]+)%.jsonl$")
      (string.match (path.basename p) "([^/%.]+)%.jsonl$")))

(fn read-entries [p]
  "Read JSONL entries, skipping malformed lines with a warning."
  (let [(f open-err) (io.open p :r)
        entries []]
    (if (not f)
        (do (log.warn (.. "session: cannot read " p ": " (tostring open-err)))
            entries)
        (do
          (each [line (f:lines)]
            (when (not= line "")
              (let [(ok? entry) (pcall json.decode line)]
                (if ok?
                    (table.insert entries entry)
                    (log.warn (.. "session: skipping malformed line in " p))))))
          (f:close)
          entries))))

(fn last-entry-id [p]
  "Return the last persisted entry id in a JSONL session, if present."
  (var last nil)
  (each [_ entry (ipairs (read-entries p))]
    (when entry.id
      (set last entry.id)))
  last)

(fn open-file [p cwd id]
  (let [(f open-err) (io.open p :a)]
    (if (not f)
        (do (log.warn (.. "session: cannot open " p ": " (tostring open-err)))
            nil)
        (do
          (f:setvbuf :line)
          {:id (or id (id-from-path p)) :path p :cwd cwd :file f
           :last-entry-id (last-entry-id p)
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

;; @doc fen.extensions.session_jsonl.session.message-count
;; kind: function
;; signature: (message-count p) -> number
;; summary: Count valid :message entries in a session JSONL file while skipping the header and malformed lines.
;; tags: session jsonl inspect
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

;; @doc fen.extensions.session_jsonl.session.latest-for-cwd
;; kind: function
;; signature: (latest-for-cwd cwd) -> string|nil
;; summary: Return the newest non-empty session JSONL path for cwd by scanning the cwd session directory newest first.
;; tags: session jsonl discovery
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

;; @doc fen.extensions.session_jsonl.session.header
;; kind: function
;; signature: (header p) -> table|nil
;; summary: Read and decode the first JSONL header entry from a session file, returning nil for unreadable or non-session headers.
;; tags: session jsonl inspect
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

;; @doc fen.extensions.session_jsonl.session.title
;; kind: function
;; signature: (title p) -> string|nil
;; summary: Return a human-readable transcript title from the first user text, falling back to the first assistant text.
;; tags: session jsonl inspect
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

;; @doc fen.extensions.session_jsonl.session.list-for-cwd
;; kind: function
;; signature: (list-for-cwd cwd limit) -> [SessionInfo]
;; summary: Return recent non-empty session metadata records for cwd in reverse chronological order, capped by limit.
;; tags: session jsonl discovery
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

;; @doc fen.extensions.session_jsonl.session.open-existing
;; kind: function
;; signature: (open-existing p) -> Session|nil
;; summary: Open an existing session JSONL for append without writing a duplicate header, preserving header id and cwd.
;; tags: session jsonl resume
(fn open-existing [p]
  "Open an existing session JSONL for append without writing a duplicate
   header. Returns nil if the path is not a regular file."
  (if (not (path.file-exists? p))
      (do (log.warn (.. "session: cannot resume missing file " p)) nil)
      (let [h (header p)]
        (open-file p (?. h :cwd) (?. h :id)))))

;; @doc fen.extensions.session_jsonl.session.find
;; kind: function
;; signature: (find cwd target) -> string|nil
;; summary: Resolve a resume target as latest, list index, existing path, exact id, or unique id/path prefix within cwd sessions.
;; tags: session jsonl resume
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

;; @doc fen.extensions.session_jsonl.session.load
;; kind: function
;; signature: (load path) -> [Message]
;; summary: Read a session JSONL file and return replayable canonical messages, applying the latest valid compaction entry when present.
;; tags: session jsonl replay compaction
(fn load [path]
  "Read the JSONL at `path` and return replayable canonical messages. Header
   and unknown entry types are skipped. If the session contains a valid latest
   :compaction entry, synthesize its summary message and replay only messages
   from :first-kept-entry-id onward."
  (let [entries (read-entries path)
        msg-entries (message-entries entries)
        compact (latest-valid-compaction entries msg-entries)
        out []]
    (if compact
        (do
          (table.insert out (compaction-summary-message compact.entry))
          (for [i compact.index (length msg-entries)]
            (table.insert out (. msg-entries i :message))))
        (each [_ entry (ipairs msg-entries)]
          (table.insert out entry.message)))
    out))

;; @doc fen.extensions.session_jsonl.session.VERSION
;; kind: data
;; signature: number
;; summary: Current JSONL session format version written into new session headers.
;; tags: session jsonl metadata
{:open open
 :open-existing open-existing
 :append append
 :append-entry append-entry
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
