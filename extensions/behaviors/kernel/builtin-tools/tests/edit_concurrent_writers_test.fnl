;; Regression for #657: edit holds a kernel lock on the path that every fen
;; edit/write in every fen process takes (G3), and re-reads the file just
;; before the rename, failing if it changed since the read (G4, best effort:
;; a write between the check and the rename is still lost).
;; See spec/tools/FINDINGS.md ("Five guarantees").
(local th (require :fen.testing.tools))
(local process (require :fen.util.process))
(local file-mutex (require :fen.util.file_mutex))
(local path (require :fen.util.path))
(local clock (require :fen.util.clock))
(local h th.h)
(import-macros {: with-tmpdir} :fen.testing.macros)

(after_each (fn [] (h.assert-no-leaks!)))

(fn sh-ok? [cmd]
  (let [r (os.execute cmd)]
    (or (= r true) (= r 0))))

(fn lua-with-lfs []
  "A Lua interpreter on PATH that can load lfs, or nil."
  (let [p (io.popen "command -v lua lua5.4 2>/dev/null")
        out (p:read :*a)]
    (p:close)
    (var found nil)
    (each [bin (string.gmatch out "[^\n]+") &until found]
      (when (sh-ok? (.. (h.shellquote bin) " -e 'require(\"lfs\")' 2>/dev/null"))
        (set found bin)))
    found))

(local LOCK-HOLDER "local lfs = require('lfs')
local f = assert(io.open(arg[1], 'a'))
assert(lfs.lock(f, 'w'))
local ready = assert(io.open(arg[2], 'w')); ready:close()
for _ = 1, 500 do
  local r = io.open(arg[3], 'r')
  if r then r:close() break end
  os.execute('sleep 0.01')
end
f:close()
")

(describe "edit with concurrent writers (#657)"
          (fn []
            (it "fails instead of reverting a write made since the read"
                (fn []
                  (with-tmpdir [dir]
                    (let [f (.. dir "/f")]
                      (h.write-file f "x = 1\ny = 2\n")
                      (var done? false)
                      (let [r (th.execute-coop th.registry :edit
                                               {:path f
                                                :edits [{:old_string "x = 1"
                                                         :new_string "x = 10"}]}
                                               (fn []
                                                 ;; a writer outside fen's locks
                                                 (when (not done?)
                                                   (set done? true)
                                                   (h.write-file f
                                                                 "x = 1\ny = 2\nz = 3\n"))))]
                        (assert.is_true r.is-error?)
                        (assert.is_truthy (string.find (th.first-text r.content)
                                                       "changed since it was read"
                                                       1 true))
                        (assert.are.equal "x = 1\ny = 2\nz = 3\n"
                                          (h.read-file f)))))))
            (it "waits for another process holding the path's lock"
                (fn []
                  (let [lua-bin (lua-with-lfs)]
                    ;; Needs a second Lua process with lfs; skip where there is none.
                    (when lua-bin
                      (with-tmpdir [dir]
                        (let [f (.. dir "/f")
                              script (.. dir "/holder.lua")
                              ready (.. dir "/ready")
                              release (.. dir "/release")
                              lock-file (file-mutex.kernel-lock-path f)]
                          (h.write-file f "x = 1\n")
                          (h.write-file script LOCK-HOLDER)
                          (path.ensure-dir! (path.dirname lock-file))
                          (let [job (process.start-captured {:argv [lua-bin
                                                                    script
                                                                    lock-file
                                                                    ready
                                                                    release]})
                                edit (coroutine.create #(th.execute-coop th.registry
                                                                         :edit
                                                                         {:path f
                                                                          :edits [{:old_string "x = 1"
                                                                                   :new_string "x = 10"}]}
                                                                         #(coroutine.yield)))]
                            (let [(ok? err) (pcall (fn []
                                                     (let [until-ms (+ (clock.monotonic-ms)
                                                                       5000)]
                                                       (while (and (not (io.open ready
                                                                                 :r))
                                                                   (< (clock.monotonic-ms)
                                                                      until-ms))
                                                         (job:resume)
                                                         (clock.sleep-ms 10)))
                                                     (assert (io.open ready :r)
                                                             "lock holder never started")
                                                     (for [_ 1 30]
                                                       (assert (coroutine.resume edit))
                                                       (clock.sleep-ms 2))
                                                     ;; Still waiting on the other process's lock.
                                                     (assert.are.equal :suspended
                                                                       (coroutine.status edit))
                                                     (assert.are.equal "x = 1\n"
                                                                       (h.read-file f))
                                                     (h.write-file release "")
                                                     (let [until-ms (+ (clock.monotonic-ms)
                                                                       5000)]
                                                       (while (and (not= (coroutine.status edit)
                                                                         :dead)
                                                                   (< (clock.monotonic-ms)
                                                                      until-ms))
                                                         (job:resume)
                                                         (assert (coroutine.resume edit))
                                                         (clock.sleep-ms 5)))
                                                     (assert.are.equal :dead
                                                                       (coroutine.status edit))
                                                     (assert.are.equal "x = 10\n"
                                                                       (h.read-file f))))]
                              (job:abort)
                              (var done? false)
                              (while (not done?)
                                (set done? (job:resume))
                                (when (not done?) (clock.sleep-ms 5)))
                              (when (not ok?) (error err 0))))))))))))
