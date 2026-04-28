(local util (require :core.tools.util))
(local truncate (require :core.tools.truncate))

(fn run-ls [{: path : limit}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (util.shellquote target) " 2>&1") :r)]
    (if (not pipe) (util.err "io.popen failed")
        (let [out (or (pipe:read :*a) "")
              take (util.int-arg limit nil)]
          (pipe:close)
          (if (and take (> take 0))
              (let [lines []]
                (var taken 0)
                (each [line (string.gmatch out "[^\n]+")]
                  (when (< taken take)
                    (table.insert lines line)
                    (set taken (+ taken 1))))
                (util.ok (table.concat lines "\n")))
              (let [(capped _) (truncate.truncate-head out nil)]
                (util.ok capped)))))))

{:name :ls
 :label "Ls"
 :snippet "List directory contents"
 :description "List entries in a directory."
 :parameters {:type :object
              :properties {:path {:type :string :description "Directory (defaults to .)"}
                           :limit {:type :integer
                                   :description "Maximum number of entries to return"}}}
 :execute run-ls}
