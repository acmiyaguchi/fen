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

