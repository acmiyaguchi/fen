;; Auth storage for ChatGPT/Codex OAuth credentials.
;;
;; fen owns its auth file and deliberately does not read pi-mono's
;; `~/.pi/agent/auth.json` or `PI_CODING_AGENT_DIR/auth.json` fallbacks.
;; `fen --login openai-codex`, refresh, logout, and credential lookup all
;; use only the fen-owned path.
;;
;; Auth path, in order: `FEN_AUTH_DIR/auth.json`, then
;; `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json`.
;;
;; All public functions accept an optional explicit `path` argument so
;; tests can target a tempdir without setenv tricks.

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))
(local durable (require :fen.util.durable_store))

;; A waiter outlasts one refresh POST (30 s total, 10 s connect) plus slack.
(local AUTH-LOCK-TIMEOUT-MS 45000)

(fn home []
  (or (os.getenv "HOME") "/"))

(fn xdg-config-home []
  (or (os.getenv "XDG_CONFIG_HOME") (.. (home) "/.config")))

(fn default-agent-dir []
  "Return fen's writable auth directory. Kept as the public name because
   callers historically used it for the default write target."
  (or (os.getenv "FEN_AUTH_DIR") (.. (xdg-config-home) "/fen")))

(fn default-auth-path []
  "Return fen's writable auth.json path."
  (.. (default-agent-dir) "/auth.json"))

(fn candidate-read-auth-paths []
  "Return auth.json paths checked for credentials. Fen only reads its
   own auth path; pi-mono auth files are intentionally ignored."
  [(default-auth-path)])

(fn read-file [path]
  (let [f (io.open path "r")]
    (when f
      (let [content (f:read "*a")]
        (f:close)
        content))))

(fn load [?path]
  "Read one auth.json and return the decoded table. Returns {} if missing,
   unreadable, or malformed (with a log warning in the malformed case).
   Without an explicit path this reads the fen-owned writable file only."
  (let [auth-path (or ?path (default-auth-path))
        content (read-file auth-path)]
    (if (or (not content) (= content ""))
        {}
        (let [(ok? value) (pcall json.decode content)]
          (if (and ok? (= (type value) :table))
              value
              (do
                (log.warn (.. "auth.storage: malformed " auth-path))
                {}))))))

(fn get [provider-id ?path]
  "Return a provider record. With an explicit path, read only that file.
   Otherwise read only fen's auth.json."
  (. (load (or ?path (default-auth-path))) provider-id))

(fn save [data ?path]
  "Atomic write of the entire auth.json table. Creates the parent directory
   owner-only (0700) if missing; the temp file is created 0600 before the
   tokens are written and renamed over auth.json, so readers never observe a
   half-written file and no other user can read the tokens (#615). A failed
   write removes the temp file."
  (let [auth-path (or ?path (default-auth-path))]
    (durable.ensure-private-dir! (path.dirname auth-path))
    (durable.write-private! auth-path (json.encode (or data {})))))

(fn with-auth-lock [?path ?yield body]
  "Run BODY holding the auth lock for ?PATH. Refresh holds it from the re-read
   through the POST to the write-back; login and logout hold it around their
   write. Contention yields through ?YIELD (or sleeps) for up to
   AUTH-LOCK-TIMEOUT-MS, which covers one refresh POST's HTTP timeouts."
  (let [auth-path (or ?path (default-auth-path))]
    (durable.ensure-private-dir! (path.dirname auth-path))
    (durable.with-lock (.. auth-path ".lock") ?yield body
      {:timeout-ms AUTH-LOCK-TIMEOUT-MS})))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.set
;; kind: function
;; signature: (set provider-id record ?path) -> table
;; summary: Read-modify-write one provider credential record into auth.json and return the persisted auth table.
;; tags: codex auth storage write
(fn set-record [provider-id record ?path]
  "Read-modify-write merge of one provider's record. Returns the merged
   table that was persisted."
  (let [data (load ?path)]
    (tset data provider-id record)
    (save data ?path)
    data))

(fn compare-and-set! [provider-id expected-refresh record ?path]
  "Commit a refresh result only onto the record it refreshed (#612): if the
   stored record was removed by logout or replaced by a login meanwhile,
   drop RECORD and return false plus the current record. The read, check,
   and rename run without yielding."
  (let [data (load ?path)
        current (. data provider-id)]
    (if (and current (= current.refresh expected-refresh))
        (do
          (tset data provider-id record)
          (save data ?path)
          true)
        (values false current))))

{: default-agent-dir
 : default-auth-path
 : candidate-read-auth-paths
 : load
 : get
 : save
 :set set-record
 : compare-and-set!
 : with-auth-lock}
