;; Producer conformance: Quint traces of spec/network/model.qnt drive the real
;; event producer, and the events it emits and the TUI states they lead to are
;; compared with the model's step by step. Run by spec/network/conform.sh,
;; which generates the traces and sets FEN_SPEC_ITF_INDEX; not part of
;; `make test`.
;;
;; The boundary is the HTTP backend: each trace's actions become a scripted
;; transport (SSE chunks of the OpenAI Responses stream, transient failures,
;; terminal failures) under the real `turn_submit` -> `agent.step` ->
;; `llm.complete` -> `openai_responses` -> `provider_shared.streaming` ->
;; `retry.with-retry` -> `fen.util.http` chain. A cancel sets the turn's
;; cancel flag at the next cooperative yield, as Ctrl-C does. Nothing touches
;; the network.
;;
;; Per trace it checks:
;; - the events the code emits, projected onto the model's alphabet, equal
;;   the model's `emitted` list;
;; - after every model step, the real TUI state (rows, open streaming rows,
;;   hosted-tool flag, retrying flag) equals the model's `tui`;
;; - the assistant history equals the model's `history`.

(local testing (require :fen.testing))
;; The scripted transport replaces the HTTP backend before any provider
;; module captures `fen.util.http`.
(local transport {:respond nil})
(testing.stub-http! (fn [opts] (transport.respond opts)))

(local tui-test (require :fen.testing.tui))
(local tb (tui-test.install-termbox-stub! {:capture? true :cols 80 :rows 10}))
(tui-test.install-markdown-stub!)

(local test-api (require :fen.core.extensions.test_api))
(local register-registry (require :fen.core.extensions.register))
(local state (require :fen.extensions.tui.state))
(local tui (require :fen.extensions.tui))
(local paint (require :fen.extensions.tui.paint))
(local events (require :fen.core.extensions.events))
(local agent-mod (require :fen.core.agent))
(local turn-submit (require :fen.turn_submit))
(local openai-responses
       (require :fen.extensions.provider_openai.openai_responses))

(local types (require :fen.core.types))
(local json (require :fen.util.json))

(local MAIN (.. (or (os.getenv :FEN_SPEC_ITF_MAIN) :current) "::network::"))
(local MAX-RESUMES 2000)

(fn field [st name]
  (. st (.. MAIN name)))

(fn int [v]
  (if (= (type v) :table) (tonumber (. v "#bigint")) v))

(fn tok-text [turn attempt idx]
  (.. "t" turn "a" attempt "i" idx ";"))

;; ---- model side ----

(fn model-event [e]
  (if (= e.tag :TextDelta)
      (.. "TextDelta:" (tok-text (int e.value.turn) (int e.value.attempt)
                                 (int e.value.idx)))
      e.tag))

(fn model-rows [tui-state]
  (icollect [_ row (ipairs tui-state.rows)]
    (.. row.kind ":" (table.concat (icollect [_ tok (ipairs row.toks)]
                                     (tok-text (int tok.turn) (int tok.attempt)
                                               (int tok.idx)))
                                   ""))))

(fn model-view [tui-state]
  {:rows (model-rows tui-state)
   :open (if (>= (int tui-state.open) 0) 1 0)
   :hosted tui-state.hosted
   :retrying tui-state.retrying})

(fn model-history [history]
  (icollect [_ m (ipairs history)]
    (.. m.outcome ":" (table.concat (icollect [_ tok (ipairs m.toks)]
                                      (tok-text (int tok.turn)
                                                (int tok.attempt) (int tok.idx)))
                                    ""))))

;; ---- real side ----

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

(fn real-view []
  (let [running (or state.status-info.running-tools {})]
    {:rows (real-rows)
     :open (accumulate [n 0 _ _ (pairs (or state.streaming-assistant-rows {}))]
             (+ n 1))
     :hosted (accumulate [h false key (pairs running)]
               (or h (= (string.sub (tostring key) 1 12) "hosted-tool:")))
     :retrying (= true state.status-info.retrying?)}))

(fn project [ev]
  "The model alphabet's name for a bus event, or nil for events the model
   does not track (message-appended and the like)."
  (case ev.type
    :user :User
    :llm-start :LlmStart
    :assistant-text-delta (do
                            (assert (= ev.content-index 1)
                                    (.. "delta on content index "
                                        (tostring ev.content-index)))
                            (.. "TextDelta:" ev.delta))
    :hosted-tool (if (= ev.phase :start) :HostedStart :HostedEnd)
    :provider-retry :ProviderRetry
    :llm-end :LlmEnd
    :assistant-stream-end (if ev.final? :StreamEnd :StreamEndNotFinal)
    :error :Error
    :cancelled :Cancelled
    _ nil))

(fn real-history [agent]
  (icollect [_ m (ipairs agent.messages)]
    (when (= m.role :assistant)
      (case m.stop-reason
        :stop (.. "ok:" (types.assistant-text m))
        :error "error:"
        :aborted "aborted:"
        other (.. "?" (tostring other) ":")))))

;; ---- scripted SSE ----

(fn sse [obj]
  (.. "data: " (json.encode obj) "\n\n"))

(fn web-search [id phase]
  (if (= phase :start)
      (sse {:type "response.output_item.added"
            :item {:type "web_search_call" : id :status "in_progress"}})
      (sse {:type "response.output_item.done"
            :item {:type "web_search_call"
                   : id
                   :status "completed"
                   :action {:type "search" :query "q"}}})))

(fn transient-response [turn attempt]
  "Vary the transient failure across the three kinds retry accepts."
  (case (% (+ turn attempt) 3)
    0 {:status 500 :body "server error" :headers {}}
    1 {:error "recv failure" :curl-code 56}
    _ {:status 200 :body "" :headers {}}))

;; 2xx without a terminal event

(fn reset-tui! []
  (test-api.reset!)
  (tb.clear)
  (tui-test.reset-state! {:cols 80 :rows 10 :markdown? false})
  (tui.register (test-api.make-runtime-api :tui))
  (set state.tb-initialized? true)
  (paint.ensure-state-defaults!))

(fn register-provider! []
  (register-registry.register :provider
                              {:name :spec-network
                               :api :openai-responses
                               :complete openai-responses.complete}
                              :test))

(fn replay [actions]
  "Run the actions of one trace through the real producer. Returns
   {:events [projected] :views [view after the k-th projected event, from 0]
    :agent agent}."
  (let [projected []
        views [(real-view)]
        emit (fn [ev]
               (events.emit ev)
               (let [p (project ev)]
                 (when p
                   (table.insert projected p)
                   (table.insert views (real-view)))))
        agent (agent-mod.make-agent {:provider-name :spec-network
                                     :model "gpt-test"
                                     :api-key "sk-test"
                                     :on-event emit
                                     :provider-options {:retry-max-attempts 2
                                                        :retry-base-delay-ms 0
                                                        :retry-max-delay-ms 0}})
        turn-state {: agent}
        cur {:i 1 :turn 0 :attempt 0 :hosted 0}]
    (fn peek [] (. actions cur.i))

    (fn take! []
      (let [a (. actions cur.i)]
        (set cur.i (+ cur.i 1))
        a))

    (fn respond [opts]
      ;; One HTTP attempt: play actions until the attempt ends.
      (set cur.attempt (+ cur.attempt 1))
      (var idx 0)
      (var text "")
      (var result nil)
      (while (= result nil)
        ;; A transport tick: the driver may deliver a cancel here.
        (opts.yield)
        (case (peek)
          :streamToken
          (let [delta (tok-text cur.turn cur.attempt idx)]
            (take!)
            (when (= idx 0)
              (opts.on-chunk (sse {:type "response.output_item.added"
                                   :item {:type "message"
                                          :id "msg"
                                          :role "assistant"
                                          :content []}})))
            (opts.on-chunk (sse {:type "response.output_text.delta" : delta}))
            (set text (.. text delta))
            (set idx (+ idx 1)))
          :hostedStart
          (do
            (take!)
            (set cur.hosted (+ cur.hosted 1))
            (opts.on-chunk (web-search (.. "ws" cur.hosted) :start)))
          :hostedEnd
          (do
            (take!)
            (opts.on-chunk (web-search (.. "ws" cur.hosted) :end)))
          :complete
          (do
            (take!)
            (opts.on-chunk (sse {:type "response.output_item.done"
                                 :item {:type "message"
                                        :id "msg"
                                        :role "assistant"
                                        :content [{:type "output_text" : text}]}}))
            (opts.on-chunk (sse {:type "response.completed"
                                 :response {:status "completed"
                                            :usage {:input_tokens 1
                                                    :output_tokens 1
                                                    :total_tokens 2}}}))
            (set result {:status 200 :body "" :headers {}}))
          :transient
          (do
            (take!)
            (set result (transient-response cur.turn cur.attempt)))
          :permanent
          (do
            (take!)
            (set result {:status 400 :body "bad request" :headers {}}))
          nil
          nil
          ;; trace over: keep the attempt open
          other
          (error (.. "replay: action " (tostring other)
                     " reached the transport"))))
      result)

    (set transport.respond respond)
    (var resumes 0)
    (while (<= cur.i (length actions))
      (let [a (peek)
            live? (and turn-state.turn
                       (not= (coroutine.status turn-state.turn) :dead))]
        (if (and (= a :startTurn) (not live?))
            (do
              (take!)
              (set cur.turn (+ cur.turn 1))
              (set cur.attempt 0)
              ;; The presenter clears busy? when it sees the turn end.
              (set turn-state.busy? false)
              (let [r (turn-submit.submit! turn-state "u" {:emit-user? true}
                                           agent-mod.step emit)]
                (assert r.started "replay: turn did not start")))
            (not live?)
            (error (.. "replay: " (tostring a) " with no running turn"))
            (do
              ;; At a cooperative yield: a cancel or the end of a backoff
              ;; happens here; everything else is played by the transport.
              ;; (A startTurn while the turn is live lets it finish first.)
              (when (= a :cancel)
                (take!)
                (set turn-state.cancel-requested? true))
              (when (= a :backoffDone)
                (take!))
              (set resumes (+ resumes 1))
              (when (> resumes MAX-RESUMES)
                (error "replay: the producer made no progress"))
              (let [(ok? err) (coroutine.resume turn-state.turn)]
                (when (not ok?)
                  (error (.. "replay: turn raised: " (tostring err)))))))))
    ;; Let a finished turn run to its end (stream-end after the last yield).
    (while (and turn-state.turn (not= (coroutine.status turn-state.turn) :dead)
                (< resumes MAX-RESUMES)
                (let [h agent.messages
                      last (. h (length h))]
                  ;; only when the turn has ended in the model: its assistant
                  ;; message is in, or a cancel is pending
                  (or turn-state.cancel-requested?
                      (and last (= last.role :assistant)))))
      (set resumes (+ resumes 1))
      (coroutine.resume turn-state.turn))
    (set transport.respond nil)
    {:events projected : views : agent}))

(fn read-file [path]
  (with-open [f (assert (io.open path :r))]
    (f:read :a)))

(fn describe-view [v]
  (.. "rows=" (table.concat v.rows " | ") " open=" v.open " hosted="
      (tostring v.hosted) " retrying=" (tostring v.retrying)))

(local index (os.getenv :FEN_SPEC_ITF_INDEX))

(describe "spec/network producer conformance (turn_submit -> agent -> openai_responses -> retry -> http stub -> TUI ingest)"
          (fn []
            (if (not index)
                (pending "set FEN_SPEC_ITF_INDEX (run spec/network/conform.sh)")
                (each [path (string.gmatch (read-file index) "[^\n]+")]
                  (it path
                      (fn []
                        (reset-tui!)
                        (register-provider!)
                        (let [itf (json.decode (read-file path))
                              states itf.states
                              actions (fcollect [i 2 (length states)]
                                        (field (. states i) :lastAction))
                              last (. states (length states))
                              real (replay actions)
                              want-events (icollect [_ e (ipairs (field last
                                                                        :emitted))]
                                            (model-event e))]
                          (assert.are.same want-events real.events)
                          ;; Step by step: model state i shows the TUI after
                          ;; its first #emitted events.
                          (each [i st (ipairs states)]
                            (let [k (length (field st :emitted))
                                  want (model-view (field st :tui))
                                  got (. real.views (+ k 1))]
                              (when (not (and (= (table.concat want.rows "\n")
                                                 (table.concat got.rows "\n"))
                                              (= want.open got.open)
                                              (= want.hosted got.hosted)
                                              (= want.retrying got.retrying)))
                                (error (.. "state " i " ("
                                           (tostring (field st :lastAction))
                                           ")\n  model " (describe-view want)
                                           "\n  real  " (describe-view got))))))
                          (assert.are.same (model-history (field last :history))
                                           (real-history real.agent)))))))))
