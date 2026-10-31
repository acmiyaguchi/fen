;; #621: total-tokens is input + output (cache excluded) on every adapter, so
;; usage-totals sums one convention. The OpenAI adapter ignores the provider's
;; total_tokens (cache included) and a gateway that omits it still gets a total.

(local oc (require :fen.extensions.provider_openai.openai_completions))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local tokens (require :fen.util.tokens))

(fn openai-resp [usage]
  {:choices [{:message {:role :assistant :content "ok"} :finish_reason :stop}]
   : usage})

(describe "#621 total-tokens convention"
          (fn []
            (it "is input + output for the same token counts on every adapter"
                (fn []
                  (do
                    (do
                      ;; 20 uncached + 80 cached prompt tokens, 5 output
                      (let [o (oc.parse-response (openai-resp {:prompt_tokens 100
                                                               :completion_tokens 5
                                                               :total_tokens 105
                                                               :prompt_tokens_details {:cached_tokens 80}})
                                                 "m")
                            a (am.parse-response {:content [{:type :text
                                                             :text "ok"}]
                                                  :stop_reason :end_turn
                                                  :usage {:input_tokens 20
                                                          :output_tokens 5
                                                          :cache_read_input_tokens 80
                                                          :cache_creation_input_tokens 0}}
                                                 "claude-x")
                            g (oc.parse-response (openai-resp {:prompt_tokens 25
                                                               :completion_tokens 5})
                                                 "m")
                            sum (tokens.usage-totals [o a g])]
                        (assert.is_true (and (= 20 o.usage.input a.usage.input)
                                             (= 80 o.usage.cache-read
                                                a.usage.cache-read)
                                             (= 25 o.usage.total-tokens)
                                             (= 25 a.usage.total-tokens)
                                             (= 30 g.usage.total-tokens)
                                             (= 80 sum.total-tokens)
                                             (= 80 (+ sum.input sum.output)))))))))))
