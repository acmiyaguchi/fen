;; Guards against rockspec/source drift: every package's hand-maintained
;; build.install.lua list must match the Fennel modules its sources imply.
;;
;; Why: rockspec install lists are enumerated by hand, but the build
;; (scripts/build/fennel-build.fnl) compiles the source tree independently of
;; them. A module that exists on disk but is missing from install.lua compiles
;; fine in the workspace yet is absent from the published rock, so a clean
;; `luarocks install` fails with `module not found` at require time (issue
;; #164). This test makes that drift fail loudly instead.
;;
;; The source -> module-name mapping below mirrors fennel-build.fnl (the
;; `/src/fen/` prefix strip, the flat-extension manifest `:name` namespace, and
;; the `/init` -> base-module rule). Keep the two in sync; the bidirectional
;; check here makes any divergence self-announcing.

(local h (require :fen.testing))
(local path (require :fen.util.path))

(fn popen-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (p:close)
    out))

(fn strip-init [mod]
  (or (string.match mod "^(.+)%.init$") mod))

;; Modules that intentionally have no 1:1 source<->install correspondence.
;; pty/tui are test-only helpers in fen-testing (pty needs native fen_pty /
;; socket / cjson) and are deliberately unpublished. bundled_data is generated
;; at build time from SKILL.md and has no .fnl source.
(local EXCEPTIONS
  {:fen.testing.pty true
   :fen.testing.tui true
   :fen.extensions.skills.bundled_data true})

;; Parse a rockspec (pure Lua data) in a sandbox and return its
;; build.install.lua table (module name -> path), or {} if absent.
(fn declared-lua-modules [rockspec-path]
  (let [src (assert (h.read-file rockspec-path) (.. "cannot read " rockspec-path))
        env {}
        chunk (assert (load src rockspec-path :t env))]
    (chunk)
    (or (?. env :build :install :lua) {})))

;; The manifest :name regexes match fennel-build.fnl's parse-manifest-name.
(fn manifest-name [pkg-dir]
  (let [text (h.read-file (.. pkg-dir "/manifest.fnl"))]
    (when text
      (or (string.match text ":name%s+:([%w_%-]+)")
          (string.match text ":name%s+\"([^\"]+)\"")))))

;; Map a source .fnl path to the Lua module name it installs as.
;; Returns nil for sources that don't map to a publishable module.
(fn source-module [src pkg-dir]
  (let [inner (string.match src "/src/fen/(.+)%.fnl$")]
    (if inner
        ;; Rock-shaped package: packages/<pkg>/src/fen/<inner>.fnl
        (strip-init (.. "fen." (string.gsub inner "/" ".")))
        ;; Flat-layout extension: <pkg-dir>/<rel>.fnl, namespaced by manifest.
        (let [snake (manifest-name pkg-dir)
              rel (string.sub src (+ 2 (length pkg-dir)) -5)]
          (when (and snake (not (string.find rel "^src/")))
            (strip-init (.. "fen.extensions." snake "." (string.gsub rel "/" "."))))))))

;; Source modules implied by a package's .fnl files (build exclusions applied).
(fn source-modules [pkg-dir]
  (let [cmd (.. "find " pkg-dir " -name '*.fnl' -type f"
                " -not -path '*/tests/*'"
                " -not -path '*/dist/*'"
                " -not -path '*/vendor/*'"
                " -not -path '*/.lrbuild/*'")
        mods {}]
    (each [_ src (ipairs (popen-lines cmd))]
      (let [mod (source-module src pkg-dir)]
        (when mod
          (tset mods mod src))))
    mods))

;; Discover every rockspec and resolve its (declared, sources) pair once, so
;; the forward and reverse checks below share the find/read work.
(local packages
  (let [out []]
    (each [_ rs (ipairs (popen-lines "find packages extensions -name '*.rockspec' -type f | sort"))]
      (table.insert out
        {:rs rs
         :declared (declared-lua-modules rs)
         :sources (source-modules (path.dirname rs))}))
    out))

;; Collect drift across all packages: for each (mod -> v) in `pick pkg`, flag it
;; when absent from `lookup pkg` and not exempt. `msg` formats the report line.
(fn drift [pick lookup msg]
  (let [problems []]
    (each [_ pkg (ipairs packages)]
      (each [mod v (pairs (pick pkg))]
        (when (and (not (. (lookup pkg) mod)) (not (. EXCEPTIONS mod)))
          (table.insert problems (msg pkg mod v)))))
    (doto problems (table.sort))))

(describe "rockspec install lists match source modules"
  (fn []
    (it "discovers rockspecs to validate"
      (fn []
        (assert.is_true (> (length packages) 0)
                        "expected to find at least one .rockspec")))

    ;; Forward: every source module must be declared (the #164 bug class).
    (it "declares every source module (no omitted modules)"
      (fn []
        (assert.are.same []
          (drift #(. $1 :sources) #(. $1 :declared)
                 (fn [pkg mod src]
                   (.. pkg.rs ": missing install entry for " mod
                       " (source " src ")"))))))

    ;; Reverse: every declared module must have a source (catches typos/stale).
    (it "has a source for every declared module (no stale entries)"
      (fn []
        (assert.are.same []
          (drift #(. $1 :declared) #(. $1 :sources)
                 (fn [pkg mod _]
                   (.. pkg.rs ": install entry " mod " has no .fnl source"))))))))
