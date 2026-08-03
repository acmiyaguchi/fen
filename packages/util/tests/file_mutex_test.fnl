(local mutex (require :fen.util.file_mutex))
(local state (require :fen.util.file_mutex_state))
(local h (require :fen.testing))
(import-macros {: with-tmpdir : with-tmpfile} :fen.testing.macros)

(fn clear-locks! []
  (each [key _ (pairs state.locks)] (tset state.locks key nil)))

(fn resume! [co]
  (let [(ok? value) (coroutine.resume co)]
    (assert.is_true ok? value)))

(before_each clear-locks!)
(after_each clear-locks!)

(describe "fen.util.file_mutex"
  (fn []
    (it "serializes same-path cooperative mutators in FIFO order"
      (fn []
        (with-tmpfile [path ""]
          (let [events []
                holder (coroutine.create
                         #(mutex.with-file path #(coroutine.yield)
                                           #(do (table.insert events :holder-read)
                                                (coroutine.yield)
                                                (table.insert events :holder-write))))
                first (coroutine.create
                       #(mutex.with-file path #(coroutine.yield)
                                         #(table.insert events :first)))
                second (coroutine.create
                        #(mutex.with-file path #(coroutine.yield)
                                          #(table.insert events :second)))]
            (resume! holder)
            (resume! first)
            (resume! second)
            (assert.are.same [:holder-read] events)
            (resume! holder)
            (resume! first)
            (resume! second)
            (assert.are.same [:holder-read :holder-write :first :second] events)))))

    (it "does not block different paths"
      (fn []
        (with-tmpfile [a ""]
          (with-tmpfile [b ""]
            (let [events []
                  holder (coroutine.create
                           #(mutex.with-file a #(coroutine.yield)
                                             #(do (table.insert events :a-start)
                                                  (coroutine.yield)
                                                  (table.insert events :a-end))))
                  other (coroutine.create
                         #(mutex.with-file b #(coroutine.yield)
                                           #(table.insert events :b)))]
              (resume! holder)
              (resume! other)
              (assert.are.same [:a-start :b] events)
              (resume! holder))))))

    (it "shares a lock between absolute and relative spellings"
      (fn []
        (with-tmpdir [dir]
          (let [lfs (require :lfs)
                old (lfs.currentdir)]
            (h.write-file (.. dir "/file") "")
            (assert (lfs.chdir dir))
            (let [events []
                  abs (.. dir "/file")
                  holder (coroutine.create
                           #(mutex.with-file abs #(coroutine.yield)
                                             #(do (table.insert events :absolute)
                                                  (coroutine.yield))))
                  waiter (coroutine.create
                          #(mutex.with-file "./file" #(coroutine.yield)
                                            #(table.insert events :relative)))]
              (let [(ok? err) (pcall (fn []
                                       (resume! holder)
                                       (resume! waiter)
                                       (assert.are.same [:absolute] events)
                                       (resume! holder)
                                       (resume! waiter)))]
                (assert (lfs.chdir old))
                (if (not ok?) (error err)))
              (assert.are.same [:absolute :relative] events))))))

    (it "preserves live locks when the behavior module reloads"
      (fn []
        (with-tmpfile [path ""]
          (let [events []
                holder (coroutine.create
                         #(mutex.with-file path #(coroutine.yield)
                                           #(do (table.insert events :holder)
                                                (coroutine.yield))))]
            (resume! holder)
            (tset package.loaded :fen.util.file_mutex nil)
            (let [reloaded (require :fen.util.file_mutex)
                  waiter (coroutine.create
                          #(reloaded.with-file path #(coroutine.yield)
                                                #(table.insert events :waiter)))]
              (resume! waiter)
              (assert.are.same [:holder] events)
              (resume! holder)
              (resume! waiter)
              (assert.are.same [:holder :waiter] events))))))

    (it "releases the lock when the body throws"
      (fn []
        (with-tmpfile [path ""]
          (let [(ok? _) (pcall #(mutex.with-file path nil #(error "boom")))]
            (assert.is_false ok?)
            (assert.are.equal :available
                              (mutex.with-file path nil #(values :available)))))))

    (it "asserts when a synchronous mutator finds a held lock"
      (fn []
        (with-tmpfile [path ""]
          (let [holder (coroutine.create
                         #(mutex.with-file path #(coroutine.yield)
                                           #(coroutine.yield)))]
            (resume! holder)
            (let [(ok? err) (pcall #(mutex.with-file path nil #(values :never)))]
              (assert.is_false ok?)
              (assert.is_truthy (string.find (tostring err)
                                              "synchronous mutation" 1 true)))
            (resume! holder)))))))
