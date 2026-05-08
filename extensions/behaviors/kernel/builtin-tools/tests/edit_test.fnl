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

