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
          (assert.is_true (. names "ls"))
          (assert.is_true (. names "edit"))
          (assert.is_true (. names "grep"))
          (assert.is_true (. names "find")))))))

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
          (assert.is_truthy (string.find (first-text r.content) "missing 'cmd'")))))

    (it "kills a runaway command at the requested timeout"
      (fn []
        ;; timeout(1) returns 124 when it has to send SIGTERM. sleep 5 with
        ;; timeout=1 is plenty of margin even on a loaded box.
        (let [r (tools.execute tools.registry :bash
                                {:cmd "sleep 5" :timeout 1})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "%[exit 124%]")))))

    (it "accepts float-looking integer timeout args"
      (fn []
        (let [r (tools.execute tools.registry :bash
                                {:cmd "echo hello" :timeout 1.0})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "hello")))))

    (it "runs the command in the requested cwd"
      (fn []
        (let [dir (tmpdir)
              r (tools.execute tools.registry :bash
                                {:cmd "pwd" :cwd dir})]
          (os.execute (.. "rm -rf '" dir "'"))
          (assert.is_false r.is-error?)
          ;; pwd may resolve symlinks (e.g. /tmp → /private/tmp on mac); the
          ;; tmpdir basename is still in the output either way.
          (let [base (string.match dir "([^/]+)$")]
            (assert.is_truthy (string.find (first-text r.content) base 1 true))))))

    (it "is-error? when cwd does not exist"
      (fn []
        (let [r (tools.execute tools.registry :bash
                                {:cmd "pwd"
                                 :cwd "/no/such/dir/agent-fennel-cwd-test"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "cwd does not exist")))))

    (it "applies the timeout to the cwd-prefixed command, not just cd"
      (fn []
        (let [dir (tmpdir)
              ;; sleep 5 with timeout 1 should still kill the inner sleep.
              r (tools.execute tools.registry :bash
                                {:cmd "sleep 5" :cwd dir :timeout 1})]
          (os.execute (.. "rm -rf '" dir "'"))
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "%[exit 124%]")))))

    (it "reports unknown exit when pipe:close returns no code"
      (fn []
        ;; Mock io.popen to simulate a pipe whose close() returns nil for the
        ;; third value — what Lua's io.popen does for some signal-kills and
        ;; popen cleanup failures. Without this fix, the result would read
        ;; "[exit 0]" and the model would assume success.
        (let [orig io.popen
              fake-pipe {:read (fn [_ _] "fake output")
                         :close (fn [_] (values true :exit nil))}]
          (set io.popen (fn [_cmd _mode] fake-pipe))
          (let [(ok? r) (pcall tools.execute tools.registry :bash
                                {:cmd "any"})]
            (set io.popen orig)
            (assert.is_true ok?)
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)]
              (assert.is_truthy (string.find text "fake output"))
              (assert.is_falsy (string.find text "%[exit 0%]"))
              (assert.is_truthy (string.find text "%[exit unknown")))))))))

(describe "core.tools.read offset/limit"
  (fn []
    (it "slices [offset, offset+limit) of file lines"
      (fn []
        (let [path (tmpfile "one\ntwo\nthree\nfour\nfive\n")
              r (tools.execute tools.registry :read
                                {:path path :offset 2 :limit 2})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "two\nthree" (first-text r.content)))))

    (it "returns empty content when offset is past the end"
      (fn []
        (let [path (tmpfile "alpha\nbeta\n")
              r (tools.execute tools.registry :read
                                {:path path :offset 99 :limit 5})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "" (first-text r.content)))))

    (it "accepts float-looking integer offset/limit args"
      (fn []
        (let [path (tmpfile "one\ntwo\nthree\n")
              r (tools.execute tools.registry :read
                                {:path path :offset 2.0 :limit 1.0})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "two" (first-text r.content)))))))

(describe "core.tools.write parent dir"
  (fn []
    (it "auto-creates the parent directory"
      (fn []
        (let [base (tmpdir)
              path (.. base "/nested/deeper/hello.txt")
              r (tools.execute tools.registry :write
                                {:path path :content "hi"})]
          (assert.is_false r.is-error?)
          (assert.are.equal "hi" (read-file path))
          (os.execute (.. "rm -rf '" base "'")))))))

(describe "core.tools.ls limit"
  (fn []
    (it "truncates the listing to the requested limit"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "touch '" dir "/a' '" dir "/b' '" dir "/c' '"
                                    dir "/d' '" dir "/e'")))
          (let [r (tools.execute tools.registry :ls
                                  {:path dir :limit 2})
                lines []]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 2 (length lines))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "touch '" dir "/a' '" dir "/b'")))
          (let [r (tools.execute tools.registry :ls
                                  {:path dir :limit 1.0})
                lines []]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))))

(describe "core.tools.edit"
  (fn []
    (it "applies a single replacement"
      (fn []
        (let [path (tmpfile "alpha beta gamma")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "beta"
                                          :new_string "BETA"}]})]
          (assert.is_false r.is-error?)
          (assert.are.equal "alpha BETA gamma" (read-file path))
          (assert.is_truthy (string.find (first-text r.content)
                                          "applied 1 edit"))
          (os.remove path))))

    (it "applies multiple disjoint edits in one call"
      (fn []
        (let [path (tmpfile "alpha beta gamma")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "alpha" :new_string "A"}
                                         {:old_string "gamma" :new_string "G"}]})]
          (assert.is_false r.is-error?)
          (assert.are.equal "A beta G" (read-file path))
          (os.remove path))))

    (it "applies edits to the original snapshot, not sequentially"
      (fn []
        ;; If applied sequentially: edit_a turns "X-Y" into "Y-Y", then edit_b
        ;; sees two Ys and would either pick wrong or fail uniqueness. Snapshot
        ;; semantics: edit_a matches X@1, edit_b matches Y@3 in the original;
        ;; final result is "Y-Z" with no ambiguity.
        (let [path (tmpfile "X-Y")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "X" :new_string "Y"}
                                         {:old_string "Y" :new_string "Z"}]})]
          (assert.is_false r.is-error?)
          (assert.are.equal "Y-Z" (read-file path))
          (os.remove path))))

    (it "is-error? when old_string is not found"
      (fn []
        (let [path (tmpfile "abc")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "xyz" :new_string "_"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "not found"))
          (os.remove path))))

    (it "hints at CRLF when not-found and file uses CRLF line endings"
      (fn []
        ;; Two lines separated by \r\n — old_string with LF won't match.
        (let [path (tmpfile "alpha\r\nbeta\r\n")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "alpha\nbeta"
                                          :new_string "_"}]})]
          (os.remove path)
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "CRLF" 1 true))
          (assert.is_truthy (string.find (first-text r.content)
                                          "old_string uses LF" 1 true)))))

    (it "is-error? when old_string occurs more than once"
      (fn []
        (let [path (tmpfile "abc abc")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "abc" :new_string "_"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "not unique"))
          (os.remove path))))

    (it "is-error? when two edits' matches overlap"
      (fn []
        (let [path (tmpfile "abcdef")
              r (tools.execute tools.registry :edit
                                {:path path
                                 :edits [{:old_string "abc" :new_string "_"}
                                         {:old_string "bcd" :new_string "_"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "overlap"))
          (os.remove path))))

    (it "is-error? for missing path"
      (fn []
        (let [r (tools.execute tools.registry :edit
                                {:edits [{:old_string "x" :new_string "y"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "is-error? for empty edits array"
      (fn []
        (let [path (tmpfile "x")
              r (tools.execute tools.registry :edit
                                {:path path :edits []})]
          (os.remove path)
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'edits'")))))))

(describe "core.tools.grep"
  (fn []
    (it "finds a pattern across files in a directory"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "echo 'hello world' > '" dir "/a.txt'")))
          (assert (os.execute (.. "echo 'goodbye' > '" dir "/b.txt'")))
          (let [r (tools.execute tools.registry :grep
                                  {:pattern "hello" :path dir})]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "hello world"))
            (assert.is_falsy (string.find (first-text r.content) "goodbye"))))))

    (it "ignore_case matches across cases"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "echo 'Hello' > '" dir "/a.txt'")))
          (let [r (tools.execute tools.registry :grep
                                  {:pattern "hello" :path dir :ignore_case true})]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "Hello"))))))

    (it "literal treats regex chars as text"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "echo 'a.b' > '" dir "/a.txt'")))
          (assert (os.execute (.. "echo 'aXb' > '" dir "/b.txt'")))
          (let [r (tools.execute tools.registry :grep
                                  {:pattern "a.b" :path dir :literal true})]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "a%.b"))
            (assert.is_falsy (string.find (first-text r.content) "aXb"))))))

    (it "accepts float-looking integer context/limit args"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "printf 'before\\nneedle\\nafter\\n' > '" dir "/a.txt'")))
          (let [r (tools.execute tools.registry :grep
                                  {:pattern "needle" :path dir :context 1.0 :limit 2.0})]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle"))
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (tools.execute tools.registry :grep {:path "."})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))))

(describe "core.tools.find"
  (fn []
    (it "locates files matching a glob"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "touch '" dir "/needle.fnl' '" dir "/other.lua'")))
          (let [r (tools.execute tools.registry :find
                                  {:pattern "*.fnl" :path dir})]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle%.fnl"))
            (assert.is_falsy (string.find (first-text r.content) "other%.lua"))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (let [dir (tmpdir)]
          (assert (os.execute (.. "touch '" dir "/a.fnl' '" dir "/b.fnl'")))
          (let [r (tools.execute tools.registry :find
                                  {:pattern "*.fnl" :path dir :limit 1.0})
                lines []]
            (os.execute (.. "rm -rf '" dir "'"))
            (assert.is_false r.is-error?)
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (tools.execute tools.registry :find {:path "."})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))))

(describe "core.tools output truncation"
  (fn []
    (fn count-lines [s]
      (var n 0)
      (each [_ (string.gmatch (.. s "\n") "[^\n]*\n")]
        (set n (+ n 1)))
      n)

    (it "tail-truncates bash output > 2000 lines, keeps the [exit] line"
      (fn []
        ;; seq 1..5000 > /dev/stdout — well over the 2000-line cap.
        (let [r (tools.execute tools.registry :bash
                                {:cmd "seq 1 5000"})]
          (assert.is_false r.is-error?)
          (let [text (first-text r.content)]
            ;; Tail-keep means the last lines (close to 5000) survive,
            ;; the first lines (1, 2, 3...) are gone.
            (assert.is_truthy (string.find text "5000"))
            (assert.is_falsy (string.find text "^1\n"))
            (assert.is_truthy (string.find text "%[truncated:.*lines"))
            (assert.is_truthy (string.find text "%[exit 0%]"))))))

    (it "head-truncates read full-slurp > 50KB"
      (fn []
        ;; Build a >50KB file: 1500 lines * 50 bytes = 75KB.
        (let [parts []]
          (for [i 1 1500]
            (table.insert parts
                          (string.format "line-%04d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                                         i)))
          (let [path (tmpfile (table.concat parts "\n"))
                r (tools.execute tools.registry :read {:path path})]
            (os.remove path)
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)]
              (assert.is_truthy (string.find text "line%-0001"))
              (assert.is_falsy (string.find text "line%-1500"))
              (assert.is_truthy (string.find text "%[truncated:.*lines"))
              (assert.is_true (< (length text) (* 60 1024))))))))

    (it "leaves small read outputs untouched (no truncation tag)"
      (fn []
        (let [path (tmpfile "tiny\nfile\n")
              r (tools.execute tools.registry :read {:path path})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "tiny\nfile\n" (first-text r.content))
          (assert.is_falsy (string.find (first-text r.content) "%[truncated:")))))

    (it "leaves read offset/limit slices untouched (caller is bounding)"
      (fn []
        ;; The slice path trusts the caller's limit.
        (let [path (tmpfile "a\nb\nc\nd\ne\n")
              r (tools.execute tools.registry :read
                                {:path path :offset 1 :limit 3})]
          (os.remove path)
          (assert.is_false r.is-error?)
          (assert.are.equal "a\nb\nc" (first-text r.content)))))

    (it "spills full output to a temp file when truncating, embeds path in tag"
      (fn []
        (let [parts []]
          (for [i 1 1500]
            (table.insert parts
                          (string.format "line-%04d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                                         i)))
          (let [path (tmpfile (table.concat parts "\n"))
                r (tools.execute tools.registry :read {:path path})]
            (os.remove path)
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)
                  ;; The tag is "[truncated: ... — full output: <path>]".
                  spill-path (string.match text "full output: ([^%]]+)%]")]
              (assert.is_truthy spill-path)
              ;; The spilled file should exist and contain the line we know
              ;; was dropped from the truncated output.
              (let [f (assert (io.open spill-path :r))
                    full (f:read :*a)]
                (f:close)
                (os.remove spill-path)
                (assert.is_truthy (string.find full "line%-1500"))))))))

    (it "spills full bash output too (tail-truncate path)"
      (fn []
        (let [r (tools.execute tools.registry :bash {:cmd "seq 1 5000"})]
          (assert.is_false r.is-error?)
          (let [text (first-text r.content)
                spill-path (string.match text "full output: ([^%]]+)%]")]
            (assert.is_truthy spill-path)
            (let [f (assert (io.open spill-path :r))
                  full (f:read :*a)]
              (f:close)
              (os.remove spill-path)
              ;; Full output keeps the lines truncated from the visible head.
              (assert.is_truthy (string.find full "^1\n")))))))))
