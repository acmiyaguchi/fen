(local id (require :fen.util.id))

(describe "fen.util.id"
  (fn []
    (it "generates UUIDv7-shaped IDs"
      (fn []
        (let [u (id.uuidv7)]
          (assert.is_not_nil
            (string.match u "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")))))

    (it "generates lexically increasing IDs within a process"
      (fn []
        (let [a (id.uuidv7)
              b (id.uuidv7)
              c (id.uuidv7)]
          (assert.is_true (< a b))
          (assert.is_true (< b c)))))

    (it "returns requested random hex length"
      (fn []
        (let [h (id.random-hex 17)]
          (assert.are.equal 17 (length h))
          (assert.is_not_nil (string.match h "^%x+$")))))))
