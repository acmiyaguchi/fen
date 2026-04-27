;; Unified resource loader for system prompt inputs.
;;
;; It centralizes the filesystem probes that used to be split between
;; main.fnl and core.skills: cwd, SYSTEM.md / APPEND_SYSTEM.md overlays,
;; project instruction files (AGENTS.md / CLAUDE.md), and skills.

(local skills (require :core.skills))
(local log (require :util.log))

(local M {})

(fn home []
  (or (os.getenv :HOME) "/tmp"))

(fn config-dir []
  (let [xdg (os.getenv :XDG_CONFIG_HOME)]
    (if (and xdg (not= xdg ""))
        (.. xdg "/agent-fennel")
        (.. (home) "/.config/agent-fennel"))))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn dirname [path]
  (let [d (string.match path "^(.*)/[^/]+$")]
    (if (not d) "."
        (= d "") "/"
        d)))

(fn basename [path]
  (or (string.match path "([^/]+)$") path))

(fn pwd-physical [dir]
  (let [pipe (io.popen (.. "cd " (shell-quote dir) " 2>/dev/null && pwd -P") :r)]
    (when pipe
      (let [out (pipe:read :*l)]
        (pipe:close)
        out))))

(fn cwd []
  ;; PWD preserves the user's symlink spelling, matching the existing session
  ;; slug behavior. Canonical paths are used only for de-duping resources.
  (or (os.getenv :PWD) (pwd-physical ".") "."))

(fn file-exists? [path]
  (let [pipe (io.popen (.. "test -f " (shell-quote path) " && echo y") :r)]
    (if (not pipe)
        false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out "y")))))

(fn dir-exists? [path]
  (let [pipe (io.popen (.. "test -d " (shell-quote path) " && echo y") :r)]
    (if (not pipe)
        false
        (let [out (pipe:read :*l)]
          (pipe:close)
          (= out "y")))))

(fn realpath [path]
  (let [dir (dirname path)
        base (basename path)
        real-dir (pwd-physical dir)]
    (if real-dir (.. real-dir "/" base) path)))

(fn read-file [path]
  (let [(f err) (io.open path :r)]
    (if (not f)
        (do (log.warn (.. "resources: cannot read " path ": " (tostring err)))
            nil)
        (let [s (f:read :*a)]
          (f:close)
          s))))

(fn first-existing-file [dir names]
  (var found nil)
  (each [_ name (ipairs names)]
    (let [path (.. dir "/" name)]
      (when (and (not found) (file-exists? path))
        (set found path))))
  found)

(fn ancestors-root-to-leaf [start]
  (let [physical (or (pwd-physical start) start)
        parts []]
    (var cur physical)
    (var done? false)
    (while (not done?)
      (table.insert parts 1 cur)
      (if (= cur "/")
          (set done? true)
          (set cur (dirname cur))))
    parts))

(fn load-project-context-files [start-cwd]
  "Load global context, then cwd ancestors root-to-leaf. Per directory,
   AGENTS.md wins over CLAUDE.md."
  (let [out []
        seen {}]
    (each [_ dir (ipairs [(.. (home) "/.pi/agent") (config-dir)])]
      (let [path (first-existing-file dir ["AGENTS.md" "CLAUDE.md"])]
        (when path
          (let [canon (realpath path)]
            (when (not (. seen canon))
              (tset seen canon true)
              (table.insert out {:path canon :content (read-file path)}))))))
    (each [_ dir (ipairs (ancestors-root-to-leaf start-cwd))]
      (let [path (first-existing-file dir ["AGENTS.md" "CLAUDE.md"])]
        (when path
          (let [canon (realpath path)]
            (when (not (. seen canon))
              (tset seen canon true)
              (table.insert out {:path canon :content (read-file path)}))))))
    out))

(fn load-system-file [start-cwd filename]
  "Find the effective SYSTEM.md/APPEND_SYSTEM.md. Project .agent-fennel files
   beat global config; among project ancestors, nearest cwd wins."
  (let [candidates []]
    (table.insert candidates (.. (config-dir) "/" filename))
    (each [_ dir (ipairs (ancestors-root-to-leaf start-cwd))]
      (table.insert candidates (.. dir "/.agent-fennel/" filename)))
    (var chosen nil)
    (each [_ path (ipairs candidates)]
      (when (file-exists? path)
        (set chosen path)))
    (when chosen
      {:path (realpath chosen) :content (read-file chosen)})))

(fn scan [opts]
  (let [c (cwd)
        extra (or (?. opts :extra-skill-paths)
                  (?. opts :extra-skill-dirs)
                  [])]
    {:cwd c
     :context-files (load-project-context-files c)
     :skills (skills.discover extra)
     :system-md (load-system-file c "SYSTEM.md")
     :append-system-md (load-system-file c "APPEND_SYSTEM.md")}))

(fn M.make [opts]
  (let [loader {:opts (or opts {})}]
    (fn loader.reload [self]
      (let [fresh (scan self.opts)]
        (each [k v (pairs fresh)]
          (tset self k v))
        self))
    (loader.reload loader)))

(set M.cwd cwd)
(set M.config-dir config-dir)
(set M.load-project-context-files load-project-context-files)
(set M.load-system-file load-system-file)
(set M._ancestors-root-to-leaf ancestors-root-to-leaf)

M
