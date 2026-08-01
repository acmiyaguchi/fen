(local compiler (require :fen.core.extensions.loader.compiler))
(local process (require :fen.util.process))
(local runtime (require :fen.runtime))

(describe "loader.compiler one-shot batch"
  (fn []
    (local original-run process.run-captured)
    (local original-binary runtime.binary-path)

    (after_each
      (fn []
        (set process.run-captured original-run)
        (set runtime.binary-path original-binary)))

    (it "returns every framed worker result only after one complete batch"
      (fn []
        (var argv nil)
        (var polls 0)
        (set runtime.binary-path (fn [] "/fake/fen"))
        (set process.run-captured
             (fn [opts yield!]
               (set argv opts.argv)
               (yield!)
               {:exit-code 0 :output
                "FEN-COMPILE\t5\t5\t8\nalphaa.fnlreturn 1FEN-COMPILE\t4\t5\t8\nbetab.fnlreturn 2"}))
        (let [batch (compiler.compile!
                      [{:module "alpha" :path "a.fnl"}
                       {:module "beta" :path "b.fnl"}]
                      (fn [_] (set polls (+ polls 1))))]
          (assert.are.equal :ok batch.status (tostring batch.error))
          (assert.are.equal "return 1" (. batch.outputs :alpha :lua))
          (assert.are.equal "return 2" (. batch.outputs :beta :lua))
          (assert.are.same ["/fake/fen" :eval]
                           [(. argv 1) (. argv 2)])
          (assert.are.equal 1 polls))))

    (it "rejects a successful exit with an incomplete batch"
      (fn []
        (set runtime.binary-path (fn [] "/fake/fen"))
        (set process.run-captured
             (fn [_ _]
               {:exit-code 0 :output
                "FEN-COMPILE\t5\t5\t8\nalphaa.fnlreturn 1"}))
        (let [batch (compiler.compile!
                      [{:module "alpha" :path "a.fnl"}
                       {:module "beta" :path "b.fnl"}])]
          (assert.are.equal :failed batch.status)
          (assert.is_truthy (string.find batch.error "omitted beta" 1 true)
                            (tostring batch.error)))))))
