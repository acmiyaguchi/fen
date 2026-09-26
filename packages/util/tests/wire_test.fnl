(local json (require :fen.util.json))
(local wire (require :fen.util.wire))

(local FIXTURES "./packages/util/tests/fixtures/wire/")

(fn fixture-lines [name]
  (let [out []]
    (each [line (io.lines (.. FIXTURES name))]
      (when (not= line "") (table.insert out line)))
    out))

(fn deep-equal? [a b]
  (if (and (= (type a) :table) (= (type b) :table))
      (do
        (var same true)
        (each [k v (pairs a)]
          (when (not (deep-equal? v (. b k))) (set same false)))
        (each [k _ (pairs b)]
          (when (= (. a k) nil) (set same false)))
        same)
      (= a b)))

(fn covered-types [lines direction]
  (let [seen {}]
    (each [_ line (ipairs lines)]
      (let [msg (wire.decode line direction)]
        (when msg (tset seen msg.type true))))
    seen))

(describe "fen.util.wire golden fixtures"
  (fn []
    (each [_ fx (ipairs [{:file "events.jsonl" :direction :event
                            :types wire.EVENT-TYPES}
                           {:file "controls.jsonl" :direction :control
                            :types wire.CONTROL-TYPES}])]
      (it (.. "accepts every line of " fx.file)
        (fn []
          (each [_ line (ipairs (fixture-lines fx.file))]
            (let [(msg rej) (wire.decode line fx.direction)]
              (assert.is_nil rej (.. line " -> " (tostring (?. rej :reason))))
              (assert.are.equal wire.VERSION msg.v)))))

      (it (.. "covers every " fx.direction " type in " fx.file)
        (fn []
          (let [seen (covered-types (fixture-lines fx.file) fx.direction)]
            (each [typ _ (pairs fx.types)]
              (assert.is_true (= true (. seen typ)) (.. "no fixture for " typ))))))

      (it (.. "round-trips " fx.file " through encode and decode")
        (fn []
          (each [_ line (ipairs (fixture-lines fx.file))]
            (let [msg (wire.decode line fx.direction)
                  encoded (assert (wire.encode msg fx.direction))
                  again (assert (wire.decode encoded fx.direction))]
              (assert.is_true (deep-equal? msg again) line)))))

      (it (.. "receives " fx.file " as one monotonic stream")
        (fn []
          (let [rx (wire.receiver fx.direction)]
            (each [_ line (ipairs (fixture-lines fx.file))]
              (let [(msg rej) (wire.receive! rx line)]
                (assert.is_nil rej line)
                (assert.are.equal rx.seq msg.seq)))))))

    (it "rejects every invalid fixture with its expected code, never throwing"
      (fn []
        (let [cases (fixture-lines "invalid.jsonl")]
          (assert.is_true (> (length cases) 0))
          (each [_ raw (ipairs cases)]
            (let [fx (json.decode raw)
                  (ok? msg rej) (pcall wire.decode fx.line fx.direction)]
              (assert.is_true ok? fx.line)
              (assert.is_nil msg fx.line)
              (assert.are.equal fx.code rej.code fx.line)
              (assert.are.equal :string (type rej.reason))
              (assert.are.equal (= fx.code "version-mismatch") rej.fatal?))))))))

(describe "fen.util.wire envelope"
  (fn []
    (it "stamps monotonic seqs and only advances on success"
      (fn []
        (let [tx (wire.sender :control "subagent-2")
              first (assert (wire.next! tx :prompt {:text "go"}))
              (bad rej) (wire.next! tx :steer {})
              second (assert (wire.next! tx :cancel))]
          (assert.is_nil bad)
          (assert.are.equal :invalid-payload rej.code)
          (assert.are.equal 2 rej.seq)
          (assert.are.equal 1 (. (json.decode first) :seq))
          (assert.are.equal 2 (. (json.decode second) :seq))
          (assert.are.equal "subagent-2" (. (json.decode second) :run))
          (assert.are.equal 2 tx.seq))))

    (it "keeps envelope fields over payload fields of the same name"
      (fn []
        (let [msg (wire.message :prompt "r" 3 {:text "x" :v 9 :seq 99
                                                :type :steer :run "other"})]
          (assert.are.equal 1 msg.v)
          (assert.are.equal 3 msg.seq)
          (assert.are.equal :prompt msg.type)
          (assert.are.equal "r" msg.run))))

    (it "rejects non-increasing seqs and still consumes rejected payload seqs"
      (fn []
        (let [rx (wire.receiver :control)
              line (fn [seq typ ?payload]
                     (json.encode (wire.message typ "r" seq ?payload)))]
          (assert (wire.receive! rx (line 1 :prompt {:text "go"})))
          (let [(msg rej) (wire.receive! rx (line 2 :steer))]
            (assert.is_nil msg)
            (assert.are.equal :invalid-payload rej.code)
            (assert.are.equal 2 rx.seq))
          (let [(msg rej) (wire.receive! rx (line 2 :cancel))]
            (assert.is_nil msg)
            (assert.are.equal :out-of-order rej.code)
            ;; The stale seq was already consumed; an ack must not name it.
            (assert.is_nil rej.seq)
            (assert.is_nil (. (wire.rejection-ack rej) :ref)))
          (assert (wire.receive! rx (line 5 :cancel)))
          (assert.are.equal 5 rx.seq))))

    (it "keeps huge or infinite seqs from poisoning the receiver"
      (fn []
        (let [rx (wire.receiver :control)]
          (each [_ seq (ipairs ["1e300" "1e400" "9007199254740992"])]
            (let [(msg rej) (wire.receive! rx (.. "{\"v\":1,\"seq\":" seq
                                                  ",\"type\":\"cancel\",\"run\":\"r\"}"))]
              (assert.is_nil msg)
              (assert.are.equal :invalid rej.code)
              (assert.is_nil rej.seq)))
          (assert.are.equal 0 rx.seq)
          (assert (wire.receive! rx (json.encode (wire.message :cancel "r" 1)))))))

    (it "treats a version mismatch as fatal before seq ordering"
      (fn []
        (let [rx (wire.receiver :event)
              (msg rej) (wire.receive! rx "{\"v\":2,\"seq\":1,\"type\":\"ready\",\"run\":\"r\"}")]
          (assert.is_nil msg)
          (assert.are.equal :version-mismatch rej.code)
          (assert.is_true rej.fatal?)
          (assert.are.equal 0 rx.seq))))

    (it "builds a valid control-ack for a rejection, with or without a seq"
      (fn []
        (let [tx (wire.sender :event "r")
              (_ with-seq) (wire.decode "{\"v\":1,\"seq\":4,\"type\":\"pause\",\"run\":\"r\"}" :control)
              (_ no-seq) (wire.decode "not json" :control)
              acked (assert (wire.next! tx :control-ack (wire.rejection-ack with-seq)))
              bare (assert (wire.next! tx :control-ack (wire.rejection-ack no-seq)))]
          (assert.are.equal 4 (. (json.decode acked) :ref))
          (assert.are.equal "rejected" (. (json.decode acked) :status))
          (assert.is_nil (. (json.decode bare) :ref)))))

    (it "rejects lines that a bounded drain could never consume"
      (fn []
        (let [big (string.rep "x" wire.MAX-LINE-BYTES)
              (line rej) (wire.encode (wire.message :prompt "r" 1 {:text big}) :control)
              (msg drej) (wire.decode (.. "\"" big "\"") :control)]
          (assert.is_nil line)
          (assert.are.equal :too-large rej.code)
          (assert.is_nil msg)
          (assert.are.equal :too-large drej.code))))

    (it "never throws on non-table, non-string, or unknown-direction input"
      (fn []
        (let [(m1 r1) (wire.validate "x" :event)
              (m2 r2) (wire.decode 42 :event)
              (m3 r3) (wire.validate (wire.message :ready "r" 1) :sideways)]
          (assert.is_nil m1)
          (assert.are.equal :invalid r1.code)
          (assert.is_nil m2)
          (assert.are.equal :malformed r2.code)
          (assert.is_nil m3)
          (assert.are.equal :invalid r3.code))))

    (it "classifies types by direction"
      (fn []
        (assert.is_true (wire.event-type? :result))
        (assert.is_false (wire.event-type? :steer))
        (assert.is_true (wire.control-type? :finalize))
        (assert.is_false (wire.control-type? :exit))))))

(describe "fen.util.wire display normalization"
  (fn []
    (it "copies run metadata onto normalized events"
      (fn []
        (let [ev (wire.normalize {:type :user :text "hi"}
                                 {:run-id "subagent-1" :agent "scout"
                                  :cwd "/w" :bogus "dropped"})]
          (assert.are.equal "subagent-1" ev.run-id)
          (assert.are.equal "scout" ev.agent)
          (assert.are.equal "/w" ev.cwd)
          (assert.is_nil ev.bogus)
          (assert.are.equal "hi" ev.summary))))

    (it "coerces odd bus event fields so wire types stay schema-valid"
      (fn []
        (let [tx (wire.sender :event "subagent-1")
              evs [{:type :tool-call :id 7 :name {:odd true} :arguments [1 2]}
                   {:type :tool-result :id 7 :tool-call-id 7 :name "read"
                    :duration-seconds "slow" :result "plain text"}
                   {:type :assistant-text :text {:parts ["a"]} :content-index 1.5}
                   {:type :assistant-text-delta :delta 42 :content-index "2"}
                   {:type :assistant-thinking :text json.null :final? true}
                   {:type :user :text ["a" "b"]}
                   {:type :llm-start :provider {:id "p"} :model 3}
                   {:type :llm-end :stop-reason {:why "x"} :usage "lots"}
                   {:type :agent-started :provider :p :model :m :cwd 5}
                   {:type :agent-turn-complete :status {:s 1} :error {:e 1}}
                   {:type :error :error {:message "boom"} :source {:ext "x"}}
                   {:type :assistant-stream-end}
                   {:type :steering-injected :text 1}
                   {:type :follow-up-injected}]]
          (each [_ ev (ipairs evs)]
            (let [out (wire.normalize ev {:run-id 12 :agent "scout"})
                  (line rej) (wire.next! tx ev.type out)]
              (assert.is_nil rej (.. ev.type " -> " (tostring (?. rej :reason))))
              (assert.is_string line))))))

    (it "produces payloads the event schema accepts"
      (fn []
        (let [tx (wire.sender :event "subagent-1")]
          (each [_ ev (ipairs [{:type :tool-call :id "c1" :name "read"
                                :arguments {:path "README.md"}}
                               {:type :tool-result :id "c1" :name "read"
                                :tool-call-id "c1"
                                :result {:content [{:type :text :text "ok"}]}}
                               {:type :assistant-text :text "done" :final? true}
                               {:type :llm-end :stop-reason :stop
                                :usage {:input 1 :output 2}}
                               {:type :error :error "boom"}])]
            (let [(line rej) (wire.next! tx ev.type (wire.normalize ev {:run-id "subagent-1"}))]
              (assert.is_nil rej (.. ev.type " -> " (tostring (?. rej :reason))))
              (assert.is_string line))))))

    (it "preserves bounded canonical display payloads"
      (fn []
        (let [delta (wire.normalize
                      {:type :assistant-text-delta :delta "hello"
                       :content-index 2} {})
              call (wire.normalize
                     {:type :tool-call :id "c1" :name "read"
                      :arguments {:path "README.md"}} {})
              result (wire.normalize
                       {:type :tool-result :id "c1" :name "read"
                        :result {:content [{:type :text
                                           :text (string.rep "x" 20000)}]}} {})]
          (assert.are.equal "hello" delta.delta)
          (assert.are.equal 2 delta.content-index)
          (assert.are.equal "README.md" call.arguments.path)
          (assert.are.equal :text (. result.result.content 1 :type))
          (assert.is_true result.transport-truncated?)
          (assert.is_true (< (length (json.encode result))
                             wire.EVENT-PAYLOAD-BYTES)))))

    (it "reads bounded batches of complete lines through a line reader"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))
              reader (wire.line-reader p)]
          (for [i 1 100]
            (f:write (.. "line-" i) "\n"))
          (f:close)
          (let [(first first-status) (wire.read-lines! reader)
                (second second-status) (wire.read-lines! reader)
                (third) (wire.read-lines! reader)]
            (wire.close-reader! reader)
            (os.remove p)
            (assert.are.equal :ok first-status)
            (assert.are.equal wire.DRAIN-EVENT-BUDGET (length first))
            (assert.are.equal :ok second-status)
            (assert.are.equal (- 100 wire.DRAIN-EVENT-BUDGET) (length second))
            (assert.are.same [] third)))))

    (it "reads complete raw lines and leaves a partial tail for later"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))
              reader (wire.line-reader p)]
          (f:write "one\n\ntwo\npart")
          (f:close)
          (let [(lines status) (wire.read-lines! reader)]
            (assert.are.equal :ok status)
            (assert.are.same ["one" "" "two"] lines)
            (assert.are.equal 9 reader.offset)
            (let [g (assert (io.open p :a))]
              (g:write "ial\n")
              (g:close))
            (let [(more) (wire.read-lines! reader)]
              (wire.close-reader! reader)
              (os.remove p)
              (assert.are.same ["partial"] more))))))

    (it "reports a missing file, then reads it once it appears"
      (fn []
        (let [p (os.tmpname)
              _ (os.remove p)
              reader (wire.line-reader p)
              (lines status) (wire.read-lines! reader)]
          (assert.are.same [] lines)
          (assert.are.equal :missing status)
          (let [f (assert (io.open p :w))]
            (f:write "late\n")
            (f:close))
          (let [(later) (wire.read-lines! reader)]
            (wire.close-reader! reader)
            (os.remove p)
            (assert.are.same ["late"] later)))))

    (it "returns an unterminated oversized line once and skips its rest"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))
              reader (wire.line-reader p)]
          (f:write (string.rep "x" (+ wire.MAX-LINE-BYTES 10)) "\nnext\n")
          (f:close)
          (let [(lines) (wire.read-lines! reader)
                (rest) (wire.read-lines! reader)]
            (wire.close-reader! reader)
            (os.remove p)
            (assert.are.equal 1 (length lines))
            (assert.are.same ["next"] rest)
            (let [(_msg rej) (wire.decode (. lines 1) :control)]
              (assert.are.equal :too-large rej.code))))))

    (it "reports a file truncated below the consumed offset"
      (fn []
        (let [p (os.tmpname)
              f (assert (io.open p :w))
              reader (wire.line-reader p)]
          (f:write "one\ntwo\n")
          (f:close)
          (wire.read-lines! reader)
          (let [g (assert (io.open p :w))]
            (g:close))
          (let [(lines status) (wire.read-lines! reader)]
            (wire.close-reader! reader)
            (os.remove p)
            (assert.are.same [] lines)
            (assert.are.equal :truncated status)))))))
