(local util (require :extensions.core_tools.util))

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (util.err "missing 'path'")
      (do
        (let [parent (string.match path "^(.*)/[^/]+$")]
          (when parent
            (os.execute (.. "mkdir -p " (util.shellquote parent)))))
        (let [(f open-err) (io.open path :w)]
          (if (not f) (util.err open-err)
              (do (f:write (or content ""))
                  (f:close)
                  (util.ok (.. "wrote " (tostring (length (or content "")))
                               " bytes to " path))))))))

{:name :write
 :label "Write"
 :snippet "Create or overwrite a file"
 :description "Write content to a file (overwrites). Creates the parent directory if missing."
 :parameters {:type :object
              :properties {:path {:type :string :description "File path"}
                           :content {:type :string :description "Content to write"}}
              :required [:path :content]}
 :execute run-write}
