;; Unified resource loader for system prompt inputs.
;;
;; It centralizes the filesystem probes that used to be split between
;; main.fnl and core.prompt.skills: cwd, SYSTEM.md / APPEND_SYSTEM.md overlays,
;; project instruction files (AGENTS.md / CLAUDE.md), and skills.

(local skills (require :core.prompt.skills))
(local log (require :util.log))
(local path (require :util.path))

(local M {})

(fn config-dir []
  (path.config-dir :agent-fennel))

(fn read-file [file-path]
  (let [(f err) (io.open file-path :r)]
    (if (not f)
        (do (log.warn (.. "resources: cannot read " file-path ": " (tostring err)))
            nil)
        (let [s (f:read :*a)]
          (f:close)
          s))))

(fn first-existing-file [dir names]
  (var found nil)
  (each [_ name (ipairs names)]
    (let [candidate (.. dir "/" name)]
      (when (and (not found) (path.file-exists? candidate))
        (set found candidate))))
  found)

(fn load-project-context-files [start-cwd]
  "Load global context, then cwd ancestors root-to-leaf. Per directory,
   AGENTS.md wins over CLAUDE.md."
  (let [out []
        seen {}]
    (each [_ dir (ipairs [(.. (path.home) "/.pi/agent") (config-dir)])]
      (let [hit (first-existing-file dir ["AGENTS.md" "CLAUDE.md"])]
        (when hit
          (let [canon (path.realpath hit)]
            (when (not (. seen canon))
              (tset seen canon true)
              (table.insert out {:path canon :content (read-file hit)}))))))
    (each [_ dir (ipairs (path.ancestors-root-to-leaf start-cwd))]
      (let [hit (first-existing-file dir ["AGENTS.md" "CLAUDE.md"])]
        (when hit
          (let [canon (path.realpath hit)]
            (when (not (. seen canon))
              (tset seen canon true)
              (table.insert out {:path canon :content (read-file hit)}))))))
    out))

(fn load-system-file [start-cwd filename]
  "Find the effective SYSTEM.md/APPEND_SYSTEM.md. Project .agent-fennel files
   beat global config; among project ancestors, nearest cwd wins."
  (let [candidates []]
    (table.insert candidates (.. (config-dir) "/" filename))
    (each [_ dir (ipairs (path.ancestors-root-to-leaf start-cwd))]
      (table.insert candidates (.. dir "/.agent-fennel/" filename)))
    (var chosen nil)
    (each [_ candidate (ipairs candidates)]
      (when (path.file-exists? candidate)
        (set chosen candidate)))
    (when chosen
      {:path (path.realpath chosen) :content (read-file chosen)})))

(fn scan [opts]
  (let [c (path.cwd)
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

(set M.cwd path.cwd)
(set M.config-dir config-dir)
(set M.load-project-context-files load-project-context-files)
(set M.load-system-file load-system-file)
(set M._ancestors-root-to-leaf path.ancestors-root-to-leaf)

M
