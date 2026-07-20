(local interactive (require :fen.interactive))

(local pin-tools! interactive.pin-tools!)

(local TOOLS [{:name :bash :exposure :always}
              {:name :todo_write :exposure :search}
              {:name :subagent :exposure :search}])

(describe "fen.interactive.pin-tools!"
  (fn []
    (it "activates configured search tools that resolve to a registered tool"
      (fn []
        (let [active {}]
          (pin-tools! active ["todo_write" "subagent"] TOOLS)
          (assert.is_true (. active :todo_write))
          (assert.is_true (. active :subagent)))))

    (it "ignores names that do not resolve to a registered tool"
      (fn []
        (let [active {}]
          (pin-tools! active ["todo_write" "nope"] TOOLS)
          (assert.is_true (. active :todo_write))
          (assert.is_nil (. active :nope)))))

    (it "no-ops on an empty pin list (pinning disabled)"
      (fn []
        (let [active {}]
          (pin-tools! active [] TOOLS)
          (assert.are.same {} active))))

    (it "no-ops when pinned is nil"
      (fn []
        (let [active {}]
          (pin-tools! active nil TOOLS)
          (assert.are.same {} active))))))
