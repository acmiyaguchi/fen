(local json (require :util.json))

(fn ok [output] {:ok? true :output output})
(fn err [message] {:ok? false :output (.. "error: " message) :error message})

(fn run-bash [{: cmd}]
  (if (or (not cmd) (= cmd ""))
      (err "missing 'cmd'")
      (let [pipe (io.popen (.. cmd " 2>&1") :r)]
        (if (not pipe) (err "io.popen failed")
            (let [out (pipe:read :*a)
                  (_ _ code) (pipe:close)]
              (ok (.. (or out "") "\n[exit " (tostring (or code 0)) "]")))))))

(fn run-read [{: path}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :r)]
        (if (not f) (err open-err)
            (let [content (f:read :*a)]
              (f:close)
              (ok content))))))

(fn run-write [{: path : content}]
  (if (or (not path) (= path ""))
      (err "missing 'path'")
      (let [(f open-err) (io.open path :w)]
        (if (not f) (err open-err)
            (do (f:write (or content ""))
                (f:close)
                (ok (.. "wrote " (tostring (length (or content ""))) " bytes to " path)))))))

(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn run-ls [{: path}]
  (let [target (or path ".")
        pipe (io.popen (.. "ls -1 " (shellquote target) " 2>&1") :r)]
    (if (not pipe) (err "io.popen failed")
        (let [out (pipe:read :*a)]
          (pipe:close)
          (ok (or out ""))))))

(local registry
  {:bash {:description "Run a shell command and return combined stdout/stderr."
          :parameters {:type :object
                       :properties {:cmd {:type :string
                                          :description "Shell command to run"}}
                       :required [:cmd]}
          :execute run-bash}
   :read {:description "Read the entire contents of a file."
          :parameters {:type :object
                       :properties {:path {:type :string :description "File path"}}
                       :required [:path]}
          :execute run-read}
   :write {:description "Write content to a file (overwrites)."
           :parameters {:type :object
                        :properties {:path {:type :string :description "File path"}
                                     :content {:type :string :description "Content to write"}}
                        :required [:path :content]}
           :execute run-write}
   :ls {:description "List entries in a directory."
        :parameters {:type :object
                     :properties {:path {:type :string :description "Directory (defaults to .)"}}
                     :required []}
        :execute run-ls}})

(fn descriptors [reg]
  "Translate the registry into OpenAI tool descriptors."
  (let [out []]
    (each [name spec (pairs reg)]
      (table.insert out {:type :function
                         :function {: name
                                    :description spec.description
                                    :parameters spec.parameters}}))
    out))

(fn execute [reg name args-json]
  (let [spec (. reg name)]
    (if (not spec) (err (.. "unknown tool: " name))
        (let [(ok? value)
              (if (or (= args-json nil) (= args-json ""))
                  (values true {})
                  (pcall json.decode args-json))]
          (if (not ok?)
              (err (.. "bad json args: " (tostring value)))
              (spec.execute value))))))

{: registry : descriptors : execute}
