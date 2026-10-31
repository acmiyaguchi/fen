;; Trace replay: Quint traces of spec/network/model.qnt (module `current`) are
;; fed through the real TUI ingest, and the resulting transcript must match the
;; model's `tui` state. Run by spec/network/conform.sh, which generates the
;; traces and sets FEN_SPEC_ITF_INDEX; not part of `make test`.

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local events (require :fen.core.extensions.events))
(local json (require :fen.util.json))

(local MAIN (.. (or (os.getenv :FEN_SPEC_ITF_MAIN) :current) "::network::"))

(fn reset! []
  (test-api.reset!)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 10 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!))

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn tok-text [tok]
  (.. "t" (int tok.turn) "a" (int tok.attempt) "i" (int tok.idx) ";"))

(fn bus-event [e]
  (case e.tag
    :User {:type :user :text "u"}
    :LlmStart {:type :llm-start}
    :TextDelta
    {:type :assistant-text-delta :content-index 1 :delta (tok-text e.value)}
    :HostedStart {:type :hosted-tool :phase :start :name "web_search" :id "ws"}
    :HostedEnd {:type :hosted-tool
                :phase :end
                :name "web_search"
                :id "ws"
                :status "completed"
                :detail "q"}
    :ProviderRetry {:type :provider-retry
                    :attempt 2
                    :max-attempts 2
                    :delay-ms 0
                    :reason "curl: recv"}
    :LlmEnd {:type :llm-end}
    :StreamEnd {:type :assistant-stream-end :final? true}
    :Error {:type :error :error "boom"}
    :Cancelled {:type :cancelled}
    other (error (.. "replay: unmapped model event " (tostring other)))))

(local KIND {:user :user
             :assistant-text :assistant
             :error :error
             :cancelled :cancelled
             :info :info})

(fn real-rows []
  (icollect [_ row (ipairs state.transcript)]
    (.. (or (. KIND row.type) (.. "?" (tostring row.type))) ":"
        (if (= row.type :assistant-text)
            (or (and row.text-chunks (table.concat row.text-chunks ""))
                row.text "")
            ""))))

(fn model-rows [tui-state]
  (icollect [_ row (ipairs tui-state.rows)]
    (.. row.kind ":" (table.concat (icollect [_ tok (ipairs row.toks)]
                                     (tok-text tok))
                                   ""))))

(fn open-rows []
  (accumulate [n 0 _ _ (pairs (or state.streaming-assistant-rows {}))]
    (+ n 1)))

(fn read-file [path]
  (with-open [f (assert (io.open path :r))]
    (f:read :a)))

(local index (os.getenv :FEN_SPEC_ITF_INDEX))

(describe "spec/network trace replay against TUI ingest"
          (fn []
            (if (not index)
                (pending "set FEN_SPEC_ITF_INDEX (run spec/network/conform.sh)")
                (each [path (string.gmatch (read-file index) "[^\n]+")]
                  (it path
                      (fn []
                        (reset!)
                        (let [itf (json.decode (read-file path))
                              last (. itf.states (length itf.states))
                              emitted (. last (.. MAIN "emitted"))
                              model-tui (. last (.. MAIN "tui"))]
                          (each [_ e (ipairs emitted)]
                            (events.emit (bus-event e)))
                          (assert.are.same (model-rows model-tui) (real-rows))
                          (assert.are.equal (if (>= (int model-tui.open) 0) 1 0)
                                            (open-rows)))))))))
