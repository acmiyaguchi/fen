;; Canonical wire protocol between a parent and a live child agent.
;;
;; This module is the authoritative schema for both directions of the duplex
;; JSONL channel (#516): child -> parent events and parent -> child controls.
;; Every line is a versioned envelope {:v :seq :type :run ...payload}.
;; It also owns the transport bounds for display events: bounded copy,
;; byte/depth/entry budgets, text scrubbing, and truncation flags (#395).
;;
;; Invalid input never throws: decode/validate return nil plus a rejection
;; value {:code :reason :fatal? :seq :type :run :errors}. Keep this module
;; reloadable and stateless; senders and receivers are plain data tables.

(local json (require :fen.util.json))
(local json-schema (require :fen.util.json_schema))
(local text (require :fen.util.text))

(local M {})

(local VERSION 1)
(local SUMMARY-BYTES 160)
(local EVENT-PAYLOAD-BYTES (* 12 1024))
(local EVENT-RECORD-BYTES (* 16 1024))
(local EVENT-STRING-BYTES (* 4 1024))
(local EVENT-TABLE-ENTRIES 64)
(local EVENT-MAX-DEPTH 8)
(local DRAIN-BYTE-BUDGET (* 64 1024))
(local DRAIN-EVENT-BUDGET 64)
;; A line longer than one drain chunk could never be consumed by `drain`.
(local MAX-LINE-BYTES DRAIN-BYTE-BUDGET)

;; ----------------------------------------------------------------
;; Display event normalization (transport bounds)
;; ----------------------------------------------------------------

(fn now []
  (os.date "!%Y-%m-%dT%H:%M:%SZ"))

(fn summarize [v]
  (let [s (if (= (type v) :string)
              v
              (= v nil)
              ""
              (let [(ok? encoded) (pcall json.encode v)]
                (if ok? encoded (tostring v))))]
    (text.truncate-line (text.first-line s) SUMMARY-BYTES)))

(local META-KEYS [:run-id :agent :requested-cwd :cwd :physical-cwd])

(fn copy-meta! [out meta]
  (each [_ k (ipairs META-KEYS)]
    (let [v (. meta k)]
      (when v (tset out k v))))
  out)

(fn bounded-copy [value budget depth]
  (if (> depth EVENT-MAX-DEPTH)
      (do (set budget.truncated? true) "[transport depth limit]")
      (= (type value) :string)
      (let [limit (math.max 1 (math.min EVENT-STRING-BYTES budget.bytes))
            scrubbed (text.scrub-tool-text value {:max-bytes limit})]
        (set budget.bytes (math.max 0 (- budget.bytes (length scrubbed.text))))
        (when scrubbed.changed? (set budget.truncated? true))
        scrubbed.text)
      (= (type value) :table)
      (let [out {}]
        (each [k v (pairs value)]
          (if (or (<= budget.entries 0) (<= budget.bytes 0))
              (set budget.truncated? true)
              (do
                (set budget.entries (- budget.entries 1))
                (tset out k (bounded-copy v budget (+ depth 1))))))
        out)
      (or (= value nil) (= (type value) :boolean) (= (type value) :number)) value
      (do (set budget.truncated? true) (tostring value))))

(fn keep-payload! [out key value budget]
  (when (not= value nil)
    (tset out key (bounded-copy value budget 0))))

(fn M.normalize [ev ?meta]
  "Return a bounded canonical display event for EV.
   ?meta supplies run metadata (:run-id :agent :requested-cwd :cwd
   :physical-cwd). Oversized or non-JSON payloads are cut to the transport
   budgets and flagged with :transport-truncated?."
  (let [meta (or ?meta {})
        typ (?. ev :type)
        out {:type typ :timestamp (now)}
        budget {:bytes EVENT-PAYLOAD-BYTES :entries EVENT-TABLE-ENTRIES
                :truncated? false}]
    (copy-meta! out meta)
    (if (= typ :tool-call)
        (do
          (set out.name (tostring (or ev.name "")))
          (set out.id ev.id)
          (keep-payload! out :arguments ev.arguments budget)
          (set out.summary (summarize ev.arguments)))
        (= typ :tool-result)
        (do
          (set out.name (tostring (or ev.name "")))
          (set out.id ev.id)
          (set out.tool-call-id ev.tool-call-id)
          (set out.duration-seconds ev.duration-seconds)
          (set out.is-error? (not (not (or ev.is-error?
                                               (?. ev :result :is-error?)))))
          (keep-payload! out :result ev.result budget)
          (set out.summary (summarize (or (?. ev :result :content)
                                          (?. ev :result)))))
        (or (= typ :assistant-text) (= typ :assistant-thinking))
        (do
          (set out.final? (not (not ev.final?)))
          (set out.content-index ev.content-index)
          (keep-payload! out :text ev.text budget)
          (set out.summary (summarize ev.text)))
        (or (= typ :user) (= typ :steering-injected)
            (= typ :follow-up-injected))
        (do
          (keep-payload! out :text ev.text budget)
          (set out.summary (summarize ev.text)))
        (or (= typ :assistant-text-delta) (= typ :assistant-thinking-delta))
        (do
          (set out.content-index ev.content-index)
          (keep-payload! out :delta ev.delta budget)
          (set out.summary (summarize ev.delta)))
        (= typ :assistant-stream-end)
        (set out.final? (not (not ev.final?)))
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
    (when budget.truncated? (set out.transport-truncated? true))
    out))

(fn M.append! [path ev ?meta]
  "Append one normalized display event for EV to PATH as a JSONL record.
   Records over the transport record limit are replaced by a bounded :info
   record. Returns true, or nil plus an error."
  (let [(f err) (io.open path :a)]
    (if (not f)
        (values nil (tostring err))
        (let [(ok? encoded-or-err) (pcall json.encode (M.normalize ev ?meta))]
          (if (not ok?)
              (do (f:close) (values nil (tostring encoded-or-err)))
              (let [encoded (if (> (length encoded-or-err) EVENT-RECORD-BYTES)
                                (json.encode {:type :info
                                              :summary (.. (tostring (or ev.type :event))
                                                           " payload omitted: transport record limit")
                                              :transport-truncated? true
                                              :timestamp (now)})
                                encoded-or-err)
                    (wok? werr) (pcall #(f:write (.. encoded "\n")))]
                (f:close)
                (if wok? true (values nil (tostring werr)))))))))

(fn decode-line [line]
  (let [(ok? decoded) (pcall json.decode line)]
    (if (and ok? (= (type decoded) :table))
        decoded
        nil
        (if ok? "decoded JSON is not an object" (tostring decoded)))))

(fn M.drain [path ?offset]
  "Drain a bounded JSONL prefix from PATH starting at byte ?offset.

   Only complete records are consumed, so a writer's partial final line is
   retried on the next tick. Returns records, new-offset, errors, and status
   (:ok or :missing). Missing files are not fatal."
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

;; ----------------------------------------------------------------
;; Envelope schema: both directions
;; ----------------------------------------------------------------

(local str {:type :string})
(local int {:type :integer})
(local num {:type :number})
(local bool {:type :boolean})
(local obj {:type :object})
(local any {})

(fn object-schema [properties ?required]
  {:type :object :properties properties :required (or ?required [])})

;; Fields every normalized display event may carry (see `normalize`).
(fn display-event [extra ?required]
  (let [props {:timestamp str :summary str :transport-truncated? bool
               :run-id str :agent str :requested-cwd str :cwd str
               :physical-cwd str}]
    (each [k v (pairs extra)] (tset props k v))
    (object-schema props ?required)))

(local turn {:type :integer :minimum 1})

;; Child -> parent. Keys are wire `type` values; schemas cover the payload.
(local EVENT-SCHEMAS
  {;; Normalized display events.
   :tool-call (display-event {:name str :id str :arguments any} [:name])
   :tool-result (display-event {:name str :id str :tool-call-id str
                                :duration-seconds num :is-error? bool
                                :result any}
                               [:name :is-error?])
   :assistant-text (display-event {:final? bool :content-index int :text str}
                                  [:final?])
   :assistant-thinking (display-event {:final? bool :content-index int
                                       :text str}
                                      [:final?])
   :assistant-text-delta (display-event {:content-index int :delta str})
   :assistant-thinking-delta (display-event {:content-index int :delta str})
   :assistant-stream-end (display-event {:final? bool} [:final?])
   :user (display-event {:text str})
   :steering-injected (display-event {:text str})
   :follow-up-injected (display-event {:text str})
   :llm-start (display-event {:provider str :model str})
   :llm-end (display-event {:stop-reason str :usage obj})
   :agent-started (display-event {:provider str :model str})
   :agent-turn-complete (display-event {:status str :error str})
   :error (display-event {:error str :source str})
   :info (display-event {})
   ;; Live-child lifecycle.
   :ready (object-schema {})
   :turn-started (object-schema {:turn turn} [:turn])
   :turn-complete (object-schema {:turn turn :stop-reason str :usage obj}
                                 [:turn])
   :control-ack {:type :object
                 :properties {:ref {:type :integer :minimum 1}
                              :status {:type :string
                                       :enum [:accepted :rejected :applied]}
                              :reason str}
                 :required [:status]
                 ;; ref may be omitted only when a rejected line had no seq.
                 :anyOf [{:required [:ref]}
                         {:properties {:status {:enum [:rejected]}}}]}
   :result (object-schema {:final-text str :stop-reason str :usage obj
                           :context {:type :string
                                     :enum [:complete :partial]}}
                          [:context])
   :exit (object-schema {:status {:type :string
                                  :enum [:done :cancelled :failed :timed-out]}
                         :error str}
                        [:status])})

;; Parent -> child.
(local CONTROL-SCHEMAS
  {:prompt (object-schema {:text str} [:text])
   :steer (object-schema {:text str} [:text])
   :follow-up (object-schema {:text str} [:text])
   :finalize (object-schema {:note str})
   :cancel (object-schema {})
   :close (object-schema {})})

(local SCHEMAS {:event EVENT-SCHEMAS :control CONTROL-SCHEMAS})

(local ENVELOPE-SCHEMA
  (object-schema {:v int
                  :seq {:type :integer :minimum 1}
                  :type str
                  :run str}
                 [:v :seq :type :run]))

(fn type-set [schemas]
  (let [out {}]
    (each [k _ (pairs schemas)] (tset out k true))
    out))

(fn other-direction [direction]
  (if (= direction :event) :control :event))

(fn rejection [code reason ?msg ?errors]
  (let [msg (if (= (type ?msg) :table) ?msg {})
        seq (and (= (type msg.seq) :number) (math.tointeger msg.seq))]
    {:code code
     :reason reason
     :fatal? (= code :version-mismatch)
     :seq (when (and seq (>= seq 1)) seq)
     :type (when (= (type msg.type) :string) msg.type)
     :run (when (= (type msg.run) :string) msg.run)
     :errors ?errors}))

(fn describe-errors [errors]
  (let [parts []]
    (each [_ e (ipairs (or errors []))]
      (table.insert parts (.. e.field " " e.message)))
    (table.concat parts "; ")))

(fn json-object? [value]
  (and (= (type value) :table)
       (not= nil (json-schema.validate {:type :object} value))))

(fn valid-direction? [direction]
  (not= nil (. SCHEMAS direction)))

(fn M.validate [msg direction]
  "Validate envelope MSG for DIRECTION (:event child->parent or :control
   parent->child). Returns MSG, or nil plus a rejection
   {:code :reason :fatal? :seq :type :run :errors}. Codes: :invalid,
   :version-mismatch (fatal), :unknown-type, :invalid-payload. Never throws."
  (if (not (valid-direction? direction))
      (values nil (rejection :invalid (.. "unknown direction: " (tostring direction))))
      (not (json-object? msg))
      (values nil (rejection :invalid "message must be a JSON object"))
      (not= msg.v VERSION)
      (values nil (rejection :version-mismatch
                             (.. "wire version " (tostring msg.v)
                                 " is not supported; expected " VERSION)
                             msg))
      (let [(ok? errors) (json-schema.validate ENVELOPE-SCHEMA msg)]
        (if (not ok?)
            (values nil (rejection :invalid (describe-errors errors) msg errors))
            (let [schema (. SCHEMAS direction msg.type)]
              (if (not schema)
                  (values nil (rejection :unknown-type
                                         (if (. SCHEMAS (other-direction direction) msg.type)
                                             (.. msg.type " is not a " direction " message")
                                             (.. "unknown " direction " type: " msg.type))
                                         msg))
                  (let [(pok? perrors) (json-schema.validate schema msg)]
                    (if pok?
                        msg
                        (values nil (rejection :invalid-payload
                                               (describe-errors perrors)
                                               msg perrors))))))))))

(fn M.message [typ run seq ?payload]
  "Build an unvalidated envelope: ?payload fields plus :v :seq :type :run.
   Envelope fields win over payload fields of the same name."
  (let [out {}]
    (each [k v (pairs (or ?payload {}))] (tset out k v))
    (set out.v VERSION)
    (set out.seq seq)
    (set out.type typ)
    (set out.run run)
    out))

(fn M.encode [msg direction]
  "Validate MSG for DIRECTION and encode it as one JSONL line without the
   trailing newline. Returns the line, or nil plus a rejection (including
   :too-large past MAX-LINE-BYTES)."
  (let [(valid rej) (M.validate msg direction)]
    (if (not valid)
        (values nil rej)
        (let [(ok? line) (pcall json.encode valid)]
          (if (not ok?)
              (values nil (rejection :invalid (tostring line) valid))
              (>= (length line) MAX-LINE-BYTES)
              (values nil (rejection :too-large
                                     (.. "encoded line exceeds " MAX-LINE-BYTES " bytes")
                                     valid))
              line)))))

(fn M.decode [line direction]
  "Decode and validate one JSONL LINE for DIRECTION. Returns the message, or
   nil plus a rejection (:malformed, :too-large, or any `validate` code)."
  (if (not= (type line) :string)
      (values nil (rejection :malformed "line must be a string"))
      (>= (length line) MAX-LINE-BYTES)
      (values nil (rejection :too-large
                             (.. "line exceeds " MAX-LINE-BYTES " bytes")))
      (let [(ok? decoded) (pcall json.decode line)]
        (if (not ok?)
            (values nil (rejection :malformed (tostring decoded)))
            (not (json-object? decoded))
            (values nil (rejection :malformed "decoded JSON is not an object"))
            (M.validate decoded direction)))))

(fn M.sender [direction run]
  "Return sender state for DIRECTION on RUN: {:direction :run :seq}."
  {:direction direction :run run :seq 0})

(fn M.next! [sender typ ?payload]
  "Stamp, validate, and encode the next message from SENDER. The sender's
   seq advances only when a line is produced. Returns the line, or nil plus
   a rejection."
  (let [msg (M.message typ sender.run (+ sender.seq 1) ?payload)
        (line rej) (M.encode msg sender.direction)]
    (when line (set sender.seq msg.seq))
    (values line rej)))

(fn M.receiver [direction]
  "Return receiver state for lines arriving in DIRECTION: {:direction :seq}."
  {:direction direction :seq 0})

(fn M.receive! [receiver line]
  "Decode LINE for RECEIVER, also rejecting a seq that does not increase
   (:out-of-order). Any readable increasing seq is consumed, even when the
   payload is rejected. Returns the message, or nil plus a rejection."
  (let [(msg rej) (M.decode line receiver.direction)
        seq (or (?. msg :seq) (?. rej :seq))]
    (if (?. rej :fatal?)
        (values nil rej)
        (and seq (<= seq receiver.seq))
        (values nil (rejection :out-of-order
                               (.. "seq " seq " does not follow " receiver.seq)
                               (or msg {:seq seq :type (?. rej :type)
                                        :run (?. rej :run)})))
        (do
          (when seq (set receiver.seq seq))
          (values msg rej)))))

(fn M.rejection-ack [rej]
  "Return the control-ack payload answering rejection REJ."
  {:ref rej.seq :status :rejected :reason rej.reason})

(fn M.event-type? [typ]
  "True when TYP is a child->parent wire event type."
  (not= nil (. EVENT-SCHEMAS typ)))

(fn M.control-type? [typ]
  "True when TYP is a parent->child wire control type."
  (not= nil (. CONTROL-SCHEMAS typ)))

(set M.VERSION VERSION)
(set M.SCHEMAS SCHEMAS)
(set M.ENVELOPE-SCHEMA ENVELOPE-SCHEMA)
(set M.EVENT-TYPES (type-set EVENT-SCHEMAS))
(set M.CONTROL-TYPES (type-set CONTROL-SCHEMAS))
(set M.EVENT-PAYLOAD-BYTES EVENT-PAYLOAD-BYTES)
(set M.EVENT-RECORD-BYTES EVENT-RECORD-BYTES)
(set M.DRAIN-BYTE-BUDGET DRAIN-BYTE-BUDGET)
(set M.DRAIN-EVENT-BUDGET DRAIN-EVENT-BUDGET)
(set M.MAX-LINE-BYTES MAX-LINE-BYTES)

M
