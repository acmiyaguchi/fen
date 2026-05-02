;; Extension rock/dependency helpers.
;;
;; This module owns the fen-managed rocks tree convention and the
;; `fen ext build <dir>` wrapper. In the single-file runtime, LuaRocks is
;; embedded as Lua modules plus a statically registered lfs module. Source-checkout/package
;; runs without bundled LuaRocks fall back to system `luarocks`.

(local path (require :fen.util.path))

(local M {})

(fn M.default-tree []
  (let [override (os.getenv :FEN_ROCKS_TREE)]
    (if (and override (not= override ""))
        override
        (.. (path.data-home) "/fen/rocks"))))

(fn M.lua-path-fragment [tree]
  (.. tree "/share/lua/5.4/?.lua;"
      tree "/share/lua/5.4/?/init.lua"))

(fn M.lua-cpath-fragment [tree]
  (.. tree "/lib/lua/5.4/?.so"))

(fn prepend-search-path [current fragment]
  (if (or (not current) (= current ""))
      (.. fragment ";;")
      (.. fragment ";" current)))

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

(fn M.rockspecs [dir]
  (let [cmd (.. "find " (path.shell-quote dir)
                " -maxdepth 1 -type f -name '*.rockspec' -print")]
    (command-output-lines cmd)))

(fn M.rockspec-present? [dir]
  (> (length (M.rockspecs dir)) 0))

(fn M.single-rockspec [dir]
  (let [items (M.rockspecs dir)]
    (if (= (length items) 1)
        (values (. items 1) nil)
        (= (length items) 0)
        (values nil (.. "no .rockspec found in " dir))
        (values nil (.. "multiple .rockspec files found in " dir
                        "; keep exactly one for `fen ext build` v1")))))

(fn command-output-line [cmd]
  (let [p (io.popen cmd)]
    (when p
      (let [out (p:read :*l)]
        (p:close)
        out))))

(fn M.command-exists? [cmd]
  (= (command-output-line
       (.. "command -v " (path.shell-quote cmd) " >/dev/null 2>&1 && printf yes"))
     "yes"))

(fn M.parse-missing-module [err]
  "Extract X from Lua's standard `module 'X' not found` require error."
  (let [s (tostring err)]
    (or (string.match s "module '([^']+)' not found")
        (string.match s "module \"([^\"]+)\" not found"))))

(fn M.manual-install-command [module-name ?tree]
  (.. "luarocks install --tree " (path.shell-quote (or ?tree (M.default-tree)))
      " " (path.shell-quote module-name)))

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

(fn M.missing-module-message [spec module-name]
  (let [dir spec.dir
        shared-msg (shared-libs-message spec)]
    (if (M.rockspec-present? dir)
        (.. "missing Lua module '" module-name "' while loading extension " spec.name
            "; run: " (M.build-command dir) shared-msg)
        (.. "missing Lua module '" module-name "' while loading extension " spec.name
            "; install module " module-name " ("
            (M.manual-install-command module-name) ")" shared-msg))))

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

(fn os-exit-code [a b c]
  (if (= (type a) :number) a
      (= a true) 0
      (= (type c) :number) c
      1))

(fn run-system-luarocks [dir rockspec tree]
  (let [cmd (.. "cd " (path.shell-quote dir)
                " && luarocks make --tree " (path.shell-quote tree)
                " " (path.shell-quote (path.basename rockspec)))
        (a b c) (os.execute cmd)]
    (os-exit-code a b c)))

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

(fn M.build! [dir]
  (let [(rockspec err) (M.single-rockspec dir)
        tree (M.default-tree)]
    (if err
        (do (io.stderr:write (.. err "\n")) 2)
        (let [bundled-rc (run-bundled-luarocks dir rockspec tree)]
          (if bundled-rc
              bundled-rc
              (if (M.command-exists? :luarocks)
                  (run-system-luarocks dir rockspec tree)
                  (do (io.stderr:write "luarocks not found on PATH and bundled luarocks is unavailable\n")
                      127)))))))

M
