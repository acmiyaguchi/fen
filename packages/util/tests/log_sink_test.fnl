(local log-sink (require :fen.util.log_sink))
(local log (require :fen.util.log))

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn tmp-path [name]
  (.. (or (os.getenv :TMPDIR) "/tmp") "/fen-log-sink-test-" (tostring (os.time))
      "-" (tostring (math.random 1000000)) "-" name))

(describe "util.log_sink"
  (fn []
    (it "is inactive before open!"
      (fn []
        (log-sink.close!)
        (assert.is_false (log-sink.active?))))

    (it "opens a file in append mode and reports active?"
      (fn []
        (let [p (tmp-path "open")
              (ok? err) (log-sink.open! p)]
          (assert.is_true ok?)
          (assert.is_nil err)
          (assert.is_true (log-sink.active?))
          (log-sink.write-line "hello")
          (log-sink.write-line "world")
          (log-sink.close!)
          (assert.is_false (log-sink.active?))
          (let [data (read-file p)]
            (assert.is_truthy data)
            (assert.is_truthy (string.find data "hello\n" 1 true))
            (assert.is_truthy (string.find data "world\n" 1 true)))
          (os.remove p))))

    (it "appends across reopens of the same file"
      (fn []
        (let [p (tmp-path "append")]
          (log-sink.open! p)
          (log-sink.write-line "first")
          (log-sink.close!)
          (log-sink.open! p)
          (log-sink.write-line "second")
          (log-sink.close!)
          (let [data (read-file p)]
            (assert.is_truthy (string.find data "first" 1 true))
            (assert.is_truthy (string.find data "second" 1 true)))
          (os.remove p))))

    (it "returns false + err when path is unwritable"
      (fn []
        (let [(ok? err) (log-sink.open! "/this/path/does/not/exist/log")]
          (assert.is_false ok?)
          (assert.is_truthy err)
          (assert.is_false (log-sink.active?)))))

    (it "closes prior sink even when new open! fails"
      (fn []
        (let [p (tmp-path "prior")]
          (log-sink.open! p)
          (assert.is_true (log-sink.active?))
          (let [(ok? _err) (log-sink.open! "/this/path/does/not/exist/log")]
            (assert.is_false ok?))
          (assert.is_false (log-sink.active?))
          (os.remove p))))

    (it "write-line is a no-op when inactive"
      (fn []
        (log-sink.close!)
        ;; Should not raise.
        (let [(ok? err) (log-sink.write-line "discarded")]
          (assert.is_true ok?)
          (assert.is_nil err))
        (assert.is_false (log-sink.active?))))

    (it "clears the sink and returns the error after a write failure"
      (fn []
        (let [p (tmp-path "fail")]
          (log-sink.open! p)
          (assert.is_true (log-sink.active?))
          ;; Force the next write to throw by closing the underlying handle
          ;; out from under the sink. write-line's pcall should observe the
          ;; failure, clear the handle, and propagate ok?=false.
          (pcall #(log-sink.handle:close))
          (let [(ok? err) (log-sink.write-line "boom")]
            (assert.is_false ok?)
            (assert.is_truthy err))
          (assert.is_false (log-sink.active?))
          (os.remove p))))

    (it "clears the sink on disk-full (nil, err return from write/flush)"
      (fn []
        ;; /dev/full is a Linux special: every write succeeds for write()
        ;; but FILE:write/flush surface ENOSPC as (nil, errmsg) WITHOUT
        ;; throwing. This is exactly the case a naive pcall guard misses.
        (let [f (io.open "/dev/full" :r)]
          (if (not f)
              ;; Not Linux — skip silently rather than fail.
              (assert.is_true true)
              (do (f:close)
                  (log-sink.open! "/dev/full")
                  (assert.is_true (log-sink.active?))
                  (let [(ok? err) (log-sink.write-line "won't fit")]
                    (assert.is_false ok?)
                    (assert.is_truthy err))
                  (assert.is_false (log-sink.active?)))))))))

(describe "util.log routing"
  (fn []
    (it "routes warn through the sink when active"
      (fn []
        (let [p (tmp-path "warn")]
          (log-sink.open! p)
          (log.warn "stalled-thing")
          (log-sink.close!)
          (let [data (read-file p)]
            (assert.is_truthy data)
            (assert.is_truthy (string.find data "[warn]" 1 true))
            (assert.is_truthy (string.find data "stalled-thing" 1 true)))
          (os.remove p))))

    (it "stamps an ISO8601 timestamp on sink-routed lines"
      (fn []
        (let [p (tmp-path "ts")]
          (log-sink.open! p)
          (log.warn "tagged")
          (log-sink.close!)
          (let [data (read-file p)]
            (assert.is_truthy
              (string.find data "^%[%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ%]")))
          (os.remove p))))))
