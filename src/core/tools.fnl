;; Tool registry and executor.
;;
;; Mirrors pi-mono's split:
;;   - `Tool`        (canonical, provider-agnostic): {name, description, parameters}
;;   - `AgentTool`   (pi-mono `packages/agent/src/types.ts:308`): adds
;;                   {label, execute}. We skip prepareArguments / executionMode /
;;                   signal / onUpdate because there's no consumer for them yet.
;;   - `AgentToolResult`: {content: [TextContent], is-error?, details?}
;;
;; The registry is an array of AgentTool, not a name-keyed map. Order matters
;; for things like UI display; lookup is by linear scan (we have a handful of
;; tools, this is fine).
;;
;; Tool execute receives a *parsed* arguments table — the provider has already
;; JSON-decoded the wire-level argument string before constructing the
;; canonical ToolCall block.
;;
;; POSIX-only stance: grep/find shell out to system grep(1)/find(1); we don't
;; require ripgrep/fd. read has no image base64 / syntax highlighting; edit
;; is exact-match only (no fuzzy fallback or unified-diff output). See
;; CLAUDE.md's "Conventions / gotchas" section.

(local types (require :core.types))
(local agent-state (require :core.agent_state))

(fn agent-result [content is-error? details]
  (let [r {:content content :is-error? (or is-error? false)}]
    (when (not= details nil) (set r.details details))
    r))

(fn ok [text]
  (agent-result [(types.text-block (or text ""))] false nil))

(fn err [message]
  (agent-result [(types.text-block (.. "error: " message))] true nil))

(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn int-arg [v default]
  "Normalize integer-ish tool args. Some providers/model calls pass JSON
   integers through as floats (e.g. 200.0); shell utilities like head(1) and
   grep(1) reject those when they require integer arguments. Non-numeric nil
   falls back to `default`."
  (let [n (tonumber v)]
    (if n (math.floor n) default)))

;; ----------------------------------------------------------------
;; Output-size truncation helpers
;;
;; Mirrors pi-mono's coding-agent/src/core/tools/truncate.ts. Two limits;
;; whichever hits first wins:
;;   - 2000 lines (default)
;;   -   50 KB   (default)
;;
;; Without these, every byte the model reads/runs gets re-sent on EVERY
;; subsequent turn (tool-result blocks live in agent.messages), so a single
;; `cat huge_file` permanently bloats the conversation. Capping here keeps
;; the canonical message tail bounded; the model can still page via read's
;; offset/limit args or grep's limit arg if it needs more.
;; ----------------------------------------------------------------

(local DEFAULT-MAX-LINES 2000)
(local DEFAULT-MAX-BYTES (* 50 1024))

(fn count-lines [s]
  (var n 1)
  (each [_ (string.gmatch s "\n")] (set n (+ n 1)))
  n)

(fn fmt-kb [n]
  (string.format "%dKB" (math.floor (/ n 1024))))

;; ----------------------------------------------------------------
;; Spill truncated output to a temp file
;;
;; When the cap drops content, we still want the model to be able to
;; reach it via the read tool's offset/limit. Mirror pi-mono's
;; `fullOutputPath` mechanism: write the original full bytes to a
;; predictable location and surface the path inside the truncation tag.
;; ----------------------------------------------------------------

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn tool-output-dir []
  (let [xdg (os.getenv :XDG_STATE_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel/tool-output")
        (.. (home) "/.local/state/agent-fennel/tool-output"))))

(fn spill-id []
  ;; Cheap unique-ish suffix. math.random is fine; we only need
  ;; uniqueness across human-paced tool calls in one process.
  (math.randomseed (+ (os.time) (math.floor (* (os.clock) 1000000))))
  (let [parts []]
    (for [_ 1 8]
      (table.insert parts (string.format "%x" (math.random 0 15))))
    (table.concat parts)))

(fn spill-full-output [content]
  "Write `content` to a file under the tool-output dir and return the
   path on success, or nil on failure (caller proceeds without the
   suffix). Cleanup is deferred to the OS — XDG state dirs accumulate,
   /tmp is reaped on reboot."
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
  "Keep the first lines of `s` up to maxLines / maxBytes. Used for read/ls
   where the beginning is what the caller asked for. Never returns a
   partial trailing line. Returns (content, truncated?). When truncated,
   spills the full original to a temp file and embeds the path in the tag."
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
  "Keep the last lines of `s` up to maxLines / maxBytes. Used for bash
   output where errors/summaries land at the end. Returns (content,
   truncated?). When truncated, spills the full original to a temp file
   and embeds the path in the tag."
  (let [s (or s "")
        max-lines (or (?. opts :max-lines) DEFAULT-MAX-LINES)
        max-bytes (or (?. opts :max-bytes) DEFAULT-MAX-BYTES)
        total-bytes (length s)
        total-lines (count-lines s)]
    (if (and (<= total-lines max-lines) (<= total-bytes max-bytes))
        (values s false)
        (let [;; Collect all lines first, then pop from the back.
              lines []]
          (each [line (string.gmatch (.. s "\n") "([^\n]*)\n")]
            (table.insert lines line))
          (let [out []
                first-idx (length lines)]
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

;; ----------------------------------------------------------------
;; Built-in tool implementations
;; ----------------------------------------------------------------

(fn dir-exists? [path]
  (let [pipe (io.popen (.. "test -d " (shellquote path)
                            " && echo y || echo n") :r)]
    (if (not pipe) false
        (let [out (or (pipe:read :*l) "")]
          (pipe:close)
          (= out "y")))))

(fn read-small-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn read-pidfile [path]
  (let [s (read-small-file path)
        pid (and s (string.match s "^(%d+)"))]
    (and pid (tonumber pid))))

(fn kill-pid [pid]
  "Best-effort cancel cleanup for io.popen commands. Send TERM first, then
   KILL after a tiny grace period before pipe:close() enters pclose/waitpid."
  (when pid
    (os.execute (.. "kill -TERM " (tostring pid) " 2>/dev/null; "
                    "sleep 0.1; "
                    "kill -KILL " (tostring pid) " 2>/dev/null"))))

(fn bash-spawn-command [inner timeout-int pidfile]
  "Wrap the user command so the child PID is written before exec. The wrapper
   lets cancellation kill the process before io.popen's close() waits for it."
  (let [script "echo $$ > \"$1\"; shift; exec \"$@\""
        argv (if (and timeout-int (> timeout-int 0))
                 ["timeout" (.. (tostring timeout-int) "s") "sh" "-c" inner]
                 ["sh" "-c" inner])
        parts ["sh" "-c" (shellquote script) "agent-fennel-run" (shellquote pidfile)]]
    (each [_ arg (ipairs argv)]
      (table.insert parts (shellquote arg)))
    (.. (table.concat parts " ") " 2>&1")))

(fn run-bash-impl [{: cmd : timeout : cwd} reader]
  "Shared body for bash. `reader` is a function (pipe → string) that the
   blocking and cooperative variants supply: run-bash uses pipe:read :*a,
   run-bash-coop uses util.process.read-pipe-coop with a yield-fn."
  (if (or (not cmd) (= cmd ""))
      (err "missing 'cmd'")
      (and cwd (not= cwd "") (not (dir-exists? cwd)))
      (err (.. "cwd does not exist: " cwd))
      (let [timeout-int (int-arg timeout nil)
            ;; Optional `cwd` is prefixed as `cd <quoted> && <cmd>`. Timeout
            ;; is passed as argv to the PID-writing wrapper so the recorded
            ;; PID is the timeout supervisor (when present), not an extra
            ;; shell that would delay cancellation cleanup.
            cd-prefix (if (and cwd (not= cwd ""))
                          (.. "cd " (shellquote cwd) " && ")
                          "")
            inner (.. cd-prefix cmd)
            pidfile (os.tmpname)
            spawn-cmd (bash-spawn-command inner timeout-int pidfile)
            pipe (io.popen spawn-cmd :r)]
        (if (not pipe) (err "io.popen failed")
            (let [(read-ok? read-result) (pcall reader pipe)]
              (when (not read-ok?)
                ;; If the agent cancels while a silent child is still running,
                ;; pipe:close() would otherwise block in pclose()/waitpid.
                (kill-pid (read-pidfile pidfile)))
              (let [;; close even on read error so we surface the exit code
                    ;; and the child's resources are released.
                    (_ _ code) (pipe:close)]
                (os.remove pidfile)
                (if (not read-ok?)
                    (error read-result)
                    (let [(capped _) (truncate-tail (or read-result "") nil)
                          ;; pipe:close returns nil for the exit code when the child
                          ;; was killed by a signal Lua's io.popen doesn't surface, or
                          ;; when popen itself fails during cleanup. Don't coerce to 0
                          ;; — the model would treat a signal-killed run as success.
                          exit-tag (if code
                                       (.. "[exit " (tostring code) "]")
                                       "[exit unknown — process killed or popen error]")]
                      (ok (.. capped "\n" exit-tag))))))))))

(fn run-bash [args]
  (run-bash-impl args (fn [pipe] (or (pipe:read :*a) ""))))

(fn run-bash-coop [args yield-fn]
  "Cooperative bash: drains the pipe via util.process.read-pipe-coop,
   yielding while the child has no output ready. Lazy-requires posix so
   environments without luaposix degrade to the blocking path instead of
   crashing — coop falls back to run-bash."
  (let [(ok? process) (pcall require :util.process)]
    (if (not ok?)
        (run-bash args)
        (run-bash-impl args
                       (fn [pipe] (process.read-pipe-coop pipe yield-fn))))))

(fn result-text [r]
  (let [b (and r.content (. r.content 1))]
    (if (and b (= b.type :text)) b.text "")))

(fn run-read-one [{: path : offset : limit}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (err open-err)
            (if (and (not offset) (not limit))
                ;; Default: full slurp + head-truncate so reading a 10 MB log
                ;; doesn't poison every subsequent turn's context. Caller can
                ;; pass offset/limit to page explicitly.
                (let [content (f:read :*a)
                      _ (f:close)
                      (capped _) (truncate-head content nil)]
                  (ok capped))
                ;; Slice: f:lines drops the trailing newline; we re-join with
                ;; "\n" without re-adding one at the end. The slice is sized
                ;; by the caller, so we trust it (no second-layer cap).
                (let [start (int-arg offset 1)
                      take (or (int-arg limit nil) math.huge)
                      lines []]
                  (var n 0)
                  (each [line (f:lines)]
                    (set n (+ n 1))
                    (when (and (>= n start) (< (length lines) take))
                      (table.insert lines line)))
                  (f:close)
                  (ok (table.concat lines "\n"))))))))

(fn normalize-read-spec [spec]
  (if (= (type spec) :string)
      {:path spec}
      spec))

(fn run-read-batch [paths]
  (if (or (not paths) (= (length paths) 0))
      (err "missing 'paths'")
      (let [parts []]
        (each [_ raw (ipairs paths)]
          (let [spec (normalize-read-spec raw)
                path (?. spec :path)
                header (.. "==> " (or path "<missing path>") " <==")
                r (run-read-one (or spec {}))]
            (table.insert parts (.. header "\n" (result-text r)))))
        (ok (table.concat parts "\n\n")))))

(fn run-read [args]
  (let [has-path? (and args.path (not= args.path ""))
        has-paths? (not= args.paths nil)]
    (if (and has-path? has-paths?)
        (err "provide either 'path' or 'paths', not both")
        has-paths?
        (run-read-batch args.paths)
        (run-read-one args))))

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (do
        ;; mkdir -p the parent so the model doesn't need a separate bash call.
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when parent
            (os.execute (.. "mkdir -p " (shellquote parent)))))
        (let [(f open-err) (io.open path :w)]
          (if (not f) (err open-err)
              (do (f:write (or content ""))
                  (f:close)
                  (ok (.. "wrote " (tostring (length (or content "")))
                          " bytes to " path))))))))

(fn run-ls [{: path : limit}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (shellquote target) " 2>&1") :r)]
    (if (not pipe) (err "io.popen failed")
        (let [out (or (pipe:read :*a) "")
              take (int-arg limit nil)]
          (pipe:close)
          (if (and take (> take 0))
              (let [lines []]
                (var taken 0)
                (each [line (string.gmatch out "[^\n]+")]
                  (when (< taken take)
                    (table.insert lines line)
                    (set taken (+ taken 1))))
                (ok (table.concat lines "\n")))
              ;; No explicit limit → still cap so a 100k-entry dir doesn't
              ;; flood the conversation.
              (let [(capped _) (truncate-head out nil)]
                (ok capped)))))))

;; --- edit -------------------------------------------------------

(fn find-all [s sub]
  "All 1-based start indices where literal `sub` occurs in `s`. Plain match,
   no pattern interpretation."
  (let [out []
        sub-len (length sub)]
    (var i 1)
    (var done? false)
    (while (not done?)
      (let [pos (string.find s sub i 1)]
        (if pos
            (do (table.insert out pos)
                (set i (+ pos sub-len)))
            (set done? true))))
    out))

(fn has-crlf? [s]
  ;; Cheap probe: Lua string.find with literal pattern.
  (not= nil (string.find s "\r\n" 1 true)))

(fn validate-edits [content edits]
  "Locate every edit's match. Each old_string must occur exactly once in
   the original content, and no two matches may overlap. Returns
   (matches nil) on success or (nil error-message) on failure."
  (let [matches []
        ;; Detect once — surface a CRLF hint on not-found errors so the
        ;; CRLF-vs-LF mismatch isn't a silent failure mode. We don't
        ;; auto-normalize: doing so reliably while preserving original
        ;; line endings on write needs careful index tracking. Naming
        ;; the failure is enough for the model to retry with \r\n.
        crlf? (has-crlf? content)]
    (var error-msg nil)
    (each [i edit (ipairs edits)]
      (when (not error-msg)
        (let [old-str edit.old_string]
          (if (or (not old-str) (= old-str ""))
              (set error-msg (.. "edit " (tostring i) ": missing old_string"))
              (let [hits (find-all content old-str)]
                (if (= (length hits) 0)
                    (set error-msg
                         (.. "edit " (tostring i) ": old_string not found"
                             (if (and crlf? (not (has-crlf? old-str)))
                                 " (file has CRLF line endings; old_string uses LF — try \\r\\n)"
                                 "")))
                    (> (length hits) 1)
                    (set error-msg (.. "edit " (tostring i)
                                       ": old_string is not unique ("
                                       (tostring (length hits))
                                       " matches)"))
                    (table.insert matches
                      {:start (. hits 1)
                       :end (+ (. hits 1) (length old-str) -1)
                       :new (or edit.new_string "")
                       :index i})))))))
    (when (not error-msg)
      (table.sort matches (fn [a b] (< a.start b.start)))
      (each [k cur (ipairs matches)]
        (when (and (not error-msg) (> k 1))
          (let [prev (. matches (- k 1))]
            (when (>= prev.end cur.start)
              (set error-msg (.. "edits " (tostring prev.index)
                                 " and " (tostring cur.index)
                                 " overlap")))))))
    (if error-msg (values nil error-msg) (values matches nil))))

(fn apply-edits [content matches]
  "Splice each match's replacement in from end to start so earlier index
   positions stay valid for later splices."
  (var result content)
  (for [k (length matches) 1 -1]
    (let [m (. matches k)]
      (set result
           (.. (string.sub result 1 (- m.start 1))
               m.new
               (string.sub result (+ m.end 1))))))
  result)

(fn validate-edit-file [path edits]
  (if (or (not path) (= path ""))
      (values nil "missing 'path'")
      (or (not edits) (= (length edits) 0))
      (values nil "missing 'edits'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (values nil open-err)
            (let [content (f:read :*a)
                  _ (f:close)
                  (matches verr) (validate-edits content edits)]
              (if verr
                  (values nil verr)
                  (values {:path path
                           :edits edits
                           :content content
                           :matches matches}
                          nil)))))))

(fn write-edit-file [validated]
  (let [result (apply-edits validated.content validated.matches)
        (wf werr) (io.open validated.path :w)]
    (if (not wf)
        (values nil werr)
        (do (wf:write result)
            (wf:close)
            (values true nil)))))

(fn run-edit-one [{: path : edits}]
  (let [(validated verr) (validate-edit-file path edits)]
    (if verr
        (err verr)
        (let [(_ werr) (write-edit-file validated)]
          (if werr
              (err werr)
              (ok (.. "applied " (tostring (length edits))
                      " edit(s) to " path)))))))

(fn run-edit-batch [files]
  (if (or (not files) (= (length files) 0))
      (err "missing 'files'")
      (let [validated []
            seen {}]
        (var error-msg nil)
        (each [i f (ipairs files)]
          (when (not error-msg)
            (let [path (?. f :path)]
              (if (and path (. seen path))
                  (set error-msg (.. path ": duplicate path in files batch; combine edits for the same file in one entry"))
                  (do
                    (when path (tset seen path true))
                    (let [(v verr) (validate-edit-file path (?. f :edits))]
                      (if verr
                          (set error-msg (.. (or path (.. "file " (tostring i))) ": " verr))
                          (table.insert validated v))))))))
        (if error-msg
            (err error-msg)
            (let [summaries []]
              (var write-err nil)
              (each [_ v (ipairs validated)]
                (when (not write-err)
                  (let [(_ werr) (write-edit-file v)]
                    (if werr
                        (set write-err (.. v.path ": " werr))
                        (table.insert summaries
                                      (.. "applied " (tostring (length v.edits))
                                          " edit(s) to " v.path))))))
              (if write-err
                  (err write-err)
                  (ok (table.concat summaries "\n"))))))))

(fn run-edit [args]
  (let [has-single? (or (and args.path (not= args.path ""))
                         (not= args.edits nil))
        has-files? (not= args.files nil)]
    (if (and has-single? has-files?)
        (err "provide either 'path'/'edits' or 'files', not both")
        has-files?
        (run-edit-batch args.files)
        (run-edit-one args))))

;; --- grep / find ------------------------------------------------

(fn run-grep [{: pattern : path : glob : ignore_case : literal : context : limit}]
  (if (or (not pattern) (= pattern ""))
      (err "missing 'pattern'")
      (let [target (or path ".")
            cap (int-arg limit 200)
            opts ["-rn"]]
        (when literal (table.insert opts "-F"))
        (when ignore_case (table.insert opts "-i"))
        (let [context-int (int-arg context nil)]
          (when (and context-int (> context-int 0))
            (table.insert opts (.. "-C " (tostring context-int)))))
        (when (and glob (not= glob ""))
          (table.insert opts (.. "--include=" (shellquote glob))))
        (let [cmd (.. "grep " (table.concat opts " ")
                      " -- " (shellquote pattern) " " (shellquote target)
                      " 2>&1 | head -n " (tostring cap))
              pipe (io.popen cmd :r)]
          (if (not pipe) (err "io.popen failed")
              (let [out (or (pipe:read :*a) "")
                    ;; Line cap is enforced by `head -n`; layer a byte cap on
                    ;; top so a single match line that's 10 MB long (e.g. a
                    ;; minified bundle) doesn't sneak through.
                    (capped _) (truncate-head out nil)]
                (pipe:close)
                (ok capped)))))))

(fn run-find [{: pattern : path : limit}]
  (if (or (not pattern) (= pattern ""))
      (err "missing 'pattern'")
      (let [target (or path ".")
            cap (int-arg limit 200)
            cmd (.. "find " (shellquote target)
                    " -name " (shellquote pattern)
                    " -print 2>&1 | head -n " (tostring cap))
            pipe (io.popen cmd :r)]
        (if (not pipe) (err "io.popen failed")
            (let [out (or (pipe:read :*a) "")
                  (capped _) (truncate-head out nil)]
              (pipe:close)
              (ok capped))))))

;; ----------------------------------------------------------------
;; Default registry
;; ----------------------------------------------------------------

(local registry
  [{:name :bash
    :label "Bash"
    :snippet "Run a shell command in the working directory"
    :description "Run a shell command and return combined stdout+stderr (intentionally merged via 2>&1; pipe to /dev/null inside the cmd if you want to drop one). Output is tail-truncated to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass to the read tool to inspect any region of the original."
    :parameters {:type :object
                 :properties {:cmd {:type :string
                                    :description "Shell command to run"}
                              :timeout {:type :integer
                                        :description "Kill the command after N seconds (uses timeout(1))"}
                              :cwd {:type :string
                                    :description "Working directory; validated to exist before running"}}
                 :required [:cmd]}
    :execute run-bash
    :execute-coop run-bash-coop}
   {:name :read
    :label "Read"
    :snippet "Read a file's contents"
    :description "Read one or more files. Single-file shape: {path, optional offset/limit}. Batch shape: {paths:[path-or-{path,offset,limit}, ...]}. Default full slurp is head-truncated per file to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass back to this tool with offset/limit to page explicitly through the original. In batched reads, missing/unreadable files are reported inline under that path's header; the overall call still succeeds."
    :parameters {:type :object
                 :properties {:path {:type :string
                                     :description "File path for single-file reads; mutually exclusive with paths"}
                              :paths {:type :array
                                      :description "Batch multiple reads in one call. Items may be path strings or {path, offset, limit} objects; mutually exclusive with path."
                                      :items {:anyOf [{:type :string}
                                                      {:type :object
                                                       :properties {:path {:type :string}
                                                                    :offset {:type :integer}
                                                                    :limit {:type :integer}}
                                                       :required [:path]}]}}
                              :offset {:type :integer
                                       :description "1-indexed start line for single-file reads"}
                              :limit {:type :integer
                                      :description "Maximum number of lines to return"}}}
    :execute run-read}
   {:name :write
    :label "Write"
    :snippet "Create or overwrite a file"
    :description "Write content to a file (overwrites). Creates the parent directory if missing."
    :parameters {:type :object
                 :properties {:path {:type :string :description "File path"}
                              :content {:type :string :description "Content to write"}}
                 :required [:path :content]}
    :execute run-write}
   {:name :ls
    :label "Ls"
    :snippet "List directory contents"
    :description "List entries in a directory."
    :parameters {:type :object
                 :properties {:path {:type :string :description "Directory (defaults to .)"}
                              :limit {:type :integer
                                      :description "Maximum number of entries to return"}}}
    :execute run-ls}
   {:name :edit
    :label "Edit"
    :snippet "Make exact-text replacements in one or more files"
    :description "Make exact-text replacements. Single-file shape: {path, edits}. Batch shape: {files:[{path, edits}, ...]}. Each old_string must match uniquely in the original; multiple disjoint edits per file are applied to the original snapshot, not sequentially. Batch validation is all-or-nothing: if any file fails validation, no file is mutated. After validation succeeds, files are written sequentially; a rare write failure can leave earlier files already written."
    :parameters {:type :object
                 :properties {:path {:type :string
                                     :description "File path for single-file edits; mutually exclusive with files"}
                              :edits {:type :array
                                      :description "Replacements to apply to path"
                                      :items {:type :object
                                              :properties {:old_string {:type :string
                                                                        :description "Exact text to match (unique in file)"}
                                                           :new_string {:type :string
                                                                        :description "Replacement text"}}
                                              :required [:old_string :new_string]}}
                              :files {:type :array
                                      :description "Batch edits across files in one call; mutually exclusive with path/edits"
                                      :items {:type :object
                                              :properties {:path {:type :string
                                                                  :description "File path"}
                                                           :edits {:type :array
                                                                   :description "Replacements to apply"
                                                                   :items {:type :object
                                                                           :properties {:old_string {:type :string
                                                                                                     :description "Exact text to match (unique in file)"}
                                                                                        :new_string {:type :string
                                                                                                     :description "Replacement text"}}
                                                                           :required [:old_string :new_string]}}}
                                              :required [:path :edits]}}}}
    :execute run-edit}
   {:name :grep
    :label "Grep"
    :snippet "Search file contents with regex"
    :description "Search files for a regex pattern. Recursive when path is a directory."
    :parameters {:type :object
                 :properties {:pattern {:type :string :description "Pattern to search for"}
                              :path {:type :string :description "File or directory (default: .)"}
                              :glob {:type :string
                                     :description "Filename glob filter, e.g. *.fnl"}
                              :ignore_case {:type :boolean
                                            :description "Case-insensitive match"}
                              :literal {:type :boolean
                                        :description "Treat pattern as literal text, not regex"}
                              :context {:type :integer
                                        :description "Lines of context before/after each match"}
                              :limit {:type :integer
                                      :description "Maximum output lines (default 200)"}}
                 :required [:pattern]}
    :execute run-grep}
   {:name :find
    :label "Find"
    :snippet "Find files by name pattern"
    :description "Locate files by name glob, recursively."
    :parameters {:type :object
                 :properties {:pattern {:type :string
                                        :description "Glob pattern, e.g. *.fnl"}
                              :path {:type :string
                                     :description "Directory (default: .)"}
                              :limit {:type :integer
                                      :description "Maximum results (default 200)"}}
                 :required [:pattern]}
    :execute run-find}
   {:name :agent_state
    :label "Agent State"
    :snippet "Inspect read-only agent state"
    :description "Read structured state of the running agent. Read-only; does not evaluate code. Query is a tiny Fennel-shaped data language. Examples: (:get :model), (:count (:get :messages)), (:get :messages -1), (:pluck (:get :tools) :name), (:where (:get :messages) :role :assistant), (:last (:where (:get :messages) :role :assistant)), (:slice (:get :messages) -5 5), (:keys (:get)). Prefer narrow queries over dumping large roots. Output defaults to JSON; use format=fennel for Fennel rendering when available."
    :parameters {:type :object
                 :properties {:query {:type :string
                                      :description "Read-only query form, e.g. (:get :messages -1 :content)"}
                              :format {:type :string
                                       :enum [:json :fennel]
                                       :description "Output format; defaults to json"}
                              :max_bytes {:type :integer
                                          :description "Maximum output bytes before truncation (default 8192)"}}
                 :required [:query]}
    :execute-with-context agent-state.execute}])

;; ----------------------------------------------------------------
;; Helpers
;; ----------------------------------------------------------------

(fn find-tool [reg name]
  (var found nil)
  (each [_ t (ipairs reg)]
    (when (and (= found nil) (= (tostring t.name) (tostring name)))
      (set found t)))
  found)

(fn descriptors [reg]
  "Strip execute/label → canonical Tool[] (the shape providers wrap)."
  (let [out []]
    (each [_ t (ipairs reg)]
      (table.insert out
                    {:name t.name
                     :description t.description
                     :parameters t.parameters}))
    out))

(fn execute [reg name args ctx]
  "Look up a tool by name and run it. `args` is a parsed table (the provider
   has already JSON-decoded the wire arguments). Returns a canonical
   AgentToolResult. Tools may opt into `:execute-with-context` when they need
   read-only access to agent/session context."
  (let [t (find-tool reg name)]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

(fn execute-coop [reg name args yield-fn ctx]
  "Like `execute` but routes to the tool's :execute-coop when present so
   long-running tools (currently just bash) can yield while waiting on
   I/O. Tools without a coop variant fall back to blocking :execute."
  (let [t (find-tool reg name)]
    (if (not t)
        (err (.. "unknown tool: " (tostring name)))
        t.execute-coop
        (t.execute-coop (or args {}) yield-fn)
        t.execute-with-context
        (t.execute-with-context (or args {}) ctx)
        (t.execute (or args {})))))

{: registry : descriptors : execute : execute-coop : find-tool}
