;; Built-in Agent Skills shipped with fen itself.
;;
;; The authoring source is real Markdown under ./bundled/*/SKILL.md. Release
;; builds generate fen.extensions.skills.bundled_data from those files so the
;; single-file binary can still materialize readable skill files at runtime.

(local M {})

(fn read-all [p]
  (let [f (io.open p :r)]
    (when f
      (let [data (f:read :*a)]
        (f:close)
        data))))

(fn module-dir []
  (let [info (debug.getinfo 1 :S)
        src (or info.source "")
        file (or (string.match src "^@(.+)$")
                 (string.match src "^@embedded:(.+)$"))]
    (when file
      (or (string.match file "^(.+)/[^/]+$") "."))))

(fn source-bundled-root []
  (let [dir (module-dir)]
    (or (and dir (.. dir "/bundled"))
        "extensions/behaviors/companions/skills/bundled")))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn command-lines [cmd]
  (let [out []
        p (io.popen cmd :r)]
    (when p
      (each [line (p:lines)]
        (table.insert out line))
      (p:close))
    out))

(fn basename [p]
  (or (string.match p "([^/]+)/?$") p))

(fn load-source-skills []
  (let [root (source-bundled-root)
        out []]
    (each [_ dir (ipairs (command-lines
                           (.. "if [ -d " (shell-quote root) " ]; then find "
                               (shell-quote root)
                               " -mindepth 1 -maxdepth 1 -type d -print | sort; fi")))]
      (let [content (read-all (.. dir "/SKILL.md"))]
        (when content
          (table.insert out {:dir (basename dir)
                             :file "SKILL.md"
                             :content content}))))
    (when (> (length out) 0)
      out)))

(fn generated-skills []
  (let [(ok? data) (pcall require :fen.extensions.skills.bundled_data)]
    (when ok?
      (if (= (type data) :function) (data) data))))

(fn M.skills []
  (or (generated-skills)
      (load-source-skills)
      []))

M
