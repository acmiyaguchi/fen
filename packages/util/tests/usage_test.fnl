(local usage (require :fen.util.usage))

(describe "fen.util.usage"
  (fn []
    (it "exposes the canonical field list in display order"
      (fn []
        (assert.are.same [:input :output :cache-read :cache-write :reasoning
                          :total-tokens]
                         usage.USAGE-FIELDS)))

    (it "canonicalizes provider snake_case keys and derives a missing total"
      (fn []
        (let [canon (usage.canonical-usage {:prompt_tokens 10
                                            :completion_tokens 4
                                            :cache_read_input_tokens 2
                                            :latency-ms 999})]
          (assert.are.equal 10 canon.input)
          (assert.are.equal 4 canon.output)
          (assert.are.equal 2 canon.cache-read)
          (assert.are.equal 14 canon.total-tokens)
          (assert.is_nil canon.latency-ms))))

    (it "prefers an explicit reported total over the derived one"
      (fn []
        (let [canon (usage.canonical-usage {:input 10 :output 4 :total 99})]
          (assert.are.equal 99 canon.total-tokens))))

    (it "returns nil for empty or non-table usage"
      (fn []
        (assert.is_nil (usage.canonical-usage nil))
        (assert.is_nil (usage.canonical-usage {}))
        (assert.is_nil (usage.canonical-usage {:latency-ms 5}))))

    (it "flags a derived total as estimated in provenance"
      (fn []
        (let [prov (usage.usage-provenance {:input 10 :output 4})]
          (assert.are.equal :provider-reported prov.input)
          (assert.are.equal :provider-reported prov.output)
          (assert.are.equal :estimated prov.total-tokens))
        (let [prov (usage.usage-provenance {:input 10 :output 4 :total-tokens 14})]
          (assert.are.equal :provider-reported prov.total-tokens))
        (let [prov (usage.usage-provenance {:input 10} :events)]
          (assert.are.equal :events prov.input))))

    (it "explicit-total? detects reported totals only"
      (fn []
        (assert.is_true (usage.explicit-total? {:total_tokens 5}))
        (assert.is_false (not (not (usage.explicit-total? {:input 1}))))))

    (it "adds usage field-wise keeping only positive results"
      (fn []
        (let [sum (usage.add-usage {:input 3 :output 1 :cache-read 0}
                                   {:input 2 :reasoning 5})]
          (assert.are.equal 5 sum.input)
          (assert.are.equal 1 sum.output)
          (assert.are.equal 5 sum.reasoning)
          (assert.is_nil sum.cache-read))))

    (it "subtracts usage field-wise dropping non-positive results"
      (fn []
        (let [diff (usage.subtract-usage {:input 10 :output 5 :reasoning 2}
                                         {:input 4 :output 5 :reasoning 3})]
          (assert.are.equal 6 diff.input)
          (assert.is_nil diff.output)
          (assert.is_nil diff.reasoning))))

    (it "merges provenance treating estimated as sticky"
      (fn []
        (let [merged (usage.merge-provenance {:input :provider-reported
                                              :total-tokens :estimated}
                                             {:input :provider-reported}
                                             {:input true :total-tokens true})]
          (assert.are.equal :provider-reported merged.input)
          (assert.are.equal :estimated merged.total-tokens))))

    (it "add-usage! accumulates numeric fields in place without deriving total"
      (fn []
        (let [totals {}]
          (usage.add-usage! totals {:input 3 :output 2 :latency-ms 7})
          (usage.add-usage! totals {:input 1})
          (usage.add-usage! totals nil)
          (assert.are.equal 4 totals.input)
          (assert.are.equal 2 totals.output)
          (assert.is_nil totals.total-tokens)
          (assert.is_nil totals.latency-ms))))

    (it "ensure-total! derives total-tokens only when absent"
      (fn []
        (let [totals {:input 3 :output 2}]
          (usage.ensure-total! totals)
          (assert.are.equal 5 totals.total-tokens))
        (let [totals {:input 3 :output 2 :total-tokens 99}]
          (usage.ensure-total! totals)
          (assert.are.equal 99 totals.total-tokens))
        (let [totals {}]
          (usage.ensure-total! totals)
          (assert.is_nil totals.total-tokens))))

    (it "usage-total prefers a reported total then derives input+output"
      (fn []
        (assert.are.equal 7 (usage.usage-total {:total-tokens 7 :input 1}))
        (assert.are.equal 5 (usage.usage-total {:input 3 :output 2}))
        (assert.is_nil (usage.usage-total nil))))

    (it "copy-usage-acc shallow-copies accumulator sub-tables"
      (fn []
        (let [acc {:totals {:input 3} :current {:input 1}
                   :provenance {:input :provider-reported}
                   :turns 2 :source :events}
              copied (usage.copy-usage-acc acc)]
          (assert.are.same acc.totals copied.totals)
          (assert.are.equal 2 copied.turns)
          (assert.are.equal :events copied.source)
          (set copied.totals.input 99)
          (assert.are.equal 3 acc.totals.input)
          (assert.is_nil (usage.copy-usage-acc nil)))))))
