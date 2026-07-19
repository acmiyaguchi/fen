;; Lightweight token estimation and formatting helpers.
;;
;; These estimates are deliberately rough (chars / 4). Provider-reported usage
;; remains authoritative; this module only feeds status displays and cheap
;; context-size hints on small machines.

(local json (require :fen.util.json))

(local M {})

;; @doc fen.util.tokens.approx-tokens
;; kind: function
;; signature: (approx-tokens s) -> number
;; summary: Estimate token count from text length for status displays when provider-reported usage is unavailable.
;; tags: tokens status
(fn M.approx-tokens [s]
  (if (or (= s nil) (= s ""))
      0
      (math.ceil (/ (length (tostring s)) 4))))

;; @doc fen.util.tokens.safe-json
;; kind: function
;; signature: (safe-json v) -> string
;; summary: JSON-encode a value for token estimation, falling back to tostring when encoding fails.
;; tags: tokens json
(fn M.safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

;; @doc fen.util.tokens.content-tokens
;; kind: function
;; signature: (content-tokens content) -> number
;; summary: Estimate tokens for canonical message content, including text, thinking blocks, and tool-call names/arguments.
;; tags: tokens messages
(fn M.content-tokens [content]
  (if (= content nil)
      0
      (= (type content) :string)
      (M.approx-tokens content)
      (do
        (var n 0)
        (each [_ block (ipairs content)]
          (if (= block.type :text)
              (set n (+ n (M.approx-tokens block.text)))
              (= block.type :thinking)
              ;; Responses/Codex stores the replayable encrypted reasoning
              ;; item in thinking-signature. It is request context just like
              ;; visible thinking text, and can be much larger than it.
              (set n (+ n
                        (M.approx-tokens block.thinking)
                        (M.approx-tokens block.thinking-signature)))
              (= block.type :tool-call)
              (set n (+ n
                        (M.approx-tokens block.name)
                        (M.approx-tokens (M.safe-json (or block.arguments {})))))))
        n)))

(fn context-message? [msg]
  ;; Keep this aligned with core.agent: failed/partial assistant turns are
  ;; persisted for diagnostics but are not replayed to providers.
  (not (and (= msg.role :assistant) (= msg.stop-reason :error))))

;; @doc fen.util.tokens.message-tokens
;; kind: function
;; signature: (message-tokens msg) -> number
;; summary: Estimate tokens for one provider-context message including role and tool-result name metadata; persisted failed assistant turns count as zero because they are not replayed.
;; tags: tokens messages
(fn M.message-tokens [msg]
  (let [m (or msg {})]
    (if (context-message? m)
        (+ (M.approx-tokens m.role)
           (M.content-tokens m.content)
           (if (= m.role :tool-result)
               (M.approx-tokens m.tool-name)
               0))
        0)))

(fn tool-visible? [tool active-tool-names]
  (or (not= tool.exposure :search)
      (= true (. (or active-tool-names {}) (tostring tool.name)))))

(fn tool-schema-tokens [tools active-tool-names]
  "Estimate the provider-visible declaration for each active tool. Exclude
   executable fields such as handlers, which never ride on the wire."
  (var n 0)
  (each [_ tool (ipairs (or tools []))]
    (when (tool-visible? tool active-tool-names)
      (set n (+ n (M.approx-tokens
                    (M.safe-json {:name tool.name
                                  :description tool.description
                                  :parameters (or tool.parameters {})}))))))
  n)

(fn active-tools-key [tools active-tool-names]
  "Cheap ledger validity key for dynamic tool_search activation."
  (let [names []]
    (each [_ tool (ipairs (or tools []))]
      (when (tool-visible? tool active-tool-names)
        (table.insert names (tostring tool.name))))
    (table.sort names)
    (table.concat names "\0")))

(fn make-empty-ledger [system-prompt messages tools active-tool-names]
  (let [system-tokens (M.approx-tokens system-prompt)
        tools-tokens (tool-schema-tokens tools active-tool-names)]
    {:system-prompt system-prompt
     :system-tokens system-tokens
     :tools-ref tools
     :active-tools-key (active-tools-key tools active-tool-names)
     :tools-tokens tools-tokens
     :messages-ref messages
     :message-count 0
     :message-tokens []
     :total (+ system-tokens tools-tokens)}))

;; @doc fen.util.tokens.rebuild-ledger
;; kind: function
;; signature: (rebuild-ledger system-prompt messages ?tools ?active-tool-names) -> TokenLedger
;; summary: Build a token ledger for the current system prompt, active tool schemas, and message table in one pass.
;; tags: tokens ledger
(fn M.rebuild-ledger [system-prompt messages ?tools ?active-tool-names]
  (let [msgs (or messages [])
        ledger (make-empty-ledger system-prompt msgs ?tools ?active-tool-names)]
    (each [_ msg (ipairs msgs)]
      (let [n (M.message-tokens msg)]
        (table.insert ledger.message-tokens n)
        (set ledger.message-count (+ ledger.message-count 1))
        (set ledger.total (+ ledger.total n))))
    ledger))

(fn valid-ledger? [agent ledger]
  (and agent ledger
       (= ledger.system-prompt agent.system-prompt)
       (= ledger.tools-ref agent.tools)
       (= ledger.active-tools-key
          (active-tools-key agent.tools agent.active-tool-names))
       (= ledger.messages-ref agent.messages)
       (= ledger.message-count (length (or agent.messages [])))))

;; @doc fen.util.tokens.rebuild-agent-ledger!
;; kind: function
;; signature: (rebuild-agent-ledger! agent) -> TokenLedger
;; summary: Recompute and attach the context-token ledger for an agent.
;; tags: tokens ledger agent
(fn M.rebuild-agent-ledger! [agent]
  (let [ledger (M.rebuild-ledger (?. agent :system-prompt)
                                 (or (?. agent :messages) [])
                                 (?. agent :tools)
                                 (?. agent :active-tool-names))]
    (when agent
      (tset agent :context-token-ledger ledger))
    ledger))

;; @doc fen.util.tokens.note-message-appended!
;; kind: function
;; signature: (note-message-appended! agent message index) -> TokenLedger|nil
;; summary: Increment an agent's token ledger after append-message! grows agent.messages, falling back to lazy rebuild when the ledger is stale.
;; tags: tokens ledger agent
(fn M.note-message-appended! [agent message ?index]
  (when agent
    (let [messages (or agent.messages [])
          index (or ?index (length messages))
          ledger (or agent.context-token-ledger
                     (make-empty-ledger agent.system-prompt messages
                                        agent.tools agent.active-tool-names))]
      (if (and (= ledger.system-prompt agent.system-prompt)
               (= ledger.tools-ref agent.tools)
               (= ledger.active-tools-key
                  (active-tools-key agent.tools agent.active-tool-names))
               (= ledger.messages-ref messages)
               (= ledger.message-count (- index 1)))
          (let [n (M.message-tokens message)]
            (table.insert ledger.message-tokens n)
            (set ledger.message-count index)
            (set ledger.total (+ ledger.total n))
            (tset agent :context-token-ledger ledger)
            ledger)
          ;; Direct message-table edits happened. Leave the next estimate to
          ;; rebuild once rather than doing an O(history) walk on this append.
          (do (tset agent :context-token-ledger nil) nil)))))

;; @doc fen.util.tokens.estimated-context-tokens
;; kind: function
;; signature: (estimated-context-tokens agent) -> number
;; summary: Return an agent's approximate context tokens, using an incremental ledger when current and rebuilding once after direct message edits.
;; tags: tokens ledger agent
(fn M.estimated-context-tokens [agent]
  (if (not agent)
      0
      (let [ledger agent.context-token-ledger]
        (if (valid-ledger? agent ledger)
            ledger.total
            (. (M.rebuild-agent-ledger! agent) :total)))))

(fn reported-context [messages]
  "Return the provider-reported context at the latest assistant boundary.
   Canonical input excludes cache reads/writes, so all input classes plus the
   generated output are needed to describe context after that message."
  (var i (length (or messages [])))
  (var found nil)
  (while (and (> i 0) (= found nil))
    (let [msg (. messages i)
          u (and (= msg.role :assistant)
                 (context-message? msg)
                 msg.usage)
          input (and u (or u.input 0))
          output (and u (or u.output 0))
          cache-read (and u (or u.cache-read 0))
          cache-write (and u (or u.cache-write 0))]
      ;; Canonical assistant constructors use an all-zero usage record when a
      ;; provider omitted usage, so require at least one non-zero counter.
      (when (and u (> (+ input output cache-read cache-write) 0))
        (set found {:tokens (+ input output cache-read cache-write)
                    :index i})))
    (set i (- i 1)))
  found)

;; @doc fen.util.tokens.context-token-info
;; kind: function
;; signature: (context-token-info agent) -> {:tokens number :source keyword :estimated? boolean}
;; summary: Prefer exact provider-reported context at the latest assistant boundary, otherwise return the wire-aware fallback estimate.
;; tags: tokens context usage status
(fn M.context-token-info [agent]
  (if (not agent)
      {:tokens 0 :source :estimated :estimated? true}
      (let [reported (reported-context agent.messages)
            message-count (length (or agent.messages []))]
        (if (and reported (= reported.index message-count))
            {:tokens reported.tokens :source :provider-reported :estimated? false}
            ;; Messages after the reported boundary (normally tool results)
            ;; make that old number stale. Prefer a complete fallback estimate
            ;; over presenting stale provider data as exact.
            {:tokens (M.estimated-context-tokens agent)
             :source :estimated :estimated? true}))))

;; @doc fen.util.tokens.usage-totals
;; kind: function
;; signature: (usage-totals messages) -> Usage
;; summary: Sum provider usage counters across assistant messages for status and session diagnostics.
;; tags: tokens usage messages
(fn M.usage-totals [messages]
  (let [u {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0}]
    (each [_ msg (ipairs (or messages []))]
      (when (and (= msg.role :assistant) msg.usage)
        (set u.input (+ u.input (or msg.usage.input 0)))
        (set u.output (+ u.output (or msg.usage.output 0)))
        (set u.cache-read (+ u.cache-read (or msg.usage.cache-read 0)))
        (set u.cache-write (+ u.cache-write (or msg.usage.cache-write 0)))
        (set u.total-tokens (+ u.total-tokens
                               (or msg.usage.total-tokens
                                   (+ (or msg.usage.input 0)
                                      (or msg.usage.output 0)))))))
    u))

;; @doc fen.util.tokens.fmt-tokens
;; kind: function
;; signature: (fmt-tokens n) -> string
;; summary: Format a token count compactly with raw, k, or M suffixes for status output.
;; tags: tokens format
(fn M.fmt-tokens [n]
  (let [n (or n 0)]
    (if (< n 1000) (tostring n)
        (< n 10000) (string.format "%.1fk" (/ n 1000))
        (< n 1000000) (string.format "%dk" (math.floor (/ n 1000)))
        (string.format "%.1fM" (/ n 1000000)))))

;; @doc fen.util.tokens.format-token-summary
;; kind: function
;; signature: (format-token-summary usage context ?estimated?) -> string
;; summary: Build the one-line input/output/cache/context token summary shown by status UIs.
;; tags: tokens format status
(fn M.format-token-summary [usage context ?estimated?]
  (let [estimated? (if (= ?estimated? nil) true ?estimated?)]
    (.. "↑" (M.fmt-tokens usage.input)
        " ↓" (M.fmt-tokens usage.output)
        " R" (M.fmt-tokens usage.cache-read)
        " W" (M.fmt-tokens usage.cache-write)
        "  ctx:" (if estimated? "~" "") (M.fmt-tokens context))))

M
