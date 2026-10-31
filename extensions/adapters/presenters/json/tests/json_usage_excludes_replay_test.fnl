;; Regression for #619: after a --continue replay, the JSON presenter reports
;; only this invocation's usage (the usage ledger delta), on a successful turn
;; and on a failed one. The real presenter, agent, and mock provider run.
;; See spec/context/FINDINGS.md (#619).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local events (require :fen.core.extensions.events))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local json-presenter (require :fen.extensions.json))

(fn usage [n]
  {:input n :output 0 :cache-read 0 :cache-write 0 :total-tokens n})

(fn run-json [reply]
  "One headless JSON turn after a replayed exchange; returns (code blob)."
  (test-api.reset!)
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test))
  (let [agent (agent-mod.make-agent {:on-event events.emit
                                     :provider-name :mock
                                     :model "mock"
                                     :api-key :test
                                     :provider-options {:mock-script (fn [_]
                                                                       reply)}})
        out-path (os.tmpname)]
    ;; what session_lifecycle.start! replays on --continue
    (table.insert agent.messages (types.user-message "earlier"))
    (table.insert agent.messages
                  (types.assistant-message {:content [(types.text-block "earlier answer")]
                                            :usage (usage 1500)
                                            :stop-reason :stop}))
    (let [code (json-presenter.run {:state {: agent
                                            :opts {:print "new"
                                                   :json-output-file out-path}}})
          f (assert (io.open out-path :r))
          blob (json.decode (f:read :*a))]
      (f:close)
      (os.remove out-path)
      (test-api.reset!)
      (values code blob))))

(describe "#619 json presenter after --continue (real agent)"
          (fn []
            (it "reports only this turn's usage, not the replayed turn's"
                (fn []
                  (let [(code blob) (run-json {:text "new" :usage (usage 15)})]
                    (assert.are.equal 0 code)
                    (assert.are.equal "new" blob.final-text)
                    (assert.are.equal 15 (. blob :usage :total-tokens)))))
            (it "reports none of the replayed usage for a failed turn"
                (fn []
                  (let [(code blob) (run-json {:error "boom"})]
                    (assert.are.equal 1 code)
                    (assert.is_nil blob.final-text)
                    (assert.are.equal "error" blob.stop-reason)
                    (assert.are.equal 0 (or (?. blob :usage :total-tokens) 0)))))))
