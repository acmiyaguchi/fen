(local h (require :fen.testing))
(local lfs (require :lfs))

(local module :fen.util.durable_store)

(fn fresh-store [?lfs]
  (let [saved-lfs (. package.loaded :lfs)]
    (tset package.loaded module nil)
    (when ?lfs (tset package.loaded :lfs ?lfs))
    (let [store (require module)]
      (tset package.loaded :lfs saved-lfs)
      (tset package.loaded module nil)
      store)))

(describe "fen.util.durable_store"
          (fn []
            (var tmp nil)
            (before_each (fn [] (set tmp (h.make-tmpdir))))
            (after_each (fn [] (when tmp (h.rmtree tmp))))
            (it "returns the body's value and releases the lock on error"
                (fn []
                  (let [store (fresh-store)
                        lock (.. tmp "/x.lock")]
                    (assert.equal 42 (store.with-lock lock nil #42))
                    (let [(ok? err) (pcall store.with-lock lock nil
                                           #(error :boom 0))]
                      (assert.is_false ok?)
                      (assert.equal :boom err))
                    (assert.equal :again (store.with-lock lock nil #:again))
                    ;; the lock inode is kept, never renamed or removed
                    (assert.equal :file (lfs.attributes lock :mode)))))
            (it "errors without running the body when the OS lock stays busy"
                (fn []
                  (let [store (fresh-store (setmetatable {:lock (fn [] nil)}
                                                         {:__index lfs}))
                        ran? false
                        (ok? err) (pcall store.with-lock (.. tmp "/y.lock") nil
                                         #(set-forcibly! ran? true)
                                         {:timeout-ms 30})]
                    (assert.is_false ok?)
                    (assert.truthy (string.find (tostring err) "lock busy" 1
                                                true))
                    (assert.is_false ran?))))
            (it "replaces the target atomically and leaves no temp file on failure"
                (fn []
                  (let [store (fresh-store)
                        target (.. tmp "/data.json")]
                    (store.write-private! target "one")
                    (store.write-private! target "two")
                    (let [f (io.open target :r)]
                      (assert.equal "two" (f:read "*a"))
                      (f:close))
                    ;; a directory in the way makes the rename fail
                    (let [blocked (.. tmp "/blocked")]
                      (lfs.mkdir blocked)
                      (let [f (io.open (.. blocked "/keep") :w)]
                        (f:write "x")
                        (f:close))
                      (assert.is_false (pcall store.write-private! blocked
                                              "secret")))
                    (let [names []]
                      (each [name (lfs.dir tmp)]
                        (when (and (not= name ".") (not= name ".."))
                          (table.insert names name)))
                      (table.sort names)
                      (assert.same [:blocked :data.json] names)))))))
