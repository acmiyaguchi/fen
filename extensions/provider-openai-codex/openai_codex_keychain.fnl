;; Auth storage for ChatGPT/Codex OAuth credentials.
;;
;; fen writes to `~/.pi/agent/auth.json` so it shares storage with
;; pi-mono — either tool can run `--login openai-codex` and the other
;; will pick up the resulting credentials. `openai_codex_login.fnl`
;; owns the initial PKCE flow; `openai_codex_oauth.fnl` owns the
;; refresh path; both go through this module for atomic file I/O.
;;
;; Two env vars override the directory, in order: `FEN_AUTH_DIR` (fen-
;; specific, set this when you want fen to read/write a separate file
;; without affecting pi-mono in the same shell) and `PI_CODING_AGENT_DIR`
;; (legacy/interop, the variable pi-mono itself honors). Either points
;; at the *directory* that holds `auth.json`; the file name is fixed.
;;
;; All public functions accept an optional explicit `path` argument so
;; tests can target a tempdir without setenv tricks.

(local json (require :fen.util.json))
(local log (require :fen.util.log))

(fn home []
  (or (os.getenv "HOME") "/"))

(fn default-agent-dir []
  (or (os.getenv "FEN_AUTH_DIR")
      (os.getenv "PI_CODING_AGENT_DIR")
      (.. (home) "/.pi/agent")))

(fn default-auth-path []
  (.. (default-agent-dir) "/auth.json"))

(fn read-file [path]
  (let [f (io.open path "r")]
    (when f
      (let [content (f:read "*a")]
        (f:close)
        content))))

(fn parent-dir [path]
  "Strip the final /name component. Returns the root slash when the path
   has no separator above the leading one."
  (let [last-slash (string.find path "/[^/]*$")]
    (if (or (not last-slash) (<= last-slash 1))
        "/"
        (string.sub path 1 (- last-slash 1)))))

(fn shell-quote [s]
  "Single-quote a path for shell use. We control the input (env vars and
   constants), but be defensive against embedded apostrophes anyway."
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn ensure-dir! [path]
  (os.execute (.. "mkdir -p " (shell-quote path) " 2>/dev/null")))

(fn chmod-private! [path]
  (os.execute (.. "chmod 600 " (shell-quote path) " 2>/dev/null")))

(fn load [?path]
  "Read auth.json and return the decoded table. Returns {} if missing,
   unreadable, or malformed (with a log warning in the malformed case)."
  (let [auth-path (or ?path (default-auth-path))
        content (read-file auth-path)]
    (if (or (not content) (= content ""))
        {}
        (let [(ok? value) (pcall json.decode content)]
          (if (and ok? (= (type value) :table))
              value
              (do (log.warn (.. "auth.storage: malformed " auth-path))
                  {}))))))

(fn get [provider-id ?path]
  (. (load ?path) provider-id))

(fn save [data ?path]
  "Atomic write of the entire auth.json table. Creates the parent directory
   if missing, chmod 0600 the resulting file. The tmp+rename dance keeps
   readers from observing a half-written file."
  (let [auth-path (or ?path (default-auth-path))
        dir (parent-dir auth-path)
        tmp (.. auth-path ".tmp")]
    (ensure-dir! dir)
    (let [f (io.open tmp "w")]
      (when (not f)
        (error (.. "auth.storage: cannot open " tmp " for write")))
      (f:write (json.encode (or data {})))
      (f:close))
    (chmod-private! tmp)
    (let [(ok? err) (os.rename tmp auth-path)]
      (when (not ok?)
        (os.remove tmp)
        (error (.. "auth.storage: rename " tmp " -> " auth-path
                   " failed: " (tostring err))))
      ;; Defensive: if the file existed before with looser perms, rename
      ;; preserves them on most filesystems but tightening explicitly
      ;; matches pi-mono's behavior.
      (chmod-private! auth-path))))

(fn set-record [provider-id record ?path]
  "Read-modify-write merge of one provider's record. Returns the merged
   table that was persisted."
  (let [data (load ?path)]
    (tset data provider-id record)
    (save data ?path)
    data))

{: default-agent-dir
 : default-auth-path
 : load
 : get
 : save
 :set set-record}
