;; Per-session, append-only ledger of provider usage reports (#617, #619, #620).
;;
;; Every `:llm-end` that carries usage is appended once, by `events.emit`, so
;; the turn, a compaction summary call, and a handoff all land in one place.
;; Views are derived: a delta between a marker and now (turn, run, invocation),
;; or a session total. Usage replayed from a resumed session seeds session
;; totals only, never a delta, so one invocation never reports earlier ones.
;; A history rewrite (compaction) bumps the epoch; provider-reported context
;; size from before the latest rewrite no longer describes the history.
;; State lives on fen.core.extensions.state, so it survives a /reload.

(local state (require :fen.core.extensions.state))

(local M {})

(fn ledger []
  (when (= state.usage-ledger nil)
    (set state.usage-ledger {:entries [] :epoch 0}))
  state.usage-ledger)

(fn current-session []
  (?. state :session :info :id))

(fn add-usage! [total usage]
  (each [key value (pairs usage)]
    (when (= (type value) :number)
      (tset total key (+ (or (. total key) 0) value))))
  total)

(fn entry-for [usage]
  (var found nil)
  (let [entries (. (ledger) :entries)]
    (for [i (length entries) 1 -1 &until found]
      (when (= (. entries i :usage) usage)
        (set found (. entries i)))))
  found)

;; @doc fen.core.extensions.usage_ledger.record!
;; kind: function
;; signature: (record! usage ?opts) -> entry|nil
;; summary: Append one provider usage report to the ledger for the active session; nil usage is ignored. Called by events.emit for every :llm-end, so callers never record by hand.
;; tags: usage ledger tokens
(fn M.record! [usage ?opts]
  (when (= (type usage) :table)
    (let [l (ledger)
          entry {:seq (+ (length l.entries) 1)
                 : usage
                 :session (or (?. ?opts :session) (current-session))
                 :epoch l.epoch
                 :replayed? (= (?. ?opts :replayed?) true)}]
      (table.insert l.entries entry)
      entry)))

;; @doc fen.core.extensions.usage_ledger.mark!
;; kind: function
;; signature: (mark!) -> marker
;; summary: Return a marker for the ledger's current end; delta(marker) later sums the live usage recorded after it (turn, run, or invocation start).
;; tags: usage ledger
(fn M.mark! []
  (length (. (ledger) :entries)))

;; @doc fen.core.extensions.usage_ledger.delta
;; kind: function
;; signature: (delta marker ?session) -> Usage|nil
;; summary: Sum the live (not replayed) usage recorded after marker, optionally for one session; nil when nothing was recorded.
;; tags: usage ledger
(fn M.delta [marker ?session]
  (let [total {}
        entries (. (ledger) :entries)]
    (var any? false)
    (for [i (+ (or marker 0) 1) (length entries)]
      (let [e (. entries i)]
        (when (and (not e.replayed?)
                   (or (= ?session nil) (= e.session ?session)))
          (set any? true)
          (add-usage! total e.usage))))
    (when any? total)))

;; @doc fen.core.extensions.usage_ledger.seed!
;; kind: function
;; signature: (seed! session-id messages) -> number
;; summary: Add usage found on replayed assistant messages that the ledger has not seen, marked replayed so it counts toward session totals but never toward a delta. Returns how many were added.
;; tags: usage ledger session
(fn M.seed! [session-id messages]
  (var added 0)
  (each [_ msg (ipairs (or messages []))]
    (when (and (= msg.role :assistant) (= (type msg.usage) :table)
               (not (entry-for msg.usage)))
      (M.record! msg.usage {:session session-id :replayed? true})
      (set added (+ added 1))))
  added)

;; @doc fen.core.extensions.usage_ledger.session-totals
;; kind: function
;; signature: (session-totals ?session-id ?messages) -> Usage
;; summary: Sum every entry (live and replayed) for the session; messages, when given, are first seeded so a resumed session reports its earlier usage. Includes usage whose messages compaction later dropped.
;; tags: usage ledger status
(fn M.session-totals [?session-id ?messages]
  (let [sid (or ?session-id (current-session))
        total {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}]
    (when ?messages
      (M.seed! sid ?messages))
    (each [_ e (ipairs (. (ledger) :entries))]
      (when (= e.session sid)
        (add-usage! total e.usage)
        (when (= e.usage.total-tokens nil)
          (set total.total-tokens
               (+ total.total-tokens (or e.usage.input 0) (or e.usage.output 0))))))
    total))

;; @doc fen.core.extensions.usage_ledger.rewrite!
;; kind: function
;; signature: (rewrite!) -> epoch
;; summary: Record that the message history was rewritten (compaction); usage reported earlier no longer describes the context.
;; tags: usage ledger compaction
(fn M.rewrite! []
  (let [l (ledger)]
    (set l.epoch (+ l.epoch 1))
    l.epoch))

;; @doc fen.core.extensions.usage_ledger.stale?
;; kind: function
;; signature: (stale? usage) -> boolean
;; summary: True when usage was recorded before the latest history rewrite. Usage the ledger never saw (replayed from disk) is treated as current.
;; tags: usage ledger context
(fn M.stale? [usage]
  (let [e (and (= (type usage) :table) (entry-for usage))]
    (and e (< e.epoch (. (ledger) :epoch)) true)))

(fn latest-usage-message [messages]
  (var found nil)
  (for [i (length (or messages [])) 1 -1 &until found]
    (let [m (. messages i)]
      (when (and (= m.role :assistant) (= (type m.usage) :table))
        (set found m))))
  found)

;; @doc fen.core.extensions.usage_ledger.context-info
;; kind: function
;; signature: (context-info agent) -> {:tokens :source :estimated?}
;; summary: Context size for status and hints: provider-reported when the latest usage is newer than the last history rewrite, otherwise the local estimate (#620).
;; tags: usage ledger context status
(fn M.context-info [agent]
  (let [tokens (require :fen.util.tokens)
        last (and agent (latest-usage-message agent.messages))]
    (if (and last (M.stale? last.usage))
        {:tokens (tokens.estimated-context-tokens agent)
         :source :estimated
         :estimated? true}
        (tokens.context-token-info agent))))

;; @doc fen.core.extensions.usage_ledger.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Empty the ledger (test isolation).
;; tags: usage ledger
(fn M.reset! []
  (set state.usage-ledger {:entries [] :epoch 0})
  nil)

M
