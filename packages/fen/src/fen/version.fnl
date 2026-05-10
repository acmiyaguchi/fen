;; Runtime/build version metadata.
;;
;; Nix builds overwrite the compiled `fen/version.lua` with an exact build
;; stamp from flake metadata. Source-checkout runs use this fallback module,
;; which best-effort reads git so `fen --version` and /status still identify
;; the code under development.

(local M {})

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn command-output [cmd]
  (let [p (io.popen (.. cmd " 2>/dev/null") :r)]
    (when p
      (let [out (p:read :*a)]
        (p:close)
        (let [s (trim out)]
          (when (not= s "") s))))))

(fn git-describe []
  (command-output "git describe --tags --match 'v[0-9]*' --dirty --always"))

(fn git-short-rev []
  (command-output "git rev-parse --short HEAD"))

(fn git-rev []
  (command-output "git rev-parse HEAD"))

(fn git-dirty? []
  (let [status (command-output "git status --porcelain")]
    (and status (not= status ""))))

(fn source-info []
  (let [short (or (git-short-rev) "source")
        described (or (git-describe)
                      (if (git-dirty?) (.. short "-dirty") short))]
    {:version described
     :gitRev (git-rev)
     :gitShortRev short
     :dirty (git-dirty?)
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
