;; Focused tests for owner-tagged durable extension logs.

(local state (require :fen.core.extensions.state))
(local logs (require :fen.core.extensions.logs))
(local json (require :fen.util.json))
(local stderr-log (require :fen.util.log))
(import-macros {: with-tmpdir} :fen.testing.macros)

(fn reset! []
  (set state.logs [])
  (set state.log-path nil))

(describe "core.extensions.logs"
  (fn []
    (before_each reset!)

    (it "appends sanitized JSONL records and mirrors through the FEN_LOG-gated writer"
      (fn []
        (with-tmpdir [dir]
          (let [old-info stderr-log.info
                mirrored []]
            (set state.log-path (.. dir "/logs.jsonl"))
            (tset stderr-log :info (fn [text] (table.insert mirrored text)))
            (let [rec (logs.record! :session-jsonl :info
                                    {:retry-count 3 :api-key "secret"})]
              (tset stderr-log :info old-info)
              (assert.are.equal "session-jsonl" rec.owner)
              (assert.are.equal "info" rec.level)
              (assert.is_nil (string.find rec.msg "secret" 1 true))
              (assert.is_truthy (string.find rec.msg "[redacted]" 1 true))
              (assert.are.equal 1 (length mirrored))
              (assert.is_truthy (string.find (. mirrored 1) "[session-jsonl]" 1 true))
              (let [f (assert (io.open state.log-path :r))
                    line (f:read :l)]
                (f:close)
                (let [decoded (json.decode line)]
                  (assert.are.equal "session-jsonl" decoded.owner)
                  (assert.are.equal "info" decoded.level)
                  (assert.is_truthy decoded.timestamp)
                  (assert.is_nil (string.find decoded.msg "secret" 1 true)))))))))

    (it "redacts Authorization headers, message content, and raw-string secrets"
      (fn []
        (with-tmpdir [dir]
          (let [old-info stderr-log.info]
            (set state.log-path (.. dir "/logs.jsonl"))
            (tset stderr-log :info (fn [_] nil))
            (let [header-rec (logs.record! :http :info {:headers {:Authorization "Bearer top-secret"}})
                  content-rec (logs.record! :chat :info {:messages [{:content "do not persist this"}]})
                  string-rec (logs.record! :raw :info "Bearer token-value sk-ABC123 token=very-secret")]
              (tset stderr-log :info old-info)
              (assert.is_nil (string.find header-rec.msg "top-secret" 1 true))
              (assert.is_truthy (string.find header-rec.msg "[redacted]" 1 true))
              (assert.is_nil (string.find content-rec.msg "do not persist this" 1 true))
              (assert.is_nil (string.find string-rec.msg "token-value" 1 true))
              (assert.is_nil (string.find string-rec.msg "ABC123" 1 true))
              (assert.is_nil (string.find string-rec.msg "very-secret" 1 true))))))

    (it "does no file write for a debug record gated by the default log level"
      (fn []
        (with-tmpdir [dir]
          (let [old-enabled stderr-log.enabled?]
            (set state.log-path (.. dir "/logs.jsonl"))
            (tset stderr-log :enabled? (fn [level] (not= level :debug)))
            (assert.is_nil (logs.record! :quiet :debug "Bearer should-not-be-processed"))
            (tset stderr-log :enabled? old-enabled)
            (assert.are.equal 0 (length (logs.list)))
            (assert.is_nil (io.open state.log-path :r))))))

    (it "evicts oldest records from the 500-entry ring"
      (fn []
        (with-tmpdir [dir]
          (let [old-info stderr-log.info]
            (set state.log-path (.. dir "/logs.jsonl"))
            ;; Stub the existing writer: production FEN_LOG threshold behavior
            ;; remains centralized in fen.util.log rather than duplicated here.
            (tset stderr-log :info (fn [_] nil))
            (for [i 1 501] (logs.record! :chatty :info (tostring i)))
            (tset stderr-log :info old-info)
            (assert.are.equal 500 (length (logs.list)))
            (assert.are.equal "2" (. (logs.list) 1 :msg))
            (assert.are.equal "501" (. (logs.list) 500 :msg)))))))))
