;; One-shot structured presenter: writes the result blob to FEN_JSON_OUTPUT_PATH (a file avoids stdout corruption) or stdout.

(local agent-mod (require :fen.core.agent))
(local events (require :fen.core.extensions.events))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local json (require :fen.util.json))
(local text (require :fen.util.text))
(local turn-result (require :fen.util.turn_result))
(local sub-events (require :fen.extensions.subagent.events))
(local headless-progress (require :fen.util.headless_progress))

(local M {})

(local TRANSCRIPT-OWNER :json-subagent-transcript)

(fn encode-blob [blob]
  "Encode the result blob, falling back to dropping :messages if the full
   structure is not JSON-encodable, then to a minimal all-strings blob if even
   that fails — so the child always writes a decodable result rather than
   crashing and leaving the parent with no output file."
  (let [(ok? encoded) (pcall json.encode blob)]
    (if ok?
        encoded
        (do (set blob.messages nil)
            (tset blob :messages-error "messages omitted: not JSON-encodable")
            (let [(ok2? encoded2) (pcall json.encode blob)]
              (if ok2?
                  encoded2
                  (json.encode {:final-text (tostring (?. blob :final-text))
                                :error "result not JSON-encodable"})))))))

(fn output-path [state]
  "Resolve where the result blob is written: an explicit opts override (used in
   tests) wins, then FEN_JSON_OUTPUT_PATH; nil means stdout."
  (or (text.blank->nil (?. state :opts :json-output-file))
      (text.blank->nil (os.getenv :FEN_JSON_OUTPUT_PATH))))

(fn write-output [path text]
  "Write TEXT to PATH when given, else stdout. Returns true on success."
  (if path
      (let [(f err) (io.open path :w)]
        (if f
            (do (f:write text) (f:write "\n") (f:close) true)
            (do (io.stderr:write (.. "json presenter: cannot write "
                                     path ": " (tostring err) "\n"))
                false)))
      (do (print text) true)))

(fn transcript-path [state]
  "Subagent canonical transcript sidecar: opts override (tests), then env."
  (or (text.blank->nil (?. state :opts :subagent-transcript-file))
      (text.blank->nil (os.getenv :FEN_SUBAGENT_TRANSCRIPT_PATH))))

(fn attach-transcript! [state path]
  "Replay a restarted subagent's prior canonical conversation into the agent
   and append every new canonical message to the same transcript, so a later
   restart can resume this attempt too. Returns the replayed message count."
  (let [agent state.agent
        (prior _stats) (sub-events.read-transcript path)]
    ;; Plain inserts like session replay: the token ledger does not see these
    ;; messages, which is harmless because --print children never compact.
    (each [_ m (ipairs prior)]
      (table.insert agent.messages m))
    (events.unregister-by-owner TRANSCRIPT-OWNER)
    (events.on :message-appended
               (fn [ev]
                 (when (= ev.agent agent)
                   (let [(ok? err) (sub-events.append-transcript-message! path ev.message)]
                     (when (not ok?)
                       (io.stderr:write (.. "json presenter: cannot write subagent transcript: "
                                            (tostring err) "\n"))))))
               TRANSCRIPT-OWNER)
    (length prior)))

(fn suffix [messages start]
  (let [out []]
    (for [i start (length messages)]
      (table.insert out (. messages i)))
    out))

;; @doc fen.extensions.json.run
;; kind: function
;; signature: (run ctx) -> exit-code
;; summary: Step the agent once and write a structured JSON result blob. Returns a non-zero CLI exit code (1) when the turn failed or the output could not be written, and 0 otherwise, leaving the process exit to the CLI layer.
;; tags: json presenter run
(fn M.run [ctx]
  (let [state ctx.state
        prompt (or (?. state :opts :print) ctx.prompt)]
    (when (not prompt)
      (error "json presenter requires a prompt"))
    (let [tpath (transcript-path state)
          replayed (if tpath (attach-transcript! state tpath) 0)
          (ok? result) (xpcall #(agent-mod.step state.agent prompt) debug.traceback)]
      (when tpath (events.unregister-by-owner TRANSCRIPT-OWNER))
      (turn-lifecycle.emit-complete! state ok? result)
      (let [agent state.agent
            ;; Replayed history belongs to earlier attempts, whose usage the
            ;; parent already accounted; report only this invocation's turn.
            messages (suffix (or (?. agent :messages) []) (+ replayed 1))
            asst (turn-result.last-assistant messages)
            ;; ok? alone is insufficient: failures surface as assistant stop-reason :error or a final :tool-use.
            failed? (turn-result.failed? ok? messages)
            blob {:final-text (if failed? nil result)
                  :messages messages
                  :usage (turn-result.sum-usage messages)
                  :stop-reason (?. asst :stop-reason)
                  :error (if failed? (tostring result) nil)}
            wrote? (write-output (output-path state) (encode-blob blob))]
        (if (or failed? (not wrote?)) 1 0)))))

(fn maybe-subagent-events [api]
  (let [event-path (text.blank->nil (os.getenv :FEN_SUBAGENT_EVENT_PATH))]
    (when event-path
      (api.on :*
              (fn [ev]
                (let [(ok? err) (sub-events.append! event-path ev)]
                  (when (not ok?)
                    (io.stderr:write (.. "json presenter: cannot write subagent event: "
                                         (tostring err) "\n")))))))))

(fn M.register [api]
  (headless-progress.register api)
  (maybe-subagent-events api)
  (api.on :error
          (fn [ev]
            (io.stderr:write (.. "error: " (tostring ev.error) "\n"))))
  (api.register :presenter
                {:name :json
                 :active? true
                 :init (fn [_ctx] nil)
                 :run (fn [ctx] (M.run ctx))
                 :shutdown (fn [_ctx] nil)})
  true)

M
