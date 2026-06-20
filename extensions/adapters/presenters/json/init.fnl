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
(local text (require :fen.util.text))

(local M {})

(fn last-assistant [messages]
  "Return the most recent assistant message, or nil. The turn's stop-reason
   lives on this message (agent.fnl appends one assistant message per provider
   call)."
  (let [msgs (or messages [])]
    (var found nil)
    (for [i (length msgs) 1 -1 &until found]
      (let [m (. msgs i)]
        (when (= m.role :assistant)
          (set found m))))
    found))

(fn sum-usage [messages]
  "Aggregate usage across every assistant message in the turn. agent.fnl appends
   one assistant message per provider call with its own per-call usage, so a
   multi-step (tool-using) turn would be under-counted if only the last message
   were read. Returns nil when no assistant message carried usage."
  (let [total {}]
    (var any? false)
    (each [_ m (ipairs (or messages []))]
      (when (and (= m.role :assistant) m.usage)
        (set any? true)
        (each [k v (pairs m.usage)]
          (when (= (type v) :number)
            (tset total k (+ (or (. total k) 0) v))))))
    (when any? total)))

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
            messages (or (?. agent :messages) [])
            asst (last-assistant messages)
            ;; A provider failure does not raise: agent.step sets stop-reason
            ;; :error and returns "[error] ...", so ok? alone would report a
            ;; failed turn as success. Treat :error as an error too.
            errored? (or (not ok?) (= (?. asst :stop-reason) :error))
            blob {:final-text (if errored? nil result)
                  :messages messages
                  :usage (sum-usage messages)
                  :stop-reason (?. asst :stop-reason)
                  :error (if errored? (tostring result) nil)}
            wrote? (write-output (output-path state) (encode-blob blob))]
        (when (or errored? (not wrote?))
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
