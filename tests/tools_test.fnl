;; Tests for core.tools executor helpers plus builtin_tools built-in registry.

(local tools (require :core.tools))
(local builtin-tools (require :extensions.builtin_tools.registry))
(local extensions (require :core.extensions))
(local registry builtin-tools.registry)
(local types (require :core.types))
(local json (require :util.json))
(local h (require :test_helpers))
(import-macros {: with-tmpdir : with-tmpfile} :test_macros)

(local read-file h.read-file!)

(after_each (fn [] (h.assert-no-leaks!)))

(fn first-text [content]
  "Extract the text from the first TextContent block of an AgentToolResult."
  (let [b (. content 1)]
    (if (and b (= b.type :text)) b.text "")))

(fn execute [reg name args ?ctx]
  "Test helper over the compact core.tools API; returns AgentToolResult."
  (let [out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 : name
                                 :arguments args}
                                ?ctx)]
    out.result))

(fn execute-coop [reg name args yield-fn ?ctx]
  "Test helper over execute-call with a yield-fn; returns AgentToolResult."
  (let [out (tools.execute-call reg
                                {:type :tool-call
                                 :id "test-call"
                                 : name
                                 :arguments args}
                                ?ctx
                                yield-fn)]
    out.result))

(describe "core.tools.execute-call"
  (fn []
    (it "keeps the public core.tools surface compact"
      (fn []
        (assert.is_function tools.descriptors)
        (assert.is_function tools.execute-call)
        (assert.is_nil tools.execute)
        (assert.is_nil tools.execute-coop)
        (assert.is_nil tools.execute-call-coop)
        (assert.is_nil tools.find-tool)))

    (it "wraps an AgentToolResult as a canonical ToolResultMessage"
      (fn []
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               {:content [(types.text-block "ok")]
                                :is-error? false
                                :details {:n 1}})}]
              out (tools.execute-call reg
                                      {:type :tool-call
                                       :id "call-1"
                                       :name :probe
                                       :arguments {}}
                                      {})]
          (assert.are.equal :tool-result out.message.role)
          (assert.are.equal "call-1" out.message.tool-call-id)
          (assert.are.equal :probe out.message.tool-name)
          (assert.are.equal "ok" (first-text out.message.content))
          (assert.are.same {:n 1} out.message.details)
          (assert.are.same out.result.content out.message.content))))

    (it "marks unknown tool calls as is-error?"
      (fn []
        (let [r (execute registry :no-such-tool nil)]
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
          (execute reg :probe nil)
          (assert.are.same {} seen))))

    (it "forwards parsed args directly (provider has already JSON-decoded)"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [a]
                               (set seen a)
                               {:content [(types.text-block "")] :is-error? false})}]]
          (execute reg :probe {:foo :bar :n 7})
          (assert.are.equal :bar seen.foo)
          (assert.are.equal 7 seen.n))))

    (it "passes context to context-aware tools"
      (fn []
        (var seen nil)
        (let [reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_a ctx]
                               (set seen ctx)
                               {:content [(types.text-block "")] :is-error? false})}]
              ctx {:agent {:model "m"}}]
          (execute reg :probe {} ctx)
          (assert.are.same ctx seen))))

    (it "converts throwing tools to tool error results"
      (fn []
        (let [reg [{:name :boom :label "Boom" :description ""
                    :parameters {}
                    :execute (fn [_] (error "kaboom"))}]
              r (execute reg :boom {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "kaboom")))))

    (it "runs before-tool hooks and turns vetoes into tool errors"
      (fn []
        (extensions.reset!)
        (let [api (extensions.make-api :policy)
              fired {:tool false}
              reg [{:name :probe :label "Probe" :description ""
                    :parameters {}
                    :execute (fn [_]
                               (set fired.tool true)
                               {:content [(types.text-block "ok")]
                                :is-error? false})}]]
          (api.register :hook
                        {:before-tool
                         (fn [name _args _ctx]
                           (when (= name :probe)
                             {:block true :reason "not allowed"}))})
          (let [r (execute reg :probe {})]
            (extensions.reset!)
            (assert.is_true r.is-error?)
            (assert.is_false fired.tool)
            (assert.is_truthy (string.find (first-text r.content)
                                            "not allowed"))))))))

(describe "core.tools.descriptors"
  (fn []
    (it "exposes canonical Tool[] (no execute, no label)"
      (fn []
        (let [descs (tools.descriptors registry)
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
        (with-tmpfile [path "hello world"]
          (let [r (execute registry :read {:path path})]
            (assert.is_false r.is-error?)
            (assert.are.equal "hello world" (first-text r.content))))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (execute registry :read {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "is-error? for nonexistent path"
      (fn []
        (let [r (execute registry :read
                                {:path "/no/such/path/agent-fennel-test"})]
          (assert.is_true r.is-error?))))))

(describe "core.tools.write"
  (fn []
    (it "writes content and reports byte count"
      (fn []
        (with-tmpfile [path ""]
          (let [r (execute registry :write {:path path :content "abc"})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "wrote 3 bytes"))
            (assert.are.equal "abc" (read-file path))))))

    (it "is-error? for missing path arg"
      (fn []
        (let [r (execute registry :write {:content :x})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))))

(describe "core.tools.ls"
  (fn []
    (it "lists entries in a directory"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/alpha") "")
          (h.write-file (.. dir "/beta") "")
          (let [r (execute registry :ls {:path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "alpha"))
            (assert.is_truthy (string.find (first-text r.content) "beta"))))))

    (it "defaults to '.' when no path is given"
      (fn []
        (let [r (execute registry :ls {})]
          (assert.is_false r.is-error?))))))

(describe "core.tools.bash"
  (fn []
    (it "captures stdout and exit code from a successful command"
      (fn []
        (let [r (execute registry :bash {:cmd "echo hello"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "hello"))
          (assert.is_truthy (string.find (first-text r.content) "%[exit 0%]")))))

    (it "captures combined stderr and exit code from a failing command"
      (fn []
        (let [r (execute registry :bash
                                {:cmd "sh -c 'echo oops 1>&2; exit 3'"})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "oops"))
          (assert.is_truthy (string.find (first-text r.content) "%[exit 3%]")))))

    (it "is-error? for missing cmd arg"
      (fn []
        (let [r (execute registry :bash {})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'cmd'")))))

    (it "kills a runaway command at the requested timeout"
      (fn []
        ;; timeout(1) returns 124 when it has to send SIGTERM. sleep 5 with
        ;; timeout=1 is plenty of margin even on a loaded box.
        (let [r (execute registry :bash
                                {:cmd "sleep 5" :timeout 1})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "%[exit 124%]")))))

    (it "accepts float-looking integer timeout args"
      (fn []
        (let [r (execute registry :bash
                                {:cmd "echo hello" :timeout 1.0})]
          (assert.is_false r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "hello")))))

    (it "runs the command in the requested cwd"
      (fn []
        (with-tmpdir [dir]
          (let [r (execute registry :bash
                                  {:cmd "pwd" :cwd dir})]
            (assert.is_false r.is-error?)
            ;; pwd may resolve symlinks (e.g. /tmp → /private/tmp on mac); the
            ;; tmpdir basename is still in the output either way.
            (let [base (string.match dir "([^/]+)$")]
              (assert.is_truthy (string.find (first-text r.content) base 1 true)))))))

    (it "is-error? when cwd does not exist"
      (fn []
        (let [r (execute registry :bash
                                {:cmd "pwd"
                                 :cwd "/no/such/dir/agent-fennel-cwd-test"})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "cwd does not exist")))))

    (it "applies the timeout to the cwd-prefixed command, not just cd"
      (fn []
        (with-tmpdir [dir]
          ;; sleep 5 with timeout 1 should still kill the inner sleep.
          (let [r (execute registry :bash
                                  {:cmd "sleep 5" :cwd dir :timeout 1})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content)
                                            "%[exit 124%]"))))))

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
          (let [(ok? r) (pcall execute registry :bash
                                {:cmd "any"})]
            (set io.popen orig)
            (assert.is_true ok?)
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)]
              (assert.is_truthy (string.find text "fake output"))
              (assert.is_falsy (string.find text "%[exit 0%]"))
              (assert.is_truthy (string.find text "%[exit unknown")))))))))

(describe "core.tools.execute-call-coop"
  (fn []
    (it "falls back to blocking execute for tools without :execute-coop"
      (fn []
        ;; read has no :execute-coop, so execute-coop should route to its
        ;; blocking :execute and return the same result.
        (with-tmpfile [path "alpha\nbeta\n"]
          (let [r (execute-coop registry :read {:path path}
                                      (fn [] (error "yield should not run")))]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "alpha"))))))

    (it "routes bash through :execute-coop and yields while waiting on output"
      (fn []
        (var yields 0)
        ;; A command that produces output, sleeps, and produces more output
        ;; forces at least one EAGAIN between chunks. The exact yield count
        ;; depends on scheduling; we only assert it's > 0 to prove the
        ;; nonblocking read path was used rather than pipe:read :*a.
        (let [r (execute-coop registry :bash
                                     {:cmd "echo first; sleep 0.05; echo second"}
                                     (fn [] (set yields (+ yields 1))))]
          (assert.is_false r.is-error?)
          (let [text (first-text r.content)]
            (assert.is_truthy (string.find text "first"))
            (assert.is_truthy (string.find text "second"))
            (assert.is_truthy (string.find text "%[exit 0%]")))
          (assert.is_true (> yields 0)))))

    (it "matches blocking output byte-for-byte for a simple command"
      (fn []
        (let [blocking (execute registry :bash {:cmd "seq 1 5"})
              coop (execute-coop registry :bash {:cmd "seq 1 5"}
                                       (fn [] nil))]
          (assert.is_false blocking.is-error?)
          (assert.is_false coop.is-error?)
          (assert.are.equal (first-text blocking.content)
                            (first-text coop.content)))))

    (it "propagates a yield-fn error so the agent can cancel mid-command"
      (fn []
        ;; If yield-fn raises (e.g. CANCEL-MARKER from agent.step),
        ;; run-bash-coop's inner pcall catches read errors but re-raises
        ;; them after closing the pipe so cancellation unwinds cleanly.
        (let [(ok? err) (pcall execute-coop registry :bash
                               {:cmd "echo a; sleep 0.1; echo b"}
                               (fn [] (error :cancel-test)))]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err) "cancel%-test")))))

    (it "kills a silent child before closing the popen pipe on cancel"
      (fn []
        ;; Regression for #9: without killing the recorded child PID first,
        ;; pipe:close() blocks in pclose()/waitpid until this sleep exits.
        (let [(ok? err) (pcall execute-coop registry :bash
                               {:cmd "sleep 2"}
                               (fn [] (error :cancel-silent-test)))]
          (assert.is_false ok?)
          (assert.is_truthy (string.find (tostring err)
                                          "cancel%-silent%-test")))))))

(describe "core.tools.read offset/limit"
  (fn []
    (it "slices [offset, offset+limit) of file lines"
      (fn []
        (with-tmpfile [path "one\ntwo\nthree\nfour\nfive\n"]
          (let [r (execute registry :read
                                  {:path path :offset 2 :limit 2})]
            (assert.is_false r.is-error?)
            (assert.are.equal "two\nthree" (first-text r.content))))))

    (it "returns empty content when offset is past the end"
      (fn []
        (with-tmpfile [path "alpha\nbeta\n"]
          (let [r (execute registry :read
                                  {:path path :offset 99 :limit 5})]
            (assert.is_false r.is-error?)
            (assert.are.equal "" (first-text r.content))))))

    (it "accepts float-looking integer offset/limit args"
      (fn []
        (with-tmpfile [path "one\ntwo\nthree\n"]
          (let [r (execute registry :read
                                  {:path path :offset 2.0 :limit 1.0})]
            (assert.is_false r.is-error?)
            (assert.are.equal "two" (first-text r.content))))))

    (it "is-error? when single and batched read shapes are both provided"
      (fn []
        (let [r (execute registry :read
                                {:path "/tmp/a" :paths ["/tmp/b"]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "either 'path' or 'paths'" 1 true)))))

    (it "is-error? for empty paths array"
      (fn []
        (let [r (execute registry :read {:paths []})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "missing 'paths'" 1 true)))))

    (it "reads multiple paths in one batched call with headers"
      (fn []
        (with-tmpfile [a "alpha"]
          (with-tmpfile [b "one\ntwo\nthree\n"]
            (let [r (execute registry :read
                                    {:paths [a {:path b :offset 2 :limit 1}]})]
              (assert.is_false r.is-error?)
              (let [text (first-text r.content)]
                (assert.is_truthy (string.find text (.. "==> " a " <==") 1 true))
                (assert.is_truthy (string.find text "alpha" 1 true))
                (assert.is_truthy (string.find text (.. "==> " b " <==") 1 true))
                (assert.is_truthy (string.find text "two" 1 true))
                (assert.is_falsy (string.find text "three" 1 true))))))))

    (it "includes missing-file errors inline in batched read results"
      (fn []
        (with-tmpfile [a "alpha"]
          (let [missing "/no/such/path/agent-fennel-read-batch-test"
                r (execute registry :read {:paths [a missing]})]
            (assert.is_false r.is-error?)
            (let [text (first-text r.content)]
              (assert.is_truthy (string.find text (.. "==> " a " <==") 1 true))
              (assert.is_truthy (string.find text (.. "==> " missing " <==") 1 true))
              (assert.is_truthy (string.find text "error:" 1 true)))))))

  ))

(describe "core.tools.write parent dir"
  (fn []
    (it "auto-creates the parent directory"
      (fn []
        (with-tmpdir [base]
          (let [path (.. base "/nested/deeper/hello.txt")
                r (execute registry :write
                                  {:path path :content "hi"})]
            (assert.is_false r.is-error?)
            (assert.are.equal "hi" (read-file path))))))))

(describe "core.tools.ls limit"
  (fn []
    (it "truncates the listing to the requested limit"
      (fn []
        (with-tmpdir [dir]
          (each [_ name (ipairs ["a" "b" "c" "d" "e"])]
            (h.write-file (.. dir "/" name) ""))
          (let [r (execute registry :ls
                                  {:path dir :limit 2})
                lines []]
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 2 (length lines))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a") "")
          (h.write-file (.. dir "/b") "")
          (let [r (execute registry :ls
                                  {:path dir :limit 1.0})
                lines []]
            (assert.is_false r.is-error?)
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))))

(describe "core.tools.edit"
  (fn []
    (it "applies a single replacement"
      (fn []
        (with-tmpfile [path "alpha beta gamma"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "beta"
                                            :new_string "BETA"}]})]
            (assert.is_false r.is-error?)
            (assert.are.equal "alpha BETA gamma" (read-file path))
            (assert.is_truthy (string.find (first-text r.content)
                                            "applied 1 edit"))))))

    (it "applies multiple disjoint edits in one call"
      (fn []
        (with-tmpfile [path "alpha beta gamma"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "alpha" :new_string "A"}
                                           {:old_string "gamma" :new_string "G"}]})]
            (assert.is_false r.is-error?)
            (assert.are.equal "A beta G" (read-file path))))))

    (it "applies edits to the original snapshot, not sequentially"
      (fn []
        ;; If applied sequentially: edit_a turns "X-Y" into "Y-Y", then edit_b
        ;; sees two Ys and would either pick wrong or fail uniqueness. Snapshot
        ;; semantics: edit_a matches X@1, edit_b matches Y@3 in the original;
        ;; final result is "Y-Z" with no ambiguity.
        (with-tmpfile [path "X-Y"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "X" :new_string "Y"}
                                           {:old_string "Y" :new_string "Z"}]})]
            (assert.is_false r.is-error?)
            (assert.are.equal "Y-Z" (read-file path))))))

    (it "is-error? when old_string is not found"
      (fn []
        (with-tmpfile [path "abc"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "xyz" :new_string "_"}]})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "not found"))))))

    (it "hints at CRLF when not-found and file uses CRLF line endings"
      (fn []
        ;; Two lines separated by \r\n — old_string with LF won't match.
        (with-tmpfile [path "alpha\r\nbeta\r\n"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "alpha\nbeta"
                                            :new_string "_"}]})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content)
                                            "CRLF" 1 true))
            (assert.is_truthy (string.find (first-text r.content)
                                            "old_string uses LF" 1 true))))))

    (it "is-error? when old_string occurs more than once"
      (fn []
        (with-tmpfile [path "abc abc"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "abc" :new_string "_"}]})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "not unique"))))))

    (it "is-error? when two edits' matches overlap"
      (fn []
        (with-tmpfile [path "abcdef"]
          (let [r (execute registry :edit
                                  {:path path
                                   :edits [{:old_string "abc" :new_string "_"}
                                           {:old_string "bcd" :new_string "_"}]})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "overlap"))))))

    (it "is-error? for missing path"
      (fn []
        (let [r (execute registry :edit
                                {:edits [{:old_string "x" :new_string "y"}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'path'")))))

    (it "is-error? when single and batched edit shapes are both provided"
      (fn []
        (let [r (execute registry :edit
                                {:path "/tmp/a"
                                 :edits [{:old_string "x" :new_string "y"}]
                                 :files [{:path "/tmp/b"
                                          :edits [{:old_string "x"
                                                   :new_string "y"}]}]})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "either 'path'/'edits' or 'files'" 1 true)))))

    (it "is-error? for empty files array"
      (fn []
        (let [r (execute registry :edit {:files []})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content)
                                          "missing 'files'" 1 true)))))

    (it "applies batched edits across multiple files"
      (fn []
        (with-tmpfile [a "alpha beta"]
          (with-tmpfile [b "gamma delta"]
            (let [r (execute registry :edit
                                    {:files [{:path a
                                              :edits [{:old_string "beta"
                                                       :new_string "BETA"}]}
                                             {:path b
                                              :edits [{:old_string "gamma"
                                                       :new_string "GAMMA"}]}]})]
              (assert.is_false r.is-error?)
              (assert.are.equal "alpha BETA" (read-file a))
              (assert.are.equal "GAMMA delta" (read-file b))
              (let [text (first-text r.content)]
                (assert.is_truthy (string.find text (.. "applied 1 edit(s) to " a) 1 true))
                (assert.is_truthy (string.find text (.. "applied 1 edit(s) to " b) 1 true))))))))

    (it "does not mutate any file when batched edit validation fails"
      (fn []
        (with-tmpfile [a "alpha beta"]
          (with-tmpfile [b "gamma delta"]
            (let [r (execute registry :edit
                                    {:files [{:path a
                                              :edits [{:old_string "beta"
                                                       :new_string "BETA"}]}
                                             {:path b
                                              :edits [{:old_string "missing"
                                                       :new_string "MISS"}]}]})]
              (assert.is_true r.is-error?)
              (assert.is_truthy (string.find (first-text r.content) b 1 true))
              (assert.are.equal "alpha beta" (read-file a))
              (assert.are.equal "gamma delta" (read-file b)))))))

    (it "surfaces CRLF hints with the path in batched edit validation failures"
      (fn []
        (with-tmpfile [a "alpha beta"]
          (with-tmpfile [b "gamma\r\ndelta\r\n"]
            (let [r (execute registry :edit
                                    {:files [{:path a
                                              :edits [{:old_string "beta"
                                                       :new_string "BETA"}]}
                                             {:path b
                                              :edits [{:old_string "gamma\ndelta"
                                                       :new_string "G"}]}]})]
              (assert.is_true r.is-error?)
              (let [text (first-text r.content)]
                (assert.is_truthy (string.find text b 1 true))
                (assert.is_truthy (string.find text "CRLF" 1 true)))
              (assert.are.equal "alpha beta" (read-file a))
              (assert.are.equal "gamma\r\ndelta\r\n" (read-file b)))))))

    (it "is-error? for empty edits array"
      (fn []
        (with-tmpfile [path "x"]
          (let [r (execute registry :edit
                                  {:path path :edits []})]
            (assert.is_true r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "missing 'edits'"))))))))

(describe "core.tools.grep"
  (fn []
    (it "finds a pattern across files in a directory"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "hello world\n")
          (h.write-file (.. dir "/b.txt") "goodbye\n")
          (let [r (execute registry :grep
                                  {:pattern "hello" :path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "hello world"))
            (assert.is_falsy (string.find (first-text r.content) "goodbye"))))))

    (it "ignore_case matches across cases"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "Hello\n")
          (let [r (execute registry :grep
                                  {:pattern "hello" :path dir :ignore_case true})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "Hello"))))))

    (it "literal treats regex chars as text"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "a.b\n")
          (h.write-file (.. dir "/b.txt") "aXb\n")
          (let [r (execute registry :grep
                                  {:pattern "a.b" :path dir :literal true})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "a%.b"))
            (assert.is_falsy (string.find (first-text r.content) "aXb"))))))

    (it "accepts float-looking integer context/limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.txt") "before\nneedle\nafter\n")
          (let [r (execute registry :grep
                                  {:pattern "needle" :path dir :context 1.0 :limit 2.0})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle"))
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (execute registry :grep {:path "."})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "missing 'pattern'")))))))

(describe "core.tools.find"
  (fn []
    (it "locates files matching a glob"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/needle.fnl") "")
          (h.write-file (.. dir "/other.lua") "")
          (let [r (execute registry :find
                                  {:pattern "*.fnl" :path dir})]
            (assert.is_false r.is-error?)
            (assert.is_truthy (string.find (first-text r.content) "needle%.fnl"))
            (assert.is_falsy (string.find (first-text r.content) "other%.lua"))))))

    (it "accepts float-looking integer limit args"
      (fn []
        (with-tmpdir [dir]
          (h.write-file (.. dir "/a.fnl") "")
          (h.write-file (.. dir "/b.fnl") "")
          (let [r (execute registry :find
                                  {:pattern "*.fnl" :path dir :limit 1.0})
                lines []]
            (assert.is_false r.is-error?)
            (assert.is_falsy (string.find (first-text r.content) "invalid number"))
            (each [line (string.gmatch (first-text r.content) "[^\n]+")]
              (table.insert lines line))
            (assert.are.equal 1 (length lines))))))

    (it "is-error? for missing pattern"
      (fn []
        (let [r (execute registry :find {:path "."})]
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
        (let [r (execute registry :bash
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
          (with-tmpfile [path (table.concat parts "\n")]
            (let [r (execute registry :read {:path path})]
              (assert.is_false r.is-error?)
              (let [text (first-text r.content)]
                (assert.is_truthy (string.find text "line%-0001"))
                (assert.is_falsy (string.find text "line%-1500"))
                (assert.is_truthy (string.find text "%[truncated:.*lines"))
                (assert.is_true (< (length text) (* 60 1024)))))))))

    (it "leaves small read outputs untouched (no truncation tag)"
      (fn []
        (with-tmpfile [path "tiny\nfile\n"]
          (let [r (execute registry :read {:path path})]
            (assert.is_false r.is-error?)
            (assert.are.equal "tiny\nfile\n" (first-text r.content))
            (assert.is_falsy (string.find (first-text r.content) "%[truncated:"))))))

    (it "leaves read offset/limit slices untouched (caller is bounding)"
      (fn []
        ;; The slice path trusts the caller's limit.
        (with-tmpfile [path "a\nb\nc\nd\ne\n"]
          (let [r (execute registry :read
                                  {:path path :offset 1 :limit 3})]
            (assert.is_false r.is-error?)
            (assert.are.equal "a\nb\nc" (first-text r.content))))))

    (it "spills full output to a temp file when truncating, embeds path in tag"
      (fn []
        (let [parts []]
          (for [i 1 1500]
            (table.insert parts
                          (string.format "line-%04d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                                         i)))
          (with-tmpfile [path (table.concat parts "\n")]
            (let [r (execute registry :read {:path path})]
              (assert.is_false r.is-error?)
              (let [text (first-text r.content)
                    ;; The tag is "[truncated: ... — full output: <path>]".
                    spill-path (string.match text "full output: ([^%]]+)%]")]
                (assert.is_truthy spill-path)
                ;; The spilled file should exist and contain the line we know
                ;; was dropped from the truncated output.
                (let [full (h.read-file! spill-path)]
                  (os.remove spill-path)
                  (assert.is_truthy (string.find full "line%-1500")))))))))

    (it "spills full bash output too (tail-truncate path)"
      (fn []
        (let [r (execute registry :bash {:cmd "seq 1 5000"})]
          (assert.is_false r.is-error?)
          (let [text (first-text r.content)
                spill-path (string.match text "full output: ([^%]]+)%]")]
            (assert.is_truthy spill-path)
            (let [full (h.read-file! spill-path)]
              (os.remove spill-path)
              ;; Full output keeps the lines truncated from the visible head.
              (assert.is_truthy (string.find full "^1\n")))))))))

(describe "agent_state extension tool"
  (fn []
    (after_each (fn [] (extensions.reset!)))

    (fn agent [reg]
      {:model "test-model"
       :provider-api :openai-completions
       :system-prompt "system text"
       :max-tokens 123
       :api-key "secret"
       :provider-options {:api-key "secret2"}
       :messages [(types.user-message "hello")
                  (types.assistant-message
                    {:content [(types.text-block "hi")]
                     :api :openai-completions
                     :provider :openai
                     :model "test-model"
                     :usage {:input 10 :output 3 :total-tokens 13}
                     :stop-reason :stop})]
       :tools reg})

    (fn agent-state-registry []
      (extensions.reset!)
      (tset package.loaded :extensions.agent_state nil)
      (tset package.loaded :extensions.agent_state.tool nil)
      (require :extensions.agent_state)
      (extensions.merged-tools registry))

    (it "answers simple get queries as JSON"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :model)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"test-model\"" (first-text r.content)))))

    (it "supports count, slice, pluck, where, and last"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:pluck (:slice (:get :messages) -2 2) :role)"}
                               {:agent (agent reg)})
              decoded (json.decode (first-text r.content))]
          (assert.is_false r.is-error?)
          (assert.are.equal "user" (. decoded 1))
          (assert.are.equal "assistant" (. decoded 2)))
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get (:last (:where (:get :messages) :role :assistant)) :stop-reason)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"stop\"" (first-text r.content)))))

    (it "exposes sanitized tool descriptors, not executable closures or secrets"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get)"}
                               {:agent (agent reg)})
              text (first-text r.content)]
          (assert.is_false r.is-error?)
          (assert.is_nil (string.find text "secret" 1 true))
          (assert.is_nil (string.find text "execute" 1 true))
          (assert.is_truthy (string.find text "agent_state" 1 true)))))

    (it "exposes extension registry introspection"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:keys (:get :extensions))"}
                               {:agent (agent reg)})
              decoded (json.decode (first-text r.content))]
          (assert.is_false r.is-error?)
          (assert.are.same ["commands" "event-handlers" "loaded" "presenters" "system-prompt-contributions" "tools"]
                           decoded))
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :extensions :tools 0 :name)"}
                               {:agent (agent reg)})]
          (assert.is_false r.is-error?)
          (assert.are.equal "\"agent_state\"" (first-text r.content)))))

    (it "returns an error for invalid query syntax"
      (fn []
        (let [reg (agent-state-registry)
              r (execute reg :agent_state
                               {:query "(:get :messages"}
                               {:agent (agent reg)})]
          (assert.is_true r.is-error?)
          (assert.is_truthy (string.find (first-text r.content) "unterminated")))))))
