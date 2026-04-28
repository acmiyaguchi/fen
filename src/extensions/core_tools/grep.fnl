(local util (require :extensions.core_tools.util))
(local truncate (require :extensions.core_tools.truncate))

(fn run-grep [{: pattern : path : glob : ignore_case : literal : context : limit}]
  (if (or (not pattern) (= pattern ""))
      (util.err "missing 'pattern'")
      (let [target (or path ".")
            cap (util.int-arg limit 200)
            opts ["-rn"]]
        (when literal (table.insert opts "-F"))
        (when ignore_case (table.insert opts "-i"))
        (let [context-int (util.int-arg context nil)]
          (when (and context-int (> context-int 0))
            (table.insert opts (.. "-C " (tostring context-int)))))
        (when (and glob (not= glob ""))
          (table.insert opts (.. "--include=" (util.shellquote glob))))
        (let [cmd (.. "grep " (table.concat opts " ")
                      " -- " (util.shellquote pattern) " " (util.shellquote target)
                      " 2>&1 | head -n " (tostring cap))
              pipe (io.popen cmd :r)]
          (if (not pipe) (util.err "io.popen failed")
              (let [out (or (pipe:read :*a) "")
                    (capped _) (truncate.truncate-head out nil)]
                (pipe:close)
                (util.ok capped)))))))

{:name :grep
 :label "Grep"
 :snippet "Search file contents with regex"
 :description "Search files for a regex pattern. Recursive when path is a directory."
 :parameters {:type :object
              :properties {:pattern {:type :string :description "Pattern to search for"}
                           :path {:type :string :description "File or directory (default: .)"}
                           :glob {:type :string
                                  :description "Filename glob filter, e.g. *.fnl"}
                           :ignore_case {:type :boolean
                                         :description "Case-insensitive match"}
                           :literal {:type :boolean
                                     :description "Treat pattern as literal text, not regex"}
                           :context {:type :integer
                                     :description "Lines of context before/after each match"}
                           :limit {:type :integer
                                   :description "Maximum output lines (default 200)"}}
              :required [:pattern]}
 :execute run-grep}
