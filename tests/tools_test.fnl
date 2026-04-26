;; Tests for core.tools — built-in tool implementations + registry helpers.

(local tools (require :core.tools))
(local json (require :util.json))

(fn tmpfile [content]
  "Create a fresh temp file with the given content; return its path."
  (let [path (os.tmpname)
        f (assert (io.open path :w))]
    (f:write content)
    (f:close)
    path))

(fn read-file [path]
  (let [f (assert (io.open path :r))
        content (f:read :*a)]
    (f:close)
    content))

(fn tmpdir []
  "Make a fresh temp directory; return its path. Caller cleans up."
  (let [base (os.tmpname)]
    (os.remove base)
    (assert (os.execute (.. "mkdir -p '" base "'")))
    base))

(describe "core.tools.execute"
  (fn []
    (it "returns an error for unknown tool names"
      (fn []
        (let [r (tools.execute tools.registry :no-such-tool nil)]
          (assert.is_false r.ok?)
          (assert.is_truthy (string.find r.output "unknown tool: no%-such%-tool")))))

    (it "passes empty args as {} when args-json is nil or empty string"
      (fn []
        (var seen nil)
        (let [reg {:probe {:description "" :parameters {}
                           :execute (fn [args] (set seen args) {:ok? true :output ""})}}]
          (tools.execute reg :probe nil)
          (assert.are.same {} seen)
          (set seen nil)
          (tools.execute reg :probe "")
          (assert.are.same {} seen))))

    (it "decodes JSON args before forwarding to execute"
      (fn []
        (var seen nil)
        (let [reg {:probe {:description "" :parameters {}
                           :execute (fn [args] (set seen args) {:ok? true :output ""})}}]
          (tools.execute reg :probe (json.encode {:foo :bar :n 7}))
          (assert.are.equal :bar seen.foo)
          (assert.are.equal 7 seen.n))))

    (it "returns an error on malformed JSON args"
      (fn []
        (let [reg {:probe {:description "" :parameters {}
                           :execute (fn [_] {:ok? true :output ""})}}
              r (tools.execute reg :probe "{not json")]
          (assert.is_false r.ok?)
          (assert.is_truthy (string.find r.output "bad json args")))))))

(describe "core.tools.descriptors"
  (fn []
    (it "translates the registry into OpenAI function descriptors"
      (fn []
        (let [descs (tools.descriptors tools.registry)
              names {}]
          (each [_ d (ipairs descs)]
            (assert.are.equal :function d.type)
            (assert.is_table d.function)
            (assert.is_string d.function.description)
            (assert.is_table d.function.parameters)
            (tset names d.function.name true))
          (assert.is_true (. names :bash))
          (assert.is_true (. names :read))
          (assert.is_true (. names :write))
          (assert.is_true (. names :ls)))))))

(describe "core.tools.read"
  (fn []
    (it "reads existing file contents"
      (fn []
        (let [path (tmpfile "hello world")
              r (tools.execute tools.registry :read (json.encode {:path path}))]
          (os.remove path)
          (assert.is_true r.ok?)
          (assert.are.equal "hello world" r.output))))

    (it "returns an error for missing path arg"
      (fn []
        (let [r (tools.execute tools.registry :read (json.encode {}))]
          (assert.is_false r.ok?)
          (assert.is_truthy (string.find r.output "missing 'path'")))))

    (it "returns an error for nonexistent path"
      (fn []
        (let [r (tools.execute tools.registry :read
                                (json.encode {:path "/no/such/path/agent-fennel-test"}))]
          (assert.is_false r.ok?))))))

(describe "core.tools.write"
  (fn []
    (it "writes content and reports byte count"
      (fn []
        (let [path (os.tmpname)
              r (tools.execute tools.registry :write
                                (json.encode {:path path :content "abc"}))]
          (assert.is_true r.ok?)
          (assert.is_truthy (string.find r.output "wrote 3 bytes"))
          (assert.are.equal "abc" (read-file path))
          (os.remove path))))

    (it "returns an error for missing path arg"
      (fn []
        (let [r (tools.execute tools.registry :write (json.encode {:content :x}))]
          (assert.is_false r.ok?)
          (assert.is_truthy (string.find r.output "missing 'path'")))))))

(describe "core.tools.ls"
  (fn []
    (it "lists entries in a directory"
      (fn []
        (let [dir (tmpdir)
              _ (assert (os.execute (.. "touch '" dir "/alpha' '" dir "/beta'")))
              r (tools.execute tools.registry :ls (json.encode {:path dir}))]
          (os.execute (.. "rm -rf '" dir "'"))
          (assert.is_true r.ok?)
          (assert.is_truthy (string.find r.output "alpha"))
          (assert.is_truthy (string.find r.output "beta")))))

    (it "defaults to '.' when no path is given"
      (fn []
        (let [r (tools.execute tools.registry :ls (json.encode {}))]
          (assert.is_true r.ok?))))))

(describe "core.tools.bash"
  (fn []
    (it "captures stdout and exit code from a successful command"
      (fn []
        (let [r (tools.execute tools.registry :bash (json.encode {:cmd "echo hello"}))]
          (assert.is_true r.ok?)
          (assert.is_truthy (string.find r.output "hello"))
          (assert.is_truthy (string.find r.output "%[exit 0%]")))))

    (it "captures combined stderr and exit code from a failing command"
      (fn []
        (let [r (tools.execute tools.registry :bash
                                (json.encode {:cmd "sh -c 'echo oops 1>&2; exit 3'"}))]
          (assert.is_true r.ok?)
          (assert.is_truthy (string.find r.output "oops"))
          (assert.is_truthy (string.find r.output "%[exit 3%]")))))

    (it "returns an error for missing cmd arg"
      (fn []
        (let [r (tools.execute tools.registry :bash (json.encode {}))]
          (assert.is_false r.ok?)
          (assert.is_truthy (string.find r.output "missing 'cmd'")))))))
