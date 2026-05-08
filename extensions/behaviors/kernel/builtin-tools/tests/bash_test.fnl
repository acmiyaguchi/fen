;; Tool-related test cases.

(local th (require :fen.testing.tools))
(local tools th.tools)
(local extensions th.extensions)
(local registry th.registry)
(local types th.types)
(local json th.json)
(local h th.h)
(local read-file th.read-file)
(local first-text th.first-text)
(local execute th.execute)
(local execute-coop th.execute-coop)
(import-macros {: with-tmpdir : with-tmpfile} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

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
                                 :cwd "/no/such/dir/fen-cwd-test"})]
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

