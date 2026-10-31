;; Known-bug probe for #621: `fen.util.usage` defines total-tokens as
;; input + output (cache excluded), and Anthropic follows it, but the OpenAI
;; Chat Completions adapter keeps the provider's total_tokens (cache included)
;; and a gateway that omits it yields 0, which usage-totals keeps.
;; See spec/context/FINDINGS.md (#621).

(local oc (require :fen.extensions.provider_openai.openai_completions))
(local am (require :fen.extensions.provider_anthropic.anthropic_messages))
(local tokens (require :fen.util.tokens))
(local {: known-bug} (require :fen.testing))

(fn openai-resp [usage]
  {:choices [{:message {:role :assistant :content "ok"} :finish_reason :stop}]
   : usage})

(describe "#621 total-tokens convention"
          (fn []
            (it "differs between adapters for the same token counts"
                (fn []
                  (known-bug 621
                             (fn []
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
                                     sum (tokens.usage-totals [o a])]
                                 (and (= 20 o.usage.input a.usage.input)
                                      (= 80 o.usage.cache-read
                                         a.usage.cache-read)
                                      (= 105 o.usage.total-tokens)
                                      (= 25 a.usage.total-tokens)
                                      (= 0 g.usage.total-tokens)
                                      (= 130 sum.total-tokens)
                                      (= 50 (+ sum.input sum.output))))))))))
