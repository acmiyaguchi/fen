;; Flat-layout first-party extension searcher.
;;
;; After issue #67 Phase A, manifest-shaped extensions live as flat sources
;; under <ext-root>/<kebab>/{manifest.fnl,init.fnl,...} with no
;; `fen/extensions/<snake>/` mirror. The runtime contract still uses
;; `require :fen.extensions.<snake>...`, so this module provides a Lua
;; searcher that maps that namespace back to the flat-source location.
;;
;; Lua's `?`-substitution can't strip the `fen/extensions/<snake>/` prefix
;; from the module name, so we register a real searcher rather than just
;; appending entries to package.path / fennel.path.
;;
;; Consumers:
;;   - tests/busted-helper.lua — installs the searcher with the workspace
;;     flat root so test files can `(require :fen.extensions.<snake>...)`
;;   - packages/fen/fen.c   — installs the searcher with --extension-root
;;     paths so the single-file binary picks up edits to flat sources

(local M {})

(fn read-all [path]
  (let [(f err) (io.open path :r)]
    (if (not f)
        (values nil err)
        (let [data (f:read :*a)]
          (f:close)
          (values data nil)))))

(fn file-exists? [path]
  (let [f (io.open path :r)]
    (if f (do (f:close) true) false)))

(fn parse-manifest-name [text]
  "Manifests are literal tables; text-match :name with no Fennel eval."
  (when text
    (or (string.match text ":name%s+:([%w_%-]+)")
        (string.match text ":name%s+\"([^\"]+)\"")
        (string.match text "name%s*=%s*\"([^\"]+)\""))))

(fn manifest-snake-of [dir]
  "Read <dir>/manifest.{fnl,lua} and return its :name, or nil."
  (let [candidates [(.. dir "/manifest.fnl") (.. dir "/manifest.lua")]]
    (var found nil)
    (each [_ candidate (ipairs candidates)]
      (when (and (not found) (file-exists? candidate))
        (let [(text _err) (read-all candidate)]
          (when text
            (set found (parse-manifest-name text))))))
    found))

(fn list-children [dir]
  "Return absolute paths of immediate children of `dir` via shell `find`.
   Skips dotfiles/underscore-prefixed entries during the caller's filter."
  (let [out []
        cmd (.. "find " (string.format "%q" dir)
                " -mindepth 1 -maxdepth 1 -type d 2>/dev/null")
        (ok? p) (pcall io.popen cmd)]
    (when (and ok? p)
      (each [line (p:lines)]
        (table.insert out line))
      (p:close))
    out))

(fn M.build-map [roots]
  "Walk each root for child manifest dirs and return a snake->dir map.
   First snake wins across roots, matching the loader's first-party
   discovery precedence."
  (let [map {}]
    (each [_ root (ipairs (or roots []))]
      (each [_ child (ipairs (list-children root))]
        (let [base (string.match child "([^/]+)$")
              first-char (string.sub (or base "") 1 1)]
          (when (and base
                     (not= first-char ".")
                     (not= first-char "_"))
            (let [snake (manifest-snake-of child)]
              (when (and snake (= nil (. map snake)))
                (tset map snake child)))))))
    map))

(fn resolve-fnl [map modname]
  "Return the flat .fnl path for `fen.extensions.<snake>[.<rest>]` or nil."
  (let [(snake rest) (string.match modname "^fen%.extensions%.([^.]+)%.?(.*)$")
        dir (and snake (. map snake))]
    (when dir
      (if (or (not rest) (= rest ""))
          (let [c (.. dir "/init.fnl")]
            (when (file-exists? c) c))
          (let [sub (string.gsub rest "%." "/")
                a (.. dir "/" sub ".fnl")
                b (.. dir "/" sub "/init.fnl")]
            (if (file-exists? a) a
                (file-exists? b) b
                nil))))))

(fn M.make-searcher [fennel map]
  "Build a Lua package.searchers entry that resolves flat extensions.
   Defers to package.preload[modname] when set so callers (notably tests
   that stub modules via package.preload) can override resolution."
  (fn [modname]
    (if (. package.preload modname)
        nil
        (let [path (resolve-fnl map modname)]
          (if (not path)
              nil
              (values (fn [] (fennel.dofile path)) path))))))

(fn M.install! [opts]
  "Convenience installer. opts.roots is the list of extension roots to
   walk; opts.fennel is the fennel module; opts.position is the
   package.searchers slot to insert at (default 2). Returns the inserted
   searcher fn for callers that want to reference or remove it."
  (let [opts (or opts {})
        roots (or opts.roots [])
        fennel (or opts.fennel (require :fennel))
        position (or opts.position 2)
        map (M.build-map roots)
        searcher (M.make-searcher fennel map)
        searchers (or package.searchers package.loaders)]
    (table.insert searchers position searcher)
    searcher))

M
