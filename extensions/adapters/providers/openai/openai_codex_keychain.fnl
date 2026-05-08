;; Auth storage for ChatGPT/Codex OAuth credentials.
;;
;; fen owns its writable auth file and treats pi-mono credentials as a
;; read-only fallback. `fen --login openai-codex`, refresh, and logout
;; mutate only the fen-owned path; existing pi-mono auth can still be
;; read so users do not need to log in twice.
;;
;; Writable path, in order: `FEN_AUTH_DIR/auth.json`, then
;; `${XDG_CONFIG_HOME:-~/.config}/fen/auth.json`.
;;
;; Read candidates, in order: writable path, `PI_CODING_AGENT_DIR/auth.json`,
;; then `~/.pi/agent/auth.json`. `PI_CODING_AGENT_DIR` is legacy/interop
;; with pi-mono and is deliberately read-only unless explicitly reused via
;; `FEN_AUTH_DIR`.
;;
;; All public functions accept an optional explicit `path` argument so
;; tests can target a tempdir without setenv tricks.

(local json (require :fen.util.json))
(local log (require :fen.util.log))

(fn home []
  (or (os.getenv "HOME") "/"))

(fn xdg-config-home []
  (or (os.getenv "XDG_CONFIG_HOME") (.. (home) "/.config")))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.default-agent-dir
;; kind: function
;; signature: (default-agent-dir) -> string
;; summary: Return fen's writable Codex auth directory, honoring FEN_AUTH_DIR before the XDG fen config directory.
;; tags: codex auth storage paths
(fn default-agent-dir []
  "Return fen's writable auth directory. Kept as the public name because
   callers historically used it for the default write target."
  (or (os.getenv "FEN_AUTH_DIR")
      (.. (xdg-config-home) "/fen")))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.default-auth-path
;; kind: function
;; signature: (default-auth-path) -> string
;; summary: Return the fen-owned auth.json path where Codex login, refresh, and logout persist credentials.
;; tags: codex auth storage paths
(fn default-auth-path []
  "Return fen's writable auth.json path."
  (.. (default-agent-dir) "/auth.json"))

(fn append-unique [xs v]
  (var seen? false)
  (each [_ existing (ipairs xs)]
    (when (= existing v)
      (set seen? true)))
  (when (not seen?)
    (table.insert xs v)))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.candidate-read-auth-paths
;; kind: function
;; signature: (candidate-read-auth-paths) -> [string]
;; summary: Return credential read paths in priority order: fen writable auth first, then pi-mono read-only fallbacks.
;; tags: codex auth storage paths
(fn candidate-read-auth-paths []
  "Return auth.json paths checked for credentials. The first path is the
   writable fen-owned path; later paths are pi-mono read-only fallbacks."
  (let [paths []]
    (append-unique paths (default-auth-path))
    (when (os.getenv "PI_CODING_AGENT_DIR")
      (append-unique paths (.. (os.getenv "PI_CODING_AGENT_DIR") "/auth.json")))
    (append-unique paths (.. (home) "/.pi/agent/auth.json"))
    paths))

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

;; @doc fen.extensions.provider_openai.openai_codex_keychain.load
;; kind: function
;; signature: (load ?path) -> table
;; summary: Read and decode one auth.json file, returning an empty table for missing, unreadable, or malformed storage.
;; tags: codex auth storage json
(fn load [?path]
  "Read one auth.json and return the decoded table. Returns {} if missing,
   unreadable, or malformed (with a log warning in the malformed case).
   Without an explicit path this reads the fen-owned writable file only;
   use `get` for read-through fallback to pi-mono credentials."
  (let [auth-path (or ?path (default-auth-path))
        content (read-file auth-path)]
    (if (or (not content) (= content ""))
        {}
        (let [(ok? value) (pcall json.decode content)]
          (if (and ok? (= (type value) :table))
              value
              (do (log.warn (.. "auth.storage: malformed " auth-path))
                  {}))))))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.get
;; kind: function
;; signature: (get provider-id ?path) -> table|nil
;; summary: Return one provider credential record, using read-through fallback to pi-mono auth only when no explicit path is supplied.
;; tags: codex auth storage lookup
(fn get [provider-id ?path]
  "Return a provider record. With an explicit path, read only that file.
   Otherwise read fen's writable auth first, then pi-mono read-only fallbacks."
  (if ?path
      (. (load ?path) provider-id)
      (let [paths (candidate-read-auth-paths)]
        (var found nil)
        (each [_ path (ipairs paths)]
          (when (= nil found)
            (let [record (. (load path) provider-id)]
              (when record
                (set found record)))))
        found)))

;; @doc fen.extensions.provider_openai.openai_codex_keychain.save
;; kind: function
;; signature: (save data ?path) -> nil
;; summary: Atomically write the full auth.json table, creating the parent directory and tightening file permissions to 0600.
;; tags: codex auth storage write
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

{: default-agent-dir
 : default-auth-path
 : candidate-read-auth-paths
 : load
 : get
 : save
 :set set-record}
