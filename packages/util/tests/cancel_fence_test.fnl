;; spec/core/tasks/proofs/fence: a cancel arms only the holder it names.

(local fence (require :fen.util.cancel_fence))

(describe "fen.util.cancel_fence"
          (fn []
            (it "a cancel captured for run 1 that lands during run 2 does nothing"
                (fn []
                  (let [t {}
                        hid1 (fence.acquire! t)
                        pressed-for (fence.current t)]
                    (fence.release! t hid1)
                    (let [hid2 (fence.acquire! t)]
                      (assert.is_false (fence.cancel! t pressed-for))
                      (assert.is_false (fence.cancel-requested? t hid2))))))
            (it "a cancel for the current holder stays armed until it releases"
                (fn []
                  (let [t {}
                        hid (fence.acquire! t)]
                    (assert.is_true (fence.cancel-current! t))
                    (assert.is_true (fence.cancel-requested? t hid))
                    (fence.release! t hid)
                    (assert.is_false (fence.cancel-requested? t hid)))))
            (it "a cancel while idle arms nothing and the next run starts clean"
                (fn []
                  (let [t {}]
                    (assert.is_false (fence.cancel-current! t))
                    (fence.release! t (fence.acquire! t))
                    (assert.is_false (fence.cancel-current! t))
                    (assert.is_false (fence.cancel-requested? t
                                                              (fence.acquire! t))))))
            (it "fences are per table: the same id on another owner is untouched"
                (fn []
                  (let [a {}
                        b {}
                        ha (fence.acquire! a)
                        hb (fence.acquire! b)]
                    (assert.are.equal ha hb)
                    (fence.cancel! a ha)
                    (assert.is_false (fence.cancel-requested? b hb)))))
            (it "release! of an earlier holder does not end the current one"
                (fn []
                  (let [t {}
                        h1 (fence.acquire! t)
                        h2 (fence.acquire! t)]
                    (fence.release! t h1)
                    (assert.are.equal h2 (fence.current t)))))))
