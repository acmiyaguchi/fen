(local util (require :fen.extensions.builtin_tools.util))
(local text (require :fen.util.text))

;; A cut that lands inside a UTF-8 character drops its continuation bytes.
(local LEADING-CONTINUATION (.. "^[" (string.char 128) "-" (string.char 191)
                                "]+"))

;; @doc fen.extensions.builtin_tools.bash.name
;; kind: data
;; signature: keyword
;; summary: Registry name for the built-in Bash tool descriptor advertised to providers and slash-command docs.
;; tags: builtin tools bash descriptor

;; @doc fen.extensions.builtin_tools.bash.bash
;; kind: data
;; signature: AgentToolSpec
;; summary: Complete Bash tool specification exported by the module for registration in the built-in tool registry.
;; tags: builtin tools bash descriptor

;; @doc fen.extensions.builtin_tools.bash.label
;; kind: data
;; signature: string
;; summary: Human-readable label shown in tool-running status and generated tool listings before shell commands.
;; tags: builtin tools bash ui

;; @doc fen.extensions.builtin_tools.bash.snippet
;; kind: data
;; signature: string
;; summary: Short Bash tool teaser used by generated docs and compact tool summaries before the full description.
;; tags: builtin tools bash docs

;; @doc fen.extensions.builtin_tools.bash.description
;; kind: data
;; signature: string
;; summary: Provider-facing Bash tool description documenting merged stdout/stderr and tail-truncation behavior.
;; tags: builtin tools bash docs

;; @doc fen.extensions.builtin_tools.bash.parameters
;; kind: data
;; signature: JSONSchema
;; summary: JSON schema for Bash tool arguments, including command text, optional timeout, and checked working directory.
;; tags: builtin tools bash schema

;; @doc fen.extensions.builtin_tools.bash.execute
;; kind: function
;; signature: (execute args ctx yield-fn?) -> AgentToolResult
;; summary: Bash tool executor that runs a shell command through the timed/cancellable process helper and returns capped output with exit status.
;; tags: builtin tools bash execution

(fn fmt-kb [n]
  (string.format "%dKB" (math.floor (/ (or n 0) 1024))))

(fn timeout-arg [timeout]
  "Normalize positive timeout values. The provider schema asks for integer
   seconds, but if a caller passes a positive fraction, round up to one second
   instead of silently disabling the timeout."
  (let [n (tonumber timeout)]
    (if (not n) nil
        (<= n 0) nil
        (< n 1) 1
        (math.floor n))))

(fn truncation-tag [r]
  (let [stats (or r.stats {})
        total-lines (or stats.total-lines stats.lines-read 0)
        total-bytes (or stats.total-bytes stats.bytes-read 0)
        kept-lines (let [s (or r.output "")]
                     (if (= s "") 0
                         (do
                           (var newlines 0)
                           (each [_ (string.gmatch s "\n")]
                             (set newlines (+ newlines 1)))
                           (if (= (string.sub s -1) "\n") newlines
                               (+ newlines 1)))))
        kept-bytes (length (or r.output ""))
        base (string.format "[truncated: kept tail %d/%d lines, %s/%s"
                            kept-lines total-lines (fmt-kb kept-bytes)
                            (fmt-kb total-bytes))]
    (if r.full-output-path
        (.. base " — full output: " r.full-output-path "]")
        (.. base "]"))))

(fn exit-tag [r timeout-seconds]
  (if r.timed-out?
      (.. "[timeout: process group signaled after " (tostring timeout-seconds)
          "s]")
      r.exit-code
      (.. "[exit " (tostring r.exit-code) "]")
      r.signal
      (.. "[signal " (tostring r.signal) "]")
      "[exit unknown — process killed or subprocess error]"))

(fn tail-within [s budget]
  "Keep at most budget bytes of s's tail, starting on a UTF-8 boundary."
  (if (<= (length s) budget) s (<= budget 0) ""
      (pick-values 1 (string.gsub (string.sub s (- budget))
                                  LEADING-CONTINUATION ""))))

(fn result-text [r timeout-seconds]
  "Sanitize the body here and budget it in sanitized bytes so the whole text
   fits the provider-side cap (FEN_TOOL_RESULT_MAX_BYTES): scrub-result then
   has nothing to cut, and the exit/timeout trailer stays last (#652)."
  (let [limit (text.default-tool-result-max-bytes)
        trailer (exit-tag r timeout-seconds)
        cleaned (text.sanitize (or r.output ""))
        escaped (+ cleaned.unsafe-count cleaned.invalid-count)
        note (when (> escaped 0)
               (.. "[fen: tool output sanitized: " escaped
                   " unsafe bytes escaped]"))
        full-body cleaned.text
        ;; Tag length never grows as the body shrinks, so size it on the full body.
        tag-for (fn [body]
                  (truncation-tag {:stats r.stats
                                   :output body
                                   :full-output-path r.full-output-path}))
        overhead (+ (length trailer) 1 (if note (+ (length note) 1) 0))
        fits? (and (not r.truncated?)
                   (<= (+ (length full-body) overhead) limit))
        body (if fits? full-body
                 (tail-within full-body
                              (- limit overhead (length (tag-for full-body)) 1)))
        shown (if fits? body (.. (tag-for body) "\n" body))]
    (.. shown "\n" (if note (.. note "\n") "") trailer)))

(fn process-details [r]
  {:exit-code r.exit-code :signal r.signal :timed-out? (or r.timed-out? false)})

(fn process-failed? [r]
  "Anything but a clean exit 0 (including an unknown exit) is a failure."
  (not (not (or r.timed-out? r.signal (not= r.exit-code 0)))))

(fn run-bash [args _ctx ?yield-fn]
  (let [{: cmd : timeout : cwd} args]
    (if (or (not cmd) (= cmd ""))
        (util.err "missing 'cmd'")
        (and cwd (not= cwd "") (not (util.dir-exists? cwd)))
        (util.err (.. "cwd does not exist: " cwd))
        (let [(ok? process) (pcall require :fen.util.process)]
          (if (not ok?)
              (util.err "fen.util.process helper is unavailable")
              (let [timeout-seconds (timeout-arg timeout)
                    r (process.run-captured {:cmd cmd
                                             :cwd cwd
                                             :timeout-seconds timeout-seconds
                                             :spill? true}
                                            ?yield-fn)]
                (util.text-result (result-text r timeout-seconds)
                                  (process-failed? r) (process-details r))))))))

{:name :bash
 :label "Bash"
 :snippet "Run a shell command in the working directory"
 :description "Run a shell command and return combined stdout+stderr (intentionally merged via 2>&1; pipe to /dev/null inside the cmd if you want to drop one). Output is tail-truncated to ~50KB / 2000 lines; when truncated, the tag includes a `full output: <path>` you can pass to the read tool to inspect any region of the original. Timeouts signal the command's process group; descendants that leave that group are outside this containment scope."
 :parameters {:type :object
              :properties {:cmd {:type :string
                                 :description "Shell command to run"}
                           :timeout {:type :integer
                                     :description "Signal the command's process group after N seconds"}
                           :cwd {:type :string
                                 :description "Working directory; validated to exist before running"}}
              :required [:cmd]}
 :execute run-bash}
