;; M4 (issue #167): input-phase stalls must log event/buffer diagnostics.
;; Input stalls carry no coroutine stack, so warn-if-stalled! is the only
;; place to surface what the TUI was chewing on (e.g. a huge bracketed paste).

(local tui-test (require :fen.testing.tui))
(tui-test.install-termbox-stub!)
(tui-test.install-markdown-stub!)

(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local process (require :fen.util.process))
(local log (require :fen.util.log))

;; Capture log.warn output and drive monotonic-ms deterministically so a
;; stall can be forced without real elapsed time.
(local saved {:mono process.monotonic-ms :warn log.warn})
(var now-ms 0)
(var warns [])

(fn install! []
  (set now-ms 1000000)
  (set warns [])
  (set process.monotonic-ms (fn [] now-ms))
  (set log.warn (fn [line] (table.insert warns line)))
  (set state.last-stall-warn-ms 0)
  (set state.input-buf "")
  (set state.paste-buffer "")
  (set state.paste-active? false)
  (set state.status-info {}))

(fn restore! []
  (set process.monotonic-ms saved.mono)
  (set log.warn saved.warn))

(describe "tui input-stall diagnostics"
  (fn []
    (before_each install!)
    (after_each restore!)

    (it "input-meta surfaces the event and buffer sizes"
      (fn []
        (set state.input-buf (string.rep "a" 42))
        (set state.paste-buffer (string.rep "p" 7))
        (set state.paste-active? true)
        (let [meta (tui.input-meta {:type 1 :key 27 :ch 0 :mod 8})]
          (assert.is_truthy (string.find meta "event=1" 1 true))
          (assert.is_truthy (string.find meta "key=27" 1 true))
          (assert.is_truthy (string.find meta "mod=8" 1 true))
          (assert.is_truthy (string.find meta "paste=true" 1 true))
          (assert.is_truthy (string.find meta "paste_bytes=7" 1 true))
          (assert.is_truthy (string.find meta "buf_bytes=42" 1 true)))))

    (it "logs phase=input with metadata when the input phase stalls"
      (fn []
        (set state.input-buf (string.rep "x" 100))
        ;; start 600ms before "now" → elapsed 600 > 250 threshold.
        (tui.warn-if-stalled! :input (- now-ms 600) nil {:type 1 :key 13 :ch 0})
        (assert.are.equal 1 (length warns))
        (let [line (. warns 1)]
          (assert.is_truthy (string.find line "phase=input" 1 true))
          (assert.is_truthy (string.find line "elapsed_ms=600" 1 true))
          (assert.is_truthy (string.find line "event=1" 1 true))
          (assert.is_truthy (string.find line "buf_bytes=100" 1 true)))))

    (it "does not log when the input phase is under threshold"
      (fn []
        (tui.warn-if-stalled! :input (- now-ms 10) nil {:type 1 :key 13})
        (assert.are.equal 0 (length warns))))

    (it "omits input metadata for tick-phase stalls"
      (fn []
        (tui.warn-if-stalled! :tick (- now-ms 600) nil)
        (assert.are.equal 1 (length warns))
        (let [line (. warns 1)]
          (assert.is_truthy (string.find line "phase=tick" 1 true))
          (assert.is_nil (string.find line "buf_bytes=" 1 true)))))))
