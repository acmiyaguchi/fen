(local random (require :fen.util.random))
(local testing (require :fen.testing))

(describe "util.random"
  (fn []
    (it "returns a string of the requested length"
      (fn []
        (assert.are.equal 1 (length (random.bytes 1)))
        (assert.are.equal 16 (length (random.bytes 16)))
        (assert.are.equal 32 (length (random.bytes 32)))
        (assert.are.equal 64 (length (random.bytes 64)))))

    (it "produces different output across calls"
      (fn []
        (let [a (random.bytes 32)
              b (random.bytes 32)]
          ;; 32 random bytes colliding has probability ~2^-256; in practice
          ;; never. If this fails the RNG is broken.
          (assert.is_not.equal a b))))

    (it "errors on non-positive sizes"
      (fn []
        (assert.has_error (fn [] (random.bytes 0)))
        (assert.has_error (fn [] (random.bytes -1)))))

    (it "produces output with high entropy (no all-zeros block)"
      (fn []
        (let [raw (random.bytes 32)]
          (assert.is_not.equal (string.rep "\0" 32) raw))))))

;; Backend-seam tests (#472): the public module dispatches through an injectable
;; backend, and the default backend wraps the fen_random native CSPRNG.
(describe "util.random backend seam"
  (fn []
    (after_each
      (fn []
        (testing.restore-random!)))

    (it "dispatches bytes through the injected backend"
      (fn []
        (testing.stub-random!
          {:bytes (fn [n] (string.rep "z" n))})
        (let [stubbed (testing.reload-module :fen.util.random)]
          (assert.are.equal "zzzz" (stubbed.bytes 4)))))

    (it "uses the fen_random native backend by default"
      (fn []
        (testing.restore-random!)
        (let [default (testing.reload-module :fen.util.random)
              out (default.bytes 16)]
          (assert.are.equal 16 (length out)))))))
