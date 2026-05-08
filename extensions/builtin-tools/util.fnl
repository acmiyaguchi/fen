(local types (require :fen.core.types))

;; @doc fen.extensions.builtin_tools.util.agent-result
;; kind: function
;; signature: (agent-result content is-error? details) -> AgentToolResult
;; summary: Build the common AgentToolResult shape used by built-in tools, preserving optional presenter details.
;; tags: tools results util
(fn agent-result [content is-error? details]
  (let [r {:content content :is-error? (or is-error? false)}]
    (when (not= details nil) (set r.details details))
    r))

;; @doc fen.extensions.builtin_tools.util.ok
;; kind: function
;; signature: (ok text) -> AgentToolResult
;; summary: Wrap successful plain text output as a canonical non-error AgentToolResult.
;; tags: tools results util
(fn ok [text]
  (agent-result [(types.text-block (or text ""))] false nil))

;; @doc fen.extensions.builtin_tools.util.err
;; kind: function
;; signature: (err message) -> AgentToolResult
;; summary: Wrap an error message as a canonical AgentToolResult whose text is prefixed with error:.
;; tags: tools results util
(fn err [message]
  (agent-result [(types.text-block (.. "error: " message))] true nil))

;; @doc fen.extensions.builtin_tools.util.shellquote
;; kind: function
;; signature: (shellquote s) -> string
;; summary: Quote a built-in tool path or argument as one POSIX shell word for system probes.
;; tags: tools shell util
(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

;; @doc fen.extensions.builtin_tools.util.int-arg
;; kind: function
;; signature: (int-arg v default) -> number
;; summary: Normalize numeric tool arguments by converting to an integer or returning the provided default.
;; tags: tools args util
(fn int-arg [v default]
  "Normalize integer-ish tool args."
  (let [n (tonumber v)]
    (if n (math.floor n) default)))

;; @doc fen.extensions.builtin_tools.util.result-text
;; kind: function
;; signature: (result-text r) -> string
;; summary: Extract the first text block from an AgentToolResult for tests and composed tool helpers.
;; tags: tools results util
(fn result-text [r]
  (let [b (and r.content (. r.content 1))]
    (if (and b (= b.type :text)) b.text "")))

;; @doc fen.extensions.builtin_tools.util.dir-exists?
;; kind: function
;; signature: (dir-exists? path) -> boolean
;; summary: Check whether a path is a directory using a shell-quoted POSIX test probe.
;; tags: tools filesystem util
(fn dir-exists? [path]
  (let [pipe (io.popen (.. "test -d " (shellquote path)
                            " && echo y || echo n") :r)]
    (if (not pipe) false
        (let [out (or (pipe:read :*l) "")]
          (pipe:close)
          (= out "y")))))

{: agent-result
 : ok
 : err
 : shellquote
 : int-arg
 : result-text
 : dir-exists?}
