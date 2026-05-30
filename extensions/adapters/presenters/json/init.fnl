;; One-shot structured presenter used by `fen --presenter json --print TEXT`.
;;
;; Like the print presenter, it performs exactly one agent step and returns so
;; the shared presenter runner can flush/close/shutdown. Instead of printing the
;; final text, it serializes a structured result blob — {final-text, messages,
;; usage, stop-reason, error} — to FEN_JSON_OUTPUT_PATH (a file, to avoid
;; corruption from any child log output merged onto stdout/stderr), or to stdout
;; when the env var is unset. Designed for the subagent extension to consume.

(local agent-mod (require :fen.core.agent))
(local turn-lifecycle (require :fen.turn_lifecycle))
(local json (require :fen.util.json))

(local M {})

(fn last-assistant [messages]
  "Return the most recent assistant message, or nil. Usage and stop-reason for
   the turn live on this message (agent.fnl appends one per provider call)."
  (let [msgs (or messages [])]
    (var found nil)
    (for [i (length msgs) 1 -1 &until found]
      (let [m (. msgs i)]
        (when (= m.role :assistant)
          (set found m))))
    found))

(fn encode-blob [blob]
  "Encode the result blob, falling back to dropping :messages if the full
   structure is not JSON-encodable for any reason."
  (let [(ok? encoded) (pcall json.encode blob)]
    (if ok?
        encoded
        (do (set blob.messages nil)
            (tset blob :messages-error "messages omitted: not JSON-encodable")
            (json.encode blob)))))

(fn output-path [state]
  "Resolve where the result blob is written: an explicit opts override (used in
   tests) wins, then FEN_JSON_OUTPUT_PATH; nil means stdout."
  (let [present (fn [s] (and s (not= s "") s))]
    (or (present (?. state :opts :json-output-file))
        (present (os.getenv :FEN_JSON_OUTPUT_PATH)))))

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

;; @doc fen.extensions.json.run
;; kind: function
;; signature: (run ctx) -> nil
;; summary: Step the agent once and write a structured JSON result blob. Exits 1 when the step errored or the output could not be written.
;; tags: json presenter run
(fn M.run [ctx]
  (let [state ctx.state
        prompt (or (?. state :opts :print) ctx.prompt)]
    (when (not prompt)
      (error "json presenter requires a prompt"))
    (let [(ok? result) (xpcall #(agent-mod.step state.agent prompt) debug.traceback)]
      (turn-lifecycle.emit-complete! state ok? result)
      (let [agent state.agent
            asst (last-assistant (?. agent :messages))
            blob {:final-text (if ok? result nil)
                  :messages (or (?. agent :messages) [])
                  :usage (?. asst :usage)
                  :stop-reason (?. asst :stop-reason)
                  :error (if ok? nil (tostring result))}
            wrote? (write-output (output-path state) (encode-blob blob))]
        (when (not (and ok? wrote?))
          (os.exit 1))))))

(fn M.register [api]
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
