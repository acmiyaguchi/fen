(local subcommands (require :fen.util.subcommands))

(fn recorder []
  "Return (emit events) where emit collects into the events list."
  (let [events []]
    (values (fn [ev] (table.insert events ev)) events)))

(fn last-of [events type-key]
  (var found nil)
  (each [_ ev (ipairs events)]
    (when (= ev.type type-key)
      (set found ev)))
  found)

(describe "fen.util.subcommands"
  (fn []
    (it "requires :name and :emit"
      (fn []
        (assert.has_error (fn [] (subcommands.build {})))
        (assert.has_error (fn [] (subcommands.build {:name :x})))
        (assert.has_error (fn [] (subcommands.build {:name :x :emit 1})))))

    (it "rejects invalid default and subcommand handlers"
      (fn []
        (let [(emit _) (recorder)]
          (assert.has_error
            (fn [] (subcommands.build {:name :x :emit emit :default "bad"})))
          (assert.has_error
            (fn [] (subcommands.build {:name :x :emit emit
                                       :subcommands {:bad {}}})))
          (assert.has_error
            (fn [] (subcommands.build {:name :x :emit emit
                                       :subcommands {:bad "nope"}}))))))

    (it "dispatches a matching subcommand with trim/lowercase"
      (fn []
        (let [(emit _) (recorder)
              seen []
              sub (subcommands.build
                    {:name :mem :emit emit
                     :subcommands
                       {:gc {:description "gc"
                             :handler (fn [rest st]
                                        (table.insert seen [:gc rest st]))}}})]
          (sub.handler "  GC  " {:id 1})
          (assert.are.equal 1 (length seen))
          (assert.are.equal :gc (. seen 1 1))
          (assert.are.equal "" (. seen 1 2))
          (assert.are.equal 1 (. (. seen 1 3) :id)))))

    (it "passes the remaining argument string to the subcommand handler"
      (fn []
        (let [(emit _) (recorder)
              seen []
              sub (subcommands.build
                    {:name :mem :emit emit
                     :subcommands
                       {:set {:handler (fn [rest _] (table.insert seen rest))}}})]
          (sub.handler "set  a b  c" {})
          (assert.are.equal "a b  c" (. seen 1)))))

    (it "calls :default for a bare invocation"
      (fn []
        (let [(emit _) (recorder)
              seen []
              sub (subcommands.build
                    {:name :mem :emit emit
                     :default (fn [rest _] (table.insert seen [:default rest]))
                     :subcommands {:gc {:handler (fn [] nil)}}})]
          (sub.handler "" {})
          (sub.handler "   " {})
          (sub.handler nil {})
          (assert.are.equal 3 (length seen))
          (each [_ call (ipairs seen)]
            (assert.are.equal :default (. call 1))
            (assert.are.equal "" (. call 2))))))

    (it "renders help on /cmd help and does not touch handlers"
      (fn []
        (let [(emit events) (recorder)
              called []
              sub (subcommands.build
                    {:name :mem :emit emit
                     :summary "Memory diagnostics"
                     :subcommands
                       {:gc {:description "force a GC pass"
                             :handler (fn [] (table.insert called :gc))}
                        :off {:description "hide the panel"
                              :handler (fn [] (table.insert called :off))}}})]
          (sub.handler "help" {})
          (assert.are.equal 0 (length called))
          (let [ev (last-of events :info)]
            (assert.is_not_nil ev)
            (assert.is_not_nil (string.find ev.text "/mem" 1 true))
            (assert.is_not_nil (string.find ev.text "Memory diagnostics" 1 true))
            (assert.is_not_nil (string.find ev.text "gc" 1 true))
            (assert.is_not_nil (string.find ev.text "force a GC pass" 1 true))
            (assert.is_not_nil (string.find ev.text "off" 1 true))))))

    (it "emits an error plus help for an unknown subcommand"
      (fn []
        (let [(emit events) (recorder)
              sub (subcommands.build
                    {:name :mem :emit emit
                     :subcommands {:gc {:handler (fn [] nil)}}})]
          (sub.handler "bogus" {})
          (let [err (last-of events :error)
                info (last-of events :info)]
            (assert.is_not_nil err)
            (assert.is_not_nil (string.find err.error "unknown subcommand" 1 true))
            (assert.is_not_nil (string.find err.error "bogus" 1 true))
            (assert.is_not_nil info)
            (assert.is_not_nil (string.find info.text "gc" 1 true))))))

    (it "routes unmatched words to :default when default-takes-args?"
      (fn []
        (let [(emit events) (recorder)
              seen []
              sub (subcommands.build
                    {:name :resume :emit emit
                     :default-takes-args? true
                     :default (fn [args _] (table.insert seen args))
                     :subcommands {}})]
          (sub.handler "abc123" {})
          (assert.are.equal "abc123" (. seen 1))
          ;; No error emitted for the free-form argument.
          (assert.is_nil (last-of events :error)))))

    (it "lets a declared :help subcommand override generated help"
      (fn []
        (let [(emit events) (recorder)
              called []
              sub (subcommands.build
                    {:name :x :emit emit
                     :subcommands
                       {:help {:description "custom help"
                               :handler (fn [] (table.insert called :help))}}})]
          (sub.handler "help" {})
          (assert.are.equal 1 (length called))
          (assert.is_nil (last-of events :info)))))

    (it "exposes a completion descriptor with sorted subcommand names"
      (fn []
        (let [(emit _) (recorder)
              sub (subcommands.build
                    {:name :mem :emit emit
                     :subcommands
                       {:off {:description "hide" :handler (fn [] nil)}
                        :gc {:description "gc" :handler (fn [] nil)}
                        :on {:description "show" :handler (fn [] nil)}}})]
          (assert.are.equal :mem sub.descriptor.name)
          (let [names (icollect [_ e (ipairs sub.descriptor.subcommands)] e.name)]
            (assert.are.same ["gc" "off" "on"] names)))))

    (it "complete returns subcommand choices including help"
      (fn []
        (let [(emit _) (recorder)
              sub (subcommands.build
                    {:name :mem :emit emit
                     :subcommands {:gc {:description "gc"
                                        :handler (fn [] nil)}}})
              choices (sub.complete "" {})]
          (var saw-gc? false)
          (var saw-help? false)
          (each [_ c (ipairs choices)]
            (when (= c.value "gc") (set saw-gc? true))
            (when (= c.value "help") (set saw-help? true)))
          (assert.is_true saw-gc?)
          (assert.is_true saw-help?))))

    (it "omits the generated help entry when :help is declared"
      (fn []
        (let [(emit _) (recorder)
              sub (subcommands.build
                    {:name :x :emit emit
                     :subcommands {:help {:description "custom"
                                          :handler (fn [] nil)}}})
              choices (sub.complete "" {})]
          (var help-count 0)
          (each [_ c (ipairs choices)]
            (when (= c.value "help") (set help-count (+ help-count 1))))
          (assert.are.equal 1 help-count))))

    (it "generates a usage string from subcommand names"
      (fn []
        (let [(emit _) (recorder)
              with-default (subcommands.build
                             {:name :mem :emit emit
                              :default (fn [] nil)
                              :subcommands {:gc {:handler (fn [] nil)}
                                            :off {:handler (fn [] nil)}}})
              no-default (subcommands.build
                           {:name :x :emit emit
                            :subcommands {:a {:handler (fn [] nil)}}})]
          (assert.are.equal "/mem [gc|off|help]" with-default.usage)
          (assert.are.equal "/x <a|help>" no-default.usage)
          (assert.are.equal with-default.usage
                            with-default.descriptor.usage))))

    (it "keeps a declared :help subcommand from duplicating generated usage"
      (fn []
        (let [(emit _) (recorder)
              sub (subcommands.build
                    {:name :x :emit emit
                     :subcommands {:help {:handler (fn [] nil)}}})]
          (assert.are.equal "/x <help>" sub.usage))))

    (it "accepts subcommands given as a list of entries"
      (fn []
        (let [(emit _) (recorder)
              seen []
              sub (subcommands.build
                    {:name :x :emit emit
                     :subcommands
                       [{:name :one :handler (fn [] (table.insert seen :one))}
                        {:name :two :handler (fn [] (table.insert seen :two))}]})]
          (sub.handler "TWO" {})
          (assert.are.equal :two (. seen 1)))))))
