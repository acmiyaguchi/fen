;; Shared extension/package build logic.
;;
;; This is the single source of the `.fnl`->`.lua` compile rules (file walk,
;; excludes, source->output path mapping, and the generated skills data blob)
;; used by every packaging path:
;;
;;   * `scripts/build/fennel-build.fnl` (workspace + per-rock `--lrbuild`
;;     bootstrap, driven by bare `fennel`);
;;   * `fen ext build <dir>` (in-process compile via the embedded compiler,
;;     see `fen.core.extensions.rocks`).
;;
;; It depends only on `(require :fennel)` and the Lua standard library, never on
;; a built `fen` binary, so it can run before any binary exists. The fennel
;; compiler is the bootstrap floor.

(local fennel (require :fennel))

(local M {})

(fn read-all [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn write-all [path data]
  (let [f (assert (io.open path :w))]
    (f:write data)
    (f:close)))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn dirname [path]
  (or (string.match path "^(.+)/[^/]+$") "."))

(fn file-exists? [path]
  (let [f (io.open path :r)]
    (if f (do (f:close) true) false)))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (let [ok (p:close)]
      (when (not ok)
        (error (.. "command failed: " cmd))))
    out))

(fn lua-quote [s]
  (string.format "%q" s))

;; Manifest-name cache. Flat-layout extensions live at
;; extensions/**/{manifest.fnl,init.fnl,...} and the build needs the manifest's
;; :name to map flat sources to namespaced output. We read the manifest text
;; and parse :name with a regex — manifests are literal tables so no Fennel eval
;; is needed at build bootstrap time.
(local manifest-name-cache {})

(fn parse-manifest-name [text]
  (or (string.match text ":name%s+:([%w_%-]+)")
      (string.match text ":name%s+\"([^\"]+)\"")))

(fn read-manifest-name [pkg-dir]
  (when (= nil (. manifest-name-cache pkg-dir))
    (let [path (.. pkg-dir "/manifest.fnl")]
      (if (file-exists? path)
          (tset manifest-name-cache pkg-dir
                (or (parse-manifest-name (read-all path)) false))
          (tset manifest-name-cache pkg-dir false))))
  (let [v (. manifest-name-cache pkg-dir)]
    (if v v nil)))

(fn flat-extension-output [src]
  "Match flat-layout extension sources below extensions/**/<rel>.fnl where
   <rel> is under the nearest manifest-bearing package root (not under src/,
   dist/, tests/, vendor/, .lrbuild/). Returns the workspace dist path or nil."
  (let [rel-src (string.match src "^extensions/(.+)%.fnl$")]
    (when rel-src
      (var pkg-dir nil)
      (var rel nil)
      (var cur (dirname src))
      (while (and (not pkg-dir) cur (not= cur ".") (not= cur "extensions"))
        (if (file-exists? (.. cur "/manifest.fnl"))
            (do
              (set pkg-dir cur)
              (set rel (string.sub src (+ (length cur) 2) -5)))
            (set cur (dirname cur))))
      (when (and pkg-dir rel
                 (not (string.find rel "^src/"))
                 (not (string.find rel "^dist/"))
                 (not (string.find rel "^tests/"))
                 (not (string.find rel "^vendor/"))
                 (not (string.find rel "^%.lrbuild/")))
        (let [snake (read-manifest-name pkg-dir)]
          (when snake
            (.. pkg-dir "/dist/fen/extensions/" snake "/" rel ".lua")))))))

;; @doc fen.core.extensions.build.workspace-output-path
;; kind: function
;; signature: (workspace-output-path src) -> string
;; summary: Map a workspace source path to its in-tree dist/ output, handling both rock-shaped src/ trees and flat-layout extensions.
;; tags: extensions build
(fn M.workspace-output-path [src]
  (or (flat-extension-output src)
      (let [(pkg rel) (string.match src "^(.-)/src/(.*)%.fnl$")]
        (assert pkg (.. "cannot derive output path for " src))
        (.. pkg "/dist/" rel ".lua"))))

(fn strip-leading-dot [s]
  (or (string.match s "^%./(.*)") s))

(fn lrbuild-flat-output [src]
  "Flat extension source seen from within its own rock dir (cwd has
   manifest.fnl at root, sources at ./<rel>.fnl). Returns the .lrbuild path or
   nil if cwd is rock-shaped (no root manifest)."
  (when (file-exists? "manifest.fnl")
    (let [snake (read-manifest-name ".")
          rel (string.match src "^(.+)%.fnl$")]
      (when (and snake rel (not (string.match rel "^src/")))
        (.. ".lrbuild/extensions/" snake "/" rel ".lua")))))

;; @doc fen.core.extensions.build.lrbuild-output-path
;; kind: function
;; signature: (lrbuild-output-path src) -> string
;; summary: Map a source path to its per-rock .lrbuild/ output, used when a single rockspec is built in place.
;; tags: extensions build
(fn M.lrbuild-output-path [src]
  (let [src (strip-leading-dot src)]
    (or (lrbuild-flat-output src)
        (let [rel (string.match src "^src/fen/(.*)%.fnl$")]
          (assert rel (.. "cannot derive .lrbuild output path for " src))
          (.. ".lrbuild/" rel ".lua")))))

;; @doc fen.core.extensions.build.compile-file
;; kind: function
;; signature: (compile-file src output-path) -> nil
;; summary: Compile a single Fennel source file to Lua and write it to the path returned by output-path.
;; tags: extensions build
(fn M.compile-file [src output-path]
  (let [out (output-path src)
        compiled (fennel.compileString (read-all src) {:filename src})]
    (os.execute (.. "mkdir -p " (shell-quote (dirname out))))
    (write-all out compiled)))

;; @doc fen.core.extensions.build.build-files
;; kind: function
;; signature: (build-files files output-path) -> boolean
;; summary: Compile a list of source files with the given output-path mapper, printing each failure and returning whether all succeeded.
;; tags: extensions build
(fn M.build-files [files output-path]
  (var ok? true)
  (each [_ src (ipairs files)]
    (let [(ok err) (pcall M.compile-file src output-path)]
      (when (not ok)
        (print (.. "FAIL: " src))
        (print err)
        (set ok? false))))
  ok?)

;; Find both `src/`-tree sources (rock-shaped: core, util, fen, providers/*)
;; and flat-layout extension sources (manifest.fnl at the package root).
;; workspace-output-path routes each to its dist/ tree.
(set M.workspace-find
  (.. "find packages extensions -name '*.fnl' -type f"
      " -not -path '*/dist/*'"
      " -not -path '*/tests/*'"
      " -not -path '*/vendor/*'"
      " -not -path '*/.lrbuild/*'"
      " -not -path 'packages/testing/*'"
      " | sort"))

;; Lrbuild runs from a single rock package dir. Pick up flat sources at the cwd
;; root OR src/-tree sources for rock-shaped packages; lrbuild-output-path
;; routes based on whether cwd has manifest.fnl.
(set M.lrbuild-find
  (.. "find . -type f -name '*.fnl'"
      " -not -path './tests/*'"
      " -not -path './vendor/*'"
      " -not -path './.lrbuild/*'"
      " -not -path './dist/*'"
      " -not -path './src/fen/testing/macros.fnl'"
      " | sort"))

;; @doc fen.core.extensions.build.generate-bundled-skills-data
;; kind: function
;; signature: (generate-bundled-skills-data out ?root) -> nil
;; summary: Emit an embeddable Lua data module from real bundled SKILL.md sources, skipping silently when the bundled root is absent.
;; tags: extensions build
(fn M.generate-bundled-skills-data [out ?root]
  (let [root (or ?root "extensions/behaviors/companions/skills/bundled")]
    (when (file-exists? root)
      (let [dirs (command-lines (.. "find " (shell-quote root)
                                    " -mindepth 1 -maxdepth 1 -type d -print | sort"))
            lines ["return {"]]
        (each [_ dir (ipairs dirs)]
          (let [skill-path (.. dir "/SKILL.md")]
            (when (file-exists? skill-path)
              (let [name (or (string.match dir "([^/]+)$") dir)
                    content (read-all skill-path)]
                (table.insert lines
                  (.. "  { dir = " (lua-quote name)
                      ", file = \"SKILL.md\", content = " (lua-quote content) " },"))))))
        (table.insert lines "}")
        (os.execute (.. "mkdir -p " (shell-quote (dirname out))))
        (write-all out (.. (table.concat lines "\n") "\n"))))))

;; @doc fen.core.extensions.build.build-lrbuild-dir
;; kind: function
;; signature: (build-lrbuild-dir) -> boolean
;; summary: Compile the rock package in the current directory into its .lrbuild/ tree (the in-place per-rock build shared by fennel-build.fnl --lrbuild and `fen ext build`).
;; tags: extensions build
(fn M.build-lrbuild-dir []
  "Rebuild the current directory's .lrbuild/ tree from its Fennel sources.
   Runs relative to cwd, matching a rockspec build_command's working
   directory. Returns true on success."
  (os.execute "rm -rf .lrbuild")
  (let [files (command-lines M.lrbuild-find)
        ok? (M.build-files files M.lrbuild-output-path)]
    (when ok?
      ;; Only the skills rock has a bundled/ tree; other rocks skip this.
      (M.generate-bundled-skills-data ".lrbuild/extensions/skills/bundled_data.lua" "bundled"))
    ok?))

M
