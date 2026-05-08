;; Extension rock/dependency helpers.
;;
;; This module owns the fen-managed rocks tree convention and the
;; `fen ext build <dir>` wrapper. The single-file runtime embeds LuaRocks as
;; Lua modules plus a statically registered lfs module, so extension builds do
;; not depend on a system LuaRocks executable.

(local path (require :fen.util.path))

(local M {})

;; @doc fen.core.extensions.rocks.default-tree
;; kind: function
;; signature: (default-tree) -> string
;; summary: Return the fen-managed LuaRocks tree, honoring FEN_ROCKS_TREE before falling back to the user data directory.
;; tags: extensions rocks paths
(fn M.default-tree []
  (let [override (os.getenv :FEN_ROCKS_TREE)]
    (if (and override (not= override ""))
        override
        (.. (path.data-home) "/fen/rocks"))))

;; @doc fen.core.extensions.rocks.lua-path-fragment
;; kind: function
;; signature: (lua-path-fragment tree) -> string
;; summary: Build the package.path fragment that exposes pure-Lua modules installed in a fen rocks tree.
;; tags: extensions rocks paths
(fn M.lua-path-fragment [tree]
  (.. tree "/share/lua/5.4/?.lua;"
      tree "/share/lua/5.4/?/init.lua"))

;; @doc fen.core.extensions.rocks.lua-cpath-fragment
;; kind: function
;; signature: (lua-cpath-fragment tree) -> string
;; summary: Build the package.cpath fragment that exposes native Lua 5.4 modules installed in a fen rocks tree.
;; tags: extensions rocks paths
(fn M.lua-cpath-fragment [tree]
  (.. tree "/lib/lua/5.4/?.so"))

(fn prepend-search-path [current fragment]
  (if (or (not current) (= current ""))
      (.. fragment ";;")
      (.. fragment ";" current)))

;; @doc fen.core.extensions.rocks.prepend-tree!
;; kind: function
;; signature: (prepend-tree! ?tree) -> true|nil
;; summary: Prepend an existing fen rocks tree to package.path and package.cpath so extension dependencies can be required.
;; tags: extensions rocks paths
(fn M.prepend-tree! [?tree]
  "Prepend a rocks tree to package.path/package.cpath when the tree exists."
  (let [tree (or ?tree (M.default-tree))]
    (when (path.dir-exists? tree)
      (set package.path (prepend-search-path package.path (M.lua-path-fragment tree)))
      (set package.cpath (prepend-search-path package.cpath (M.lua-cpath-fragment tree)))
      true)))

(fn command-output-lines [cmd]
  (let [p (io.popen cmd)
        out []]
    (when p
      (each [line (p:lines)]
        (table.insert out line))
      (p:close))
    out))

;; @doc fen.core.extensions.rocks.rockspecs
;; kind: function
;; signature: (rockspecs dir) -> [string]
;; summary: List top-level .rockspec files in an extension directory for build and missing-dependency diagnostics.
;; tags: extensions rocks build
(fn M.rockspecs [dir]
  (let [cmd (.. "find " (path.shell-quote dir)
                " -maxdepth 1 -type f -name '*.rockspec' -print")]
    (command-output-lines cmd)))

;; @doc fen.core.extensions.rocks.rockspec-present?
;; kind: function
;; signature: (rockspec-present? dir) -> boolean
;; summary: Return true when an extension directory contains at least one rockspec for fen ext build guidance.
;; tags: extensions rocks build
(fn M.rockspec-present? [dir]
  (> (length (M.rockspecs dir)) 0))

;; @doc fen.core.extensions.rocks.single-rockspec
;; kind: function
;; signature: (single-rockspec dir) -> rockspec|nil, err|nil
;; summary: Require exactly one rockspec in an extension directory and return a user-facing error when zero or multiple are present.
;; tags: extensions rocks build
(fn M.single-rockspec [dir]
  (let [items (M.rockspecs dir)]
    (if (= (length items) 1)
        (values (. items 1) nil)
        (= (length items) 0)
        (values nil (.. "no .rockspec found in " dir))
        (values nil (.. "multiple .rockspec files found in " dir
                        "; keep exactly one for `fen ext build` v1")))))

;; @doc fen.core.extensions.rocks.parse-missing-module
;; kind: function
;; signature: (parse-missing-module err) -> string|nil
;; summary: Extract the missing module name from Lua's standard require error so loader failures can suggest installation actions.
;; tags: extensions rocks diagnostics
(fn M.parse-missing-module [err]
  "Extract X from Lua's standard `module 'X' not found` require error."
  (let [s (tostring err)]
    (or (string.match s "module '([^']+)' not found")
        (string.match s "module \"([^\"]+)\" not found"))))

;; @doc fen.core.extensions.rocks.manual-install-command
;; kind: function
;; signature: (manual-install-command module-name ?tree) -> string
;; summary: Format the LuaRocks install command users can run to install a missing dependency into the fen rocks tree.
;; tags: extensions rocks diagnostics
(fn M.manual-install-command [module-name ?tree]
  (.. "luarocks install --tree " (path.shell-quote (or ?tree (M.default-tree)))
      " " (path.shell-quote module-name)))

;; @doc fen.core.extensions.rocks.build-command
;; kind: function
;; signature: (build-command dir) -> string
;; summary: Format the fen ext build command for an extension directory that declares a rockspec.
;; tags: extensions rocks build
(fn M.build-command [dir]
  (.. "fen ext build " (path.shell-quote dir)))

(fn shared-libs-message [spec]
  (let [shared (or (?. spec :manifest :requires-shared-libs)
                   (?. spec :manifest :requiresSharedLibs)
                   [])]
    (if (> (length shared) 0)
        (.. "\nRequired shared libraries declared by manifest: "
            (table.concat shared ", "))
        "")))

;; @doc fen.core.extensions.rocks.missing-module-message
;; kind: function
;; signature: (missing-module-message spec module-name) -> string
;; summary: Build an actionable loader error for one missing Lua module, preferring fen ext build when the extension has a rockspec.
;; tags: extensions rocks diagnostics
(fn M.missing-module-message [spec module-name]
  (let [dir spec.dir
        shared-msg (shared-libs-message spec)]
    (if (M.rockspec-present? dir)
        (.. "missing Lua module '" module-name "' while loading extension " spec.name
            "; run: " (M.build-command dir) shared-msg)
        (.. "missing Lua module '" module-name "' while loading extension " spec.name
            "; install module " module-name " ("
            (M.manual-install-command module-name) ")" shared-msg))))

;; @doc fen.core.extensions.rocks.missing-modules-message
;; kind: function
;; signature: (missing-modules-message spec modules) -> string
;; summary: Build an actionable loader error for declared missing modules, including shared-library hints from the manifest.
;; tags: extensions rocks diagnostics
(fn M.missing-modules-message [spec modules]
  (let [names []]
    (each [_ m (ipairs modules)] (table.insert names (tostring m)))
    (let [joined (table.concat names ", ")]
      (if (M.rockspec-present? spec.dir)
          (.. "missing Lua modules [" joined "] while loading extension " spec.name
              "; run: " (M.build-command spec.dir)
              (shared-libs-message spec))
          (.. "missing Lua modules [" joined "] while loading extension " spec.name
              "; install them into the fen rocks tree, e.g. "
              (M.manual-install-command (. names 1))
              (shared-libs-message spec))))))

(fn lua-exe-for-luarocks []
  ;; LuaRocks insists cfg.variables.LUA is set even for pure-Lua local builds.
  ;; A user-provided LUA wins for native rocks. Otherwise use /bin/false as a
  ;; harmless placeholder: pure-Lua rocks do not execute it, and native rocks
  ;; should fail clearly unless the user points LuaRocks at a development Lua.
  (let [env-lua (os.getenv :LUA)]
    (if (and env-lua (not= env-lua ""))
        env-lua
        "/bin/false")))

(fn run-bundled-luarocks [dir rockspec tree]
  (let [(ok-cmd? cmd) (pcall require :luarocks.cmd)
        (ok-lfs? lfs) (pcall require :lfs)]
    (if (not (and ok-cmd? ok-lfs?))
        nil
        (let [old-cwd (lfs.currentdir)
              rockspec-name (path.basename rockspec)]
          (lfs.chdir dir)
          (let [old-arg0 (?. _G :arg 0)]
            (when _G.arg (tset _G.arg 0 (lua-exe-for-luarocks)))
            (let [(ok? err) (xpcall
                              #(cmd.run_command
                                 "fen bundled LuaRocks"
                                 {:make :luarocks.cmd.make}
                                 :luarocks.cmd.external
                                 :make
                                 :--tree tree
                                 rockspec-name
                                 (.. "LUA=" (lua-exe-for-luarocks)))
                              debug.traceback)]
              (when _G.arg (tset _G.arg 0 old-arg0))
              (when old-cwd (pcall lfs.chdir old-cwd))
              (if ok?
                  0
                  (do (io.stderr:write (.. "bundled luarocks failed: "
                                          (tostring err) "\n"))
                      1))))))))

;; @doc fen.core.extensions.rocks.build!
;; kind: function
;; signature: (build! dir) -> exit-code
;; summary: Build an extension rockspec into the fen rocks tree using bundled LuaRocks when available, returning process-style exit codes.
;; tags: extensions rocks build
(fn M.build! [dir]
  (let [(rockspec err) (M.single-rockspec dir)
        tree (M.default-tree)]
    (if err
        (do (io.stderr:write (.. err "\n")) 2)
        (let [bundled-rc (run-bundled-luarocks dir rockspec tree)]
          (if bundled-rc
              bundled-rc
              (do (io.stderr:write "bundled LuaRocks is unavailable in this fen runtime; run `fen ext build` with the Nix-built fen binary\n")
                  127))))))

M
