;; Structured subagent progress events.
;;
;; Children append JSONL records while the parent drains them cooperatively into
;; persistent subagent run state. Keep this module reloadable; durable identity
;; lives in fen.extensions.subagent.state.

(local json (require :fen.util.json))
(local text (require :fen.util.text))

(local M {})

(local SUMMARY-BYTES 160)
(local DRAIN-BYTE-BUDGET (* 64 1024))
(local DRAIN-EVENT-BUDGET 64)

(fn now []
  (os.date "!%Y-%m-%dT%H:%M:%SZ"))

(fn blank->nil [s]
  (text.blank->nil (tostring (or s ""))))

(fn summarize [v]
  (let [s (if (= (type v) :string)
              v
              (= v nil)
              ""
              (let [(ok? encoded) (pcall json.encode v)]
                (if ok? encoded (tostring v))))]
    (text.truncate-line (text.first-line s) SUMMARY-BYTES)))

(fn env-meta []
  {:run-id (blank->nil (os.getenv :FEN_SUBAGENT_RUN_ID))
   :agent (blank->nil (os.getenv :FEN_SUBAGENT_NAME))
   :requested-cwd (blank->nil (os.getenv :FEN_SUBAGENT_REQUESTED_CWD))
   :cwd (blank->nil (os.getenv :FEN_SUBAGENT_CWD))
   :physical-cwd (blank->nil (os.getenv :FEN_SUBAGENT_PHYSICAL_CWD))})

(fn copy-meta! [out meta]
  (each [_ k (ipairs [:run-id :agent :requested-cwd :cwd :physical-cwd])]
    (let [v (. meta k)]
      (when v (tset out k v))))
  out)

(fn M.normalize [ev ?meta]
  "Return a bounded, JSON-encodable subagent progress event for EV."
  (let [meta (or ?meta (env-meta))
        typ (?. ev :type)
        out {:type typ :timestamp (now)}]
    (copy-meta! out meta)
    (if (= typ :tool-call)
        (do
          (set out.name (tostring (or ev.name "")))
          (set out.id ev.id)
          (set out.summary (summarize ev.arguments)))
        (= typ :tool-result)
        (do
          (set out.name (tostring (or ev.name "")))
          (set out.id ev.id)
          (set out.duration-seconds ev.duration-seconds)
          (set out.is-error? (not (not (?. ev :result :is-error?))))
          (set out.summary (summarize (or (?. ev :result :content)
                                          (?. ev :result)))))
        (= typ :assistant-text)
        (do
          (set out.final? (not (not ev.final?)))
          (set out.summary (summarize ev.text)))
        (= typ :assistant-thinking)
        (do
          (set out.final? (not (not ev.final?)))
          (set out.summary (summarize ev.text)))
        (= typ :assistant-text-delta)
        (set out.summary (summarize ev.text))
        (= typ :llm-start)
        (do
          (set out.provider ev.provider)
          (set out.model ev.model))
        (= typ :llm-end)
        (do
          (set out.stop-reason ev.stop-reason)
          (set out.usage ev.usage))
        (= typ :agent-started)
        (do
          (set out.provider ev.provider)
          (set out.model ev.model)
          (set out.cwd ev.cwd))
        (= typ :agent-turn-complete)
        (do
          (set out.status ev.status)
          (set out.summary (summarize (or ev.result ev.error)))
          (when ev.error (set out.error (summarize ev.error))))
        (= typ :error)
        (do
          (set out.error (summarize (or ev.error ev.text)))
          (set out.source ev.source))
        (= typ :subagent-start)
        (do
          (set out.timeout-seconds ev.timeout-seconds)
          (set out.summary (summarize ev.task)))
        (= typ :subagent-done)
        (do
          (set out.status ev.status)
          (set out.summary (summarize ev.summary)))
        (set out.summary (summarize ev)))
    out))

(fn M.append! [path ev ?meta]
  "Append one normalized event to PATH. Returns true, or nil plus an error."
  (let [(f err) (io.open path :a)]
    (if (not f)
        (values nil (tostring err))
        (let [(ok? encoded-or-err) (pcall json.encode (M.normalize ev ?meta))]
          (if (not ok?)
              (do (f:close) (values nil (tostring encoded-or-err)))
              (let [(wok? werr) (pcall #(f:write (.. encoded-or-err "\n")))]
                (f:close)
                (if wok? true (values nil (tostring werr)))))))))

(fn decode-line [line]
  (let [(ok? decoded) (pcall json.decode line)]
    (if (and ok? (= (type decoded) :table))
        decoded
        nil
        (if ok? "decoded JSON is not an object" (tostring decoded)))))

(fn M.drain [path ?offset]
  "Drain a bounded JSONL prefix from PATH starting at byte OFFSET.

   Only complete records are consumed, so a writer's partial final line is
   retried on the next tick. Returns events, new-offset, errors, and status.
   Missing files are not fatal."
  (let [offset (or ?offset 0)
        (f err) (io.open path :r)]
    (if (not f)
        (values [] offset [] :missing)
        (do
          (f:seek :set offset)
          (let [chunk (or (f:read DRAIN-BYTE-BUDGET) "")
                events []
                errors []]
            (f:close)
            (var pos 1)
            (var count 0)
            (var newline (string.find chunk "\n" pos true))
            (while (and newline (< count DRAIN-EVENT-BUDGET))
              (let [line (string.sub chunk pos (- newline 1))]
                (when (not= line "")
                  (let [(ev decode-err) (decode-line line)]
                    (if ev
                        (table.insert events ev)
                        (table.insert errors {:line (text.truncate-line line 120)
                                              :error decode-err}))))
                (set count (+ count 1))
                (set pos (+ newline 1))
                (set newline (string.find chunk "\n" pos true))))
            (values events (+ offset (- pos 1)) errors :ok))))))

M
