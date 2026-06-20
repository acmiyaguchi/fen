;; Runtime introspection for the running fen process. Currently just resolves
;; the path to fen's own executable so extensions (e.g. subagent) can spawn a
;; fresh child fen.
(local path (require :fen.util.path))

(local M {})

(fn which [name]
  "Resolve NAME on PATH via `command -v`, or nil when not found."
  (let [pipe (io.popen (.. "command -v " (path.shell-quote name) " 2>/dev/null") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        (when (and out (not= out "")) out)))))

(fn from-arg0 []
  "Absolutize _G.arg[0] when it names an existing path (contains a slash).
   Bare names like `fen` (resolved off PATH) are left to later fallbacks."
  (let [a0 (?. _G.arg 0)]
    (when (and a0 (string.find a0 "/" 1 true))
      (let [abs (path.realpath a0)]
        (when (path.file-exists? abs) abs)))))

(fn from-proc-self []
  "Linux: resolve the running executable via /proc/self/exe. Reliable for the
   compiled single-file binary; used as a fallback after argv[0] (so the dev
   wrapper, which re-execs with overlays, still wins) and before `which`, so a
   bare argv[0] with fen off PATH does not leave the subagent tool inert."
  (let [pipe (io.popen "readlink /proc/self/exe 2>/dev/null" :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        (when (and out (not= out "") (path.file-exists? out)) out)))))

;; @doc fen.runtime.binary-path
;; kind: function
;; signature: (binary-path) -> string|nil
;; summary: Best-effort absolute path to fen's own executable. Prefers argv[0]
;;   (so a child inherits the same binary and any dev overlays in the
;;   environment), then $FEN_BIN, then /proc/self/exe, then `fen` on PATH.
;; tags: runtime process self
(fn M.binary-path []
  (or (from-arg0)
      (os.getenv :FEN_BIN)
      (from-proc-self)
      (which :fen)))

M
