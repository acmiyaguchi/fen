;; Known-bug probe for #619, presenters side: the real JSON presenter, the
;; real agent, and the mock provider, after a --continue replay put one
;; earlier turn (1500 tokens) in agent.messages. `usage` and `messages` cover
;; the replayed turn too, on a successful turn and on a failed one.
;; (The context-side probe is issue_619_json_usage_includes_replay_test.fnl.)
;; See spec/presenters/FINDINGS.md and spec/context/FINDINGS.md (#619).

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local mock (require :fen.extensions.provider_mock.mock_provider))
(local json-presenter (require :fen.extensions.json))
(local {: known-bug} (require :fen.testing))

(fn usage [n]
  {:input n :output 0 :cache-read 0 :cache-write 0 :total-tokens n})

(fn run-json [reply]
  "One headless JSON turn after a replayed exchange; returns (code blob)."
  (test-api.reset!)
  (let [p {}]
    (each [k v (pairs mock)] (tset p k v))
    (set p.name :mock)
    (register-registry.register :provider p :test))
  (let [agent (agent-mod.make-agent {:provider-name :mock
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
            (it "reports the replayed turn's usage as this turn's"
                (fn []
                  (known-bug 619
                             (fn []
                               (let [(code blob) (run-json {:text "new"
                                                            :usage (usage 15)})]
                                 (and (= 0 code) (= "new" blob.final-text)
                                      (= 1515 (. blob :usage :total-tokens))
                                      (= 4 (length blob.messages))))))))
            (it "reports only replayed usage for a failed turn"
                (fn []
                  (known-bug 619
                             (fn []
                               (let [(code blob) (run-json {:error "boom"})]
                                 (and (= 1 code) (= nil blob.final-text)
                                      (= "error" blob.stop-reason)
                                      (= 1500 (. blob :usage :total-tokens))))))))))
