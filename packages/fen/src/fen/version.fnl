;; Source-checkout version fallback; Nix builds overwrite the compiled `fen/version.lua` with an exact build stamp.

(local M {})

(local trim (. (require :fen.util.text) :trim))

(fn command-output [cmd]
  (let [p (io.popen (.. cmd " 2>/dev/null") :r)]
    (when p
      (let [out (p:read :*a)]
        (p:close)
        (let [s (trim out)]
          (when (not= s "") s))))))

(fn git-describe []
  (command-output "git describe --tags --match 'v[0-9]*' --dirty --always"))

(fn git-revs []
  "Full and short HEAD revisions from one git call; nil outside a checkout."
  (let [out (command-output "git rev-parse HEAD --short HEAD")
        (rev short) (string.match (or out "") "^(%x+)%s+(%x+)$")]
    (values rev short)))

(fn git-dirty? []
  (let [status (command-output "git status --porcelain")]
    (and status (not= status ""))))

(fn source-info []
  ;; Skip the remaining git calls outside a checkout; every source-mode start
  ;; (including test subprocesses) pays for them.
  (let [(rev short-rev) (git-revs)
        short (or short-rev "source")
        dirty? (and rev (git-dirty?))
        described (or (and rev (git-describe))
                      (if dirty? (.. short "-dirty") short))]
    {:version described
     :gitRev rev
     :gitShortRev short
     :dirty dirty?
     :source "source"
     :targetSystem nil
     :buildSystem nil
     :lastModified nil}))

;; @doc fen.version.info
;; kind: function
;; signature: (info) -> VersionInfo
;; summary: Return source-checkout version metadata; Nix builds replace this module with a stamped table.
;; tags: version build metadata
(fn M.info []
  (source-info))

;; @doc fen.version.version
;; kind: function
;; signature: (version) -> string
;; summary: Return the short source version string used by CLI/status displays.
;; tags: version build metadata
(fn M.version []
  (. (M.info) :version))

;; @doc fen.version.format
;; kind: function
;; signature: (format ?info) -> string
;; summary: Format version metadata as the single-line `fen --version` display.
;; tags: version build metadata
(fn M.format [?info]
  (let [info (or ?info (M.info))
        version (or info.version "unknown")
        source (or info.source "unknown")
        target info.targetSystem]
    (.. "fen " version
        " (" source
        (if target (.. ", " target) "")
        ")")))

M
