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

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [data (f:read :*a)]
        (f:close)
        data))))

(fn popen-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (p:close)
    out))

(fn dirname [path]
  (or (string.match path "^(.+)/[^/]+$") "."))

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
  (let [src (assert (read-file rockspec-path) (.. "cannot read " rockspec-path))
        env {}
        chunk (assert (load src rockspec-path :t env))]
    (chunk)
    (or (?. env :build :install :lua) {})))

;; The manifest :name regexes match fennel-build.fnl's parse-manifest-name.
(fn manifest-name [pkg-dir]
  (let [text (read-file (.. pkg-dir "/manifest.fnl"))]
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

(fn all-rockspecs []
  (popen-lines "find packages extensions -name '*.rockspec' -type f | sort"))

(describe "rockspec install lists match source modules"
  (fn []
    (let [rockspecs (all-rockspecs)]
      (it "discovers rockspecs to validate"
        (fn []
          (assert.is_true (> (length rockspecs) 0)
                          "expected to find at least one .rockspec")))

      ;; Forward: every source module must be declared (the #164 bug class).
      (it "declares every source module (no omitted modules)"
        (fn []
          (let [problems []]
            (each [_ rs (ipairs rockspecs)]
              (let [pkg-dir (dirname rs)
                    declared (declared-lua-modules rs)
                    sources (source-modules pkg-dir)]
                (each [mod src (pairs sources)]
                  (when (and (not (. declared mod))
                             (not (. EXCEPTIONS mod)))
                    (table.insert problems
                      (.. rs ": missing install entry for " mod
                          " (source " src ")"))))))
            (assert.are.same [] (doto problems (table.sort))))))

      ;; Reverse: every declared module must have a source (catches typos/stale).
      (it "has a source for every declared module (no stale entries)"
        (fn []
          (let [problems []]
            (each [_ rs (ipairs rockspecs)]
              (let [pkg-dir (dirname rs)
                    declared (declared-lua-modules rs)
                    sources (source-modules pkg-dir)]
                (each [mod _ (pairs declared)]
                  (when (and (not (. sources mod))
                             (not (. EXCEPTIONS mod)))
                    (table.insert problems
                      (.. rs ": install entry " mod " has no .fnl source"))))))
            (assert.are.same [] (doto problems (table.sort)))))))))
