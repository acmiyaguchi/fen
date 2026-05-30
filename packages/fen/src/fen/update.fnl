;; Self-update: replace the running fen binary with the latest GitHub release.
;;
;; `fen update` is the only entry point. It is deliberately restricted to tagged
;; release binaries — source/dev checkouts and untagged local builds are refused,
;; since overwriting them with a downloaded artifact would clobber a working tree
;; or fail against a read-only Nix store path.
;;
;; The single-file binary is a C launcher with an appended zip, so an update is a
;; whole-file swap: download the matching asset, verify its SHA-256 against the
;; release SHA256SUMS, then atomically rename it over the running executable
;; (which keeps its old inode, exactly like the install.sh `mv -f`).
;;
;; All HTTP goes through fen.util.http; redirects are followed here because the
;; release asset URL 302-redirects to a CDN and the shared transport does not
;; follow redirects on its own.

(local http (require :fen.util.http))
(local json (require :fen.util.json))
(local sha256 (require :fen.util.sha256))
(local path (require :fen.util.path))
(local version (require :fen.version))

(local M {})

(local REPO "acmiyaguchi/fen")
(local API-LATEST (.. "https://api.github.com/repos/" REPO "/releases/latest"))
(local DL-BASE (.. "https://github.com/" REPO "/releases/download"))
(local USER-AGENT "fen-update")
(local MAX-REDIRECTS 5)

(fn version-info []
  "Resolve version metadata across the three shapes fen.version can take:
   the source-checkout module (functions), a Nix/make flat data table, or a
   bare version string (luarocks install)."
  (if (= (type version.info) :function) (version.info)
      (= (type version) :table) version
      {:version (tostring version) :source "unknown"}))

(fn say [s] (io.write s "\n"))
(fn oops [s] (io.stderr:write (.. "fen update: " s "\n")))

(fn command-line [cmd]
  "Read the first output line of a shell command, or nil."
  (let [p (io.popen (.. cmd " 2>/dev/null") :r)]
    (when p
      (let [out (p:read :*l)]
        (p:close)
        (when (and out (not= out "")) out)))))

(fn header-get [headers name]
  "Case-insensitive header lookup (curl preserves the server's casing)."
  (let [want (name:lower)]
    (var found nil)
    (each [k v (pairs (or headers {}))]
      (when (= (string.lower k) want) (set found v)))
    found))

(fn arch->slug [arch]
  "Map a `uname -m` value to a release asset slug, or nil if unsupported.
   The generic armv7 build is the safe default and runs on the N900 too;
   the N900-tuned asset is reachable via the FEN_ARCH override."
  (if (or (= arch "x86_64") (= arch "amd64")) "linux-x86_64-musl-static"
      (or (= arch "aarch64") (= arch "arm64")) "linux-aarch64-musl-static"
      (or (= arch "armv7l") (= arch "armv6l")) "linux-armv7-musleabihf-static"
      nil))

(fn detect-slug []
  "Resolve this host's asset slug, honoring a FEN_ARCH override.
   Returns (values slug nil) or (values nil error-message)."
  (let [override (os.getenv :FEN_ARCH)]
    (if (and override (not= override ""))
        (values override nil)
        (let [os-name (or (command-line "uname -s") "")]
          (if (not= os-name "Linux")
              (values nil (.. "prebuilt binaries are Linux-only (detected: "
                              (if (= os-name "") "unknown" os-name)
                              "); build from source instead"))
              (let [arch (or (command-line "uname -m") "")
                    slug (arch->slug arch)]
                (if slug
                    (values slug nil)
                    (values nil (.. "unsupported architecture: "
                                    (if (= arch "") "unknown" arch)
                                    "; set FEN_ARCH to override")))))))))

(fn http-get [url]
  "GET `url`, following up to MAX-REDIRECTS redirects (the shared transport
   does not). Returns (values body nil) or (values nil error-message)."
  (var current url)
  (var redirects 0)
  (var body nil)
  (var err nil)
  (var done? false)
  (while (not done?)
    (let [resp (http.request {:method "GET"
                              :url current
                              :headers {:User-Agent USER-AGENT :Accept "*/*"}})]
      (if resp.error
          (do (set err resp.error) (set done? true))
          (let [status resp.status]
            (if (and (>= status 300) (< status 400))
                (let [loc (header-get resp.headers :location)]
                  (if (not loc)
                      (do (set err (.. "redirect " status " without Location header"))
                          (set done? true))
                      (>= redirects MAX-REDIRECTS)
                      (do (set err "too many redirects") (set done? true))
                      (do (set current loc) (set redirects (+ redirects 1)))))
                (= status 200)
                (do (set body resp.body) (set done? true))
                (do (set err (.. "HTTP " status)) (set done? true)))))))
  (values body err))

(fn fetch-latest-tag []
  "Return (values tag nil) for the newest published release, else (nil err)."
  (let [(body err) (http-get API-LATEST)]
    (if (not body)
        (values nil err)
        (let [(ok? data) (pcall json.decode body)]
          (if (and ok? (= (type data) :table) data.tag_name)
              (values data.tag_name nil)
              (values nil "could not parse latest release metadata"))))))

(fn expected-hash [sums asset]
  "Look up the SHA-256 hex digest for `asset` in a SHA256SUMS body."
  (var found nil)
  (each [line (string.gmatch sums "[^\n]+")]
    (let [(hash name) (string.match line "^(%x+)%s+%*?(.+)$")]
      (when (and name (= name asset)) (set found hash))))
  found)

(fn search-path [name]
  "Locate `name` on PATH, returning the first executable match (absolute)."
  (let [path-env (or (os.getenv :PATH) "")]
    (var found nil)
    (each [dir (string.gmatch path-env "[^:]+")]
      (when (not found)
        (let [candidate (.. dir "/" name)]
          (when (path.file-exists? candidate)
            (set found (path.realpath candidate))))))
    found))

(fn resolve-self []
  "Absolute path of the running fen binary. Prefers the launcher-surfaced
   `arg.exe`; otherwise resolves arg[0] against cwd or PATH."
  (let [a (or _G.arg {})]
    (if (and a.exe (not= a.exe ""))
        a.exe
        (let [argv0 (. a 0)]
          (if (not argv0) nil
              (string.find argv0 "/") (path.realpath argv0)
              (search-path argv0))))))

(fn install-binary [target body]
  "Write `body` to a temp file beside `target`, mark it executable, then
   atomically rename it into place. Returns (values true nil) or (nil err)."
  (let [dir (path.dirname target)
        tmp (.. dir "/.fen-update." (os.time) ".tmp")
        f (io.open tmp "wb")]
    (if (not f)
        (values nil (.. "cannot write to " dir
                        " (need write permission — try sudo, or the binary "
                        "lives in a read-only location)"))
        (do
          (f:write body)
          (f:close)
          (os.execute (.. "chmod +x " (path.shell-quote tmp)))
          (let [(ok? rename-err) (os.rename tmp target)]
            (if ok?
                (values true nil)
                (do (os.remove tmp)
                    (values nil (.. "could not replace " target ": "
                                    (tostring rename-err))))))))))

(fn apply-update! [target tag slug]
  "Download, verify, and install the release asset. Returns an exit code."
  (let [asset (.. "fen-" tag "-" slug)
        (body body-err) (http-get (.. DL-BASE "/" tag "/" asset))]
    (if (not body)
        (do (oops (.. "download failed: " body-err)) 1)
        (let [(sums sums-err) (http-get (.. DL-BASE "/" tag "/SHA256SUMS"))]
          (if (not sums)
              (do (oops (.. "could not fetch checksums: " sums-err)) 1)
              (let [expected (expected-hash sums asset)]
                (if (not expected)
                    (do (oops (.. "no checksum for " asset " in SHA256SUMS")) 1)
                    (not= (sha256.hex-digest body) expected)
                    (do (oops (.. "checksum mismatch for " asset
                                  "; refusing to install")) 1)
                    (let [(ok? install-err) (install-binary target body)]
                      (if ok?
                          (do (say (.. "updated to " tag "; restart fen to use it")) 0)
                          (do (oops install-err) 1))))))))))

;; @doc fen.update.run!
;; kind: function
;; signature: (run! argv) -> exit-code
;; summary: Replace the running release binary with the latest GitHub release; refuses source/dev builds.
;; tags: update self-update distribution
(fn M.run! [_argv]
  (let [info (version-info)
        current (or info.version "unknown")
        source (or info.source "unknown")]
    (if (not (or (= source "nix") (= source "make")))
        (do (oops (.. "fen update only manages released single-file binaries "
                      "(this build's source is '" source "'); update with "
                      "git pull / nix build .#fen, or reinstall via install.sh"))
            1)
        (not (string.match current "^v%d"))
        (do (oops (.. "this looks like an unreleased local build (" current
                      "); fen update only replaces tagged release binaries"))
            1)
        (let [(slug slug-err) (detect-slug)]
          (if (not slug)
              (do (oops slug-err) 1)
              (do
                (say "checking for the latest release...")
                (let [(tag tag-err) (fetch-latest-tag)]
                  (if (not tag)
                      (do (oops (.. "could not check for updates: " tag-err)) 1)
                      (= tag current)
                      (do (say (.. "already up to date (" current ")")) 0)
                      (let [target (resolve-self)]
                        (if (not target)
                            (do (oops "could not locate the running fen binary") 1)
                            (do (say (.. "updating " current " -> " tag " (" slug ")"))
                                (apply-update! target tag slug))))))))))))

;; Exposed for unit tests; not part of the stable public surface.
(set M.arch->slug arch->slug)
(set M.expected-hash expected-hash)

M
