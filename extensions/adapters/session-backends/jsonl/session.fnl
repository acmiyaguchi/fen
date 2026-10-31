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

;; Simple LRU bound so a long-lived TUI does not pin decoded metadata for
;; hundreds of transcripts (#426). Recency is a monotonic clock kept in the
;; persistent state module; the eviction policy itself lives here in reloadable
;; code so it can be tuned via /reload.
(fn cache-cap []
  (or cache-state.cache-cap 64))

(fn cache-touch! [rec]
  (set cache-state.cache-clock (+ (or cache-state.cache-clock 0) 1))
  (set rec.__tick cache-state.cache-clock))

(fn cache-size []
  (var size 0)
  (each [_ (pairs cache-state.record-cache)] (set size (+ size 1)))
  size)

(fn cache-evict-if-needed! []
  (var size (cache-size))
  (while (> size (cache-cap))
    (var victim nil)
    (var victim-tick nil)
    (each [k v (pairs cache-state.record-cache)]
      (let [tick (or v.__tick 0)]
        (when (or (not victim) (< tick victim-tick))
          (set victim k)
          (set victim-tick tick))))
    (if victim
        (do
          (tset cache-state.record-cache victim nil)
          (set size (- size 1)))
        (set size 0))))

(fn cache-get [p sig]
  (let [rec (. cache-state.record-cache p)]
    (when (and rec sig (= rec.size sig.size) (= rec.mtime sig.mtime))
      ;; Touch on read so recently used records survive eviction.
      (cache-touch! rec)
      rec)))

(fn cache-put! [p sig rec]
  (when (and p sig rec)
    (let [out {}]
      (each [k v (pairs rec)] (tset out k v))
      (set out.size sig.size)
      (set out.mtime sig.mtime)
      (cache-touch! out)
      (tset cache-state.record-cache p out)
      (cache-evict-if-needed!))))

(fn cache-invalidate! [p]
  (when p
    (tset cache-state.record-cache p nil)))

(fn session-file? [name]
  "Whether a directory entry is a discoverable session transcript."
  (and (string.match name "%.jsonl$")
       (not (string.match name "%.repaired%.jsonl$"))
       (not (string.match name "%.lock$"))))

(fn session-files-newest [dir ?yield-fn]
  "Return JSONL filenames in newest-first order, preferring lfs over shell ls."
  (let [l (lfs)]
    (if (and l l.dir l.attributes)
        (let [items []]
          (when (path.dir-exists? dir)
            (fn scan! []
              (each [name (l.dir dir)]
                (when (session-file? name)
                  (let [p (.. dir "/" name)
                        mtime (or (l.attributes p :modification) 0)]
                    (table.insert items {:name name :mtime mtime})
                    (maybe-yield ?yield-fn)))))

            (if ?yield-fn
                (scan!)
                (let [(ok? err) (xpcall scan! debug.traceback)]
                  (when (not ok?)
                    (log.warn (.. "session: cannot list " dir ": "
                                  (tostring err)))))))
          (table.sort items
                      (fn [a b]
                        (if (= a.mtime b.mtime)
                            (> a.name b.name)
                            (> a.mtime b.mtime))))
          (let [out []]
            (each [_ item (ipairs items)]
              (table.insert out item.name))
            out))
        (let [out []]
          (each [_ name (ipairs (command-output-lines (.. "ls -1t "
                                                          (path.shell-quote dir)
                                                          " 2>/dev/null")
                                                      ?yield-fn))]
            (when (session-file? name)
              (table.insert out name)))
          out))))

;; ----------------------------------------------------------------
;; Open / append / close
;; ----------------------------------------------------------------

(fn id-from-path [p]
  (or (string.match (path.basename p) "_([A-Za-z0-9%-]+)%.jsonl$")
      (string.match (path.basename p) "([^/%.]+)%.jsonl$")))

(fn read-entries [p ?yield-fn ?strict?]
  "Read JSONL entries. Strict machine-control reads reject malformed data."
  (let [(f open-err) (io.open p :r)
        entries []
        first-entry? {:value true}]
    (if (not f)
        (do
          (log.warn (.. "session: cannot read " p ": " (tostring open-err)))
          entries)
        (let [(ok? err) (xpcall (fn []
                                  (var scanned 0)
                                  (each [line (f:lines)]
                                    (when (not= line "")
                                      (let [(ok? entry) (pcall json.decode line)
                                            valid-table? (and ok?
                                                              (= (type entry)
                                                                 :table))
                                            valid-header? (or (not first-entry?.value)
                                                              (and valid-table?
                                                                   (= entry.type
                                                                      :session)))
                                            valid-message? (or (not valid-table?)
                                                               (not= entry.type
                                                                     :message)
                                                               (= (type entry.message)
                                                                  :table))]
                                        (if (and valid-table? valid-header?
                                                 valid-message?)
                                            (table.insert entries entry)
                                            ?strict?
                                            (error (.. "malformed session transcript: "
                                                       p))
                                            (log.warn (.. "session: skipping malformed line in "
                                                          p)))
                                        (set first-entry?.value false)))
                                    (set scanned (+ scanned 1))
                                    (when (and ?yield-fn
                                               (>= scanned LINES-BEFORE-YIELD))
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

;; ----------------------------------------------------------------
;; Writer lock (#642, #644)
;; ----------------------------------------------------------------
;;
;; One writer per transcript: every writable handle (`open-existing`, and a new
;; session on its first write) holds the session's writer lock until `close`.
;; The lock is a kernel record lock (`lfs.lock`: fcntl on POSIX, _locking on
;; Windows) on a sibling `<transcript>.writer.lock` file, so the kernel drops it
;; when the process dies and there is no stale lock to reclaim. The lock file is
;; never removed: a record lock belongs to the inode, and deleting the file
;; while it is held would let a second writer lock a fresh inode.
;;
;; fcntl locks are per process and are dropped when the process closes *any*
;; descriptor of the locked file, so the lock file is opened once per process
;; and only by this code, and same-process exclusion comes from the held-lock
;; table in the non-reloadable state module (which also keeps the handle alive
;; across /reload).

(fn writer-lock-path [p]
  (.. p ".writer.lock"))

(fn held-locks []
  (when (not cache-state.locks)
    (set cache-state.locks {}))
  cache-state.locks)

(var warned-no-kernel-lock? false)

(fn hold-lock [locks lock-path f l]
  (tset locks lock-path f)
  (var released? false)
  (fn []
    (when (not released?)
      (set released? true)
      (when (= (. locks lock-path) f)
        (tset locks lock-path nil))
      (when (and l l.unlock)
        (pcall l.unlock f 0 1))
      (pcall #(f:close)))))

;; @doc fen.extensions.session_jsonl.session.acquire-lock
;; kind: function
;; signature: (acquire-lock SessionInfo) -> release-fn|nil
;; summary: Take the session's writer lock (a kernel record lock released when the process dies), returning nil when another holder in this or another process has it.
;; tags: session jsonl concurrency
(fn acquire-lock [info]
  (let [lock-path (writer-lock-path info.path)
        locks (held-locks)]
    (if (. locks lock-path)
        nil
        (let [l (lfs)
              (f open-err) (io.open lock-path :a)]
          (if (not f)
              (do
                (log.warn (.. "session: cannot open lock " lock-path ": "
                              (tostring open-err)))
                nil)
              (not (and l l.lock))
              (do
                ;; Without lfs only writers in this process are excluded.
                (when (not warned-no-kernel-lock?)
                  (set warned-no-kernel-lock? true)
                  (log.warn "session: lfs.lock unavailable; the session lock excludes only this process"))
                (hold-lock locks lock-path f nil))
              (let [(ok? locked?) (pcall l.lock f :w 0 1)]
                (if (and ok? locked?)
                    (hold-lock locks lock-path f l)
                    (do
                      ;; Closing is safe: this process holds no lock on the file.
                      (f:close)
                      nil))))))))

(fn terminate-torn-tail! [p]
  "If the transcript's last byte is not a newline, a writer died partway
   through a line (#640). Terminate that partial line so the next entry starts
   on a line of its own; the partial line stays malformed and is skipped by
   replay. Call only while holding the writer lock. Returns false when the
   newline could not be written."
  (let [f (io.open p :rb)]
    (if (not f)
        true
        (let [size (f:seek :end)
              last-byte (when (and size (> size 0))
                          (f:seek :set (- size 1))
                          (f:read 1))]
          (f:close)
          (if (or (not last-byte) (= last-byte "\n"))
              true
              (let [(w open-err) (io.open p :ab)]
                (if (not w)
                    (do
                      (log.warn (.. "session: cannot terminate torn line in " p
                                    ": " (tostring open-err)))
                      false)
                    (let [(wrote? write-err) (w:write "\n")
                          (closed? close-err) (w:close)]
                      (cache-invalidate! p)
                      (if (and wrote? closed?)
                          (do
                            (log.warn (.. "session: terminated a torn last line in "
                                          p))
                            true)
                          (do
                            (log.warn (.. "session: cannot terminate torn line in "
                                          p ": "
                                          (tostring (or write-err close-err))))
                            false))))))))))

(fn open-file [p cwd id ?yield-fn ?last-entry-id]
  (let [(f open-err) (io.open p :a)]
    (if (not f)
        (do
          (log.warn (.. "session: cannot open " p ": " (tostring open-err)))
          nil)
        (do
          (f:setvbuf :line)
          {:id (or id (id-from-path p))
           :path p
           :cwd cwd
           :file f
           :last-entry-id (if (not= ?last-entry-id nil)
                              ?last-entry-id
                              (last-entry-id p ?yield-fn))
           :header-written? true}))))

(fn open [cwd ?opts]
  "Pick a future session path under sessions-root(cwd), but do not create the
   file yet. The header is written lazily on the first appended message, which
   mirrors pi-mono and avoids header-only 0-message sessions when the user
   opens/quits the TUI without completing a turn."
  (let [dir (sessions-root cwd)
        ts (or (?. ?opts :timestamp) (iso-timestamp))
        id (or (?. ?opts :id) (random-id))
        p (.. dir "/" ts "_" id ".jsonl")]
    {:id id
     :path p
     :cwd cwd
     :file nil
     :last-entry-id nil
     :header {:type :session :version VERSION : id :timestamp ts : cwd}
     :header-written? false}))

(fn release-handle-lock! [session]
  (let [release session.release-lock]
    (set session.release-lock nil)
    (when release (release))))

(fn ensure-open! [session]
  "Open the handle for append on its first write (or after a failed write),
   taking the writer lock first and terminating a torn last line (#640)."
  (if session.file
      true
      (do
        (ensure-dir (path.dirname session.path))
        (when (not session.release-lock)
          (set session.release-lock (acquire-lock session)))
        (if (not session.release-lock)
            (do
              (log.warn (.. "session: " session.path
                            " is in use by another writer"))
              false)
            (not (terminate-torn-tail! session.path))
            false
            (let [(f open-err) (io.open session.path :a)]
              (if (not f)
                  (do
                    (log.warn (.. "session: cannot open " session.path ": "
                                  (tostring open-err)))
                    false)
                  (do
                    (f:setvbuf :line)
                    (set session.file f)
                    (if session.header-written?
                        true
                        (let [(wrote? write-err) (f:write (.. (json.encode session.header)
                                                              "\n"))]
                          (if wrote?
                              (do
                                (set session.header-written? true)
                                true)
                              (do
                                (log.warn (.. "session: cannot write header: "
                                              (tostring write-err)))
                                (f:close)
                                (set session.file nil)
                                false)))))))))))

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
      ;; file:write and file:flush report I/O errors (ENOSPC, EIO) as
      ;; nil, message rather than raising; json.encode may raise.
      (let [(ok? wrote? err) (pcall #(let [(w werr) (session.file:write (.. (json.encode out)
                                                                            "\n"))]
                                       (if w
                                           (session.file:flush)
                                           (values w werr))))]
        (cache-invalidate! session.path)
        (if (and ok? wrote?)
            (do
              (set session.last-entry-id out.id)
              out)
            (do
              (log.warn (.. "session: append failed: "
                            (tostring (if ok? err wrote?))))
              ;; A failed write may have left a partial line. Drop the handle
              ;; (keeping the lock) so the next append reopens it and
              ;; terminates that line first (#640, #641).
              (when (and ok? session.file)
                (pcall #(session.file:close))
                (set session.file nil))
              nil))))))

(fn clone-message-for-storage [msg]
  "Copy a message while dropping in-memory session metadata fields."
  (let [out {}]
    (each [k v (pairs msg)]
      (when (not= (string.sub (tostring k) 1 2) "__")
        (tset out k v)))
    out))

(fn append [session msg]
  "Append one canonical AgentMessage as a :message entry."
  (let [entry (append-entry session
                            {:type :message
                             :message (clone-message-for-storage msg)})]
    (when (and entry msg)
      (tset msg :__session-entry-id entry.id))
    entry))

;; @doc fen.extensions.session_jsonl.session.close
;; kind: function
;; signature: (close session) -> nil
;; summary: Close an open session file handle, release its writer lock, and clear both from the mutable session record.
;; tags: session jsonl close
(fn close [session]
  (when session
    (when session.file
      (session.file:close)
      (set session.file nil))
    (release-handle-lock! session)))

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
  (and (= entry.type :extension-state) entry.extension
       (= (type entry.version) :number)
       (= entry.version (math.floor entry.version)) (>= entry.version 1)
       (= (type entry.state) :table)))

(fn replayable-entry? [entry]
  (or (and (= entry.type :message) (= (type entry.message) :table))
      (valid-extension-state-entry? entry)))

(fn empty-metadata-record [p]
  {:path p :id (id-from-path p) :message-count 0})

(local ENOENT 2)

(fn scan-metadata [p ?yield-fn]
  "Scan one JSONL file once and return lightweight metadata for list/find/open."
  (let [(f open-err open-code) (io.open p :r)]
    (if (not f)
        ;; ENOENT is the normal state of a lazily created session that has no assistant turn yet.
        (if (= open-code ENOENT)
            (values (empty-metadata-record p) true)
            (do
              (log.warn (.. "session: cannot read metadata " p ": "
                            (tostring open-err)))
              (values (empty-metadata-record p) false)))
        (let [rec {:path p
                   :id (id-from-path p)
                   :timestamp (string.match (path.basename p) "^([^_]+)")
                   :message-count 0
                   :raw-entry-count 0
                   :extension-state-entries {}}
              (ok? err) (xpcall (fn []
                                  (let [header-line (f:read :*l)]
                                    (when (and header-line
                                               (not= header-line ""))
                                      (let [(ok? h) (pcall json.decode
                                                           header-line)]
                                        (when (and ok? (= (type h) :table)
                                                   (= h.type :session))
                                          (set rec.id (or h.id rec.id))
                                          (set rec.cwd h.cwd)
                                          (set rec.timestamp
                                               (or h.timestamp rec.timestamp))
                                          (set rec.version h.version)))))
                                  (var fallback nil)
                                  (var found nil)
                                  (var scanned 0)
                                  (each [line (f:lines)]
                                    (when (not= line "")
                                      (let [(ok? entry) (pcall json.decode line)]
                                        (when (and ok? (= (type entry) :table))
                                          (set rec.raw-entry-count
                                               (+ rec.raw-entry-count 1))
                                          (when (replayable-entry? entry)
                                            (set rec.entry-count
                                                 (+ (or rec.entry-count 0) 1)))
                                          ;; Retain only the latest valid entry per owner so a
                                          ;; long-lived cache never pins whole :state payloads
                                          ;; for hundreds of transcripts (#426). A caller's
                                          ;; ?accept predicate is not in scope here, so this
                                          ;; keeps the newest structurally valid entry;
                                          ;; latest-extension-state streams older entries from
                                          ;; disk when ?accept rejects the cached one.
                                          (when (and (= entry.type
                                                        :extension-state)
                                                     entry.extension
                                                     (valid-extension-state-entry? entry))
                                            (tset rec.extension-state-entries
                                                  (tostring entry.extension)
                                                  entry))
                                          (when entry.id
                                            (set rec.last-entry-id entry.id))
                                          (let [msg (and (= entry.type :message)
                                                         (= (type entry.message)
                                                            :table)
                                                         entry.message)]
                                            (when msg
                                              (set rec.message-count
                                                   (+ rec.message-count 1))
                                              (when (not found)
                                                (let [text (first-text msg)]
                                                  (when text
                                                    (if (= msg.role :user)
                                                        (set found text)
                                                        (when (not fallback)
                                                          (set fallback text)))))))))))
                                    (set scanned (+ scanned 1))
                                    (when (and ?yield-fn
                                               (>= scanned LINES-BEFORE-YIELD))
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
        (let [(rec missing?) (scan-metadata p ?yield-fn)]
          ;; A lazy session path may appear after this read, so never cache its
          ;; empty record even if a concurrent filesystem change supplied SIG.
          (when (not missing?) (cache-put! p sig rec))
          rec))))

;; @doc fen.extensions.session_jsonl.session.message-count
;; kind: function
;; signature: (message-count p) -> number
;; summary: Count valid :message entries in a session JSONL file while skipping the header and malformed lines.
;; tags: session jsonl inspect
(fn message-count [p ?yield-fn]
  (or (?. (cached-record p ?yield-fn) :message-count) 0))

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

(fn header [p ?yield-fn]
  "Read and decode the first JSONL header entry from `p`, or nil."
  (maybe-yield ?yield-fn)
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        (do
          (log.warn (.. "session: cannot read header " p ": "
                        (tostring open-err)))
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
     :timestamp (or rec.timestamp (string.match (path.basename p) "^([^_]+)"))
     :title (short-title rec.title)
     :message-count (or rec.message-count 0)
     :version rec.version}))

(fn list-for-cwd [cwd limit ?yield-fn]
  "Return recent session metadata records for `cwd`, newest first. Durable
   header-only sessions created by the control CLI are included."
  (let [dir (sessions-root cwd)
        max-count (or limit 20)
        out []]
    (each [_ name (ipairs (session-files-newest dir ?yield-fn))
           &until (>= (length out) max-count)]
      (let [rec (session-record (.. dir "/" name) ?yield-fn)]
        (when (and (= rec.cwd cwd)
                   (or (> (or (?. (cached-record rec.path ?yield-fn)
                                  :entry-count) 0) 0)
                       (= (or (?. (cached-record rec.path ?yield-fn)
                                  :raw-entry-count)
                              0) 0)))
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
  (var ambiguous? false)
  (each [_ name (ipairs (session-files-newest (sessions-root cwd) ?yield-fn))]
    (let [rec (session-record (.. (sessions-root cwd) "/" name) ?yield-fn)]
      (when (and (= rec.cwd cwd) (= (tostring rec.id) (tostring target)))
        (if found
            (set ambiguous? true)
            (set found rec))))
    (maybe-yield ?yield-fn))
  (if ambiguous? (values nil :ambiguous) found))

(fn open-existing [p ?yield-fn]
  "Open an existing session JSONL for append without writing a duplicate
   header. The handle holds the session's writer lock until `close`; returns
   nil, :busy when another writer holds it, and nil if the path is not a
   regular file. A torn last line left by a killed writer is terminated
   before the first append (#640)."
  (if (not (path.file-exists? p))
      (do
        (log.warn (.. "session: cannot resume missing file " p))
        nil)
      (let [release (acquire-lock {:path p})]
        (if (not release)
            (values nil :busy)
            ;; Read the tail and metadata only under the lock, and release it
            ;; if opening fails or a cooperative cancel unwinds a yield.
            (let [(ok? handle) (pcall (fn []
                                        (when (terminate-torn-tail! p)
                                          (let [rec (cached-record p ?yield-fn)]
                                            (open-file p rec.cwd rec.id
                                                       ?yield-fn
                                                       rec.last-entry-id)))))]
              (if (and ok? handle)
                  (do
                    (set handle.release-lock release)
                    handle)
                  (do
                    (release)
                    (when (not ok?) (error handle 0))
                    nil)))))))

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
                  (when (or (= rec.id t) (= rec.path t)
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
;; summary: Return the latest accepted extension-owned state entry from cooperatively cached session metadata, falling back to a disk scan for an older accepted entry when the cached latest one is rejected by ?accept, warning and ignoring malformed entries.
;; tags: session jsonl extensions state replay
(fn accepted-extension-state-from-disk [p extension ?yield-fn ?accept]
  "Stream a session from disk and return the newest ?accept-accepted valid
  extension-state entry for `extension`. Used only as a fallback when the
  cached latest entry is rejected, so the whole-file scan stays off the
  common path while preserving accept-fallback semantics (#426)."
  (let [owner (tostring extension)]
    (var found nil)
    (each [_ entry (ipairs (read-entries p ?yield-fn))]
      (when (and (= entry.type :extension-state) entry.extension
                 (= (tostring entry.extension) owner)
                 (valid-extension-state-entry? entry)
                 (or (not ?accept) (?accept entry.state entry)))
        (set found entry))
      (maybe-yield ?yield-fn))
    found))

(fn latest-extension-state [session extension ?yield-fn ?accept]
  (let [p (or (?. session :path) session)
        rec (cached-record p ?yield-fn)
        entry (. (or rec.extension-state-entries {}) (tostring extension))]
    (maybe-yield ?yield-fn)
    (if (not entry)
        nil
        (not (valid-extension-state-entry? entry))
        (do
          (log.warn "session: ignoring malformed extension-state entry")
          nil)
        (or (not ?accept) (?accept entry.state entry))
        entry
        ;; The cache holds only the newest valid entry per owner (#426), so a
        ;; rejected cached entry falls back to a disk scan for the newest
        ;; older accepted entry rather than giving up.
        (accepted-extension-state-from-disk p extension ?yield-fn ?accept))))

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

;; ----------------------------------------------------------------
;; Replay repair (#639, #643): one tool-pairing rule for every reader
;; ----------------------------------------------------------------

(local INTERRUPTED-RESULT-TEXT
       "[interrupted] this tool call did not finish before the session was saved; no result was recorded")

(fn context-assistant? [m]
  "Mirror of the agent's context filter: error turns and empty :aborted
   markers never reach a provider, so their tool calls are never pending."
  (and (= m.role :assistant) (not= m.stop-reason :error)
       (not (and (= m.stop-reason :aborted) (= 0 (length (or m.content [])))))))

(fn assistant-calls [m]
  (let [out []]
    (when (context-assistant? m)
      (each [_ block (ipairs (or m.content []))]
        (when (and (= (?. block :type) :tool-call) block.id)
          (table.insert out block))))
    out))

(fn interrupted-result [call]
  (types.tool-result-message {:tool-call-id call.id
                              :tool-name call.name
                              :content [(types.text-block INTERRUPTED-RESULT-TEXT)]
                              :is-error? true
                              :details {:synthetic? true :interrupted? true}}))

;; @doc fen.extensions.session_jsonl.session.replay-plan
;; kind: function
;; signature: (replay-plan messages) -> steps, repairs
;; summary: The replay pairing rule: keep messages in order, answer every tool call whose result does not follow it with a synthetic interrupted result, and drop results that answer no open call.
;; tags: session jsonl replay tool-pairing
(fn replay-plan [messages]
  "Steps are {:src i} (keep messages[i]) or {:call block :at i} (a synthetic
   result for a call carried by messages[i]). A result answers an open call of
   the assistant it follows, matched by id in any order; anything else (a user
   message, another assistant, the end of the log) closes the calls still
   open. Repairs list what the plan changes, as {:kind :missing-result :index
   i :call-id id} and {:kind :orphan-result :index i :call-id id}.
   This is the close-turn rule (#668) applied to a log that may have been cut
   or interleaved anywhere; `load`, `transcript`, and `doctor` all use it, so
   every provider sees valid pairing and the doctor reports exactly what
   replay changes."
  (let [steps []
        repairs []]
    (var pending [])

    (fn close-pending! []
      (each [_ p (ipairs pending)]
        (when (not p.answered?)
          (table.insert steps {:call p.call :at p.index})
          (table.insert repairs
                        {:kind :missing-result
                         :index p.index
                         :call-id (tostring p.call.id)})))
      (set pending []))

    (each [i m (ipairs (or messages []))]
      (if (= m.role :tool-result)
          (let [call-id (tostring (or m.tool-call-id ""))]
            (var hit nil)
            (each [_ p (ipairs pending) &until hit]
              (when (and (not p.answered?) (= (tostring p.call.id) call-id))
                (set hit p)))
            (if hit
                (do
                  (set hit.answered? true)
                  (table.insert steps {:src i}))
                (table.insert repairs {:kind :orphan-result :index i : call-id})))
          (do
            (close-pending!)
            (table.insert steps {:src i})
            (each [_ call (ipairs (assistant-calls m))]
              (table.insert pending {: call :index i})))))
    (close-pending!)
    (values steps repairs)))

;; @doc fen.extensions.session_jsonl.session.replay-messages
;; kind: function
;; signature: (replay-messages messages) -> [Message], repair-count
;; summary: Apply the replay pairing rule to a message list, so the history any provider receives has every tool call answered right after it.
;; tags: session jsonl replay tool-pairing
(fn replay-messages [messages]
  (let [(steps repairs) (replay-plan messages)
        out []]
    (each [_ step (ipairs steps)]
      (table.insert out
                    (if step.src
                        (. messages step.src)
                        (interrupted-result step.call))))
    (values out (length repairs))))

;; @doc fen.extensions.session_jsonl.session.transcript
;; kind: function
;; signature: (transcript path) -> [Message]
;; summary: Return persisted canonical messages, with replay's tool-pairing repair but without replay compaction.
;; tags: session jsonl inspect
(fn transcript [p ?yield-fn ?strict?]
  (let [out []]
    (each [_ entry (ipairs (read-entries p ?yield-fn ?strict?))]
      (when (and (= entry.type :message) (= (type entry.message) :table))
        (table.insert out (clone-message-for-storage entry.message)))
      (maybe-yield ?yield-fn))
    (pick-values 1 (replay-messages out))))

(fn load [path ?yield-fn ?strict?]
  "Read the JSONL at `path` and return replayable canonical messages. Header
   and unknown entry types are skipped. If the session contains a valid latest
   :compaction entry, synthesize its summary message and replay only messages
   from :first-kept-entry-id onward. Tool pairing is repaired by
   `replay-messages`: a call left open by a crash or another writer gets a
   synthetic interrupted result, and a result answering nothing is dropped.
   Synthetic results are in-memory only; they carry no entry id."
  (let [entries (read-entries path ?yield-fn ?strict?)
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
    (pick-values 1 (replay-messages out))))

;; ----------------------------------------------------------------
;; Doctor / non-destructive repair
;; ----------------------------------------------------------------

(local MAX-TOOL-RESULT-BYTES 100000)

(fn doctor-issue [issues line code message]
  (table.insert issues {:line line :code code :message message}))

(fn tool-call-ids [message]
  (let [out []]
    (each [_ block (ipairs (or message.content []))]
      (when (and (= block.type :tool-call) block.id)
        (table.insert out (tostring block.id))))
    out))

(fn tool-result-text-bytes [message]
  (var bytes 0)
  (each [_ block (ipairs (or message.content []))]
    (when (= block.type :text)
      (set bytes (+ bytes (length (tostring (or block.text "")))))))
  bytes)

(fn sanitize-tool-result! [message]
  (set message.content
       [{:type :text :text "[session doctor: unsafe tool output removed]"}])
  (set message.is-error? true))

(fn message-entry? [entry]
  (and (= entry.type :message) (= (type entry.message) :table)))

(fn doctor-check-entry! [issues entries entry line-number seen-calls]
  "Line-level checks for one decoded entry; appends it to `entries`."
  (when (and (= line-number 1) (not= entry.type :session))
    (doctor-issue issues line-number :orphaned_header
                  "first entry is not a session header"))
  (when (and (> line-number 1) (= entry.type :session))
    (doctor-issue issues line-number :orphaned_header
                  "unexpected session header after line one"))
  (when (message-entry? entry)
    (let [message entry.message]
      (when (and (= message.role :assistant) (= message.stop-reason :error))
        (doctor-issue issues line-number :assistant_error
                      "assistant error turn is unsafe to replay")
        ;; Error turns never reach a provider; one without tool calls is
        ;; dropped. A carrier is kept for the record (its calls are not open
        ;; on replay, so results after it are orphans either way).
        (when (= (length (tool-call-ids message)) 0)
          (set entry.__doctor-drop true)))
      (each [_ call-id (ipairs (tool-call-ids message))]
        (if (. seen-calls call-id)
            (doctor-issue issues line-number :duplicate_tool_call
                          "duplicate tool call id")
            (tset seen-calls call-id true)))
      (when (and (= message.role :tool-result)
                 (> (tool-result-text-bytes message) MAX-TOOL-RESULT-BYTES))
        (doctor-issue issues line-number :oversized_tool_result
                      "tool result exceeds the safe replay limit")
        (sanitize-tool-result! message))))
  (set entry.__doctor-line line-number)
  (table.insert entries entry))

(fn doctor-read [f issues ?yield-fn]
  "Stream the transcript line by line, yielding periodically. Returns the
   decoded entries and the header entry, if any. Closes `f`."
  (let [entries []
        seen-calls {}]
    (var line-number 0)
    (var header nil)
    (var scanned 0)
    (let [(read-ok? read-err) (xpcall (fn []
                                        (each [line (f:lines)]
                                          (set line-number (+ line-number 1))
                                          (when (not= line "")
                                            (let [(ok? entry) (pcall json.decode
                                                                     line)]
                                              (if (or (not ok?)
                                                      (not= (type entry) :table))
                                                  (doctor-issue issues
                                                                line-number
                                                                :malformed_json
                                                                "line is not a JSON object")
                                                  (do
                                                    (when (and (= line-number 1)
                                                               (= entry.type
                                                                  :session))
                                                      (set header entry))
                                                    (doctor-check-entry! issues
                                                                         entries
                                                                         entry
                                                                         line-number
                                                                         seen-calls)))))
                                          (set scanned (+ scanned 1))
                                          (when (and ?yield-fn
                                                     (>= scanned
                                                         LINES-BEFORE-YIELD))
                                            (set scanned 0)
                                            (?yield-fn))))
                                      debug.traceback)]
      (f:close)
      (when (not read-ok?) (error read-err)))
    (values entries header)))

(fn doctor-pairing! [issues entries]
  "Report exactly what replay changes (#643): a call whose result does not
   follow it is missing a result, and a result that answers no open call is an
   orphan. Returns the replay plan as per-message actions for the repair."
  (let [msg-entries []]
    (each [_ entry (ipairs entries)]
      (when (message-entry? entry)
        (table.insert msg-entries entry)
        (set entry.__doctor-msg-index (length msg-entries))))
    (let [messages (icollect [_ entry (ipairs msg-entries)] entry.message)
          (steps repairs) (replay-plan messages)
          kept {}
          before {}]
      (each [_ r (ipairs repairs)]
        (let [line (. msg-entries r.index :__doctor-line)]
          (if (= r.kind :missing-result)
              (doctor-issue issues line :missing_tool_result
                            (.. "tool call " r.call-id
                                " has no result right after it"))
              (doctor-issue issues line :orphan_tool_result
                            "tool result does not answer a tool call right before it"))))
      (var buffer [])
      (each [_ step (ipairs steps)]
        (if step.src
            (do
              (tset kept step.src true)
              (tset before step.src buffer)
              (set buffer []))
            (table.insert buffer step.call)))
      {: kept : before :tail buffer})))

(fn synthetic-entry [call]
  {:type :message
   :id (id.uuidv7)
   :timestamp (iso-timestamp)
   :message (interrupted-result call)})

(fn clean-entry [entry]
  (let [out {}]
    (each [k v (pairs entry)]
      (when (not= (string.sub (tostring k) 1 9) :__doctor-)
        (tset out k v)))
    out))

(fn write-repair! [p report issues entries plan]
  "Write the replayed transcript to a sibling file plus a JSON audit record;
   the original is never changed. The output is what replay would build from
   the original, so replaying it changes nothing."
  (let [output (.. p ".repaired.jsonl")
        temp (.. output ".tmp")
        audit (.. output ".doctor.json")
        (ok? err) (xpcall (fn []
                            (let [out (assert (io.open temp :w))
                                  write-entry! (fn [entry line]
                                                 (let [(encoded? encoded) (pcall json.encode
                                                                                 (clean-entry entry))]
                                                   (if encoded?
                                                       (assert (out:write (.. encoded
                                                                              "\n")))
                                                       (doctor-issue issues
                                                                     line
                                                                     :repair_encode_error
                                                                     "entry could not be encoded for repair"))))
                                  (written? write-err) (xpcall (fn []
                                                                 (each [_ entry (ipairs entries)]
                                                                   (let [k entry.__doctor-msg-index
                                                                         line (or entry.__doctor-line
                                                                                  0)]
                                                                     (when k
                                                                       (each [_ call (ipairs (or (. plan.before
                                                                                                    k)
                                                                                                 []))]
                                                                         (write-entry! (synthetic-entry call)
                                                                                       line)))
                                                                     (when (and (not entry.__doctor-drop)
                                                                                (or (not k)
                                                                                    (. plan.kept
                                                                                       k)))
                                                                       (write-entry! entry
                                                                                     line))))
                                                                 (each [_ call (ipairs plan.tail)]
                                                                   (write-entry! (synthetic-entry call)
                                                                                 0)))
                                                               debug.traceback)]
                              (out:close)
                              (when (not written?)
                                (error write-err))))
                          debug.traceback)]
    (if ok?
        (do
          ;; Only replace the sibling after a complete temp write.
          (case (io.open output :r)
            f (do
                (f:close)
                (os.rename output (.. output ".bak"))))
          (let [(renamed? rename-err) (os.rename temp output)]
            (if renamed?
                (do
                  (set report.issue-count (length issues))
                  (let [audit-file (assert (io.open audit :w))]
                    (audit-file:write (.. (json.encode report) "\n"))
                    (audit-file:close))
                  (set report.output-path output)
                  (set report.audit-path audit))
                (do
                  (os.remove temp)
                  (doctor-issue issues 0 :repair_write_error
                                (.. "cannot finalize repaired session: "
                                    (tostring rename-err)))))))
        (do
          (os.remove temp)
          (doctor-issue issues 0 :repair_write_error
                        (.. "cannot write repaired session: " (tostring err)))))))

(fn doctor [p ?repair? ?yield-fn]
  "Inspect a JSONL transcript without replaying it. Tool pairing is checked
   with replay's own rule (`replay-plan`), so the doctor reports and repairs
   exactly what replay would change. With repair enabled, write a sibling
   repaired copy and JSON audit record; the original is never changed.
   Streams the transcript line by line and calls ?yield-fn periodically so a
   caller with a cooperative scheduler is not frozen on multi-MB sessions."
  (let [(f open-err) (io.open p :r)]
    (if (not f)
        {:ok false :error (.. "cannot read session: " (tostring open-err))}
        (let [issues []
              (entries header) (doctor-read f issues ?yield-fn)]
          (when (not header)
            (doctor-issue issues 1 :orphaned_header "missing session header"))
          (let [plan (doctor-pairing! issues entries)
                report {:ok true
                        :path p
                        : issues
                        :issue-count (length issues)
                        :repair? (not (not ?repair?))}]
            (when ?repair?
              (write-repair! p report issues entries plan))
            (set report.issue-count (length issues))
            report)))))

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
 :doctor doctor
 :transcript transcript
 :transcript-strict (fn [p ?yield-fn] (transcript p ?yield-fn true))
 :load load
 :replay-messages replay-messages
 :replay-plan replay-plan
 :load-strict (fn [p ?yield-fn] (load p ?yield-fn true))
 :sessions-root sessions-root
 :cwd-slug cwd-slug
 :VERSION VERSION}
