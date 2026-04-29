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

(local json (require :util.json))
(local log (require :util.log))
(local path (require :util.path))

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

(fn open [cwd]
  "Pick a session path under sessions-root(cwd), mkdir -p, open the file in
   append mode, write the header, return a session record."
  (let [dir (sessions-root cwd)
        _ (ensure-dir dir)
        ts (iso-timestamp)
        id (random-id)
        path (.. dir "/" ts "_" id ".jsonl")
        (f open-err) (io.open path :a)]
    (if (not f)
        (do (log.warn (.. "session: cannot open " path ": " (tostring open-err)))
            nil)
        (do
          (f:setvbuf :line)
          (let [header {:type :session :version VERSION : id :timestamp ts : cwd}]
            (f:write (.. (json.encode header) "\n")))
          {: id : path : cwd :file f}))))

(fn append [session msg]
  "Append one canonical AgentMessage as a :message entry."
  (when (and session session.file)
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

(fn latest-for-cwd [cwd]
  "Return the absolute path of the most recently created session file for
   `cwd`, or nil if none. Uses `ls -1t` so we don't depend on a Lua FS lib."
  (let [dir (sessions-root cwd)
        cmd (.. "ls -1t " (path.shell-quote dir) " 2>/dev/null")
        pipe (io.popen cmd :r)]
    (if (not pipe)
        nil
        (let [first-line (pipe:read :*l)]
          (pipe:close)
          (if (and first-line (not= first-line ""))
              (.. dir "/" first-line)
              nil)))))

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

{: open : append : close : latest-for-cwd : load
 : sessions-root : cwd-slug : VERSION}
