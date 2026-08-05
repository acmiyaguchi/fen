(local log-sink (require :fen.util.log_sink))
(local log (require :fen.util.log))

(fn reset! []
  (log-sink.close!)
  (set log-sink.recent [])
  (set log-sink.next-seq 0)
  (set log-sink.level nil)
  (set log-sink.fallback nil))

(describe "util.log runtime level"
  (fn []
    (it "defaults to the FEN_LOG env level (info) when unset"
      (fn []
        (reset!)
        ;; info threshold: debug suppressed, info/warn/error enabled.
        (assert.is_false (log.enabled? :debug))
        (assert.is_true (log.enabled? :info))
        (assert.is_true (log.enabled? :warn))))

    (it "set-level! lowers the threshold at runtime to enable debug"
      (fn []
        (reset!)
        (assert.is_false (log.enabled? :debug))
        (assert.is_true (log.set-level! :debug))
        (assert.is_true (log.enabled? :debug))))

    (it "set-level! raises the threshold at runtime to suppress info"
      (fn []
        (reset!)
        (assert.is_true (log.enabled? :info))
        (assert.is_true (log.set-level! :error))
        (assert.is_false (log.enabled? :info))
        (assert.is_false (log.enabled? :warn))
        (assert.is_true (log.enabled? :error))))

    (it "set-level! returns false and leaves the level unchanged for unknown names"
      (fn []
        (reset!)
        (log.set-level! :warn)
        (assert.is_false (log.set-level! :nonsense))
        (assert.is_false (log.enabled? :info))
        (assert.is_true (log.enabled? :warn))))

    (it "keeps a host-set level across a reloadable behavior re-require"
      (fn []
        (reset!)
        (log.set-level! :debug)
        (tset package.loaded :fen.util.log nil)
        (let [reloaded (require :fen.util.log)]
          ;; The env default would suppress debug; the held level does not.
          (assert.is_true (reloaded.enabled? :debug)))))))

(describe "util.log fallback seam"
  (fn []
    (it "routes the no-sink fallback through an injected writer"
      (fn []
        (reset!)
        (let [captured []]
          (set log-sink.fallback (fn [line] (table.insert captured line)))
          (log.warn "no-sink-here")
          (assert.are.equal 1 (length captured))
          (assert.is_truthy (string.find (. captured 1) "no-sink-here" 1 true))
          (assert.is_truthy (string.find (. captured 1) "[warn]" 1 true)))))

    (it "still records the line in the recent ring when using the fallback"
      (fn []
        (reset!)
        (set log-sink.fallback (fn [_line] nil))
        (let [cursor (log.cursor)]
          (log.error "ring-and-fallback")
          (let [records (log.list-recent cursor)]
            (assert.are.equal 1 (length records))
            (assert.are.equal :error (. records 1 :level))
            (assert.are.equal "ring-and-fallback" (. records 1 :message))))))

    (it "surfaces a line through the fallback when the active sink write fails"
      (fn []
        (reset!)
        (let [p (.. (or (os.getenv :TMPDIR) "/tmp") "/fen-log-test-"
                    (tostring (os.time)) "-" (tostring (math.random 1000000)))
              captured []]
          (log-sink.open! p)
          (set log-sink.fallback (fn [line] (table.insert captured line)))
          ;; Close the underlying handle so the next write-line fails and
          ;; clears the sink, forcing the fallback path.
          (pcall #(log-sink.handle:close))
          (log.error "sink-failed")
          (assert.are.equal 1 (length captured))
          (assert.is_truthy (string.find (. captured 1) "sink-failed" 1 true))
          (assert.is_false (log-sink.active?))
          (os.remove p))))

    (it "suppressed levels neither record nor hit the fallback"
      (fn []
        (reset!)
        (log.set-level! :error)
        (let [captured []
              cursor (log.cursor)]
          (set log-sink.fallback (fn [line] (table.insert captured line)))
          (log.info "quiet")
          (assert.are.equal 0 (length captured))
          (assert.are.equal 0 (length (log.list-recent cursor))))))))
