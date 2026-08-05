;; Process backend-seam tests (#472): run-captured drives its subprocess
;; state machine entirely through the injected backend and clock, proving the
;; spawn/read/wait/close surface is dispatched via the seam rather than a hard
;; require of fen_process.

(local testing (require :fen.testing))

(describe "util.process backend seam"
  (fn []
    (after_each
      (fn []
        (testing.restore-process!)
        (testing.restore-clock!)))

    (it "dispatches spawn/read/wait/close through the injected backend"
      (fn []
        (var calls {:spawn-shell 0 :wait 0 :close 0})
        (var reads 0)
        (testing.stub-process!
          {:EAGAIN :eagain :EWOULDBLOCK :ewouldblock
           :SIGTERM 15 :SIGKILL 9
           :spawn_shell (fn [cmd _cwd]
                          (set calls.spawn-shell (+ calls.spawn-shell 1))
                          (set calls.cmd cmd)
                          (values {:pid 4242 :fd 7} nil nil))
           :read (fn [_fd _n]
                   (set reads (+ reads 1))
                   (if (= reads 1) (values "hello world" nil nil)
                       (values "" nil nil)))
           :wait_pid (fn [_pid _nohang]
                       (set calls.wait (+ calls.wait 1))
                       (values true "exit" 0))
           :close_fd (fn [_fd] (set calls.close (+ calls.close 1)))
           :kill_process_group (fn [_pid _sig] nil)})
        (testing.stub-clock!
          {:monotonic-ms (fn [] 0)
           :sleep-ms (fn [_] true)})
        (let [process (testing.reload-module :fen.util.process)
              r (process.run-captured {:cmd "echo hi"})]
          (assert.are.equal 1 calls.spawn-shell)
          (assert.are.equal "echo hi" calls.cmd)
          (assert.are.equal 0 r.exit-code)
          (assert.are.equal "hello world" r.output)
          (assert.is_true (>= calls.close 1)))))))
