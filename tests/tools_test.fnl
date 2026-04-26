;; Tests for core.tools — built-in tools + canonical AgentTool registry.

(local tools (require :core.tools))
(local types (require :core.types))

(fn tmpfile [content]
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
  (let [base (os.tmpname)]
    (os.remove base)
    (assert (os.execute (.. "mkdir -p '" base "'")))
    base))

(fn first-text [content]
  "Extract the text from the first TextContent block of an AgentToolResult."
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(describe "core.tools.execute"
  (fn []
    (it "marks unknown tool calls as is-error?"
      (fn []
        (let [r (tools.execute tools.registry :no-such-tool nil)]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "unknown tool: no%-such%-tool")))))

    (it "passes a fresh {} to execute when args is nil"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [a]
                               (set seen a)
                               {:content [(types.text-block "")] :is-error? false})}]]
          (tools.execute reg :probe nil)
          (assert.are.same {} seen))))

    (it "forwards parsed args directly (provider has already JSON-decoded)"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [a]
                               (set seen a)
                               {:content [(types.text-block "")] :is-error? false})}]]
          (tools.execute reg :probe {:foo :bar :n 7})
          (assert.are.equal :bar seen.foo)
          (assert.are.equal 7 seen.n))))))

(describe "core.tools.descriptors"
  (fn []
    (it "exposes canonical Tool[] (no execute, no label)"
      (fn []
        (let [descs (tools.descriptors tools.registry)
              names {}]
          (each [_ d (ipairs descs)]
            (assert.is_string d.description)
            (assert.is_table d.parameters)
            (assert.is_nil d.execute)
            (assert.is_nil d.label)
            (tset names (tostring d.name) true))
          (assert.is_true (. names "bash"))
          (assert.is_true (. names "read"))
          (assert.is_true (. names "write"))
          (assert.is_true (. names "ls")))))))

(describe "core.tools.read"
  (fn []
    (it "reads existing file contents into a TextContent block"
      (fn []
        (let [path (tmpfile "hello world")
              r (tools.execute tools.registry :read {:path path})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "hello world" (first-text r.content)))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (tools.execute tools.registry :read {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "is-error? for nonexistent path"
      (fn []
        (let [r (tools.execute tools.registry :read
                                {:path "/no/such/path/agent-fennel-test"})]
          (assert.is_true r.is-error?))))))

(describe "core.tools.write"
  (fn []
    (it "writes content and reports byte count"
      (fn []
        (let [path (os.tmpname)
              r (tools.execute tools.registry :write {:path path :content "abc"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "wrote 3 bytes"))
          (assert.are.equal "abc" (read-file path))
          (os.remove path))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (tools.execute tools.registry :write {:content :x})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))))

(describe "core.tools.ls"
  (fn []
    (it "lists entries in a directory"
      (fn []
        (let [dir (tmpdir)
              _ (assert (os.execute (.. "touch '" dir "/alpha' '" dir "/beta'")))
              r (tools.execute tools.registry :ls {:path dir})]
          (os.execute (.. "rm -rf '" dir "'"))
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "alpha"))
          (assert.is_truthy (string.find (first-text r.content) "beta")))))

    (it "defaults to '.' when no path is given"
      (fn []
        (let [r (tools.execute tools.registry :ls {})]
          (assert.is_false r.is-error?))))))

(describe "core.tools.bash"
  (fn []
    (it "captures stdout and exit code from a successful command"
      (fn []
        (let [r (tools.execute tools.registry :bash {:cmd "echo hello"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "hello"))
          (assert.is_truthy (string.find (first-text r.content) "%[exit 0%]")))))

    (it "captures combined stderr and exit code from a failing command"
      (fn []
        (let [r (tools.execute tools.registry :bash
                                {:cmd "sh -c 'echo oops 1>&2; exit 3'"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "oops"))
          (assert.is_truthy (string.find (first-text r.content) "%[exit 3%]")))))

    (it "is-error? for missing cmd arg"
      (fn []
        (let [r (tools.execute tools.registry :bash {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'cmd'")))))))
