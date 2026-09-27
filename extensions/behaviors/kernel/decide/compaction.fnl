;; Compaction questions for the decide service.
;;
;; The compact extension calls exactly two functions here: rate-tool-results
;; before summarizing, and ask-good-moment! inside the auto-compaction soft
;; window. Question wording, thresholds, excerpts, and batching all live in
;; this module; compact keeps its threshold, window, and turn bookkeeping.
;; Both functions do nothing when decide is disabled.

(local service (require :fen.extensions.decide.service))
(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local text (require :fen.util.text))

(local M {})

;; Tool-result rating. A result is stubbed when P(no longer needed) reaches
;; DROP-THRESHOLD; results smaller than MIN-RATED-BYTES are not worth a
;; question. Jev sees each result as a head+tail excerpt.
(local DROP-THRESHOLD 0.8)
(local MIN-RATED-BYTES 1024)
(local RATE-HEAD-BYTES 1500)
(local RATE-TAIL-BYTES 500)
(local REQUEST-HEAD-BYTES 1500)
(local REQUEST-TAIL-BYTES 500)
(local ARGS-SUMMARY-BYTES 120)
;; Headroom under decide's request cap for the request envelope around the measured entries.
(local BATCH-BUDGET-RATIO 0.8)
(local DROP-CRITERIA
  {:true "The continuing work does not need this output: it is superseded, redundant, or unrelated to the current request."
   :false "The output holds facts the continuing work still needs, such as file contents, errors, test results, or decisions."})

;; Auto-compaction moment. Inside compact's soft window a rating of at least
;; GOOD-MOMENT-THRESHOLD lets compact compact early.
(local GOOD-MOMENT-THRESHOLD 0.7)
(local MOMENT-MESSAGES 6)
(local MOMENT-TAIL-BYTES 400)
(local MOMENT-QUESTION
  {:type :noul
   :instructions "state.recent_messages are the latest messages of a coding-agent session, oldest first, each cut to its tail. Is this a good moment to compact: the last subtask finished (e.g. checks passed) rather than work being mid-flight (an edit awaiting validation, a failing check being iterated)?"
   :criteria {:true "The last subtask finished: checks passed or the assistant reported the work done, and nothing awaits validation."
              :false "Work is mid-flight: an edit awaits validation, a failing check is being iterated, or the assistant announced an immediate next step."}})

(fn content-text [content]
  "Message text as the summarizer sees it: text, thinking, and tool-call names."
  (if (= (type content) :string)
      content
      (= (type content) :table)
      (let [parts []]
        (each [_ block (ipairs content)]
          (when (= block.type :text)
            (table.insert parts (or block.text "")))
          (when (= block.type :thinking)
            (table.insert parts (or block.thinking "")))
          (when (= block.type :tool-call)
            (table.insert parts (.. "[tool-call " (tostring block.name) "]"))))
        (table.concat parts "\n"))
      ""))

(fn utf8-suffix [s n]
  "Last n bytes of s, advanced past any split UTF-8 continuation bytes."
  (var i (math.max 1 (+ (- (length s) n) 1)))
  (while (and (<= i (length s))
              (let [b (string.byte s i)] (and (>= b 0x80) (< b 0xC0))))
    (set i (+ i 1)))
  (string.sub s i))

(fn head-tail [s head tail]
  (if (<= (length s) (+ head tail))
      s
      (let [h (text.utf8-prefix s head)
            t (utf8-suffix s tail)]
        (.. h "\n[... " (- (length s) (length h) (length t)) " bytes omitted ...]\n" t))))

(fn latest-user-text [messages]
  (var found nil)
  (var i (length messages))
  (while (and (>= i 1) (not found))
    (let [m (. messages i)]
      (when (= m.role :user)
        (set found (content-text m.content))))
    (set i (- i 1)))
  (or found ""))

(fn tool-call-args [messages]
  (let [out {}]
    (each [_ m (ipairs messages)]
      (when (= m.role :assistant)
        (each [_ block (ipairs (or m.content []))]
          (when (and (= block.type :tool-call) block.id)
            (tset out block.id block.arguments)))))
    out))

(fn args-summary [args]
  (when (and (= (type args) :table) (not= (next args) nil))
    (let [(ok? s) (pcall json.encode args)]
      (when ok?
        (if (<= (length s) ARGS-SUMMARY-BYTES)
            s
            (.. (text.utf8-prefix s ARGS-SUMMARY-BYTES) "…"))))))

(fn rating-candidates [span]
  (let [args-by-id (tool-call-args span)
        out []]
    (each [i m (ipairs span)]
      (when (= m.role :tool-result)
        (let [body (content-text m.content)
              args (args-summary (. args-by-id m.tool-call-id))]
          (when (>= (length body) MIN-RATED-BYTES)
            (table.insert out {:id (.. "r" i)
                               :index i
                               :bytes (length body)
                               : args
                               :item {:tool (tostring m.tool-name)
                                      : args
                                      :bytes (length body)
                                      :is_error (= m.is-error? true)
                                      :output (head-tail body RATE-HEAD-BYTES RATE-TAIL-BYTES)}})))))
    out))

(fn drop-question [id]
  {:type :noul
   :instructions (.. "state.tool_results." id " is an older tool result from a coding-agent session about to be summarized. Is it no longer needed to continue the work on state.request?")
   :criteria DROP-CRITERIA})

(fn encoded-bytes [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? (length s) math.huge)))

(fn rating-batches [request candidates]
  "Group candidates into requests that fit decide's size guard; a candidate
   too large on its own is left unrated."
  (let [budget (- (* service.max-request-bytes BATCH-BUDGET-RATIO)
                  (encoded-bytes request))
        batches []]
    (var current nil)
    (var used 0)
    (each [_ c (ipairs candidates)]
      (let [cost (+ (encoded-bytes c.item) (encoded-bytes (drop-question c.id)))]
        (when (<= cost budget)
          (when (or (not current) (> (+ used cost) budget))
            (set current {:state {: request :tool_results {}} :questions {}})
            (set used 0)
            (table.insert batches current))
          (tset current.state.tool_results c.id c.item)
          (tset current.questions c.id (drop-question c.id))
          (set used (+ used cost)))))
    batches))

(fn stub-message [m c]
  (let [out {}]
    (each [k v (pairs m)] (tset out k v))
    (set out.content
         [(types.text-block
            (.. "[tool result omitted before compaction: " (tostring m.tool-name)
                (if c.args (.. " " c.args) "")
                ", " c.bytes " bytes]"))])
    out))

;; @doc fen.extensions.decide.compaction.rate-tool-results
;; kind: function
;; signature: (rate-tool-results messages span ?yield!) -> (span dropped)
;; summary: Rate each older tool result of at least 1 KiB in span and return a copy where results rated >= 0.8 no longer needed are one-line stubs, plus the stub count; returns (span 0) when decide is disabled or never answers. Errors raised by ?yield! (cancellation) propagate.
;; tags: decide compaction
(fn M.rate-tool-results [messages span ?yield!]
  (let [candidates (if (service.enabled?) (rating-candidates span) [])]
    (if (= (length candidates) 0)
        (values span 0)
        (let [request (head-tail (latest-user-text messages) REQUEST-HEAD-BYTES REQUEST-TAIL-BYTES)
              drop {}]
          (each [_ batch (ipairs (rating-batches request candidates))]
            (let [answers (service.ask batch.state batch.questions {:yield ?yield!})]
              (when answers
                (each [id _ (pairs batch.questions)]
                  (let [p (?. answers id :noul)]
                    (when (and (= (type p) :number) (>= p DROP-THRESHOLD))
                      (tset drop id true)))))))
          (let [out []]
            (var n 0)
            (each [_ m (ipairs span)] (table.insert out m))
            (each [_ c (ipairs candidates)]
              (when (. drop c.id)
                (tset out c.index (stub-message (. span c.index) c))
                (set n (+ n 1))))
            (values out n))))))

(fn tail-text [s]
  (if (<= (length s) MOMENT-TAIL-BYTES)
      s
      (.. "…" (utf8-suffix s MOMENT-TAIL-BYTES))))

(fn moment-state [messages]
  "The last few messages as role plus the tail of their text; tool results
   also name the tool and whether it failed."
  (let [n (length messages)
        out []]
    (for [i (math.max 1 (+ (- n MOMENT-MESSAGES) 1)) n]
      (let [m (. messages i)
            entry {:role (tostring m.role) :text (tail-text (content-text m.content))}]
        (when (= m.role :tool-result)
          (set entry.tool (tostring m.tool-name))
          (set entry.is_error (= m.is-error? true)))
        (table.insert out entry)))
    {:recent_messages out}))

;; @doc fen.extensions.decide.compaction.ask-good-moment!
;; kind: function
;; signature: (ask-good-moment! messages on-good) -> nil
;; summary: Ask in the background whether the last subtask in messages finished, and call (on-good) only when the answer is at least 0.7; does nothing when decide is disabled. The caller re-checks its own conditions inside on-good.
;; tags: decide compaction async
(fn M.ask-good-moment! [messages on-good]
  (when (service.enabled?)
    (service.ask-async! (moment-state messages)
                        {:good_moment MOMENT-QUESTION}
                        (fn [answers]
                          (let [p (?. answers :good_moment :noul)]
                            (when (and (= (type p) :number) (>= p GOOD-MOMENT-THRESHOLD))
                              (on-good))))))
  nil)

M
