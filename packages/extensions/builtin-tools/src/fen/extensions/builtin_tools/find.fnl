(local util (require :fen.extensions.builtin_tools.util))
(local truncate (require :fen.extensions.builtin_tools.truncate))

(fn run-find [{: pattern : path : limit}]
  (if (or (not pattern) (= pattern ""))
      (util.err "missing 'pattern'")
      (let [target (or path ".")
            cap (util.int-arg limit 200)
            cmd (.. "find " (util.shellquote target)
                    " -name " (util.shellquote pattern)
                    " -print 2>&1 | head -n " (tostring cap))
            pipe (io.popen cmd :r)]
        (if (not pipe) (util.err "io.popen failed")
            (let [out (or (pipe:read :*a) "")
                  (capped _) (truncate.truncate-head out nil)]
              (pipe:close)
              (util.ok capped))))))

{:name :find
 :label "Find"
 :snippet "Find files by name pattern"
 :description "Locate files by name glob, recursively."
 :parameters {:type :object
              :properties {:pattern {:type :string
                                     :description "Glob pattern, e.g. *.fnl"}
                           :path {:type :string
                                  :description "Directory (default: .)"}
                           :limit {:type :integer
                                   :description "Maximum results (default 200)"}}
              :required [:pattern]}
 :execute run-find}
