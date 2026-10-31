;; Known-bug probe for #623: `build-body` marks the system prompt, the last
;; tool and the last message block (3 of Anthropic's 4 breakpoints). After a
;; round of ten parallel tool calls the only message breakpoint has moved 21
;; blocks past the previous request's, beyond Anthropic's ~20-block lookback,
;; and the previous tail is not re-marked. The lookback itself is Anthropic's
;; documented behaviour and is not exercised here (no network).
;; See spec/context/FINDINGS.md (#623).

(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local types (require :fen.core.types))
(local {: known-bug} (require :fen.testing))

(fn round [history n]
  "Append one assistant turn with text + N tool calls, then their results."
  (let [base (length history)
        calls [(types.text-block "working")]]
    (for [i 1 n]
      (table.insert calls
                    (types.tool-call-block (.. "c" base "-" i) :read {:i i})))
    (table.insert history
                  (types.assistant-message {:content calls
                                            :stop-reason :tool-use}))
    (for [i 1 n]
      (table.insert history
                    (types.tool-result-message {:tool-call-id (.. "c" base "-"
                                                                  i)
                                                :tool-name :read
                                                :content [(types.text-block "ok")]})))
    history))

(fn body-for [messages]
  (am.build-body "claude-x" {:system-prompt "sys"
                             :tools [{:name :read
                                      :description "read"
                                      :parameters {:type :object}}]
                             : messages} 1024 {}))

(fn blocks [body]
  (let [out []]
    (each [_ m (ipairs body.messages)]
      (if (= (type m.content) :table)
          (each [_ b (ipairs m.content)] (table.insert out b))
          (table.insert out {:type :text})))
    out))

(fn markers [body]
  (let [all []]
    (each [_ b (ipairs (or body.system []))]
      (table.insert all b))
    (each [_ t (ipairs (or body.tools []))]
      (table.insert all t))
    (each [_ b (ipairs (blocks body))]
      (table.insert all b))
    (accumulate [n 0 _ b (ipairs all)]
      (if b.cache_control (+ n 1) n))))

(fn last-marked [bs]
  (accumulate [idx nil i b (ipairs bs)]
    (if b.cache_control i idx)))

(describe "#623 one moving message breakpoint"
          (fn []
            (it "does not re-mark the previous request's tail"
                (fn []
                  (known-bug 623
                             (fn []
                               (let [h1 (round [(types.user-message "go")] 10)
                                     req1 (body-for h1)
                                     h2 (round (icollect [_ m (ipairs h1)] m)
                                               10)
                                     req2 (body-for h2)
                                     b1 (blocks req1)
                                     b2 (blocks req2)
                                     tail1 (last-marked b1)
                                     tail2 (last-marked b2)]
                                 (and (= 3 (markers req1)) (= 3 (markers req2))
                                      (= 22 (length b1)) (= 43 (length b2))
                                      (= 21 (- tail2 tail1))
                                      (= nil (. b2 tail1 :cache_control))))))))))
