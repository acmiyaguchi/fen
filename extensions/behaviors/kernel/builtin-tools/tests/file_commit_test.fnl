;; Regression for #654, #655, #656: write and edit stage to a temp file beside
;; the target and rename it over the target, check every write and close, and
;; never yield between the commit and the return. So a failed or cancelled
;; call leaves every file unchanged, and an ok result means the bytes landed.
;; See spec/tools/FINDINGS.md ("Five guarantees").
(local th (require :fen.testing.tools))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(fn sh-ok? [cmd]
  (let [r (os.execute cmd)]
    (or (= r true) (= r 0))))

(fn entries [dir]
  (let [p (io.popen (.. "ls -A " (h.shellquote dir)))
        out (p:read :*a)]
    (p:close)
    (icollect [name (string.gmatch out "[^\n]+")] name)))

(fn cancel-on-call [n]
  "A yield-fn that raises CANCEL on its nth call, like the agent's make-yield."
  (var calls 0)
  (fn []
    (set calls (+ calls 1))
    (when (= calls n) (error :CANCEL 0))))

(fn count-yields [f]
  (var calls 0)
  (f (fn [] (set calls (+ calls 1))))
  calls)

(describe "write commit"
          (fn []
            (it "a cancel at any yield keeps the original and leaves no temp (#654)"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/target")
                          original "ORIGINAL CONTENT\n"
                          content (string.rep "x" 40000)
                          args {:path f : content}
                          total (count-yields (fn [y]
                                                (h.write-file f original)
                                                (th.execute-coop th.registry
                                                                 :write args y)))]
                      (assert.is_true (> total 2))
                      (for [n 1 total]
                        (h.write-file f original)
                        (let [(ok? r) (pcall th.execute-coop th.registry :write
                                             args (cancel-on-call n))]
                          ;; Either the call was cancelled and nothing changed, or it
                          ;; got past every yield and the write is complete.
                          (if ok?
                              (do
                                (assert.is_false r.is-error?)
                                (assert.are.equal content (h.read-file f)))
                              (assert.are.equal original (h.read-file f)))
                          (assert.are.same [:target] (entries dir))))))))
            (it "reports a failed write as an error (#655)"
                (fn []
                  (let [probe (io.open "/dev/full" :r)]
                    ;; /dev/full is Linux; elsewhere the case does not apply.
                    (when probe
                      (probe:close)
                      (let [r (th.execute th.registry :write
                                          {:path "/dev/full"
                                           :content (string.rep "x" 100)})]
                        (assert.is_true r.is-error?)
                        (assert.is_falsy (string.find (th.first-text r.content)
                                                      "wrote" 1 true)))))))
            (it "reports an error and keeps the file when its directory refuses the temp (#655)"
                (fn []
                  (with-tmpdir [dir]
                    (let [sub (.. dir "/ro")
                          f (.. sub "/target")]
                      (assert (sh-ok? (.. "mkdir " (h.shellquote sub))))
                      (h.write-file f "old\n")
                      (assert (sh-ok? (.. "chmod 555 " (h.shellquote sub))))
                      (let [probe (io.open (.. sub "/probe") :w)]
                        ;; Running as root ignores the mode; nothing to check then.
                        (if probe
                            (do
                              (probe:close)
                              (os.remove (.. sub "/probe")))
                            (let [r (th.execute th.registry :write
                                                {:path f :content "new\n"})]
                              (assert.is_true r.is-error?)
                              (assert.are.equal "old\n" (h.read-file f)))))
                      (sh-ok? (.. "chmod 755 " (h.shellquote sub)))))))
            (it "keeps the target's permission bits"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/script")]
                      (h.write-file f "old\n")
                      (assert (sh-ok? (.. "chmod 750 " (h.shellquote f))))
                      (let [r (th.execute th.registry :write
                                          {:path f :content "#!/bin/sh\n"})
                            lfs (require :lfs)]
                        (assert.is_false r.is-error?)
                        (assert.are.equal "rwxr-x---"
                                          (lfs.attributes f :permissions)))))))
            (it "writes through a symlink instead of replacing it"
                (fn []
                  (with-tmpdir [dir]
                    (let [real (.. dir "/real")
                          link (.. dir "/link")
                          lfs (require :lfs)]
                      (h.write-file real "old\n")
                      (assert (sh-ok? (.. "ln -s real " (h.shellquote link))))
                      (let [r (th.execute th.registry :write
                                          {:path link :content "new\n"})]
                        (assert.is_false r.is-error?)
                        (assert.are.equal :link
                                          (lfs.symlinkattributes link :mode))
                        (assert.are.equal "new\n" (h.read-file real)))))))))

(describe "edit commit (#656)"
          (fn []
            (it "a cancel at any yield of a batch applies both files or neither"
                (fn []
                  (with-tmpdir [dir]
                    (let [a (.. dir "/a")
                          b (.. dir "/b")
                          edits [{:old_string "foo" :new_string "bar"}]
                          args {:files [{:path a : edits} {:path b : edits}]}
                          reset! (fn []
                                   (h.write-file a "foo\n")
                                   (h.write-file b "foo\n"))
                          total (count-yields (fn [y]
                                                (reset!)
                                                (th.execute-coop th.registry
                                                                 :edit args y)))]
                      (assert.is_true (> total 2))
                      (for [n 1 total]
                        (reset!)
                        (let [(ok? r) (pcall th.execute-coop th.registry :edit
                                             args (cancel-on-call n))]
                          (if ok?
                              (do
                                (assert.is_false r.is-error?)
                                (assert.are.equal "bar\n" (h.read-file a))
                                (assert.are.equal "bar\n" (h.read-file b)))
                              (do
                                (assert.are.equal "foo\n" (h.read-file a))
                                (assert.are.equal "foo\n" (h.read-file b))))
                          (assert.are.same [:a :b] (entries dir))))))))
            (it "a cancelled single-file edit never hides a completed edit"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/f")
                          args {:path f
                                :edits [{:old_string "foo" :new_string "bar"}]}
                          total (count-yields (fn [y]
                                                (h.write-file f "foo\n")
                                                (th.execute-coop th.registry
                                                                 :edit args y)))]
                      (for [n 1 total]
                        (h.write-file f "foo\n")
                        (let [(ok? _) (pcall th.execute-coop th.registry :edit
                                             args (cancel-on-call n))]
                          (assert.are.equal (if ok? "bar\n" "foo\n")
                                            (h.read-file f))))))))
            (it "a batch whose second file cannot be staged changes nothing"
                (fn []
                  (with-tmpdir [dir]
                    (let [a (.. dir "/a")
                          sub (.. dir "/ro")
                          b (.. sub "/b")
                          edits [{:old_string "foo" :new_string "bar"}]]
                      (assert (sh-ok? (.. "mkdir " (h.shellquote sub))))
                      (h.write-file a "foo\n")
                      (h.write-file b "foo\n")
                      (assert (sh-ok? (.. "chmod 555 " (h.shellquote sub))))
                      (let [probe (io.open (.. sub "/probe") :w)]
                        (if probe
                            (do
                              (probe:close)
                              (os.remove (.. sub "/probe")))
                            (let [r (th.execute th.registry :edit
                                                {:files [{:path a : edits}
                                                         {:path b : edits}]})]
                              (assert.is_true r.is-error?)
                              (assert.are.equal "foo\n" (h.read-file a))
                              (assert.are.equal "foo\n" (h.read-file b))
                              (assert.are.same [:a :ro] (entries dir)))))
                      (sh-ok? (.. "chmod 755 " (h.shellquote sub)))))))))
